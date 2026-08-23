@echo off
cd /d D:\repo\ECO\udp_hls_eco
C:\AMDDesignTools\2025.2\Vivado\bin\vivado.bat -mode batch -source D:\repo\ECO\udp_hls_eco\program_eco.tcl -tclargs D:/repo/ECO/udp_hls_eco/vivado_prj/udp_dual_phy1g2.runs/impl_1/wrapper_1g.bit
