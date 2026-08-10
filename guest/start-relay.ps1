param([string]$Target='@default',[int]$Port=8082)
Get-NetTCPConnection -LocalPort $Port -State Listen -EA SilentlyContinue | ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -EA SilentlyContinue }
Start-Sleep -Milliseconds 300
Start-Process -FilePath 'C:\Users\Public\relaytest\qubes-updates-relay.exe' -ArgumentList '--listen',"$Port",'--target',$Target,'--log','C:\Users\Public\relaytest' -WindowStyle Hidden
Start-Sleep -Milliseconds 1000
$n = @(Get-NetTCPConnection -LocalPort $Port -State Listen -EA SilentlyContinue).Count
Write-Output ("RELAY-BOUND=" + $n)
