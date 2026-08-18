$if = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match "Killer|E5000B" } | Select-Object -First 1
Write-Host "Disabling LSO v2 IPv4 on $($if.Name)..."
Set-NetAdapterAdvancedProperty -Name $if.Name -RegistryKeyword "*LsoV2IPv4" -RegistryValue 0 -NoRestart
Write-Host "Disabling USO IPv4..."
Set-NetAdapterAdvancedProperty -Name $if.Name -RegistryKeyword "*UsoIPv4" -RegistryValue 0 -NoRestart
# verify
Get-NetAdapterAdvancedProperty -Name $if.Name | Where-Object { $_.DisplayName -match "Large|Segmentation" } | Select-Object DisplayName, DisplayValue | Format-Table -AutoSize | Out-String | Write-Host
