# Toggle the gui-agent ShellManaged switch and restart the agent (watchdog revives it).
# ShellManaged=0 restores shell surfaces (Start/toasts) to override_redirect popups -
# cropped + positioned + NOT WM-decorated: no resize border, no dom0-drag feedback loop.
param([int]$Value = 0)
$ErrorActionPreference = 'Continue'
$k = 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools\gui-agent'
if (-not (Test-Path $k)) { New-Item $k -Force | Out-Null }
Set-ItemProperty $k -Name ShellManaged -Value $Value -Type DWord
$before = (Get-Process gui-agent -ErrorAction SilentlyContinue).Id
Get-Process gui-agent -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 8
$p = Get-Process gui-agent -ErrorAction SilentlyContinue
Write-Output '=== RESULT ==='
@{ shellmanaged = (Get-ItemProperty $k).ShellManaged
   pid_before = $before
   pid_after = if ($p) { $p.Id } else { $null }
   agent_running = [bool]$p } | ConvertTo-Json
