# program_eco.tcl — program ECO board over JTAG (1 MHz, verify startup HIGH)
# Usage: vivado -mode batch -source program_eco.tcl -tclargs <bitfile>
set bitfile [lindex $argv 0]
if {$bitfile eq ""} { set bitfile "D:/repo/ECO/udp_hls_eco/vivado_prj/udp_dual_eco.runs/impl_1/wrapper.bit" }

open_hw_manager
if {[catch {connect_hw_server -url localhost:3121} msg]} { puts "HW_CONNECT_FAILED: $msg"; exit 1 }
set targets [get_hw_targets *]
if {[llength $targets] == 0} { puts "NO_TARGETS_FOUND"; exit 1 }
puts "TARGETS: $targets"
open_hw_target [lindex $targets 0]
set_property PARAM.FREQUENCY 1000000 [current_hw_target]
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
puts "=== PROGRAMMING $dev with $bitfile ==="
set_property PROGRAM.FILE $bitfile $dev
if {[catch {program_hw_devices $dev} msg]} { puts "PROGRAM_FAILED: $msg"; exit 1 }
puts "PROGRAM_OK"
close_hw_manager
exit 0
