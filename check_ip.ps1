Get-NetIPConfiguration | Where-Object { $_.NetAdapter.Status -eq 'Up' } | ForEach-Object {
    "Adapter: $($_.InterfaceAlias)"
    "  IPv4: $($_.IPv4Address.IPAddress)  Gateway: $($_.IPv4DefaultGateway.NextHop)"
}
