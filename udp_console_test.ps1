# udp_console_test.ps1 — board test for udp_hls UART console (9600-8N1)
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File udp_console_test.ps1 [COMx]
# Sends ?mac / ?ip / ?help and verifies responses.
param([string]$PortName = "")

$ErrorActionPreference = "Stop"

if ($PortName -eq "") {
    $candidates = Get-CimInstance Win32_PnPEntity | Where-Object { $_.Name -match "\(COM\d+\)" } |
        ForEach-Object { [regex]::Match($_.Name, "\((COM\d+)\)").Groups[1].Value } | Sort-Object -Unique
    $PortName = ($candidates | Where-Object { $_ -ne "COM1" } | Select-Object -First 1)
}
Write-Host "UART console test on $PortName @ 9600-8N1"

$port = New-Object System.IO.Ports.SerialPort $PortName, 9600, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$port.ReadTimeout = 3000
$port.Open()
try {
    function Send-Cmd($cmd, $expect) {
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($cmd + "`r`n")
        $port.Write($bytes, 0, $bytes.Length)
        Start-Sleep -Milliseconds 800
        $resp = $port.ReadExisting()
        Write-Host "CMD: '$cmd' -> '$($resp.Trim())'"
        if ($expect -and -not $resp.Contains($expect)) {
            Write-Host "  *** MISMATCH: expected '$expect'"
            return $false
        }
        return $true
    }
    $ok = $true
    $ok = (Send-Cmd "?mac" "MAC: 00:0A:35:01:FE:C0") -and $ok
    $ok = (Send-Cmd "?ip"  "IP: 192.168.100.2") -and $ok
    $ok = (Send-Cmd "?help" "?help") -and $ok
    $ok = (Send-Cmd "?"     "?") -and $ok

    # Desync probe: no extra bytes after quiet period
    Start-Sleep -Milliseconds 500
    $extra = $port.ReadExisting()
    if ($extra.Length -gt 0) { Write-Host "EXTRA_BYTES: '$extra'"; $ok = $false }
    else { Write-Host "NO_EXTRA_BYTES" }

    if ($ok) { Write-Host "CONSOLE_TEST_PASS" } else { Write-Host "CONSOLE_TEST_FAIL"; exit 1 }
} finally {
    $port.Close()
}
