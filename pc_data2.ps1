$lines = Get-Content -LiteralPath "pk_tcp7.txt" -Encoding Unicode
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match "Flags \[S\]") {
        # found SYN, print next 40 lines
        for ($j = $i; $j -lt [Math]::Min($i + 40, $lines.Count); $j++) {
            if ($lines[$j] -match "0x[0-9a-fA-F]{4}:") {
                Write-Host $lines[$j].Trim()
            } elseif ($lines[$j] -match "ethertype IPv4") {
                Write-Host $lines[$j].Trim().Substring(0, [Math]::Min($lines[$j].Trim().Length, 180))
            }
        }
        Write-Host "============"
        break
    }
}
