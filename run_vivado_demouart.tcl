#=============================================================================
# Vivado script — demo rebuild + UART stats probe (UART infra isolation test)
#=============================================================================
set project_name  udp_demouart
set top_module    eth_rebuild_uart_top
set part_name     xc7k325tffg676-2

set demo_dir      D:/repo/ECO/DEMO/k720_rgmii_ethernet1

create_project -force $project_name ./vivado_prj -part $part_name

import_files -norecurse eth_rebuild_uart_top.v
import_files -norecurse $demo_dir/eth_test.srcs/sources_1/imports/src/ethernet_test.v
import_files -norecurse $demo_dir/eth_test.srcs/sources_1/imports/src/util_gmii_to_rgmii.v
import_files -norecurse [glob $demo_dir/eth_test.srcs/sources_1/mac/*.v]
import_files -norecurse [glob $demo_dir/eth_test.srcs/sources_1/mac/rx/*.v]
import_files -norecurse [glob $demo_dir/eth_test.srcs/sources_1/mac/tx/*.v]
import_files -norecurse [glob $demo_dir/src/arbi/*.v]
foreach ip {eth_data_fifo len_fifo udp_tx_data_fifo udp_checksum_fifo udp_rx_ram_8_2048 icmp_rx_ram_8_256} {
    import_files -norecurse $demo_dir/eth_test.srcs/sources_1/ip/$ip/$ip.dcp
}
import_files -norecurse net_stats.v

add_files -fileset constrs_1 xdc/demo_rebuild_uart.xdc

set_property top $top_module [current_fileset]
update_compile_order -fileset sources_1

launch_runs synth_1 -jobs 8
wait_on_run synth_1
launch_runs impl_1 -jobs 8
wait_on_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

puts "\n===== DEMO-UART BITSTREAM DONE ====="
exit
