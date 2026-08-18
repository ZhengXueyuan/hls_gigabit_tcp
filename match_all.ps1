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
function Get-PayloadFrom([string]$hex,[int]$off) { $b=@(); for($i=$off*2; $i -lt $hex.Length; $i+=2){ $b += $hex.Substring($i,2) }; return ,$b }

# PC segments
$pcSegs = @()
$pcSegs += ,(Get-Payload (Get-FrameHex "seq 1550365290"))
$pcSegs += ,(Get-Payload (Get-FrameHex "seq 1550365826"))
$pcSegs += ,(Get-Payload (Get-FrameHex "seq 1550366362"))
$pcSegs += ,(Get-Payload (Get-FrameHex "seq 1550366898"))
for ($s = 0; $s -lt 4; $s++) { Write-Host "PC seg$($s+1): $($pcSegs[$s].Count) bytes, first=$($pcSegs[$s][0])" }

# FPGA echo frames
$fpSegs = @()
$fpSegs += ,(Get-Payload (Get-FrameHex "seq 305419897"))
$fpSegs += ,(Get-Payload (Get-FrameHex "seq 305420369"))
$fpSegs += ,(Get-Payload (Get-FrameHex "seq 305420433"))
$fpSegs += ,(Get-Payload (Get-FrameHex "seq 305420893"))
$fpSegs += ,(Get-Payload (Get-FrameHex "seq 305421365"))
for ($s = 0; $s -lt 5; $s++) { Write-Host "FPGA echo$($s+1): $($fpSegs[$s].Count) bytes, first=$($fpSegs[$s][0]), last=$($fpSegs[$s][-1])" }

# For each FPGA frame, find best match in the full PC data blob
$blob = @()
foreach ($seg in $pcSegs) { $blob += $seg }
Write-Host ""
for ($s = 0; $s -lt 5; $s++) {
    $fp = $fpSegs[$s]
    $best = @()
    for ($off = 0; $off -lt $blob.Count; $off++) {
        $m = 0
        $limit = [Math]::Min($fp.Count, $blob.Count - $off)
        for ($i = 0; $i -lt $limit; $i++) {
            if ($fp[$i] -eq $blob[$off+$i]) { $m++ }
        }
        if ($limit -gt 0) {
            $pct = [Math]::Round($m * 100.0 / $limit, 0)
            if ($pct -ge 90) { $best += "offset $off : $m/$limit ($pct%)" }
        }
    }
    Write-Host ("FPGA echo$($s+1) ($($fp.Count)B) best matches:")
    if ($best.Count -eq 0) { Write-Host "  NONE >= 90%" } else { $best | Select-Object -First 4 | ForEach-Object { Write-Host "  $_" } }
}
