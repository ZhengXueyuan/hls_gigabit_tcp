$lines = Get-Content -LiteralPath "pk_tcp9.txt" -Encoding Unicode
$inFrame = $false
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match "00-0A-35-01-FE-C0 > FC-9D-05-7D-88-6B.*Flags \[[^F]\]") {
        Write-Host ("=== FPGA data frame line {0}: {1}" -f $i, $lines[$i].Trim().Substring(0, [Math]::Min($lines[$i].Trim().Length, 160)))
        $inFrame = $true
    } elseif ($inFrame -and $lines[$i] -match "^\s*0x[0-9a-fA-F]{4}:") {
        Write-Host $lines[$i].Trim()
    } elseif ($inFrame -and $lines[$i] -match "PktNumber") {
        $inFrame = $false
        Write-Host ""
    }
}
