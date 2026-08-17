// rtl_sim_tb.v — verify the SYNTHESIZED udp_echo IP TX frames (FCS check)
// Feeds a real ARP request into rx_stream, captures the ARP reply from
// tx_stream, then verifies the frame contents and the FCS (Ethernet CRC32).
`timescale 1ns/1ps

module rtl_sim_tb;

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

always #4 ap_clk = ~ap_clk;   // 125MHz

udp_echo dut (
    .ap_clk(ap_clk),
    .ap_rst_n(ap_rst_n),
    .reset_n(reset_n),
    .rx_stream_TDATA(rx_stream_TDATA),
    .rx_stream_TVALID(rx_stream_TVALID),
    .rx_stream_TREADY(rx_stream_TREADY),
    .tx_stream_TDATA(tx_stream_TDATA),
    .tx_stream_TVALID(tx_stream_TVALID),
    .tx_stream_TREADY(tx_stream_TREADY),
    .msg_stream_TDATA(msg_stream_TDATA),
    .msg_stream_TVALID(msg_stream_TVALID),
    .msg_stream_TREADY(msg_stream_TREADY),
    .led_d0(led_d0),
    .led_d1(led_d1),
    .led_d2(led_d2),
    .led_d3(led_d3)
);

// ---- RX accept counter ----
reg [7:0] rx_accept_buf [0:64];
integer rx_accept_n = 0;
always @(posedge ap_clk) begin
    if (rx_stream_TVALID && rx_stream_TREADY) begin
        if (rx_accept_n < 64) rx_accept_buf[rx_accept_n] = rx_stream_TDATA[7:0];
        rx_accept_n = rx_accept_n + 1;
    end
end

// ---- captured TX frames ----
reg [7:0] tx_buf [0:4095];
integer tx_cur = 0;          // next free slot
integer tx_frame_start [0:63];
integer tx_frame_len  [0:63];
integer frame_idx = 0;
integer tx_writing = 0;
integer k;

always @(posedge ap_clk) begin
    if (tx_stream_TVALID) begin
        if (!tx_writing) begin
            tx_frame_start[frame_idx] = tx_cur;
            tx_writing = 1;
        end
        tx_buf[tx_cur] = tx_stream_TDATA[7:0];
        if (tx_cur < 4095) tx_cur = tx_cur + 1;
        if (tx_stream_TDATA[8]) begin
            tx_frame_len[frame_idx] = tx_cur - tx_frame_start[frame_idx];
            $display("TXFRAME %0d len=%0d", frame_idx, tx_frame_len[frame_idx]);
            frame_idx = frame_idx + 1;
            tx_writing = 0;
        end
    end
end

// ---- stimulus ----
reg [7:0] frame [0:60];
integer fi, n, cyc;
integer i;
reg [31:0] crc;
reg [31:0] fcs;

task crc32_byte_ref;
    input [7:0] d;
    inout [31:0] c;
    integer biti;
    begin
        c = c ^ d;
        for (biti = 0; biti < 8; biti = biti + 1)
            c = (c & 1) ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
    end
endtask

initial begin
    // build ARP request (dest=FF*6, src=AA:BB:CC:DD:EE:FF, SPA=192.168.100.1 -> TPA=192.168.100.2)
    n = 0;
    for (i = 0; i < 7; i = i + 1) begin frame[n] = 8'h55; n = n + 1; end
    frame[n] = 8'hD5; n = n + 1;
    for (i = 0; i < 6; i = i + 1) begin frame[n] = 8'hFF; n = n + 1; end
    frame[n] = 8'hAA; n = n + 1; frame[n] = 8'hBB; n = n + 1;
    frame[n] = 8'hCC; n = n + 1; frame[n] = 8'hDD; n = n + 1;
    frame[n] = 8'hEE; n = n + 1; frame[n] = 8'hFF; n = n + 1;
    frame[n] = 8'h08; n = n + 1; frame[n] = 8'h06; n = n + 1;
    frame[n] = 8'h00; n = n + 1; frame[n] = 8'h01; n = n + 1;
    frame[n] = 8'h08; n = n + 1; frame[n] = 8'h00; n = n + 1;
    frame[n] = 8'h06; n = n + 1; frame[n] = 8'h04; n = n + 1;
    frame[n] = 8'h00; n = n + 1; frame[n] = 8'h01; n = n + 1;
    frame[n] = 8'hAA; n = n + 1; frame[n] = 8'hBB; n = n + 1;
    frame[n] = 8'hCC; n = n + 1; frame[n] = 8'hDD; n = n + 1;
    frame[n] = 8'hEE; n = n + 1; frame[n] = 8'hFF; n = n + 1;
    frame[n] = 192; n = n + 1; frame[n] = 168; n = n + 1;
    frame[n] = 100; n = n + 1; frame[n] = 1;   n = n + 1;
    for (i = 0; i < 6; i = i + 1) begin frame[n] = 8'h00; n = n + 1; end
    frame[n] = 192; n = n + 1; frame[n] = 168; n = n + 1;
    frame[n] = 100; n = n + 1; frame[n] = 2;   n = n + 1;

    repeat (20) @(posedge ap_clk);
    ap_rst_n <= 1; reset_n <= 1;
    repeat (20) @(posedge ap_clk);

    $display("FEEDING ARP request %0d bytes", n);
    for (fi = 0; fi < n; fi = fi + 1) begin
        rx_stream_TDATA <= {(fi == n - 1), frame[fi]};   // bit8 = TLAST on last byte
        rx_stream_TVALID <= 1;
        // wait until a cycle with TVALID && TREADY (bytes accepted)
        while (!rx_stream_TREADY) @(posedge ap_clk);
        @(posedge ap_clk);
        rx_stream_TVALID <= 0;
        @(posedge ap_clk);
    end
    rx_stream_TVALID <= 0;

    cyc = 0;
    while (frame_idx == 0 && cyc < 50000) begin
        @(posedge ap_clk);
        cyc = cyc + 1;
    end
    @(posedge ap_clk);
    repeat (200) @(posedge ap_clk);

    $display("rx_accept_n = %0d", rx_accept_n);
    for (i = 0; i < rx_accept_n && i < 40; i = i + 1)
        $display("  RX[%0d] = %02X", i, rx_accept_buf[i]);

    if (frame_idx == 0) begin
        $display("RESULT: NO TX FRAME EMITTED");
    end else begin
        // frame 0: preamble(8) + dst(6) + src(6) + et(2) + payload + fcs(4)
        $display("FRAME0 length = %0d bytes", tx_frame_len[0]);
        for (i = 0; i < tx_frame_len[0] && i < 64; i = i + 1)
            $display("  B[%0d] = %02X", i, tx_buf[tx_frame_start[0] + i]);
        if (tx_frame_len[0] >= 12) begin
            // verify FCS over bytes [8 .. len-5]
            crc = 32'hFFFFFFFF;
            for (i = 8; i < tx_frame_len[0] - 4; i = i + 1)
                crc32_byte_ref(tx_buf[tx_frame_start[0] + i], crc);
            crc = crc ^ 32'hFFFFFFFF;
            fcs = {tx_buf[tx_frame_start[0] + tx_frame_len[0] - 4],
                   tx_buf[tx_frame_start[0] + tx_frame_len[0] - 3],
                   tx_buf[tx_frame_start[0] + tx_frame_len[0] - 2],
                   tx_buf[tx_frame_start[0] + tx_frame_len[0] - 1]};
            $display("computed FCS = %08X  on-wire FCS = %08X", crc, fcs);
            if (crc == fcs) $display("RESULT: FCS CORRECT");
            else            $display("RESULT: FCS WRONG  ***");
        end
    end
    $finish;
end

endmodule
