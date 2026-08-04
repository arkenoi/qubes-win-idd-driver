# One A/B measurement for agent 6b5b298 (never capture while the secure desktop is up).
#
# The fix has NO log line on its idle path - CaptureThread just does `Sleep(200); continue;`
# - so the observable has to be the ABSENCE of per-window capture work during a secure
# desktop episode, against its PRESENCE on the control. Metric: per-window capture damage
# events (MSG_SHMIMAGE) logged while the session is locked.
#
# Requires PerWindowCapture=1: the whole of wincapture.cpp is inert otherwise.
#
# Locking needs to happen in the INTERACTIVE session - this script runs as SYSTEM via
# qrexec, where LockWorkStation is a no-op - so it goes through a scheduled task registered
# to run as the logged-on user with /it (interactive only).
param([string]$Which = 'new', [string]$ExpectHash = '', [int]$LockSeconds = 25)

$ErrorActionPreference = 'Stop'
$bin    = 'C:\Program Files\Qubes Tools\bin'
$logdir = 'C:\Program Files\Qubes Tools\log'

$h = (Get-FileHash (Join-Path $bin 'gui-agent.exe')).Hash.Substring(0,16)
if ($ExpectHash -and $h -ne $ExpectHash) {
  Write-Output "RESULT which=$Which status=FAIL reason=wrong_binary installed=$h expect=$ExpectHash"; exit 1
}
$pwc = (Get-ItemProperty 'HKLM:\Software\Invisible Things Lab\Qubes Tools').PerWindowCapture
if ($pwc -ne 1) { Write-Output "RESULT which=$Which status=FAIL reason=per_window_capture_off"; exit 1 }

$log = Get-ChildItem $logdir -Filter 'gui-agent-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $log) { Write-Output "RESULT which=$Which status=FAIL reason=no_log"; exit 1 }
$before = (Get-Content $log.FullName | Measure-Object -Line).Lines

# is anyone actually logged on interactively? without a session there is no Default desktop
# to leave, so the whole experiment is vacuous
$sessionUser = (Get-CimInstance Win32_ComputerSystem).UserName
if (-not $sessionUser) { Write-Output "RESULT which=$Which status=FAIL reason=no_interactive_session"; exit 1 }

schtasks /delete /tn QubesLockProbe /f *> $null
$null = schtasks /create /tn QubesLockProbe /tr 'rundll32.exe user32.dll,LockWorkStation' `
        /sc once /st 23:59 /ru $sessionUser /it /f 2>&1
if ($LASTEXITCODE -ne 0) { Write-Output "RESULT which=$Which status=FAIL reason=schtasks_create_failed"; exit 1 }

$null = schtasks /run /tn QubesLockProbe 2>&1
Start-Sleep -Seconds $LockSeconds

# How much PER-WINDOW capture work was logged while locked?
#
# CAREFUL - do not count MSG_SHMIMAGE. 6b5b298 only stops the per-window capture thread in
# wincapture.cpp; the DDA frame loop keeps running and keeps emitting MSG_SHMIMAGE for the
# screen window on BOTH sides, so that count cannot discriminate and would produce yet
# another instrument that cannot fail.
#
# The per-window path is PwOnDamage -> SendWindowDamageEvent(hwnd,...), logged as
# "SendWindowDamageEvent: 0x<hwnd>: ...". Restrict to the HWNDs that actually hold a
# per-window buffer (PwAttachWindow announced them), which excludes the screen window and
# the non-capture SendWindowDamageEvent call sites in main.c (resize/initial/synth patch).
$after  = Get-Content $log.FullName
$window = $after[$before..($after.Count-1)]

$pwHwnds = @()
foreach ($l in $after) {
  if ($l -match 'PwAttachWindow: (0x[0-9a-f]+):') { $pwHwnds += $matches[1] }
}
$pwHwnds = @($pwHwnds | Sort-Object -Unique)

$pwDamage = 0
foreach ($l in $window) {
  if ($l -match 'SendWindowDamageEvent: (0x[0-9a-f]+):' -and $pwHwnds -contains $matches[1]) { $pwDamage++ }
}
$shm    = @($window | Select-String -Pattern 'MSG_SHMIMAGE').Count   # context only, NOT the metric
$attach = @($window | Select-String -Pattern 'PwAttachWindow').Count

schtasks /delete /tn QubesLockProbe /f *> $null

Write-Output ("LOCKED_FOR=" + $LockSeconds + "s LOGLINES_ADDED=" + ($after.Count - $before))
Write-Output ("PW_DAMAGE_WHILE_LOCKED=" + $pwDamage + "  (metric; expect >0 on control, 0 on fix)")
Write-Output ("context: shmimage=" + $shm + " pwattach=" + $attach + " pw_channels=" + $pwHwnds.Count)
Write-Output ("LOG=" + $log.Name)
Write-Output ("RESULT which=$Which status=OK installed=$h pw_damage_while_locked=" + $pwDamage)
Write-Output "NOTE: the guest is now LOCKED. Recover with a reboot (autologon), not a password."
