create_project -force uo ./uo_prj -part xc7a35tftg256-1
import_files -norecurse [glob uart_hls/uart_prj/solution1/syn/verilog/*.v]
import_files -norecurse uart_test_only.v
add_files -fileset constrs_1 xdc/uart_fixed.xdc
set_property top wrapper [current_fileset]
update_compile_order -fileset sources_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
puts "DONE"
exit
