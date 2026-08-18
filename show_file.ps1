param([string]$Path = "pk_tcp8.txt")
$lines = Get-Content -LiteralPath $Path -Encoding Unicode
Write-Host "line count: $($lines.Count)"
foreach ($ln in $lines) {
    Write-Host $ln.Substring(0, [Math]::Min($ln.Length, 400))
}
