$ErrorActionPreference='SilentlyContinue'
Get-Process chromerepro -EA SilentlyContinue | Stop-Process -Force
Get-Process notepad     -EA SilentlyContinue | Stop-Process -Force
Start-Sleep 2
$k='HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools\gui-agent'
Remove-ItemProperty -Path $k -Name 'ProtoTrace' -Force -EA SilentlyContinue
Set-ItemProperty  -Path $k -Name 'LogLevel' -Value 3 -Type DWord
$it=Get-ItemProperty $k
$has = ($it.PSObject.Properties.Name -contains 'ProtoTrace')
Write-Output ("RESULT=REGRESTORED LogLevel={0} ProtoTracePresent={1}" -f $it.LogLevel,$has)
Get-Process gui-agent -EA SilentlyContinue | Stop-Process -Force
Start-Sleep 16
$p=Get-Process gui-agent -EA SilentlyContinue
Write-Output ("RESULT=AGENTPID {0}" -f $(if($p){$p.Id}else{'NONE'}))
$f=(Get-ChildItem 'C:\Program Files\Qubes Tools\log' -Filter 'gui-agent*.log'|Sort LastWriteTime -Desc|Select -First 1)
Write-Output ("RESULT=LOGAFTER {0}" -f $f.Name)
$n=(Get-Content $f.FullName | Select-String 'QGAPROTO,' | Measure-Object).Count
Write-Output ("RESULT=PROTORECS-AFTER {0}" -f $n)
$d=(Get-Content $f.FullName | Select-String -Pattern '-\d+-D\]' | Measure-Object).Count
Write-Output ("RESULT=DEBUGLINES-AFTER {0}" -f $d)
Write-Output ("RESULT=PROCS {0}" -f ((Get-Process chromerepro,notepad -EA SilentlyContinue | Measure-Object).Count))
