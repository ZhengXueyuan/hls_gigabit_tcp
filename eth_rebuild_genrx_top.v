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
module eth_rebuild_genrx_top
        (
        input clk,
        input rstn,
        output [7:0] led,

        output[3:0] rgmii_txd1,
        output rgmii_txctl1,
        output rgmii_txc1,
        input[3:0] rgmii_rxd1,
        input rgmii_rxctl1,
        input rgmii_rxc1
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

eth_test_genrx u1
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

(* IODELAY_GROUP = "idelay", DONT_TOUCH = "true" *)
            IDELAYCTRL  idelayctrl_inst1(
            .RDY                  (delay_ready),
            .REFCLK               (sys_clk_200m),
            .RST                  ('b0)
        );

endmodule
