create_project -force qt ./qt_prj -part xc7a35tftg256-1
import_files -norecurse [glob udp_echo_prj/solution1/syn/verilog/*.v]
import_files -norecurse wrapper_net_only.v
add_files -fileset constrs_1 ../udp/udp1.srcs/constrs_1/new/tedy.xdc
set src_d [file dirname [lindex [glob qt_prj/qt.srcs/sources_1/imports/verilog/*.v] 0]]
foreach dat [glob -nocomplain udp_echo_prj/solution1/syn/verilog/*.dat] { file copy -force $dat $src_d/ }
set_property top wrapper [current_fileset]
update_compile_order -fileset sources_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1
puts "QUICK TEST DONE"
exit
