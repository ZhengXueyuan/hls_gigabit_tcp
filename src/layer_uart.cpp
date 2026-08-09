//=============================================================================
// layer_uart.cpp — UART 9600-8N1 with BRAM FIFO + command parser
//=============================================================================
// TX: reads from tx_buf[] circular buffer, sends serial bytes
// RX: receives serial bytes, writes to rx_buf[] circular buffer
// CMD: parses newline-terminated commands, formats responses
//
// Commands:  ?help  ?mac  ?ip  ?dhcp  ?arp  ?stat
//=============================================================================

#include "eth_types.h"
#include "eth_utils.h"

// Inline string compare (HLS doesn't support strcmp)
static bool str_match(const uint8_t *a, const char *b, int len) {
    for (int i = 0; i < len; i++) {
        if (a[i] != (uint8_t)b[i]) return false;
        if (a[i] == 0 && b[i] == 0) return true;
    }
    return b[len] == 0;
}

// UART timing: 125MHz / 9600 ≈ 13020
#define UART_DIV    13020
#define UART_HALF   6510

// FIFO sizes
#define TX_FIFO_SIZE  512   // outgoing text buffer
#define RX_FIFO_SIZE   64   // incoming command buffer
#define CMD_MAX_LEN    48   // max command line length

// UART FSM states
enum { UART_IDLE, UART_START, UART_DATA, UART_STOP };

//=============================================================================
// TX FIFO (circular buffer, network-write / UART-read)
//=============================================================================
static uint8_t  tx_buf[TX_FIFO_SIZE];
static uint16_t tx_wr = 0;
static uint16_t tx_rd = 0;

//=============================================================================
// RX FIFO (circular buffer, UART-write / cmd-read)
//=============================================================================
static uint8_t  rx_buf[RX_FIFO_SIZE];
static uint8_t  rx_wr = 0;
static uint8_t  rx_rd = 0;

//=============================================================================
// UART RX state
//=============================================================================
static uint8_t  rx_state    = UART_IDLE;
static uint16_t rx_div      = 0;
static uint8_t  rx_bit      = 0;
static uint8_t  rx_shift    = 0;
static bool     rx_prev     = true;
static bool     rx_byte_rdy = false;
static uint8_t  rx_byte_val = 0;

//=============================================================================
// UART TX state
//=============================================================================
static uint8_t  tx_state    = UART_IDLE;
static uint16_t tx_div      = 0;
static uint8_t  tx_bit      = 0;
static uint8_t  tx_shift    = 0;
static bool     tx_busy     = false;

//=============================================================================
// Command parser state
//=============================================================================
static uint8_t  cmd_buf[CMD_MAX_LEN];
static uint8_t  cmd_len     = 0;

//=============================================================================
// Debug output — write string to TX FIFO (called from any layer)
//=============================================================================
static void uart_puts(const char *s) {
    while (*s) {
        uint16_t next = (tx_wr + 1) & (TX_FIFO_SIZE - 1);
        if (next != tx_rd) {  // not full
            tx_buf[tx_wr] = (uint8_t)*s;
            tx_wr = next;
        }
        s++;
    }
}

//=============================================================================
// Write a single character to TX FIFO
//=============================================================================
static void uart_putc(char c) {
    uint16_t next = (tx_wr + 1) & (TX_FIFO_SIZE - 1);
    if (next != tx_rd) { tx_buf[tx_wr] = (uint8_t)c; tx_wr = next; }
}

//=============================================================================
// Write a hex byte (2 chars)
//=============================================================================
static void uart_puthex(uint8_t v) {
    char hex[] = "0123456789ABCDEF";
    uart_putc(hex[v >> 4]);
    uart_putc(hex[v & 0xF]);
}

//=============================================================================
// Write uint32 as dotted decimal
//=============================================================================
static void uart_putip(uint32_t ip) {
    uint8_t b0 = (ip >> 24) & 0xFF, b1 = (ip >> 16) & 0xFF, b2 = (ip >> 8) & 0xFF, b3 = ip & 0xFF;
    char buf[16]; int p = 0;
    auto putdec = [](uint8_t v, char *b, int &pos) {
        if (v >= 100) { b[pos++] = '0' + v/100; v %= 100; }
        if (v >= 10)  { b[pos++] = '0' + v/10;  v %= 10; }
        b[pos++] = '0' + v;
    };
    putdec(b0, buf, p); buf[p++] = '.'; putdec(b1, buf, p); buf[p++] = '.';
    putdec(b2, buf, p); buf[p++] = '.'; putdec(b3, buf, p); buf[p] = 0;
    uart_puts(buf);
}

//=============================================================================
// Write MAC address
//=============================================================================
static void uart_putmac(mac_addr_t mac) {
    for (int i = 5; i >= 0; i--) {
        uart_puthex((mac >> (i * 8)) & 0xFF);
        if (i > 0) uart_putc(':');
    }
}

