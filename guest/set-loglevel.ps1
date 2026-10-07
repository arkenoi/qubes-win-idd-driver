# Raise/lower gui-agent LogLevel and restart, to capture incoming MSG_CONFIGURE (Updating
# position, logged at Verbose) alongside the outgoing SendWindowConfigure.
# Push guest/restart-gui-agent.ps1 next to this script: the agent is restarted THROUGH THE
# SERVICE THAT OWNS IT with the turnover proven (owner 2026-10-07: never `Get-Process gui-agent |
# Stop-Process`, which raced the watchdog's own relaunch and could leave the OLD level in force).
param([int]$Level = 5)
$ErrorActionPreference = 'Continue'
# The log library reads the MODULE key first (log.c LogReadLevel -> CfgReadDword(LogGetName(),
# "LogLevel")), so a stale gui-agent\LogLevel=3 silently overrides the global value and every
# Debug line vanishes - which defeated a whole afternoon of instrumentation (2026-08-12).
# Set BOTH, module key included.
$k = 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools'
$km = "$k\gui-agent"
Set-ItemProperty $k -Name LogLevel -Value $Level -Type DWord
if (-not (Test-Path $km)) { New-Item $km -Force | Out-Null }
Set-ItemProperty $km -Name LogLevel -Value $Level -Type DWord
$helper = Join-Path $PSScriptRoot 'restart-gui-agent.ps1'
if (-not (Test-Path -LiteralPath $helper)) { Write-Output '=== RESULT ==='; @{ ok = $false; error = 'restart-gui-agent.ps1 not pushed next to this script (tools/qtest push guest/restart-gui-agent.ps1)' } | ConvertTo-Json -Compress; exit 3 }
. $helper
$ra = Restart-GuiAgent
foreach ($ln in @($ra.lines)) { Write-Output $ln }
Write-Output '=== RESULT ==='
@{ loglevel_global = (Get-ItemProperty $k).LogLevel
   loglevel_module = (Get-ItemProperty $km).LogLevel
   agent_pid = $(if ($ra.ok) { $ra.new_pid } else { $null })
   restart = $ra.verdict; restart_reason = $ra.reason
   log = $ra.new_log } | ConvertTo-Json
