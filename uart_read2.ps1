$port = New-Object System.IO.Ports.SerialPort COM8,9600,'None',8,1
$port.Open()
Start-Sleep -Milliseconds 5000
$line = $port.ReadExisting()
$port.Close()
$line -split "`n" | Select-String "39:" | ForEach-Object { Write-Host $_ }
