//=============================================================================
// wrapper_v2.v — udp_echo + uart_console, Kintex7 ECO board
//   RGMII 100M-CORRECT bridge (root-cause fix, see PORT_NOTES 攻坚日志)
//=============================================================================
// WHY THIS FILE EXISTS (2026-08-17):
//   The RTL8211E at a 100M link operates RGMII at ONE NIBBLE PER RXC PERIOD
//   (falling edge = duplicate/don't-care; rising edge only is sampled), NOT
//   the 1G-style byte-per-cycle DDR.  The previous wrapper drove/received a
//   byte per period on both edges:
//     TX: the PHY consumed only the rising-edge nibble (lo nibbles) → no
//         valid SFD ever reached the PCS → FPGA→PC never delivered a frame.
//     RX: the PHY presents one nibble per period → {Q2,Q1} assembled
//         nibble-doubled bytes {n,n} → the MAC dropped every frame.
//   Board proof: a 64-byte PC frame (72 wire bytes incl. preamble) produced
//   rxdv_hi=144 = 72*2 periods in the mini probe.
//
// FIX:
//   RX: rising-edge nibbles (IDDR Q1) are accumulated two per byte with a
//       SELF-ALIGNING nibble-pair FSM: the SFD nibble pair [5,D] — if the
//       D lands in a lo slot the pairing is off by one nibble and the byte
//       {D,5}=0xD5 is emitted immediately, re-locking the alignment.  All
//       preamble bytes are 0x55 (pair-invariant), so only the SFD byte is
//       ever affected.  Frame end: the last byte is flagged last=1 on the
//       RXCTL falling edge.
//   TX: the MAC byte stream is serialized to ONE NIBBLE PER TXC PERIOD
//       (D1=D2=nibble, lo first, byte = 2 periods = 100 Mbps).  The MAC's
//       TX is backpressured (TREADY gated 1 cycle in 2) — the HLS IP at
//       25MHz produces bytes at 200Mbps, which would overrun the 100M PCS.
//       The bridge runs in the raw-RXC domain (tx_clk) with 2-FF synced
//       AXI-Stream controls; TXC stays on the MMCM output so the @+/-
//       phase sweep still covers the PHY's TX sample point (needed only if
//       the TXDLY strap were 0; with nibbles stable for a full period it is
//       phase-independent).
//   MDIO: startup one-shot write BMCR=0x2100 (100M-FD, AN off, loopback
//         off) — ported from the board-verified gmii_probe_eco/top.v.
//         AA23 pin group (board-verified wired set) + MDIO AA25/Y25.
//=============================================================================

