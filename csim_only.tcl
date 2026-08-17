#=============================================================================
# csim_only.tcl — fast csim iteration (no synthesis) for TB debugging
# Usage: vitis-run.bat --mode hls --tcl csim_only.tcl
#=============================================================================
open_project -reset udp_echo_prj
add_files src/udp_echo.cpp
add_files -tb tb/udp_echo_tb.cpp
set_top udp_echo
open_solution -reset solution1
set_part {xc7k325tffg676-2}
create_clock -period 8 -name default
csim_design
puts "===== CSIM FINISHED ====="
exit
