<#
.SYNOPSIS
    Read-only report of the PC's ARP cache entry for the FPGA (default 192.168.0.2):
    MAC address, state (Reachable / Stale / Unreachable), and which interface the
    traffic to the server will leave on.
    Optional -Delete purges stale/unreachable entries for the IP before a test run
    (requires an elevated shell; default is read-only).
    FPGA expected MAC (udp_hls board): 00:0A:35:01:FE:C0

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File arp_check.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File arp_check.ps1 -Delete
#>
param(
    [string]$Server = "192.168.0.2",
    [switch]$Delete
)

# ---------- ARP cache entries for the server IP ----------
$entries = @(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -eq $Server })

if ($entries.Count -eq 0) {
    Write-Host "ARP: no cached entry for $Server (will be created by the first ARP request on contact)"
} else {
    foreach ($e in $entries) {
        $mac = $e.LinkLayerAddress
        Write-Host ("ARP: {0}  MAC={1}  state={2}  ifIndex={3} ({4})" -f `
            $e.IPAddress, $mac, $e.State, $e.InterfaceIndex, $e.InterfaceAlias)
        if (-not $mac -or $mac -eq "00-00-00-00-00-00" -or $e.State -eq "Unreachable") {
            Write-Host "  WARNING: not a valid neighbor - FPGA did not answer ARP on this interface"
        } elseif ($mac -ne "00-0A-35-01-FE-C0") {
            Write-Host "  NOTE: MAC differs from the udp_hls board MAC 00:0A:35:01:FE:C0"
        }
    }
}

# ---------- Which interface will carry the traffic ----------
# Find-NetRoute returns a row per candidate (source IP row has empty NextHop);
# pick the row that actually carries the route info.
$route = @(Find-NetRoute -RemoteIPAddress $Server -ErrorAction SilentlyContinue |
    Where-Object { $_.NextHop } | Select-Object -First 1)
if ($route.Count -gt 0) {
    Write-Host ("route to {0}: ifIndex {1} ({2}), nextHop {3}, metric {4}" -f `
        $Server, $route[0].InterfaceIndex, $route[0].InterfaceAlias, $route[0].NextHop, $route[0].RouteMetric)
    if ($route[0].InterfaceAlias -eq "WLAN") {
        Write-Host "  WARNING: traffic would leave via WLAN - if the FPGA is on the wired NIC, this is wrong;"
        Write-Host "           verify the wired NIC has static IP 192.168.0.1/24 and check route metrics."
    }
} else {
    Write-Host "route to ${Server}: none found"
}

# ---------- Optional purge (needs admin) ----------
if ($Delete) {
    foreach ($e in $entries) {
        if (-not $e.LinkLayerAddress -or $e.LinkLayerAddress -eq "00-00-00-00-00-00" -or $e.State -eq "Unreachable") {
            try {
                Remove-NetNeighbor -InterfaceIndex $e.InterfaceIndex -IPAddress $e.IPAddress -Confirm:$false -ErrorAction Stop
                Write-Host ("deleted stale ARP entry for $Server on interface $($e.InterfaceAlias)")
            } catch {
                Write-Host ("could not delete ARP entry (run elevated): $($_.Exception.Message)")
            }
        }
    }
    & arp -d $Server 2>$null
    Write-Host "purged ARP entry for $Server; re-run without -Delete to confirm"
} else {
    Write-Host "(read-only report; use -Delete to purge stale entries before a test run)"
}
exit 0
