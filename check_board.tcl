open_hw_manager
connect_hw_server
refresh_hw_server
puts "TARGETS: [get_hw_targets]"
set target [lindex [get_hw_targets] 0]
open_hw_target $target
puts "DEVICES: [get_hw_devices]"
set device [lindex [get_hw_devices] 0]
puts "PART: [get_property PART $device]"
close_hw_target $target
exit
