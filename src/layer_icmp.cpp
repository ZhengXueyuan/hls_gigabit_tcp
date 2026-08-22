//=============================================================================
// layer_icmp.cpp — ICMP (Internet Control Message Protocol) layer
//=============================================================================
// Handles ICMP Echo Request (type 8) → Echo Reply (type 0).
// ICMP payload follows IP header at buffer[RX_BUFFER_BASE + 5].
//
// ICMP Echo Reply construction:
//   - Copy ICMP header from request, change type 8→0
//   - Recompute ICMP checksum (covers type+code+checksum+id+seq+data)
//   - Build IP header for reply
//   - Issue TX request
//=============================================================================

#include "eth_types.h"
#include "eth_utils.h"

// ARP lookup (defined in layer_arp.cpp — same translation unit).
// The arp_entry_t* parameter is unused (tables are file-static in layer_arp.cpp).
bool arp_lookup(arp_entry_t *table, ap_uint<32> ip, mac_addr_t &mac);

//=============================================================================
// ICMP checksum computation
//=============================================================================
// ICMP checksum covers: type(1) + code(1) + checksum(2) + rest_of_header(4) + data(N)
// Returns 16-bit one's complement checksum ready to insert.
//=============================================================================
static uint16_t icmp_checksum(const uint8_t *buf, uint16_t total_len) {
    // Build array of uint16_t words (pad with 0 if odd length)
    uint32_t sum = 0;
    for (int i = 0; i < total_len - 1; i += 2) {
        sum += ((uint16_t)buf[i] << 8) | buf[i + 1];
    }
    if (total_len & 1) {
        sum += ((uint16_t)buf[total_len - 1] << 8);  // last byte padded
    }
    while (sum >> 16) { sum = (sum & 0xFFFF) + (sum >> 16); }
    return (uint16_t)(~sum);
}

