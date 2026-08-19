# analyze_pkt.ps1 — parse pktmon text dump, print TCP frames from FPGA<->PC
param([string]$File = "pk_tcp_race.txt")
$lines = [System.IO.File]::ReadAllLines((Resolve-Path $File), [System.Text.Encoding]::Unicode)
Write-Host ("Total lines: " + $lines.Count)

$frameCount = 0
$pcCount = 0
for ($i = 0; $i -lt $lines.Count; $i++) {
    $ln = $lines[$i]
    if ($ln -match '192\.168\.100\.2\.7 > 192\.168\.100\.1') {
        $frameCount++
        if ($frameCount -le 12) { Write-Host ("FPGA#" + $frameCount + " L" + $i + ": " + $ln) }
    } elseif ($ln -match '192\.168\.100\.1\.\d+ > 192\.168\.100\.2') {
        $pcCount++
        if ($pcCount -le 8) { Write-Host ("PC#" + $pcCount + " L" + $i + ": " + $ln.Substring(0, [Math]::Min($ln.Length, 240))) }
    }
}
Write-Host ("FPGA frames: " + $frameCount + "  PC frames: " + $pcCount)
