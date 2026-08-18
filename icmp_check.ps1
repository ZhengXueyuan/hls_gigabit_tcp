param([string]$File = "pk_tcp9.txt")
$lines = Get-Content -LiteralPath $File -Encoding Unicode
$icmp = 0
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match "ICMP|ICMPv6|fragment|unreachable|redirect") { 
        Write-Host ("line {0}: {1}" -f $i, $lines[$i].Trim().Substring(0, [Math]::Min($lines[$i].Trim().Length, 150)))
        $icmp++
        if ($icmp -ge 10) { break }
    }
}
if ($icmp -eq 0) { Write-Host "no ICMP/frag frames" }
