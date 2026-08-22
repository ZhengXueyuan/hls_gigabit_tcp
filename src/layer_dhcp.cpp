//=============================================================================
// layer_dhcp.cpp — DHCP Client (RFC 2131)
//=============================================================================
// Implements DHCP DORA sequence:
//   DISCOVER → OFFER → REQUEST → ACK
//
// Uses UDP ports 67(server)/68(client). Message buffer at TX_SCRATCH_BASE.
// On completion, updates board IP from DHCP ACK.
//=============================================================================

#include "eth_types.h"
#include "eth_utils.h"

// DHCP TX frame layout in the shared buffer (contiguous, 82 words):
//   IPv4 header (5 words) + UDP header (2 words) + DHCP message (75 words)
// 2026-08-22: with the enlarged 768-word buffer, DHCP gets its own disjoint
// 128-word region at 384..511 (was TX_SCRATCH_BASE+32 = 288, which
// overlapped BUF_B after the dual-buffer rework).
#define DHCP_BUF_WORDS   75
#define DHCP_FRAME_BASE  384                          // dedicated DHCP region
#define DHCP_BUF_BASE    (DHCP_FRAME_BASE + 7)        // DHCP message follows IP+UDP headers
// DHCP_RX_BASE: replaced by udp_rx.buf_base + 7 inside dhcp_rx_process so the
// DHCP message is read from the buffer region the frame actually landed in
// (dual-buffer BUF_A/BUF_B alternation driven by MAC RX).

//=============================================================================
// Write DHCP fixed header to buffer
//=============================================================================
static void dhcp_build_header(uint32_t *buf, uint8_t op, uint32_t xid,
                               uint8_t *chaddr, uint32_t ciaddr) {
    // Clear buffer
    for (int i = 0; i < DHCP_BUF_WORDS; i++) buf[DHCP_BUF_BASE + i] = 0;

    buf[DHCP_BUF_BASE + 0] = ((uint32_t)op << 24) | ((uint32_t)DHCP_HTYPE_ETH << 16) |
                              ((uint32_t)DHCP_HLEN << 8);  // op, htype, hlen, hops=0
    buf[DHCP_BUF_BASE + 1] = xid;
    buf[DHCP_BUF_BASE + 2] = 0;  // secs=0, flags=0
    buf[DHCP_BUF_BASE + 2] |= ((uint32_t)DHCP_FLAG_BROADCAST) << 16;
    buf[DHCP_BUF_BASE + 3] = ciaddr;
    // yiaddr, siaddr, giaddr = 0
    // chaddr (16 bytes, only 6 used)
    buf[DHCP_BUF_BASE + 7] = ((uint32_t)chaddr[0] << 24) | ((uint32_t)chaddr[1] << 16) |
                              ((uint32_t)chaddr[2] << 8)  | chaddr[3];
    buf[DHCP_BUF_BASE + 8] = ((uint32_t)chaddr[4] << 24) | ((uint32_t)chaddr[5] << 16);
    // Magic cookie
    buf[DHCP_BUF_BASE + 59] = DHCP_MAGIC_COOKIE;
}

//=============================================================================
// Build IPv4 + UDP headers for a DHCP frame (7 words at DHCP_FRAME_BASE)
// src_ip = 0.0.0.0 for DISCOVER/REQUEST (client has no IP yet)
//=============================================================================
static void dhcp_build_headers(uint32_t *buf, uint16_t udp_len,
                               uint32_t src_ip, uint32_t dst_ip) {
    uint8_t ip[20];
    ip[0] = 0x45; ip[1] = 0x00;                        // ver=4, IHL=5
    ip[2] = (uint8_t)((IP_HEADER_BYTES + udp_len) >> 8);
    ip[3] = (uint8_t)(IP_HEADER_BYTES + udp_len);      // total length
    ip[4] = 0; ip[5] = 0;                              // ID
    ip[6] = 0x40; ip[7] = 0x00;                        // DF, frag=0
    ip[8] = 64; ip[9] = IP_PROTO_UDP;                  // TTL, protocol
    ip[10] = 0; ip[11] = 0;                            // checksum (computed below)
    ip[12] = (uint8_t)(src_ip >> 24); ip[13] = (uint8_t)(src_ip >> 16);
    ip[14] = (uint8_t)(src_ip >> 8);  ip[15] = (uint8_t)src_ip;
    ip[16] = (uint8_t)(dst_ip >> 24); ip[17] = (uint8_t)(dst_ip >> 16);
    ip[18] = (uint8_t)(dst_ip >> 8);  ip[19] = (uint8_t)dst_ip;

    uint16_t ip_words[10];
    for (int i = 0; i < 10; i++) ip_words[i] = ((uint16_t)ip[i*2] << 8) | ip[i*2+1];
    uint16_t csum = ones_complement_checksum(ip_words, 10);
    ip[10] = (uint8_t)(csum >> 8); ip[11] = (uint8_t)csum;

    uint8_t udp[8];
    udp[0] = (uint8_t)(DHCP_CLIENT_PORT >> 8); udp[1] = (uint8_t)DHCP_CLIENT_PORT;
    udp[2] = (uint8_t)(DHCP_SERVER_PORT >> 8); udp[3] = (uint8_t)DHCP_SERVER_PORT;
    udp[4] = (uint8_t)(udp_len >> 8);          udp[5] = (uint8_t)udp_len;
    udp[6] = 0; udp[7] = 0;                    // UDP checksum = 0 (not required)

    for (int i = 0; i < 5; i++) {
        buf[DHCP_FRAME_BASE + i] = ((uint32_t)ip[i*4]  << 24) | ((uint32_t)ip[i*4+1] << 16) |
                                   ((uint32_t)ip[i*4+2] << 8)  | ip[i*4+3];
    }
    for (int i = 0; i < 2; i++) {
        buf[DHCP_FRAME_BASE + 5 + i] = ((uint32_t)udp[i*4]  << 24) | ((uint32_t)udp[i*4+1] << 16) |
                                       ((uint32_t)udp[i*4+2] << 8)  | udp[i*4+3];
    }
}

