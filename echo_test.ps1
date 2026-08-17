#=============================================================================
# echo_test.ps1 — UART echo verification for udp_hls (COM3, 9600-8N1)
#=============================================================================
param(
    [string]$Port = "COM3",
    [int]$Count  = 20
)

try { Add-Type -AssemblyName System.IO.Ports -ErrorAction Stop } catch { }

$sp = New-Object System.IO.Ports.SerialPort($Port, 9600, [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
$sp.ReadTimeout  = 2000
$sp.WriteTimeout = 2000

try {
    $sp.Open()
} catch {
    Write-Host "ERROR: cannot open $Port — $($_.Exception.Message)"
    Write-Host "Available ports: $([System.IO.Ports.SerialPort]::GetPortNames() -join ', ')"
    exit 1
}
Write-Host "Port $Port open, 9600-8N1"

# drain any pending garbage first
while ($sp.BytesToRead -gt 0) { $null = $sp.ReadByte() }
Write-Host "Drained pending bytes"

# test pattern: printable + binary bytes
# NOTE: NO 0x0D/0x0A here - Enter bytes trigger the console "?\r\n" response
# which injects extra bytes into the stream (correct behavior, breaks the
# naive 1-send-1-read model). cmd_test.ps1 covers command semantics.
$tests = @(0x41,0x42,0x43,0x7A,0x5A,0x30,0x31,0x55,0xAA,0xA5,0x5A,0xFF,0x00,0x41,0x5A,0x7A,0x31,0x32,0x7E,0x40) | Select-Object -First $Count

$pass = 0; $fail = 0
for ($i = 0; $i -lt $tests.Count; $i++) {
    $b = [byte]$tests[$i]
    $sp.Write([byte[]]@($b), 0, 1)
    $rx = $sp.ReadByte()
    if ($rx -eq $b) {
        $pass++
    } else {
        $fail++
        Write-Host ("FAIL byte[{0}]: sent 0x{1:X2}, got 0x{2:X2}" -f $i, $b, $rx)
    }
    Start-Sleep -Milliseconds 5
}

Write-Host "========================================="
Write-Host " Echo test: $pass passed, $fail failed"
Write-Host "========================================="
$sp.Close()
exit ($fail -gt 0)
