// rtl_diag_tb.v — diagnostic: feed SYN, observe FSM + MAC RX + buffer + tx
`timescale 1ns/1ps
module rtl_diag_tb;

reg ap_clk = 0;
reg ap_rst_n = 0;
reg reset_n = 0;
reg [15:0] rx_stream_TDATA = 0;
reg rx_stream_TVALID = 0;
wire rx_stream_TREADY;
wire [15:0] tx_stream_TDATA;
wire tx_stream_TVALID;
reg tx_stream_TREADY = 1;
wire [15:0] msg_stream_TDATA;
wire msg_stream_TVALID;
reg msg_stream_TREADY = 1;
wire led_d0, led_d1, led_d2, led_d3;

always #4 ap_clk = ~ap_clk;

udp_echo dut (
    .ap_clk(ap_clk), .ap_rst_n(ap_rst_n), .reset_n(reset_n),
    .rx_stream_TDATA(rx_stream_TDATA), .rx_stream_TVALID(rx_stream_TVALID), .rx_stream_TREADY(rx_stream_TREADY),
    .tx_stream_TDATA(tx_stream_TDATA), .tx_stream_TVALID(tx_stream_TVALID), .tx_stream_TREADY(tx_stream_TREADY),
    .msg_stream_TDATA(msg_stream_TDATA), .msg_stream_TVALID(msg_stream_TVALID), .msg_stream_TREADY(msg_stream_TREADY),
    .led_d0(led_d0), .led_d1(led_d1), .led_d2(led_d2), .led_d3(led_d3)
);

reg [7:0] f [0:4095];
integer n, k;

task feed_frame(input integer fcnt);
begin : blk
    integer b;
    rx_stream_TVALID = 0;
    @(posedge ap_clk);
    for (b = 0; b < fcnt; b = b + 1) begin
        while (dut.rx_stream_TVALID_int_regslice) @(posedge ap_clk);
        rx_stream_TDATA = {(b == fcnt - 1), f[b]};
        rx_stream_TVALID = 1;
        while (!(rx_stream_TVALID && rx_stream_TREADY)) @(posedge ap_clk);
        @(posedge ap_clk);
        $display("t=%0t feed b=%0d dat=%02x last=%b", $time, b, f[b], (b == fcnt-1));
        rx_stream_TVALID = 0;
    end
    rx_stream_TVALID = 0;
end
endtask

initial begin
    $display("=== DIAG TB start ===");
    ap_rst_n = 0; reset_n = 0;
    repeat (20) @(posedge ap_clk);
    ap_rst_n = 1; reset_n = 1;
    repeat (50) @(posedge ap_clk);

    // Build SYN frame (same as rtl_tcp_tb)
    n = 0;
    for (k = 0; k < 7; k = k + 1) f[n+k] = 8'h55; n = n + 7;
    f[n] = 8'hD5; n = n + 1;
    f[n]=8'h00;f[n+1]=8'h0A;f[n+2]=8'h35;f[n+3]=8'h01;f[n+4]=8'hFE;f[n+5]=8'hC0; n = n + 6;
    f[n]=8'h10;f[n+1]=8'h11;f[n+2]=8'h12;f[n+3]=8'h13;f[n+4]=8'h14;f[n+5]=8'h15; n = n + 6;
    f[n]=8'h08;f[n+1]=8'h00; n = n + 2;
    f[n]=8'h45;f[n+1]=8'h00;f[n+2]=8'h00;f[n+3]=8'h28;
    f[n+4]=8'h00;f[n+5]=8'h01;f[n+6]=8'h40;f[n+7]=8'h00;
    f[n+8]=8'h40;f[n+9]=8'h06;f[n+10]=8'h00;f[n+11]=8'h00;
    f[n+12]=8'hC0;f[n+13]=8'hA8;f[n+14]=8'h64;f[n+15]=8'h64;
    f[n+16]=8'hC0;f[n+17]=8'hA8;f[n+18]=8'h64;f[n+19]=8'h02;
    // IP checksum placeholder - compute in sim
    begin : csum
        integer s;
        s = 0;
        for (k = 0; k < 20; k = k + 2) s = s + ((f[n+k] << 8) | f[n+k+1]);
        while (s >> 16) s = (s & 16'hFFFF) + (s >> 16);
        s = ~s;
        f[n+10] = (s >> 8) & 8'hFF; f[n+11] = s & 8'hFF;
    end
    // TCP
    f[n+20]=8'h30;f[n+21]=8'h39;
    f[n+22]=8'h00;f[n+23]=8'h07;
    f[n+24]=8'h10;f[n+25]=8'h00;f[n+26]=8'h00;f[n+27]=8'h00;
    f[n+28]=8'h00;f[n+29]=8'h00;f[n+30]=8'h00;f[n+31]=8'h00;
    f[n+32]=8'h50;f[n+33]=8'h02;f[n+34]=8'h20;f[n+35]=8'h00;
    f[n+36]=8'h00;f[n+37]=8'h00;f[n+38]=8'h00;f[n+39]=8'h00;
    begin : tcsum
        integer s;
        s = 6 + 20;
        s = s + ((32'hC0A86464 >> 16) & 16'hFFFF) + (32'hC0A86464 & 16'hFFFF);
        s = s + ((32'hC0A86402 >> 16) & 16'hFFFF) + (32'hC0A86402 & 16'hFFFF);
        for (k = 0; k < 20; k = k + 2) s = s + ((f[n+20+k] << 8) | f[n+20+k+1]);
        while (s >> 16) s = (s & 16'hFFFF) + (s >> 16);
        s = ~s;
        f[n+36] = (s >> 8) & 8'hFF; f[n+37] = s & 8'hFF;
    end
    n = n + 40;

    $display("SYN frame length = %0d", n);
    $display("f[0..15] = %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x",
        f[0],f[1],f[2],f[3],f[4],f[5],f[6],f[7],f[8],f[9],f[10],f[11],f[12],f[13],f[14],f[15]);
    feed_frame(n);
    $display("SYN fed  (MRX state=%0d cnt=%0d mrxbuf=%0d)", dut.grp_mac_rx_process_fu_1145.state_1,
        dut.grp_mac_rx_process_fu_1145.byte_cnt_1, dut.grp_mac_rx_process_fu_1145.buf_wr_addr);

    // Watch for up to 3000 cycles: print FSM state transitions + tx
    begin : watch
        integer w;
        reg prev7;
        prev7 = 0;
        for (w = 0; w < 4000; w = w + 1) begin
            @(posedge ap_clk);
            if (w % 100 == 0) $display("t=%0t FSM=%h st7=%b st9=%b st18=%b", $time,
                dut.ap_CS_fsm, dut.ap_CS_fsm_state7, dut.ap_CS_fsm_state9, dut.ap_CS_fsm_state18);
            if (dut.ap_CS_fsm_state7) begin
                $display("t=%0t st7: tbin=%04x reg_vld=%b reg_dat=%04x mrxtrdy=%b mrxst=%0d mrxcnt=%0d", $time,
                    rx_stream_TDATA, dut.rx_stream_TVALID_int_regslice, dut.rx_stream_TDATA_int_regslice,
                    dut.grp_mac_rx_process_fu_1145.rx_stream_TREADY,
                    dut.grp_mac_rx_process_fu_1145.state_1, dut.grp_mac_rx_process_fu_1145.byte_cnt_1);
            end
            prev7 = dut.ap_CS_fsm_state7;
            if (dut.mac_rx_valid_reg_2119) $display("t=%0t MAC RX valid, ethertype=%h", $time, dut.mac_rx_ethertype_reg_2114);
            if (dut.ip_rx_valid_reg_2149) $display("t=%0t IP RX valid, proto=%h", $time, dut.ip_rx_protocol_reg_2128);
            if (tx_stream_TVALID && tx_stream_TREADY) $display("t=%0t TX byte %02x%s", $time, tx_stream_TDATA[7:0], tx_stream_TDATA[8] ? " LAST" : "");
        end
    end

    // Dump RX buffer (should contain SYN IP+TCP header)
    $display("=== RX buffer words 0..12 ===");
    for (k = 0; k < 13; k = k + 1)
        $display("  buf[%0d] = %08x", k, dut.buffer_r_U.udp_echo_buffer_r_RAM_2P_BRAM_1R1W_ram_u.ram[k]);
    $finish;
end

endmodule
