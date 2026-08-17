# console_baud_test.ps1 — send ?mac once, read response at multiple bauds
param([string]$PortName = "COM8")

# send at 9600
$p = New-Object System.IO.Ports.SerialPort $PortName, 9600, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
$p.ReadTimeout = 500
$p.Open()
$bytes = [System.Text.Encoding]::ASCII.GetBytes("?mac`r`n")
$p.Write($bytes, 0, $bytes.Length)
Start-Sleep -Milliseconds 1200
$first = $p.ReadExisting()
Write-Host "read@9600 right after send: '$first'"
$p.Close()

foreach ($baud in @(9600, 19200, 4800, 38400)) {
    $q = New-Object System.IO.Ports.SerialPort $PortName, $baud, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
    $q.ReadTimeout = 2000
    $q.Open()
    # trigger a fresh response
    $bytes = [System.Text.Encoding]::ASCII.GetBytes("?mac`r`n")
    $q.Write($bytes, 0, $bytes.Length)
    Start-Sleep -Milliseconds 1500
    $buf = New-Object byte[] 128
    $n = $q.Read($buf, 0, 128)
    $hex = ($buf[0..($n-1)] | ForEach-Object { $_.ToString("X2") }) -join " "
    $ascii = -join ($buf[0..($n-1)] | ForEach-Object { if ($_ -ge 32 -and $_ -lt 127) { [char]$_ } else { "." } })
    Write-Host "baud=$baud n=$n"
    Write-Host "  hex: $hex"
    Write-Host "  ascii: $ascii"
    $q.Close()
    Start-Sleep -Milliseconds 300
}
