# UART pins (PerfV manual 2.11 USER JTAG: TX0→P9, RX0→N9)
# FPGA TX output → connector TX0 = P9
# FPGA RX input  ← connector RX0 = N9
set_property PACKAGE_PIN P9  [get_ports rs232_rx]
set_property PACKAGE_PIN N9  [get_ports rs232_tx]
set_property IOSTANDARD LVCMOS33 [get_ports rs232_rx]
set_property IOSTANDARD LVCMOS33 [get_ports rs232_tx]
set_property PULLUP true [get_ports rs232_rx]
set_property DRIVE 12 [get_ports rs232_tx]
set_property SLEW SLOW [get_ports rs232_tx]

# LEDs: D0=M16 D1=N16 D2=P15 D3=P16 (PerfV board manual 2.6.1)
set_property PACKAGE_PIN M16 [get_ports led_d0]
set_property PACKAGE_PIN N16 [get_ports led_d1]
set_property PACKAGE_PIN P15 [get_ports led_d2]
set_property PACKAGE_PIN P16 [get_ports led_d3]
set_property IOSTANDARD LVCMOS33 [get_ports led_d0]
set_property IOSTANDARD LVCMOS33 [get_ports led_d1]
set_property IOSTANDARD LVCMOS33 [get_ports led_d2]
set_property IOSTANDARD LVCMOS33 [get_ports led_d3]
