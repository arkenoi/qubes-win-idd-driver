# Run a command, or a PowerShell script, in the LOGGED-ON USER'S INTERACTIVE SESSION and return
# its output.
#
# WHY THIS EXISTS - and what it is NOT for.
# qrexec on this testbed runs as NT AUTHORITY\SYSTEM (memory: `presession-qrexec-system`). It is
# tempting to conclude "therefore session 0, therefore no windows and no display APIs". MEASURED
# 2026-08-30 on win10-p46, that conclusion is WRONG:
#
#   via qtest (qrexec):        whoami=nt authority\system  sessionId=1  winsta=WinSta0
#   via schtasks /ru user /it: whoami=win-idd-test\user     sessionId=1  winsta=WinSta0
#
# qrexec lands in the INTERACTIVE session on the interactive window station. So from `qtest run`:
# windows DO map (two notepads started that way were both mapped by the agent, `win=2` in QGAPERF),
# and display APIs DO work - `EnumDisplaySettings("\\.\DISPLAY2", ENUM_CURRENT_SETTINGS)` and
# `ChangeDisplaySettingsEx` both succeed there. An identical probe run through this wrapper and
# through qrexec returned byte-identical output.
#
# I wrote the opposite here earlier the same day - that session-0 blindness was what had made
# `set-resolution.ps1` fail - and committed it before testing it. It was not the cause. The cause
# was a NULL lpszDeviceName on a guest whose desktop is on DISPLAY2 (see set-resolution.ps1).
# Recorded rather than quietly deleted, because a plausible cause written into a file header is
# indistinguishable from a measured one the next time somebody reads it.
#
# WHAT THIS IS ACTUALLY FOR: running something as the USER PRINCIPAL rather than as SYSTEM.
# That difference is real and matters for per-user state - toasts and the Action Center, the Start
# menu, HKCU, the user's own Explorer - none of which SYSTEM owns. It is NOT needed for display
# work, and it is NOT needed to get a window mapped.
#
# `schtasks /ru user /it` is the pattern already used across this repo (guest/fire-toast.ps1:32).
# This wraps it AND recovers stdout/stderr, which the bare pattern throws away - the reason it was
# only ever used fire-and-forget.
#
#   run-as-user.ps1 -Command 'notepad.exe'
#   run-as-user.ps1 -Script C:\path\to\thing.ps1 -ScriptArgs '-List'
#
# Output between USEROUT_BEGIN/USEROUT_END is the child's own output, verbatim.
param(
    [string]$Command,
    [string]$Script,
    [string]$ScriptArgs = '',
    # Base64 (UTF-16LE) of the argument string. USE THIS FOR ANYTHING WITH A SPACE.
    # -ScriptArgs travels bash -> qtest -> cmd.exe -> powershell, and each hop re-splits on
    # whitespace. Measured 2026-08-31: '-DurationSeconds 90 -IntervalSeconds 1' arrived as a
    # fragment and PowerShell reported "Missing an argument for parameter", so the surface sampler
    # never started - and RND-4 then graded INVALID-VACUOUS "the toast never existed" when nothing
    # had been watching. A base64 blob has no spaces and survives every hop intact.
    [string]$ArgsB64 = '',
    [switch]$NoWait,
    [int]$TimeoutSec = 120,
    [int]$SettleSec = 4,
    # A UNIQUE task name per concurrent launch. The task name used to be the constant
    # 'QwtRunAsUser', and this function DELETES the task on entry - so starting a long-running
    # sampler with -NoWait and then launching anything else through this same helper destroyed the
    # sampler. Measured 2026-08-31: RND-4 started surface-watch.ps1, then fired the toast through
    # here, which deleted surface-watch's task; the sampler recorded nothing and the cell graded
    # INVALID-VACUOUS ("the toast never existed") when in fact the DETECTOR had been killed. Pass a
    # distinct -Tag for anything that must survive a subsequent launch.
    [string]$Tag = ''
)
$ErrorActionPreference = 'Continue'
$tn   = if ($Tag) { 'QwtRunAsUser_' + ($Tag -replace '[^A-Za-z0-9_]','') } else { 'QwtRunAsUser' }
$work = 'C:\ProgramData\Qubes\runasuser'
# Per-tag working dir too, or two concurrent launches overwrite each other's output file.
New-Item -ItemType Directory -Force -Path $work | Out-Null
$outf = Join-Path $work ($(if ($Tag) { "out-$Tag.txt" } else { 'out.txt' }))
Remove-Item $outf -Force -EA SilentlyContinue

