$lines = Get-Content -LiteralPath "pk_tcp9.txt" -Encoding Unicode
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
function Get-Payload([string]$hex) { $b=@(); for($i=108; $i -lt $hex.Length; $i+=2){ $b += $hex.Substring($i,2) }; return ,$b }

# PC seg1 payload (bytes 54..590)
$pc1hex = Get-FrameHex "seq 1550365290"
$pc1 = Get-Payload $pc1hex
Write-Host "PC seg1 payload: $($pc1.Count) bytes"
# FPGA echo1 payload
$fp1hex = Get-FrameHex "seq 305419897"
$fp1 = Get-Payload $fp1hex
Write-Host "FPGA echo1 payload: $($fp1.Count) bytes"

# exact match of fp1 against pc1 at every offset
Write-Host "=== fp1 vs pc1 (exact 472-byte window) ==="
for ($off = 0; $off -le ($pc1.Count - $fp1.Count); $off++) {
    $m = $true
    for ($i = 0; $i -lt $fp1.Count; $i++) {
        if ($fp1[$i] -ne $pc1[$off+$i]) { $m = $false; break }
    }
    if ($m) { Write-Host "EXACT MATCH at offset $off" }
}

# longest common prefix per offset
Write-Host "=== best offsets (match length) ==="
$best = @()
for ($off = 0; $off -le ($pc1.Count - $fp1.Count); $off++) {
    $len = 0
    for ($i = 0; $i -lt $fp1.Count; $i++) {
        if ($fp1[$i] -eq $pc1[$off+$i]) { $len++ } else { break }
    }
    if ($len -ge 50) { $best += "offset $off : first $len bytes match" }
}
if ($best.Count -eq 0) { Write-Host "no offset with >=50 matching prefix" } else { $best | ForEach-Object { Write-Host $_ } }
