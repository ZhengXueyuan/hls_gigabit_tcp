// debug_tb.cpp - trace TX line transitions to find where the stream stalls
#include <stdio.h>
#include <stdint.h>
#include "ap_int.h"

void uart_console(ap_uint<1>, ap_uint<1>, ap_uint<1>*, ap_uint<1>*, ap_uint<1>*);

#define BIT_CYCLES  5208

static ap_uint<1> tx_line, rx_line, rx_done_o, resp_o;

static void cyc(void) { uart_console(1, rx_line, &tx_line, &rx_done_o, &resp_o); }

static void drive_bit(ap_uint<1> b) {
    rx_line = b;
    for (int i = 0; i < BIT_CYCLES; i++) cyc();
}

static void send_byte(uint8_t b) {
    drive_bit(0);
    for (int i = 0; i < 8; i++) drive_bit((b >> i) & 1);
    drive_bit(1);
}

static void send_str(const char *s) {
    while (*s) send_byte((uint8_t)*s++);
}

int main() {
    rx_line = 1;
    for (int i = 0; i < 5; i++) uart_console(0, 1, &tx_line, &rx_done_o, &resp_o);
    for (int i = 0; i < 200; i++) cyc();

    send_str("?xxx\r");

    // record tx transitions
    ap_uint<1> prev = tx_line;
    long last_edge = 0;
    for (long i = 0; i < 400000; i++) {
        cyc();
        if (tx_line != prev) {
            printf("t=%6ld tx %d -> %d (delta %ld, resp_active=%d)\n",
                   i, (int)prev, (int)tx_line, i - last_edge, (int)resp_o);
            prev = tx_line;
            last_edge = i;
        }
    }
    printf("done, resp_active=%d\n", (int)resp_o);
    return 0;
}