//=============================================================================
// Write a single byte to buffer at a byte offset (from DHCP_BUF_BASE)
//=============================================================================
static void dhcp_write_byte(uint32_t *buf, int byte_off, uint8_t val) {
    int wi = DHCP_BUF_BASE + (byte_off >> 2);
    int bi = byte_off & 0x3;
    uint32_t mask = ~(((uint32_t)0xFF) << ((3 - bi) * 8));
    uint32_t v   = ((uint32_t)val) << ((3 - bi) * 8);
    buf[wi] = (buf[wi] & mask) | v;
}

//=============================================================================
// Read a single byte from buffer at a byte offset relative to a message base
//=============================================================================
static uint8_t dhcp_read_byte(uint32_t *buf, int base, int byte_off) {
    int wi = base + (byte_off >> 2);
    int bi = byte_off & 0x3;
    return (buf[wi] >> ((3 - bi) * 8)) & 0xFF;
}

//=============================================================================
// Write a fixed-size option (code + len + data) to buffer at byte_off
//=============================================================================
static void dhcp_write_opt(uint32_t *buf, int &off, uint8_t code, uint8_t len,
                           uint8_t d0, uint8_t d1, uint8_t d2, uint8_t d3) {
    dhcp_write_byte(buf, off++, code);
    dhcp_write_byte(buf, off++, len);
    if (len > 0) dhcp_write_byte(buf, off++, d0);
    if (len > 1) dhcp_write_byte(buf, off++, d1);
    if (len > 2) dhcp_write_byte(buf, off++, d2);
    if (len > 3) dhcp_write_byte(buf, off++, d3);
}

//=============================================================================
// Read DHCP option: scan for <code>, return its length, copy up to 4 bytes
//=============================================================================
static uint8_t dhcp_read_opt(uint32_t *buf, int base, int msg_bytes, uint8_t target, uint8_t *out) {
    int off = 240;
    while (off < msg_bytes - 1) {
        uint8_t c = dhcp_read_byte(buf, base, off);
        if (c == 255) break;
        if (c == 0) { off++; continue; }
        uint8_t l = dhcp_read_byte(buf, base, off + 1);
        if (c == target && l <= 4) {
            for (int i = 0; i < l; i++) out[i] = dhcp_read_byte(buf, base, off + 2 + i);
            return l;
        }
        off += 2 + l;
    }
    return 0;
}

//=============================================================================
// DHCP RX processing — checks for DHCP Offer/ACK on UDP port 68
//=============================================================================
static void dhcp_rx_process(
    bool          reset_n,
    udp_rx_t     &udp_rx,
    uint32_t     *buffer,
    uint8_t      &dhcp_state,
    uint32_t     &xid,
    uint32_t     &offered_ip,
    uint32_t     &server_ip,
    uint32_t     &dhcp_timer,
    bool         &dhcp_done
) {
    if (!reset_n) return;
    if (!udp_rx.valid) return;
    if (udp_rx.dst_port != DHCP_CLIENT_PORT) return;

    // Read DHCP message type from options (message is in the staged frame
    // buffer, right after the 20-byte IP header + 8-byte UDP header = word 7).
    int rx_base = 7;
    uint8_t msg_type = 0;
    dhcp_read_opt(frame_buf, rx_base, udp_rx.payload_len, 53, &msg_type);

    if (dhcp_state == DHCP_WAIT_OFFER && msg_type == DHCP_MSG_OFFER) {
        offered_ip = frame_buf[rx_base + 4];  // yiaddr at word offset 4
        uint8_t srv[4];
        if (dhcp_read_opt(frame_buf, rx_base, udp_rx.payload_len, 54, srv)) {
            server_ip = ((uint32_t)srv[0]<<24)|((uint32_t)srv[1]<<16)|((uint32_t)srv[2]<<8)|srv[3];
        }
        dhcp_state = DHCP_REQUEST;
    } else if (dhcp_state == DHCP_WAIT_ACK && msg_type == DHCP_MSG_ACK) {
        dhcp_done = true;
        dhcp_state = DHCP_DONE;
    }
}

