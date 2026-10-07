# Turn ProtoTrace (+ wobble) on/off and restart the agent, to log every MSG_CONFIGURE the
# agent sends during a drag - the data needed to see the position echo/jump.
# Push guest/restart-gui-agent.ps1 next to this script: the agent is restarted THROUGH THE
# SERVICE THAT OWNS IT with the turnover proven (owner 2026-10-07: never `Get-Process gui-agent |
# Stop-Process`, which raced the watchdog's own relaunch and could leave the OLD setting in force).
param([int]$Value = 1)
$ErrorActionPreference = 'Continue'
$k = 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools\gui-agent'
if (-not (Test-Path $k)) { New-Item $k -Force | Out-Null }
Set-ItemProperty $k -Name ProtoTrace -Value $Value -Type DWord
Set-ItemProperty $k -Name ProtoTraceWobble -Value $Value -Type DWord
$helper = Join-Path $PSScriptRoot 'restart-gui-agent.ps1'
if (-not (Test-Path -LiteralPath $helper)) { Write-Output '=== RESULT ==='; @{ ok = $false; error = 'restart-gui-agent.ps1 not pushed next to this script (tools/qtest push guest/restart-gui-agent.ps1)' } | ConvertTo-Json -Compress; exit 3 }
. $helper
$ra = Restart-GuiAgent
foreach ($ln in @($ra.lines)) { Write-Output $ln }
Write-Output '=== RESULT ==='
@{ prototrace = (Get-ItemProperty $k).ProtoTrace
   agent_pid = $(if ($ra.ok) { $ra.new_pid } else { $null })
   restart = $ra.verdict; restart_reason = $ra.reason
   log = $ra.new_log } | ConvertTo-Json
