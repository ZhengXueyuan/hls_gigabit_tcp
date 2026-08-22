open_project udp_echo_prj
open_solution solution1
set_top udp_echo
puts "\n===== RTL CO-SIMULATION (catches scheduling races csim misses) ====="
cosim_design -tool xsim -rtl verilog
puts "\n===== COSIM DONE ====="
exit
