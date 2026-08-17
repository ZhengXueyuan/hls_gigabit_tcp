//=============================================================================
// wrapper.v — udp_echo + uart_console, Kintex7 ECO board (phase-tuned FINAL)
//=============================================================================
// Physical board facts (all board-verified 2026-08-17):
//   - Cabled port = AA23 pin group (bank 12, LVCMOS33): rxc=AA23,
//     rxd=V26/V21/U24/U25, rxctl=U26, txc=V24, txd=V22/W26/W25/W21, txctl=W23
//   - Link: forced 100M-FD via MDIO (autoneg loops otherwise), RXC=25MHz
//   - RXDLY/TXDLY straps on the PHYSICAL board appear DISABLED (data
//     transitions at the clock edges) → sampling must be mid-nibble:
//     RX: IDDRs on the MMCM output clock, phase P after the RXC rising edge
//     TX: TXD/TXCTL fixed on the raw RXC (BUFG(phy1_rxc)); TXC = the MMCM
//         output → sweeping P moves the PHY's TX sample point across the
//         fixed TXD nibbles. Both directions work for P in ~(3..18)ns.
//   - Mini-probe calibration found the RX window at P=+3.34ns (2 "@+" steps
//     of 56 PS steps = 1.67ns each). The main design should sweep P to find
//     the common RX+TX window (ping is the observable).
//=============================================================================

