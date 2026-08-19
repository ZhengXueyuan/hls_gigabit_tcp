@echo off
REM sim_build.bat — compile latest HLS RTL + TB, elaborate, run xsim
set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set XILINX_VITIS=C:\AMDDesignTools\2025.2\Vitis
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;C:\AMDDesignTools\2025.2\Vitis\bin;%PATH%
cd /d D:\repo\ECO\udp_hls_eco
if exist xsim.dir\work rmdir /s /q xsim.dir\work
if exist xsim.dir\tcp_sim rmdir /s /q xsim.dir\tcp_sim
echo === XVLOG ===
for %%f in (udp_echo_prj\solution1\syn\verilog\*.v) do (
  xvlog -work work %%f >> xvlog_sim.log 2>&1
)
xvlog -work work rtl_tcp_tb.v >> xvlog_sim.log 2>&1
echo XVLOG_EXIT=%errorlevel%
echo === XELAB ===
xelab rtl_tcp_tb glbl -L unisims_ver -L unisim -L secureip -s tcp_sim > xelab_sim.log 2>&1
echo XELAB_EXIT=%errorlevel%
echo === XSIM ===
xsim tcp_sim -R -log xsim_run.log > xsim_out.log 2>&1
echo XSIM_EXIT=%errorlevel%
