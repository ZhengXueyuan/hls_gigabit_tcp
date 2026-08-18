$lines = Get-Content -LiteralPath "pk_tcp10.txt" -Encoding Unicode
$started = $false
for ($i = 0; $i -lt $lines.Count; $i++) {
    $ln = $lines[$i]
    if ($ln -match "FC-9D-05-7D-88-6B > 00-0A-35-01-FE-C0, ethertype IPv4.*seq 4052004406") {
        Write-Host ("=== PC seg3 line {0}: {1}" -f $i, $ln.Trim().Substring(0, [Math]::Min($ln.Trim().Length, 160)))
        for ($j = $i + 1; $j -lt $lines.Count; $j++) {
            if ($lines[$j] -match "^\s*0x[0-9a-fA-F]{4}:") { Write-Host $lines[$j].Trim() }
            elseif ($lines[$j] -match "PktNumber") { break }
        }
        break
    }
}
