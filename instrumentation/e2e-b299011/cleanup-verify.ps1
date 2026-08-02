$ErrorActionPreference='SilentlyContinue'
Get-Process notepad,chromerepro -EA SilentlyContinue | Stop-Process -Force
Start-Sleep 3
Write-Output ("RESULT=PROCS {0}" -f ((Get-Process notepad,chromerepro -EA SilentlyContinue|Measure-Object).Count))
$k='HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools\gui-agent'
$it=Get-ItemProperty $k
Write-Output ("RESULT=REG LogLevel={0} ProtoTracePresent={1}" -f $it.LogLevel,($it.PSObject.Properties.Name -contains 'ProtoTrace'))
$p=Get-Process gui-agent -EA SilentlyContinue
Write-Output ("RESULT=AGENTPID {0}" -f $(if($p){$p.Id}else{'NONE'}))
$svc=@(Get-Service | Where-Object { $_.DisplayName -match 'Qubes' } | ForEach-Object { "$($_.Name)=$($_.Status)" })
Write-Output ("RESULT=SERVICES {0}" -f ($svc -join ';'))
