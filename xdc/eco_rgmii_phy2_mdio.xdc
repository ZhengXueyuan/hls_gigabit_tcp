#=============================================================================
# eco_rgmii_phy2_mdio.xdc — Kintex7 ECO board wrapper_v2 constraints
#   AA23 pin group (board-verified wired PHY set) + MDIO on the proven
#   AA25/Y25 pins (gmii_probe_eco probe_phy2_mdio.xdc, board-verified) so
#   the wrapper_v2 startup write (BMCR=0x2100 forced 100M-FD) reaches the
#   PHY.  Link is forced 100M → phy1_rxc = 25MHz / 40ns.
#=============================================================================

# --- Configuration ---
set_property CFGBVS VCCO [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 50 [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN Pullup [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

# --- Clocks ---
create_clock -period 40.000 -name phy1_rxc [get_ports phy1_rxc]
create_clock -period 20.000 -name fpga_gclk [get_ports fpga_gclk]

# --- RGMII (AA23 group, bank 12 LVCMOS33 — board-verified wired set) ---
set_property PACKAGE_PIN AA23 [get_ports phy1_rxc]
set_property PACKAGE_PIN V26 [get_ports {phy1_rxd[0]}]
set_property PACKAGE_PIN V21 [get_ports {phy1_rxd[1]}]
set_property PACKAGE_PIN U24 [get_ports {phy1_rxd[2]}]
set_property PACKAGE_PIN U25 [get_ports {phy1_rxd[3]}]
set_property PACKAGE_PIN U26 [get_ports phy1_rxctl]
set_property PACKAGE_PIN V24 [get_ports phy1_txc]
set_property PACKAGE_PIN V22 [get_ports {phy1_txd[0]}]
set_property PACKAGE_PIN W26 [get_ports {phy1_txd[1]}]
set_property PACKAGE_PIN W25 [get_ports {phy1_txd[2]}]
set_property PACKAGE_PIN W21 [get_ports {phy1_txd[3]}]
set_property PACKAGE_PIN W23 [get_ports phy1_txctl]
set_property PACKAGE_PIN AA25 [get_ports phy1_mdc]
set_property PACKAGE_PIN Y25  [get_ports phy1_mdio]
set_property PACKAGE_PIN V1   [get_ports phy1_nrst]

set_property IOSTANDARD LVCMOS33 [get_ports phy1_rxc]
set_property IOSTANDARD LVCMOS33 [get_ports {phy1_rxd[*]}]
set_property IOSTANDARD LVCMOS33 [get_ports phy1_rxctl]
set_property IOSTANDARD LVCMOS33 [get_ports phy1_txc]
set_property IOSTANDARD LVCMOS33 [get_ports {phy1_txd[*]}]
set_property IOSTANDARD LVCMOS33 [get_ports phy1_txctl]
set_property IOSTANDARD LVCMOS33 [get_ports phy1_mdc]
set_property IOSTANDARD LVCMOS33 [get_ports phy1_mdio]
set_property IOSTANDARD LVCMOS18 [get_ports phy1_nrst]
set_property SLEW FAST [get_ports {phy1_txd[*]}]
set_property SLEW FAST [get_ports phy1_txctl]
set_property SLEW FAST [get_ports phy1_txc]

# --- UART (CH340E, TTL 3.3V — demo-proven pins) ---
set_property PACKAGE_PIN B17 [get_ports rs232_rx]
set_property PACKAGE_PIN A17 [get_ports rs232_tx]
set_property IOSTANDARD LVCMOS33 [get_ports rs232_rx]
set_property IOSTANDARD LVCMOS33 [get_ports rs232_tx]
set_property PULLUP true [get_ports rs232_rx]
set_property DRIVE 12 [get_ports rs232_tx]
set_property SLEW SLOW [get_ports rs232_tx]

# --- Board clock / reset (demo-proven pins) ---
set_property PACKAGE_PIN G22 [get_ports fpga_gclk]
set_property IOSTANDARD LVCMOS33 [get_ports fpga_gclk]
set_property PACKAGE_PIN D26 [get_ports reset_n]
set_property IOSTANDARD LVCMOS33 [get_ports reset_n]
set_property PULLUP true [get_ports reset_n]

# --- LEDs ---
set_property PACKAGE_PIN A23 [get_ports led_d0]
set_property PACKAGE_PIN A24 [get_ports led_d1]
set_property PACKAGE_PIN D23 [get_ports led_d2]
set_property PACKAGE_PIN C24 [get_ports led_d3]
set_property IOSTANDARD LVCMOS33 [get_ports {led_d0 led_d1 led_d2 led_d3}]
set_property SLEW FAST [get_ports {led_d0 led_d1 led_d2 led_d3}]
