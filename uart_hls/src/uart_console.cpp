//=============================================================================
// uart_console.cpp - UART command console: echo + command responses
//=============================================================================
// Faithful to uart_test_hls (board-verified): 9600-8N1 @ 50MHz, fixed
// BPS_DIV=5207 / BPS_HALF=2603, falling-edge start detect, mid-bit sample,
// byte latched at stop-bit mid. NO auto-baud - the clock is the same N14
// 50MHz oscillator as the verified demo project.
//
// Extensions over the demo:
//   - incremental command matcher: ?help ?mac ?ip ?stat (scalar states)
//   - response queue: 192-bit shift register, left-aligned (first char at
//     bits 191:184), drained after the Enter echo
//   - rx_done pulse output (LED) + resp_active flag output (debug)
//
// IMPORTANT: the body must schedule to II=1 (Latency 0, Interval 1) -
// one body pass = one 50MHz clock cycle. Check csynth after synthesis.
//=============================================================================
#include "ap_int.h"

#define BPS_DIV   5207    // 50MHz / 9600 = 5208.33, counter counts 0..5207
#define BPS_HALF  2603    // mid-bit sample point

// 2-stage sync (input already synced once by wrapper.v - mirrors the
// demo's total of 4 register stages from the raw pin)
static ap_uint<2>  sync_sr = 3;

// --- RX side ---
static ap_uint<1>  rx_active = 0;
static ap_uint<13> rcnt = 0;
static ap_uint<4>  rnum = 0;
static ap_uint<8>  rx_byte = 0;

// echo handoff (demo semantics: absorbed if the TX is busy)
static ap_uint<8>  tx_hold = 0;
static ap_uint<1>  tx_pending = 0;

// --- TX side ---
static ap_uint<1>  tx_active = 0;
static ap_uint<13> tcnt = 0;
static ap_uint<4>  tnum = 0;
static ap_uint<8>  tx_byte = 0;
static ap_uint<1>  tx_out = 1;              // idle high

// --- response queue ---
// 192-bit shift register = 24 bytes, left-aligned: byte 0 = bits 191:184.
// TX pops the top byte then shifts left 8.
static ap_uint<192> resp_sr = 0;
static ap_uint<5>   resp_remain = 0;

// --- incremental command state ---
//   0=idle, 1='?', 2='?h', 3='?he', 4='?hel', 5='?help'
//   11='?m', 12='?ma', 13='?mac'
//   21='?i', 22='?ip'
//   31='?s', 32='?st', 33='?sta', 34='?stat'
static ap_uint<7>  cmd_st = 0;

// rx_done pulse for wrapper LED
static ap_uint<1>  rx_done_p = 0;

