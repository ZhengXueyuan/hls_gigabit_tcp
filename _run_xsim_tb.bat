@echo off
set PATH=C:\AMDDesignTools\2025.2\Vivado\bin;%PATH%
cd /d D:\repo\ECO\udp_hls_eco\xsim_run
echo ===== XVLOG =====
xvlog -prj sim_files.prj > _xvlog_out.txt 2>&1
if errorlevel 1 (echo XVLOG_FAIL & type _xvlog_out.txt & exit /b 1)
echo ===== XELAB =====
xelab tb_udp_echo -s tb_snap -debug all > _xelab_out.txt 2>&1
if errorlevel 1 (echo XELAB_FAIL & type _xelab_out.txt & exit /b 1)
echo ===== XSIM =====
xsim tb_snap -runall > _xsim_out.txt 2>&1
echo ===== DONE =====
