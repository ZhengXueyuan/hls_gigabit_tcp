open_project -reset uart_prj
add_files src/uart_console.cpp
add_files -tb tb/uart_tb.cpp
set_top uart_console
open_solution -reset solution1
set_part {xc7k325tffg676-2}
create_clock -period 20 -name default
config_rtl -reset all -reset_async -reset_level low
csim_design
csynth_design
export_design -format ip_catalog
puts "\n===== UART HLS DONE ====="
exit
