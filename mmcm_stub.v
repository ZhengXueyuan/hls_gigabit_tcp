`timescale 1ns/1ps
// sim-only stub: 200MHz CLKOUT0, locked=1
module MMCME2_BASE_REF #(
    parameter BANDWIDTH = "OPTIMIZED",
    parameter CLKIN1_PERIOD = 20.0,
    parameter CLKFBOUT_MULT_F = 20.0,
    parameter CLKFBOUT_PHASE = 0.0,
    parameter DIVCLK_DIVIDE = 1,
    parameter CLKOUT0_DIVIDE_F = 5.0,
    parameter CLKOUT0_DUTY_CYCLE = 0.5,
    parameter CLKOUT0_PHASE = 0.0,
    parameter CLKOUT1_DIVIDE = 1,
    parameter CLKOUT1_DUTY_CYCLE = 0.5,
    parameter CLKOUT1_PHASE = 0.0,
    parameter CLKOUT2_DIVIDE = 1,
    parameter CLKOUT2_DUTY_CYCLE = 0.5,
    parameter CLKOUT2_PHASE = 0.0,
    parameter CLKOUT3_DIVIDE = 1,
    parameter CLKOUT3_DUTY_CYCLE = 0.5,
    parameter CLKOUT3_PHASE = 0.0,
    parameter CLKOUT4_DIVIDE = 1,
    parameter CLKOUT5_DIVIDE = 1,
    parameter CLKOUT6_DIVIDE = 1,
    parameter REF_JITTER1 = 0.010,
    parameter STARTUP_WAIT = "FALSE"
) (
    input CLKIN1,
    output CLKOUT0, CLKOUT0B, CLKOUT1, CLKOUT1B, CLKOUT2, CLKOUT2B,
    output CLKOUT3, CLKOUT3B, CLKOUT4, CLKOUT5, CLKOUT6,
    output CLKFBOUT, CLKFBOUTB,
    input CLKFBIN,
    output LOCKED,
    input PWRDWN, RST
);
reg clkout0_r = 0;
always #2.5 clkout0_r = ~clkout0_r;
assign CLKOUT0 = clkout0_r;
assign CLKOUT0B = ~clkout0_r;
assign LOCKED = 1'b1;
endmodule
