`timescale 1ns/1ps
//=============================================================================
// eth_rebuild_top.v — k720 demo top REBUILT with Vivado 2025.2
// ethernet_top.v (from DEMO/k720_rgmii_ethernet1) VERBATIM except:
//   clk_ref (a 2019.2 clk_wiz IP) replaced by a direct MMCME2_BASE with the
//   same outputs (clk_out1=200MHz for IDELAYCTRL, clk_out2=50MHz sys_clk).
// Purpose: isolate the 2025.2-vs-2019.2 build as the remaining variable.
// All other RTL (ethernet_test, util_gmii_to_rgmii, gmii_arbi, mac_*) is the
// project's original source, unmodified.
//=============================================================================
module eth_rebuild_uart_top
        (
        input clk,
        input rstn,
        output [7:0] led,

        output[3:0] rgmii_txd1,
        output rgmii_txctl1,
        output rgmii_txc1,
        input[3:0] rgmii_rxd1,
        input rgmii_rxctl1,
        input rgmii_rxc1,
        input  rs232_rx,
        output rs232_tx
        );
wire delay_ready;
wire sys_clk_200m;
wire sys_clk;
wire locked;
wire ref_fb;

assign led[4]=delay_ready;
assign led[1]='b0;
assign led[3]='b0;
assign led[5]='b0;
assign led[6]=locked;
assign led[7]='b0;

// --- clk_ref replacement: MMCME2_BASE, 50MHz in -> 200MHz (CLKOUT0) + 50MHz (CLKOUT1)
// VCO = 50 x 20 = 1000MHz; CLKOUT0 /5 = 200MHz, CLKOUT1 /20 = 50MHz.
MMCME2_BASE #(
    .BANDWIDTH("OPTIMIZED"),
    .CLKIN1_PERIOD(20.0),
    .CLKFBOUT_MULT_F(20.0),
    .CLKFBOUT_PHASE(0.0),
    .DIVCLK_DIVIDE(1),
    .CLKOUT0_DIVIDE_F(5.0),
    .CLKOUT0_DUTY_CYCLE(0.5),
    .CLKOUT0_PHASE(0.0),
    .CLKOUT1_DIVIDE(20),
    .CLKOUT1_DUTY_CYCLE(0.5),
    .CLKOUT1_PHASE(0.0),
    .CLKOUT2_DIVIDE(1), .CLKOUT2_DUTY_CYCLE(0.5), .CLKOUT2_PHASE(0.0),
    .CLKOUT3_DIVIDE(1), .CLKOUT3_DUTY_CYCLE(0.5), .CLKOUT3_PHASE(0.0),
    .CLKOUT4_DIVIDE(1), .CLKOUT5_DIVIDE(1), .CLKOUT6_DIVIDE(1),
    .REF_JITTER1(0.010),
    .STARTUP_WAIT("FALSE")
) mmcm_ref_inst (
    .CLKIN1(clk),
    .CLKOUT0(sys_clk_200m),
    .CLKOUT0B(),
    .CLKOUT1(sys_clk),
    .CLKOUT1B(),
    .CLKOUT2(), .CLKOUT2B(),
    .CLKOUT3(), .CLKOUT3B(),
    .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
    .CLKFBOUT(ref_fb),
    .CLKFBOUTB(),
    .CLKFBIN(ref_fb),
    .LOCKED(locked),
    .PWRDWN(1'b0),
    .RST(~rstn)
);

ethernet_test u1
                (
                .sys_clk_50m(sys_clk),
                .rst_n(rstn),
                .rgmii_txd(rgmii_txd1),
                .rgmii_txctl(rgmii_txctl1),
                .rgmii_txc(rgmii_txc1),
                .rgmii_rxd(rgmii_rxd1),
                .rgmii_rxctl(rgmii_rxctl1),
                .rgmii_rxc(rgmii_rxc1)
                );

(* IODELAY_GROUP = "idelay" *)
            IDELAYCTRL  idelayctrl_inst1(
            .RDY                  (delay_ready),
            .REFCLK               (sys_clk_200m),
            .RST                  ('b0)
        );

// --- UART stats probe (net_stats, same as the wrapper builds) ---
    wire gmii_tx_clk_u, gmii_rx_clk_u;
    wire [7:0] gmii_txd_u, gmii_rxd_u;
    wire gmii_tx_en_u, gmii_rx_dv_u;
    // tap the mark_debug wires inside u1
    assign gmii_tx_clk_u = u1.gmii_tx_clk;
    assign gmii_rx_clk_u = u1.gmii_rx_clk;
    assign gmii_txd_u    = u1.gmii_txd;
    assign gmii_rxd_u    = u1.gmii_rxd;
    assign gmii_tx_en_u  = u1.gmii_tx_en;
    assign gmii_rx_dv_u  = u1.gmii_rx_dv;

    reg [1:0] uart_sync_sr;
    always @(posedge clk or negedge rstn) begin
        if (!rstn) uart_sync_sr <= 2'b11;
        else       uart_sync_sr <= {uart_sync_sr[0], rs232_rx};
    end

    // frame toggles in the gmii domain + captures
    reg rx_tgl, tx_tgl, gmii_tx_en_d1, gmii_rx_dv_d1;
    always @(posedge gmii_tx_clk_u or negedge rstn) begin
        if (!rstn) begin rx_tgl<=0; tx_tgl<=0; gmii_tx_en_d1<=0; gmii_rx_dv_d1<=0; end
        else begin
            rx_tgl <= rx_tgl ^ (gmii_rx_dv_u && !gmii_rx_dv_d1);
            tx_tgl <= tx_tgl ^ (gmii_tx_en_u && !gmii_tx_en_d1);
            gmii_tx_en_d1 <= gmii_tx_en_u;
            gmii_rx_dv_d1 <= gmii_rx_dv_u;
        end
    end

    reg [4:0] tx_run;
    reg [7:0] tx_cap [0:15];
    reg       tx_cap_done;
    always @(posedge gmii_tx_clk_u or negedge rstn) begin
        if (!rstn) begin tx_run<=0; tx_cap_done<=0; end
        else begin
            if (!tx_cap_done) begin
                if (!gmii_tx_en_u) tx_run <= 5'd0;
                else begin
                    if (tx_run < 5'd31) tx_run <= tx_run + 5'd1;
                    if (tx_run == 5'd0)  tx_cap[0]  <= gmii_txd_u;
                    if (tx_run == 5'd1)  tx_cap[1]  <= gmii_txd_u;
                    if (tx_run == 5'd2)  tx_cap[2]  <= gmii_txd_u;
                    if (tx_run == 5'd3)  tx_cap[3]  <= gmii_txd_u;
                    if (tx_run == 5'd4)  tx_cap[4]  <= gmii_txd_u;
                    if (tx_run == 5'd5)  tx_cap[5]  <= gmii_txd_u;
                    if (tx_run == 5'd6)  tx_cap[6]  <= gmii_txd_u;
                    if (tx_run == 5'd7)  tx_cap[7]  <= gmii_txd_u;
                    if (tx_run == 5'd8)  tx_cap[8]  <= gmii_txd_u;
                    if (tx_run == 5'd9)  tx_cap[9]  <= gmii_txd_u;
                    if (tx_run == 5'd10) tx_cap[10] <= gmii_txd_u;
                    if (tx_run == 5'd11) tx_cap[11] <= gmii_txd_u;
                    if (tx_run == 5'd12) tx_cap[12] <= gmii_txd_u;
                    if (tx_run == 5'd13) tx_cap[13] <= gmii_txd_u;
                    if (tx_run == 5'd14) tx_cap[14] <= gmii_txd_u;
                    if (tx_run == 5'd15) tx_cap[15] <= gmii_txd_u;
                end
                if (!gmii_tx_en_u && tx_run >= 5'd15) tx_cap_done <= 1'b1;
            end
        end
    end

    reg [3:0] rx_run;
    reg [7:0] rx_cap [0:7];
    reg       rx_cap_done;
    always @(posedge gmii_rx_clk_u or negedge rstn) begin
        if (!rstn) begin rx_run<=0; rx_cap_done<=0; end
        else begin
            if (!rx_cap_done) begin
                if (!gmii_rx_dv_u) rx_run <= 4'd0;
                else begin
                    if (rx_run < 4'd7) rx_run <= rx_run + 4'd1;
                    if (rx_run == 4'd0) rx_cap[0] <= gmii_rxd_u;
                    if (rx_run == 4'd1) rx_cap[1] <= gmii_rxd_u;
                    if (rx_run == 4'd2) rx_cap[2] <= gmii_rxd_u;
                    if (rx_run == 4'd3) rx_cap[3] <= gmii_rxd_u;
                    if (rx_run == 4'd4) rx_cap[4] <= gmii_rxd_u;
                    if (rx_run == 4'd5) rx_cap[5] <= gmii_rxd_u;
                    if (rx_run == 4'd6) rx_cap[6] <= gmii_rxd_u;
                    if (rx_run == 4'd7) rx_cap[7] <= gmii_rxd_u;
                end
                if (!gmii_rx_dv_u && rx_run >= 4'd7) rx_cap_done <= 1'b1;
            end
        end
    end

    net_stats u_net_stats (
        .clk50      (clk),
        .reset_n    (rstn),
        .uart_rx    (uart_sync_sr[1]),
        .uart_tx_in (1'b1),
        .uart_tx_out(rs232_tx),
        .rx_toggle  (rx_tgl),
        .tx_toggle  (tx_tgl),
        .stat_lock  (delay_ready & locked),
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

endmodule
