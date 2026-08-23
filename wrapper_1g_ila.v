`timescale 1ns/1ps
//=============================================================================
// wrapper_1g.v — udp_echo + uart_console, PHY1 (ETH1) @1G link
//               k720-demo RGMII recipe + AXI-stream frame-buffer bridges
//=============================================================================
// PHY1 = AB2 pin group (bank 34, LVCMOS18): rxc=AB2, rxd=AE2/AE1/AC1/AC2,
// rxctl=AF3, txc=AB1, txd=AB4/AA4/AA3/AA2, txctl=Y3. Link = 1G (125MHz).
//
// k720 DEMO RGMII RECIPE (board-verified; bare IDDR on raw RXC tops out
// ~1/15 ping):
//   RX: RXC → LUT1 invert → BUFG → gmii_clk; RXD[3:0]+RXCTL through
//       IDELAYE2 (FIXED, value=10 ≈ 1.56ns @200MHz ref); IDDR
//       SAME_EDGE_PIPELINED on gmii_clk, byte = {Q2, Q1}; one re-register
//       stage; rx_er = dv ^ ctl.
//   TX: SAME gmii_clk. TXD ODDR: D1 = 2-cycle-delayed byte's low nibble,
//       D2 = 2-cycle-delayed byte's HIGH nibble (the demo's registered
//       "gmii_txd_low" reads the OLD txd_r — same byte on both edges,
//       classic RGMII DDR). TXCTL: D1 = D2 = tx_en delayed 2.
//       TXC = ODDR(1,0) forward of gmii_clk.
//   IDELAYCTRL ref = 200MHz from MMCME2_BASE (50MHz gclk ×20 VCO=1000MHz,
//   ÷5). IODELAY_GROUP "idelay" on all delay cells. No MDIO, no RGMII
//   timing constraints (works by construction, like the demo).
//
// AXI-STREAM FRAME-BUFFER BRIDGES (the HLS IP is call-based; its TVALID
// drops between bytes mid-frame and its TREADY is only high when its outer
// FSM is in the RX state — passing the wire signals straight through
// fragments every TX frame and drops RX bytes. Board proof: ?txd showed the
// IP's 4-consecutive-cycle CRC run "00 00 00 12(last)" instead of the
// gapped preamble; the PC NIC never saw a whole frame):
//   RX: 2048×9 FIFO (wire-rate bytes in; drained at the IP's TREADY pace).
//   TX: 2048×9 FIFO (frame-buffered; TLAST=TDATA[8] marks frame end; a
//       complete frame is emitted CONTIGUOUSLY, one byte per cycle, then
//       TXEN drops for a proper inter-frame gap).
//
// Debug: net_stats "?net" (frame counters + lock), "?txd" (first 8 bytes
// of last bridged TX frame), "?rxd" (first 8 bytes of last wire RX frame).
// LEDs D2=IDELAYCTRL RDY, D3=MMCM ref locked.
//=============================================================================

module wrapper_1g_ila (
    input           reset_n,        // async reset, active low (KEY1)
    input           fpga_gclk,      // 50MHz board oscillator (UART + MMCM ref)
    // RGMII RX from PHY (RTL8211E)
    input           phy1_rxc,       // RX clock (125MHz @1G link)
    input  [3:0]    phy1_rxd,       // RX data (DDR)
    input           phy1_rxctl,     // RX control (DDR: rising=RXDV, falling=RXDV^RXER)
    // RGMII TX to PHY
    output          phy1_txc,       // TX clock to PHY
    output [3:0]    phy1_txd,       // TX data (DDR)
    output          phy1_txctl,     // TX control (DDR: rising=TXEN, falling=TXEN^TXER)
    // UART
    input           rs232_rx,
    output          rs232_tx,
    // LEDs
    output          led_d0,
    output          led_d1,
    output          led_d2,
    output          led_d3
);

    // NOTE: no mdc/mdio/nrst ports — the k720 demo drives ONLY the 12 RGMII
    // pins (verified in its top level); the R3-schematic pin map for
    // MDC/MDIO/nRST (W4/W1/V1) does not match the physical board, and
    // driving unknown pins risks overriding PHY strap resistors. Unused
    // pins float via the bitstream's UNUSEDPIN Pullup, same as the demo.

    // --- 200MHz IDELAYCTRL reference: MMCM from 50MHz board clock ---
    // 50 × 20 = 1000MHz VCO; ÷5 = 200MHz. CLKFBIN closed (open loop never
    // locks). Kintex-7 VCO range 600-1440MHz.
    wire ref200_clk, ref200_clk_raw, ref200_fb, mmcm_ref_locked;
    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKIN1_PERIOD(20.0),          // 50MHz board oscillator
        .CLKFBOUT_MULT_F(20.0),        // VCO = 50 × 20 = 1000MHz
        .CLKFBOUT_PHASE(0.0),
        .DIVCLK_DIVIDE(1),
        .CLKOUT0_DIVIDE_F(5.0),        // 1000/5 = 200MHz
        .CLKOUT0_DUTY_CYCLE(0.5),
        .CLKOUT0_PHASE(0.0),
        .CLKOUT1_DIVIDE(1), .CLKOUT1_DUTY_CYCLE(0.5), .CLKOUT1_PHASE(0.0),
        .CLKOUT2_DIVIDE(1), .CLKOUT2_DUTY_CYCLE(0.5), .CLKOUT2_PHASE(0.0),
        .CLKOUT3_DIVIDE(1), .CLKOUT3_DUTY_CYCLE(0.5), .CLKOUT3_PHASE(0.0),
        .CLKOUT4_DIVIDE(1), .CLKOUT4_DUTY_CYCLE(0.5), .CLKOUT4_PHASE(0.0),
        .CLKOUT5_DIVIDE(1), .CLKOUT5_DUTY_CYCLE(0.5), .CLKOUT5_PHASE(0.0),
        .CLKOUT6_DIVIDE(1), .CLKOUT6_DUTY_CYCLE(0.5), .CLKOUT6_PHASE(0.0),
        .REF_JITTER1(0.010),
        .STARTUP_WAIT("FALSE")
    ) u_mmcm_ref (
        .CLKIN1(fpga_gclk),
        .CLKOUT0(ref200_clk_raw),
        .CLKOUT0B(),
        .CLKOUT1(), .CLKOUT1B(),
        .CLKOUT2(), .CLKOUT2B(),
        .CLKOUT3(), .CLKOUT3B(),
        .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
        .CLKFBOUT(ref200_fb),
        .CLKFBOUTB(),
        .CLKFBIN(ref200_fb),           // feedback loop MUST be closed
        .LOCKED(mmcm_ref_locked),
        .PWRDWN(1'b0),
        .RST(!reset_n)
    );
    BUFG u_bufg_200 (.I(ref200_clk_raw), .O(ref200_clk));

    wire delay_ready;
    (* IODELAY_GROUP = "idelay" *) IDELAYCTRL u_idelayctrl (
        .RDY(delay_ready),
        .REFCLK(ref200_clk),
        .RST(1'b0)
    );

    // --- RGMII adapter: the k720 demo's util_gmii_to_rgmii.v VERBATIM ---
    // Includes its own BUFG(inverted RXC) + IDELAYE2(10) + IDDR/ODDR chain
    // and exposes gmii_rx_clk for the whole design. speed=2'b10 (gigabit),
    // duplex=1, reset tied off (like the demo's ethernet_test.v).
    wire gmii_clk;
    wire [7:0] e_rxd;
    wire       e_rxdv, e_rxer;
    wire [7:0] e_txd;     // bridged TX byte (assigned in the FIFO section)
    wire       e_txen;    // bridged TX enable (assigned in the FIFO section)
    reg        tx_draining;   // bridge drain state (assigned in FIFO section)

    // --- DEMO-CLONE frame generator: k720 ipsend clone, 72B GMII frame @1Hz ---
    // Sends the EXACT frame the demo sends (preamble 55x7 D5, dst FFx6,
    // src 00:0A:35:01:FE:C0, ARP who-has 192.168.0.3, 46B payload incl.
    // padding, correct FCS) once per second, whenever the HLS bridge is
    // idle. Purpose: decide whether "PC sees nothing" is caused by our
    // frame cadence/content or by something environmental (power/noise).
    function [31:0] eth_crc32;
        // FIXED 2026-08-18: the old unreflected (MSB-first) CRC emitted the
        // bit-reversed FCS on the wire (21 27 d6 68 instead of the correct
        // 63 f9 a3 ca for the demo ARP frame) — the PC NIC silently dropped
        // every demo-clone frame as an FCS error. This is the standard
        // reflected CRC-32 (IEEE 802.3, same as zlib.crc32); wire order of
        // the final complement stays MSB-first per byte.
        input [31:0] crc;
        input [7:0]  data;
        reg [31:0] c;
        integer k;
        begin
            c = crc ^ data;
            for (k = 0; k < 8; k = k + 1) begin
                if (c[0]) c = (c >> 1) ^ 32'hEDB88320;
                else      c = (c >> 1);
            end
            eth_crc32 = c;
        end
    endfunction

    function [7:0] demo_byte;
        input [6:0] idx;
        begin
            case (idx)
                7'd0, 7'd1, 7'd2, 7'd3, 7'd4, 7'd5, 7'd6: demo_byte = 8'h55;
                7'd7:                                     demo_byte = 8'hD5;
                7'd8, 7'd9, 7'd10, 7'd11, 7'd12, 7'd13:  demo_byte = 8'hFF;
                7'd14: demo_byte = 8'h00; 7'd15: demo_byte = 8'h0A;
                7'd16: demo_byte = 8'h35; 7'd17: demo_byte = 8'h01;
                7'd18: demo_byte = 8'hFE; 7'd19: demo_byte = 8'hC0;
                7'd20: demo_byte = 8'h08; 7'd21: demo_byte = 8'h06;
                7'd22: demo_byte = 8'h00; 7'd23: demo_byte = 8'h01;
                7'd24: demo_byte = 8'h08; 7'd25: demo_byte = 8'h00;
                7'd26: demo_byte = 8'h06; 7'd27: demo_byte = 8'h04;
                7'd28: demo_byte = 8'h00; 7'd29: demo_byte = 8'h01;
                7'd30: demo_byte = 8'h00; 7'd31: demo_byte = 8'h0A;
                7'd32: demo_byte = 8'h35; 7'd33: demo_byte = 8'h01;
                7'd34: demo_byte = 8'hFE; 7'd35: demo_byte = 8'hC0;
                7'd36: demo_byte = 8'hC0; 7'd37: demo_byte = 8'hA8;
                7'd38: demo_byte = 8'h00; 7'd39: demo_byte = 8'h02;
                7'd40, 7'd41, 7'd42, 7'd43, 7'd44, 7'd45: demo_byte = 8'hFF;
                7'd46: demo_byte = 8'hC0; 7'd47: demo_byte = 8'hA8;
                7'd48: demo_byte = 8'h00; 7'd49: demo_byte = 8'h03;
                7'd50, 7'd51, 7'd52, 7'd53, 7'd54, 7'd55, 7'd56, 7'd57, 7'd58, 7'd59:
                    demo_byte = 8'h00;
                default: demo_byte = 8'h00;
            endcase
        end
    endfunction

    reg [26:0] demo_cnt;
    reg [6:0]  demo_idx;     // 0..71 (8 preamble + 60 frame + 4 FCS)
    reg        demo_sending;
    reg [31:0] demo_crc;
    wire       demo_tick = (demo_cnt == 27'd124999999);
    always @(posedge gmii_clk or negedge reset_n) begin
        if (!reset_n) begin
            demo_cnt<=0; demo_idx<=0; demo_sending<=0; demo_crc<=32'hFFFFFFFF;
        end else begin
            if (demo_cnt >= 27'd124999999) demo_cnt <= 27'd0;
            else                            demo_cnt <= demo_cnt + 27'd1;
            if (demo_tick && !tx_draining && !demo_sending) begin
                demo_sending <= 1'b1;
                demo_idx     <= 7'd0;
                demo_crc     <= 32'hFFFFFFFF;
            end else if (demo_sending) begin
                if (demo_idx >= 7'd8 && demo_idx < 7'd68)
                    demo_crc <= eth_crc32(demo_crc, demo_byte(demo_idx));
                if (demo_idx == 7'd71) demo_sending <= 1'b0;
                demo_idx <= demo_idx + 7'd1;
            end
        end
    end
    wire [31:0] demo_fcs = ~demo_crc;   // final complement, MSB-first on wire
    wire [7:0] demo_out =
        (demo_idx < 7'd68) ? demo_byte(demo_idx) :
        // FIX 2026-08-18 #2: the board's PHY/NIC chain expects the FCS in
        // LSB-first byte order (demo's wire FCS = CA A3 F9 63 = zlib register
        // little-endian). MSB-first (63 F9 A3 CA) frames were silently dropped.
        (demo_idx == 7'd68) ? demo_fcs[7:0]  :
        (demo_idx == 7'd69) ? demo_fcs[15:8] :
        (demo_idx == 7'd70) ? demo_fcs[23:16] :
                              demo_fcs[31:24];

    // Mux: demo clone has priority; HLS bridge frames wait (bridge backs
    // up in the FIFO while the 72-cycle demo frame goes out).
    wire [7:0] gmii_txd_sel = demo_sending ? demo_out : e_txd;
    wire       gmii_txen_sel = demo_sending ? 1'b1   : e_txen;

    util_gmii_to_rgmii u_rgmii (
        .reset          (1'b0),
        .rgmii_td       (phy1_txd),
        .rgmii_tx_ctl   (phy1_txctl),
        .rgmii_txc      (phy1_txc),
        .rgmii_rd_i     (phy1_rxd),
        .rgmii_rx_ctl_i (phy1_rxctl),
        .gmii_rx_clk    (gmii_clk),
        .rgmii_rxc      (phy1_rxc),
        .gmii_txd       (gmii_txd_sel),
        .gmii_tx_en     (gmii_txen_sel),
        .gmii_tx_er     (1'b0),
        .gmii_tx_clk    (),
        .gmii_crs       (),
        .gmii_col       (),
        .gmii_rxd       (e_rxd),
        .gmii_rx_dv     (e_rxdv),
        .gmii_rx_er     (e_rxer),
        .speed_selection(2'b10),   // gigabit
        .duplex_mode    (1'b1)     // full duplex
    );

    // --- LED logic ---
    wire led_d0_hls, led_d1_hls, led_d2_hls, led_d3_hls;  // raw HLS outputs
    // D2/D3 repurposed for this debug build: IDELAYCTRL RDY / MMCM locked.
    wire resp_active_wire;
    assign led_d1 = resp_active_wire;
    assign led_d2 = delay_ready;
    assign led_d3 = mmcm_ref_locked;

    // D0 = UART RX activity: lights 2s after a COMPLETE byte is received
    wire rx_done_pulse;
    reg [26:0] rx_act_cnt;   // 2s @ 50MHz = 100M cycles (27-bit)
    always @(posedge fpga_gclk or negedge reset_n) begin
        if (!reset_n) rx_act_cnt <= 27'd0;
        else if (rx_done_pulse) rx_act_cnt <= 27'd100000000;
        else if (rx_act_cnt > 0) rx_act_cnt <= rx_act_cnt - 27'd1;
    end
    assign led_d0 = (rx_act_cnt > 0);

    // --- Network IP signals (@gmii_clk) ---
    wire [15:0] net_rx_data, net_tx_data;
    wire        net_rx_valid, net_rx_ready, net_tx_valid, net_tx_ready;
    wire [15:0] net_msg_data;
    wire        net_msg_valid, net_msg_ready;

    // RX: GMII → 1-cycle register (wire-side byte + last flag)
    reg [7:0]  rx_d1, rx_d2; reg rx_dv_d1, rx_dv_d2;
    always @(posedge gmii_clk or negedge reset_n) begin
        if (!reset_n) begin rx_d1<=0;rx_d2<=0;rx_dv_d1<=0;rx_dv_d2<=0; end
        else begin rx_d1<=e_rxd;rx_d2<=rx_d1;rx_dv_d1<=e_rxdv;rx_dv_d2<=rx_dv_d1; end
    end

    // --- RX FIFO bridge: wire-rate bytes in, IP-paced bytes out ---
    // The HLS IP's rx_stream_TREADY is only high when its outer FSM is in
    // the RX state — passing wire bytes straight through would overwrite
    // its 1-deep input regslice and drop most of every frame.
    // FIX 2026-08-23 (ILA-proven): 2048→4096. The DUT drains at ~1 byte/20cy
    // (pass-structured FSM), so a 4-segment back-to-back TCP burst (4×602B)
    // filled the 2048 FIFO past the occ<1900 gate mid-segment-4 → the gate
    // dropped ~275B of seg4's middle and subsampled its tail at stride ~21
    // (the "乱序" signature). 4096 covers the 4-seg burst (peak occ ~2400);
    // gate 3900. NOTE: bursts >6 segments still overflow — the real fix is a
    // wire-rate-capable DUT drain, which is HLS-side.
    reg [8:0] rx_fifo [0:4095];     // {last, data}
    reg [11:0] rx_wptr, rx_rptr;
    wire [11:0] rx_occ = rx_wptr - rx_rptr;
    wire rx_push = rx_dv_d2 && (rx_occ < 12'd3900);
    wire rx_last_in = rx_dv_d2 && !rx_dv_d1;   // dv fell right after this byte
    always @(posedge gmii_clk or negedge reset_n) begin
        if (!reset_n) rx_wptr <= 12'd0;
        else if (rx_push) begin
            rx_fifo[rx_wptr] <= {rx_last_in, rx_d2};
            rx_wptr <= rx_wptr + 12'd1;
        end
    end
    wire rx_pop = net_rx_valid && net_rx_ready;
    always @(posedge gmii_clk or negedge reset_n) begin
        if (!reset_n) rx_rptr <= 12'd0;
        else if (rx_pop) rx_rptr <= rx_rptr + 12'd1;
    end
    assign net_rx_valid = (rx_occ > 0);
    assign net_rx_data  = {6'b0, rx_fifo[rx_rptr][8], rx_fifo[rx_rptr][7:0]};

    // --- TX FIFO bridge: buffer whole frames, emit contiguous ---
    // The HLS IP's TVALID drops between bytes (its FSM reads the preamble
    // ROM / payload buffer between writes). Emitting those gaps as TXEN
    // low would fragment the frame on the wire (idle mid-frame). Instead
    // we buffer each frame (TLAST = TDATA[8] marks the end) and drain it
    // as one continuous byte stream.
    reg [8:0] tx_fifo [0:2047];     // {last, data}
    reg [10:0] tx_wptr, tx_rptr;
    reg [10:0] tx_frame_cnt;        // complete frames in the FIFO
    reg        tx_draining;
    reg [3:0]  tx_gap;              // inter-frame gap counter (≥12 bytes)
    wire [10:0] tx_occ = tx_wptr - tx_rptr;
    assign net_tx_ready = (tx_occ < 11'd1900);
    // CLEAN POWER TEST: when the HLS IP is held in reset (ip_enable=0) its
    // TX regslice glitches garbage frames onto net_tx_valid. Gate tx_push
    // so the bridge never accepts them — the ONLY wire traffic is then the
    // demo-clone generator at 1Hz (plus idle IFG, no PHY-link disturbance).
    wire tx_push = ip_enable && net_tx_valid && net_tx_ready;
    wire [8:0] tx_push_word = {net_tx_data[8], net_tx_data[7:0]};
    wire tx_emit_last = tx_draining && tx_fifo[tx_rptr][8];
    wire tx_push_last = tx_push && tx_push_word[8];

    always @(posedge gmii_clk or negedge reset_n) begin
        if (!reset_n) tx_wptr <= 11'd0;
        else if (tx_push) begin
            tx_fifo[tx_wptr] <= tx_push_word;
            tx_wptr <= tx_wptr + 11'd1;
        end
    end

    always @(posedge gmii_clk or negedge reset_n) begin
        if (!reset_n) begin
            tx_rptr <= 11'd0; tx_draining <= 1'b0; tx_frame_cnt <= 11'd0;
            tx_gap <= 4'd12;
        end else begin
            if (tx_draining) begin
                tx_rptr <= tx_rptr + 11'd1;
                if (tx_fifo[tx_rptr][8] && tx_frame_cnt == 11'd1) begin
                    tx_draining <= 1'b0;          // last byte of last frame
                    tx_gap <= 4'd12;              // enforce ≥12-byte IFG
                end
            end else begin
                if (tx_gap > 0) tx_gap <= tx_gap - 4'd1;
                if (tx_frame_cnt > 0 && tx_gap == 4'd0)
                    tx_draining <= 1'b1;          // emit starts next cycle
            end
            // frame count delta: +1 on push-last, -1 on emit-last
            if (tx_push_last && !tx_emit_last)
                tx_frame_cnt <= tx_frame_cnt + 11'd1;
            else if (!tx_push_last && tx_emit_last)
                tx_frame_cnt <= tx_frame_cnt - 11'd1;
        end
    end

    // Bridged GMII TX signals (fed to the demo module's gmii_txd/gmii_tx_en)
    assign e_txd  = tx_draining ? tx_fifo[tx_rptr][7:0] : 8'h00;
    assign e_txen = tx_draining;

    // POWER-GATING EXPERIMENT (CLEAN): hold the HLS IP in reset at power-up
    // AND gate tx_push (above) so the IP's reset-garbage never reaches the
    // wire. Design stays near-idle (clock tree still toggling), the ONLY
    // TX traffic is the demo-clone generator at 1Hz. If the PC receives
    // those frames, the big design's activity was the cause; if not,
    // power/noise from the clock tree alone is not the cause.
    reg ip_enable;
    always @(posedge gmii_clk or negedge reset_n) begin
        if (!reset_n) ip_enable <= 1'b0;
        else          ip_enable <= 1'b1;   // IP RUNNING (FCS fix verified)
    end

    // Network IP instance
    wire [10:0] dbg_tsb_addr0, dbg_tsb_addr1;
    wire [7:0]  dbg_tsb_d1, dbg_tsb_q0;
    wire [15:0] dbg_q_len, dbg_q_off;
    wire [32:0] dbg_fsm;
    wire [15:0] dbg_ctrl;
    udp_echo u_net (
        .ap_clk             (gmii_clk),
        .ap_rst_n           (ip_enable & reset_n),
        .reset_n            (ip_enable & reset_n),
        .rx_stream_TDATA    (net_rx_data),
        .rx_stream_TVALID   (net_rx_valid),
        .rx_stream_TREADY   (net_rx_ready),
        .tx_stream_TDATA    (net_tx_data),
        .tx_stream_TVALID   (net_tx_valid),
        .tx_stream_TREADY   (net_tx_ready),
        .msg_stream_TDATA   (net_msg_data),
        .msg_stream_TVALID  (net_msg_valid),
        .msg_stream_TREADY  (net_msg_ready),
        .led_d0             (led_d0_hls),
        .led_d1             (led_d1_hls),
        .led_d2             (led_d2_hls),
        .led_d3             (led_d3_hls),
        .dbg_tsb_addr0      (dbg_tsb_addr0),
        .dbg_tsb_addr1      (dbg_tsb_addr1),
        .dbg_tsb_d1         (dbg_tsb_d1),
        .dbg_tsb_q0         (dbg_tsb_q0),
        .dbg_q_len          (dbg_q_len),
        .dbg_q_off          (dbg_q_off),
        .dbg_fsm            (dbg_fsm),
        .dbg_ctrl           (dbg_ctrl)
    );

    // --- msg stream: DISABLED (cross-clock-domain issue) ---
    assign net_msg_ready = 1'b1;

    // --- GMII TX → RGMII: handled inside the demo's util module above;
    // the bridged e_txd/e_txen connect directly to its gmii_txd/gmii_tx_en.

    // --- UART IP instance (@50MHz board oscillator) ---
    reg [1:0] uart_sync_sr;
    always @(posedge fpga_gclk or negedge reset_n) begin
        if (!reset_n) uart_sync_sr <= 2'b11;
        else          uart_sync_sr <= {uart_sync_sr[0], rs232_rx};
    end

    wire uart_tx_raw;
    uart_console u_uart (
        .ap_clk             (fpga_gclk),
        .ap_rst_n           (reset_n),
        .rst_n              (reset_n),
        .rx                 (uart_sync_sr[1]),
        .tx                 (uart_tx_raw),
        .rx_done            (rx_done_pulse),
        .resp_active        (resp_active_wire)
    );

    // --- stats: frame toggles + captures (gmii_clk domain) ---
    reg rx_tgl, tx_tgl, tx_valid_d1, e_txen_d1;
    always @(posedge gmii_clk or negedge reset_n) begin
        if (!reset_n) begin rx_tgl<=0; tx_tgl<=0; tx_valid_d1<=0; e_txen_d1<=0; end
        else begin
            rx_tgl <= rx_tgl ^ (rx_dv_d1 && !rx_dv_d2);
            tx_tgl <= tx_tgl ^ (gmii_txen_sel && !e_txen_d1);
            e_txen_d1 <= e_txen;
            tx_valid_d1 <= net_tx_valid;
        end
    end

    // --- RAW stream capture: first 16 valid bytes of the IP's stream ---
    // Counts VALID CYCLES (not runs): the HLS stream has gaps between
    // bytes, so this captures the IP's first 16 actual bytes in order.
    // Frozen after 16 bytes (no cross-frame tearing).
    reg [4:0] raw_n;
    reg [7:0] raw_cap [0:15];
    reg       raw_done;
    always @(posedge gmii_clk or negedge reset_n) begin
        if (!reset_n) begin raw_n<=0; raw_done<=0; end
        else if (!raw_done) begin
            if (net_tx_valid && raw_n <= 5'd15) begin
                raw_cap[raw_n] <= net_tx_data[7:0];
                if (raw_n == 5'd15) raw_done <= 1'b1;
                raw_n <= raw_n + 5'd1;
            end
        end
    end

    // --- TX frame capture: first 16 bytes of the FIRST bridged frame ---
    // FROZEN after the first frame completes: the values never change
    // again, so the 50MHz-side 2-FF sync can never tear across frames.
    reg [4:0] tx_run;
    reg [7:0] tx_cap [0:15];
    reg       tx_cap_done;
    always @(posedge gmii_clk or negedge reset_n) begin
        if (!reset_n) begin tx_run<=0; tx_cap_done<=0; end
        else begin
            if (!tx_cap_done) begin
                if (!e_txen) begin
                    tx_run <= 5'd0;
                end else begin
                    if (tx_run < 5'd31) tx_run <= tx_run + 5'd1;
                    if (tx_run == 5'd0)  tx_cap[0]  <= e_txd;
                    if (tx_run == 5'd1)  tx_cap[1]  <= e_txd;
                    if (tx_run == 5'd2)  tx_cap[2]  <= e_txd;
                    if (tx_run == 5'd3)  tx_cap[3]  <= e_txd;
                    if (tx_run == 5'd4)  tx_cap[4]  <= e_txd;
                    if (tx_run == 5'd5)  tx_cap[5]  <= e_txd;
                    if (tx_run == 5'd6)  tx_cap[6]  <= e_txd;
                    if (tx_run == 5'd7)  tx_cap[7]  <= e_txd;
                    if (tx_run == 5'd8)  tx_cap[8]  <= e_txd;
                    if (tx_run == 5'd9)  tx_cap[9]  <= e_txd;
                    if (tx_run == 5'd10) tx_cap[10] <= e_txd;
                    if (tx_run == 5'd11) tx_cap[11] <= e_txd;
                    if (tx_run == 5'd12) tx_cap[12] <= e_txd;
                    if (tx_run == 5'd13) tx_cap[13] <= e_txd;
                    if (tx_run == 5'd14) tx_cap[14] <= e_txd;
                    if (tx_run == 5'd15) tx_cap[15] <= e_txd;
                end
                // freeze when a frame that reached at least 16 bytes ends
                if (!e_txen && tx_run >= 5'd15) tx_cap_done <= 1'b1;
            end
        end
    end

    // --- RX frame capture: first 8 bytes of the FIRST wire frame (?rxd) ---
    // Same freeze-on-first strategy (no cross-frame tearing).
    reg [3:0] rx_run;
    reg [7:0] rx_cap [0:7];
    reg       rx_cap_done;
    always @(posedge gmii_clk or negedge reset_n) begin
        if (!reset_n) begin rx_run<=0; rx_cap_done<=0; end
        else begin
            if (!rx_cap_done) begin
                if (!rx_dv_d2) begin
                    rx_run <= 4'd0;
                end else begin
                    if (rx_run < 4'd7) rx_run <= rx_run + 4'd1;
                    if (rx_run == 4'd0) rx_cap[0] <= rx_d2;
                    if (rx_run == 4'd1) rx_cap[1] <= rx_d2;
                    if (rx_run == 4'd2) rx_cap[2] <= rx_d2;
                    if (rx_run == 4'd3) rx_cap[3] <= rx_d2;
                    if (rx_run == 4'd4) rx_cap[4] <= rx_d2;
                    if (rx_run == 4'd5) rx_cap[5] <= rx_d2;
                    if (rx_run == 4'd6) rx_cap[6] <= rx_d2;
                    if (rx_run == 4'd7) rx_cap[7] <= rx_d2;
                end
                if (!rx_dv_d2 && rx_run >= 4'd7) rx_cap_done <= 1'b1;
            end
        end
    end

    net_stats u_net_stats (
        .clk50      (fpga_gclk),
        .reset_n    (reset_n),
        .uart_rx    (uart_sync_sr[1]),
        .uart_tx_in (uart_tx_raw),
        .uart_tx_out(rs232_tx),
        .rx_toggle  (rx_tgl),
        .tx_toggle  (tx_tgl),
        .stat_lock  (delay_ready & mmcm_ref_locked),
        .dbg0       ({rx_occ[7:0], tx_occ[7:0]}),
        .dbg1       (net_rx_ready),
        .tx_cap     ({tx_cap[15], tx_cap[14], tx_cap[13], tx_cap[12],
                      tx_cap[11], tx_cap[10], tx_cap[9],  tx_cap[8],
                      tx_cap[7],  tx_cap[6],  tx_cap[5],  tx_cap[4],
                      tx_cap[3],  tx_cap[2],  tx_cap[1],  tx_cap[0]}),
        .rx_cap     ({rx_cap[7], rx_cap[6], rx_cap[5], rx_cap[4],
                      rx_cap[3], rx_cap[2], rx_cap[1], rx_cap[0]}),
        .raw_cap    ({raw_cap[15], raw_cap[14], raw_cap[13], raw_cap[12],
                      raw_cap[11], raw_cap[10], raw_cap[9],  raw_cap[8],
                      raw_cap[7],  raw_cap[6],  raw_cap[5],  raw_cap[4],
                      raw_cap[3],  raw_cap[2],  raw_cap[1],  raw_cap[0]})
    );

    //=========================================================================
    // ILA debug: frame counters (idle-auto-reset for deterministic triggers)
    // + ila_0 probing the TCP echo queue race (tcp_send_bufs / q pointers / FSM)
    //=========================================================================
    wire rx_beat      = net_rx_valid && net_rx_ready;
    wire rx_last_beat = rx_beat && net_rx_data[8];
    wire tx_beat      = net_tx_valid && net_tx_ready;
    wire tx_last_beat = tx_beat && net_tx_data[8];
    reg [7:0]  dbg_rx_fcnt, dbg_tx_fcnt;
    reg [23:0] rx_idle_cnt;
    always @(posedge gmii_clk or negedge reset_n) begin
        if (!reset_n) begin
            dbg_rx_fcnt <= 8'd0; dbg_tx_fcnt <= 8'd0; rx_idle_cnt <= 24'd0;
        end else begin
            if (rx_beat) rx_idle_cnt <= 24'd0;
            else if (rx_idle_cnt < 24'd625000) rx_idle_cnt <= rx_idle_cnt + 24'd1;
            else begin
                // >5ms of no DUT RX activity: re-zero both counters so every
                // host test run restarts frame numbering at the same values.
                dbg_rx_fcnt <= 8'd0;
                dbg_tx_fcnt <= 8'd0;
            end
            if (rx_last_beat) dbg_rx_fcnt <= dbg_rx_fcnt + 8'd1;
            if (tx_last_beat) dbg_tx_fcnt <= dbg_tx_fcnt + 8'd1;
        end
    end

    // wire-side GMII truth + stream handshakes + RX FIFO occupancy (probe12/13)
    wire [7:0] dbg_wire = {e_rxdv, e_txen, net_rx_valid, net_rx_ready,
                           net_tx_valid, net_tx_ready, 2'b00};

    ila_0 u_ila (
        .clk    (gmii_clk),
        .probe0 (dbg_tsb_addr1),          // tcp_send_bufs write addr (tcp_queue)
        .probe1 (dbg_tsb_addr0),          // tcp_send_bufs read addr (tcp_send_1)
        .probe2 (dbg_tsb_d1),             // write data
        .probe3 (dbg_tsb_q0),             // read data
        .probe4 (dbg_q_len),              // queue length register
        .probe5 (dbg_q_off),              // queue read offset register
        .probe6 (dbg_fsm),                // ap_CS_fsm[32:0] one-hot
        .probe7 (dbg_ctrl),               // ce0/ce1/we1/tx_req/busy/start/done...
        .probe8 (net_rx_data[8:0]),       // DUT rx stream {last,data}
        .probe9 (net_tx_data[8:0]),       // DUT tx stream {last,data}
        .probe10(dbg_rx_fcnt),
        .probe11(dbg_tx_fcnt),
        .probe12(dbg_wire),               // wire dv/en + stream valid/ready
        .probe13(rx_occ)                  // wrapper RX FIFO occupancy
    );

endmodule
