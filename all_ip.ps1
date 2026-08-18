$lines = Get-Content -LiteralPath "pk_tcp6.txt" -Encoding Unicode
$curNum = ""; $curDir = ""; $curSize = ""; $curSum = ""
for ($i = 0; $i -lt $lines.Count; $i++) {
    $ln = $lines[$i]
    if ($ln -match "PktNumber (\d+)") { $curNum = $Matches[1] }
    if ($ln -match "PktNumber (\d+).*?(Rx|Tx)") { $curDir = $Matches[2] }
    if ($ln -match "OriginalSize (\d+)") { $curSize = $Matches[1] }
    if ($ln -match "192\.168\.100\.\d+\.\d+ > 192\.168\.100\.\d+\.\d+") {
        $curSum = $ln.Trim()
        $line = "{0} {1} len={2} : {3}" -f $curNum, $curDir, $curSize, $curSum
        Write-Host $line.Substring(0, [Math]::Min($line.Length, 200))
    }
}
