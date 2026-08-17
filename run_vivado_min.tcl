#=============================================================================
# Vivado script — dual-IP: Network + UART, Kintex7 ECO board (R3)
#=============================================================================
set project_name  udp_dual_min
set top_module    wrapper
set part_name     xc7k325tffg676-2

create_project -force $project_name ./vivado_prj -part $part_name

# Network IP RTL
import_files -norecurse [glob udp_echo_prj/solution1/syn/verilog/*.v]
# UART IP RTL
import_files -norecurse [glob uart_hls/uart_prj/solution1/syn/verilog/*.v]
# Wrapper
import_files -norecurse wrapper.v

# Copy .dat files for ROM init
set src_dir [file dirname [lindex [glob vivado_prj/udp_dual_min.srcs/sources_1/imports/verilog/*.v] 0]]
foreach dat [glob -nocomplain udp_echo_prj/solution1/syn/verilog/*.dat] { file copy -force $dat $src_dir/ }
foreach dat [glob -nocomplain uart_hls/uart_prj/solution1/syn/verilog/*.dat] { file copy -force $dat $src_dir/ }

# Constraints (ECO board: RGMII PHY1 + UART + clock + LEDs, all in one file)
add_files -fileset constrs_1 xdc/eco_rgmii_phy2.xdc

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