//=============================================================================
// ICMP RX processing
//=============================================================================
// ICMP data starts at buffer[RX_BUFFER_BASE + 5] (5 words = 20 bytes of IP header).
// Returns icmp_rx with parsed fields.
// If Echo Request → builds Echo Reply in TX scratch and sets tx_req.
//=============================================================================
static void icmp_rx_process(
    bool          reset_n,
    ip_rx_t      &ip_rx,
    uint32_t     *buffer,
    mac_tx_req_t &tx_req
) {
    if (!reset_n) return;
    if (!ip_rx.valid) return;
    if (ip_rx.protocol != IP_PROTO_ICMP) return;

    // ICMP header starts after 20-byte IP header (word 5 of the staged frame)
    int icmp_base = 5;

    // Read first 8 bytes of ICMP header
    uint8_t icmp_hdr[8];
    for (int i = 0; i < 2; i++) {
        uint32_t w = frame_buf[icmp_base + i];
        icmp_hdr[i*4 + 0] = (w >> 24) & 0xFF;
        icmp_hdr[i*4 + 1] = (w >> 16) & 0xFF;
        icmp_hdr[i*4 + 2] = (w >> 8)  & 0xFF;
        icmp_hdr[i*4 + 3] = w & 0xFF;
    }

    uint8_t  icmp_type = icmp_hdr[0];
    uint8_t  icmp_code = icmp_hdr[1];
    // uint16_t icmp_rx_csum = ((uint16_t)icmp_hdr[2] << 8) | icmp_hdr[3];
    uint16_t icmp_id   = ((uint16_t)icmp_hdr[4] << 8) | icmp_hdr[5];
    uint16_t icmp_seq  = ((uint16_t)icmp_hdr[6] << 8) | icmp_hdr[7];

    // ICMP data length = IP total_len - IP header(20)
    uint16_t icmp_total_len = ip_rx.total_len - IP_HEADER_BYTES;

    if (icmp_type == ICMP_ECHO_REQUEST && icmp_code == 0) {
        // Build Echo Reply: copy ICMP payload, change type to 0, recompute checksum

        // Copy full ICMP message (header + data) to TX scratch
        int tx_base = TX_SCRATCH_BASE;
        int icmp_words = (icmp_total_len + 3) >> 2;  // round up to words

        for (int i = 0; i < icmp_words; i++) {
            buffer[tx_base + i] = frame_buf[icmp_base + i];
        }

        // Modify type: 8 → 0 (in place, word 0 of ICMP header)
        uint32_t w0 = frame_buf[icmp_base];
        w0 = (w0 & 0x00FFFFFF) | (ICMP_ECHO_REPLY << 24);  // byte 0 = new type
        buffer[tx_base] = w0;

        // Clear checksum field (bytes 2-3 of ICMP header)
        buffer[tx_base] &= 0xFFFF0000;  // FIX 2026-08-18: clear BOTH checksum
                                      // bytes (0xFFFF00FF only cleared byte 2;
                                      // the request's checksum low byte leaked
                                      // into the sum -> wrong ICMP checksum
                                      // -> Windows dropped every echo reply).

        // Recompute ICMP checksum over (header + data)
        // Build a byte array of the ICMP message for checksum computation
        uint8_t csum_buf[256];  // enough for any ICMP message
        for (int i = 0; i < icmp_words; i++) {
            uint32_t w = buffer[tx_base + i];
            csum_buf[i*4 + 0] = (w >> 24) & 0xFF;
            csum_buf[i*4 + 1] = (w >> 16) & 0xFF;
            csum_buf[i*4 + 2] = (w >> 8)  & 0xFF;
            csum_buf[i*4 + 3] = w & 0xFF;
        }
        uint16_t new_csum = icmp_checksum(csum_buf, icmp_total_len);

        // Insert new checksum
        uint32_t w0_new = buffer[tx_base];
        w0_new = (w0_new & 0xFFFF0000) | new_csum;
        buffer[tx_base] = w0_new;

        // Build IP header for the reply
        // IP header (5 words) placed before ICMP data at TX scratch
        int ip_hdr_base = TX_SCRATCH_BASE;  // IP header goes here
        // ICMP data starts after IP header
        // Actually, we need the IP header at the FRONT, then ICMP data after
        // Shift ICMP data forward by 5 words
        for (int i = icmp_words - 1; i >= 0; i--) {
            buffer[TX_SCRATCH_BASE + 5 + i] = buffer[TX_SCRATCH_BASE + i];
        }

        // Build IP header (20 bytes = 5 words)
        uint16_t ip_total = IP_HEADER_BYTES + icmp_total_len;
        uint8_t ip_hdr[20];
        ip_hdr[0] = 0x45;  // Version=4, IHL=5
        ip_hdr[1] = 0x00;  // DSCP+ECN
        ip_hdr[2] = (ip_total >> 8) & 0xFF;
        ip_hdr[3] = ip_total & 0xFF;
        ip_hdr[4] = 0x00; ip_hdr[5] = 0x00;  // ID (0 for echo reply)
        ip_hdr[6] = 0x40; ip_hdr[7] = 0x00;  // Flags+Fragment
        ip_hdr[8] = 128;   // TTL
        ip_hdr[9] = IP_PROTO_ICMP;
        ip_hdr[10] = 0x00; ip_hdr[11] = 0x00; // checksum placeholder
        // src = board IP
        ip_hdr[12] = BOARD_IP_BYTE0; ip_hdr[13] = BOARD_IP_BYTE1;
        ip_hdr[14] = BOARD_IP_BYTE2; ip_hdr[15] = BOARD_IP_BYTE3;
        // dst = sender's IP (from IP layer)
        ip_hdr[16] = (ip_rx.src_ip >> 24) & 0xFF;
        ip_hdr[17] = (ip_rx.src_ip >> 16) & 0xFF;
        ip_hdr[18] = (ip_rx.src_ip >> 8)  & 0xFF;
        ip_hdr[19] = ip_rx.src_ip & 0xFF;

        // Compute IP checksum
        uint16_t ip_words[10];
        for (int i = 0; i < 10; i++) {
            ip_words[i] = ((uint16_t)ip_hdr[i*2] << 8) | ip_hdr[i*2 + 1];
        }
        uint16_t ip_csum = ones_complement_checksum(ip_words, 10);
        ip_hdr[10] = (ip_csum >> 8) & 0xFF;
        ip_hdr[11] = ip_csum & 0xFF;

        // Write IP header to buffer
        for (int i = 0; i < 5; i++) {
            buffer[TX_SCRATCH_BASE + i] =
                ((uint32_t)ip_hdr[i*4] << 24) | ((uint32_t)ip_hdr[i*4+1] << 16) |
                ((uint32_t)ip_hdr[i*4+2] << 8) | ip_hdr[i*4+3];
        }

        uint16_t total_buf_len = IP_HEADER_BYTES + icmp_total_len;

        // Issue TX request
        // The reply must go to the sender's MAC. On a direct link the sender
        // ARPed for us (or was learnt from any ARP frame), so resolve its MAC
        // from the ARP cache by source IP. Fallback: broadcast if unknown.
        mac_addr_t reply_mac = 0xFFFFFFFFFFFFULL;
        if (arp_lookup(NULL, ip_rx.src_ip, reply_mac)) {
            // unicast reply to sender
        }
        tx_req.dst_mac   = reply_mac;
        tx_req.ethertype = ETHERTYPE_IPV4;
        tx_req.buf_addr  = TX_SCRATCH_BASE;
        tx_req.buf_len   = total_buf_len;
        tx_req.request   = true;
    }
}