module wrapper_v2 (
    input           reset_n,        // async reset, active low (KEY1, D26)
    input           fpga_gclk,      // 50MHz board oscillator (UART clock)
    // RGMII RX from PHY (RTL8211E)
    input           phy1_rxc,       // RX clock (25MHz @100M link)
    input  [3:0]    phy1_rxd,       // RX data (DDR)
    input           phy1_rxctl,     // RX control (DDR: rising=RXDV, falling=RXDV^RXER)
    // RGMII TX to PHY
    output          phy1_txc,       // TX clock to PHY (MMCM output, phase-swept)
    output [3:0]    phy1_txd,       // TX data (DDR)
    output          phy1_txctl,     // TX control (DDR)
    // Management
    output          phy1_nrst,      // PHY reset, active low (1 = released)
    output          phy1_mdc,
    inout           phy1_mdio,
    // UART
    input           rs232_rx,
    output          rs232_tx,
    // LEDs
    output          led_d0,
    output          led_d1,
    output          led_d2,
    output          led_d3
);

    assign phy1_nrst = 1'b1;   // RTL8211E nRST active low: hold released

    //-------------------------------------------------------------------------
    // RX clock: MMCME2_ADV, phase-adjustable — copied from wrapper.v
    //   25MHz in, VCO=600MHz, CLKOUT0 ÷24 = 25MHz gmii_clk.  FINE_PS for the
    //   dynamic phase shift; "@+"/"@-" = 56 PS steps ≈ 1.67ns.
    //-------------------------------------------------------------------------
    wire gmii_clk, gmii_clk_raw, mmcm_rx_locked, psdone, mmcm_rx_fb;
    reg  psen, ps_incdec;
    MMCME2_ADV #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKFBOUT_MULT_F(24.0),        // VCO = 25 × 24 = 600MHz
        .CLKFBOUT_PHASE(0.0),
        .CLKFBOUT_USE_FINE_PS("FALSE"),
        .CLKIN1_PERIOD(40.0),          // 25MHz RXC @100M link
        .CLKIN2_PERIOD(0.0),
        .CLKOUT0_DIVIDE_F(24.0),       // 600/24 = 25MHz
        .CLKOUT0_DUTY_CYCLE(0.5),
        .CLKOUT0_PHASE(0.0),
        .CLKOUT0_USE_FINE_PS("TRUE"),
        .CLKOUT1_DIVIDE(1), .CLKOUT1_DUTY_CYCLE(0.5), .CLKOUT1_PHASE(0.0),
        .CLKOUT2_DIVIDE(1), .CLKOUT2_DUTY_CYCLE(0.5), .CLKOUT2_PHASE(0.0),
        .CLKOUT3_DIVIDE(1), .CLKOUT3_DUTY_CYCLE(0.5), .CLKOUT3_PHASE(0.0),
        .CLKOUT4_DIVIDE(1), .CLKOUT4_DUTY_CYCLE(0.5), .CLKOUT4_PHASE(0.0),
        .CLKOUT5_DIVIDE(1), .CLKOUT5_DUTY_CYCLE(0.5), .CLKOUT5_PHASE(0.0),
        .CLKOUT6_DIVIDE(1), .CLKOUT6_DUTY_CYCLE(0.5), .CLKOUT6_PHASE(0.0),
        .COMPENSATION("ZHOLD"),
        .DIVCLK_DIVIDE(1),
        .IS_CLKINSEL_INVERTED(1'b0),
        .IS_PSEN_INVERTED(1'b0),
        .IS_PSINCDEC_INVERTED(1'b0),
        .IS_PWRDWN_INVERTED(1'b0),
        .IS_RST_INVERTED(1'b0),
        .REF_JITTER1(0.010),
        .REF_JITTER2(0.010),
        .SS_EN("FALSE"),
        .SS_MODE("CENTER_HIGH"),
        .SS_MOD_PERIOD(10000),
        .STARTUP_WAIT("FALSE")
    ) u_mmcm_rxclk (
        .CLKOUT0(gmii_clk_raw),
        .CLKOUT0B(),
        .CLKOUT1(), .CLKOUT1B(),
        .CLKOUT2(), .CLKOUT2B(),
        .CLKOUT3(), .CLKOUT3B(),
        .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
        .CLKFBOUT(mmcm_rx_fb),
        .CLKFBOUTB(),
        .CLKFBIN(mmcm_rx_fb),          // feedback loop MUST be closed
        .CLKIN1(phy1_rxc),
        .CLKIN2(1'b0),
        .CLKINSEL(1'b1),
        .DADDR(7'b0),
        .DCLK(1'b0),
        .DEN(1'b0),
        .DI(16'b0),
        .DO(),
        .DRDY(),
        .DWE(1'b0),
        .PSCLK(fpga_gclk),
        .PSDONE(psdone),
        .PSEN(psen),
        .PSINCDEC(ps_incdec),
        .PWRDWN(1'b0),
        .RST(!reset_n),
        .LOCKED(mmcm_rx_locked)
    );
    BUFG u_gmii_clk_bufg (.I(gmii_clk_raw), .O(gmii_clk));

    //-------------------------------------------------------------------------
    // TXC clock forwarding: ODDR 1/0 = clean copy of gmii_clk (phase-swept).
    // NOTE (board-verified): the RTL8211E samples TXD with its OWN internal
    // clock, NOT this TXC — so TXD/TXCTL are clocked by gmii_clk too (see
    // the TX bridge below); the @+/- sweep moves the TXD across the PHY's
    // fixed sample point.  The mini probe needed ~10-12 "@+" steps for a
    // byte-perfect PCS loopback — repeat that calibration after each boot.
    //-------------------------------------------------------------------------
    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC"))
        u_oddr_txc (.Q(phy1_txc), .C(gmii_clk), .CE(1'b1),
                    .D1(1'b1), .D2(1'b0), .R(1'b0), .S(1'b0));

    //-------------------------------------------------------------------------
    // RGMII RX → nibbles (IDDR SAME_EDGE_PIPELINED on gmii_clk)
    //   At 100M the PHY presents ONE nibble per RXC period on both edges
    //   (duplicate) — rx_q1 (rising-edge sample) is the nibble stream.
    //-------------------------------------------------------------------------
    wire [3:0] rx_q1, rx_q2;
    wire       rxctl_q1, rxctl_q2;
    genvar gi;
    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : gen_iddr_rx
            IDDR #(.DDR_CLK_EDGE("SAME_EDGE_PIPELINED"), .INIT_Q1(1'b0),
                   .INIT_Q2(1'b0), .SRTYPE("SYNC"))
                u_iddr (.Q1(rx_q1[gi]), .Q2(rx_q2[gi]), .C(gmii_clk), .CE(1'b1),
                        .D(phy1_rxd[gi]), .R(1'b0), .S(1'b0));
        end
    endgenerate
    IDDR #(.DDR_CLK_EDGE("SAME_EDGE_PIPELINED"), .INIT_Q1(1'b0),
           .INIT_Q2(1'b0), .SRTYPE("SYNC"))
        u_iddr_rxctl (.Q1(rxctl_q1), .Q2(rxctl_q2), .C(gmii_clk), .CE(1'b1),
                      .D(phy1_rxctl), .R(1'b0), .S(1'b0));

    //-------------------------------------------------------------------------
    // RX byte assembly — self-aligning 2-nibble accumulator (100M mode)
    //   Nibble n[k] arrives each gmii_clk period.  Byte = {n[2i+1], n[2i]}.
    //   Misalignment recovery: when a D arrives in a LO slot right after a 5
    //   (the SFD nibble pair [5,D] straddling a byte boundary), emit the
    //   byte {D,5} = 0xD5 immediately and stay in the LO slot — the pairing
    //   is re-locked for the rest of the frame.  All preamble bytes are 0x55
    //   (pair-invariant) so nothing before the SFD is corrupted.
    //   Stage B pipelines the byte one period so the last flag is asserted
    //   on the final byte when RXCTL falls.
    //-------------------------------------------------------------------------
    reg        rx_lo_state = 1'b0;   // 0 = expect lo nibble, 1 = expect hi
    reg [3:0]  rx_lo_hold  = 4'd0;   // held lo nibble
    reg [3:0]  rx_n_prev   = 4'd0;   // previous period's nibble
    reg [7:0]  rx_byte0    = 8'd0;   // stage A: completed byte
    reg        rx_byte0_we = 1'b0;
    reg [7:0]  rx_byte1    = 8'd0;   // stage B: pipeline
    reg        rx_byte1_we = 1'b0;

    wire [3:0] rx_n = rx_q1;

    always @(posedge gmii_clk or negedge reset_n) begin
        if (!reset_n) begin
            rx_lo_state <= 1'b0;
            rx_lo_hold  <= 4'd0;
            rx_n_prev   <= 4'd0;
            rx_byte0    <= 8'd0;
            rx_byte0_we <= 1'b0;
            rx_byte1    <= 8'd0;
            rx_byte1_we <= 1'b0;
        end else begin
            rx_byte0_we <= 1'b0;
            if (!rxctl_q1) begin
                // idle (or frame ended): discard any partial byte
                rx_lo_state <= 1'b0;
            end else if (!rx_lo_state) begin
                // LO slot: current nibble is the lo of a byte
                if (rx_n_prev == 4'h5 && rx_n == 4'hD) begin
                    // SFD's D landed in the lo slot → pairing is off by one
                    // nibble: emit {D,5}=0xD5 now, stay in LO (this D is the
                    // SFD's HI nibble; the next nibble is the next byte's lo)
                    rx_byte0   <= {rx_n, rx_n_prev};
                    rx_byte0_we <= 1'b1;
                end else begin
                    rx_lo_hold <= rx_n;
                    rx_lo_state <= 1'b1;
                end
            end else begin
                // HI slot: byte complete
                rx_byte0   <= {rx_n, rx_lo_hold};
                rx_byte0_we <= 1'b1;
                rx_lo_state <= 1'b0;
            end
            rx_n_prev <= rx_n;
            // pipeline (stage B)
            rx_byte1   <= rx_byte0;
            rx_byte1_we <= rx_byte0_we;
        end
    end

    // AXI-Stream to the MAC: {7'b0, last, data[7:0]}, valid 1 cycle/byte.
    // last is asserted on the final byte (the fall of RXCTL follows the last
    // data nibble; the pipeline presents that byte in the fall period).
    wire rx_frame_last = rx_byte1_we & ~rxctl_q1;
    wire [15:0] net_rx_data  = {7'b0, rx_frame_last, rx_byte1};
    wire        net_rx_valid = rx_byte1_we;

    //-------------------------------------------------------------------------
    // TX bridge — MAC stream → FIFO → nibble-per-period serializer (gmii_clk)
    //   BOARD-VERIFIED 2026-08-17: the RTL8211E samples TXD with its OWN
    //   internal (RXC-locked) clock — NOT our TXC.  Therefore TXD/TXCTL must
    //   be clocked by the MMCM output (gmii_clk) so the @+/- phase sweep
    //   moves the TXD relative to the PHY's fixed sample point (mini probe:
    //   PCS-loopback data becomes byte-perfect at ~10-12 @+ steps).  The
    //   original wrapper pinned TXD to the raw RXC (fixed bad sample phase).
    //   The MAC (gmii_clk) can produce up to 1 byte/cycle (200Mbps @25MHz)
    //   while the 100M wire takes exactly 1 byte per 2 periods — a small
    //   FIFO decouples the MAC's bursty writes from the wire's strict
    //   schedule.  TDATA bit 8 = last (frame-end flag); the serializer
    //   deasserts TXEN exactly after the last byte's hi period.
    //-------------------------------------------------------------------------
    // 8-deep FIFO of {last, byte}
    reg [8:0]  tx_fifo [0:7];
    reg [3:0]  tx_fifo_n  = 4'd0;
    reg [2:0]  tx_fifo_rp = 3'd0;
    reg [2:0]  tx_fifo_wp = 3'd0;
    wire       tx_fifo_full  = (tx_fifo_n == 4'd8);
    wire       tx_fifo_empty = (tx_fifo_n == 4'd0);
    wire       tx_do_wr = net_tx_valid & !tx_fifo_full;
    wire       tx_do_rd = tx_s_consume;   // serializer takes a byte

    always @(posedge gmii_clk or negedge reset_n) begin
        if (!reset_n) begin
            tx_fifo_n  <= 4'd0;
            tx_fifo_rp <= 3'd0;
            tx_fifo_wp <= 3'd0;
        end else begin
            case ({tx_do_wr, tx_do_rd})
                2'b10: begin
                    tx_fifo[tx_fifo_wp] <= {net_tx_data[8], net_tx_data[7:0]};
                    tx_fifo_wp <= tx_fifo_wp + 3'd1;
                    tx_fifo_n  <= tx_fifo_n + 4'd1;
                end
                2'b01: begin
                    tx_fifo_rp <= tx_fifo_rp + 3'd1;
                    tx_fifo_n  <= tx_fifo_n - 4'd1;
                end
                2'b11: begin
                    tx_fifo[tx_fifo_wp] <= {net_tx_data[8], net_tx_data[7:0]};
                    tx_fifo_wp <= tx_fifo_wp + 3'd1;
                    tx_fifo_rp <= tx_fifo_rp + 3'd1;
                end
                default: ;
            endcase
        end
    end

    // nibble serializer: holds each byte 2 periods (lo, then hi; D1=D2)
    reg        tx_s_phase  = 1'b0;
    reg        tx_s_have   = 1'b0;    // a byte is being serialized
    reg [8:0]  tx_s_byte   = 9'd0;    // {last, byte}
    reg        txen_r      = 1'b0;
    reg [3:0]  txd_d1      = 4'd0;
    reg [3:0]  txd_d2      = 4'd0;
    wire       tx_s_consume = tx_s_have & tx_s_phase;   // byte done pulse

    always @(posedge gmii_clk or negedge reset_n) begin
        if (!reset_n) begin
            tx_s_phase <= 1'b0;
            tx_s_have  <= 1'b0;
            tx_s_byte  <= 9'd0;
            txen_r     <= 1'b0;
            txd_d1     <= 4'd0;
            txd_d2     <= 4'd0;
        end else begin
            tx_s_phase <= ~tx_s_phase;
            if (!tx_s_have) begin
                // load the next byte (lo period starts immediately)
                if (!tx_fifo_empty) begin
                    tx_s_byte <= tx_fifo[tx_fifo_rp];
                    tx_s_have <= 1'b1;
                    txen_r    <= 1'b1;
                    txd_d1    <= tx_fifo[tx_fifo_rp][3:0];
                    txd_d2    <= tx_fifo[tx_fifo_rp][3:0];
                end
            end else begin
                txd_d1 <= tx_s_phase ? tx_s_byte[7:4] : tx_s_byte[3:0];
                txd_d2 <= tx_s_phase ? tx_s_byte[7:4] : tx_s_byte[3:0];
                if (tx_s_phase) begin
                    // hi period over: byte done
                    tx_s_have <= 1'b0;
                    if (tx_s_byte[8]) txen_r <= 1'b0;   // last: frame ends
                end
            end
        end
    end

    assign net_tx_ready = !tx_fifo_full;

    genvar tj;
    generate
        for (tj = 0; tj < 4; tj = tj + 1) begin : gen_oddr_tx
            ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC"))
                u_oddr_tx (.Q(phy1_txd[tj]), .C(gmii_clk), .CE(1'b1),
                           .D1(txd_d1[tj]), .D2(txd_d2[tj]), .R(1'b0), .S(1'b0));
        end
    endgenerate
    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC"))
        u_oddr_txctl (.Q(phy1_txctl), .C(gmii_clk), .CE(1'b1),
                      .D1(txen_r), .D2(txen_r), .R(1'b0), .S(1'b0));

    //-------------------------------------------------------------------------
    // Network IP signals (@gmii_clk)
    //-------------------------------------------------------------------------
    wire [15:0] net_tx_data, net_msg_data;
    wire        net_tx_valid, net_msg_valid, net_msg_ready;
    wire        led_d0_hls, led_d1_hls, led_d2_hls, led_d3_hls;

    // --- LED logic ---
    reg [25:0] led_cnt;
    always @(posedge fpga_gclk or negedge reset_n) begin
        if (!reset_n) led_cnt <= 26'd0;
        else if (led_cnt >= 26'd49999999) led_cnt <= 26'd0;
        else          led_cnt <= led_cnt + 26'd1;
    end
    wire led_tick  = (led_cnt < 26'd25000000);   // 0.5s on, 0.5s off = 1Hz
    wire dhcp_ok   = led_d0_hls;
    wire resp_active_wire;
    assign led_d1 = resp_active_wire;
    assign led_d2 = ~dhcp_ok & led_tick;
    assign led_d3 = dhcp_ok & led_tick;

    wire rx_done_pulse;
    reg [26:0] rx_act_cnt;
    always @(posedge fpga_gclk or negedge reset_n) begin
        if (!reset_n) rx_act_cnt <= 27'd0;
        else if (rx_done_pulse) rx_act_cnt <= 27'd100000000;
        else if (rx_act_cnt > 0) rx_act_cnt <= rx_act_cnt - 27'd1;
    end
    assign led_d0 = (rx_act_cnt > 0);

    // Network IP instance
    udp_echo u_net (
        .ap_clk             (gmii_clk),
        .ap_rst_n           (reset_n),
        .reset_n            (reset_n),
        .rx_stream_TDATA    (net_rx_data),
        .rx_stream_TVALID   (net_rx_valid),
        .rx_stream_TREADY   (),
        .tx_stream_TDATA    (net_tx_data),
        .tx_stream_TVALID   (net_tx_valid),
        .tx_stream_TREADY   (net_tx_ready),
        .msg_stream_TDATA   (net_msg_data),
        .msg_stream_TVALID  (net_msg_valid),
        .msg_stream_TREADY  (net_msg_ready),
        .led_d0             (led_d0_hls),
        .led_d1             (led_d1_hls),
        .led_d2             (led_d2_hls),
        .led_d3             (led_d3_hls)
    );

    // msg stream: DISABLED (cross-clock-domain issue)
    assign net_msg_ready = 1'b1;

    //-------------------------------------------------------------------------
    // UART IP instance (@50MHz board oscillator)
    //-------------------------------------------------------------------------
    reg [1:0] uart_sync_sr;
    always @(posedge fpga_gclk or negedge reset_n) begin
        if (!reset_n) uart_sync_sr <= 2'b11;
        else          uart_sync_sr <= {uart_sync_sr[0], rs232_rx};
    end

    uart_console u_uart (
        .ap_clk             (fpga_gclk),
        .ap_rst_n           (reset_n),
        .rst_n              (reset_n),
        .rx                 (uart_sync_sr[1]),
        .tx                 (rs232_tx),
        .rx_done            (rx_done_pulse),
        .resp_active        (resp_active_wire)
    );

    //-------------------------------------------------------------------------
    // MMCM phase control: UART "@+"/"@-" (9600-8N1 @50MHz) — from wrapper.v
    //-------------------------------------------------------------------------
    reg [1:0]  psrx_prev;
    reg [15:0] psrx_cnt;
    reg [3:0]  psrx_bitn;
    reg [7:0]  psrx_shift;
    reg        psrx_active;
    reg        psrx_saw_at;
    reg        ps_go, ps_dir;
    wire       psrx_fall = (psrx_prev[1] == 1'b1 && uart_sync_sr[1] == 1'b0);
    always @(posedge fpga_gclk or negedge reset_n) begin
        if (!reset_n) begin
            psrx_prev <= 2'b11; psrx_active <= 0; psrx_saw_at <= 0;
            ps_go <= 0; ps_dir <= 0;
        end else begin
            psrx_prev <= {psrx_prev[0], uart_sync_sr[1]};
            ps_go <= 1'b0;
            if (!psrx_active) begin
                if (psrx_fall) begin
                    psrx_active <= 1'b1;
                    psrx_cnt    <= 16'd0;
                    psrx_bitn   <= 4'd0;
                    psrx_shift  <= 8'd0;
                end
            end else begin
                if (psrx_cnt == 16'd5207) psrx_cnt <= 16'd0;
                else                      psrx_cnt <= psrx_cnt + 16'd1;
                if (psrx_cnt == 16'd2603) begin
                    if (psrx_bitn == 4'd0) begin
                    end else if (psrx_bitn <= 4'd8) begin
                        psrx_shift <= {uart_sync_sr[1], psrx_shift[7:1]};
                    end else begin
                        if (psrx_shift == 8'h40) psrx_saw_at <= 1'b1;
                        else if (psrx_saw_at && psrx_shift == 8'h2B) begin
                            ps_go <= 1'b1; ps_dir <= 1'b1; psrx_saw_at <= 1'b0;
                        end else if (psrx_saw_at && psrx_shift == 8'h2D) begin
                            ps_go <= 1'b1; ps_dir <= 1'b0; psrx_saw_at <= 1'b0;
                        end else psrx_saw_at <= 1'b0;
                        psrx_active <= 1'b0;
                    end
                    if (psrx_bitn < 4'd9) psrx_bitn <= psrx_bitn + 4'd1;
                end
            end
        end
    end

    reg [9:0]  ps_count;
    reg        ps_busy;
    reg        ps_wait_done;
    always @(posedge fpga_gclk or negedge reset_n) begin
        if (!reset_n) begin
            ps_busy <= 0; ps_count <= 0; ps_wait_done <= 0;
            psen <= 0; ps_incdec <= 0;
        end else begin
            psen <= 1'b0;
            if (ps_go && !ps_busy) begin
                ps_busy <= 1'b1;
                ps_count <= 10'd56;
                ps_incdec <= ps_dir;
                ps_wait_done <= 1'b0;
            end else if (ps_busy) begin
                if (ps_count == 0) ps_busy <= 1'b0;
                else if (!ps_wait_done) begin
                    psen <= 1'b1;
                    ps_wait_done <= 1'b1;
                end else if (psdone) begin
                    ps_wait_done <= 1'b0;
                    ps_count <= ps_count - 10'd1;
                end
            end
        end
    end

    //-------------------------------------------------------------------------
    // MDIO startup write: BMCR = 0x2100 (100M-FD, AN off, loopback off)
    //   One-shot ~25ms after reset release — ported from gmii_probe_eco/top.v
    //   (board-verified: the forced-100M write stabilizes the link).
    //   MDC = fpga_gclk/32 = 1.5625MHz; drive on falling edge, sampled by the
    //   PHY on the rising edge.  Frame: preamble/start/op=01/PHYAD0/REG0/
    //   TA 10/data MSB-first, all master-driven.
    //-------------------------------------------------------------------------
    localparam [1:0]   MDW_DLY     = 2'd0;
    localparam [1:0]   MDW_TX      = 2'd1;
    localparam [1:0]   MDW_IDLE    = 2'd2;
    localparam [20:0]  MDW_DLY_MAX = 21'd1_250_000;   // ~25ms @ 50MHz
    parameter [15:0]   MDW_DATA    = 16'h2100;        // 100M-FD, AN off
    parameter [4:0]    MDW_PHYAD   = 5'd0;            // PHYAD of the write
                                                      // (PHY1/AB2 = 5'd1)

    reg        mdw_busy  = 1'b0;
    reg        mdw_done  = 1'b0;
    reg [1:0]  mdw_state = MDW_IDLE;
    reg [6:0]  mdw_bcnt  = 7'd0;
    reg [20:0] mdw_dcnt  = 21'd0;

    reg [4:0]  mdc_cnt = 5'd0;
    reg       mdc_r   = 1'b1;
    always @(posedge fpga_gclk) begin
        if (!reset_n) begin
            mdc_cnt <= 5'd0;
            mdc_r   <= 1'b1;
        end else begin
            mdc_cnt <= (mdc_cnt == 5'd31) ? 5'd0 : mdc_cnt + 5'd1;
            mdc_r   <= (mdc_cnt < 5'd16);
        end
    end
    assign phy1_mdc = mdc_r;
    wire mdc_fall = (mdc_cnt == 5'd16);       // falling edge -> drive
    wire mdc_rise = (mdc_cnt == 5'd0);        // rising edge   -> PHY samples

    reg md_oe_r = 1'b1;
    reg md_o_r  = 1'b1;
    assign phy1_mdio = md_oe_r ? md_o_r : 1'bz;

    reg mdw_oe_c;
    reg mdw_o_c;
    always @* begin
        if (mdw_state == MDW_TX) begin
            mdw_oe_c = 1'b1;
            if      (mdw_bcnt >= 7'd33) mdw_o_c = 1'b1;
            else if (mdw_bcnt == 7'd32) mdw_o_c = 1'b0;
            else if (mdw_bcnt == 7'd31) mdw_o_c = 1'b1;
            else if (mdw_bcnt == 7'd30) mdw_o_c = 1'b0;
            else if (mdw_bcnt == 7'd29) mdw_o_c = 1'b1;
            else if (mdw_bcnt >= 7'd24) mdw_o_c = MDW_PHYAD[mdw_bcnt - 7'd24]; // PHYAD MSB first
            else if (mdw_bcnt >= 7'd19) mdw_o_c = 1'b0;                        // REGAD 0
            else if (mdw_bcnt == 7'd18) mdw_o_c = 1'b1;
            else if (mdw_bcnt == 7'd17) mdw_o_c = 1'b0;
            else                        mdw_o_c = MDW_DATA[mdw_bcnt - 7'd1];
        end else begin
            mdw_oe_c = 1'b1;  mdw_o_c = 1'b1;
        end
    end

    always @(posedge fpga_gclk) begin
        if (!reset_n) begin
            md_oe_r   <= 1'b1;
            md_o_r    <= 1'b1;
            mdw_busy  <= 1'b0;
            mdw_done  <= 1'b0;
            mdw_state <= MDW_IDLE;
            mdw_bcnt  <= 7'd0;
            mdw_dcnt  <= 21'd0;
        end else begin
            case (mdw_state)
                MDW_IDLE: begin
                    if (!mdw_done) begin
                        mdw_busy  <= 1'b1;
                        mdw_dcnt  <= 21'd0;
                        mdw_state <= MDW_DLY;
                    end
                end
                MDW_DLY: begin
                    if (mdw_dcnt == MDW_DLY_MAX) begin
                        mdw_bcnt  <= 7'd64;
                        mdw_state <= MDW_TX;
                    end else
                        mdw_dcnt <= mdw_dcnt + 21'd1;
                end
                MDW_TX: begin
                    // drive the MDIO line on the MDC falling edge (the PHY
                    // samples on the rising edge)
                    if (mdc_fall) begin
                        md_oe_r <= mdw_oe_c;
                        md_o_r  <= mdw_o_c;
                    end
                    if (mdc_rise) begin
                        // one bit per MDC period; bit 1 = last data bit
                        if (mdw_bcnt > 7'd1) mdw_bcnt <= mdw_bcnt - 7'd1;
                        else begin
                            mdw_busy  <= 1'b0;
                            mdw_done  <= 1'b1;
                            mdw_state <= MDW_IDLE;
                        end
                    end
                end
                default: mdw_state <= MDW_IDLE;
            endcase
        end
    end

endmodule
