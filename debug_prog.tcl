open_hw_manager
connect_hw_server
refresh_hw_server
set target [lindex [get_hw_targets] 0]
open_hw_target $target
set device [lindex [get_hw_devices] 0]
set_property PROGRAM.FILE "uo_prj/uo.runs/impl_1/wrapper.bit" $device
program_hw_devices $device
puts "UART_ONLY_PROG_DONE"
exit
