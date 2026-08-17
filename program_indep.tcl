#=============================================================================
# program_indep.tcl - Program via the independent downloader (210251391367)
# Usage: vivado -mode batch -source program_indep.tcl -tclargs <bitfile>
#=============================================================================
open_hw_manager
connect_hw_server -url localhost:3121
set targets [get_hw_targets -quiet]
puts "HW TARGETS: $targets"

# prefer the independent downloader (JTAG-SMT2); fall back to onboard
set chosen ""
foreach t $targets {
    if {[string match "*210251391367*" $t]} { set chosen $t; break }
}
if {$chosen eq ""} { set chosen [lindex $targets 0] }
puts "USING TARGET: $chosen"
if {$chosen eq ""} { puts "NO HW TARGET FOUND"; exit 1 }

current_hw_target $chosen
open_hw_target
# Reduce JTAG frequency to 1MHz - higher rates cause "End of startup status: LOW"
set_property PARAM.FREQUENCY 1000000 $chosen
set devices [get_hw_devices -quiet]
puts "HW DEVICES: $devices"
if {[llength $devices] == 0} { puts "NO DEVICE FOUND"; close_hw_target; exit 1 }

set device [lindex $devices 0]
set_property PROGRAM.FILE [lindex $argv 0] $device
program_hw_devices $device
puts "PROGRAM DONE"
close_hw_target
close_hw_manager
