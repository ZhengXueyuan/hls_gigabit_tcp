param([string]$File = "pk_tcp6.txt")
$lines = Get-Content -LiteralPath $File
$inBlock = $false
$cur = ""
$frames = @()
$curHex = ""
foreach ($ln in $lines) {
    # frame header line: "PktNumber ... Direction Rx/Tx"
    if ($ln -match "PktNumber\s+(\d+).*Direction\s+(Rx|Tx).*OriginalSize\s+(\d+)") {
        if ($cur -ne "" -and $cur -match "TCP") { $frames += [pscustomobject]@{Num=$curNum; Dir=$curDir; Size=$curSize; Info=$cur; Hex=$curHex} }
        $curNum = $Matches[1]; $curDir = $Matches[2]; $curSize = $Matches[3]
        $cur = $ln; $curHex = ""
        $inBlock = $true
        continue
    }
    if ($inBlock -and $ln -match "^\s*[0-9a-fA-F]{4}:") {
        $curHex += $ln
        $cur += $ln
        continue
    }
    # summary line with protocol info
    if ($inBlock -and $ln -match "ethertype IPv4") {
        $cur += " | " + $ln.Trim()
    }
}
if ($cur -ne "" -and $cur -match "TCP") { $frames += [pscustomobject]@{Num=$curNum; Dir=$curDir; Size=$curSize; Info=$cur; Hex=$curHex} }
Write-Host "Total TCP frames: $($frames.Count)"
$frames | ForEach-Object {
    $ip = if ($_.Info -match "(192\.168\.\d+\.\d+\.\d+) > (192\.168\.\d+\.\d+\.\d+)") { "$($Matches[1])->$($Matches[2])" } else { "?" }
    $tcpinfo = if ($_.Info -match "TCP[^,]*(,)") { $_.Info } else { "?" }
    $flags = if ($_.Info -match "Flags \[(.)\]") { $Matches[1] } else { "-" }
    $sport = if ($_.Info -match "\.(\d+)\s*>\s*192\.168\.100\.2\.(\d+)") { "$($Matches[1])" } elseif ($_.Info -match "\.(\d+)\s*>\s*\.(\d+)") { "$($Matches[1])" } else { "?" }
    Write-Host ("#{0} {1} size={2} {3}" -f $_.Num, $_.Dir, $_.Size, $_.Info.Substring(0, [Math]::Min($_.Info.Length, 220)))
}
