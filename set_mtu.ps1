param([int]$Mtu = 500)
$if = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match "Killer|E5000B" } | Select-Object -First 1
Write-Host "Setting MTU $Mtu on $($if.Name)..."
Set-NetIPInterface -InterfaceAlias $if.Name -AddressFamily IPv4 -NlMtu $Mtu
Start-Sleep -Seconds 2
Get-NetIPInterface -InterfaceAlias $if.Name -AddressFamily IPv4 | Select-Object InterfaceAlias, NlMtu | Format-Table -AutoSize | Out-String | Write-Host
