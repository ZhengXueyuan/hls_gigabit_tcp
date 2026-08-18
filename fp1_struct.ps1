$lines = Get-Content -LiteralPath "pk_536.txt" -Encoding Unicode
function Get-FrameHex([string]$matchLine) {
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $matchLine) {
            $hex = ""
            for ($j = $i + 1; $j -lt $lines.Count; $j++) {
                if ($lines[$j] -match "^\s*0x[0-9a-fA-F]{4}:\s*(.*)$") { $hex += ($Matches[1] -replace '\s','') }
                elseif ($lines[$j] -match "PktNumber") { break }
            }
            return $hex
        }
    }
    return ""
}
$fp1hex = Get-FrameHex "seq 305419897"
# payload = bytes 54..526
$pl = $fp1hex.Substring(54*2)
Write-Host "FPGA echo1 payload bytes:"
# print in rows of 16
for ($i = 0; $i -lt $pl.Length; $i += 32) {
    $row = $pl.Substring($i, [Math]::Min(32, $pl.Length - $i))
    $str = ""
    for ($j = 0; $j -lt $row.Length; $j += 2) { $str += $row.Substring($j,2) + " " }
    Write-Host ("{0:X4}: {1}" -f ($i/2), $str)
}
