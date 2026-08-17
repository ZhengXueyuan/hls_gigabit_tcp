#=============================================================================
# net_test.ps1 — send a command to the FPGA UART console, print the response
# Usage: powershell -File net_test.ps1 -Port COM8 -Cmd "?net"   (default ?net)
#=============================================================================
param([string]$Port = "COM8", [string]$Cmd = "?net")

try { Add-Type -AssemblyName System.IO.Ports -ErrorAction Stop } catch { }

$sp = New-Object System.IO.Ports.SerialPort($Port, 9600, [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
$sp.ReadTimeout  = 1000
$sp.WriteTimeout = 2000
$sp.Open()
Write-Host "Port $Port open, 9600-8N1"

# drain leftovers
Start-Sleep -Milliseconds 500
while ($sp.BytesToRead -gt 0) { $null = $sp.ReadByte() }

# send command and read everything that comes back within 2s
$cmdBytes = [System.Text.Encoding]::ASCII.GetBytes($Cmd + "`r`n")
$sp.Write($cmdBytes, 0, $cmdBytes.Length)
$resp = ""
$deadline = [DateTime]::Now.AddMilliseconds(2000)
while ([DateTime]::Now -lt $deadline) {
    while ($sp.BytesToRead -gt 0) {
        $b = $sp.ReadByte()
        if ($b -ge 32 -and $b -lt 127) { $resp += [char]$b }
        elseif ($b -eq 13 -or $b -eq 10) { $resp += " " }
    }
    Start-Sleep -Milliseconds 20
}
Write-Host "response: '$resp'"
$sp.Close()
