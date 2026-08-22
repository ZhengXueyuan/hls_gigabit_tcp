//=============================================================================
// eth_types.h — Protocol type definitions for layered IP stack
//=============================================================================
// All interface structs and protocol constants used across layers.
//=============================================================================

#ifndef ETH_TYPES_H
#define ETH_TYPES_H

#include <stdint.h>
#include "ap_int.h"
#include "hls_stream.h"

//=============================================================================
// RX frame channel (UG1399: never share a raw array between a concurrent
// producer/consumer — use hls::stream). MAC RX pushes each accepted frame's
// 32-bit payload words into a frame FIFO; udp_echo stages them into frame_buf
// (below) at frame_done and the layers parse frame_buf at 0-based offsets.
// The FIFO itself is a static inside udp_echo (passed to mac_rx by reference).
//=============================================================================

// Per-frame staging buffer: written-then-read within a single pass (never
// shared across concurrent processes), so it carries no race. TX builders
// still use the shared buffer[]. Sized for a full MTU frame (1500B = 375w).
#define FRAME_BUF_WORDS 400
extern uint32_t frame_buf[FRAME_BUF_WORDS];

//=============================================================================
// Protocol constants
//=============================================================================

// EtherType values
#define ETHERTYPE_IPV4  0x0800
#define ETHERTYPE_ARP   0x0806

// VLAN (802.1Q) TPID values
#define TPID_VLAN      0x8100   // 802.1Q single tag
#define TPID_QINQ      0x88A8   // 802.1ad provider bridge (double tag)

// AXI-Stream GMII byte type
struct gmii_byte_t {
    ap_uint<8> data;
    bool       last;   // true = end of frame (replaces dv falling-edge detection)
};

// IP protocol numbers
#define IP_PROTO_ICMP   1
#define IP_PROTO_IGMP   2
#define IP_PROTO_TCP    6
#define IP_PROTO_UDP    17

// ICMP types
#define ICMP_ECHO_REPLY    0
#define ICMP_ECHO_REQUEST  8

// IGMP types (v1 + v2 compatible; v3 not supported)
#define IGMP_QUERY       0x11
#define IGMP_REPORT_V1   0x12   // IGMPv1 Membership Report
#define IGMP_REPORT_V2   0x16   // IGMPv2 Membership Report
#define IGMP_LEAVE       0x17   // IGMPv2 Leave Group

//=============================================================================
// DHCP constants
//=============================================================================
#define DHCP_CLIENT_PORT  68
#define DHCP_SERVER_PORT  67
#define DHCP_OP_REQUEST   1
#define DHCP_OP_REPLY     2
#define DHCP_HTYPE_ETH    1
#define DHCP_HLEN         6
#define DHCP_MAGIC_COOKIE 0x63825363
#define DHCP_MSG_DISCOVER 1
#define DHCP_MSG_OFFER    2
#define DHCP_MSG_REQUEST  3
#define DHCP_MSG_ACK      5
#define DHCP_FLAG_BROADCAST 0x8000
#define DHCP_TIMEOUT      0x1000000   // ~130ms @ 125MHz
#define DHCP_MSG_SIZE     300          // fixed header + options (bytes)

// DHCP FSM states
#define DHCP_IDLE      0
#define DHCP_DISCOVER  1
#define DHCP_WAIT_OFFER 2
#define DHCP_REQUEST   3
#define DHCP_WAIT_ACK  4
#define DHCP_DONE      5
#define DHCP_FAILED    6   // gave up after retries — stays quiet until reset

// Multicast group the board listens to (configurable)
#define BOARD_MCAST_BYTE0  239
#define BOARD_MCAST_BYTE1  0
#define BOARD_MCAST_BYTE2  0
#define BOARD_MCAST_BYTE3  1
// BOARD_MCAST = 239.0.0.1 (local multicast)

// ARP operation codes
#define ARP_REQUEST  1
#define ARP_REPLY    2

// ARP hardware/protocol types
#define ARP_HW_ETHERNET  1
#define ARP_PROTO_IPV4   0x0800

