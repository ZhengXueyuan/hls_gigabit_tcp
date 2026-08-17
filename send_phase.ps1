# send_phase.ps1 — send ONE phase command, no pings
param([string]$PortName = "COM8", [string]$Dir = "P")
$p = New-Object System.IO.Ports.SerialPort $PortName, 9600, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$p.Open()
$c = if ($Dir -eq "P") { "+" } else { "-" }
$bytes = [System.Text.Encoding]::ASCII.GetBytes("@$c")
$p.Write($bytes, 0, $bytes.Length)
Start-Sleep -Milliseconds 300
$p.Close()
