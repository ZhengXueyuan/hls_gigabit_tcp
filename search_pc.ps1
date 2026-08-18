$lines = Get-Content -LiteralPath "pk_tcp7.txt" -Encoding Unicode
for ($i = 0; $i -lt $lines.Count; $i++) {
    $ln = $lines[$i]
    if ($ln -match "192\.168\.100\.1\.\d+ > 192\.168\.100\.2") {
        Write-Host ("PC line {0}: {1}" -f $i, $ln.Trim().Substring(0, [Math]::Min($ln.Trim().Length, 200)))
    }
    if ($ln -match "192\.168\.100\.2\.7 > 192\.168\.100\.1") {
        Write-Host ("FPGA line {0}: {1}" -f $i, $ln.Trim().Substring(0, [Math]::Min($ln.Trim().Length, 200)))
    }
}
