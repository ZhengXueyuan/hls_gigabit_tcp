// uart_tb.cpp - command console test: echo + response for all commands
// One uart_console() call = one 50MHz clock cycle (II=1), BT=5208.
// Echoes stream out DURING the send of subsequent chars, so each char's
// echo is captured immediately after that char is sent; the response
// follows the last echo back-to-back.
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include "ap_int.h"

void uart_console(ap_uint<1>, ap_uint<1>, ap_uint<1>*, ap_uint<1>*, ap_uint<1>*);

#define BIT_CYCLES  5208
#define MID_BIT     2603

static ap_uint<1> tx_line, rx_line, rx_done_o, resp_o;

static void cyc(void) { uart_console(1, rx_line, &tx_line, &rx_done_o, &resp_o); }

static void drive_bit(ap_uint<1> b) {
    rx_line = b;
    for (int i = 0; i < BIT_CYCLES; i++) cyc();
}

// Transmit one byte LSB-first: start(0) + 8 data + stop(1)
static void send_byte(uint8_t b) {
    drive_bit(0);
    for (int i = 0; i < 8; i++) drive_bit((b >> i) & 1);
    drive_bit(1);
}

// Capture one TX frame with mid-bit sampling. wait_high_first handles
// back-to-back frames (echo -> response stream).
static bool capture_byte(uint8_t *out, int max_cycles, bool wait_high_first) {
    int t = 0;
    if (wait_high_first) {
        while (t++ < max_cycles && tx_line != 1) cyc();
        if (t >= max_cycles) return false;
    }
    while (t++ < max_cycles && tx_line != 0) cyc();
    if (t >= max_cycles) return false;
    for (int j = 0; j < MID_BIT; j++) cyc();
    uint8_t b = 0;
    for (int i = 0; i < 8; i++) {
        for (int j = 0; j < BIT_CYCLES; j++) cyc();
        b |= (uint8_t)(tx_line & 1) << i;
    }
    *out = b;
    return true;
}

static int fails = 0;

// Send command char-by-char, capturing each char's echo as it streams out,
// then capture the response stream (back-to-back after the last echo).
static void test_cmd(const char *cmd, const char *expect, int resp_len) {
    int cmd_len = (int)strlen(cmd);
    for (int i = 0; i < cmd_len; i++) {
        send_byte((uint8_t)cmd[i]);
        uint8_t got = 0;
        if (!capture_byte(&got, BIT_CYCLES * 40, false)) {
            printf("  [%s] echo[%d] capture timeout\n", cmd, i);
            fails++;
            return;
        }
        if (got != (uint8_t)cmd[i]) {
            printf("  [%s] echo[%d]: sent 0x%02X got 0x%02X FAIL\n",
                   cmd, i, (uint8_t)cmd[i], got);
            fails++;
            return;
        }
    }
    // response stream follows the last echo back-to-back
    for (int i = 0; i < resp_len; i++) {
        uint8_t got = 0;
        if (!capture_byte(&got, BIT_CYCLES * 40, true)) {
            printf("  [%s] resp[%d] capture timeout\n", cmd, i);
            fails++;
            return;
        }
        if (got != (uint8_t)expect[i]) {
            printf("  [%s] resp[%d]: want 0x%02X ('%c') got 0x%02X ('%c') FAIL\n",
                   cmd, i, (uint8_t)expect[i],
                   (expect[i] >= 32 && expect[i] < 127) ? expect[i] : '.',
                   got, (got >= 32 && got < 127) ? (char)got : '.');
            fails++;
            return;
        }
    }
    printf("  [%s] echo + response OK\n", cmd);
    for (int i = 0; i < 20000; i++) cyc();   // inter-command idle
}

// single byte echo sanity (no command state involvement)
static void test_echo(uint8_t b) {
    send_byte(b);
    uint8_t got = 0;
    if (capture_byte(&got, BIT_CYCLES * 40, false) && got == b) {
        printf("  echo 0x%02X OK\n", b);
    } else {
        printf("  echo 0x%02X got 0x%02X FAIL\n", b, got);
        fails++;
    }
    for (int i = 0; i < 20000; i++) cyc();
}

