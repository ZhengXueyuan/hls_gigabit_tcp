@echo off
REM =============================================================================
REM run_hls.bat — Run Vitis HLS 2025.2 synthesis for udp_echo
REM =============================================================================

set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set XILINX_VITIS=C:\AMDDesignTools\2025.2\Vitis

set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;C:\AMDDesignTools\2025.2\Vitis\bin;C:\AMDDesignTools\2025.2\Vitis\lib\win64.o;%PATH%

C:\AMDDesignTools\2025.2\Vitis\bin\vitis-run.bat --mode hls --tcl --part xc7a35tftg256-1 --freqhz 125000000 run_hls.tcl
