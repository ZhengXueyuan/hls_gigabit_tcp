set project_name test_net
create_project -force $project_name ./test_prj -part xc7a35tftg256-1
import_files -norecurse [glob udp_echo_prj/solution1/syn/verilog/*.v]
import_files -norecurse wrapper_net_only.v
add_files -fileset constrs_1 ../udp/udp1.srcs/constrs_1/new/tedy.xdc
set src_dir [file dirname [lindex [glob test_prj/test_net.srcs/sources_1/imports/verilog/*.v] 0]]
foreach dat [glob -nocomplain udp_echo_prj/solution1/syn/verilog/*.dat] { file copy -force $dat $src_dir/ }
set_property top wrapper [current_fileset]
update_compile_order -fileset sources_1
launch_runs impl_1 -jobs 8
wait_on_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
puts "BITSTREAM DONE"
exit
