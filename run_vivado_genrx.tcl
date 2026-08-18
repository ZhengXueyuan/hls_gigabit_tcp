# demo top + full RX chain/MMCM/IDELAYCTRL kept + demo_clone TX source only
set project_name  udp_genrx
set top_module    eth_rebuild_genrx_top
set part_name     xc7k325tffg676-2

set demo_dir      D:/repo/ECO/DEMO/k720_rgmii_ethernet1

create_project -force $project_name ./vivado_prj -part $part_name

import_files -norecurse eth_rebuild_genrx_top.v
import_files -norecurse eth_test_genrx.v
import_files -norecurse util_gmii_dt.v

add_files -fileset constrs_1 xdc/demo_rebuild.xdc

set_property top $top_module [current_fileset]
update_compile_order -fileset sources_1

launch_runs synth_1 -jobs 8
wait_on_run synth_1
launch_runs impl_1 -jobs 8
wait_on_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

puts "\n===== GENRX BITSTREAM DONE ====="
exit
