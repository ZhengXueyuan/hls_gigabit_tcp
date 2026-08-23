#=============================================================================
# ila_capture.tcl — program (optional) + arm ILA + wait trigger + export CSV
# Usage:
#   vivado -mode batch -source ila_capture.tcl -tclargs \
#       <bit> <ltx> <probeFilter> <compareValue> <trigPos> <csvOut> [skipProg]
# Example (trigger on tcp_q_len != 0, position 1024):
#   ... -tclargs a.bit a.ltx *probe4* ne16'h0000 1024 out.csv
#=============================================================================
set bit     [lindex $argv 0]
set ltx     [lindex $argv 1]
set pfilter [lindex $argv 2]
set cmpval  [lindex $argv 3]
set trigpos [lindex $argv 4]
set csvout  [lindex $argv 5]
set skip    [lindex $argv 6]

open_hw_manager
if {[catch {connect_hw_server -url localhost:3121} msg]} { puts "HW_CONNECT_FAILED: $msg"; exit 1 }
set targets [get_hw_targets *]
if {[llength $targets] == 0} { puts "NO_TARGETS_FOUND"; exit 1 }
open_hw_target [lindex $targets 0]
set_property PARAM.FREQUENCY 1000000 [current_hw_target]
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev

if {$skip ne "skipProg"} {
    set_property PROGRAM.FILE $bit $dev
    if {$ltx ne ""} { set_property PROBES.FILE $ltx $dev }
    puts "=== PROGRAMMING $dev with $bit ==="
    if {[catch {program_hw_devices $dev} msg]} { puts "PROGRAM_FAILED: $msg"; exit 1 }
    puts "PROGRAM_OK"
}
if {$ltx ne ""} { set_property PROBES.FILE $ltx $dev }
refresh_hw_device $dev

set ilas [get_hw_ilas -of_objects $dev]
if {[llength $ilas] == 0} { puts "NO_ILA_FOUND (bitstream lacks ILA?)"; exit 1 }
set ila [lindex $ilas 0]
puts "ILA: $ila"
set probes [get_hw_probes -of_objects $ila]
puts "PROBES:"
foreach p $probes { puts "  [get_property NAME $p] width=[get_property WIDTH $p]" }

# --- trigger configuration ---
set tprobe [get_hw_probes -of_objects $ila -filter "NAME =~ $pfilter"]
if {[llength $tprobe] != 1} { puts "TRIGGER_PROBE_AMBIGUOUS: $tprobe"; exit 1 }
puts "TRIGGER_PROBE: [get_property NAME $tprobe]"
set_property TRIGGER_COMPARE_VALUE $cmpval $tprobe
set_property CONTROL.TRIGGER_POSITION $trigpos $ila
set_property CONTROL.WINDOW_COUNT 1 $ila

puts "=== ARMING (pos=$trigpos cmp=$cmpval) ==="
run_hw_ila $ila
puts "ARMED_WAITING_FOR_TRIGGER"
if {[catch {wait_on_hw_ila -timeout 180 $ila} msg]} {
    puts "WAIT_TIMEOUT_OR_ERROR: $msg"
    exit 1
}
puts "TRIGGERED — uploading"
set d [upload_hw_ila_data $ila]
write_hw_ila_data -csv_file $csvout $d
puts "CAPTURE_SAVED $csvout"
close_hw_manager
exit 0
