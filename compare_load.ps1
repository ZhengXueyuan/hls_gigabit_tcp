# Extract hex payloads from pktmon txt and compare
$lines = Get-Content -LiteralPath "pk_tcp9.txt" -Encoding Unicode

function Get-FrameHex([string]$matchLine) {
    $found = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $matchLine) {
            $hex = ""
            for ($j = $i + 1; $j -lt $lines.Count; $j++) {
                if ($lines[$j] -match "^\s*0x[0-9a-fA-F]{4}:\s*(.*)$") {
                    $hex += ($Matches[1] -replace '\s','')
                } elseif ($lines[$j] -match "PktNumber") { break }
            }
            return $hex
        }
    }
    return ""
}

# PC segment 1: flags [.] seq 1550365290:1550365826
$pc1 = Get-FrameHex "seq 1550365290"
Write-Host "PC seg1 frame hex length: $($pc1.Length / 2) bytes"
# PC frame: eth(14) + ip(20) + tcp(20) = 54 bytes header, payload from byte 54
$pc1Payload = $pc1.Substring(54*2)
Write-Host "PC seg1 payload len: $($pc1Payload.Length / 2) bytes"
Write-Host "PC seg1 payload[0..15]: $(($pc1Payload.Substring(0,32) -split '(..)') | Where-Object {$_} | ForEach-Object { '0x' + $_ })"

# FPGA echo frame 1: seq 305419897
$fp1 = Get-FrameHex "seq 305419897"
Write-Host ""
Write-Host "FPGA echo1 frame hex length: $($fp1.Length / 2) bytes"
$fp1Payload = $fp1.Substring(54*2)
Write-Host "FPGA echo1 payload len: $($fp1Payload.Length / 2) bytes"
Write-Host "FPGA echo1 payload[0..15]: $(($fp1Payload.Substring(0,32) -split '(..)') | Where-Object {$_} | ForEach-Object { '0x' + $_ })"

# Find where FPGA payload matches PC payload
Write-Host ""
Write-Host "=== matching FPGA payload offset vs PC payload ==="
$fpbytes = @()
for ($i = 0; $i -lt $fp1Payload.Length; $i += 2) { $fpbytes += $fp1Payload.Substring($i,2) }
$pcbytes = @()
for ($i = 0; $i -lt $pc1Payload.Length; $i += 2) { $pcbytes += $pc1Payload.Substring($i,2) }
$matchAt = @()
for ($off = 0; $off -lt 200; $off++) {
    $match = 0
    $cnt = 0
    for ($i = 0; $i -lt $fpbytes.Count -and $i + $off -lt $pcbytes.Count; $i++) {
        if ($fpbytes[$i] -eq $pcbytes[$i+$off]) { $match++ }
        $cnt++
    }
    if ($cnt -gt 0) {
        $pct = [Math]::Round($match * 100.0 / $cnt, 1)
        if ($pct -ge 80) { $matchAt += "offset $off : $match/$cnt ($pct%)" }
    }
}
if ($matchAt.Count -eq 0) { Write-Host "no high-match offset found" } else { $matchAt | ForEach-Object { Write-Host $_ } }
