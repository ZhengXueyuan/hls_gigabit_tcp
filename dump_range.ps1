param([int]$Start = 50, [int]$Count = 40)
$lines = Get-Content -LiteralPath "pk_tcp6.txt" -Encoding Unicode
for ($i = $Start; $i -lt [Math]::Min($Start + $Count, $lines.Count); $i++) {
    Write-Host ("{0}: {1}" -f $i, $lines[$i].Trim())
}
