#=============================================================================
# ping_test.ps1 — ping the FPGA N times, report pass/fail count
# Usage: powershell -File ping_test.ps1 -Count 30
#=============================================================================
param([int]$Count = 30, [string]$Ip = "192.168.100.2")

$out = ping -n $Count -w 700 $Ip 2>&1 | Out-String
# count "TTL=" occurrences (works in Chinese Windows too)
$ok = ([regex]::Matches($out, "TTL=")).Count
Write-Host "ping $Ip : $ok/$Count replies"
Write-Host $out -NoNewline | Select-String -Pattern "Ping|Lost|loss|丢失|统计" | Out-Null
if ($ok -gt 0) { exit 0 } else { exit 1 }
