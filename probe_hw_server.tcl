open_hw_manager
puts "===== CONNECT SERVER localhost:3121 ====="
connect_hw_server -url localhost:3121
puts "===== HW TARGETS ====="
set targets [get_hw_targets -quiet]
foreach t $targets {
    puts "TARGET: $t"
    foreach p [list_property $t] {
        set val [get_property $p $t]
        puts "  $p = $val"
    }
}
puts "===== TRY EACH TARGET ====="
foreach t $targets {
    puts ">>> TRYING: $t"
    if {[catch {current_hw_target $t} err]} {
        puts "  current_hw_target error: $err"
        continue
    }
    if {[catch {open_hw_target} err]} {
        puts "  open_hw_target error: $err"
        continue
    }
    puts "  TARGET OPENED OK"
    foreach d [get_hw_devices -quiet] {
        puts "  DEVICE: $d"
        set props [list_property $d]
        foreach p $props {
            if {[string match "*name*" $p] || [string match "*idcode*" $p] || [string match "*status*" $p] || [string match "*part*" $p] || [string match "*manufacturer*" $p]} {
                puts "    $p = [get_property $p $d]"
            }
        }
    }
    catch {close_hw_target}
}
puts "===== PROBE DONE ====="
exit
