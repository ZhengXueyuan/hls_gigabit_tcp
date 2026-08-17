# wire_scope.ps1 — send ?mac at 9600, oversample the response at 115200
param([string]$PortName = "COM8")
$p = New-Object System.IO.Ports.SerialPort $PortName, 9600, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$p.ReadTimeout = 1000
$p.Open()
# drain any stale data, then trigger
Start-Sleep -Milliseconds 200
$null = $p.ReadExisting()
$bytes = [System.Text.Encoding]::ASCII.GetBytes("?mac`r")
$p.Write($bytes, 0, $bytes.Length)
Start-Sleep -Milliseconds 900
$p.Close()

$q = New-Object System.IO.Ports.SerialPort $PortName, 115200, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$q.ReadTimeout = 3000
$q.Open()
# trigger again at 9600? we can only have one baud open. Instead: send at 115200
# will be garbage for the FPGA (wrong baud) -> no response. So: reopen at 9600,
# send, close, then open at 115200 and drain whatever comes.
$q.Close()

# Strategy: open 9600, send cmd, wait 900ms, switch to 115200 and read
$p2 = New-Object System.IO.Ports.SerialPort $PortName, 9600, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$p2.Open()
$bytes = [System.Text.Encoding]::ASCII.GetBytes("?mac`r")
$p2.Write($bytes, 0, $bytes.Length)
Start-Sleep -Milliseconds 1000
$p2.Close()

$r = New-Object System.IO.Ports.SerialPort $PortName, 115200, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$r.ReadTimeout = 4000
$r.Open()
$buf = New-Object byte[] 2048
$n = $r.Read($buf, 0, 2048)
Write-Host "oversampled n=$n"
$line = ""
for ($i = 0; $i -lt [Math]::Min($n, 480); $i++) {
    $line += [string]($buf[$i] -band 1)
    if (($i + 1) % 96 -eq 0) { $line += "`n" }
}
Write-Host $line
$r.Close()
