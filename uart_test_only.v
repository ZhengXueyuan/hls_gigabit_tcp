module wrapper(input fpga_gclk, input reset_n, input rs232_rx, output rs232_tx);
    wire [15:0] dmy; wire vld, rdy;
    uart_console u(.ap_clk(fpga_gclk),.ap_rst_n(reset_n),.rst_n(reset_n),
        .rx(rs232_rx),.tx(rs232_tx),.msg_TDATA(dmy),.msg_TVALID(vld),.msg_TREADY(rdy),.crdy(),.cb());
endmodule
