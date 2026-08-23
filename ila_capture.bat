@echo off
REM ila_capture.bat <probeFilter> <compareValue> <trigPos> <csvOut> [skipProg]
cd /d D:\repo\ECO\udp_hls_eco
set BIT=D:/repo/ECO/udp_hls_eco/vivado_ila_prj/udp_ila.runs/impl_1/wrapper_1g_ila.bit
set LTX=D:/repo/ECO/udp_hls_eco/vivado_ila_prj/udp_ila.runs/impl_1/wrapper_1g_ila.ltx
C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source D:\repo\ECO\udp_hls_eco\ila_capture.tcl -tclargs %BIT% %LTX% %1 %2 %3 %4 %5 -log D:\repo\ECO\udp_hls_eco\ila_cap.log -nojournal