//=============================================================================
// DHCP TX processing — state machine for DORA sequence
//=============================================================================
static void dhcp_tx_process(
    bool          reset_n,
    uint32_t     *buffer,
    mac_tx_req_t &tx_req,
    bool          start,          // trigger DHCP start
    uint8_t      &dhcp_state,
    uint32_t     &xid,
    uint32_t     &offered_ip,
    uint32_t     &server_ip,
    uint32_t     &dhcp_timer
) {
    static uint32_t retry_cnt = 0;

    if (!reset_n) {
        dhcp_state = DHCP_IDLE;
        xid        = 0x12345678;
        offered_ip = 0;
        server_ip  = 0;
        dhcp_timer = 0;
        retry_cnt  = 0;
        return;
    }

    // Increment timer
    if (dhcp_state != DHCP_IDLE && dhcp_state != DHCP_DONE &&
        dhcp_state != DHCP_FAILED) {
        dhcp_timer++;
    }

    // Start DHCP
    if (start && dhcp_state == DHCP_IDLE) {
        dhcp_state = DHCP_DISCOVER;
        dhcp_timer = 0;
        retry_cnt  = 0;
        xid        = 0x12345678 + ((dhcp_timer >> 8) & 0xFF); // semi-random
    }

    // Timeout: retry or give up
    bool timeout = (dhcp_timer >= DHCP_TIMEOUT);
    if (timeout && (dhcp_state == DHCP_WAIT_OFFER || dhcp_state == DHCP_WAIT_ACK)) {
        if (retry_cnt < 3) {
            retry_cnt++;
            dhcp_state = (dhcp_state == DHCP_WAIT_OFFER) ? DHCP_DISCOVER : DHCP_REQUEST;
            dhcp_timer = 0;
        } else {
            // Give up for good: DHCP_FAILED is never re-triggered by the
            // (still asserted) start flag, so the DISCOVER flood stops.
            dhcp_state = DHCP_FAILED;
            retry_cnt  = 0;
        }
        return;
    }

    // Build and send messages
    uint8_t chaddr[6] = {BOARD_MAC_BYTE0, BOARD_MAC_BYTE1, BOARD_MAC_BYTE2,
                          BOARD_MAC_BYTE3, BOARD_MAC_BYTE4, BOARD_MAC_BYTE5};

    if (dhcp_state == DHCP_DISCOVER) {
        dhcp_build_header(buffer, DHCP_OP_REQUEST, xid, chaddr, 0);
        int off = 240;
        dhcp_write_opt(buffer, off, 53, 1, DHCP_MSG_DISCOVER, 0,0,0);
        dhcp_write_opt(buffer, off, 55, 4, 1,3,6,15);  // subnet, router, DNS
        dhcp_write_opt(buffer, off, 255, 0, 0,0,0,0);  // end

        // Build IPv4 + UDP headers in front of the message, and start the
        // frame at the IP header (the old code pointed past the message to
        // the UDP header only — the NIC dropped the malformed frame)
        dhcp_build_headers(buffer, 8 + DHCP_MSG_SIZE, 0, 0xFFFFFFFF);

        tx_req.dst_mac   = 0xFFFFFFFFFFFFULL;
        tx_req.ethertype = ETHERTYPE_IPV4;
        tx_req.buf_addr  = DHCP_FRAME_BASE;
        tx_req.buf_len   = IP_HEADER_BYTES + 8 + DHCP_MSG_SIZE;
        tx_req.request   = true;
        dhcp_state = DHCP_WAIT_OFFER;
        dhcp_timer = 0;

    } else if (dhcp_state == DHCP_REQUEST) {
        dhcp_build_header(buffer, DHCP_OP_REQUEST, xid, chaddr, 0);
        int off = 240;
        dhcp_write_opt(buffer, off, 53, 1, DHCP_MSG_REQUEST, 0,0,0);
        dhcp_write_opt(buffer, off, 50, 4, (uint8_t)(offered_ip>>24), (uint8_t)(offered_ip>>16),
                       (uint8_t)(offered_ip>>8), (uint8_t)offered_ip);
        dhcp_write_opt(buffer, off, 54, 4, (uint8_t)(server_ip>>24), (uint8_t)(server_ip>>16),
                       (uint8_t)(server_ip>>8), (uint8_t)server_ip);
        dhcp_write_opt(buffer, off, 255, 0, 0,0,0,0);

        dhcp_build_headers(buffer, 8 + DHCP_MSG_SIZE, 0, 0xFFFFFFFF);

        tx_req.dst_mac   = 0xFFFFFFFFFFFFULL;
        tx_req.ethertype = ETHERTYPE_IPV4;
        tx_req.buf_addr  = DHCP_FRAME_BASE;
        tx_req.buf_len   = IP_HEADER_BYTES + 8 + DHCP_MSG_SIZE;
        tx_req.request   = true;
        dhcp_state = DHCP_WAIT_ACK;
        dhcp_timer = 0;
    }
}
