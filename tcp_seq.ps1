$lines = Get-Content -LiteralPath "pk_tcp6.txt" -Encoding Unicode
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match "Flags \[(.)\].*seq (\d+)(?::(\d+))?.*ack (\d+).*length (\d+)") {
        $f = $Matches[1]; $s = $Matches[2]; $e = $Matches[3]; $a = $Matches[4]; $l = $Matches[5]
        $dir = if ($lines[$i] -match "00-0A-35-01-FE-C0 > FC-9D") { "FPGA->PC" } else { "PC->FPGA" }
        $seqrng = "$s"
        if ($e) { $seqrng = "$s" + ":" + "$e" }
        Write-Host ("{0} {1} seq={2} ack={3} len={4}" -f $dir, $f, $seqrng, $a, $l)
    }
}
