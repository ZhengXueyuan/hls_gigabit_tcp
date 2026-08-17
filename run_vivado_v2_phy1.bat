@echo off
cd /d D:\repo\ECO\udp_hls_eco
C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source run_vivado_v2_phy1.tcl -log vivado_v2_phy1.log -nojournal
exit /b %errorlevel%
