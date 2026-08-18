$if = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match "Killer|E5000B" } | Select-Object -First 1
Write-Host "=== Get-NetAdapterAdvancedProperty full ==="
Get-NetAdapterAdvancedProperty -Name $if.Name -ErrorAction SilentlyContinue |
  Where-Object { $_.DisplayName -match "Large|Send|TCP|IPv4|Checksum" } |
  Select-Object DisplayName, DisplayValue, RegistryKeyword | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
Write-Host "=== netsh interface tcp show global ==="
netsh int tcp show global 2>&1 | Out-String | Write-Host
