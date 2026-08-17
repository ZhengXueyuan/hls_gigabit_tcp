open_hw_manager
puts "===== HW TARGETS ====="
foreach t [get_hw_targets -quiet] {
    puts "TARGET: $t"
}
puts "===== HW SERVERS ====="
foreach s [get_hw_servers -quiet] {
    puts "SERVER: $s"
}
puts "===== OPEN TARGET (first) ====="
set tg [get_hw_targets -quiet]
if {[llength $tg] > 0} {
    current_hw_target [lindex $tg 0]
    open_hw_target
    puts "TARGET OPENED OK"
    puts "===== DEVICES ====="
    foreach d [get_hw_devices -quiet] {
        puts "DEVICE: $d"
    }
    close_hw_target
}
puts "===== PROBE DONE ====="
exit
