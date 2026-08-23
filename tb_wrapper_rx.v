//=============================================================================
// tb_wrapper_rx.v — reproduce the BOARD data path: line-rate GMII bytes into
// the wrapper's rx_fifo bridge, drained by the DUT at its own pace.
// Hypothesis: 4 back-to-back 536B frames (~2392B) overflow the 2048-deep
// rx_fifo (push gated at occ<1900) -> dropped bytes -> 4th-segment corruption.
// Feed at LINE RATE (1 byte/cycle, dv high during frame, IFG between frames).
//=============================================================================
`timescale 1ns/1ps

module tb_wrapper_rx;
    localparam MAXSTIM = 8192;

    reg clk = 0;
    reg rst_n = 0;

    // GMII line-rate input (mimics PHY->RGMII->GMII byte stream)
    reg  [7:0] gmii_rxd = 0;
    reg        gmii_rxdv = 0;

    // ---- 2-stage sync (as in wrapper_1g) ----
    reg [7:0] rx_d1, rx_d2; reg rx_dv_d1, rx_dv_d2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin rx_d1<=0;rx_d2<=0;rx_dv_d1<=0;rx_dv_d2<=0; end
        else begin rx_d1<=gmii_rxd; rx_d2<=rx_d1; rx_dv_d1<=gmii_rxdv; rx_dv_d2<=rx_dv_d1; end
    end

    // ---- rx_fifo bridge (verbatim from wrapper_1g) ----
    reg [8:0] rx_fifo [0:2047];
    reg [10:0] rx_wptr, rx_rptr;
    wire net_rx_ready;
    wire net_rx_valid;
    wire [15:0] net_rx_data;
    wire [10:0] rx_occ = rx_wptr - rx_rptr;
    wire rx_push = rx_dv_d2 && (rx_occ < 11'd1900);
    wire rx_last_in = rx_dv_d2 && !rx_dv_d1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rx_wptr <= 0;
        else if (rx_push) begin rx_fifo[rx_wptr] <= {rx_last_in, rx_d2}; rx_wptr <= rx_wptr + 1; end
    end
    wire rx_pop = net_rx_valid && net_rx_ready;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rx_rptr <= 0;
        else if (rx_pop) rx_rptr <= rx_rptr + 1;
    end
    assign net_rx_valid = (rx_occ > 0);
    assign net_rx_data  = {6'b0, rx_fifo[rx_rptr][8], rx_fifo[rx_rptr][7:0]};

    // overflow/drop tracker
    integer drop_cnt = 0;
    integer max_occ = 0;
    always @(posedge clk) begin
        if (rx_dv_d2 && !(rx_occ < 11'd1900)) drop_cnt = drop_cnt + 1;  // wanted to push but full
        if (rx_occ > max_occ) max_occ = rx_occ;
    end

    // ---- DUT ----
    wire [15:0] tx_data; wire tx_valid; reg tx_ready = 1;
    wire [15:0] msg_data; wire msg_valid; reg msg_ready = 1;
    udp_echo dut (
        .ap_clk(clk), .ap_rst_n(rst_n), .reset_n(rst_n),
        .rx_stream_TDATA(net_rx_data), .rx_stream_TVALID(net_rx_valid), .rx_stream_TREADY(net_rx_ready),
        .tx_stream_TDATA(tx_data), .tx_stream_TVALID(tx_valid), .tx_stream_TREADY(tx_ready),
        .msg_stream_TDATA(msg_data), .msg_stream_TVALID(msg_valid), .msg_stream_TREADY(msg_ready),
        .led_d0(), .led_d1(), .led_d2(), .led_d3()
    );

    always #4 clk = ~clk;

    // stimulus
    reg [7:0] stim_data [0:MAXSTIM-1];
    reg       stim_last [0:MAXSTIM-1];
    integer   NSTIM, i, code, l, d;
    initial begin
        i = 0;
        begin : load
            integer fd;
            fd = $fopen("stim.memh", "r");
            if (fd == 0) begin $display("ERROR open stim"); $finish; end
            while (!$feof(fd) && i < MAXSTIM) begin
                code = $fscanf(fd, "%d %h\n", l, d);
                if (code == 2) begin stim_last[i]=l[0]; stim_data[i]=d[7:0]; i=i+1; end
            end
            $fclose(fd);
        end
        NSTIM = i;
        $display("Loaded %0d stim bytes", NSTIM);
    end

    // capture TX
    integer fout, tx_count;
    always @(posedge clk) if (tx_valid && tx_ready) begin
        $fwrite(fout, "%0d %02x\n", tx_data[8], tx_data[7:0]); tx_count = tx_count + 1;
    end

    // force DHCP done so the DUT doesn't sit in the long DHCP-delay state
    // (same signal names Agent A verified in xsim)
    initial begin
        #1;
        force dut.dhcp_state = 3'd5;   // DHCP_DONE
        force dut.dhcp_reported = 1'b1;
    end

    // feed at LINE RATE: 1 byte/cycle while in a frame, IFG between frames
    integer idx, g;
    initial begin
        fout = $fopen("resp.memh", "w"); tx_count = 0;
        gmii_rxdv = 0; gmii_rxd = 0; rst_n = 0;
        repeat (40) @(posedge clk); rst_n = 1;
        repeat (200) @(posedge clk);
        idx = 0;
        while (idx < NSTIM) begin
            // present one byte for exactly one cycle (line rate)
            @(negedge clk);
            gmii_rxd  = stim_data[idx];
            gmii_rxdv = 1'b1;
            @(posedge clk);            // byte accepted into pipeline (sync stages)
            // if last byte of a frame, drop dv for IFG
            if (stim_last[idx]) begin
                @(negedge clk); gmii_rxdv = 1'b0; gmii_rxd = 0;
                for (g = 0; g < 12; g = g + 1) @(posedge clk);
            end
            idx = idx + 1;
        end
        @(negedge clk); gmii_rxdv = 0; gmii_rxd = 0;
        $display("Feeding done t=%0t tx_count=%0d", $time, tx_count);
        repeat (80000) @(posedge clk);
        $display("Final tx_count=%0d max_occ=%0d drop_cnt=%0d", tx_count, max_occ, drop_cnt);
        $fclose(fout);
        $display("TB_DONE");
        $finish;
    end

    initial begin
        #50000000;  // 50 ms guard
        $display("TIMEOUT tx_count=%0d max_occ=%0d drop_cnt=%0d", tx_count, max_occ, drop_cnt);
        $fclose(fout); $finish;
    end
endmodule
