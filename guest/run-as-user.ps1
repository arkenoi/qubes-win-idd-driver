# Run a command, or a PowerShell script, in the LOGGED-ON USER'S INTERACTIVE SESSION and return
# its output.
#
# WHY THIS EXISTS. qrexec on this testbed runs as NT AUTHORITY\SYSTEM (memory:
# `presession-qrexec-system`), i.e. in SESSION 0 on a non-interactive window station. Two distinct
# consequences, and both have already cost this project measurements:
#
#   1. A process started from `qtest run` has NO window on the user's desktop, so the gui-agent -
#      which enumerates the INPUT desktop - never sees it. A cell needing a real mapped window
#      silently measures nothing.
#   2. Display APIs bound to a window station fail outright there. Measured 2026-08-30:
#      `EnumDisplaySettings(NULL, ENUM_CURRENT_SETTINGS, &dm)` returns 0 from session 0 with a
#      correct 220-byte DEVMODEW, while `Win32_VideoController` (a WMI device property, not a
#      session one) answers fine. That difference is what made the session fault look for months
#      like a DEVMODE marshalling bug in `set-resolution.ps1`.
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
    [switch]$NoWait,
    [int]$TimeoutSec = 120,
    [int]$SettleSec = 4
)
$ErrorActionPreference = 'Continue'
$tn   = 'QwtRunAsUser'
$work = 'C:\ProgramData\Qubes\runasuser'
New-Item -ItemType Directory -Force -Path $work | Out-Null
$outf = Join-Path $work 'out.txt'
Remove-Item $outf -Force -EA SilentlyContinue

if ($Script) {
    if (-not (Test-Path $Script)) { Write-Output "RUNASUSER error=script_not_found path=$Script"; exit 2 }
    # A wrapper is needed because schtasks' /tr cannot carry redirection, and we want the child's
    # exit code too - `$LASTEXITCODE` inside the wrapper, written next to the output.
    $wrap = Join-Path $work 'wrap.ps1'
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
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    $i = Get-ScheduledTaskInfo -TaskName $tn -EA SilentlyContinue
    # 267009 = 0x41301 "task is currently running"
    if ($i -and $i.LastTaskResult -ne 267009) { break }
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
