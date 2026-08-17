`timescale 1ns/1ps
//=============================================================================
// eth_rebuild_gen_top.v — demo rebuild + demo_clone TX source (test)
// Same pins/XDC as the working demo rebuild (eth_rebuild_top), but the TX
// source is eth_test_gen (the wrapper_min-style demo_clone generator,
// combinational demo_out -> e_txd/e_txen directly into util_gmii_to_rgmii).
// RX infrastructure (MMCM/IDELAYCTRL) removed: this design has no RX
// consumers so the IDELAYCTRL would be optimized away (driverless LED).
// Purpose: isolate the TX source structure (registered mac_test pipeline
// vs combinational demo_clone mux) as the failure variable.
//=============================================================================
module eth_rebuild_gen_top
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
wire sys_clk;
wire locked;

assign led[4]=1'b1;   // delay_ready (IDELAYCTRL removed for this test)
assign led[1]='b0;
assign led[3]='b0;
assign led[5]='b0;
assign led[6]=1'b1;   // locked
assign led[7]='b0;

eth_test_gen u1
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

endmodule
