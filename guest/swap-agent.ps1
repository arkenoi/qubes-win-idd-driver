# Swap the QWT gui-agent binary for a locally built one (Track A, CLAUDE.md Phase 1A step 3).
# Run ELEVATED in win-idd-test (needs to stop/start a service and write to Program Files).
#
#   tools/qtest push artifacts-agent/gui-agent.exe guest/swap-agent.ps1
#   tools/qtest ps "& '<incoming>\swap-agent.ps1' -NewAgent '<incoming>\gui-agent.exe'"
#
# Keeps a .orig backup so -Restore puts the shipped 4.2.2 binary back. Verifies the agent
# actually comes back up (the watchdog service must reach Running and the process must
# exist), because a bad swap otherwise leaves the VM with no GUI and only qrexec to recover.
param(
    [string]$NewAgent,
    [switch]$Restore,
    [string]$BinDir = 'C:\Program Files\Qubes Tools\bin'
)
$ErrorActionPreference = 'Continue'
$r = [ordered]@{}

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Write-Output '=== RESULT ==='; @{ ok=$false; error='not elevated' } | ConvertTo-Json; exit 1
}

$target = Join-Path $BinDir 'gui-agent.exe'
$backup = "$target.orig"
$svc    = 'QubesGuiWatchdog'

# The watchdog restarts gui-agent.exe, so it must be stopped before the file can be replaced.
Stop-Service $svc -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Get-Process gui-agent -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
$r.stopped = (Get-Service $svc).Status.ToString()

if ($Restore) {
    if (Test-Path $backup) { Copy-Item $backup $target -Force; $r.restored = $true }
    else { $r.restored = $false; $r.error = 'no .orig backup present' }
} else {
    if (-not (Test-Path $NewAgent)) {
        Write-Output '=== RESULT ==='; @{ ok=$false; error="no such file: $NewAgent" } | ConvertTo-Json; exit 1
    }
    if (-not (Test-Path $backup)) { Copy-Item $target $backup -Force; $r.backup_created = $true }
    Copy-Item $NewAgent $target -Force
    $r.swapped = $true
    $r.new_version = (Get-Item $target).VersionInfo.FileVersion
    $r.new_size = (Get-Item $target).Length
}

Start-Service $svc -ErrorAction SilentlyContinue
Start-Sleep -Seconds 6
$r.service = (Get-Service $svc).Status.ToString()
$r.agent_running = [bool](Get-Process gui-agent -ErrorAction SilentlyContinue)
$log = Get-ChildItem 'C:\Program Files\Qubes Tools\log' -Filter 'gui-agent-*.log' -ErrorAction SilentlyContinue |
       Sort-Object LastWriteTime -Descending | Select-Object -First 1
$r.newest_log = $log.Name
if ($log) { $r.log_tail = (Get-Content $log.FullName -Tail 15) }
$r.ok = ($r.service -eq 'Running' -and $r.agent_running)

Write-Output '=== RESULT ==='
$r | ConvertTo-Json -Depth 5
