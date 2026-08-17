# console_cr_test.ps1 — ?mac with CR only (no LF) vs CRLF, compare responses
param([string]$PortName = "COM8")

foreach ($mode in @("CR", "CRLF")) {
    $p = New-Object System.IO.Ports.SerialPort $PortName, 9600, ([System.IO.Ports.Parity]::None), 8, ([System.IO.Ports.StopBits]::One)
    $p.ReadTimeout = 3000
    $p.Open()
    $cmd = if ($mode -eq "CR") { "?mac`r" } else { "?mac`r`n" }
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($cmd)
    $p.Write($bytes, 0, $bytes.Length)
    Start-Sleep -Milliseconds 1500
    $buf = New-Object byte[] 128
    $n = $p.Read($buf, 0, 128)
    $hex = ($buf[0..($n-1)] | ForEach-Object { $_.ToString("X2") }) -join " "
    $ascii = -join ($buf[0..($n-1)] | ForEach-Object { if ($_ -ge 32 -and $_ -lt 127) { [char]$_ } else { "." } })
    Write-Host "$mode : n=$n"
    Write-Host "  hex: $hex"
    Write-Host "  ascii: $ascii"
    $p.Close()
    Start-Sleep -Milliseconds 500
}
