# Raise/lower gui-agent LogLevel and restart, to capture incoming MSG_CONFIGURE (Updating
# position, logged at Verbose) alongside the outgoing SendWindowConfigure.
param([int]$Level = 5)
$ErrorActionPreference = 'Continue'
$k = 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools'
Set-ItemProperty $k -Name LogLevel -Value $Level -Type DWord
Get-Process gui-agent -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 8
$p = Get-Process gui-agent -ErrorAction SilentlyContinue
Write-Output '=== RESULT ==='
@{ loglevel = (Get-ItemProperty $k).LogLevel; agent_pid = if ($p) { $p.Id } else { $null }
   log = (Get-ChildItem 'Q:\Qubes Logs' -Filter 'gui-agent-*.log' | Sort LastWriteTime -Desc | Select -First 1).Name } | ConvertTo-Json
