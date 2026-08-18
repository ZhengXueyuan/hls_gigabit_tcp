$lines = Get-Content -LiteralPath "pk_tcp6.txt" -Encoding Unicode
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match "Flags \[S\.\]") {
        Write-Host "=== SYN-ACK at line $i ==="
        # print surrounding lines including hex dump (5 before, 10 after)
        for ($j = $i - 6; $j -lt [Math]::Min($i + 12, $lines.Count); $j++) {
            if ($j -ge 0 -and $lines[$j] -match "^\s*[0-9a-fA-F]{4}:") {
                Write-Host $lines[$j].Trim()
            }
        }
        Write-Host ""
        if ((Get-Date).Second % 2 -eq 0) { break }
    }
}
