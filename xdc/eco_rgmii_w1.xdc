#=============================================================================
# eco_rgmii.xdc — Kintex7 ECO board R3 pin constraints for udp_hls wrapper
#=============================================================================
# Pin selection policy (documented 2026-08-16, board-verified with gmii_probe):
#   - UART / clock / reset / LEDs: demo-proven pins (k701/k707 verified on THIS
#     physical board; strap agent's wire-tracing agrees).
#   - PHY1 RGMII: **k719/k720 DEMO pin set** — board-verified with gmii_probe:
#     the probe sees a real 2.5MHz idle clock on AB2 (demo rxc1) while the
#     R3-schematic pin (W1) reads ZERO edges → the physical board follows the
#     demo pinout, NOT the R3 schematic's PHY1 assignment.
#   - mdc/mdio/nrst kept on W4/W1/V1 (schematic) — harmless placeholders;
#     the wrapper does not use MDIO (PHY runs on straps, like the demos).
#=============================================================================

# --- Configuration ---
set_property CFGBVS VCCO [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 50 [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN Pullup [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

# --- Clocks ---
# phy1_rxc: RGMII RX clock from RTL8211E (125MHz at 1G link). AB2 is a
# clock-capable SRCC pin → BUFG connects via the dedicated route directly.
create_clock -period 8.000 -name phy1_rxc [get_ports phy1_rxc]
# fpga_gclk: 50MHz board oscillator (demo-proven pin G22); also feeds the
# wrapper's MMCM that produces the 200MHz IDELAYCTRL reference.
create_clock -period 20.000 -name fpga_gclk [get_ports fpga_gclk]
# fpga_gclk: 50MHz board oscillator (demo-proven pin G22)
create_clock -period 20.000 -name fpga_gclk [get_ports fpga_gclk]

# --- PHY1 RGMII (bank 34, LVCMOS18) ---
set_property PACKAGE_PIN W1  [get_ports phy1_rxc]
set_property PACKAGE_PIN AA5 [get_ports {phy1_rxd[0]}]
set_property PACKAGE_PIN AC4 [get_ports {phy1_rxd[1]}]
set_property PACKAGE_PIN V2  [get_ports {phy1_rxd[2]}]
set_property PACKAGE_PIN AB2 [get_ports {phy1_rxd[3]}]
set_property PACKAGE_PIN AB6 [get_ports phy1_rxctl]
set_property PACKAGE_PIN Y2  [get_ports phy1_txc]
set_property PACKAGE_PIN AA4 [get_ports {phy1_txd[0]}]
set_property PACKAGE_PIN AA2 [get_ports {phy1_txd[1]}]
set_property PACKAGE_PIN AC2 [get_ports {phy1_txd[2]}]
set_property PACKAGE_PIN AA3 [get_ports {phy1_txd[3]}]
set_property PACKAGE_PIN V4  [get_ports phy1_txctl]
set_property PACKAGE_PIN W4  [get_ports phy1_mdc]
set_property PACKAGE_PIN AC1 [get_ports phy1_mdio]
set_property PACKAGE_PIN V1  [get_ports phy1_nrst]


set_property IOSTANDARD LVCMOS18 [get_ports phy1_rxc]
set_property IOSTANDARD LVCMOS18 [get_ports {phy1_rxd[*]}]
set_property IOSTANDARD LVCMOS18 [get_ports phy1_rxctl]
set_property IOSTANDARD LVCMOS18 [get_ports phy1_txc]
set_property IOSTANDARD LVCMOS18 [get_ports {phy1_txd[*]}]
set_property IOSTANDARD LVCMOS18 [get_ports phy1_txctl]
set_property IOSTANDARD LVCMOS18 [get_ports phy1_mdc]
set_property IOSTANDARD LVCMOS18 [get_ports phy1_mdio]
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

# --- LEDs (k701/k720 demo pins) ---
set_property PACKAGE_PIN A23 [get_ports led_d0]
set_property PACKAGE_PIN A24 [get_ports led_d1]
set_property PACKAGE_PIN D23 [get_ports led_d2]
set_property PACKAGE_PIN C24 [get_ports led_d3]
set_property IOSTANDARD LVCMOS33 [get_ports {led_d0 led_d1 led_d2 led_d3}]
set_property SLEW FAST [get_ports {led_d0 led_d1 led_d2 led_d3}]
