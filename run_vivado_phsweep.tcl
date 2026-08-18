# wrapper_min with auto phase sweep (VARIABLE IDELAY on RXC)
set project_name  udp_phsweep
set top_module    wrapper_min_phsweep
set part_name     xc7k325tffg676-2

create_project -force $project_name ./vivado_prj -part $part_name

import_files -norecurse wrapper_min_phsweep.v
import_files -norecurse net_stats.v
import_files -norecurse util_gmii_to_rgmii.v

add_files -fileset constrs_1 xdc/eco_rgmii_phy1.xdc

set_property top $top_module [current_fileset]
update_compile_order -fileset sources_1

launch_runs synth_1 -jobs 8
wait_on_run synth_1
launch_runs impl_1 -jobs 8
wait_on_run impl_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

puts "\n===== PHSWEEP BITSTREAM DONE ====="
exit
