$if = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match "Killer|E5000B" } | Select-Object -First 1
Write-Host "Restarting adapter $($if.Name)..."
Restart-NetAdapter -Name $if.Name -Confirm:$false
Start-Sleep -Seconds 8
$if2 = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match "Killer|E5000B" } | Select-Object -First 1
Write-Host "Status: $($if2.Status)  LinkSpeed: $($if2.LinkSpeed)"
