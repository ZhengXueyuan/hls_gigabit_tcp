# run_vivado_v2_phy1.tcl — wrapper_v2 on PHY1 (AB2 group, bank 34 LVCMOS18)
# MDIO write targets PHYAD 1 (wrapper_v2_phy1.v); MDIO bus = AA25/Y25.
set project_name  udp_dual_v2_phy1
set top_module    wrapper_v2
set part_name     xc7k325tffg676-2

create_project -force $project_name ./vivado_prj -part $part_name
import_files -norecurse [glob udp_echo_prj/solution1/syn/verilog/*.v]
import_files -norecurse [glob uart_hls/uart_prj/solution1/syn/verilog/*.v]
import_files -norecurse wrapper_v2_phy1.v

set src_dir [file dirname [lindex [glob vivado_prj/udp_dual_v2_phy1.srcs/sources_1/imports/verilog/*.v] 0]]
foreach dat [glob -nocomplain udp_echo_prj/solution1/syn/verilog/*.dat] { file copy -force $dat $src_dir/ }
foreach dat [glob -nocomplain uart_hls/uart_prj/solution1/syn/verilog/*.dat] { file copy -force $dat $src_dir/ }

add_files -fileset constrs_1 xdc/eco_rgmii_phy1.xdc
set_property top $top_module [current_fileset]
update_compile_order -fileset sources_1

launch_runs synth_1 -jobs 8
wait_on_run synth_1
launch_runs impl_1 -jobs 8
wait_on_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
puts "\n===== BITSTREAM DONE ====="
exit
