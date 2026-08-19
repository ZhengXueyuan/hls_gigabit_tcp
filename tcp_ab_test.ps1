param([int]$Bytes = 2000, [string]$Pattern = "A")
$server = "192.168.100.2"
$port = 7
$payload = ($Pattern * [int]([Math]::Ceiling($Bytes / $Pattern.Length))).Substring(0, $Bytes)
Write-Host "TCP ${Bytes}B (pattern=$Pattern) test..."
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
$resp = [Text.Encoding]::ASCII.GetString($buf, 0, $total)
$match = $resp -eq $payload
Write-Host "got=$total match=$match elapsed=$($sw.ElapsedMilliseconds)ms"
if (-not $match) {
    # find all mismatches and summarize runs
    $mis = @()
    for ($i = 0; $i -lt [Math]::Min($total, $Bytes); $i++) {
        if ($resp[$i] -ne $payload[$i]) { $mis += $i }
    }
    Write-Host "Total mismatches: $($mis.Count)"
    if ($mis.Count -gt 0) {
        $start = $mis[0]
        Write-Host "First mismatch at $start (got '$($resp[$start])' exp '$($payload[$start])')"
        # contiguous mismatch range
        $contig = 1
        while ($contig -lt $mis.Count -and $mis[$contig] -eq $mis[0] + $contig) { $contig++ }
        Write-Host "First contiguous bad run: $($mis[0])..$($mis[0]+$contig-1) ($contig bytes)"
        Write-Host "Bad bytes around start:"
        for ($i = $start; $i -lt [Math]::Min($start + 40, $total); $i++) {
            Write-Host ("  off {0}: got='{1}' exp='{2}'" -f $i, $resp[$i], $payload[$i])
        }
    }
}
$t.Close()
