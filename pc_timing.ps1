$lines = Get-Content -LiteralPath "pk_tcp10.txt" -Encoding Unicode
$curTime = ""
$curDir = ""
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match "::2026-08-19 (\d+):(\d+):(\d+)\.(\d+)") {
        $curTime = "$($Matches[1]):$($Matches[2]):$($Matches[3]).$($Matches[4])"
    }
    if ($lines[$i] -match "192\.168\.100\.\d+\.\d+ > 192\.168\.100\.\d+\.\d+") {
        $dir = if ($lines[$i] -match "00-0A-35-01-FE-C0 > FC-9D") { "FPGA->PC" } else { "PC->FPGA" }
        $flags = if ($lines[$i] -match "Flags \[([^\]]*)\]") { $Matches[1] } else { "?" }
        $seq = if ($lines[$i] -match "seq (\d+):(\d+)") { "$($Matches[1]):$($Matches[2])" } else { "" }
        $len = if ($lines[$i] -match "length (\d+)") { $Matches[1] } else { "" }
        Write-Host ("{0}  {1} [{2}] {3} len={4}" -f $curTime, $dir, $flags, $seq, $len)
    }
}
