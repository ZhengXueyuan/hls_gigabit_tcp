// rtl_tcp_tb.v — RTL-level debug of the TCP echo path
// Feeds: SYN (from 192.168.100.100:12345) -> ACK -> 536-byte data segment.
// Captures TX frames, dumps the payload RAM, checks echo content.
`timescale 1ns/1ps

module rtl_tcp_tb;

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


// ---------------- frame builders ----------------
reg [7:0] f [0:4095];
integer n;

// ---------------- helpers ----------------
integer k, i;
reg [7:0] tx_cap [0:4095];
integer cap_n = 0;
integer tx_total = 0;
integer rx_total = 0;
integer capture_on = 0;
integer frame_done = 0;

// capture next complete frame into tx_cap, returns byte count
task capture_frame(input integer max_wait);
begin
    capture_on = 0;
    cap_n = 0;
    frame_done = 0;
    begin : loop
        integer w;
        for (w = 0; w < max_wait && !frame_done; w = w + 1) begin
            @(posedge ap_clk);
            if (tx_stream_TVALID && tx_stream_TREADY) begin
                tx_total = tx_total + 1;
                tx_cap[cap_n] = tx_stream_TDATA[7:0];
                cap_n = cap_n + 1;
                if (tx_stream_TDATA[8]) frame_done = 1;
            end
        end
    end
end
endtask

// drain until no TX data for `quiet` consecutive cycles
task drain_tx(input integer quiet);
begin
    begin : loop
        integer d, q;
        q = 0;
        for (d = 0; d < 4000 && q < quiet; d = d + 1) begin
            @(posedge ap_clk);
            if (tx_stream_TVALID && tx_stream_TREADY) begin
                tx_total = tx_total + 1;
                q = 0;
            end else q = q + 1;
        end
    end
end
endtask

// feed a frame (with preamble) into rx_stream, one byte per cycle.
// Pacing mode: 0 = idle cycle between bytes (gapped), 1 = back-to-back.
integer feed_mode = 1;
task feed_frame(input integer fcnt);
begin
    begin : loop
        integer b;
        for (b = 0; b < fcnt; b = b + 1) begin
            rx_stream_TDATA = {(b == fcnt - 1), f[b]};   // bit8 = TLAST on last byte
            rx_stream_TVALID = 1;
            while (!rx_stream_TREADY) @(posedge ap_clk);
            rx_total = rx_total + 1;
            if (feed_mode == 0) begin
                @(posedge ap_clk);
                rx_stream_TVALID = 0;
                @(posedge ap_clk);
            end
        end
        rx_stream_TVALID = 0;
        @(posedge ap_clk);
        $display("feed done: %0d bytes driven (accepted=%0d)", fcnt, rx_total);
        rx_total = 0;
    end
end
endtask

// ---------------- checksum helpers ----------------
function [15:0] ip_csum_base;
    input integer base;
    integer s;
    begin
        s = 0;
        for (k = 0; k < 20; k = k + 2) s = s + ((f[base+k] << 8) | f[base+k+1]);
        while (s >> 16) s = (s & 16'hFFFF) + (s >> 16);
        ip_csum_base = ~s;
    end
endfunction

function [15:0] tcp_csum_base;
    input [31:0] sip;
    input [31:0] dip;
    input integer base;
    input integer seglen;
    integer s;
    begin
        s = 6 + seglen;
        s = s + ((sip >> 16) & 16'hFFFF) + (sip & 16'hFFFF);
        s = s + ((dip >> 16) & 16'hFFFF) + (dip & 16'hFFFF);
        for (k = 0; k < seglen - 1; k = k + 2) s = s + ((f[base+k] << 8) | f[base+k+1]);
        if (seglen & 1) s = s + (f[base+seglen-1] << 8);
        while (s >> 16) s = (s & 16'hFFFF) + (s >> 16);
        tcp_csum_base = ~s;
    end
endfunction

task build_syn;
begin
    n = 0;
    for (k = 0; k < 7; k = k + 1) f[n+k] = 8'h55; n = n + 7;
    f[n] = 8'hD5; n = n + 1;
    f[n]=8'h00;f[n+1]=8'h0A;f[n+2]=8'h35;f[n+3]=8'h01;f[n+4]=8'hFE;f[n+5]=8'hC0; n = n + 6;   // dst = board
    f[n]=8'h10;f[n+1]=8'h11;f[n+2]=8'h12;f[n+3]=8'h13;f[n+4]=8'h14;f[n+5]=8'h15; n = n + 6;   // src
    f[n]=8'h08;f[n+1]=8'h00; n = n + 2;
    f[n]=8'h45;f[n+1]=8'h00;f[n+2]=8'h00;f[n+3]=8'h28;          // IP total 40
    f[n+4]=8'h00;f[n+5]=8'h01;f[n+6]=8'h40;f[n+7]=8'h00;
    f[n+8]=8'h40;f[n+9]=8'h06;f[n+10]=8'h00;f[n+11]=8'h00;
    f[n+12]=8'hC0;f[n+13]=8'hA8;f[n+14]=8'h64;f[n+15]=8'h64;    // 192.168.100.100
    f[n+16]=8'hC0;f[n+17]=8'hA8;f[n+18]=8'h64;f[n+19]=8'h02;    // 192.168.100.2
    // IP checksum
    f[n+10] = ip_csum_base(n) >> 8; f[n+11] = ip_csum_base(n) & 8'hFF;
    // TCP
    f[n+20]=8'h30;f[n+21]=8'h39;                                 // src 12345
    f[n+22]=8'h00;f[n+23]=8'h07;                                 // dst 7
    f[n+24]=8'h10;f[n+25]=8'h00;f[n+26]=8'h00;f[n+27]=8'h00;     // seq
    f[n+28]=8'h00;f[n+29]=8'h00;f[n+30]=8'h00;f[n+31]=8'h00;     // ack 0
    f[n+32]=8'h50;f[n+33]=8'h02;f[n+34]=8'h20;f[n+35]=8'h00;     // doff5 SYN win8192
    f[n+36]=8'h00;f[n+37]=8'h00;f[n+38]=8'h00;f[n+39]=8'h00;     // csum urg
    f[n+40] = tcp_csum_base(32'hC0A86464, 32'hC0A86402, n+20, 20) >> 8;
    f[n+41] = tcp_csum_base(32'hC0A86464, 32'hC0A86402, n+20, 20) & 8'hFF;
    n = n + 42;
end
endtask

task build_ack;
begin
    n = 0;
    for (k = 0; k < 7; k = k + 1) f[n+k] = 8'h55; n = n + 7;
    f[n] = 8'hD5; n = n + 1;
    f[n]=8'h00;f[n+1]=8'h0A;f[n+2]=8'h35;f[n+3]=8'h01;f[n+4]=8'hFE;f[n+5]=8'hC0; n = n + 6;
    f[n]=8'h10;f[n+1]=8'h11;f[n+2]=8'h12;f[n+3]=8'h13;f[n+4]=8'h14;f[n+5]=8'h15; n = n + 6;
    f[n]=8'h08;f[n+1]=8'h00; n = n + 2;
    f[n]=8'h45;f[n+1]=8'h00;f[n+2]=8'h00;f[n+3]=8'h28;
    f[n+4]=8'h00;f[n+5]=8'h02;f[n+6]=8'h40;f[n+7]=8'h00;
    f[n+8]=8'h40;f[n+9]=8'h06;f[n+10]=8'h00;f[n+11]=8'h00;
    f[n+12]=8'hC0;f[n+13]=8'hA8;f[n+14]=8'h64;f[n+15]=8'h64;
    f[n+16]=8'hC0;f[n+17]=8'hA8;f[n+18]=8'h64;f[n+19]=8'h02;
    f[n+10] = ip_csum_base(n) >> 8; f[n+11] = ip_csum_base(n) & 8'hFF;
    f[n+20]=8'h30;f[n+21]=8'h39;
    f[n+22]=8'h00;f[n+23]=8'h07;
    f[n+24]=8'h10;f[n+25]=8'h00;f[n+26]=8'h00;f[n+27]=8'h01;    // seq 0x10000001
    f[n+28]=8'h12;f[n+29]=8'h34;f[n+30]=8'h56;f[n+31]=8'h79;    // ack 0x12345679
    f[n+32]=8'h50;f[n+33]=8'h10;f[n+34]=8'h20;f[n+35]=8'h00;
    f[n+36]=8'h00;f[n+37]=8'h00;f[n+38]=8'h00;f[n+39]=8'h00;
    f[n+40] = tcp_csum_base(32'hC0A86464, 32'hC0A86402, n+20, 20) >> 8;
    f[n+41] = tcp_csum_base(32'hC0A86464, 32'hC0A86402, n+20, 20) & 8'hFF;
    n = n + 42;
end
endtask

// 536-byte data segment
task build_data;
begin
    n = 0;
    for (k = 0; k < 7; k = k + 1) f[n+k] = 8'h55; n = n + 7;
    f[n] = 8'hD5; n = n + 1;
    f[n]=8'h00;f[n+1]=8'h0A;f[n+2]=8'h35;f[n+3]=8'h01;f[n+4]=8'hFE;f[n+5]=8'hC0; n = n + 6;
    f[n]=8'h10;f[n+1]=8'h11;f[n+2]=8'h12;f[n+3]=8'h13;f[n+4]=8'h14;f[n+5]=8'h15; n = n + 6;
    f[n]=8'h08;f[n+1]=8'h00; n = n + 2;
    // IP total = 20+20+536 = 576 = 0x240
    f[n]=8'h45;f[n+1]=8'h00;f[n+2]=8'h02;f[n+3]=8'h40;
    f[n+4]=8'h00;f[n+5]=8'h03;f[n+6]=8'h40;f[n+7]=8'h00;
    f[n+8]=8'h40;f[n+9]=8'h06;f[n+10]=8'h00;f[n+11]=8'h00;
    f[n+12]=8'hC0;f[n+13]=8'hA8;f[n+14]=8'h64;f[n+15]=8'h64;
    f[n+16]=8'hC0;f[n+17]=8'hA8;f[n+18]=8'h64;f[n+19]=8'h02;
    f[n+10] = ip_csum_base(n) >> 8; f[n+11] = ip_csum_base(n) & 8'hFF;
    f[n+20]=8'h30;f[n+21]=8'h39;
    f[n+22]=8'h00;f[n+23]=8'h07;
    f[n+24]=8'h10;f[n+25]=8'h00;f[n+26]=8'h00;f[n+27]=8'h01;    // seq 0x10000001
    f[n+28]=8'h12;f[n+29]=8'h34;f[n+30]=8'h56;f[n+31]=8'h79;    // ack 0x12345679
    f[n+32]=8'h50;f[n+33]=8'h18;f[n+34]=8'h20;f[n+35]=8'h00;
    f[n+36]=8'h00;f[n+37]=8'h00;f[n+38]=8'h00;f[n+39]=8'h00;
    for (k = 0; k < 536; k = k + 1) f[n+40+k] = k & 8'hFF;
    f[n+36] = tcp_csum_base(32'hC0A86464, 32'hC0A86402, n+20, 20+536) >> 8;
    f[n+37] = tcp_csum_base(32'hC0A86464, 32'hC0A86402, n+20, 20+536) & 8'hFF;
    n = n + 40 + 536;
end
endtask

// ---------------- main ----------------
initial begin
    $display("=== RTL TCP TB start ===");
    ap_rst_n = 0; reset_n = 0;
    repeat (20) @(posedge ap_clk);
    ap_rst_n = 1; reset_n = 1;
    repeat (50) @(posedge ap_clk);
    drain_tx(10);

    // SYN
    build_syn;
    feed_frame(n);
    capture_frame(20000);
    if (frame_done) $display("SYN-ACK frame: %0d bytes", cap_n);
    else $display("SYN-ACK: NO FRAME");
    drain_tx(20);

    // ACK
    build_ack;
    feed_frame(n);
    drain_tx(20);

    // 536-byte data segment
    build_data;
    $display("feeding data frame n=%0d", n);
    feed_frame(n);
    // capture 2 echo frames (472 + 64)
    begin : echo_cap
        integer fr;
        for (fr = 0; fr < 4; fr = fr + 1) begin
            capture_frame(20000);
            if (!frame_done) begin
                $display("frame %0d: NO FRAME (timeout)", fr);
            end else begin
                $display("frame %0d: %0d bytes", fr, cap_n);
                for (k = 62; k < cap_n && k < 62+96; k = k + 4)
                    $display("  cap[%0d..%0d] = %02x %02x %02x %02x", k, k+3,
                             tx_cap[k], tx_cap[k+1], tx_cap[k+2], tx_cap[k+3]);
            end
        end
    end
    drain_tx(10);
    // SECOND 536-byte data segment (seq 0x10000219, ack 0x12345891)
    begin : seg2
        integer nb;
        n = 0;
        for (k = 0; k < 7; k = k + 1) f[n+k] = 8'h55; n = n + 7;
        f[n] = 8'hD5; n = n + 1;
        f[n]=8'h00;f[n+1]=8'h0A;f[n+2]=8'h35;f[n+3]=8'h01;f[n+4]=8'hFE;f[n+5]=8'hC0; n = n + 6;
        f[n]=8'h10;f[n+1]=8'h11;f[n+2]=8'h12;f[n+3]=8'h13;f[n+4]=8'h14;f[n+5]=8'h15; n = n + 6;
        f[n]=8'h08;f[n+1]=8'h00; n = n + 2;
        f[n]=8'h45;f[n+1]=8'h00;f[n+2]=8'h02;f[n+3]=8'h40;
        f[n+4]=8'h00;f[n+5]=8'h04;f[n+6]=8'h40;f[n+7]=8'h00;
        f[n+8]=8'h40;f[n+9]=8'h06;f[n+10]=8'h00;f[n+11]=8'h00;
        f[n+12]=8'hC0;f[n+13]=8'hA8;f[n+14]=8'h64;f[n+15]=8'h64;
        f[n+16]=8'hC0;f[n+17]=8'hA8;f[n+18]=8'h64;f[n+19]=8'h02;
        f[n+10] = ip_csum_base(n) >> 8; f[n+11] = ip_csum_base(n) & 8'hFF;
        f[n+20]=8'h30;f[n+21]=8'h39;
        f[n+22]=8'h00;f[n+23]=8'h07;
        f[n+24]=8'h10;f[n+25]=8'h00;f[n+26]=8'h02;f[n+27]=8'h19;   // seq 0x10000219
        f[n+28]=8'h12;f[n+29]=8'h34;f[n+30]=8'h58;f[n+31]=8'h91;   // ack 0x12345891
        f[n+32]=8'h50;f[n+33]=8'h18;f[n+34]=8'h20;f[n+35]=8'h00;
        f[n+36]=8'h00;f[n+37]=8'h00;f[n+38]=8'h00;f[n+39]=8'h00;
        for (k = 0; k < 536; k = k + 1) f[n+40+k] = (k + 536) & 8'hFF;
        f[n+36] = tcp_csum_base(32'hC0A86464, 32'hC0A86402, n+20, 20+536) >> 8;
        f[n+37] = tcp_csum_base(32'hC0A86464, 32'hC0A86402, n+20, 20+536) & 8'hFF;
        nb = n + 40 + 536;
        $display("feeding data frame 2 n=%0d", nb);
        feed_frame(nb);
        for (k = 0; k < 4; k = k + 1) begin
            capture_frame(20000);
            if (!frame_done) begin
                $display("frame2 %0d: NO FRAME (timeout)", k);
            end else begin
                $display("frame2 %0d: %0d bytes", k, cap_n);
                for (i = 62; i < cap_n && i < 62+96; i = i + 4)
                    $display("  cap[%0d..%0d] = %02x %02x %02x %02x", i, i+3,
                             tx_cap[i], tx_cap[i+1], tx_cap[i+2], tx_cap[i+3]);
            end
        end
    end

    // SEG 3 (536B, seq 0x10000431, ack 0x12345a69) — consecutive arrival
    begin : seg3
        integer nb;
        n = 0;
        for (k = 0; k < 7; k = k + 1) f[n+k] = 8'h55; n = n + 7;
        f[n] = 8'hD5; n = n + 1;
        f[n]=8'h00;f[n+1]=8'h0A;f[n+2]=8'h35;f[n+3]=8'h01;f[n+4]=8'hFE;f[n+5]=8'hC0; n = n + 6;
        f[n]=8'h10;f[n+1]=8'h11;f[n+2]=8'h12;f[n+3]=8'h13;f[n+4]=8'h14;f[n+5]=8'h15; n = n + 6;
        f[n]=8'h08;f[n+1]=8'h00; n = n + 2;
        f[n]=8'h45;f[n+1]=8'h00;f[n+2]=8'h02;f[n+3]=8'h40;
        f[n+4]=8'h00;f[n+5]=8'h05;f[n+6]=8'h40;f[n+7]=8'h00;
        f[n+8]=8'h40;f[n+9]=8'h06;f[n+10]=8'h00;f[n+11]=8'h00;
        f[n+12]=8'hC0;f[n+13]=8'hA8;f[n+14]=8'h64;f[n+15]=8'h64;
        f[n+16]=8'hC0;f[n+17]=8'hA8;f[n+18]=8'h64;f[n+19]=8'h02;
        f[n+10] = ip_csum_base(n) >> 8; f[n+11] = ip_csum_base(n) & 8'hFF;
        f[n+20]=8'h30;f[n+21]=8'h39;
        f[n+22]=8'h00;f[n+23]=8'h07;
        f[n+24]=8'h10;f[n+25]=8'h00;f[n+26]=8'h04;f[n+27]=8'h31;   // seq 0x10000431
        f[n+28]=8'h12;f[n+29]=8'h34;f[n+30]=8'h5A;f[n+31]=8'h69;   // ack 0x12345a69
        f[n+32]=8'h50;f[n+33]=8'h18;f[n+34]=8'h20;f[n+35]=8'h00;
        f[n+36]=8'h00;f[n+37]=8'h00;f[n+38]=8'h00;f[n+39]=8'h00;
        for (k = 0; k < 536; k = k + 1) f[n+40+k] = (k + 1072) & 8'hFF;
        f[n+36] = tcp_csum_base(32'hC0A86464, 32'hC0A86402, n+20, 20+536) >> 8;
        f[n+37] = tcp_csum_base(32'hC0A86464, 32'hC0A86402, n+20, 20+536) & 8'hFF;
        nb = n + 40 + 536;
        $display("feeding data frame 3 n=%0d", nb);
        feed_frame(nb);
        for (k = 0; k < 4; k = k + 1) begin
            capture_frame(20000);
            if (!frame_done) begin
                $display("frame3 %0d: NO FRAME (timeout)", k);
            end else begin
                $display("frame3 %0d: %0d bytes", k, cap_n);
                for (i = 62; i < cap_n && i < 62+96; i = i + 4)
                    $display("  cap[%0d..%0d] = %02x %02x %02x %02x", i, i+3,
                             tx_cap[i], tx_cap[i+1], tx_cap[i+2], tx_cap[i+3]);
            end
        end
    end
    // SEG 4 (536B, seq 0x10000649, ack 0x12345c81) — consecutive arrival
    begin : seg4
        integer nb;
        n = 0;
        for (k = 0; k < 7; k = k + 1) f[n+k] = 8'h55; n = n + 7;
        f[n] = 8'hD5; n = n + 1;
        f[n]=8'h00;f[n+1]=8'h0A;f[n+2]=8'h35;f[n+3]=8'h01;f[n+4]=8'hFE;f[n+5]=8'hC0; n = n + 6;
        f[n]=8'h10;f[n+1]=8'h11;f[n+2]=8'h12;f[n+3]=8'h13;f[n+4]=8'h14;f[n+5]=8'h15; n = n + 6;
        f[n]=8'h08;f[n+1]=8'h00; n = n + 2;
        f[n]=8'h45;f[n+1]=8'h00;f[n+2]=8'h02;f[n+3]=8'h40;
        f[n+4]=8'h00;f[n+5]=8'h06;f[n+6]=8'h40;f[n+7]=8'h00;
        f[n+8]=8'h40;f[n+9]=8'h06;f[n+10]=8'h00;f[n+11]=8'h00;
        f[n+12]=8'hC0;f[n+13]=8'hA8;f[n+14]=8'h64;f[n+15]=8'h64;
        f[n+16]=8'hC0;f[n+17]=8'hA8;f[n+18]=8'h64;f[n+19]=8'h02;
        f[n+10] = ip_csum_base(n) >> 8; f[n+11] = ip_csum_base(n) & 8'hFF;
        f[n+20]=8'h30;f[n+21]=8'h39;
        f[n+22]=8'h00;f[n+23]=8'h07;
        f[n+24]=8'h10;f[n+25]=8'h00;f[n+26]=8'h06;f[n+27]=8'h49;   // seq 0x10000649
        f[n+28]=8'h12;f[n+29]=8'h34;f[n+30]=8'h5C;f[n+31]=8'h81;   // ack 0x12345c81
        f[n+32]=8'h50;f[n+33]=8'h18;f[n+34]=8'h20;f[n+35]=8'h00;
        f[n+36]=8'h00;f[n+37]=8'h00;f[n+38]=8'h00;f[n+39]=8'h00;
        for (k = 0; k < 536; k = k + 1) f[n+40+k] = (k + 1608) & 8'hFF;
        f[n+36] = tcp_csum_base(32'hC0A86464, 32'hC0A86402, n+20, 20+536) >> 8;
        f[n+37] = tcp_csum_base(32'hC0A86464, 32'hC0A86402, n+20, 20+536) & 8'hFF;
        nb = n + 40 + 536;
        $display("feeding data frame 4 n=%0d", nb);
        feed_frame(nb);
        for (k = 0; k < 4; k = k + 1) begin
            capture_frame(20000);
            if (!frame_done) begin
                $display("frame4 %0d: NO FRAME (timeout)", k);
            end else begin
                $display("frame4 %0d: %0d bytes", k, cap_n);
                for (i = 62; i < cap_n && i < 62+96; i = i + 4)
                    $display("  cap[%0d..%0d] = %02x %02x %02x %02x", i, i+3,
                             tx_cap[i], tx_cap[i+1], tx_cap[i+2], tx_cap[i+3]);
            end
        end
    end

    // dump payload RAM
    $display("=== payload RAM dump (first 64) ===");
    for (k = 0; k < 64; k = k + 1)
        $display("  payload[%0d] = %02x", k, dut.grp_tcp_rx_process_fu_1270.payload_U.ram[k]);
    // dump RX buffer words 8..12 and 140..147 (payload area + tail)
    $display("=== RX buffer words 8..12 ===");
    for (k = 8; k <= 12; k = k + 1)
        $display("  buf[%0d] = %08x", k, dut.buffer_r_U.udp_echo_buffer_r_RAM_2P_BRAM_1R1W_ram_u.ram[k]);
    $display("=== RX buffer words 140..147 ===");
    for (k = 140; k <= 147; k = k + 1)
        $display("  buf[%0d] = %08x", k, dut.buffer_r_U.udp_echo_buffer_r_RAM_2P_BRAM_1R1W_ram_u.ram[k]);

    $finish;
end

endmodule
