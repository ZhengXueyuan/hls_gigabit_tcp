set dcp [lindex $argv 0]
open_checkpoint $dcp
puts "=== TIMING SUMMARY ==="
report_timing_summary -file check_ts.txt
puts "=== HOLD VIOLATIONS (worst 20) ==="
report_timing -hold -max_paths 20 -file check_hold.txt
puts "=== SETUP VIOLATIONS (worst 20) ==="
report_timing -setup -max_paths 20 -file check_setup.txt
puts "DONE"
exit
