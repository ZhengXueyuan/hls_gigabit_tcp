$if = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match "Killer|E5000B" } | Select-Object -First 1
if (-not $if) { Write-Host "no killer adapter found"; exit 1 }
Write-Host ("Adapter: {0}  {1}  ifIndex={2}" -f $if.Name, $if.InterfaceDescription, $if.ifIndex)
Get-NetAdapterAdvancedProperty -Name $if.Name -ErrorAction SilentlyContinue |
  Where-Object { $_.DisplayName -match "Large Send|LSO|Offload|Jumbo|Flow Control|Interrupt" } |
  Select-Object DisplayName, DisplayValue, RegistryKeyword | Format-Table -AutoSize | Out-String | Write-Host
