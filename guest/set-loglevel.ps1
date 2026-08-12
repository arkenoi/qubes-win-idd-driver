# Raise/lower gui-agent LogLevel and restart, to capture incoming MSG_CONFIGURE (Updating
# position, logged at Verbose) alongside the outgoing SendWindowConfigure.
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
Get-Process gui-agent -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 8
$p = Get-Process gui-agent -ErrorAction SilentlyContinue
Write-Output '=== RESULT ==='
@{ loglevel_global = (Get-ItemProperty $k).LogLevel
   loglevel_module = (Get-ItemProperty $km).LogLevel; agent_pid = if ($p) { $p.Id } else { $null }
   log = (Get-ChildItem 'Q:\Qubes Logs' -Filter 'gui-agent-*.log' | Sort LastWriteTime -Desc | Select -First 1).Name } | ConvertTo-Json