// CRLF variant: real terminals send '\r' then '\n'. The '\r' loads the
// response and starts the echo; the '\n' arrives while the response is
// already draining. Wire behavior (cycle math, checked by csim):
//   - the '\r' echo [and then the response byte 0] follow the '\r' send
//     back-to-back, while the '\n' is being received. The '\n' echo is
//     ABSORBED: at its RX-complete the TX is busy draining response byte 0.
//   - response byte 0 starts exactly at the '\n' stop-bit mid, so we hold
//     rx_line high for the '\n' stop bit while capturing byte 0 - and the
//     '\n' RX-complete fires mid-capture (the guard under test: it must
//     NOT clobber the queue, the full response must still come out).
//   - the '\r' echo is not captured here (it would delay the '\n' until
//     byte 0 is mid-frame); the echo path is identical to test_cmd's
//     single-'\r' cases which verify it.
static void test_cmd_crlf(const char *cmd, const char *expect, int resp_len) {
    int cmd_len = (int)strlen(cmd);      // cmd ends with "\r\n"
    // echo chars up to (but NOT including) '\r'
    for (int i = 0; i < cmd_len - 2; i++) {
        send_byte((uint8_t)cmd[i]);
        uint8_t got = 0;
        if (!capture_byte(&got, BIT_CYCLES * 40, false)) {
            printf("  [%s] echo[%d] capture timeout\n", cmd, i);
            fails++;
            return;
        }
        if (got != (uint8_t)cmd[i]) {
            printf("  [%s] echo[%d]: sent 0x%02X got 0x%02X FAIL\n",
                   cmd, i, (uint8_t)cmd[i], got);
            fails++;
            return;
        }
    }
    // '\r' (no echo capture - keeps the '\n' back-to-back so byte 0 of the
    // response starts exactly at the '\n' stop-bit mid), then '\n' as
    // start bit + 8 data bits (0x0A, LSB first) + HOLD stop bit high while
    // response byte 0 begins on the TX wire. rx_line stays high for the
    // RX to finish sampling the '\n' stop bit while the capture runs.
    send_byte(13);
    drive_bit(0);
    for (int i = 0; i < 8; i++) drive_bit((10 >> i) & 1);
    rx_line = 1;
    uint8_t b0 = 0;
    if (!capture_byte(&b0, BIT_CYCLES * 12, true)) {
        printf("  [%s] resp[0] capture timeout\n", cmd);
        fails++;
        return;
    }
    if (b0 != (uint8_t)expect[0]) {
        printf("  [%s] resp[0]: want 0x%02X ('%c') got 0x%02X ('%c') FAIL\n",
               cmd, 0, (uint8_t)expect[0],
               (expect[0] >= 32 && expect[0] < 127) ? expect[0] : '.',
               b0, (b0 >= 32 && b0 < 127) ? (char)b0 : '.');
        fails++;
        return;
    }
    // remaining response bytes, back-to-back
    for (int i = 1; i < resp_len; i++) {
        uint8_t got = 0;
        if (!capture_byte(&got, BIT_CYCLES * 40, true)) {
            printf("  [%s] resp[%d] capture timeout\n", cmd, i);
            fails++;
            return;
        }
        if (got != (uint8_t)expect[i]) {
            printf("  [%s] resp[%d]: want 0x%02X ('%c') got 0x%02X ('%c') FAIL\n",
                   cmd, i, (uint8_t)expect[i],
                   (expect[i] >= 32 && expect[i] < 127) ? expect[i] : '.',
                   got, (got >= 32 && got < 127) ? (char)got : '.');
            fails++;
            return;
        }
    }
    printf("  [%s] full response intact over CRLF OK\n", cmd);
    for (int i = 0; i < 20000; i++) cyc();
}

// Bare "\r\n" (Enter with no command): '\r' loads the "?\r\n" fallback
// and echoes; the '\n' arrives while it drains. Response byte 0 ('?') is
// transmitted during the '\n' receive, so bytes 1-2 ('\r','\n') are what
// is observable afterwards. A clobbering reload (the bug) would re-append
// a fresh "?\r\n" -> a third frame appears / the tail shifts to '?','\r'.
static void test_bare_crlf(void) {
    send_byte(13);
    {
        uint8_t got = 0;
        if (!capture_byte(&got, BIT_CYCLES * 40, false) || got != 13) {
            printf("  [\\r\\n] echo 0x0D: got 0x%02X FAIL\n", got);
            fails++;
            for (int i = 0; i < 20000; i++) cyc();
            return;
        }
    }
    send_byte(10);                          // '\n' during the fallback drain
    uint8_t b1 = 0, b2 = 0;
    if (!capture_byte(&b1, BIT_CYCLES * 40, true) || b1 != 0x0D) {
        printf("  [\\r\\n] fallback byte1: got 0x%02X FAIL (tail corrupted)\n", b1);
        fails++;
    } else if (!capture_byte(&b2, BIT_CYCLES * 40, true) || b2 != 0x0A) {
        printf("  [\\r\\n] fallback byte2: got 0x%02X FAIL (tail corrupted)\n", b2);
        fails++;
    } else {
        // no third frame: a guard failure would re-drain "?\r\n" after this
        uint8_t b3 = 0;
        if (capture_byte(&b3, BIT_CYCLES * 40, true)) {
            printf("  [\\r\\n] unexpected extra frame 0x%02X FAIL (guard broken)\n", b3);
            fails++;
        } else {
            printf("  [\\r\\n] echo + fallback tail OK ('?' drains during the \\n)\n");
        }
    }
    for (int i = 0; i < 20000; i++) cyc();
}

int main() {
    // reset
    rx_line = 1;
    for (int i = 0; i < 5; i++) uart_console(0, 1, &tx_line, &rx_done_o, &resp_o);
    for (int i = 0; i < 200; i++) cyc();

    printf("--- basic echo ---\n");
    test_echo(0x41);
    test_echo(0x5A);

    printf("--- commands ---\n");
    test_cmd("?mac\r",  "MAC: 00:0A:35:01:FE:C0\r\n", 24);
    test_cmd("?ip\r",   "IP: 192.168.100.2\r\n", 19);
    test_cmd("?stat\r", "UART 9600-8N1 @50MHz\r\n", 22);
    test_cmd("?help\r", "?help ?mac ?ip ?stat\r\n", 22);
    test_cmd("?xxx\r",  "?\r\n", 3);
    test_cmd("\r",      "?\r\n", 3);   // bare Enter (CR only): full fallback

    printf("--- commands, real-terminal CRLF (\\r\\n) ---\n");
    test_cmd_crlf("?mac\r\n",  "MAC: 00:0A:35:01:FE:C0\r\n", 24);
    test_cmd_crlf("?ip\r\n",   "IP: 192.168.100.2\r\n", 19);
    test_cmd_crlf("?help\r\n", "?help ?mac ?ip ?stat\r\n", 22);
    test_cmd_crlf("?stat\r\n", "UART 9600-8N1 @50MHz\r\n", 22);
    test_bare_crlf();

    printf(fails ? "RESULT: FAIL (%d)\n" : "RESULT: PASS\n", fails);
    return fails ? 1 : 0;
}
