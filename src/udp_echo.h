//=============================================================================
// udp_echo.h — Type definitions and constants for GMII UDP echo design
//=============================================================================
// Simplified gigabit Ethernet UDP echo:
//   - Hardcoded MAC / IP addresses (no ARP / DHCP)
//   - No UDP checksum (set to 0x0000)
//   - No IP options / fragmentation
//   - Echoes received UDP payload or sends default "HELLO    PERFXLAB" message
//=============================================================================

#ifndef UDP_ECHO_H
#define UDP_ECHO_H

#include <stdint.h>

//=============================================================================
// Board identity
//=============================================================================
#define BOARD_MAC_HI  0x000A3501   // 00:0A:35:01 (bytes 0–3)
#define BOARD_MAC_LO  0xFEC0       // FE:C0 (bytes 4–5)
// This is the expected DESTINATION MAC in received frames

//=============================================================================
// TX frame constants (hardcoded — no dynamic address learning)
//=============================================================================
// Destination MAC: FF:FF:FF:FF:FF:FF (broadcast)
#define TX_DST_MAC_BYTE0  0xFF
#define TX_DST_MAC_BYTE1  0xFF
#define TX_DST_MAC_BYTE2  0xFF
#define TX_DST_MAC_BYTE3  0xFF
#define TX_DST_MAC_BYTE4  0xFF
#define TX_DST_MAC_BYTE5  0xFF

// Source MAC: 8C:EC:4B:5F:3B:DB
#define TX_SRC_MAC_BYTE0  0x8C
#define TX_SRC_MAC_BYTE1  0xEC
#define TX_SRC_MAC_BYTE2  0x4B
#define TX_SRC_MAC_BYTE3  0x5F
#define TX_SRC_MAC_BYTE4  0x3B
#define TX_SRC_MAC_BYTE5  0xDB

// EtherType: IPv4 = 0x0800
#define ETHERTYPE_IPV4_HI  0x08
#define ETHERTYPE_IPV4_LO  0x00

// Source IP: 192.168.0.2
#define TX_SRC_IP   0xC0A80002
// Destination IP: 192.168.0.3
#define TX_DST_IP   0xC0A80003

// UDP ports: both 8080 (0x1F90)
#define TX_SRC_PORT 0x1F90
#define TX_DST_PORT 0x1F90

// IP identification field (increments per packet)
#define TX_IP_ID_INIT   0x0000

// IP header fields
#define TX_IP_VERSION_IHL  0x45   // Version=4, IHL=5 (20 bytes)
#define TX_IP_DSCP_ECN     0x00
#define TX_IP_FLAGS_FRAG   0x4000 // Don't fragment
#define TX_IP_TTL_PROTO    0x80110000 // TTL=128, Protocol=17 (UDP), checksum=0 placeholder

//=============================================================================
// Frame sizes
//=============================================================================
// Default message "HELLO    PERFXLAB" = 20 bytes + 8 bytes padding = 28 bytes
#define DEFAULT_PAYLOAD_BYTES  28
// Static header sizes
#define MAC_HEADER_BYTES       14   // DstMAC(6) + SrcMAC(6) + EtherType(2)
#define IP_HEADER_BYTES        20
#define UDP_HEADER_BYTES       8
#define CRC_BYTES              4
#define PREAMBLE_SFD_BYTES     8    // 7×55 + 1×D5
// Default IP total length: 20 (IP hdr) + 28 (UDP hdr + payload) = 48
#define DEFAULT_IP_TOTAL_LEN   (IP_HEADER_BYTES + DEFAULT_PAYLOAD_BYTES)  // 48
// Min IP total length in bytes
#define IP_HEADER_WORDS        5

//=============================================================================
// Buffer
//=============================================================================
#define BUFFER_DEPTH  512
#define BUFFER_ADDR_BITS  9

//=============================================================================
// Timing
//=============================================================================
// TX pacing: send a frame every ~0x100 cycles of e_rxc (125 MHz)
// 0x100 = 256 cycles ≈ 2.048 µs between frames
#define TX_PACING_COUNT  0x00000100

//=============================================================================
// RX FSM states (matching iprecieve.v)
//=============================================================================
#define RX_IDLE           0
#define RX_SIX_55         1
#define RX_SPD_D5         2
#define RX_MAC            3
#define RX_IP_PROTOCOL    4
#define RX_IP_LAYER       5
#define RX_UDP_LAYER      6
#define RX_DATA           7
#define RX_FINISH         8

//=============================================================================
// TX FSM states (matching ipsend.v)
//=============================================================================
#define TX_IDLE        0
#define TX_START       1
#define TX_MAKE        2
#define TX_SEND55      3
#define TX_SENDMAC     4
#define TX_SENDHEADER  5
#define TX_SENDDATA    6
#define TX_SENDCRC     7

#endif // UDP_ECHO_H
