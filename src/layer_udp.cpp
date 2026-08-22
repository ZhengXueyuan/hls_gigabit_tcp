//=============================================================================
// layer_udp.cpp — UDP (User Datagram Protocol) transport layer
//=============================================================================
// Port filtering (8080), payload echo, periodic default message sending.
// RX: reads UDP header from buffer, stores payload for echo
// TX: builds IP+UDP header with echoed payload or default message
//=============================================================================

#include "eth_types.h"
#include "eth_utils.h"

#define UDP_PORT  0x1F90   // 8080

//=============================================================================
// UDP RX processing
//=============================================================================
static void udp_rx_process(
    bool          reset_n,
    ip_rx_t      &ip_rx,
    uint32_t     *buffer,
    udp_rx_t     &udp_rx
) {
    udp_rx.valid = false;
    udp_rx.src_port = 0;
    udp_rx.dst_port = 0;
    udp_rx.length   = 0;
    udp_rx.checksum = 0;
    udp_rx.payload_len = 0;
    udp_rx.buf_base = 0;

    if (!reset_n) return;
    if (!ip_rx.valid) return;
    if (ip_rx.protocol != IP_PROTO_UDP) return;

    // UDP header starts after 20-byte IP header (word 5 of the staged frame)
    int udp_base = 5;

    uint8_t udp_hdr[8];
    for (int i = 0; i < 2; i++) {
        uint32_t w = frame_buf[udp_base + i];
        udp_hdr[i*4 + 0] = (w >> 24) & 0xFF;
        udp_hdr[i*4 + 1] = (w >> 16) & 0xFF;
        udp_hdr[i*4 + 2] = (w >> 8)  & 0xFF;
        udp_hdr[i*4 + 3] = w & 0xFF;
    }

    udp_rx.src_port  = ((uint16_t)udp_hdr[0] << 8) | udp_hdr[1];
    udp_rx.dst_port  = ((uint16_t)udp_hdr[2] << 8) | udp_hdr[3];
    udp_rx.length    = ((uint16_t)udp_hdr[4] << 8) | udp_hdr[5];
    udp_rx.checksum  = ((uint16_t)udp_hdr[6] << 8) | udp_hdr[7];

    // Filter: only accept port 8080
    if (udp_rx.dst_port != UDP_PORT) return;

    // Calculate actual payload length
    uint16_t payload_len = udp_rx.length - UDP_HEADER_BYTES;
    udp_rx.payload_len = payload_len;
    udp_rx.buf_base    = ip_rx.buf_base;   // propagate buffer region to DHCP/echo
    udp_rx.valid = true;
}

//=============================================================================
// UDP TX processing
//=============================================================================
// Called every pass (when the MAC TX is idle). Two send sources:
//
//  1) Echo: when data_received is set (a UDP request was just captured), the
//     reply is built and issued IMMEDIATELY in the same pass — same pattern
//     as the ICMP layer. The reply's destination port = the request's source
//     port (rx_src_port), so a client on an ephemeral port receives it.
//  2) Periodic "HELLO       PERFXLAB" default frame at the TX_PACING_COUNT
//     tick (long-term behaviour only).
//
// The caller clears data_received after this function runs, so a request
// arriving while the MAC TX is busy (this function not called) survives
// until the next pass.
//=============================================================================
// Forward declaration
bool arp_lookup(arp_entry_t *table, ap_uint<32> ip, mac_addr_t &mac);
void arp_send_request(uint32_t *buffer, mac_tx_req_t &tx_req, ap_uint<32> target_ip);

