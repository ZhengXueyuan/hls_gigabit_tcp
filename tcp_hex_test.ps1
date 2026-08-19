param([int]$Bytes = 2000, [string]$Pattern = "A", [int]$From = 1600)
$server = "192.168.100.2"
$port = 7
$payload = ($Pattern * [int]([Math]::Ceiling($Bytes / $Pattern.Length))).Substring(0, $Bytes)
$t = New-Object Net.Sockets.TcpClient
$t.Connect($server, $port)
$s = $t.GetStream()
$b = [Text.Encoding]::ASCII.GetBytes($payload)
$s.Write($b, 0, $b.Length)
$buf = New-Object byte[] 65536
$total = 0
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($total -lt $Bytes -and $sw.ElapsedMilliseconds -lt 15000) {
    if ($s.DataAvailable) {
        $n = $s.Read($buf, $total, $Bytes - $total)
        $total += $n
    }
    Start-Sleep -Milliseconds 10
}
$sw.Stop()
Write-Host "got=$total match=$($([Text.Encoding]::ASCII.GetString($buf,0,$total)) -eq $payload)"
Write-Host "=== hex dump $From..($From+159) of received ==="
for ($i = $From; $i -lt [Math]::Min($From + 160, $total); $i += 16) {
    $hex = ($buf[$i..([Math]::Min($i+15,$total-1))] | ForEach-Object { "{0:X2}" -f $_ }) -join ' '
    $asc = ($buf[$i..([Math]::Min($i+15,$total-1))] | ForEach-Object { if ($_ -ge 32 -and $_ -le 126) { [char]$_ } else { '.' } }) -join ''
    Write-Host ("{0:D4}: {1,-48} {2}" -f $i, $hex, $asc)
}
$t.Close()
