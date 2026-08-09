// Minimal wrapper — network IP only (no UART)
module wrapper (
    input fpga_gclk, input reset_n,
    input e_rxc, input e_rxdv, input e_rxer, input [7:0] e_rxd,
    input e_txc,
    output e_reset, output e_mdc, inout e_mdio,
    output e_gtxc, output e_txen, output e_txer, output [7:0] e_txd,
    input rs232_rx, output rs232_tx
);
    assign e_gtxc=e_rxc; assign e_reset=1'b1; assign e_mdc=1'b0; assign e_mdio=1'bz; assign e_txer=1'b0;
    assign rs232_tx=1'b1; // idle

    reg [7:0] rx_d1; reg rx_dv_d1, rx_dv_d2;
    always @(posedge e_rxc or negedge reset_n) begin
        if(!reset_n) begin rx_d1<=0;rx_dv_d1<=0;rx_dv_d2<=0; end
        else begin rx_d1<=e_rxd;rx_dv_d1<=e_rxdv;rx_dv_d2<=rx_dv_d1; end
    end
    wire [15:0] net_rx_data = {7'b0, rx_dv_d1 && !rx_dv_d2, rx_d1};
    wire [15:0] net_tx_data; wire net_tx_valid;
    assign e_txd = net_tx_data[7:0]; assign e_txen = net_tx_valid;
    wire [15:0] dummy_msg; wire dummy_v, dummy_r;

    udp_echo u_net (
        .ap_clk(e_rxc), .ap_rst_n(reset_n), .reset_n(reset_n),
        .rx_stream_TDATA(net_rx_data), .rx_stream_TVALID(rx_dv_d1), .rx_stream_TREADY(),
        .tx_stream_TDATA(net_tx_data), .tx_stream_TVALID(net_tx_valid), .tx_stream_TREADY(1'b1),
        .msg_stream_TDATA(dummy_msg), .msg_stream_TVALID(dummy_v), .msg_stream_TREADY(dummy_r)
    );
endmodule
