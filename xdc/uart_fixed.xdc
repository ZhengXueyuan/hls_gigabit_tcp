# UART pins only — clock/reset already in network XDC (tedy.xdc)
set_property PACKAGE_PIN P9  [get_ports rs232_rx]
set_property PACKAGE_PIN N9  [get_ports rs232_tx]
set_property IOSTANDARD LVCMOS33 [get_ports rs232_rx]
set_property IOSTANDARD LVCMOS33 [get_ports rs232_tx]
set_property DRIVE 12 [get_ports rs232_tx]
set_property SLEW SLOW [get_ports rs232_tx]