void uart_console(ap_uint<1> rst_n, ap_uint<1> rx, ap_uint<1> *tx,
                  ap_uint<1> *rx_done, ap_uint<1> *resp_active) {
#pragma HLS INTERFACE ap_none port=rst_n
#pragma HLS INTERFACE ap_none port=rx
#pragma HLS INTERFACE ap_none port=tx
#pragma HLS INTERFACE ap_none port=rx_done
#pragma HLS INTERFACE ap_none port=resp_active
#pragma HLS INTERFACE ap_ctrl_none port=return

    if (!rst_n) {
        sync_sr = 3;
        rx_active = 0; rcnt = 0; rnum = 0; rx_byte = 0;
        tx_hold = 0; tx_pending = 0;
        tx_active = 0; tcnt = 0; tnum = 0; tx_byte = 0; tx_out = 1;
        resp_sr = 0; resp_remain = 0;
        cmd_st = 0; rx_done_p = 0;
        *tx = 1; *rx_done = 0; *resp_active = 0;
        return;
    }

    *rx_done = rx_done_p;
    *resp_active = (resp_remain > 0) ? (ap_uint<1>)1 : (ap_uint<1>)0;
    rx_done_p = 0;

    // 2-stage synchronizer (input already synced by wrapper.v)
    sync_sr = (sync_sr << 1) | (ap_uint<2>)rx;
    ap_uint<1> prev1 = sync_sr[0];            // pin 1 cycle ago
    ap_uint<1> prev2 = sync_sr[1];            // pin 2 cycles ago

    // ---- RX: always armed, independent of TX ----
    if (!rx_active) {
        if (prev2 == 1 && prev1 == 0) {       // start bit falling edge
            rx_active = 1;
            rx_byte   = 0;
            rcnt      = 0;
            rnum      = 0;
        }
    } else {
        if (rcnt == BPS_HALF) {
            // mid-bit: sample data bits (rnum 1..8; rnum 0 = start, ignore)
            if (rnum >= 1 && rnum <= 8)
                rx_byte = rx_byte | (ap_uint<8>)((ap_uint<8>)prev1 << (rnum - 1));
            if (rnum == 9) {                  // stop-bit mid: frame complete
                // echo handoff (demo semantics: absorbed if TX busy)
                if (!tx_active) {
                    tx_hold    = rx_byte;
                    tx_pending = 1;
                }
                rx_done_p = 1;

                // ---- incremental command matching ----
                if (rx_byte == 13 || rx_byte == 10) {
                    // Enter: load response into shift register by cmd_st.
                    // 1-deep response semantics: a second Enter (e.g. the
                    // '\n' of a CRLF pair arriving while the '\r' response
                    // is still draining) must NOT clobber the in-flight
                    // response - only load when the queue is empty.
                    if (resp_remain == 0) {
                    if (cmd_st == 5) {
                        // "?help ?mac ?ip ?stat\r\n" = 22 chars
                        resp_sr = (ap_uint<192>(0x3F) << 184) | (ap_uint<192>(0x68) << 176) |
                                  (ap_uint<192>(0x65) << 168) | (ap_uint<192>(0x6C) << 160) |
                                  (ap_uint<192>(0x70) << 152) | (ap_uint<192>(0x20) << 144) |
                                  (ap_uint<192>(0x3F) << 136) | (ap_uint<192>(0x6D) << 128) |
                                  (ap_uint<192>(0x61) << 120) | (ap_uint<192>(0x63) << 112) |
                                  (ap_uint<192>(0x20) << 104) | (ap_uint<192>(0x3F) << 96)  |
                                  (ap_uint<192>(0x69) << 88)  | (ap_uint<192>(0x70) << 80)  |
                                  (ap_uint<192>(0x20) << 72)  | (ap_uint<192>(0x3F) << 64)  |
                                  (ap_uint<192>(0x73) << 56)  | (ap_uint<192>(0x74) << 48)  |
                                  (ap_uint<192>(0x61) << 40)  | (ap_uint<192>(0x74) << 32)  |
                                  (ap_uint<192>(0x0D) << 24)  | (ap_uint<192>(0x0A) << 16);
                        resp_remain = 22;
                    } else if (cmd_st == 13) {
                        // "MAC: 00:0A:35:01:FE:C0\r\n" = 24 chars
                        resp_sr = (ap_uint<192>(0x4D) << 184) | (ap_uint<192>(0x41) << 176) |
                                  (ap_uint<192>(0x43) << 168) | (ap_uint<192>(0x3A) << 160) |
                                  (ap_uint<192>(0x20) << 152) | (ap_uint<192>(0x30) << 144) |
                                  (ap_uint<192>(0x30) << 136) | (ap_uint<192>(0x3A) << 128) |
                                  (ap_uint<192>(0x30) << 120) | (ap_uint<192>(0x41) << 112) |
                                  (ap_uint<192>(0x3A) << 104) | (ap_uint<192>(0x33) << 96)  |
                                  (ap_uint<192>(0x35) << 88)  | (ap_uint<192>(0x3A) << 80)  |
                                  (ap_uint<192>(0x30) << 72)  | (ap_uint<192>(0x31) << 64)  |
                                  (ap_uint<192>(0x3A) << 56)  | (ap_uint<192>(0x46) << 48)  |
                                  (ap_uint<192>(0x45) << 40)  | (ap_uint<192>(0x3A) << 32)  |
                                  (ap_uint<192>(0x43) << 24)  | (ap_uint<192>(0x30) << 16)  |
                                  (ap_uint<192>(0x0D) << 8)   | (ap_uint<192>(0x0A));
                        resp_remain = 24;
                    } else if (cmd_st == 22) {
                        // "IP: 192.168.100.2\r\n" = 19 chars (ECO: match BOARD_IP in eth_types.h)
                        resp_sr = (ap_uint<192>(0x49) << 184) | (ap_uint<192>(0x50) << 176) |
                                  (ap_uint<192>(0x3A) << 168) | (ap_uint<192>(0x20) << 160) |
                                  (ap_uint<192>(0x31) << 152) | (ap_uint<192>(0x39) << 144) |
                                  (ap_uint<192>(0x32) << 136) | (ap_uint<192>(0x2E) << 128) |
                                  (ap_uint<192>(0x31) << 120) | (ap_uint<192>(0x36) << 112) |
                                  (ap_uint<192>(0x38) << 104) | (ap_uint<192>(0x2E) << 96)  |
                                  (ap_uint<192>(0x31) << 88)  | (ap_uint<192>(0x30) << 80)  |
                                  (ap_uint<192>(0x30) << 72)  | (ap_uint<192>(0x2E) << 64)  |
                                  (ap_uint<192>(0x32) << 56)  | (ap_uint<192>(0x0D) << 48)  |
                                  (ap_uint<192>(0x0A) << 40);
                        resp_remain = 19;
                    } else if (cmd_st == 34) {
                        // "UART 9600-8N1 @50MHz\r\n" = 22 chars
                        resp_sr = (ap_uint<192>(0x55) << 184) | (ap_uint<192>(0x41) << 176) |
                                  (ap_uint<192>(0x52) << 168) | (ap_uint<192>(0x54) << 160) |
                                  (ap_uint<192>(0x20) << 152) | (ap_uint<192>(0x39) << 144) |
                                  (ap_uint<192>(0x36) << 136) | (ap_uint<192>(0x30) << 128) |
                                  (ap_uint<192>(0x30) << 120) | (ap_uint<192>(0x2D) << 112) |
                                  (ap_uint<192>(0x38) << 104) | (ap_uint<192>(0x4E) << 96)  |
                                  (ap_uint<192>(0x31) << 88)  | (ap_uint<192>(0x20) << 80)  |
                                  (ap_uint<192>(0x40) << 72)  | (ap_uint<192>(0x35) << 64)  |
                                  (ap_uint<192>(0x30) << 56)  | (ap_uint<192>(0x4D) << 48)  |
                                  (ap_uint<192>(0x48) << 40)  | (ap_uint<192>(0x7A) << 32)  |
                                  (ap_uint<192>(0x0D) << 24)  | (ap_uint<192>(0x0A) << 16);
                        resp_remain = 22;
                    } else {
                        // "?\r\n" = 3 chars
                        resp_sr = (ap_uint<192>(0x3F) << 184) | (ap_uint<192>(0x0D) << 176) |
                                  (ap_uint<192>(0x0A) << 168);
                        resp_remain = 3;
                    }
                    }
                    cmd_st = 0;
                } else {
                    // incremental state transition
                    switch (cmd_st) {
                        case 0:  cmd_st = (rx_byte == '?') ? 1 : 0; break;
                        case 1:  if (rx_byte=='h') cmd_st=2;
                                 else if (rx_byte=='m') cmd_st=11;
                                 else if (rx_byte=='i') cmd_st=21;
                                 else if (rx_byte=='s') cmd_st=31;
                                 else cmd_st=0; break;
                        case 2:  cmd_st = (rx_byte == 'e') ? 3 : 0; break;
                        case 3:  cmd_st = (rx_byte == 'l') ? 4 : 0; break;
                        case 4:  cmd_st = (rx_byte == 'p') ? 5 : 0; break;
                        case 11: cmd_st = (rx_byte == 'a') ? 12 : 0; break;
                        case 12: cmd_st = (rx_byte == 'c') ? 13 : 0; break;
                        case 21: cmd_st = (rx_byte == 'p') ? 22 : 0; break;
                        case 31: cmd_st = (rx_byte == 't') ? 32 : 0; break;
                        case 32: cmd_st = (rx_byte == 'a') ? 33 : 0; break;
                        case 33: cmd_st = (rx_byte == 't') ? 34 : 0; break;
                        default: cmd_st = 0; break;
                    }
                }
                rx_active = 0;
            } else {
                rnum++;
            }
        }
        if (rcnt == BPS_DIV) rcnt = 0;        // counter advances every cycle
        else                 rcnt++;
    }

    // ---- TX: echo priority, then response queue ----
    // Same flag timing as the demo: TX ends right after the stop bit is
    // driven, so back-to-back frames (echo + response stream) all go out.
    if (!tx_active) {
        tx_out = 1;
        if (tx_pending) {
            tx_active  = 1;
            tx_pending = 0;
            tx_byte    = tx_hold;
            tcnt       = 0;
            tnum       = 0;
        } else if (resp_remain > 0) {
            tx_active = 1;
            tx_byte   = resp_sr(191, 184);    // pop top byte (fixed slice)
            resp_sr   = resp_sr << 8;
            resp_remain--;
            tcnt = 0;
            tnum = 0;
        }
    } else {
        if (tcnt == BPS_HALF) {
            // drive bit at slot boundaries
            if (tnum == 0)         tx_out = 0;                            // start
            else if (tnum <= 8)    tx_out = (tx_byte >> (tnum - 1)) & 1;  // data
            else                   tx_out = 1;                            // stop
            if (tnum <= 9) tnum++;              // 10 = stop fully driven
        }
        if (tcnt == BPS_DIV) {
            tcnt = 0;
            // End the byte at the END of the stop cell (not at the mid-cell
            // drive point). Otherwise back-to-back bursts have only 9.5-cell
            // start-edge spacing: receivers that sample the stop bit late
            // (CH340 on the ECO board) hit the next byte's start edge and
            // cascade framing errors. Full 10-cell spacing is UART-standard.
            if (tnum == 10) tx_active = 0;
        } else {
            tcnt++;
        }
    }

    *tx = tx_out;
}
