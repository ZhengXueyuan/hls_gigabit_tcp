Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object Name, LinkSpeed, InterfaceDescription | Format-Table -AutoSize