module wrapper (
    input           reset_n,        // async reset, active low (KEY1)
    input           fpga_gclk,      // 50MHz board oscillator (UART + LED clock)
    // RGMII RX from PHY (RTL8211E)
    input           phy1_rxc,       // RX clock (25MHz @100M link)
    input  [3:0]    phy1_rxd,       // RX data (DDR)
    input           phy1_rxctl,     // RX control (DDR: rising=RXDV, falling=RXDV^RXER)
    // RGMII TX to PHY
    output          phy1_txc,       // TX clock to PHY (MMCM output, phase-swept)
    output [3:0]    phy1_txd,       // TX data (DDR, on raw RXC)
    output          phy1_txctl,     // TX control (DDR, on raw RXC)
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

    // --- Fixed outputs ---
    assign phy1_nrst = 1'b1;   // RTL8211E nRST active low: hold released
    assign phy1_mdc  = 1'b0;   // MDIO not driven (PHY configured by straps)
    assign phy1_mdio = 1'bz;

    // --- RX clock: MMCME2_ADV, phase-adjustable ---
    // 25MHz in, VCO=600MHz, CLKOUT0 ÷24 = 25MHz out. CLKFBIN closed (open
    // loop never locks). FINE_PS required for the dynamic phase shift.
    // "@+" / "@-" = 56 PS steps ≈ 1.67ns; 24 commands sweep the 40ns period.
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
        .CLKOUT0_USE_FINE_PS("TRUE"),  // dynamic PS requires FINE_PS
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

    // --- RGMII RX → GMII (IDDR directly on the pins, no IDELAY) ---
    wire [3:0] rx_q1, rx_q2;
    wire       rxctl_q1, rxctl_q2;
    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : gen_iddr_rx
            IDDR #(.DDR_CLK_EDGE("SAME_EDGE_PIPELINED"), .INIT_Q1(1'b0), .INIT_Q2(1'b0), .SRTYPE("SYNC"))
                u_iddr (.Q1(rx_q1[i]), .Q2(rx_q2[i]), .C(gmii_clk), .CE(1'b1),
                        .D(phy1_rxd[i]), .R(1'b0), .S(1'b0));
        end
    endgenerate
    IDDR #(.DDR_CLK_EDGE("SAME_EDGE_PIPELINED"), .INIT_Q1(1'b0), .INIT_Q2(1'b0), .SRTYPE("SYNC"))
        u_iddr_rxctl (.Q1(rxctl_q1), .Q2(rxctl_q2), .C(gmii_clk), .CE(1'b1),
                      .D(phy1_rxctl), .R(1'b0), .S(1'b0));
    wire [7:0] e_rxd  = {rx_q2, rx_q1};
    wire       e_rxdv = rxctl_q1;
    wire       e_rxer = rxctl_q1 ^ rxctl_q2;

    // --- LED logic ---
    wire led_d0_hls, led_d1_hls, led_d2_hls, led_d3_hls;  // raw HLS outputs
    reg [25:0] led_cnt;
    always @(posedge fpga_gclk or negedge reset_n) begin
        if (!reset_n) led_cnt <= 26'd0;
        else if (led_cnt >= 26'd49999999) led_cnt <= 26'd0;
        else          led_cnt <= led_cnt + 26'd1;
    end
    wire led_tick  = (led_cnt < 26'd25000000);   // 0.5s on, 0.5s off = 1Hz
    wire dhcp_ok   = led_d0_hls;   // from HLS: 1=DHCP done
    wire resp_active_wire;
    assign led_d1 = resp_active_wire;
    assign led_d2 = ~dhcp_ok & led_tick;
    assign led_d3 = dhcp_ok & led_tick;

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

    // RX: GMII → AXI-Stream (1-cycle delay)
    reg [7:0]  rx_d1; reg rx_dv_d1, rx_dv_d2;
    always @(posedge gmii_clk or negedge reset_n) begin
        if (!reset_n) begin rx_d1<=0;rx_dv_d1<=0;rx_dv_d2<=0; end
        else begin rx_d1<=e_rxd;rx_dv_d1<=e_rxdv;rx_dv_d2<=rx_dv_d1; end
    end
    assign net_rx_data  = {7'b0, rx_dv_d1 && !rx_dv_d2, rx_d1};
    assign net_rx_valid = rx_dv_d1;

    // TX: AXI-Stream → GMII
    wire [7:0] e_txd;
    wire       e_txen;
    wire       e_txer;
    assign e_txd  = net_tx_data[7:0];
    assign e_txen = net_tx_valid;
    assign e_txer = 1'b0;
    assign net_tx_ready = 1'b1;

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

    // --- msg stream: DISABLED (cross-clock-domain issue) ---
    assign net_msg_ready = 1'b1;

    // --- GMII TX → RGMII ---
    // TXD/TXCTL fixed on the RAW RXC (tx_clk); TXC = the MMCM output. The
    // phase sweep moves the PHY's TX sample point across the fixed TXD
    // nibbles; the RX window moves the same way. Common window P≈(3..18)ns.
    wire tx_clk;
    BUFG u_tx_clk_bufg (.I(phy1_rxc), .O(tx_clk));
    wire txctl_d1 = e_txen;
    wire txctl_d2 = e_txen ^ e_txer;
    generate
        for (i = 0; i < 4; i = i + 1) begin : gen_oddr_tx
            ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC"))
                u_oddr (.Q(phy1_txd[i]), .C(tx_clk), .CE(1'b1),
                        .D1(e_txd[i]), .D2(e_txd[i+4]), .R(1'b0), .S(1'b0));
        end
    endgenerate
    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC"))
        u_oddr_txctl (.Q(phy1_txctl), .C(tx_clk), .CE(1'b1),
                      .D1(txctl_d1), .D2(txctl_d2), .R(1'b0), .S(1'b0));
    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC"))
        u_oddr_txc (.Q(phy1_txc), .C(gmii_clk), .CE(1'b1),
                    .D1(1'b1), .D2(1'b0), .R(1'b0), .S(1'b0));

    // --- UART IP instance (@50MHz board oscillator) ---
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

    // --- MMCM phase control: UART "@+"/"@-" (9600-8N1 @50MHz) ---
    // Watches the SAME synchronized line as uart_console (uart_sync_sr[1]);
    // the console echoes the commands (normal). LSB-first accumulation:
    // psrx_shift <= {uart_sync_sr[1], psrx_shift[7:1]}.
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
                if (psrx_cnt == 16'd2603) begin   // mid-bit sample
                    if (psrx_bitn == 4'd0) begin
                        // start bit: nothing to shift
                    end else if (psrx_bitn <= 4'd8) begin
                        psrx_shift <= {uart_sync_sr[1], psrx_shift[7:1]};
                    end else begin                    // stop bit: byte done
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

    // --- PS sequencer: 56 × (PSEN 1 PSCLK → wait PSDONE) per command ---
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

endmodule