//=============================================================================
// Command processor — parse and respond
//=============================================================================
static void uart_cmd_process() {
    // Copy any new RX bytes into command line buffer
    while (rx_rd != rx_wr) {
        uint8_t c = rx_buf[rx_rd];
        rx_rd = (rx_rd + 1) & (RX_FIFO_SIZE - 1);
        if (c == '\n' || c == '\r') {
            cmd_buf[cmd_len] = 0;  // null-terminate
            if (cmd_len > 0) {
                // Process command
                if      (str_match(cmd_buf, "?help", cmd_len)) { uart_puts("Commands: ?help ?mac ?ip ?dhcp ?arp ?stat\r\n"); }
                else if (str_match(cmd_buf, "?mac", cmd_len))  { uart_puts("MAC: "); uart_putmac(0x000A3501FEC0ULL); uart_puts("\r\n"); }
                else if (str_match(cmd_buf, "?ip", cmd_len))   { uart_puts("IP: 192.168.0.2 (static)\r\n"); }
                else if (str_match(cmd_buf, "?stat", cmd_len)) { uart_puts("UART: rx/tx OK, BRAM FIFO\r\n"); }
                else { uart_puts("Unknown: "); uart_puts((const char*)cmd_buf); uart_puts("\r\n"); }
                cmd_len = 0;
            }
        } else if (cmd_len < CMD_MAX_LEN - 1) {
            cmd_buf[cmd_len++] = c;
        }
    }
}

//=============================================================================
// UART RX process — sample rs232_rx pin every UART_DIV cycles
//=============================================================================
static void uart_rx_process(bool reset_n, bool rs232_rx) {
    if (!reset_n) {
        rx_state = UART_IDLE; rx_div = 0; rx_bit = 0; rx_byte_rdy = false;
        rx_prev = true; rx_wr = 0; rx_rd = 0;
        return;
    }

    switch (rx_state) {
        case UART_IDLE:
            if (!rs232_rx && rx_prev) {  // falling edge = start bit
                rx_state = UART_START;
                rx_div   = 0;
            }
            rx_prev = rs232_rx;
            break;
        case UART_START:
            if (rx_div < UART_HALF + (UART_DIV / 4)) {  // sample mid-bit
                rx_div++;
            } else {
                if (!rs232_rx) {  // still low → valid start
                    rx_state = UART_DATA;
                    rx_div   = 0;
                    rx_bit   = 0;
                    rx_shift = 0;
                } else {
                    rx_state = UART_IDLE;  // false start
                }
            }
            break;
        case UART_DATA:
            rx_div++;
            if (rx_div >= UART_DIV) {
                rx_div = 0;
                if (rs232_rx) rx_shift |= (1 << rx_bit);
                rx_bit++;
                if (rx_bit == 8) {
                    rx_state = UART_STOP;
                    rx_div   = 0;
                }
            }
            break;
        case UART_STOP:
            rx_div++;
            if (rx_div >= UART_DIV) {
                rx_div = 0;
                uint8_t next = (rx_wr + 1) & (RX_FIFO_SIZE - 1);
                if (next != rx_rd) {  // not full
                    rx_buf[rx_wr] = rx_shift;
                    rx_wr = next;
                }
                rx_state = UART_IDLE;
            }
            break;
    }
}

//=============================================================================
// UART TX process — send bytes from tx_buf[]
//=============================================================================
static bool uart_tx_process(bool reset_n, bool &uart_txd) {
    if (!reset_n) {
        tx_state = UART_IDLE; tx_div = 0; tx_bit = 0; tx_busy = false;
        uart_txd = true;  // idle high
        return false;
    }

    uart_txd = true;  // default idle

    switch (tx_state) {
        case UART_IDLE:
            if (tx_rd != tx_wr) {  // data available
                tx_shift = tx_buf[tx_rd];
                tx_rd = (tx_rd + 1) & (TX_FIFO_SIZE - 1);
                tx_state = UART_START;
                tx_div   = 0;
                tx_bit   = 0;
                tx_busy  = true;
            }
            break;
        case UART_START:
            uart_txd = false;  // start bit
            tx_div++;
            if (tx_div >= UART_DIV) { tx_div = 0; tx_state = UART_DATA; }
            break;
        case UART_DATA:
            uart_txd = (tx_shift >> tx_bit) & 1;
            tx_div++;
            if (tx_div >= UART_DIV) {
                tx_div = 0;
                tx_bit++;
                if (tx_bit == 8) { tx_state = UART_STOP; tx_div = 0; }
            }
            break;
        case UART_STOP:
            uart_txd = true;  // stop bit
            tx_div++;
            if (tx_div >= UART_DIV) {
                tx_div   = 0;
                tx_state = UART_IDLE;
                tx_busy  = false;
            }
            break;
    }
    return tx_busy;
}

//=============================================================================
// UART top-level — called once per cycle from udp_echo
//=============================================================================
static void uart_process(
    bool  reset_n,
    bool  uart_rx,
    bool &uart_tx,
    bool  dhcp_done,
    uint32_t dhcp_ip
) {
    #pragma HLS RESOURCE variable=tx_buf core=RAM_2P_BRAM
    #pragma HLS RESOURCE variable=rx_buf core=RAM_2P_BRAM
    uart_rx_process(reset_n, uart_rx);
    bool busy = uart_tx_process(reset_n, uart_tx);
    uart_cmd_process();

    // Status-driven output (one-shot on DHCP completion)
    static bool dhcp_reported = false;
    if (reset_n && dhcp_done && !dhcp_reported) {
        uart_puts("\r\n=== DHCP ACK ===\r\n  IP: ");
        uart_putip(dhcp_ip);
        uart_puts("\r\n  MAC: ");
        uart_putmac(0x000A3501FEC0ULL);
        uart_puts("\r\n================\r\n");
        dhcp_reported = true;
    }
    if (!reset_n) dhcp_reported = false;
}