if ($ArgsB64) {
    $ScriptArgs = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($ArgsB64))
}
if ($Script) {
    if (-not (Test-Path $Script)) { Write-Output "RUNASUSER error=script_not_found path=$Script"; exit 2 }
    # A wrapper is needed because schtasks' /tr cannot carry redirection, and we want the child's
    # exit code too - `$LASTEXITCODE` inside the wrapper, written next to the output.
    $wrap = Join-Path $work ($(if ($Tag) { "wrap-$Tag.ps1" } else { 'wrap.ps1' }))
@"
`$ErrorActionPreference = 'Continue'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File '$Script' $ScriptArgs *>&1 |
    Out-File -FilePath '$outf' -Encoding ASCII
"RUNASUSER_CHILD_EXIT `$LASTEXITCODE" | Out-File -FilePath '$outf' -Encoding ASCII -Append
"@ | Set-Content -Path $wrap -Encoding ASCII
    $tr = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$wrap`""
} elseif ($Command) {
    $tr = $Command
} else {
    Write-Output 'RUNASUSER error=give -Command or -Script'; exit 2
}

# Is anyone actually logged on? Without an interactive session `/it` has nothing to attach to and
# the task reports success while running nothing - a silent no-op, which is the failure mode this
# whole file exists to prevent.
$sess = @(query user 2>&1 | Select-String -Pattern '\s(Active)\s')
if ($sess.Count -eq 0) {
    Write-Output 'RUNASUSER error=no_active_interactive_session (autologon not fired?) - refusing'
    exit 3
}

& schtasks /delete /tn $tn /f *>$null
& schtasks /create /tn $tn /tr $tr /sc once /st 00:00 /ru user /it /f *>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Output "RUNASUSER error=create_failed rc=$LASTEXITCODE"; exit 1 }
& schtasks /run /tn $tn *>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Output "RUNASUSER error=run_failed rc=$LASTEXITCODE"; exit 1 }

if ($NoWait) {
    Start-Sleep -Seconds $SettleSec
    Write-Output 'RUNASUSER launched nowait=true'
    exit 0
}

$deadline = (Get-Date).AddSeconds($TimeoutSec)
# 267009 = 0x41301 "task is currently running"; 267011 = 0x41303 "task has not yet run".
# schtasks /run is ASYNCHRONOUS: the task this script just created holds LastTaskResult=267011
# until the scheduler actually STARTS it, and under load that start latency exceeds the first
# 2s poll. The old loop broke on anything != 267009, so it fired on 267011 while the task was
# still QUEUED, read the not-yet-written output file, and reported "no_output_file" - a silent
# no-op of the whole relay (the A0 P6a consent-revoke EMPTY readback, rig 2026-09-06, which
# cascaded into P6b's 32-minute wait for a reconnect that could never happen). Completion is
# now: the wrapper's RUNASUSER_CHILD_EXIT marker in the output file (authoritative for
# -Script; the wrapper appends it after the child exits), or a LastTaskResult that is neither
# running nor not-yet-run (covers -Command, which writes no marker). A /run that silently
# never starts the task now waits out $TimeoutSec and reports lastresult=267011 - slower than
# the old misread, but loud and true instead of a silent no-op.
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    if ($Script -and (Test-Path $outf) -and
        (Select-String -Path $outf -Pattern 'RUNASUSER_CHILD_EXIT' -Quiet -EA SilentlyContinue)) { break }
    $i = Get-ScheduledTaskInfo -TaskName $tn -EA SilentlyContinue
    if ($i -and $i.LastTaskResult -ne 267009 -and $i.LastTaskResult -ne 267011) { break }
}
$i = Get-ScheduledTaskInfo -TaskName $tn -EA SilentlyContinue
Write-Output ('RUNASUSER lastresult=' + $(if ($i) { $i.LastTaskResult } else { 'unknown' }))
if (Test-Path $outf) {
    Write-Output 'USEROUT_BEGIN'
    Get-Content $outf | ForEach-Object { Write-Output $_ }
    Write-Output 'USEROUT_END'
} else {
    Write-Output 'RUNASUSER error=no_output_file (child produced nothing)'
}
& schtasks /delete /tn $tn /f *>$null
