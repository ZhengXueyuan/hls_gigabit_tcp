// wrapper_tb.v — full-chain sim: wrapper_1g + HLS IP + UART + converter
// Drives a real ARP request into the RGMII RX pins, captures the RGMII TX
// pins (phy1_txc/txd/txctl), reconstructs the TX bytes from the DDR stream
// and verifies frame content + FCS + TXC toggling.
`timescale 1ns/1ps

module wrapper_tb;

reg reset_n = 0;
reg fpga_gclk = 0;
reg phy1_rxc = 0;
reg [3:0] phy1_rxd = 0;
reg phy1_rxctl = 0;
wire phy1_txc, phy1_txctl;
wire [3:0] phy1_txd;
wire rs232_tx;
wire led_d0, led_d1, led_d2, led_d3;

always #10 fpga_gclk = ~fpga_gclk;   // 50MHz
always #4  phy1_rxc  = ~phy1_rxc;    // 125MHz

wrapper_1g dut (
    .reset_n(reset_n),
    .fpga_gclk(fpga_gclk),
    .phy1_rxc(phy1_rxc),
    .phy1_rxd(phy1_rxd),
    .phy1_rxctl(phy1_rxctl),
    .phy1_txc(phy1_txc),
    .phy1_txd(phy1_txd),
    .phy1_txctl(phy1_txctl),
    .rs232_rx(1'b1),
    .rs232_tx(rs232_tx),
    .led_d0(led_d0),
    .led_d1(led_d1),
    .led_d2(led_d2),
    .led_d3(led_d3)
);

// ---------- TX capture: raw nibble stream + frame boundaries ----------
reg [3:0] nib_seq [0:8191];   // raw 4-bit samples in time order
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
    if (nib_active && nib_cnt < 8191) begin
        nib_seq[nib_cnt] = phy1_txd;
        nib_cnt = nib_cnt + 1;
    end
    txctl_lo = phy1_txctl;
end

always @(negedge phy1_txc) begin
    #1;
    if (nib_active && nib_cnt < 8191) begin
        nib_seq[nib_cnt] = phy1_txd;
        nib_cnt = nib_cnt + 1;
    end
    txctl_hi = phy1_txctl;
end

// frame detector from TXCTL (both DDR phases = TXEN)
always @(posedge phy1_txc) begin
    if (txctl_hi && txctl_lo) begin
        if (!nib_active) begin
            nib_active = 1;
            tx_frame_nib_start[tx_frame_cnt] = nib_cnt;
        end
    end else begin
        if (nib_active) begin
            nib_active = 0;
            tx_frame_nib_len[tx_frame_cnt] = nib_cnt - tx_frame_nib_start[tx_frame_cnt];
            tx_frame_len[tx_frame_cnt] = tx_frame_nib_len[tx_frame_cnt] / 2;
            $display("TXFRAME %0d nibbles=%0d bytes=%0d", tx_frame_cnt,
                     tx_frame_nib_len[tx_frame_cnt], tx_frame_len[tx_frame_cnt]);
            tx_frame_cnt = tx_frame_cnt + 1;
        end
    end
end

integer fi2;
integer mm;
integer found;
integer k;
integer fs, fe, flen;
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

// ---------- IP stream probes ----------
integer ip_rx_accepted = 0;
integer ip_tx_valid_cnt = 0;
reg [7:0] ip_tx_mon [0:64];
integer ip_tx_mon_n = 0;
always @(posedge dut.gmii_clk) begin
    if (dut.net_rx_valid && dut.net_rx_ready) ip_rx_accepted = ip_rx_accepted + 1;
    if (dut.net_tx_valid) begin
        ip_tx_valid_cnt = ip_tx_valid_cnt + 1;
        if (ip_tx_mon_n < 64) begin
            ip_tx_mon[ip_tx_mon_n] = dut.net_tx_data[7:0];
            ip_tx_mon_n = ip_tx_mon_n + 1;
        end
    end
end
integer e_txen_hi = 0;
always @(posedge dut.gmii_clk) if (dut.e_txen) e_txen_hi = e_txen_hi + 1;

// Definitive TX check: monitor the bridged GMII stream (e_txd/e_txen).
reg [7:0] e_tx_frames [0:4095];
integer e_tx_len = 0;
integer e_tx_frames_n = 0;
reg e_tx_writing = 0;
always @(posedge dut.gmii_clk) begin
    if (dut.e_txen) begin
        if (!e_tx_writing) begin
            e_tx_writing = 1;
            e_tx_len = 0;
        end
        if (e_tx_len < 4095) begin
            e_tx_frames[e_tx_len] = dut.e_txd;
            e_tx_len = e_tx_len + 1;
        end
    end else begin
        if (e_tx_writing) begin
            e_tx_writing = 0;
            // verify frame content + FCS
            crc = 32'hFFFFFFFF;
            for (k = 8; k < e_tx_len - 4; k = k + 1) crc32_byte_ref(e_tx_frames[k], crc);
            crc = crc ^ 32'hFFFFFFFF;
            fcs = {e_tx_frames[e_tx_len-4], e_tx_frames[e_tx_len-3],
                   e_tx_frames[e_tx_len-2], e_tx_frames[e_tx_len-1]};
            $display("GMII TXFRAME %0d len=%0d FCS %s (0x%08X)", e_tx_frames_n,
                     e_tx_len, (crc == fcs) ? "CORRECT" : "WRONG", crc);
            for (k = 0; k < e_tx_len && k < 24; k = k + 1)
                $display("  E[%0d] = %02X", k, e_tx_frames[k]);
            e_tx_frames_n = e_tx_frames_n + 1;
        end
    end
end

// ---------- RX monitor: what bytes does the wrapper deliver? ----------
reg [7:0] rx_mon [0:64];
integer rx_mon_n = 0;
always @(posedge dut.gmii_clk) begin
    if (dut.rx_dv_d1 && rx_mon_n < 64) begin
        rx_mon[rx_mon_n] = dut.rx_d1;
        rx_mon_n = rx_mon_n + 1;
    end
end

// ---------- RX stimulus: drive ARP request on RGMII RX ----------
reg [7:0] frame [0:60];
integer fi;
integer i;

task drive_byte;
    input [7:0] b;
    input is_last;
    integer phase;
    begin
        // Empirically determined: the nibble driven during the rxc HIGH phase
        // lands in the LOW byte position, so drive low nibble first (high
        // phase) and high nibble second (low phase).
        @(posedge phy1_rxc); #0.5;
        phy1_rxd = b[3:0]; phy1_rxctl = 1;
        @(negedge phy1_rxc); #0.5;
        phy1_rxd = b[7:4]; phy1_rxctl = 1;
    end
endtask

initial begin
    // build ARP request
    fi = 0;
    for (i = 0; i < 7; i = i + 1) begin frame[fi] = 8'h55; fi = fi + 1; end
    frame[fi] = 8'hD5; fi = fi + 1;
    for (i = 0; i < 6; i = i + 1) begin frame[fi] = 8'hFF; fi = fi + 1; end
    frame[fi] = 8'hAA; fi = fi + 1; frame[fi] = 8'hBB; fi = fi + 1;
    frame[fi] = 8'hCC; fi = fi + 1; frame[fi] = 8'hDD; fi = fi + 1;
    frame[fi] = 8'hEE; fi = fi + 1; frame[fi] = 8'hFF; fi = fi + 1;
    frame[fi] = 8'h08; fi = fi + 1; frame[fi] = 8'h06; fi = fi + 1;
    frame[fi] = 8'h00; fi = fi + 1; frame[fi] = 8'h01; fi = fi + 1;
    frame[fi] = 8'h08; fi = fi + 1; frame[fi] = 8'h00; fi = fi + 1;
    frame[fi] = 8'h06; fi = fi + 1; frame[fi] = 8'h04; fi = fi + 1;
    frame[fi] = 8'h00; fi = fi + 1; frame[fi] = 8'h01; fi = fi + 1;
    frame[fi] = 8'hAA; fi = fi + 1; frame[fi] = 8'hBB; fi = fi + 1;
    frame[fi] = 8'hCC; fi = fi + 1; frame[fi] = 8'hDD; fi = fi + 1;
    frame[fi] = 8'hEE; fi = fi + 1; frame[fi] = 8'hFF; fi = fi + 1;
    frame[fi] = 192; fi = fi + 1; frame[fi] = 168; fi = fi + 1;
    frame[fi] = 100; fi = fi + 1; frame[fi] = 1;   fi = fi + 1;
    for (i = 0; i < 6; i = i + 1) begin frame[fi] = 8'h00; fi = fi + 1; end
    frame[fi] = 192; fi = fi + 1; frame[fi] = 168; fi = fi + 1;
    frame[fi] = 100; fi = fi + 1; frame[fi] = 2;   fi = fi + 1;

    // reset
    #50;
    reset_n = 1;
    #100;

    // wait for IDELAYCTRL ready / MMCM locked (their FFs are in reset until then)
    repeat (100) @(posedge fpga_gclk);

    $display("FEEDING ARP request (%0d bytes) on RGMII RX", fi);
    for (i = 0; i < fi; i = i + 1) drive_byte(frame[i], (i == fi-1));
    // deassert RXDV
    @(negedge phy1_rxc); #2; phy1_rxd = 0; phy1_rxctl = 0;

    // wait for TX frames
    #600000;   // 600us — plenty for the reply (~µs) plus margin

    $display("TXC toggles = %0d", tx_txc_count);
    $display("IP rx accepted = %0d, IP tx valid cycles = %0d, e_txen high cycles = %0d",
             ip_rx_accepted, ip_tx_valid_cnt, e_txen_hi);
    $display("RX monitor: %0d bytes received by wrapper:", rx_mon_n);
    for (i = 0; i < rx_mon_n && i < 40; i = i + 1)
        $display("  RX[%0d] = %02X", i, rx_mon[i]);
    if (tx_frame_cnt == 0) begin
        $display("RESULT: NO TX FRAME AT PINS");
    end else begin
        $display("RESULT: %0d TX FRAME(S) at pins", tx_frame_cnt);
        // Reassemble each frame's bytes from its nibble range, try both
        // nibble pairings, check preamble + FCS.
        for (fi2 = 0; fi2 < tx_frame_cnt; fi2 = fi2 + 1) begin
            fs = tx_frame_nib_start[fi2];
            fe = fs + tx_frame_nib_len[fi2];
            // Find the D5 byte: nibble pair {5, D} at (k, k+1) with pairing
            // byte[j] = {nib[2j+1], nib[2j]}. The preamble = 7x55 before it,
            // so frame start (nibble) = k - 14.
            flen = -1;
            k = fs;
            while (k + 1 < fe && flen < 0) begin
                if (nib_seq[k] == 4'h5 && nib_seq[k+1] == 4'hD) begin
                    // verify 7 bytes of 55 precede it
                    found = 1;
                    for (mm = 0; mm < 14; mm = mm + 1)
                        if (nib_seq[k - 14 + mm] != 4'h5) found = 0;
                    if (found) begin
                        flen = (fe - (k - 14)) / 2;
                        for (mm = 0; mm < flen && mm < 4096; mm = mm + 1)
                            rb[mm] = {nib_seq[k - 14 + 2*mm + 1],
                                      nib_seq[k - 14 + 2*mm]};
                    end
                end
                k = k + 1;
            end
            if (flen < 0) begin
                // diagnostics: print the first 24 nibbles of the range
                $display("  first 24 nibbles:");
                for (mm = 0; mm < 24 && fs + mm < fe; mm = mm + 1)
                    $display("    nib[%0d] = %01X", fs + mm, nib_seq[fs + mm]);
            end
            if (flen < 0) begin
                $display("FRAME %0d: no preamble found in nibble range", fi2);
            end else begin
                crc = 32'hFFFFFFFF;
                for (k = 8; k < flen - 4; k = k + 1) crc32_byte_ref(rb[k], crc);
                crc = crc ^ 32'hFFFFFFFF;
                fcs = {rb[flen-4], rb[flen-3], rb[flen-2], rb[flen-1]};
                $display("FRAME %0d: %0d bytes, preamble OK, FCS %s (0x%08X)",
                         fi2, flen, (crc == fcs) ? "CORRECT" : "WRONG", crc);
            end
            for (i = 0; i < flen && i < 40; i = i + 1)
                $display("  B[%0d] = %02X", i, rb[i]);
        end
    end
    $finish;
end

endmodule
