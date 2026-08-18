<#
.SYNOPSIS
    UDP echo client test for the FPGA UDP echo server (192.168.100.2:8080).
    Sends Payload to Server:Port, receives the reply, compares byte-for-byte.
    -LocalPort 0 (default) = ephemeral local port (strict test: reply must be
    addressed to the request's source port). -LocalPort 8080 = fixed bind test.
    Exit code: 0 = PASS, 1 = FAIL.
#>
param(
    [string]$Server     = "192.168.100.2",
    [int]$Port          = 8080,
    [string]$Payload    = "hello ECO",
    [int]$Count         = 3,
    [int]$TimeoutMs     = 8000,
    [int]$LocalPort     = 0
)

$ErrorActionPreference = "Stop"
$fail = 0
$payloadBytes = [System.Text.Encoding]::ASCII.GetBytes($Payload)

for ($i = 1; $i -le $Count; $i++) {
    $client = New-Object System.Net.Sockets.UdpClient
    try {
        if ($LocalPort -gt 0) { $client.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, $LocalPort))) }
        $localEp = $client.Client.LocalEndPoint
        $remoteEp = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($Server), $Port)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $null = $client.Send($payloadBytes, $payloadBytes.Length, $remoteEp)
        $client.Client.ReceiveTimeout = $TimeoutMs
        try {
            $reply = $client.Receive([ref]$remoteEp)
            $sw.Stop()
            $replyText = [System.Text.Encoding]::ASCII.GetString($reply)
            $match = ($reply.Length -eq $payloadBytes.Length) -and
                     (($payloadBytes -join ',') -eq ($reply -join ','))
            if ($match) {
                Write-Host ("PASS #{0}: '{1}' -> '{2}' in {3} ms (local {4})" -f $i, $Payload, $replyText, $sw.ElapsedMilliseconds, $localEp)
            } else {
                $fail++
                Write-Host ("FAIL #{0}: reply mismatch: got '{1}' ({2} bytes), expected '{3}' ({4} bytes), local {5}" -f $i, $replyText, $reply.Length, $Payload, $payloadBytes.Length, $localEp)
            }
        } catch [System.Net.Sockets.SocketException] {
            $fail++
            $sw.Stop()
            Write-Host ("FAIL #{0}: receive timeout after {1} ms, got no reply (local {2})" -f $i, $sw.ElapsedMilliseconds, $localEp)
        }
    } catch {
        $fail++
        Write-Host ("FAIL #{0}: {1}" -f $i, $_.Exception.Message)
    } finally {
        $client.Close()
    }
    Start-Sleep -Milliseconds 300
}

Write-Host "========================================="
Write-Host (" UDP test: {0}/{1} passed" -f ($Count - $fail), $Count)
Write-Host "========================================="
exit ($fail -gt 0)
