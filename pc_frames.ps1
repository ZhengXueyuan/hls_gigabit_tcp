$lines = Get-Content -LiteralPath "pk_tcp7.txt" -Encoding Unicode
$curNum=""; $curSize=""
for ($i = 0; $i -lt $lines.Count; $i++) {
    $ln = $lines[$i]
    if ($ln -match "PktNumber (\d+)") { $curNum = $Matches[1] }
    if ($ln -match "OriginalSize (\d+)") { $curSize = $Matches[1] }
    if ($ln -match "FC-9D-05-7D-88-6B > 00-0A-35-01-FE-C0, ethertype IPv4") {
        Write-Host ("{0} (len {1}): {2}" -f $curNum, $curSize, $ln.Trim().Substring(0, [Math]::Min($ln.Trim().Length, 160)))
    }
}
