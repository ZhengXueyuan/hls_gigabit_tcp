$lines = Get-Content -LiteralPath "pk_tcp7.txt" -Encoding Unicode
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match "192\.168\.100\.1\.\d+ > 192\.168\.100\.2\.7: Flags \[\.\].*length") {
        Write-Host ("=== PC data frame line {0} ===" -f $i)
        Write-Host $lines[$i].Trim().Substring(0, [Math]::Min($lines[$i].Trim().Length, 200))
        for ($j = $i + 1; $j -lt $lines.Count; $j++) {
            if ($lines[$j] -match "^\s*0x[0-9a-fA-F]{4}:") { Write-Host $lines[$j].Trim() }
            elseif ($lines[$j] -match "PktNumber") { break }
        }
    }
}
