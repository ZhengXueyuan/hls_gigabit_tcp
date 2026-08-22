//=============================================================================
// layer_ip.cpp — IP (Internet Protocol) layer
//=============================================================================
// Reads IPv4 header from buffer (20 bytes at RX_BUFFER_BASE).
// Validates header checksum, extracts fields, dispatches by protocol.
//=============================================================================

#include "eth_types.h"
#include "eth_utils.h"

//=============================================================================
// IP RX processing
//=============================================================================
// Reads 20-byte IP header from buffer[RX_BUFFER_BASE].
// Returns parsed fields in ip_rx.
// Sets ip_rx.valid = true if header is valid and destined for us.
//=============================================================================
static void ip_rx_process(
    bool          reset_n,
    mac_rx_t     &mac_rx,
    uint32_t     *buffer,
    ip_rx_t      &ip_rx
) {
    ip_rx.valid       = false;
    ip_rx.checksum_ok = false;
    ip_rx.protocol    = 0;
    ip_rx.src_ip      = 0;
    ip_rx.dst_ip      = 0;
    ip_rx.total_len   = 0;
    ip_rx.ttl         = 0;
    ip_rx.id          = 0;
    ip_rx.hdr_checksum = 0;
    ip_rx.buf_base    = 0;

    if (!reset_n) return;
    if (!mac_rx.valid) return;
    if (mac_rx.ethertype != ETHERTYPE_IPV4) return;

    // Read IP header bytes (20 bytes = 5 words) from the staged frame buffer.
    // udp_echo already popped this frame from frame_fifo into frame_buf;
    // frame_buf[0] is the first payload word (start of the IP packet).
    uint8_t hdr[20];
    for (int i = 0; i < 5; i++) {
        uint32_t w = frame_buf[i];
        hdr[i*4 + 0] = (w >> 24) & 0xFF;
        hdr[i*4 + 1] = (w >> 16) & 0xFF;
        hdr[i*4 + 2] = (w >> 8)  & 0xFF;
        hdr[i*4 + 3] = w & 0xFF;
    }

    // Basic validation: version=4, IHL=5
    uint8_t ver_ihl = hdr[0];
    if ((ver_ihl >> 4) != 4) return;       // not IPv4
    if ((ver_ihl & 0xF) != 5) return;      // not 20-byte header

    // Extract fields
    ip_rx.total_len  = ((uint16_t)hdr[2] << 8) | hdr[3];
    ip_rx.id         = ((uint16_t)hdr[4] << 8) | hdr[5];
    ip_rx.ttl        = hdr[8];
    ip_rx.protocol   = hdr[9];
    ip_rx.hdr_checksum = ((uint16_t)hdr[10] << 8) | hdr[11];
    ip_rx.src_ip     = ((uint32_t)hdr[12] << 24) | ((uint32_t)hdr[13] << 16) |
                       ((uint32_t)hdr[14] << 8)  | hdr[15];
    ip_rx.dst_ip     = ((uint32_t)hdr[16] << 24) | ((uint32_t)hdr[17] << 16) |
                       ((uint32_t)hdr[18] << 8)  | hdr[19];

    // Validate checksum
    uint16_t words[10];
    for (int i = 0; i < 10; i++) {
        words[i] = ((uint16_t)hdr[i*2] << 8) | hdr[i*2 + 1];
    }
    uint16_t computed = ones_complement_checksum(words, 10);
    ip_rx.checksum_ok = (computed == 0);

    // Check destination IP
    uint32_t board_ip = (BOARD_IP_BYTE0 << 24) | (BOARD_IP_BYTE1 << 16) |
                        (BOARD_IP_BYTE2 << 8) | BOARD_IP_BYTE3;
    uint32_t broadcast_ip = 0xFFFFFFFF;

    if (ip_rx.dst_ip == board_ip || ip_rx.dst_ip == broadcast_ip) {
        ip_rx.valid = ip_rx.checksum_ok;
        ip_rx.buf_base = mac_rx.buf_base;   // propagate buffer region to next layer
    }
}
