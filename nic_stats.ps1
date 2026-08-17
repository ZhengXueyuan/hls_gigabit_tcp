param([int]$Runs = 3, [int]$PauseSec = 4)
$nic = Get-NetAdapter | Where-Object { $_.InterfaceDescription -match "Killer" } | Select-Object -First 1
"Adapter: $($nic.Name)  Status=$($nic.Status)  LinkSpeed=$($nic.LinkSpeed)"
for ($i = 0; $i -lt $Runs; $i++) {
    $s = $nic | Get-NetAdapterStatistics
    $p = $s | Get-Member -MemberType NoteProperty | ForEach-Object { $_.Name }
    "{0}: {1}" -f (Get-Date -Format HH:mm:ss), (($p | ForEach-Object { "$_=$($s.$_)" }) -join '  ')
    if ($i -lt $Runs - 1) { Start-Sleep -Seconds $PauseSec }
}
