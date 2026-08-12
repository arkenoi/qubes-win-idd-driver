# Turn ProtoTrace (+ wobble) on/off and restart the agent, to log every MSG_CONFIGURE the
# agent sends during a drag - the data needed to see the position echo/jump.
param([int]$Value = 1)
$ErrorActionPreference = 'Continue'
$k = 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools\gui-agent'
if (-not (Test-Path $k)) { New-Item $k -Force | Out-Null }
Set-ItemProperty $k -Name ProtoTrace -Value $Value -Type DWord
Set-ItemProperty $k -Name ProtoTraceWobble -Value $Value -Type DWord
Get-Process gui-agent -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 8
$p = Get-Process gui-agent -ErrorAction SilentlyContinue
Write-Output '=== RESULT ==='
@{ prototrace = (Get-ItemProperty $k).ProtoTrace; agent_pid = if ($p) { $p.Id } else { $null }
   log = (Get-ChildItem 'Q:\Qubes Logs' -Filter 'gui-agent-*.log' | Sort LastWriteTime -Desc | Select -First 1).Name } | ConvertTo-Json
