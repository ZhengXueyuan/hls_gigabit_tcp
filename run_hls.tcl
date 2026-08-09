#=============================================================================
# run_hls.tcl — HLS synthesis for udp_echo
#=============================================================================

open_project -reset udp_echo_prj
add_files src/udp_echo.cpp
add_files -tb tb/udp_echo_tb.cpp

set_top udp_echo

open_solution -reset solution1
set_part {xc7a35tftg256-1}
create_clock -period 8 -name default

# Reset: async, active low
config_rtl -reset all -reset_async -reset_level low

# Run C simulation
puts "\n===== C SIMULATION ====="
csim_design

# Run synthesis
puts "\n===== C SYNTHESIS ====="
csynth_design

# Export (RTL is already in solution1/syn/verilog/)
puts "\n===== EXPORT DESIGN ====="
export_design -format ip_catalog

puts "\n===== HLS DONE ====="
exit
