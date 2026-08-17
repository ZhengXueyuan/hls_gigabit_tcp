@echo off
REM =============================================================================
REM run_vivado_wrapper.bat — Vivado 2025.2 synth+impl+bitstream for ECO board
REM Invoke from Git Bash by full path: cmd //c 'D:\repo\ECO\udp_hls_eco\run_vivado_wrapper.bat'
REM =============================================================================
set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set XILINX_VITIS=C:\AMDDesignTools\2025.2\Vitis
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;C:\AMDDesignTools\2025.2\Vitis\bin;C:\AMDDesignTools\2025.2\Vitis\lib\win64.o;%PATH%
cd /d D:\repo\ECO\udp_hls_eco
call C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source run_vivado_phy1g2.tcl -log vivado_phy1g2.log -nojournal
