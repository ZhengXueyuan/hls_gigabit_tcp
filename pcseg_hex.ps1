$lines = Get-Content -LiteralPath "pk_tcp9.txt" -Encoding Unicode
$started = $false
for ($i = 0; $i -lt $lines.Count; $i++) {
    $ln = $lines[$i]
    if ($ln -match "FC-9D-05-7D-88-6B > 00-0A-35-01-FE-C0, ethertype IPv4") {
        $started = $true
        Write-Host ("=== PC->FPGA frame line {0}: {1}" -f $i, $ln.Trim().Substring(0, [Math]::Min($ln.Trim().Length, 150)))
    } elseif ($started -and $ln -match "^\s*0x[0-9a-fA-F]{4}:") {
        Write-Host $ln.Trim()
    } elseif ($started -and $ln -match "PktNumber") {
        $started = $false
        Write-Host "-----"
    }
}
