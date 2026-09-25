# run-in-session.ps1 - run a command in the guest's INTERACTIVE session, from a SYSTEM qrexec call.
#
# WHY. qubes.VMShell runs as SYSTEM on these guests (%USERNAME% reports <HOST>$), and SYSTEM lives
# in session 0, which has its own window station. Measured 2026-09-25: every app launched through
# qtest opened in session 0 where nobody can see it, and any window enumeration run that way
# enumerates session 0's desktop rather than the user's. A whole window-detection survey was built
# on top of that access path before the problem was noticed.
#
# It reports what it did rather than guessing: NOSESSION when no interactive user is logged on,
# and it always removes the task it creates, including on failure.
param([Parameter(Mandatory)][string]$Command, [int]$TimeoutSec = 90)

# NOT 'Stop'. schtasks writes warnings to stderr ("WARNUNG: Aufgabe wird evtl. nicht ausgefuehrt,
# da /ST vor der aktuellen Zeit"), and under 'Stop' PS 5.1 turns native stderr into a TERMINATING
# error - so a harmless warning killed this script before the task was created. The installer in
# this repo documents the same trap. Native calls here are judged ONLY by $LASTEXITCODE.
$ErrorActionPreference = 'Continue'
$tn  = 'QwtRunInSession'
$RIS_MARKER = 'RIS-V5'   # pushed-copy identity, so a stale copy cannot be mistaken for this one
# C:\Users\Public, not C:\ProgramData\Qubes: the task runs AS THE USER, who cannot write
# there. Measured - the task ran and produced nothing, which looked identical to 'never ran'.
$out = 'C:\Users\Public\qwt-run-in-session.out'
New-Item -ItemType Directory -Force -Path (Split-Path $out) | Out-Null
Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue

# The interactive user is whoever owns explorer.exe. Not `query user`, whose output is localised -
# this guest is German and parsing its columns would be a locale trap.
$ex = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Select-Object -First 1
if (-not $ex) { Write-Output 'RIS-NOSESSION: no explorer.exe - no interactive session to run in'; exit 3 }
$owner = Invoke-CimMethod -InputObject $ex -MethodName GetOwner
$user  = "$($owner.Domain)\$($owner.User)"
Write-Output "RIS-VER=$RIS_MARKER"
Write-Output "RIS-USER=$user"

# The command goes into a .cmd FILE rather than into /tr. schtasks' own parser treats &, |, > and
# quotes as its own syntax - measured: a command containing `&` died with
# "FEHLER: Ungueltige(s) Option/Argument - "&"" before the task was ever created. A file has no
# such parsing, and it also keeps the redirect out of schtasks' hands.
$cmdFile = 'C:\Users\Public\qwt-run-in-session.cmd'
Set-Content -LiteralPath $cmdFile -Encoding ASCII -Value @(
    '@echo off',
    "$Command > `"$out`" 2>&1"
)
$global:LASTEXITCODE = 0
$mk = (& schtasks.exe /create /tn $tn /tr $cmdFile /sc once /st 23:59 /ru $user /it /f 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0) { Write-Output "RIS-FAIL: schtasks /create rc=$LASTEXITCODE :: $mk"; exit 4 }
try {
    $global:LASTEXITCODE = 0
    $rr = (& schtasks.exe /run /tn $tn 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { Write-Output "RIS-FAIL: schtasks /run rc=$LASTEXITCODE :: $rr"; exit 5 }
    # Wait on the task's NUMERIC state via the Schedule.Service COM object. Do NOT parse
    # schtasks' text: it is localised, and on this German guest the "still running" string never
    # matched, so the loop fell straight through, deleted the task mid-flight, and reported
    # 0x41301 SCHED_S_TASK_RUNNING as if it were a result. State 4 = TASK_STATE_RUNNING.
    $svc = New-Object -ComObject Schedule.Service; $svc.Connect()
    $tk  = $svc.GetFolder('\').GetTask($tn)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ($tk.State -eq 4 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
    if ($tk.State -eq 4) { Write-Output "RIS-TIMEOUT: still running after $TimeoutSec s" }
    Write-Output ("RIS-TASKRESULT=0x{0:x}" -f $tk.LastTaskResult)
} finally {
    & schtasks.exe /delete /tn $tn /f 2>&1 | Out-Null
}
if (Test-Path -LiteralPath $out) {
    Write-Output '--- RIS-OUTPUT ---'
    Get-Content -LiteralPath $out -Encoding UTF8
    Write-Output '--- RIS-END ---'
} else {
    Write-Output 'RIS-NOOUTPUT: the task produced no output file'   # missing data fails, never reads as success
    exit 6
}
