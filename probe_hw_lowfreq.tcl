open_hw_manager
puts "===== CONNECT SERVER localhost:3121 (reconnect) ====="
catch {disconnect_hw_server}
connect_hw_server -url localhost:3121
set targets [get_hw_targets -quiet]
foreach t $targets {
    puts ">>> TARGET: $t"
    set_property PARAM.FREQUENCY 1000000 $t
    puts "    freq set to [get_property PARAM.FREQUENCY $t]"
    if {[catch {current_hw_target $t} err]} {
        puts "    current_hw_target error: $err"
        continue
    }
    if {[catch {open_hw_target} err]} {
        puts "    open_hw_target error: $err"
        continue
    }
    puts "    TARGET OPENED OK"
    puts "    DEVICE_COUNT = [get_property DEVICE_COUNT $t]"
    foreach d [get_hw_devices -quiet] {
        puts "    DEVICE: $d"
        foreach p [list_property $d] {
            puts "      $p = [get_property $p $d]"
        }
    }
    catch {close_hw_target}
}
puts "===== PROBE DONE ====="
exit
