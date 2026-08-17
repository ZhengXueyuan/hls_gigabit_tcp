#=============================================================================
# cmd_test.ps1 — command response test (echoes + responses interleave)
#=============================================================================
param([string]$Port = "COM3")

try { Add-Type -AssemblyName System.IO.Ports -ErrorAction Stop } catch { }

$sp = New-Object System.IO.Ports.SerialPort($Port, 9600, [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
$sp.ReadTimeout  = 1000
$sp.WriteTimeout = 2000
$sp.Open()
Write-Host "Port $Port open, 9600-8N1"

# drain leftovers
Start-Sleep -Milliseconds 500
while ($sp.BytesToRead -gt 0) { $null = $sp.ReadByte() }

# CRLF Enter like a real terminal (bare \r alone previously hid the
# response-clobbering bug: the \n re-triggered the Enter branch)
$tests = @(
    @{ cmd = "?help`r`n"; expect = "?help" },
    @{ cmd = "?mac`r`n";  expect = "MAC:" },
    @{ cmd = "?ip`r`n";   expect = "IP:" },
    @{ cmd = "?stat`r`n"; expect = "UART" },
    @{ cmd = "?xxx`r`n";  expect = "?" }
)

$pass = 0; $fail = 0
foreach ($t in $tests) {
    # send command
    $sp.Write([System.Text.Encoding]::ASCII.GetBytes($t.cmd), 0, $t.cmd.Length)
    # read everything that comes back within 500ms
    $resp = ""
    $deadline = [DateTime]::Now.AddMilliseconds(500)
    while ([DateTime]::Now -lt $deadline) {
        while ($sp.BytesToRead -gt 0) {
            $b = $sp.ReadByte()
            if ($b -ge 32 -and $b -lt 127) { $resp += [char]$b }
            elseif ($b -eq 13 -or $b -eq 10) { $resp += " " }
        }
        Start-Sleep -Milliseconds 20
    }
    $resp = $resp.Trim()
    Write-Host ("[{0}] -> received: '{1}'" -f $t.cmd.Trim(), $resp)
    if ($resp.Contains($t.expect)) { $pass++ } else { $fail++ }
}

Write-Host "========================================="
Write-Host " Command test: $pass passed, $fail failed"
Write-Host "========================================="
$sp.Close()
exit ($fail -gt 0)
