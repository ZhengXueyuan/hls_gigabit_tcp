$lines = Get-Content -LiteralPath "pk_tcp9.txt" -Encoding Unicode
$cnt = 0
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match "Flags \[") {
        $cnt++
        Write-Host ("{0}: {1}" -f $i, $lines[$i].Trim().Substring(0, [Math]::Min($lines[$i].Trim().Length, 200)))
        if ($cnt -ge 60) { break }
    }
}
Write-Host "---total matched (cap 60): $cnt"
