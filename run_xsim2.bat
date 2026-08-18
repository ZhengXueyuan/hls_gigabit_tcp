@echo off
set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set XILINX_VITIS=C:\AMDDesignTools\2025.2\Vitis
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;C:\AMDDesignTools\2025.2\Vitis\bin;C:\AMDDesignTools\2025.2\Vitis\lib\win64.o;%PATH%
cd /d D:\repo\ECO\udp_hls_eco
xvlog -work work rtl_tcp_tb.v >> xvlog_tb.log 2>&1
xelab rtl_tcp_tb glbl -L unisims_ver -L unisim -L secureip -s tcp_sim >> xelab_all.log 2>&1
xsim tcp_sim -R -log xsim_run.log >> xsim_run_all.log 2>&1
