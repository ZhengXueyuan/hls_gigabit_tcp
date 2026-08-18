param([int]$Bytes = 2000)
$server = "192.168.100.2"
$port = 7
# Generate payload: repeating pattern "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
$pattern = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
$payload = ""
for ($i = 0; $i -lt $Bytes; $i++) { $payload += $pattern[$i % $pattern.Length] }
$payload = $payload.Substring(0, $Bytes)

Write-Host "TCP ${Bytes}B test: connecting to ${server}:${port}..."
$t = New-Object Net.Sockets.TcpClient
$t.Connect($server, $port)
$s = $t.GetStream()
$b = [Text.Encoding]::ASCII.GetBytes($payload)
$s.Write($b, 0, $b.Length)
Write-Host "Sent $($b.Length) bytes, receiving echo..."
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
$resp = [Text.Encoding]::ASCII.GetString($buf, 0, $total)
$match = $resp -eq $payload
if ($total -eq $Bytes -and $match) {
    Write-Host "TCP ${Bytes}B echo PASS ($total bytes, ${sw}ElapsedMilliseconds ms)"
} else {
    Write-Host "TCP ${Bytes}B echo FAIL: got $total bytes, match=$match"
    if ($total -gt 0 -and $total -le 200) { Write-Host "First $total bytes: $resp" }
    # Show first mismatch
    for ($i = 0; $i -lt [Math]::Min($total, $Bytes); $i++) {
        if ($resp[$i] -ne $payload[$i]) {
            Write-Host "First mismatch at offset ${i}: got '$($resp[$i])' (0x$([int]$resp[$i].ToString('X2'))) exp '$($payload[$i])' (0x$([int]$payload[$i].ToString('X2')))"
            Write-Host "Context: ...$($resp.Substring([Math]::Max(0,$i-8), 16))..."
            break
        }
    }
}
$t.Close()