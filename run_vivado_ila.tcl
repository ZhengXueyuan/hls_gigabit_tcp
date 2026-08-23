#=============================================================================
# run_vivado_ila.tcl — ILA build for the 2000B 4th-segment race hunt
#   Sources : ila_rtl_snapshot/*.v (EXCEPT udp_echo.v) + ila_dbg_src/udp_echo.v
#             (debug taps) + wrapper_1g_ila.v + net_stats.v + util_gmii_to_rgmii.v
#   Top     : wrapper_1g_ila  (ila_0 IP instantiated in RTL — no mark_debug,
#             no generate_debug_cores, no XDC channel wiring)
#=============================================================================
set project_name  udp_ila
set top_module    wrapper_1g_ila
set part_name     xc7k325tffg676-2

create_project -force $project_name ./vivado_ila_prj -part $part_name

# --- RTL: frozen snapshot minus stock udp_echo.v; debug-tapped copy instead ---
set srcs {}
foreach f [glob ila_rtl_snapshot/*.v] {
    if {[file tail $f] ne "udp_echo.v"} { lappend srcs $f }
}
import_files -norecurse $srcs
import_files -norecurse ila_dbg_src/udp_echo.v
import_files -norecurse wrapper_1g_ila.v net_stats.v util_gmii_to_rgmii.v

# --- HLS ROM/RAM init .dat files must sit next to the imported sources ---
# import_files buckets sources by their origin dir (imports/ila_rtl_snapshot,
# imports/ila_dbg_src, ...), so drop a copy of each .dat into every bucket.
foreach d [glob -nocomplain -type d vivado_ila_prj/udp_ila.srcs/sources_1/imports/*] {
    foreach dat [glob -nocomplain ila_rtl_snapshot/*.dat] { file copy -force $dat $d/ }
}

# --- ILA IP: 14 probes, 32768 samples deep (~262us @125MHz) ---
create_ip -name ila -vendor xilinx.com -library ip -version 6.2 -module_name ila_0
set_property -dict [list \
    CONFIG.C_NUM_OF_PROBES {14} \
    CONFIG.C_DATA_DEPTH {32768} \
    CONFIG.C_INPUT_PIPE_STAGES {0} \
    CONFIG.C_PROBE0_WIDTH {11} \
    CONFIG.C_PROBE1_WIDTH {11} \
    CONFIG.C_PROBE2_WIDTH {8} \
    CONFIG.C_PROBE3_WIDTH {8} \
    CONFIG.C_PROBE4_WIDTH {16} \
    CONFIG.C_PROBE5_WIDTH {16} \
    CONFIG.C_PROBE6_WIDTH {33} \
    CONFIG.C_PROBE7_WIDTH {16} \
    CONFIG.C_PROBE8_WIDTH {9} \
    CONFIG.C_PROBE9_WIDTH {9} \
    CONFIG.C_PROBE10_WIDTH {8} \
    CONFIG.C_PROBE11_WIDTH {8} \
    CONFIG.C_PROBE12_WIDTH {8} \
    CONFIG.C_PROBE13_WIDTH {12} \
] [get_ips ila_0]
generate_target all [get_ips ila_0]
if {[catch {synth_ip [get_ips ila_0]} msg]} {
    puts "synth_ip failed ($msg) — synth_1 will generate the IP OOC instead"
}

add_files -fileset constrs_1 xdc/eco_rgmii_phy1.xdc
set_property top $top_module [current_fileset]
update_compile_order -fileset sources_1

launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "SYNTH_FAILED"; exit 1
}
launch_runs impl_1 -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "IMPL_FAILED"; exit 1
}
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
puts "\n===== ILA BITSTREAM DONE ====="
exit 0
