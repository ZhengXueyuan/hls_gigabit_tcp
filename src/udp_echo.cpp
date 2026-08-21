//=============================================================================
// udp_echo.cpp — Top-level HLS module (Phase 3 — AXI-Stream + VLAN)
//=============================================================================
// AXI-Stream interfaces:
//   RX: hls::stream<gmii_byte_t>  (data + last flag)
//   TX: hls::stream<gmii_byte_t>  (data + last flag)
//
// Internal layers communicate via struct references (unchanged from Phase 2).
// VLAN tag detection (802.1Q/802.1ad) in layer_mac.cpp.
//=============================================================================

#include "eth_types.h"
#include "eth_utils.h"
#include "layer_mac.cpp"
#include "layer_arp.cpp"
#include "layer_ip.cpp"
#include "layer_icmp.cpp"
#include "layer_igmp.cpp"
#include "layer_dhcp.cpp"
#include "layer_udp.cpp"
#include "layer_tcp.cpp"
#include "layer_stats.cpp"

void udp_echo(
    bool                      reset_n,
    hls::stream<gmii_byte_t> &rx_stream,
    hls::stream<gmii_byte_t> &tx_stream,
    hls::stream<gmii_byte_t> &msg_stream,    // debug messages → UART IP
    bool                     &led_d0,        // LED D0 (M16)
    bool                     &led_d1,        // LED D1 (N16)
    bool                     &led_d2,        // LED D2 (P15)
    bool                     &led_d3         // LED D3 (P16)
) {
    #pragma HLS INTERFACE ap_none port=reset_n
    #pragma HLS INTERFACE axis port=rx_stream
    #pragma HLS INTERFACE axis port=tx_stream
    #pragma HLS INTERFACE axis port=msg_stream
    #pragma HLS INTERFACE ap_none port=led_d0
    #pragma HLS INTERFACE ap_none port=led_d1
    #pragma HLS INTERFACE ap_none port=led_d2
    #pragma HLS INTERFACE ap_none port=led_d3
    #pragma HLS INTERFACE ap_ctrl_none port=return

    // Shared resources
    static uint32_t    buffer[BUFFER_DEPTH];
    #pragma HLS RESOURCE variable=buffer core=RAM_2P_BRAM

    // TX request from upper layers to MAC TX
    static mac_tx_req_t tx_req;
    #pragma HLS RESET variable=tx_req

    mac_rx_t mac_rx;
    ip_rx_t  ip_rx;
    udp_rx_t udp_rx;

    static bool     data_received = false;
    static uint16_t rx_udp_len    = 0;
    static uint16_t rx_ip_len     = 0;
    static uint16_t rx_src_port   = 0;
    static ap_uint<32> rx_src_ip  = 0;
    static bool     init_done     = false;

    // FIX 2026-08-22: buffer[39] shadow for TCP multi-segment debug.
    // MAC RX writes to buffer[39]; we save the value here and compare
    // when TCP reads it. Mismatch → buf39_err counter incremented.
    static uint32_t buf39_shadow  = 0;
    static uint16_t buf39_err_cnt = 0;

    // DHCP state (Phase 5)
    static uint8_t  dhcp_state   = DHCP_IDLE;
    static uint32_t dhcp_xid     = 0;
    static uint32_t dhcp_offered = 0;
    static uint32_t dhcp_server  = 0;
    static uint32_t dhcp_timer   = 0;
    static bool     dhcp_start   = false;
    static uint32_t dhcp_delay   = 0;

    //=====================================================================
    // Reset
    //=====================================================================
    if (!reset_n) {
        tx_req.request = false;
        data_received  = false;
        rx_udp_len     = 0;
        rx_ip_len      = 0;
        rx_src_port    = 0;
        rx_src_ip      = 0;
        init_done      = false;
        dhcp_state     = DHCP_IDLE;
        dhcp_xid       = 0;
        dhcp_offered   = 0;
        dhcp_server    = 0;
        dhcp_timer     = 0;
        dhcp_start     = false;
        dhcp_delay     = 0;
    } else {
        // One-time init
        if (!init_done) {
            buffer[TX_UDP_BASE + 7] = 0x48454C4C;
            buffer[TX_UDP_BASE + 8] = 0x4F202020;
            buffer[TX_UDP_BASE + 9] = 0x20202020;
            buffer[TX_UDP_BASE + 10] = 0x50455246;
            buffer[TX_UDP_BASE + 11] = 0x584C4142;
            init_done = true;
        }

        // DHCP start delay (~1 second after init)
        if (!dhcp_start && dhcp_state == DHCP_IDLE) {
            dhcp_delay++;
            if (dhcp_delay > 100000000) { dhcp_start = true; dhcp_delay = 0; }
        }
    }

    // Always call layers (they handle reset internally)
    bool mac_tx_busy = false;
    mac_rx_process(reset_n, rx_stream, buffer, mac_rx);
    mac_tx_process(reset_n, tx_req, buffer, tx_stream, mac_tx_busy);

    // FIX 2026-08-22: save buffer[39] shadow after MAC RX write, compare
    // before TCP read. If they differ, the BRAM read returned wrong data.
    if (mac_rx.valid) {
        buf39_shadow = buffer[39];
    }

    ip_rx.valid = false;
    udp_rx.valid = false;

    if (mac_rx.valid) {
        if (mac_rx.ethertype == ETHERTYPE_ARP) {
            arp_rx_process(reset_n, mac_rx, buffer, tx_req, NULL);
        } else if (mac_rx.ethertype == ETHERTYPE_IPV4) {
            ip_rx_process(reset_n, mac_rx, buffer, ip_rx);
            if (ip_rx.valid) {
                if (ip_rx.protocol == IP_PROTO_ICMP) {
                    icmp_rx_process(reset_n, ip_rx, buffer, tx_req);
                } else if (ip_rx.protocol == IP_PROTO_IGMP) {
                    igmp_rx_process(reset_n, ip_rx, buffer, tx_req);
                } else if (ip_rx.protocol == IP_PROTO_TCP) {
                    // FIX 2026-08-22: compare buffer[39] with shadow
                    if (buffer[39] != buf39_shadow) {
                        buf39_err_cnt++;
                    }
                    tcp_rx_process(reset_n, ip_rx, buffer, tx_req, mac_tx_busy);
                } else if (ip_rx.protocol == IP_PROTO_UDP) {
                    udp_rx_process(reset_n, ip_rx, buffer, udp_rx);
                    if (udp_rx.valid) {
                        // Check DHCP port first
                        if (udp_rx.dst_port == DHCP_CLIENT_PORT) {
                            dhcp_rx_process(reset_n, udp_rx, buffer, dhcp_state, dhcp_xid,
                                           dhcp_offered, dhcp_server, dhcp_timer, dhcp_start);
                        } else {
                            // Copy payload for echo
                            int rx_pbase = RX_BUFFER_BASE + 7;
                            int tx_pbase = TX_UDP_BASE + 7;
                            uint16_t pw = (udp_rx.payload_len + 3) >> 2;
                            for (int i = 0; i < pw; i++) {
                                #pragma HLS PIPELINE
                                buffer[tx_pbase + i] = buffer[rx_pbase + i];
                            }
                            data_received = true;
                            rx_udp_len    = udp_rx.length;
                            rx_ip_len     = ip_rx.total_len;
                            rx_src_port   = udp_rx.src_port;
                            rx_src_ip     = ip_rx.src_ip;
                        }
                    }
                }
            }
        }
    }

    // DHCP TX (before UDP TX — DHCP takes priority)
    if (!tx_req.request) {
        dhcp_tx_process(reset_n, buffer, tx_req, dhcp_start, dhcp_state,
                       dhcp_xid, dhcp_offered, dhcp_server, dhcp_timer);
    }

    // TX arbitration: UDP echo (immediate) + periodic HELLO.
    // udp_tx_process consumes data_received whenever it runs (immediate
    // echo), so it is safe to clear the flag right after the call. When the
    // MAC TX is busy (a frame is being sent/queued and the MAC would read
    // the same buffer region) the call is skipped and the flag survives
    // until the next pass — this prevents the builder from clobbering a
    // frame mid-send.
    if (!tx_req.request && !mac_tx_busy) {
        udp_tx_process(reset_n, buffer, tx_req, NULL,
                       data_received, rx_udp_len, rx_ip_len, rx_src_port, rx_src_ip);
        data_received = false;
    }

    // TCP maintenance: flush queued echo data whenever the MAC is idle
    if (!tx_req.request && !mac_tx_busy) {
        tcp_maintenance(buffer, tx_req);
    }

    // Statistics tracking + periodic report
    static bool dhcp_reported = false;
    static uint32_t last_tx = 0;
    if (mac_rx.valid) {
        if (mac_rx.ethertype == ETHERTYPE_ARP) stats_event(2,0);
        else if (mac_rx.ethertype == ETHERTYPE_IPV4) stats_event(0, ip_rx.valid ? (uint16_t)ip_rx.total_len : (uint16_t)60);
    }
    if (dhcp_state == DHCP_DONE && !dhcp_reported) {
        stats_event(4,0); stats_dhcp_done(dhcp_offered); dhcp_reported=true;
    }
    if (!reset_n) { dhcp_reported=false; last_tx=0; }
    // TX counting: when TX request is consumed and MAC TX starts
    if (tx_req.request && last_tx==0) { stats_event(1, tx_req.buf_len+18); } // +MAC+CRC
    last_tx = tx_req.request ? 1 : 0;
    stats_report(reset_n, msg_stream, stats_should_dump(), buf39_err_cnt);
    // FIX 2026-08-22: LED D0 = buffer[39] mismatch detected (diagnostic)
    led_d0 = (buf39_err_cnt > 0);

    // DHCP status output for wrapper-level LED logic
    led_d0 = (dhcp_state == DHCP_DONE);   // 1 = DHCP acquired
    led_d1 = false;
    led_d2 = false;
    led_d3 = false;
}
