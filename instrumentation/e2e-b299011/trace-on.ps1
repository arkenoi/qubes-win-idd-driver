$ErrorActionPreference='SilentlyContinue'
$k='HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools\gui-agent'
New-Item -Path $k -Force | Out-Null
Set-ItemProperty -Path $k -Name 'ProtoTrace' -Value 1 -Type DWord
Set-ItemProperty -Path $k -Name 'LogLevel'   -Value 4 -Type DWord
$it=Get-ItemProperty $k
Write-Output ("RESULT=REGSET ProtoTrace={0} LogLevel={1}" -f $it.ProtoTrace,$it.LogLevel)
$before=(Get-ChildItem 'C:\Program Files\Qubes Tools\log' -Filter 'gui-agent*.log' | Sort LastWriteTime -Desc | Select -First 1).Name
Write-Output ("RESULT=LOGBEFORE {0}" -f $before)
Get-Process gui-agent -EA SilentlyContinue | Stop-Process -Force
Start-Sleep 16
$p=Get-Process gui-agent -EA SilentlyContinue
Write-Output ("RESULT=AGENTPID {0}" -f $(if($p){$p.Id}else{'NONE'}))
$f=(Get-ChildItem 'C:\Program Files\Qubes Tools\log' -Filter 'gui-agent*.log' | Sort LastWriteTime -Desc | Select -First 1)
Write-Output ("RESULT=LOGAFTER {0}" -f $f.Name)
$g=(Get-Content $f.FullName | Select-String 'QGAPROTO (on|off)' | Select -Last 1)
Write-Output ("RESULT=GATE {0}" -f ($g -join ' ').Trim())
$d=(Get-Content $f.FullName | Select-String 'QGAPROTO,' | Measure-Object).Count
Write-Output ("RESULT=PROTORECS {0}" -f $d)
