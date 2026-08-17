// wrapper_min_tb.v — wire-level check of wrapper_min (fixed FCS):
// captures the RGMII TX pins (DDR nibbles), reconstructs bytes, verifies
// preamble + FCS against the standard reflected CRC-32 reference.
`timescale 1ns/1ps
module wrapper_min_tb;
reg reset_n = 0;
reg fpga_gclk = 0;
reg phy1_rxc = 0;
reg [3:0] phy1_rxd = 0;
reg phy1_rxctl = 0;
wire phy1_txc, phy1_txctl;
wire [3:0] phy1_txd;
wire rs232_tx;
wire led_d0, led_d1, led_d2, led_d3;

always #10 fpga_gclk = ~fpga_gclk;
always #4  phy1_rxc  = ~phy1_rxc;

wrapper_min dut (
    .reset_n(reset_n), .fpga_gclk(fpga_gclk),
    .phy1_rxc(phy1_rxc), .phy1_rxd(phy1_rxd), .phy1_rxctl(phy1_rxctl),
    .phy1_txc(phy1_txc), .phy1_txd(phy1_txd), .phy1_txctl(phy1_txctl),
    .rs232_rx(1'b1), .rs232_tx(rs232_tx),
    .led_d0(led_d0), .led_d1(led_d1), .led_d2(led_d2), .led_d3(led_d3)
);

reg [3:0] nib_seq [0:8191];
integer nib_cnt = 0;
reg nib_active = 0;
reg [3:0] txctl_hi = 0, txctl_lo = 0;
integer tx_txc_count = 0;
integer tx_frame_cnt = 0;
integer tx_frame_nib_start [0:31];
integer tx_frame_nib_len  [0:31];
integer tx_frame_len [0:31];

always @(posedge phy1_txc) begin
    tx_txc_count = tx_txc_count + 1;
    #1;
    if (nib_active && nib_cnt < 8191) begin nib_seq[nib_cnt] = phy1_txd; nib_cnt = nib_cnt + 1; end
    txctl_lo = phy1_txctl;
end
always @(negedge phy1_txc) begin
    #1;
    if (nib_active && nib_cnt < 8191) begin nib_seq[nib_cnt] = phy1_txd; nib_cnt = nib_cnt + 1; end
    txctl_hi = phy1_txctl;
end
always @(posedge phy1_txc) begin
    if (txctl_hi && txctl_lo) begin
        if (!nib_active) begin nib_active = 1; tx_frame_nib_start[tx_frame_cnt] = nib_cnt; end
    end else begin
        if (nib_active) begin
            nib_active = 0;
            tx_frame_nib_len[tx_frame_cnt] = nib_cnt - tx_frame_nib_start[tx_frame_cnt];
            tx_frame_len[tx_frame_cnt] = tx_frame_nib_len[tx_frame_cnt] / 2;
            tx_frame_cnt = tx_frame_cnt + 1;
        end
    end
end

integer fi2, mm, found, k, fs, fe, flen;
reg [31:0] crc;
reg [31:0] fcs;
reg [7:0] rb [0:4095];
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
    #20 reset_n = 1;
    // wait for 3 frames (~3s + margin) then dump
    begin : waitloop integer li; for (li = 0; li < 4; li = li + 1) #10000000; end
    // wait until at least one frame captured, then some more
    wait (tx_frame_cnt >= 2);
    #200;
    $display("txc_edges=%0d frames=%0d", tx_txc_count, tx_frame_cnt);
    for (fi2 = 0; fi2 < tx_frame_cnt && fi2 < 4; fi2 = fi2 + 1) begin
        fs = tx_frame_nib_start[fi2];
        flen = tx_frame_len[fi2];
        $display("frame %0d: %0d bytes, first nibbles %X %X %X %X", fi2, flen,
                 nib_seq[fs], nib_seq[fs+1], nib_seq[fs+2], nib_seq[fs+3]);
        // rebuild bytes: nibble pairs — the wire carries the LOW nibble on
        // the rising edge and the HIGH nibble on the falling edge, so the
        // byte = {fall_nibble, rise_nibble}.
        for (mm = 0; mm < flen && mm < 200; mm = mm + 1)
            rb[mm] = {nib_seq[fs + 2*mm + 1], nib_seq[fs + 2*mm]};
        // check preamble
        // preamble at k>=0 (7x55+D5) OR one byte missed at k=0 (6x55+D5)
        found = -1;
        for (k = 0; k < flen - 8 && found < 0; k = k + 1)
            if (rb[k]==8'h55 && rb[k+1]==8'h55 && rb[k+2]==8'h55 && rb[k+3]==8'h55 &&
                rb[k+4]==8'h55 && rb[k+5]==8'h55 && rb[k+6]==8'h55 && rb[k+7]==8'hD5) found = k;
        if (found < 0 && flen >= 8 && rb[0]==8'h55 && rb[1]==8'h55 && rb[2]==8'h55 &&
            rb[3]==8'h55 && rb[4]==8'h55 && rb[5]==8'h55 && rb[6]==8'hD5) found = -2;
        $display("  first 24 bytes: %02X %02X %02X %02X %02X %02X %02X %02X %02X %02X %02X %02X %02X %02X %02X %02X %02X %02X %02X %02X %02X %02X %02X %02X",
                 rb[0],rb[1],rb[2],rb[3],rb[4],rb[5],rb[6],rb[7],rb[8],rb[9],rb[10],rb[11],
                 rb[12],rb[13],rb[14],rb[15],rb[16],rb[17],rb[18],rb[19],rb[20],rb[21],rb[22],rb[23]);
        if (found >= 0 && flen >= found + 72) begin
            crc = 32'hFFFFFFFF;
            for (mm = found + 8; mm < found + 68; mm = mm + 1) crc32_byte_ref(rb[mm], crc);
            crc = crc ^ 32'hFFFFFFFF;
            fcs = {rb[found+68], rb[found+69], rb[found+70], rb[found+71]};
            $display("  preamble@%0d FCS %s (computed %08X, sent %02X%02X%02X%02X)", found,
                     (crc == fcs) ? "CORRECT" : "WRONG", crc, rb[found+68], rb[found+69], rb[found+70], rb[found+71]);
        end else if (found == -2 && flen >= 71) begin
            // one preamble byte missed: rb = frame[1..71]
            crc = 32'hFFFFFFFF;
            for (mm = 7; mm < 67; mm = mm + 1) crc32_byte_ref(rb[mm], crc);
            crc = crc ^ 32'hFFFFFFFF;
            fcs = {rb[67], rb[68], rb[69], rb[70]};
            $display("  preamble shifted by 1 FCS %s (computed %08X, sent %02X%02X%02X%02X)",
                     (crc == fcs) ? "CORRECT" : "WRONG", crc, rb[67], rb[68], rb[69], rb[70]);
        end else begin
            $display("  no full frame (preamble@%0d len %0d)", found, flen);
        end
    end
    $finish;
end
endmodule
