# Deploy a new gui-agent with ShellManaged=2 (start-only managed - the shipped default
# since the GWeck goal batch), restart via watchdog.
# For win11-fresh (EnableLUA=0, qtest runs elevated). Prints === RESULT === with hash + pid.
param([string]$NewAgent = 'C:\Users\user\Documents\QubesIncoming\win-idd-mgmt\gui-agent.exe',
      [int]$ShellManaged = 2)
$ErrorActionPreference = 'Continue'
$bin = 'C:\Program Files\Qubes Tools\bin\gui-agent.exe'
$svc = 'QubesGuiWatchdog'
$k = 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools\gui-agent'
if (-not (Test-Path $k)) { New-Item $k -Force | Out-Null }
Set-ItemProperty $k -Name ShellManaged -Value $ShellManaged -Type DWord

Stop-Service $svc -Force -ErrorAction SilentlyContinue
Start-Sleep 2
Get-Process gui-agent -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep 2
if (-not (Test-Path "$bin.orig")) { Copy-Item $bin "$bin.orig" -Force }
Copy-Item $NewAgent $bin -Force
Start-Service $svc -ErrorAction SilentlyContinue
Start-Sleep 6
$p = Get-Process gui-agent -ErrorAction SilentlyContinue
Write-Output '=== RESULT ==='
@{ bin_sha256 = (Get-FileHash $bin -Algorithm SHA256).Hash
   shellmanaged = (Get-ItemProperty $k).ShellManaged
   agent_pid = if ($p) { $p.Id } else { $null }
   agent_running = [bool]$p } | ConvertTo-Json
