@echo off
REM Launcher: ensure cwd before calling the real script (cmd pre-parses .bat
REM names in compound commands before cd takes effect, so this must be a
REM separate multi-line batch, invoked by full path from Git Bash:
REM   cmd //c 'D:\repo\ECO\udp_hls_eco\uart_hls\run_uart_hls.bat'
cd /d D:\repo\ECO\udp_hls_eco\uart_hls
call D:\repo\ECO\udp_hls_eco\uart_hls\run_hls.bat
