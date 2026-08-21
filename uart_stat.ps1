$port = New-Object System.IO.Ports.SerialPort COM8,9600,'None',8,1
$port.Open()
$port.Write("?stat`r")
Start-Sleep -Milliseconds 1000
$line = $port.ReadExisting()
$port.Close()
Write-Host $line