// MAC address lengths
#define MAC_ADDR_LEN   6
#define IP_ADDR_LEN    4

//=============================================================================
// Board identity (configurable)
//=============================================================================
#define BOARD_MAC_BYTE0  0x00
#define BOARD_MAC_BYTE1  0x0A
#define BOARD_MAC_BYTE2  0x35
#define BOARD_MAC_BYTE3  0x01
#define BOARD_MAC_BYTE4  0xFE
#define BOARD_MAC_BYTE5  0xC0
// BOARD_MAC = 00:0A:35:01:FE:C0

#define BOARD_IP_BYTE0  192
#define BOARD_IP_BYTE1  168
#define BOARD_IP_BYTE2  100
#define BOARD_IP_BYTE3  2
// BOARD_IP = 192.168.100.2 (PC NIC = 192.168.100.1/24)

//=============================================================================
// Frame size constants
//=============================================================================
#define MAC_HEADER_BYTES       14   // DstMAC(6) + SrcMAC(6) + EtherType(2)
#define IP_HEADER_BYTES        20
#define UDP_HEADER_BYTES       8
#define CRC_BYTES              4
#define PREAMBLE_SFD_BYTES     8
#define ARP_PAYLOAD_BYTES      28   // HW(2)+Proto(2)+HWsz(1)+Protosz(1)+Op(2)+SHA(6)+SPA(4)+THA(6)+TPA(4)

#define DEFAULT_UDP_PAYLOAD    20   // "HELLO       PERFXLAB" = 20 bytes
#define DEFAULT_UDP_LENGTH     (UDP_HEADER_BYTES + DEFAULT_UDP_PAYLOAD)  // 28
#define DEFAULT_IP_TOTAL_LEN   (IP_HEADER_BYTES + DEFAULT_UDP_LENGTH)    // 48

//=============================================================================
// Buffer partitioning — dual-buffer dual-region layout
//=============================================================================
// Dual-buffer for MAC RX: alternating frames land in BUF_A / BUF_B so that
// MAC RX writing and layer processing never touch the same region.
//
// 2026-08-22: original 512-word layout had BUF_B[160..319] overlapping
// TX_SCRATCH_BASE[256..319] — an ICMP/ARP/IGMP reply would clobber the
// tail of a BUF_B-resident TCP segment (observed as TCP 1608B failure at
// payload offset 880, absolute word 256 = TX_SCRATCH_BASE). Enlarge the
// buffer to 768 words and give each region its own disjoint space:
//
//   BUF_A       [0..159]    160 words (640B) — fits 536B TCP seg + 40B hdrs
//   BUF_B       [160..319]  160 words (640B)
//   TX_SCRATCH  [320..383]   64 words (256B) — ARP/ICMP/IGMP scratch
//   DHCP_FRAME  [384..511]  128 words (512B) — DHCP IP+UDP+msg (~82 words)
//   TX_UDP      [512..767]  256 words (1024B) — UDP/TCP TX frame (576B max)
#define BUFFER_DEPTH        768
#define BUF_A_BASE          0
#define BUF_B_BASE          160
#define BUF_SIZE            160   // 640B — fits max TCP segment (536B + headers)
#define RX_BUFFER_BASE      0
#define RX_BUFFER_SIZE      BUF_SIZE
#define TX_SCRATCH_BASE     320   // ARP/ICMP/IGMP TX frame scratch area
#define TX_SCRATCH_SIZE     64    // 320..383
// TX_UDP_BASE at 512 so a single 536B TCP segment (Windows ignores the
// MSS=460 advert) fits in ONE TX frame: 20 IP + 20 TCP + 536 payload = 576B
// = 144 words. Region 512..768 = 256 words = 1024B (ample margin). Disjoint
// from both RX buffers and the DHCP region, so no mid-send clobbering.
#define TX_UDP_BASE         512   // UDP/TCP TX payload area
#define TX_UDP_SIZE         256   // 512..767

