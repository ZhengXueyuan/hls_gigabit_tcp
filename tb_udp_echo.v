//=============================================================================
// tb_udp_echo.v — xsim RTL testbench for the HLS udp_echo DUT
// Reproduces the board 2000B = 536*3+392 back-to-back TCP burst.
// Feeds stim.memh ("<last> <data_hex>" per line) into rx_stream respecting
// TREADY, captures tx_stream into resp.memh. Verilog-2001 (xsim xsim).
//=============================================================================
`timescale 1ns/1ps

module tb_udp_echo;

    localparam MAXSTIM = 8192;

    reg         clk = 0;
    reg         rst_n = 0;

    reg  [15:0] rx_data  = 0;
    reg         rx_valid = 0;
    wire        rx_ready;

    wire [15:0] tx_data;
    wire        tx_valid;
    reg         tx_ready = 1;

    wire [15:0] msg_data;
    wire        msg_valid;
    reg         msg_ready = 1;

    // DUT
    udp_echo dut (
        .ap_clk            (clk),
        .ap_rst_n          (rst_n),
        .reset_n           (rst_n),      // HLS-level soft reset (active low). MUST be driven;
                                          // leaving it floating makes reset_n=Z inside, phi muxes
                                          // collapse to 'bx and all sub-FSMs deadlock (xsim artifact).
        .rx_stream_TDATA   (rx_data),
        .rx_stream_TVALID  (rx_valid),
        .rx_stream_TREADY  (rx_ready),
        .tx_stream_TDATA   (tx_data),
        .tx_stream_TVALID  (tx_valid),
        .tx_stream_TREADY  (tx_ready),
        .msg_stream_TDATA  (msg_data),
        .msg_stream_TVALID (msg_valid),
        .msg_stream_TREADY (msg_ready),
        .led_d0(), .led_d1(), .led_d2(), .led_d3()
    );

    // 125 MHz clock
    always #4 clk = ~clk;

    // Stimulus storage
    reg [7:0] stim_data [0:MAXSTIM-1];
    reg       stim_last [0:MAXSTIM-1];
    integer   NSTIM;

    integer fout;
    integer tx_count;

    // Load stimulus
    integer i, code, l, d;
    initial begin
        NSTIM = 0;
        i = 0;
        begin : load
            integer fd;
            fd = $fopen("stim.memh", "r");
            if (fd == 0) begin $display("ERROR: cannot open stim.memh"); $finish; end
            while (!$feof(fd) && i < MAXSTIM) begin
                code = $fscanf(fd, "%d %h\n", l, d);
                if (code == 2) begin
                    stim_last[i] = l[0];
                    stim_data[i] = d[7:0];
                    i = i + 1;
                end
            end
            $fclose(fd);
        end
        NSTIM = i;
        $display("Loaded %0d stimulus bytes", NSTIM);
    end

    // TX monitor: capture every accepted byte
    always @(posedge clk) begin
        if (tx_valid && tx_ready) begin
            $fwrite(fout, "%0d %02x\n", tx_data[8], tx_data[7:0]);
            tx_count = tx_count + 1;
        end
    end

    // Debug: watch RX handshake for the first stretch
    integer mon_count;
    initial mon_count = 0;
    always @(posedge clk) begin
        if (mon_count < 40 && (rx_valid || rx_ready)) begin
            $display("  [mon] t=%0t rx_valid=%b rx_ready=%b rx_data=%04h", $time, rx_valid, rx_ready, rx_data);
            mon_count = mon_count + 1;
        end
    end

    // Debug: DUT internal FSM + mac_rx handshake transitions
    reg [32:0] prev_cs = 0;
    reg        prev_rxstart = 0;
    integer fsm_count;
    integer cyc;
    initial begin fsm_count = 0; cyc = 0; end
    always @(posedge clk) begin
        cyc = cyc + 1;
        if (fsm_count < 120 && (dut.ap_CS_fsm != prev_cs || dut.grp_mac_rx_process_fu_1209_ap_start != prev_rxstart)) begin
            $display("  [fsm] t=%0t cs=%h macrx_start=%b macrx_done=%b macrx_idle=%b rx_ready=%b ff_wr=%b",
                $time, dut.ap_CS_fsm,
                dut.grp_mac_rx_process_fu_1209_ap_start,
                dut.grp_mac_rx_process_fu_1209_ap_done,
                dut.grp_mac_rx_process_fu_1209_ap_idle,
                rx_ready,
                dut.grp_mac_rx_process_fu_1209_frame_fifo_write);
            prev_cs <= dut.ap_CS_fsm;
            prev_rxstart <= dut.grp_mac_rx_process_fu_1209_ap_start;
            fsm_count = fsm_count + 1;
        end
    end

    // Continuous throttled dump (every 64 cycles) of key FSM/consumer signals
    always @(posedge clk) begin
        if ((cyc % 64) == 0 && cyc > 200 && cyc < 4000) begin
            $display("  [dump] cyc=%0d cs=%h macrx_start=%b macrx_done=%b macrx_idle=%b rx_rdy=%b ff_wr=%b tx_v=%b",
                cyc, dut.ap_CS_fsm,
                dut.grp_mac_rx_process_fu_1209_ap_start,
                dut.grp_mac_rx_process_fu_1209_ap_done,
                dut.grp_mac_rx_process_fu_1209_ap_idle,
                rx_ready,
                dut.grp_mac_rx_process_fu_1209_frame_fifo_write,
                tx_valid);
        end
    end

    // regslice state probe: dump whenever the regslice handshakes a byte
    integer regslice_cnt;
    initial regslice_cnt = 0;
    always @(posedge clk) begin
        if ((rx_valid && rx_ready) && regslice_cnt < 20) begin
            $display("  [regslice] cyc=%0d IN byte=%02h | state=%b data_p1=%02h data_p2=%02h vld_out=%b ack_out=%b",
                cyc, rx_data[7:0],
                dut.regslice_both_rx_stream_U.state,
                dut.regslice_both_rx_stream_U.data_p1,
                dut.regslice_both_rx_stream_U.data_p2,
                dut.regslice_both_rx_stream_U.vld_out,
                dut.regslice_both_rx_stream_U.ack_out);
            regslice_cnt = regslice_cnt + 1;
        end
    end

    // Cycle-accurate regslice dump around the byte that gets lost
    always @(posedge clk) begin
        if (cyc >= 336 && cyc <= 368) begin
            $display("  [rs%0d] st=%b nx=%b vin=%b ain=%b aout=%b lp1=%b lp2=%b lfp2=%b p1=%02h p2=%02h vout=%b rx_v=%b rx_rdy=%b macrx_cs=%b mac_start=%b",
                cyc,
                dut.regslice_both_rx_stream_U.state,
                dut.regslice_both_rx_stream_U.next,
                dut.regslice_both_rx_stream_U.vld_in,
                dut.regslice_both_rx_stream_U.ack_in,
                dut.regslice_both_rx_stream_U.ack_out,
                dut.regslice_both_rx_stream_U.load_p1,
                dut.regslice_both_rx_stream_U.load_p2,
                dut.regslice_both_rx_stream_U.load_p1_from_p2,
                dut.regslice_both_rx_stream_U.data_p1,
                dut.regslice_both_rx_stream_U.data_p2,
                dut.regslice_both_rx_stream_U.vld_out,
                rx_valid, rx_ready,
                dut.grp_mac_rx_process_fu_1209.ap_CS_fsm,
                dut.grp_mac_rx_process_fu_1209_ap_start_reg);
        end
    end

    // mac_rx internals: dump state_1 / byte_cnt_1 / current byte every time mac_rx is started
    reg prev_macrx_start = 0;
    integer macrx_window_cnt;
    initial macrx_window_cnt = 0;
    always @(posedge clk) begin
        // When mac_rx is active, dump its internals each cycle (throttled to first 60 such cycles)
        if (dut.grp_mac_rx_process_fu_1209_ap_start_reg && macrx_window_cnt < 60) begin
            $display("  [macrx] cyc=%0d macrx_cs=%b state_1=%d byte_cnt_1=%0d rx_byte=%02h rx_v=%b rx_rdy=%b tmp_nbreq=%b rst_n=%b ff_wr=%b",
                cyc,
                dut.grp_mac_rx_process_fu_1209.ap_CS_fsm,
                dut.grp_mac_rx_process_fu_1209.state_1,
                dut.grp_mac_rx_process_fu_1209.byte_cnt_1,
                dut.grp_mac_rx_process_fu_1209.rx_byte_data_fu_740_p1,
                rx_valid, rx_ready,
                dut.grp_mac_rx_process_fu_1209.tmp_nbreadreq_fu_150_p3,
                dut.grp_mac_rx_process_fu_1209.reset_n,
                dut.grp_mac_rx_process_fu_1209.frame_fifo_write);
            macrx_window_cnt = macrx_window_cnt + 1;
        end
    end

    // Dense per-cycle dump around the hang window to see the exact stuck condition
    always @(posedge clk) begin
        if (cyc >= 230 && cyc <= 290) begin
            $display("  [D] cyc=%0d cs=%h dhcp_start=%b dhcp_done=%b dhcp_rdy=%b dhcp_idle=%b dhcp_cs=%h udp_done=%b",
                cyc, dut.ap_CS_fsm,
                dut.grp_dhcp_tx_process_fu_1472_ap_start,
                dut.grp_dhcp_tx_process_fu_1472_ap_done,
                dut.grp_dhcp_tx_process_fu_1472_ap_ready,
                dut.grp_dhcp_tx_process_fu_1472_ap_idle,
                dut.grp_dhcp_tx_process_fu_1472.ap_CS_fsm,
                dut.grp_udp_tx_process_fu_1499_ap_done);
        end
        // X-probe: dhcp internals at selected cycles
        if (cyc == 250 || cyc == 260 || cyc == 270 || cyc == 280) begin
            $display("  [X] cyc=%0d dhcp_cs=%h state1=%b reset_n=%b start_r=%b and_ln211=%b dhcp_state_i=%b empty_phi=%b timeout_phi=%b icmp_ln219=%b tmp=%h dhcp_timer_i=%h retry_phi=%b retry_cnt=%b",
                cyc,
                dut.grp_dhcp_tx_process_fu_1472.ap_CS_fsm,
                dut.grp_dhcp_tx_process_fu_1472.ap_CS_fsm_state1,
                dut.grp_dhcp_tx_process_fu_1472.reset_n,
                dut.grp_dhcp_tx_process_fu_1472.start_r,
                dut.grp_dhcp_tx_process_fu_1472.and_ln211_fu_519_p2,
                dut.grp_dhcp_tx_process_fu_1472.dhcp_state_i,
                dut.grp_dhcp_tx_process_fu_1472.ap_phi_mux_empty_phi_fu_235_p4,
                dut.grp_dhcp_tx_process_fu_1472.ap_phi_mux_timeout_phi_fu_224_p4,
                dut.grp_dhcp_tx_process_fu_1472.icmp_ln219_fu_535_p2,
                dut.grp_dhcp_tx_process_fu_1472.tmp_fu_525_p4,
                dut.grp_dhcp_tx_process_fu_1472.dhcp_timer_i,
                dut.grp_dhcp_tx_process_fu_1472.ap_phi_mux_retry_cnt_loc_0_phi_fu_213_p4,
                dut.grp_dhcp_tx_process_fu_1472.retry_cnt);
        end
    end

    // DHCP sub-FSM probe: log when started and its internal state while stuck
    reg [35:0] prev_dhcp_cs = 0;
    integer dhcp_fsm_cnt;
    initial dhcp_fsm_cnt = 0;
    always @(posedge clk) begin
        if (dut.grp_dhcp_tx_process_fu_1472.ap_CS_fsm != prev_dhcp_cs && dhcp_fsm_cnt < 60) begin
            $display("  [dhcp] t=%0t start=%b done=%b idle=%b dhcp_cs=%h",
                $time, dut.grp_dhcp_tx_process_fu_1472_ap_start,
                dut.grp_dhcp_tx_process_fu_1472_ap_done,
                dut.grp_dhcp_tx_process_fu_1472_ap_idle,
                dut.grp_dhcp_tx_process_fu_1472.ap_CS_fsm);
            prev_dhcp_cs <= dut.grp_dhcp_tx_process_fu_1472.ap_CS_fsm;
            dhcp_fsm_cnt = dhcp_fsm_cnt + 1;
        end
    end

    // Feed process
    integer idx;
    integer g;
    integer clkcnt;
    initial begin
        fout = $fopen("resp.memh", "w");
        tx_count = 0;
        rx_valid = 0; rx_data = 0; rst_n = 0;
        $display("[feed] process started, NSTIM=%0d", NSTIM);
        repeat (40) @(posedge clk);
        rst_n = 1;
        // Skip DHCP: force DUT into BOUND state so TCP echo runs without waiting
        // ~1e8 cycles (~0.8s sim time) for the first DHCP discover. This is a
        // testbench-side override of an internal register; functionally equivalent
        // to "the board already finished DHCP" (the real board case we reproduce).
        force dut.dhcp_state   = 3'd5;
        force dut.dhcp_reported = 1'b1;
        repeat (200) @(posedge clk);   // let DUT come out of reset / init
        $display("[feed] reset released, rx_ready=%b (dhcp_state forced to BOUND)", rx_ready);

        idx = 0;
        while (idx < NSTIM) begin
            // Drive stimulus on NEGEDGE so the DUT/regslice samples a STABLE value
            // on the following posedge. Updating rx_data at the same posedge that
            // the regslice latches it causes a Verilog race (the regslice can
            // capture the NEXT byte, silently dropping the current one).
            @(negedge clk);
            rx_data  = {6'b0, stim_last[idx], stim_data[idx]};
            rx_valid = 1'b1;
            // Wait until rx_ready is high at a negedge; the byte will then be
            // consumed at the NEXT posedge (value held stable across that edge).
            g = 0;
            while (rx_ready !== 1'b1) begin
                @(negedge clk);
                g = g + 1;
                if (g > 5000000) begin
                    $display("STALL: rx_ready low at idx=%0d byte=%02h t=%0t", idx, stim_data[idx], $time);
                    $fclose(fout); $finish;
                end
            end
            // transfer happens at the next posedge; deassert valid on the
            // following negedge (after the posedge has sampled it).
            @(posedge clk);
            @(negedge clk);
            rx_valid = 1'b0;
            // if this was the last byte of a frame, insert a small IFG gap
            if (stim_last[idx]) begin
                for (g = 0; g < 12; g = g + 1) @(negedge clk);
            end
            idx = idx + 1;
            if (idx < 12 || stim_last[idx-1]) $display("[feed] idx=%0d byte=%02h done t=%0t", idx, stim_data[idx-1], $time);
        end
        rx_valid = 1'b0;
        rx_data  = 0;
        $display("Feeding done @ %0t, tx_count so far=%0d", $time, tx_count);

        // drain echoes
        repeat (60000) @(posedge clk);
        $display("Final tx_count=%0d", tx_count);
        $fclose(fout);
        $display("TB_DONE");
        $finish;
    end

    // Global timeout guard
    initial begin
        #20000000;  // 20 ms
        $display("TIMEOUT");
        $fclose(fout);
        $finish;
    end

endmodule
