$if = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match "Killer|E5000B" } | Select-Object -First 1
Get-NetAdapterAdvancedProperty -Name $if.Name | ForEach-Object {
    Write-Host ("{0} | {1} | {2} | {3}" -f $_.DisplayName, $_.DisplayValue, $_.RegistryKeyword, $_.RegistryValue)
}
