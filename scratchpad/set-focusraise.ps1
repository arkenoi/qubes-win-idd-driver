# Switch the z-order-sync experiment on or off and PROVE which condition is running.
#
#   set-focusraise.ps1 -On        BringWindowToTop on MSG_FOCUS (guest z-order follows dom0)
#   set-focusraise.ps1            historic behaviour: SetForegroundWindow only
#
# g_FocusRaise is read once in PerfInit(), so the agent must be restarted for a change to
# take effect. The agent then logs "QGAFOCUSRAISE on|off" - this script reads that line back
# out of the NEW log and fails if it does not match what was asked for. Without that readback
# an A/B can silently measure the same condition twice and report the difference as noise.
param([switch]$On)
$ErrorActionPreference = 'Continue'

$pr = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Output "RESULT=FAIL not elevated - cannot write HKLM or restart the agent service"
    exit 2
}

$want    = [int]$On.IsPresent
$wantStr = if ($On) { 'on' } else { 'off' }
$key     = 'HKLM:\Software\Invisible Things Lab\Qubes Tools'
$svc     = 'QubesGuiWatchdog'

# Log directory follows the configured LogDir; hardcoding it has been wrong in four separate
# scripts in this repo already.
$logDir = 'C:\Program Files\Qubes Tools\log'
try {
    $d = (Get-ItemProperty $key -Name 'LogDir' -ErrorAction Stop).LogDir
    if ($d) { $logDir = $d }
} catch { }

try {
    New-ItemProperty -Path $key -Name 'FocusRaise' -Value $want -PropertyType DWord -Force -ErrorAction Stop | Out-Null
} catch {
    Write-Output ("RESULT=FAIL registry write: " + $_.Exception.Message); exit 3
}
$rb = (Get-ItemProperty $key -Name 'FocusRaise' -ErrorAction SilentlyContinue).FocusRaise
if ($rb -ne $want) { Write-Output "RESULT=FAIL FocusRaise readback '$rb' != $want"; exit 4 }

# Restart so PerfInit re-reads it. Both A/B sides take this same path, so the restart itself
# is common-mode and cannot bias the comparison.
$before = Get-ChildItem $logDir -Filter 'gui-agent-*.log' -ErrorAction SilentlyContinue |
          Sort-Object LastWriteTime -Descending | Select-Object -First 1
Stop-Service $svc -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
Get-Process gui-agent -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3
Start-Service $svc -ErrorAction SilentlyContinue
Start-Sleep -Seconds 10

$log = Get-ChildItem $logDir -Filter 'gui-agent-*.log' -ErrorAction SilentlyContinue |
       Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $log) { Write-Output "RESULT=FAIL no gui-agent log under $logDir"; exit 5 }
if ($before -and $log.FullName -eq $before.FullName -and $log.LastWriteTime -le $before.LastWriteTime) {
    Write-Output "RESULT=FAIL the agent did not restart (log unchanged)"; exit 6
}

$line = Select-String -Path $log.FullName -Pattern 'QGAFOCUSRAISE (on|off)' -ErrorAction SilentlyContinue |
        Select-Object -Last 1
if (-not $line) {
    Write-Output "RESULT=FAIL no QGAFOCUSRAISE line - the running agent predates the switch"
    exit 7
}
$got = if ($line.Line -match 'QGAFOCUSRAISE (on|off)') { $Matches[1] } else { '?' }
Write-Output ("LOG=" + $log.Name)
Write-Output ("QGAFOCUSRAISE=" + $got)
if ($got -ne $wantStr) { Write-Output "RESULT=FAIL agent reports '$got', asked for '$wantStr'"; exit 8 }

Write-Output ("AGENT_RUNNING=" + [bool](Get-Process gui-agent -ErrorAction SilentlyContinue))
Write-Output ("RESULT=OK focusraise=$got")
