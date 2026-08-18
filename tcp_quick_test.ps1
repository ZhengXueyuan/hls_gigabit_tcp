$server = "192.168.100.2"
$port = 7
$msg = "hello from ECO board test"
Write-Host "Connecting to ${server}:${port}..."
$t = New-Object Net.Sockets.TcpClient
$t.Connect($server, $port)
$s = $t.GetStream()
$b = [Text.Encoding]::ASCII.GetBytes($msg)
$s.Write($b, 0, $b.Length)
Write-Host "Sent $($b.Length) bytes, waiting for echo..."
Start-Sleep -Milliseconds 500
$buf = New-Object byte[] 1024
if ($s.DataAvailable) {
    $n = $s.Read($buf, 0, 1024)
    $resp = [Text.Encoding]::ASCII.GetString($buf, 0, $n)
    Write-Host "TCP echo ($n bytes): $resp"
} else {
    Write-Host "No data available after 500ms"
}
$t.Close()
Write-Host "Done"