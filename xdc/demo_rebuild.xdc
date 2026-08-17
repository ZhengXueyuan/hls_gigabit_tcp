#=============================================================================
# demo_rebuild.xdc — k720 demo top.xdc FILTERED to the ports that exist in
# eth_rebuild_top (the demo's rgmii_txd1/rgmii_rxc1 group + clk + rstn + led).
# Values copied verbatim from DEMO/k720_rgmii_ethernet1/top.xdc.
#=============================================================================
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 50 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN Pullup [current_design]
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

set_property PACKAGE_PIN H26 [get_ports rstn]
set_property IOSTANDARD LVCMOS33 [get_ports rstn]
set_property PACKAGE_PIN G22 [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports clk]

set_property PACKAGE_PIN A23 [get_ports {led[0]}]
set_property PACKAGE_PIN A24 [get_ports {led[1]}]
set_property PACKAGE_PIN D23 [get_ports {led[2]}]
set_property PACKAGE_PIN C24 [get_ports {led[3]}]
set_property PACKAGE_PIN C26 [get_ports {led[4]}]
set_property PACKAGE_PIN D24 [get_ports {led[5]}]
set_property PACKAGE_PIN D25 [get_ports {led[6]}]
set_property PACKAGE_PIN E25 [get_ports {led[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[*]}]
set_property SLEW FAST [get_ports {led[*]}]

set_property PACKAGE_PIN Y3  [get_ports rgmii_txctl1]
set_property PACKAGE_PIN AB1 [get_ports rgmii_txc1]
set_property PACKAGE_PIN AF3 [get_ports rgmii_rxctl1]
set_property PACKAGE_PIN AB2 [get_ports rgmii_rxc1]
set_property PACKAGE_PIN AE2 [get_ports {rgmii_rxd1[0]}]
set_property PACKAGE_PIN AE1 [get_ports {rgmii_rxd1[1]}]
set_property PACKAGE_PIN AC1 [get_ports {rgmii_rxd1[2]}]
set_property PACKAGE_PIN AC2 [get_ports {rgmii_rxd1[3]}]
set_property PACKAGE_PIN AB4 [get_ports {rgmii_txd1[0]}]
set_property PACKAGE_PIN AA4 [get_ports {rgmii_txd1[1]}]
set_property PACKAGE_PIN AA3 [get_ports {rgmii_txd1[2]}]
set_property PACKAGE_PIN AA2 [get_ports {rgmii_txd1[3]}]

set_property IOSTANDARD LVCMOS18 [get_ports rgmii_rxc1]
set_property IOSTANDARD LVCMOS18 [get_ports {rgmii_rxd1[*]}]
set_property IOSTANDARD LVCMOS18 [get_ports rgmii_rxctl1]
set_property IOSTANDARD LVCMOS18 [get_ports rgmii_txc1]
set_property IOSTANDARD LVCMOS18 [get_ports {rgmii_txd1[*]}]
set_property IOSTANDARD LVCMOS18 [get_ports rgmii_txctl1]
set_property SLEW FAST [get_ports {rgmii_txd1[*]}]
set_property SLEW FAST [get_ports rgmii_txc1]
set_property SLEW FAST [get_ports rgmii_txctl1]

# --- bisect: wrapper timing constraints added (isolate constraints as the variable) ---
create_clock -period 8.000 -name rgmii_rxc1 [get_ports rgmii_rxc1]
create_generated_clock -name gmii_clk \
    -source [get_ports rgmii_rxc1] -invert -divide_by 1 \
    [get_pins u1/util_gmii_to_rgmii_m0/bufmr_rgmii_rxc/O]
create_clock -period 20.000 -name clk_50m [get_ports clk]
