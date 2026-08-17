<#
.SYNOPSIS
    ICMP ping test for the FPGA (default 192.168.0.2) using
    System.Net.NetworkInformation.Ping.
    Prints RTT per reply and a PASS/FAIL summary with loss count.
    Exit code: 0 = no loss, 1 = at least one reply lost.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File icmp_test.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File icmp_test.ps1 -Server 192.168.0.2 -Count 10
#>
param(
    [string]$Server    = "192.168.0.2",
    [int]$Count        = 5,
    [int]$TimeoutMs    = 1000
)

$ping = New-Object System.Net.NetworkInformation.Ping
$lost = 0
$rtts = @()

for ($i = 1; $i -le $Count; $i++) {
    $reply = $ping.Send($Server, $TimeoutMs)
    if ($reply.Status -eq "Success") {
        $rtts += $reply.RoundtripTime
        Write-Host ("reply[$i/$Count]  $Server  RTT=$($reply.RoundtripTime) ms")
    } else {
        $lost++
        Write-Host ("reply[$i/$Count]  $Server  $($reply.Status)")
    }
    if ($i -lt $Count) { Start-Sleep -Milliseconds 100 }
}

$received = $Count - $lost
$lossPct = [math]::Round(($lost / $Count) * 100, 1)
$avg = if ($rtts.Count -gt 0) { [math]::Round(($rtts | Measure-Object -Average).Average, 1) } else { "n/a" }
$min = if ($rtts.Count -gt 0) { ($rtts | Measure-Object -Minimum).Minimum } else { "n/a" }
$max = if ($rtts.Count -gt 0) { ($rtts | Measure-Object -Maximum).Maximum } else { "n/a" }

if ($lost -eq 0) {
    Write-Host ("PASS: $received/$Count replies, loss=$lossPct%, RTT min/avg/max = $min/$avg/$max ms")
    exit 0
} else {
    Write-Host ("FAIL: $received/$Count replies, loss=$lossPct%, RTT min/avg/max = $min/$avg/$max ms")
    exit 1
}
