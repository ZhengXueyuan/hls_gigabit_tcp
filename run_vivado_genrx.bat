@echo off
REM demo top + RX chain kept + demo_clone TX source
set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set XILINX_VITIS=C:\AMDDesignTools\2025.2\Vitis
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;C:\AMDDesignTools\2025.2\Vitis\bin;C:\AMDDesignTools\2025.2\Vitis\lib\win64.o;%PATH%
cd /d D:\repo\ECO\udp_hls_eco
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source run_vivado_genrx.tcl -log vivado_genrx.log -nojournal
