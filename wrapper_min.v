`timescale 1ns/1ps
//=============================================================================
// wrapper_min.v — MINIMAL design: NO HLS IPs at all.
//   demo-clone frame generator + verbatim k720 RGMII + MMCM/IDELAYCTRL +
//   UART stats probe (net_stats only, no uart_console IP).
//   Purpose (2026-08-18): decisive power/size experiment. If THIS reaches
//   the PC, the big design's activity is the cause of the zero-TX problem.
//   If even this fails, our wrapper's RGMII environment is broken
//   independent of the HLS IPs.
//   The demo-clone generator sends the exact k720 ipsend frame (72B GMII:
//   55x7 D5 + FFx6 + 00:0A:35:01:FE:C0 + ARP who-has 192.168.0.3 + 46B
//   payload + real CRC32) once per second. The k720 demo bitstream sends
//   the same bytes and the PC receives them.
//   UART console: net_stats alone (it has its own 9600-8N1 RX parser and
//   TX FSM with full 10-bit spacing). Commands: ?net ?txd ?rxd.
//=============================================================================

module wrapper_min (
    input           reset_n,        // async reset, active low (KEY1)
    input           fpga_gclk,      // 50MHz board oscillator (MMCM ref)
    // RGMII RX from PHY (RTL8211E)
    input           phy1_rxc,
    input  [3:0]    phy1_rxd,
    input           phy1_rxctl,
    // RGMII TX to PHY
    output          phy1_txc,
    output [3:0]    phy1_txd,
    output          phy1_txctl,
    // UART
    input           rs232_rx,
    output          rs232_tx,
    // LEDs
    output          led_d0,
    output          led_d1,
    output          led_d2,
    output          led_d3
);

    // --- 200MHz IDELAYCTRL reference: MMCM from 50MHz board clock ---
    wire ref200_clk, ref200_clk_raw, ref200_fb, mmcm_ref_locked;
    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKIN1_PERIOD(20.0),
        .CLKFBOUT_MULT_F(20.0),
        .CLKFBOUT_PHASE(0.0),
        .DIVCLK_DIVIDE(1),
        .CLKOUT0_DIVIDE_F(5.0),
        .CLKOUT0_DUTY_CYCLE(0.5),
        .CLKOUT0_PHASE(0.0),
        .CLKOUT1_DIVIDE(1), .CLKOUT1_DUTY_CYCLE(0.5), .CLKOUT1_PHASE(0.0),
        .CLKOUT2_DIVIDE(1), .CLKOUT2_DUTY_CYCLE(0.5), .CLKOUT2_PHASE(0.0),
        .CLKOUT3_DIVIDE(1), .CLKOUT3_DUTY_CYCLE(0.5), .CLKOUT3_PHASE(0.0),
        .CLKOUT4_DIVIDE(1), .CLKOUT5_DIVIDE(1), .CLKOUT6_DIVIDE(1),
        .REF_JITTER1(0.010),
        .STARTUP_WAIT("FALSE")
    ) u_mmcm_ref (
        .CLKIN1(fpga_gclk),
        .CLKOUT0(ref200_clk_raw),
        .CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(),
        .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
        .CLKFBOUT(ref200_fb), .CLKFBOUTB(),
        .CLKFBIN(ref200_fb),
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

    // --- RGMII adapter: k720 demo util_gmii_to_rgmii.v VERBATIM ---
    wire gmii_clk;
    wire [7:0] e_rxd;
    wire       e_rxdv, e_rxer;
    wire [7:0] e_txd;
    wire       e_txen;

    // --- DEMO-CLONE frame generator (k720 ipsend clone, 72B @1Hz) ---
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
    reg [6:0]  demo_idx;
    reg        demo_sending;
    reg [31:0] demo_crc;
    wire       demo_tick = (demo_cnt == 27'd124999999);
    always @(posedge gmii_clk or negedge reset_n) begin
        if (!reset_n) begin
            demo_cnt<=0; demo_idx<=0; demo_sending<=0; demo_crc<=32'hFFFFFFFF;
        end else begin
            if (demo_cnt >= 27'd124999999) demo_cnt <= 27'd0;
            else                            demo_cnt <= demo_cnt + 27'd1;
            if (demo_tick && !demo_sending) begin
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
    wire [31:0] demo_fcs = ~demo_crc;
    wire [7:0] demo_out =
        (demo_idx < 7'd68) ? demo_byte(demo_idx) :
        // FIX 2026-08-18 #2: the board's PHY/NIC chain expects the FCS in
        // LSB-first byte order (demo's wire FCS = CA A3 F9 63 = zlib register
        // little-endian). MSB-first (63 F9 A3 CA) frames were silently dropped.
        (demo_idx == 7'd68) ? demo_fcs[7:0]  :
        (demo_idx == 7'd69) ? demo_fcs[15:8] :
        (demo_idx == 7'd70) ? demo_fcs[23:16] :
                              demo_fcs[31:24];

    assign e_txd  = demo_sending ? demo_out : 8'h00;
    assign e_txen = demo_sending;

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
        .duplex_mode    (1'b1)
    );

    // --- RX regs + frame counter ---
    reg [7:0]  rx_d1, rx_d2; reg rx_dv_d1, rx_dv_d2;
    always @(posedge gmii_clk or negedge reset_n) begin
        if (!reset_n) begin rx_d1<=0;rx_d2<=0;rx_dv_d1<=0;rx_dv_d2<=0; end
        else begin rx_d1<=e_rxd;rx_d2<=rx_d1;rx_dv_d1<=e_rxdv;rx_dv_d2<=rx_dv_d1; end
    end

    reg rx_tgl, tx_tgl, e_txen_d1;
    always @(posedge gmii_clk or negedge reset_n) begin
        if (!reset_n) begin rx_tgl<=0; tx_tgl<=0; e_txen_d1<=0; end
        else begin
            rx_tgl <= rx_tgl ^ (rx_dv_d1 && !rx_dv_d2);
            tx_tgl <= tx_tgl ^ (e_txen && !e_txen_d1);
            e_txen_d1 <= e_txen;
        end
    end

    // --- TX frame capture: first 16 bytes of the FIRST TX frame (?txd) ---
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
                if (!e_txen && tx_run >= 5'd15) tx_cap_done <= 1'b1;
            end
        end
    end

    // --- RX frame capture: first 8 bytes of the FIRST RX frame (?rxd) ---
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

    // --- UART: sync RX, drive stats module (no uart_console IP) ---
    reg [1:0] uart_sync_sr;
    always @(posedge fpga_gclk or negedge reset_n) begin
        if (!reset_n) uart_sync_sr <= 2'b11;
        else          uart_sync_sr <= {uart_sync_sr[0], rs232_rx};
    end

    net_stats u_net_stats (
        .clk50      (fpga_gclk),
        .reset_n    (reset_n),
        .uart_rx    (uart_sync_sr[1]),
        .uart_tx_in (1'b1),          // no console; stats drives TX alone
        .uart_tx_out(rs232_tx),
        .rx_toggle  (rx_tgl),
        .tx_toggle  (tx_tgl),
        .stat_lock  (delay_ready & mmcm_ref_locked),
        .dbg0       (16'h0000),
        .dbg1       (1'b1),
        .tx_cap     ({tx_cap[15], tx_cap[14], tx_cap[13], tx_cap[12],
                      tx_cap[11], tx_cap[10], tx_cap[9],  tx_cap[8],
                      tx_cap[7],  tx_cap[6],  tx_cap[5],  tx_cap[4],
                      tx_cap[3],  tx_cap[2],  tx_cap[1],  tx_cap[0]}),
        .rx_cap     ({rx_cap[7], rx_cap[6], rx_cap[5], rx_cap[4],
                      rx_cap[3], rx_cap[2], rx_cap[1], rx_cap[0]}),
        .raw_cap    (128'h0)
    );

    // --- LEDs ---
    assign led_d0 = 1'b0;
    assign led_d1 = 1'b0;
    assign led_d2 = delay_ready;
    assign led_d3 = mmcm_ref_locked;

endmodule
