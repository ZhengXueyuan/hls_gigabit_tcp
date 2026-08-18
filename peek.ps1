$lines = Get-Content -LiteralPath "pk_tcp6.txt" -Encoding Unicode
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match "PktNumber") {
        Write-Host ("LINE {0}: {1}" -f $i, $lines[$i].Substring(0, [Math]::Min($lines[$i].Length, 320)))
        if ($i -gt 5) { break }
    }
}
