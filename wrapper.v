//=============================================================================
// wrapper.v — Dual-IP: Network @125MHz + UART @50MHz
//=============================================================================
// Clocks:   e_rxc (125MHz) → network IP
//           fpga_gclk (50MHz) → UART IP
// Data:     msg_stream (AXI-Stream, network→UART) via async FIFO
//=============================================================================

module wrapper (
    input           reset_n,        // async reset, active low
    input           e_rxc,          // 125MHz clock (shared by all IPs)
    // GMII RX
    input           e_rxdv, input e_rxer, input [7:0] e_rxd,
    // MII TX clock (unused)
    input           e_txc,
    // Management
    output          e_reset, output e_mdc, inout e_mdio,
    // GMII TX
    output          e_gtxc, output e_txen, output e_txer, output [7:0] e_txd,
    // UART
    input           rs232_rx,
    output          rs232_tx
);

    // --- Fixed outputs ---
    assign e_gtxc  = e_rxc;
    assign e_reset = 1'b1;
    assign e_mdc   = 1'b0;
    assign e_mdio  = 1'bz;
    assign e_txer  = 1'b0;

    // --- Network IP signals (@125MHz) ---
    wire [15:0] net_rx_data, net_tx_data;
    wire        net_rx_valid, net_rx_ready, net_tx_valid, net_tx_ready;
    wire [15:0] net_msg_data;
    wire        net_msg_valid, net_msg_ready;

    // RX: GMII → AXI-Stream (1-cycle delay)
    reg [7:0]  rx_d1; reg rx_dv_d1, rx_dv_d2;
    always @(posedge e_rxc or negedge reset_n) begin
        if (!reset_n) begin rx_d1<=0;rx_dv_d1<=0;rx_dv_d2<=0; end
        else begin rx_d1<=e_rxd;rx_dv_d1<=e_rxdv;rx_dv_d2<=rx_dv_d1; end
    end
    assign net_rx_data  = {7'b0, rx_dv_d1 && !rx_dv_d2, rx_d1};
    assign net_rx_valid = rx_dv_d1;

    // TX: AXI-Stream → GMII
    assign e_txd  = net_tx_data[7:0];
    assign e_txen = net_tx_valid;
    assign net_tx_ready = 1'b1;

    // Network IP instance
    udp_echo u_net (
        .ap_clk             (e_rxc),
        .ap_rst_n           (reset_n),
        .reset_n            (reset_n),
        .rx_stream_TDATA    (net_rx_data),
        .rx_stream_TVALID   (net_rx_valid),
        .rx_stream_TREADY   (),
        .tx_stream_TDATA    (net_tx_data),
        .tx_stream_TVALID   (net_tx_valid),
        .tx_stream_TREADY   (net_tx_ready),
        .msg_stream_TDATA   (net_msg_data),
        .msg_stream_TVALID  (net_msg_valid),
        .msg_stream_TREADY  (net_msg_ready)
    );

    // --- Direct connection: both IPs @125MHz (no clock crossing needed) ---
    wire [15:0] uart_msg_data;
    wire        uart_msg_valid, uart_msg_ready;

    // network → UART: direct AXI-Stream with backpressure
    assign uart_msg_data  = net_msg_data;
    assign uart_msg_valid = net_msg_valid;
    assign net_msg_ready  = uart_msg_ready;

    // --- UART IP instance (@125MHz, same as network) ---
    uart_console u_uart (
        .ap_clk             (e_rxc),
        .ap_rst_n           (reset_n),
        .rst_n              (reset_n),
        .rx                 (rs232_rx),
        .tx                 (rs232_tx),
        .msg_TDATA          (uart_msg_data),
        .msg_TVALID         (uart_msg_valid),
        .msg_TREADY         (uart_msg_ready),
        .crdy               (),
        .cb                 ()
    );

endmodule
