$lines = Get-Content -LiteralPath "pk_536.txt" -Encoding Unicode
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match "Flags \[S\.\]") {
        Write-Host ("line {0}: {1}" -f $i, $lines[$i].Trim().Substring(0, [Math]::Min($lines[$i].Trim().Length, 200)))
        for ($j = $i + 1; $j -lt $lines.Count; $j++) {
            if ($lines[$j] -match "^\s*0x[0-9a-fA-F]{4}:") { Write-Host $lines[$j].Trim() }
            elseif ($lines[$j] -match "PktNumber") { break }
        }
        break
    }
}
