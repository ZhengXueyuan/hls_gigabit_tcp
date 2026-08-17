<#
.SYNOPSIS
    TCP echo client test for the FPGA echo server (default 192.168.0.2:7).
    Sends -Bytes bytes of a repeating 0x00..0xFF pattern, reads back the same
    count, compares byte-for-byte.
    Exit code: 0 = PASS, 1 = FAIL.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tcp_test.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File tcp_test.ps1 -Server 192.168.0.2 -Port 7 -Bytes 512 -TimeoutSec 5
#>
param(
    [string]$Server     = "192.168.0.2",
    [int]$Port          = 7,
    [int]$Bytes         = 100,
    [int]$TimeoutSec    = 10
)

$ErrorActionPreference = "Stop"

function Fail([string]$msg) {
    Write-Host ("FAIL: " + $msg)
    try { $client.Close() } catch {}
    exit 1
}

# Unwrap PowerShell's MethodInvocationException and Task's AggregateException
# wrappers to the real underlying exception (e.g. SocketException).
function Unwrap($ex) {
    while ($null -ne $ex.InnerException -and (
        $ex -is [System.Management.Automation.MethodInvocationException] -or
        $ex -is [System.AggregateException])) {
        $ex = $ex.InnerException
    }
    return $ex
}

# Build the recognizable pattern: sequential bytes 0x00..0xFF repeating.
$pattern = New-Object byte[] $Bytes
for ($i = 0; $i -lt $Bytes; $i++) { $pattern[$i] = [byte]($i % 256) }

$stage = "setup"
$client = New-Object System.Net.Sockets.TcpClient

try {
    # ---------- Connect with explicit timeout ----------
    $stage = "connect"
    $swConnect = [System.Diagnostics.Stopwatch]::StartNew()
    $connectTask = $client.ConnectAsync($Server, $Port)
    try {
        if (-not $connectTask.Wait($TimeoutSec * 1000)) {
            Fail("connect timeout: no response from $Server : $Port within $TimeoutSec s (FPGA down / wrong IP / ARP unresolved)")
        }
        $connectTask.GetAwaiter().GetResult()   # re-throws on refused / unreachable
    } catch {
        $e = Unwrap $_.Exception
        if ($e -is [System.Net.Sockets.SocketException]) {
            switch ($e.SocketErrorCode) {
                "ConnectionRefused"  { Fail("connect refused: $Server : $Port (nothing listening / FPGA not booted / wrong port)") }
                "ConnectionReset"    { Fail("connect reset by peer: RST during handshake") }
                "HostUnreachable"    { Fail("host unreachable: no route to $Server (check cable, PC NIC 192.168.0.1/24, ARP)") }
                "NetworkUnreachable" { Fail("network unreachable: check PC NIC configuration (static 192.168.0.1/24)") }
                "TimedOut"           { Fail("connect timeout: no SYN-ACK from $Server : $Port within $TimeoutSec s") }
                default              { Fail("connect failed: $($e.Message) (code $($e.SocketErrorCode))") }
            }
        }
        Fail("connect failed: $($e.Message)")
    }
    $connectMs = $swConnect.ElapsedMilliseconds
    Write-Host ("connected to $Server : $Port in $connectMs ms")

    # ---------- Send pattern ----------
    $stage = "send"
    $swEcho = [System.Diagnostics.Stopwatch]::StartNew()
    $client.NoDelay = $true
    $stream = $client.GetStream()
    $stream.Write($pattern, 0, $Bytes)
    $stream.Flush()

    # ---------- Read back exactly $Bytes with timeout ----------
    $stage = "read"
    $echo = New-Object byte[] $Bytes
    $total = 0
    while ($total -lt $Bytes) {
        $remainMs = [int]($TimeoutSec * 1000 - $swEcho.ElapsedMilliseconds)
        if ($remainMs -le 0) {
            Fail("echo timeout: received $total / $Bytes bytes within $TimeoutSec s (echo incomplete)")
        }
        try {
            $readTask = $stream.ReadAsync($echo, $total, $Bytes - $total)
            if (-not $readTask.Wait($remainMs)) {
                Fail("echo timeout: received $total / $Bytes bytes within $TimeoutSec s (echo incomplete)")
            }
            $n = $readTask.GetAwaiter().GetResult()
        } catch {
            $e = Unwrap $_.Exception
            if ($e -is [System.Net.Sockets.SocketException] -and $e.SocketErrorCode -eq "ConnectionReset") {
                Fail("connection reset during echo (peer sent RST, FPGA TCP stack dropped the conn) after $total / $Bytes bytes")
            }
            Fail("read failed: $($e.Message)")
        }
        if ($n -le 0) {
            Fail("connection closed by peer after $total / $Bytes bytes (echo shorter than sent)")
        }
        $total += $n
    }
    $echoMs = $swEcho.ElapsedMilliseconds
    $stream.Flush()
    $client.Close()

    # ---------- Compare byte-for-byte ----------
    $stage = "verify"
    for ($i = 0; $i -lt $Bytes; $i++) {
        if ($pattern[$i] -ne $echo[$i]) {
            Fail("data mismatch at offset $i : got 0x$('{0:X2}' -f $echo[$i]) expected 0x$('{0:X2}' -f $pattern[$i])")
        }
    }

    Write-Host ("PASS: $Server : $Port echo ok, $Bytes bytes, connect=$connectMs ms echo=$echoMs ms")
    exit 0

} catch {
    $e = Unwrap $_.Exception
    Fail("$stage failed: $($e.Message)")
}
