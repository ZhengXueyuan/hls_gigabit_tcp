param([string]$Match = "Flags \[S\.\]")
$lines = Get-Content -LiteralPath "pk_tcp6.txt" -Encoding Unicode
$inBlock = $false
for ($i = 0; $i -lt $lines.Count; $i++) {
    $ln = $lines[$i]
    if ($ln -match "PktNumber (\d+).*OriginalSize (\d+)") {
        $num = $Matches[1]; $size = $Matches[2]
        $sumline = ""
        $hex = @()
        for ($j = $i; $j -lt $lines.Count; $j++) {
            if ($lines[$j] -match "^\s*[0-9a-fA-F]{4}:") { $hex += $lines[$j].Trim() }
            elseif ($lines[$j] -match "ethertype") { $sumline = $lines[$j].Trim() }
            elseif ($lines[$j] -match "PktNumber") { break }
        }
        if ($sumline -match $Match) {
            Write-Host "=== frame $num size=$size ==="
            Write-Host $sumline.Substring(0, [Math]::Min($sumline.Length, 250))
            $hex | ForEach-Object { Write-Host $_ }
        }
    }
}
