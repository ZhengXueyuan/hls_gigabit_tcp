@echo off
REM Compile and run RTL TCP TB with xsim (2025.2)
set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set XILINX_VITIS=C:\AMDDesignTools\2025.2\Vitis
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;C:\AMDDesignTools\2025.2\Vitis\bin;C:\AMDDesignTools\2025.2\Vitis\lib\win64.o;%PATH%
cd /d D:\repo\ECO\udp_hls_eco
REM compile all RTL + TB
for %%f in (udp_echo_prj\solution1\syn\verilog\*.v) do xvlog -work work %%f >> xvlog_all.log 2>&1
xvlog -work work rtl_tcp_tb.v >> xvlog_all.log 2>&1
REM elaborate
xelab rtl_tcp_tb glbl -L unisims_ver -L unisim -L secureip -s tcp_sim >> xelab_all.log 2>&1
REM run
xsim tcp_sim -R -log xsim_run.log >> xsim_run_all.log 2>&1
