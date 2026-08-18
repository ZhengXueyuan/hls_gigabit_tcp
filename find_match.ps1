$lines = Get-Content -LiteralPath "pk_tcp9.txt" -Encoding Unicode

function Get-FrameHex([string]$matchLine) {
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

function Get-Payload([string]$hex) {
    $bytes = @()
    for ($i = 54*2; $i -lt $hex.Length; $i += 2) { $bytes += $hex.Substring($i,2) }
    return ,$bytes
}

# Build a search window: PC payloads from all 4 segments + FIN (the data FPGA should have echoed)
$pcAll = @()
foreach ($m in @("seq 1550365290", "seq 1550365826", "seq 1550366362", "seq 1550366898")) {
    $h = Get-FrameHex $m
    if ($h) {
        $p = Get-Payload $h
        Write-Host "PC frame $m : $($p.Count) payload bytes"
        $pcAll += $p
    }
}
$pcBlob = ($pcAll -join '')
Write-Host "PC total payload blob: $($pcBlob.Length) bytes"

# FPGA echo1 payload
$fp1 = Get-FrameHex "seq 305419897"
$fp1b = Get-Payload $fp1
Write-Host "FPGA echo1 payload: $($fp1b.Count) bytes"

# Sliding window search: does fp1's payload appear contiguously in pcBlob?
$needle = ($fp1b -join '')
$hit = $pcBlob.IndexOf($needle)
Write-Host "fp1 full payload found at pcBlob offset: $hit"

# Also try sub-windows: first 32 bytes, last 32 bytes
$first32 = ($fp1b[0..31] -join '')
Write-Host "fp1 first 32 bytes: $first32"
$idx = $pcBlob.IndexOf($first32)
Write-Host "fp1 first-32 found at: $idx"

$last32 = ($fp1b[-32..-1] -join '')
Write-Host "fp1 last 32 bytes: $last32"
$idx2 = $pcBlob.IndexOf($last32)
Write-Host "fp1 last-32 found at: $idx2"
