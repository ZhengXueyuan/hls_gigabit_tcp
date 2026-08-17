# tune_phase.ps1 — send "@-"/"@+" phase commands then ping and report loss
# Usage: tune_phase.ps1 <COM> <cmd_char> <repeat> <ping_count>
param([string]$PortName = "COM8", [string]$PhaseCmd = "M", [int]$Repeat = 2, [int]$Pings = 30)

$dirChar = if ($PhaseCmd -eq "M") { "-" } else { "+" }

$p = New-Object System.IO.Ports.SerialPort $PortName, 9600, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$p.ReadTimeout = 500
$p.Open()
try {
    for ($i = 0; $i -lt $Repeat; $i++) {
        $bytes = [System.Text.Encoding]::ASCII.GetBytes("@$dirChar")
        $p.Write($bytes, 0, $bytes.Length)
        Start-Sleep -Milliseconds 400   # allow the 56-step shift (~1ms) + margin
    }
    # flush echo
    Start-Sleep -Milliseconds 300
    $null = $p.ReadExisting()
} finally { $p.Close() }

$out = ping -n $Pings 192.168.100.2 2>&1
$line = ($out | Select-String -Pattern "已接收|received").Line
if (-not $line) { $line = ($out | Select-String -Pattern "%").Line }
Write-Host "phase cmd: @$dirChar x$Repeat -> $line"
