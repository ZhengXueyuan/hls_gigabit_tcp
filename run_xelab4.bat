@echo off
set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set XILINX_VITIS=C:\AMDDesignTools\2025.2\Vitis
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;C:\AMDDesignTools\2025.2\Vitis\bin;C:\AMDDesignTools\2025.2\Vitis\lib\win64.o;%PATH%
cd /d D:\repo\ECO\udp_hls_eco
call xvlog -work work rtl_tcp_tb.v
call xelab rtl_tcp_tb -L unisims_ver -L unisim -L secureip -s tcp_sim
call xsim tcp_sim -R -log xsim_run.log
echo XSIM_EXIT=%errorlevel%
