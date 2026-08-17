@echo off
REM =============================================================================
REM run_csim.bat — fast csim-only run for TB debugging (no synthesis)
REM Invoke from Git Bash by full path: cmd //c 'D:\repo\ECO\udp_hls_eco\run_csim.bat'
REM =============================================================================
set XILINX_VIVADO=C:\AMDDesignTools\2025.2\Vivado
set XILINX_VITIS=C:\AMDDesignTools\2025.2\Vitis
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;C:\AMDDesignTools\2025.2\Vivado\lib\win64.o;C:\AMDDesignTools\2025.2\Vitis\bin;C:\AMDDesignTools\2025.2\Vitis\lib\win64.o;%PATH%
cd /d D:\repo\ECO\udp_hls_eco
C:\AMDDesignTools\2025.2\Vitis\bin\vitis-run.bat --mode hls --tcl csim_only.tcl
