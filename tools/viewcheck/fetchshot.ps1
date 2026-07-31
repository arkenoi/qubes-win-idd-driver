# base64 the guest screenshot to stdout so the orchestrator can reconstruct it.
$p = 'C:\Windows\Temp\guestshot.png'
if (-not (Test-Path $p)) { Write-Output 'NOFILE'; exit 1 }
Write-Output 'B64START'
[Convert]::ToBase64String([IO.File]::ReadAllBytes($p)) -split '(.{1000})' | Where-Object { $_ } | ForEach-Object { $_ }
Write-Output 'B64END'
