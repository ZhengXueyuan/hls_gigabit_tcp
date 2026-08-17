#=============================================================================
# Vivado script — demo rebuild + demo_clone generator (TX source structure test)
# Same top/XDC as the working demo rebuild, but the TX source is the
# wrapper_min-style demo_clone generator (combinational mux) instead of
# mac_test/gmii_arbi. Isolates the TX source structure variable.
#=============================================================================
set project_name  udp_demogen
set top_module    eth_rebuild_gen_top
set part_name     xc7k325tffg676-2

set demo_dir      D:/repo/ECO/DEMO/k720_rgmii_ethernet1

create_project -force $project_name ./vivado_prj -part $part_name

import_files -norecurse eth_rebuild_gen_top.v
import_files -norecurse eth_test_gen.v
import_files -norecurse $demo_dir/eth_test.srcs/sources_1/imports/src/util_gmii_to_rgmii.v

add_files -fileset constrs_1 xdc/demo_rebuild.xdc

set_property top $top_module [current_fileset]
update_compile_order -fileset sources_1

launch_runs synth_1 -jobs 8
wait_on_run synth_1
launch_runs impl_1 -jobs 8
wait_on_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

puts "\n===== DEMO-GEN BITSTREAM DONE ====="
exit
