open_project -reset udp_echo_prj
add_files src/udp_echo.cpp
add_files -tb tb/udp_echo_tb.cpp
set_top udp_echo
open_solution -reset solution1
set_part {xc7k325tffg676-2}
create_clock -period 8 -name default
config_rtl -reset all -reset_async -reset_level low
puts "\n===== C SYNTHESIS (compile check) ====="
csynth_design
puts "\n===== CSYNTH DONE ====="
exit
