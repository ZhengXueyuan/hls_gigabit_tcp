@echo off
REM rebuild_sim.bat — compile latest HLS RTL + TCP TB, run xsim
set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set XILINX_VITIS=C:\AMDDesignTools\2025.2\Vitis
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;C:\AMDDesignTools\2025.2\Vitis\bin;C:\AMDDesignTools\2025.2\Vitis\lib\win64.o;%PATH%
cd /d D:\repo\ECO\udp_hls_eco
del xvlog_sim.log xelab_sim.log xsim_run.log 2>nul
rmdir /s /q xsim.dir\work 2>nul
rmdir /s /q xsim.dir\tcp_sim 2>nul
REM compile all RTL
for %%f in (udp_echo_prj\solution1\syn\verilog\*.v) do xvlog -work work %%f >> xvlog_sim.log 2>&1
xvlog -work work rtl_tcp_tb.v >> xvlog_sim.log 2>&1
echo XVLOG_EXIT=%errorlevel%
xelab rtl_tcp_tb glbl -L unisims_ver -L unisim -L secureip -s tcp_sim >> xelab_sim.log 2>&1
echo XELAB_EXIT=%errorlevel%
xsim tcp_sim -R -log xsim_run.log
echo XSIM_EXIT=%errorlevel%
