Write-Host "=== NIC MTU ==="
Get-NetIPInterface -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -match "以太网 2|Ethernet 2|Killer" -or $_.InterfaceMetric -ne $null } | Select-Object InterfaceAlias, NlMtu, InterfaceMetric | Format-Table -AutoSize | Out-String | Write-Host
Get-NetAdapter | ForEach-Object { Write-Host ("{0}  MTU={1}  Status={2}" -f $_.Name, $_.MtuSize, $_.Status) }
Write-Host ""
Write-Host "=== PMTUD / TCP global ==="
netsh int ipv4 show subinterfaces 2>&1 | Out-String | Write-Host
netsh int tcp show global 2>&1 | Out-String | Write-Host
