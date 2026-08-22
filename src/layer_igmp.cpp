//=============================================================================
// layer_igmp.cpp — IGMPv1/v2 (Internet Group Management Protocol)
//=============================================================================
// Supports IGMPv1 (RFC 1112) and IGMPv2 (RFC 2236).
// IGMPv3 (RFC 3376) is NOT supported — too complex for this FPGA project.
//
// IGMP message format (8 bytes):
//   Type(1) + MaxResp(1) + Checksum(2) + GroupAddr(4)
//
// Version compatibility (per RFC 2236 §4):
//   - v1 Query (MaxResp==0) → respond with v1 Report (0x12)
//   - v2 Query (MaxResp>0)  → respond with v2 Report (0x16)
//
// Supported queries:
//   - General Query (group=0.0.0.0)
//   - Group-Specific Query (group=board multicast address)
//=============================================================================

#include "eth_types.h"
#include "eth_utils.h"

//=============================================================================
// IGMP checksum — standard IP-style 16-bit one's complement
//=============================================================================
static uint16_t igmp_checksum(const uint8_t *msg, int len) {
    uint32_t sum = 0;
    for (int i = 0; i < len - 1; i += 2) {
        sum += ((uint16_t)msg[i] << 8) | msg[i + 1];
    }
    if (len & 1) sum += ((uint16_t)msg[len - 1] << 8);
    while (sum >> 16) sum = (sum & 0xFFFF) + (sum >> 16);
    return (uint16_t)(~sum);
}

//=============================================================================
// IGMP RX processing
//=============================================================================
// IGMP data starts at buffer[RX_BUFFER_BASE + 5] (after 20-byte IP header).
// If Membership Query received → builds Membership Report in TX scratch,
// sets tx_req to send it.
//=============================================================================
static void igmp_rx_process(
    bool          reset_n,
    ip_rx_t      &ip_rx,
    uint32_t     *buffer,
    mac_tx_req_t &tx_req
) {
    if (!reset_n) return;
    if (!ip_rx.valid) return;
    if (ip_rx.protocol != IP_PROTO_IGMP) return;

    // IGMP header at word 5 of the staged frame (only 2 words = 8 bytes)
    int igmp_base = 5;
    uint8_t igmp[8];
    for (int i = 0; i < 2; i++) {
        uint32_t w = frame_buf[igmp_base + i];
        igmp[i*4 + 0] = (w >> 24) & 0xFF;
        igmp[i*4 + 1] = (w >> 16) & 0xFF;
        igmp[i*4 + 2] = (w >> 8)  & 0xFF;
        igmp[i*4 + 3] = w & 0xFF;
    }

    uint8_t  igmp_type  = igmp[0];
    uint8_t  max_resp   = igmp[1];   // 0=v1 router, >0=v2 router
    uint32_t group_addr = ((uint32_t)igmp[4] << 24) | ((uint32_t)igmp[5] << 16) |
                          ((uint32_t)igmp[6] << 8)  | igmp[7];

    uint32_t board_mcast = (BOARD_MCAST_BYTE0 << 24) | (BOARD_MCAST_BYTE1 << 16) |
                           (BOARD_MCAST_BYTE2 << 8)  | BOARD_MCAST_BYTE3;

    // Also handle IGMPv1/v2 Leave messages — no action needed (router processes them)
    // but we can still learn from them if needed.

    // Respond to: General Query (0.0.0.0) or Group-Specific Query (our group)
    bool should_respond = false;
    uint8_t report_type = IGMP_REPORT_V2;
    if (igmp_type == IGMP_QUERY) {
        if (group_addr == 0 || group_addr == board_mcast) {
            should_respond = true;
            // RFC 2236 §4: v1 router sends MaxResp==0, respond with v1 Report
            // v2 router sends MaxResp>0, respond with v2 Report
            report_type = (max_resp == 0) ? IGMP_REPORT_V1 : IGMP_REPORT_V2;
        }
    }

    if (should_respond) {
        // Build IGMP Report message (8 bytes)
        uint8_t report[8];
        report[0] = report_type;         // v1 or v2 Membership Report
        report[1] = 0;                    // max resp = 0
        report[2] = 0; report[3] = 0;    // checksum placeholder
        report[4] = BOARD_MCAST_BYTE0;
        report[5] = BOARD_MCAST_BYTE1;
        report[6] = BOARD_MCAST_BYTE2;
        report[7] = BOARD_MCAST_BYTE3;

        // Compute checksum
        uint16_t csum = igmp_checksum(report, 8);
        report[2] = (csum >> 8) & 0xFF;
        report[3] = csum & 0xFF;

        // Build IP header (20 bytes) + IGMP message (8 bytes) in TX scratch
        int tx_base = TX_SCRATCH_BASE;

        // Write IGMP message (2 words)
        buffer[tx_base + 5] = ((uint32_t)report[0] << 24) | ((uint32_t)report[1] << 16) |
                              ((uint32_t)report[2] << 8)  | report[3];
        buffer[tx_base + 6] = ((uint32_t)report[4] << 24) | ((uint32_t)report[5] << 16) |
                              ((uint32_t)report[6] << 8)  | report[7];

        // Build IP header (5 words at TX_SCRATCH_BASE)
        uint16_t ip_total = IP_HEADER_BYTES + 8;  // 20 + 8 = 28
        uint8_t ip_hdr[20];
        ip_hdr[0] = 0x45; ip_hdr[1] = 0x00;
        ip_hdr[2] = (ip_total >> 8) & 0xFF; ip_hdr[3] = ip_total & 0xFF;
        ip_hdr[4] = 0x00; ip_hdr[5] = 0x00;  // ID=0
        ip_hdr[6] = 0x40; ip_hdr[7] = 0x00;
        ip_hdr[8] = 1;     // TTL=1 (multicast)
        ip_hdr[9] = IP_PROTO_IGMP;
        ip_hdr[10] = 0x00; ip_hdr[11] = 0x00;
        ip_hdr[12] = BOARD_IP_BYTE0; ip_hdr[13] = BOARD_IP_BYTE1;
        ip_hdr[14] = BOARD_IP_BYTE2; ip_hdr[15] = BOARD_IP_BYTE3;
        // Destination: multicast group address
        ip_hdr[16] = BOARD_MCAST_BYTE0; ip_hdr[17] = BOARD_MCAST_BYTE1;
        ip_hdr[18] = BOARD_MCAST_BYTE2; ip_hdr[19] = BOARD_MCAST_BYTE3;

        uint16_t ip_words[10];
        for (int i = 0; i < 10; i++) ip_words[i] = ((uint16_t)ip_hdr[i*2] << 8) | ip_hdr[i*2+1];
        uint16_t ip_csum = ones_complement_checksum(ip_words, 10);
        ip_hdr[10] = (ip_csum >> 8) & 0xFF; ip_hdr[11] = ip_csum & 0xFF;

        for (int i = 0; i < 5; i++) {
            buffer[tx_base + i] = ((uint32_t)ip_hdr[i*4]   << 24) |
                                  ((uint32_t)ip_hdr[i*4+1] << 16) |
                                  ((uint32_t)ip_hdr[i*4+2] << 8)  |
                                  ((uint32_t)ip_hdr[i*4+3]);
        }

        tx_req.dst_mac   = 0xFFFFFFFFFFFFULL;  // broadcast for IGMP report (multicast MAC could be derived)
        tx_req.ethertype = ETHERTYPE_IPV4;
        tx_req.buf_addr  = tx_base;
        tx_req.buf_len   = ip_total;
        tx_req.request   = true;
    }
}
