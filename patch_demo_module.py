# Patch wrapper_1g.v: replace hand-written RGMII with the demo's module verbatim
p = r'D:\repo\ECO\udp_hls_eco\wrapper_1g.v'
src = open(p, encoding='utf-8').read()

old_clock = """    // --- RX clock: inverted RXC through BUFG (demo recipe) ---
    // The LUT1 inversion + BUFG is intentional: RXD transitions AT the raw
    // RXC edges, so the sample points are the raw edges themselves; the
    // IDELAYE2(10) shifts the data ~1.56ns past them for ~2.4ns margins.
    wire rxc_ibuf;
    IBUF u_rxc_ibuf (.I(phy1_rxc), .O(rxc_ibuf));
    wire gmii_clk;
    BUFG u_bufg_rxc (.I(~rxc_ibuf), .O(gmii_clk));

    // --- RX data delay: IDELAYE2 FIXED value=10 on each RXD bit + RXCTL ---
    wire [3:0] rxd_dly;
    wire       rxctl_dly;
    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : gen_idelay_rx
            (* IODELAY_GROUP = "idelay" *) IDELAYE2 #(
                .CINVCTRL_SEL("FALSE"),
                .DELAY_SRC("IDATAIN"),
                .HIGH_PERFORMANCE_MODE("FALSE"),
                .IDELAY_TYPE("FIXED"),
                .IDELAY_VALUE(10),          // 10 × (5ns/32) ≈ 1.5625ns
                .PIPE_SEL("FALSE"),
                .REFCLK_FREQUENCY(200.0),
                .SIGNAL_PATTERN("DATA")
            ) u_idelay (
                .IDATAIN(phy1_rxd[i]),
                .DATAOUT(rxd_dly[i]),
                .DATAIN(1'b0),
                .C(1'b0),
                .CE(1'b0),
                .INC(1'b0),
                .CINVCTRL(1'b0),
                .CNTVALUEIN(5'b0),
                .CNTVALUEOUT(),
                .LD(1'b0),
                .LDPIPEEN(1'b0),
                .REGRST(1'b0)
            );
        end
    endgenerate
    (* IODELAY_GROUP = "idelay" *) IDELAYE2 #(
        .CINVCTRL_SEL("FALSE"),
        .DELAY_SRC("IDATAIN"),
        .HIGH_PERFORMANCE_MODE("FALSE"),
        .IDELAY_TYPE("FIXED"),
        .IDELAY_VALUE(10),
        .PIPE_SEL("FALSE"),
        .REFCLK_FREQUENCY(200.0),
        .SIGNAL_PATTERN("DATA")
    ) u_idelay_rxctl (
        .IDATAIN(phy1_rxctl),
        .DATAOUT(rxctl_dly),
        .DATAIN(1'b0),
        .C(1'b0),
        .CE(1'b0),
        .INC(1'b0),
        .CINVCTRL(1'b0),
        .CNTVALUEIN(5'b0),
        .CNTVALUEOUT(),
        .LD(1'b0),
        .LDPIPEEN(1'b0),
        .REGRST(1'b0)
    );

    // --- RGMII RX → GMII (IDDR SAME_EDGE_PIPELINED on gmii_clk) ---
    // Q1 = low nibble (gmii_clk rise = raw RXC fall), Q2 = high nibble.
    wire [3:0] rx_q1, rx_q2;
    wire       rxctl_q1, rxctl_q2;
    generate
        for (i = 0; i < 4; i = i + 1) begin : gen_iddr_rx
            IDDR #(.DDR_CLK_EDGE("SAME_EDGE_PIPELINED"), .INIT_Q1(1'b0), .INIT_Q2(1'b0), .SRTYPE("SYNC"))
                u_iddr (.Q1(rx_q1[i]), .Q2(rx_q2[i]), .C(gmii_clk), .CE(1'b1),
                        .D(rxd_dly[i]), .R(1'b0), .S(1'b0));
        end
    endgenerate
    IDDR #(.DDR_CLK_EDGE("SAME_EDGE_PIPELINED"), .INIT_Q1(1'b0), .INIT_Q2(1'b0), .SRTYPE("SYNC"))
        u_iddr_rxctl (.Q1(rxctl_q1), .Q2(rxctl_q2), .C(gmii_clk), .CE(1'b1),
                      .D(rxctl_dly), .R(1'b0), .S(1'b0));
    // Demo re-register stage: one cycle, all three signals together.
    reg [7:0] e_rxd;
    reg       e_rxdv, e_rxer;
    always @(posedge gmii_clk) begin
        e_rxd  <= {rx_q2, rx_q1};
        e_rxdv <= rxctl_q1;
        e_rxer <= rxctl_q1 ^ rxctl_q2;
    end
"""
new_clock = """    // --- RGMII adapter: the k720 demo's util_gmii_to_rgmii.v VERBATIM ---
    // Includes its own BUFG(inverted RXC) + IDELAYE2(10) + IDDR/ODDR chain
    // and exposes gmii_rx_clk for the whole design. speed=2'b10 (gigabit),
    // duplex=1, reset tied off (like the demo's ethernet_test.v).
    wire gmii_clk;
    wire [7:0] e_rxd;
    wire       e_rxdv, e_rxer;
    wire [7:0] e_txd;     // bridged TX byte (assigned in the FIFO section)
    wire       e_txen;    // bridged TX enable (assigned in the FIFO section)
    util_gmii_to_rgmii u_rgmii (
        .reset          (1'b0),
        .rgmii_td       (phy1_txd),
        .rgmii_tx_ctl   (phy1_txctl),
        .rgmii_txc      (phy1_txc),
        .rgmii_rd_i     (phy1_rxd),
        .rgmii_rx_ctl_i (phy1_rxctl),
        .gmii_rx_clk    (gmii_clk),
        .rgmii_rxc      (phy1_rxc),
        .gmii_txd       (e_txd),
        .gmii_tx_en     (e_txen),
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
"""
assert old_clock in src, "old clock section not found"
src = src.replace(old_clock, new_clock)