static void udp_tx_process(
    bool          reset_n,
    uint32_t     *buffer,
    mac_tx_req_t &tx_req,
    arp_entry_t  *arp_table,    // ARP table for MAC lookup
    bool          data_received,
    uint16_t      rx_data_len,      // request UDP length (8 + payload)
    uint16_t      rx_ip_total_len,  // request IP total length
    uint16_t      rx_src_port,      // request source port (echo destination)
    ap_uint<32>   rx_src_ip         // request source IP (echo destination)
) {
    static uint32_t time_cnt    = 0;
    static uint16_t tx_data_len = DEFAULT_UDP_LENGTH;
    static uint16_t tx_total    = DEFAULT_IP_TOTAL_LEN;
    static uint32_t tx_ip_id    = 0;
    static bool     arp_pending = false;
    static ap_uint<32> pending_ip = 0;

    if (!reset_n) {
        time_cnt    = 0;
        tx_data_len = DEFAULT_UDP_LENGTH;
        tx_total    = DEFAULT_IP_TOTAL_LEN;
        tx_ip_id    = 0;
        arp_pending = false;
        pending_ip  = 0;
        return;
    }

    // Echo path: reply immediately (do NOT wait for the pacing tick — the
    // tick needs ~6e8 top-level passes which is minutes of wall-clock time).
    bool     want_send = false;
    bool     echo_sent = false;
    uint16_t dst_port  = UDP_PORT;

    if (data_received) {
        tx_data_len = rx_data_len;
        tx_total    = rx_ip_total_len;
        dst_port    = rx_src_port;
        want_send   = true;
        echo_sent   = true;
    }

    // Periodic HELLO path
    time_cnt++;
    if (time_cnt >= TX_PACING_COUNT) {
        time_cnt = 0;
        tx_ip_id++;
        if (!want_send) {
            want_send   = true;
            tx_data_len = DEFAULT_UDP_LENGTH;
            tx_total    = DEFAULT_IP_TOTAL_LEN;
        }
    }

    if (!want_send) return;

    // Echo replies go back to the REQUEST's source IP; the periodic HELLO
    // goes to the fixed default destination (192.168.100.1).
    uint32_t dst_ip = echo_sent ? (uint32_t)rx_src_ip : 0xC0A86401;
    mac_addr_t dst_mac = 0xFFFFFFFFFFFFULL;   // default: broadcast
    bool use_unicast = false;

    // Look up in ARP table
    if (arp_lookup(arp_table, dst_ip, dst_mac)) {
        use_unicast = true;
        arp_pending = false;
    } else {
        // MAC unknown — ARP request only for the fixed HELLO destination
        // (echo misses fall back to broadcast so the reply always goes out)
        if (!echo_sent && !arp_pending) {
            arp_send_request(buffer, tx_req, dst_ip);
            arp_pending = true;
            pending_ip  = dst_ip;
        }
        dst_mac = 0xFFFFFFFFFFFFULL;  // broadcast fallback
    }

    // Build IP+UDP header
    int hdr_base = TX_UDP_BASE;
    uint8_t ipudp_hdr[28];
    ipudp_hdr[0] = 0x45; ipudp_hdr[1] = 0x00;
    ipudp_hdr[2] = (tx_total >> 8) & 0xFF; ipudp_hdr[3] = tx_total & 0xFF;
    ipudp_hdr[4] = (tx_ip_id >> 8) & 0xFF; ipudp_hdr[5] = tx_ip_id & 0xFF;
    ipudp_hdr[6] = 0x40; ipudp_hdr[7] = 0x00;
    ipudp_hdr[8] = 128; ipudp_hdr[9] = IP_PROTO_UDP;
    ipudp_hdr[10] = 0x00; ipudp_hdr[11] = 0x00;
    ipudp_hdr[12] = BOARD_IP_BYTE0; ipudp_hdr[13] = BOARD_IP_BYTE1;
    ipudp_hdr[14] = BOARD_IP_BYTE2; ipudp_hdr[15] = BOARD_IP_BYTE3;
    ipudp_hdr[16] = (dst_ip >> 24) & 0xFF; ipudp_hdr[17] = (dst_ip >> 16) & 0xFF;
    ipudp_hdr[18] = (dst_ip >> 8) & 0xFF;  ipudp_hdr[19] = dst_ip & 0xFF;
    ipudp_hdr[20] = (UDP_PORT >> 8) & 0xFF; ipudp_hdr[21] = UDP_PORT & 0xFF;
    ipudp_hdr[22] = (dst_port >> 8) & 0xFF; ipudp_hdr[23] = dst_port & 0xFF;
    ipudp_hdr[24] = (tx_data_len >> 8) & 0xFF; ipudp_hdr[25] = tx_data_len & 0xFF;
    ipudp_hdr[26] = 0x00; ipudp_hdr[27] = 0x00;

    uint16_t ip_words[10];
    for (int i = 0; i < 10; i++) ip_words[i] = ((uint16_t)ipudp_hdr[i*2] << 8) | ipudp_hdr[i*2+1];
    uint16_t csum = ones_complement_checksum(ip_words, 10);
    ipudp_hdr[10] = (csum >> 8) & 0xFF; ipudp_hdr[11] = csum & 0xFF;

    for (int i = 0; i < 7; i++) {
        buffer[hdr_base + i] = ((uint32_t)ipudp_hdr[i*4]   << 24) |
                               ((uint32_t)ipudp_hdr[i*4+1] << 16) |
                               ((uint32_t)ipudp_hdr[i*4+2] << 8)  |
                               ((uint32_t)ipudp_hdr[i*4+3]);
    }
    if (!echo_sent) {
        buffer[hdr_base + 7] = 0x48454C4C; buffer[hdr_base + 8] = 0x4F202020;
        buffer[hdr_base + 9] = 0x20202020; buffer[hdr_base + 10] = 0x50455246;
        buffer[hdr_base + 11] = 0x584C4142;
    }

    tx_req.dst_mac   = dst_mac;
    tx_req.ethertype = ETHERTYPE_IPV4;
    tx_req.buf_addr  = hdr_base;
    tx_req.buf_len   = IP_HEADER_BYTES + tx_data_len;
    tx_req.request   = true;

    if (arp_pending && use_unicast) {
        arp_pending = false;  // ARP resolved!
    }
    if (echo_sent) {
        tx_data_len = DEFAULT_UDP_LENGTH;
        tx_total    = DEFAULT_IP_TOTAL_LEN;
    }
}
