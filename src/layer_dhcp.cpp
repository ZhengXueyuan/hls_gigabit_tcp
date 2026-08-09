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

// DHCP message buffer: 75 words (300 bytes) in TX scratch area
#define DHCP_BUF_WORDS  75
#define DHCP_BUF_BASE   (TX_SCRATCH_BASE)

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
// Read a single byte from buffer at a byte offset
//=============================================================================
static uint8_t dhcp_read_byte(uint32_t *buf, int byte_off) {
    int wi = DHCP_BUF_BASE + (byte_off >> 2);
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
static uint8_t dhcp_read_opt(uint32_t *buf, int msg_bytes, uint8_t target, uint8_t *out) {
    int off = 240;
    while (off < msg_bytes - 1) {
        uint8_t c = dhcp_read_byte(buf, off);
        if (c == 255) break;
        if (c == 0) { off++; continue; }
        uint8_t l = dhcp_read_byte(buf, off + 1);
        if (c == target && l <= 4) {
            for (int i = 0; i < l; i++) out[i] = dhcp_read_byte(buf, off + 2 + i);
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

    // Read DHCP message type from options
    uint8_t msg_type = 0;
    dhcp_read_opt(buffer, udp_rx.payload_len, 53, &msg_type);

    if (dhcp_state == DHCP_WAIT_OFFER && msg_type == DHCP_MSG_OFFER) {
        offered_ip = buffer[DHCP_BUF_BASE + 4];  // yiaddr at word offset 4
        uint8_t srv[4];
        if (dhcp_read_opt(buffer, udp_rx.payload_len, 54, srv)) {
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
    if (dhcp_state != DHCP_IDLE && dhcp_state != DHCP_DONE) {
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
            dhcp_state = DHCP_IDLE;  // give up
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

        // Build UDP header for DHCP Discover (broadcast)
        int hdr_base = TX_SCRATCH_BASE + DHCP_BUF_WORDS;
        uint8_t udp_hdr[8];
        udp_hdr[0] = (DHCP_CLIENT_PORT >> 8) & 0xFF;
        udp_hdr[1] = DHCP_CLIENT_PORT & 0xFF;
        udp_hdr[2] = (DHCP_SERVER_PORT >> 8) & 0xFF;
        udp_hdr[3] = DHCP_SERVER_PORT & 0xFF;
        uint16_t udp_len = 8 + DHCP_MSG_SIZE;
        udp_hdr[4] = (udp_len >> 8) & 0xFF; udp_hdr[5] = udp_len & 0xFF;
        udp_hdr[6] = 0; udp_hdr[7] = 0;
        for (int i = 0; i < 2; i++)
            buffer[hdr_base + i] = ((uint32_t)udp_hdr[i*4]<<24)|((uint32_t)udp_hdr[i*4+1]<<16)|
                                   ((uint32_t)udp_hdr[i*4+2]<<8)|udp_hdr[i*4+3];

        tx_req.dst_mac   = 0xFFFFFFFFFFFFULL;
        tx_req.ethertype = ETHERTYPE_IPV4;
        tx_req.buf_addr  = hdr_base;
        tx_req.buf_len   = 8 + DHCP_MSG_SIZE;
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

        int hdr_base = TX_SCRATCH_BASE + DHCP_BUF_WORDS;
        uint8_t udp_hdr[8];
        udp_hdr[0] = (DHCP_CLIENT_PORT >> 8) & 0xFF; udp_hdr[1] = DHCP_CLIENT_PORT & 0xFF;
        udp_hdr[2] = (DHCP_SERVER_PORT >> 8) & 0xFF; udp_hdr[3] = DHCP_SERVER_PORT & 0xFF;
        uint16_t udp_len = 8 + DHCP_MSG_SIZE; udp_hdr[4] = (udp_len>>8)&0xFF; udp_hdr[5] = udp_len&0xFF;
        udp_hdr[6] = 0; udp_hdr[7] = 0;
        for (int i = 0; i < 2; i++)
            buffer[hdr_base + i] = ((uint32_t)udp_hdr[i*4]<<24)|((uint32_t)udp_hdr[i*4+1]<<16)|
                                   ((uint32_t)udp_hdr[i*4+2]<<8)|udp_hdr[i*4+3];

        tx_req.dst_mac   = 0xFFFFFFFFFFFFULL;
        tx_req.ethertype = ETHERTYPE_IPV4;
        tx_req.buf_addr  = hdr_base;
        tx_req.buf_len   = 8 + DHCP_MSG_SIZE;
        tx_req.request   = true;
        dhcp_state = DHCP_WAIT_ACK;
        dhcp_timer = 0;
    }
}