old_tx = """    // --- GMII TX → RGMII (demo pipeline) ---
    // TX clock = gmii_clk. The demo's "gmii_txd_low" is a REGISTER with
    // blocking assignment, so it reads txd_r's OLD value at each edge —
    // i.e. it equals txd_r_d1[7:4]. Net effect: BOTH D1 and D2 come from
    // the SAME 2-cycle-delayed byte (classic RGMII DDR, 2-cycle latency).
    reg [7:0] gmii_txd_r, gmii_txd_r_d1;
    reg       gmii_tx_en_r, gmii_tx_en_r_d1;
    always @(posedge gmii_clk) begin
        gmii_txd_r      <= e_txd;
        gmii_tx_en_r    <= e_txen;
        gmii_txd_r_d1   <= gmii_txd_r;
        gmii_tx_en_r_d1 <= gmii_tx_en_r;
    end
    generate
        for (i = 0; i < 4; i = i + 1) begin : gen_oddr_tx
            ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC"))
                u_oddr (.Q(phy1_txd[i]), .C(gmii_clk), .CE(1'b1),
                        .D1(gmii_txd_r_d1[i]), .D2(gmii_txd_r_d1[i+4]), .R(1'b0), .S(1'b0));
        end
    endgenerate
    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC"))
        u_oddr_txctl (.Q(phy1_txctl), .C(gmii_clk), .CE(1'b1),
                      .D1(gmii_tx_en_r_d1), .D2(gmii_tx_en_r_d1), .R(1'b0), .S(1'b0));
    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("SYNC"))
        u_oddr_txc (.Q(phy1_txc), .C(gmii_clk), .CE(1'b1),
                    .D1(1'b1), .D2(1'b0), .R(1'b0), .S(1'b0));
"""
new_tx = """    // --- GMII TX → RGMII: handled inside the demo's util module above;
    // the bridged e_txd/e_txen connect directly to its gmii_txd/gmii_tx_en.
"""
assert old_tx in src, "old tx section not found"
src = src.replace(old_tx, new_tx)

src = src.replace("    wire [7:0] e_txd  = tx_draining ? tx_fifo[tx_rptr][7:0] : 8'h00;\n    wire       e_txen = tx_draining;\n    wire       e_txer = 1'b0;\n",
                  "    wire [7:0] e_txd  = tx_draining ? tx_fifo[tx_rptr][7:0] : 8'h00;\n    wire       e_txen = tx_draining;\n")

open(p, 'w', encoding='utf-8', newline='').write(src)
print("wrapper converted to demo module OK")
