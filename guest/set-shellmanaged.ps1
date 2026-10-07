# Toggle the gui-agent ShellManaged switch and restart the agent through the service that owns it.
# ShellManaged=0 restores shell surfaces (Start/toasts) to override_redirect popups -
# cropped + positioned + NOT WM-decorated: no resize border, no dom0-drag feedback loop.
# Push guest/restart-gui-agent.ps1 next to this script: the restart is proven by the agent's own
# log turnover (owner 2026-10-07: never `Get-Process gui-agent | Stop-Process`, which raced the
# watchdog's own relaunch and could leave the OLD switch in force).
param([int]$Value = 0)
$ErrorActionPreference = 'Continue'
$k = 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools\gui-agent'
if (-not (Test-Path $k)) { New-Item $k -Force | Out-Null }
Set-ItemProperty $k -Name ShellManaged -Value $Value -Type DWord
$helper = Join-Path $PSScriptRoot 'restart-gui-agent.ps1'
if (-not (Test-Path -LiteralPath $helper)) { Write-Output '=== RESULT ==='; @{ ok = $false; error = 'restart-gui-agent.ps1 not pushed next to this script (tools/qtest push guest/restart-gui-agent.ps1)' } | ConvertTo-Json -Compress; exit 3 }
. $helper
$ra = Restart-GuiAgent
foreach ($ln in @($ra.lines)) { Write-Output $ln }
Write-Output '=== RESULT ==='
@{ shellmanaged = (Get-ItemProperty $k).ShellManaged
   pid_before = $ra.old_pid
   pid_after = $(if ($ra.ok) { $ra.new_pid } else { $null })
   agent_running = $ra.ok
   restart = $ra.verdict; restart_reason = $ra.reason } | ConvertTo-Json