//=============================================================================
// Timing
//=============================================================================
#ifdef __SYNTHESIS__
// RTL: ~5s between HELLO frames @ 125MHz (625,000,000 < 2^32, fits the uint32_t counter)
#define TX_PACING_COUNT  625000000
#else
// csim: keep the legacy fast pacing so the TB's frame-drain helpers run quickly
#define TX_PACING_COUNT  0x00000100
#endif

//=============================================================================
// MAC address type (6 bytes in a 64-bit container)
//=============================================================================
typedef ap_uint<48> mac_addr_t;

//=============================================================================
// AXI-Stream types for GMII interface
//=============================================================================
// gmii_byte_t defined above (struct with data + last flag)
// RX: hls::stream<gmii_byte_t>  — from PHY
// TX: hls::stream<gmii_byte_t>  — to PHY

//=============================================================================
// MAC layer → upper layers: parsed Ethernet frame metadata
//=============================================================================
struct mac_rx_t {
    ap_uint<16> ethertype;      // 0x0800=IPv4, 0x0806=ARP
    mac_addr_t  src_mac;
    mac_addr_t  dst_mac;
    bool        is_broadcast;   // dst MAC == FF:FF:FF:FF:FF:FF
    bool        is_unicast;     // dst MAC == board MAC
    bool        valid;          // frame passed MAC filter
    ap_uint<10> buf_base;       // which buffer region this frame landed in
    ap_uint<10> nwords;         // number of 32-bit payload words pushed to frame_fifo
};

//=============================================================================
// MAC layer → TX request from upper layers
//=============================================================================
struct mac_tx_req_t {
    mac_addr_t  dst_mac;
    ap_uint<16> ethertype;
    ap_uint<10> buf_addr;       // start address in shared buffer (word index)
    ap_uint<16> buf_len;        // bytes to send (not including CRC)
    bool        request;
    bool        insert_vlan;    // insert 802.1Q VLAN tag in TX frame
    ap_uint<16> vlan_tci;       // VLAN TCI value (PCP+DEI+VID)
};

//=============================================================================
// IP layer → transport layers
//=============================================================================
struct ip_rx_t {
    ap_uint<8>  protocol;       // IP protocol number
    ap_uint<8>  ttl;
    ap_uint<32> src_ip;
    ap_uint<32> dst_ip;
    ap_uint<16> total_len;      // IP total length
    ap_uint<16> hdr_checksum;   // received checksum
    ap_uint<16> id;             // IP identification
    bool        checksum_ok;
    bool        valid;
    ap_uint<10> buf_base;       // buffer region for this IP packet
};

//=============================================================================
// ARP table entry
//=============================================================================
struct arp_entry_t {
    ap_uint<32> ip;
    mac_addr_t  mac;
    bool        valid;
};

//=============================================================================
// ARP RX frame (parsed from Ethernet payload)
//=============================================================================
struct arp_rx_t {
    ap_uint<16> hw_type;
    ap_uint<16> proto_type;
    ap_uint<8>  hw_size;
    ap_uint<8>  proto_size;
    ap_uint<16> opcode;         // 1=Request, 2=Reply
    mac_addr_t  sender_mac;
    ap_uint<32> sender_ip;
    mac_addr_t  target_mac;
    ap_uint<32> target_ip;
    bool        valid;
};

//=============================================================================
// ICMP RX info
//=============================================================================
struct icmp_rx_t {
    ap_uint<8>  type;
    ap_uint<8>  code;
    ap_uint<16> checksum;
    ap_uint<16> identifier;
    ap_uint<16> sequence;
    ap_uint<16> data_len;       // ICMP payload length (bytes)
    bool        valid;
};

//=============================================================================
// UDP RX info
//=============================================================================
struct udp_rx_t {
    ap_uint<16> src_port;
    ap_uint<16> dst_port;
    ap_uint<16> length;         // UDP length (header + payload)
    ap_uint<16> checksum;
    ap_uint<16> payload_len;    // actual payload bytes
    bool        valid;
    ap_uint<10> buf_base;       // buffer region for this UDP datagram
};

#endif // ETH_TYPES_H
