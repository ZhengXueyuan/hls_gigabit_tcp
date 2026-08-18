$lines = Get-Content -LiteralPath "pk_tcp9.txt" -Encoding Unicode
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match "192\.168\.100\.\d+\.\d+ > 192\.168\.100\.\d+\.\d+: Flags \[([^\]]*)\](, seq (\d+))?(, ack (\d+))?[^,]*(, length (\d+))?") {
        $f = $Matches[1]; $s = $Matches[3]; $a = $Matches[5]; $l = $Matches[7]
        $dir = if ($lines[$i] -match "00-0A-35-01-FE-C0 > FC-9D") { "FPGA->PC" } else { "PC->FPGA" }
        $str = "{0} [{1}] " -f $dir, $f
        if ($s) { $str += "seq=$s " }
        if ($a) { $str += "ack=$a " }
        if ($l) { $str += "len=$l" }
        Write-Host $str
    }
}
