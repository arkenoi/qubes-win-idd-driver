# Deploy a new gui-agent with ShellManaged=2 (start-only managed - the shipped default
# since the GWeck goal batch), restart via the watchdog service.
# For win11-fresh (EnableLUA=0, qtest runs elevated). Prints === RESULT === with hash + pid.
# Push guest/restart-gui-agent.ps1 next to this script: the agent is stopped THROUGH THE SERVICE
# THAT OWNS IT and proven gone by handle (Stop-GuiAgentOwner), the binary swapped, and the service
# started with the NEW agent proven by its log turnover (Start-GuiAgentOwner). Owner 2026-10-07:
# never `Get-Process gui-agent | Stop-Process`, which raced the watchdog's own relaunch.
param([string]$NewAgent = 'C:\Users\user\Documents\QubesIncoming\win-idd-mgmt\gui-agent.exe',
      [int]$ShellManaged = 2)
$ErrorActionPreference = 'Continue'
$bin = 'C:\Program Files\Qubes Tools\bin\gui-agent.exe'
$k = 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools\gui-agent'
if (-not (Test-Path $k)) { New-Item $k -Force | Out-Null }
Set-ItemProperty $k -Name ShellManaged -Value $ShellManaged -Type DWord

$helper = Join-Path $PSScriptRoot 'restart-gui-agent.ps1'
if (-not (Test-Path -LiteralPath $helper)) { Write-Output '=== RESULT ==='; @{ ok = $false; error = 'restart-gui-agent.ps1 not pushed next to this script (tools/qtest push guest/restart-gui-agent.ps1)' } | ConvertTo-Json; exit 3 }
. $helper
$st = Stop-GuiAgentOwner
if (-not (Test-Path "$bin.orig")) { Copy-Item $bin "$bin.orig" -Force }
Copy-Item $NewAgent $bin -Force
$ra = Start-GuiAgentOwner -Stopped $st
foreach ($ln in @($ra.lines)) { Write-Output $ln }
Write-Output '=== RESULT ==='
@{ bin_sha256 = $(if (Test-Path $bin) { (Get-FileHash $bin -Algorithm SHA256).Hash } else { 'none' })
   shellmanaged = (Get-ItemProperty $k).ShellManaged
   agent_pid = $(if ($ra.ok) { $ra.new_pid } else { $null })
   agent_running = $ra.ok
   restart = $ra.verdict; restart_reason = $ra.reason } | ConvertTo-Json
