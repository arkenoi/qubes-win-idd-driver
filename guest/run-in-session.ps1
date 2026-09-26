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
$RIS_MARKER = 'RIS-V8'   # pushed-copy identity, so a stale copy cannot be mistaken for this one
# C:\Users\Public, not C:\ProgramData\Qubes: the task runs AS THE USER, who cannot write there.
# Measured - the task ran and produced nothing, which looked identical to 'never ran'.
#
# UNIQUE PER INVOCATION, and this is not tidiness. A single fixed path cost several runs on
# 2026-09-26: something kept the file open, the -ErrorAction SilentlyContinue delete swallowed the
# failure, every later redirect failed, and the runner returned 0x1 with an empty output for EVERY
# command including whoami. Worse than the lost runs, a taskkill I believed had succeeded had not -
# so a process I thought was gone was still running and misled the diagnosis for several steps.
# Jev: cause = output-file-locked-or-undeletable 0.90, and the shared-path design itself
# instrument_fragile 0.83.
$stamp = [Guid]::NewGuid().ToString('N').Substring(0, 12)
$out     = "C:\Users\Public\qwt-ris-$stamp.out"
$cmdFile = "C:\Users\Public\qwt-ris-$stamp.cmd"
New-Item -ItemType Directory -Force -Path (Split-Path $out) | Out-Null
# Sweep leftovers from earlier invocations, best-effort - they are unique names now, so a locked one
# cannot block this run. Keeps C:\Users\Public from accumulating them.
Get-ChildItem -LiteralPath 'C:\Users\Public' -Filter 'qwt-ris-*' -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddMinutes(-10) } |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }

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
# REPORT WHAT IS THERE, not what is assumed. An empty output section meant two different things
# earlier - the command wrote nothing, and the redirect never produced a file - and the second wore
# the first's clothes for an hour. The length is printed so a zero-byte file is visible as such.
$fi = Get-Item -LiteralPath $out -ErrorAction SilentlyContinue
Write-Output ("RIS-OUTFILE exists={0} bytes={1} path={2}" -f `
    [bool]$fi, $(if ($fi) { $fi.Length } else { -1 }), $out)
if ($fi) {
    Write-Output '--- RIS-OUTPUT ---'
    # NOT -Encoding UTF8. Console tools redirect in the OEM/ANSI codepage, and on this German guest
    # a 24-byte whoami result read back as NOTHING under that switch - the file existed, the bytes
    # were there, and the output section was empty. Reading the raw text and letting the default
    # codepage apply is what actually returns the content.
    [IO.File]::ReadAllText($out)
    Write-Output '--- RIS-END ---'
} else {
    # MISSING DATA FAILS, and it now says WHY rather than leaving the caller to guess. The previous
    # version printed one line for two very different conditions - the command wrote nothing, and the
    # redirect could not be created at all - and the second one masqueraded as the first for an hour.
    Write-Output "RIS-NOOUTPUT: no output file at $out - the task ran (result above) but its redirect
 did not produce a file, so the command's output is UNKNOWN, not empty"
    exit 6
}
# Clean up this invocation's own files ONLY when the command actually produced output. Deleting them
# after a failure destroys the evidence of why, which is how an empty output section stayed
# unexplained through several runs.
if ($fi -and $fi.Length -gt 0) {
    Remove-Item -LiteralPath $out     -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $cmdFile -Force -ErrorAction SilentlyContinue
} else {
    Write-Output "RIS-KEPT: $out and $cmdFile are left in place as evidence"
}
