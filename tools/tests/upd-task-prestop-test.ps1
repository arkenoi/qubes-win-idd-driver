# OUR INSTALLER ENDS OUR OWN TASKS, AND THIS RUNS THE CODE THAT DOES IT.
#
# THE DEFECT, measured on campaign 3 cell win11-reinstall, 2026-10-22. The MSI's Restart Manager
# opened a session at 04:01:35.590 and reported every file-holding application shut down at
# 04:01:36.256. \QubesWindowsUpdateScan's powershell died at 04:01:35.747 - inside that 666 ms
# window - with TaskScheduler 201 result 3221225786 = 0xC000013A STATUS_CONTROL_C_EXIT, which is
# what Restart Manager's shutdown request leaves on a console process. The death reporter correctly
# read that as an unexplained stop and told dom0 "The Windows Update scan task failed", so the USER
# saw a failure our own install had caused. dom0_loud_failures=2 against a max of 0, severity P1.
#
# WHY THE FIX IS A DECLARATION AND NOT AN INFERENCE. Owner: "it is our installer and our receiver.
# we may tell it to die politely in any way we please." A task WE end reports 267014 / 0x41306, and
# guest/qwt-report-death.ps1 already ignores that as "a stop that was asked for, not a death" - so
# the reporter needs NO change. The installer already quiesces our SERVICES before msiexec for this
# exact reason ("the Restart Manager will tear it down in bulk"); the tasks were left out of it.
#
# WHAT THIS ASSERTS, by running the shipped region with schtasks replaced by a recorder:
#   * /end comes BEFORE /disable for every task - /disable does not stop an instance already
#     running, and a running instance is the whole case;
#   * all three update tasks are covered;
#   * an absent task (a clean install has none) is tolerated and reported, not failed;
#   * the detail string the harness grades names what happened to each task;
#   * only the tasks actually disabled are recorded for the Fail path's re-enable.
# Each is a real call recorded by the stub, never a grep of the source.
$ErrorActionPreference = 'Stop'
$pass = 0; $fail = 0
function Check([string]$what, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:pass++; "ok   $what" }
    else { $script:fail++; "FAIL $what"; if ($detail) { "       -> $detail" } }
}

$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$src = Join-Path $repo 'packaging/setup/Install-QwtImproved.ps1'
if (-not (Test-Path -LiteralPath $src)) { "FATAL: $src missing"; exit 2 }

# Extract the marked region from the SHIPPED installer. Nothing is copied into this file: a test
# over a transcribed copy is a test of the transcription.
$all = Get-Content -LiteralPath $src
$a = ($all | Select-String -SimpleMatch 'UPDTASKPRESTOP-BEGIN' | Select-Object -First 1).LineNumber
$b = ($all | Select-String -SimpleMatch 'UPDTASKPRESTOP-END'   | Select-Object -First 1).LineNumber
if (-not $a -or -not $b -or $b -le $a) { "FATAL: could not extract the UPDTASKPRESTOP region ($a..$b)"; exit 2 }
$region = ($all[$a..($b - 2)]) -join "`n"
if ($region -notmatch '/end' -or $region -notmatch '/disable') {
    "FATAL: the extracted region does not carry both /end and /disable"; exit 2
}

# The harness the region runs against. `& schtasks` resolves a FUNCTION before a native command, so
# this intercepts without touching PATH; $global:LASTEXITCODE is what the region reads.
function New-Harness([string[]]$present) {
    $script:calls = New-Object System.Collections.ArrayList
    $script:presentTasks = $present
    function global:schtasks {
        $argv = @($args)
        $tn = ''
        for ($i = 0; $i -lt $argv.Count; $i++) { if ("$($argv[$i])" -eq '/tn') { $tn = "$($argv[$i+1])" } }
        $verb = if ($argv -contains '/end') { 'end' } elseif ($argv -contains '/disable') { 'disable' }
                elseif ($argv -contains '/enable') { 'enable' } else { 'other' }
        [void]$script:calls.Add("$verb`:$tn")
        if ($script:presentTasks -contains $tn) { $global:LASTEXITCODE = 0; "OK" }
        else { $global:LASTEXITCODE = 1; "ERROR: The specified task name `"$tn`" does not exist in the system." }
    }
    $script:Result = @{ detail = @{} }
    function global:Write-Log { param([string]$Message, [string]$Level = 'INFO') [void]$script:calls.Add("log:$Message") }
}

# ---- all three tasks present (an upgrade over a guest that already has them) -------------------
New-Harness @('QubesWindowsUpdateScan', 'QubesWindowsUpdateRun', 'QubesWindowsUpdateDownload')
Invoke-Expression $region
$seq = @($script:calls | Where-Object { $_ -notlike 'log:*' })

Check 'every one of the three update tasks is acted on' `
    (($seq | Where-Object { $_ -like 'end:*' }).Count -eq 3) "ends=$(($seq | Where-Object { $_ -like 'end:*' }) -join ',')"

$endScan = [array]::IndexOf($seq, 'end:QubesWindowsUpdateScan')
$disScan = [array]::IndexOf($seq, 'disable:QubesWindowsUpdateScan')
Check '/end comes BEFORE /disable for the scan task - /disable cannot stop a running instance' `
    ($endScan -ge 0 -and $disScan -ge 0 -and $endScan -lt $disScan) "end@$endScan disable@$disScan"

$ok = $true
foreach ($t in @('QubesWindowsUpdateScan', 'QubesWindowsUpdateRun', 'QubesWindowsUpdateDownload')) {
    $e = [array]::IndexOf($seq, "end:$t"); $d = [array]::IndexOf($seq, "disable:$t")
    if ($e -lt 0 -or $d -lt 0 -or $e -ge $d) { $ok = $false }
}
Check '...and for all three, not just the one that was measured' $ok "seq=$($seq -join ' ')"

Check 'the graded detail says what happened to each task' `
    ("$($script:Result.detail.upd_task_prestop)" -match 'QubesWindowsUpdateScan=ended\+disabled') `
    "detail=$($script:Result.detail.upd_task_prestop)"

Check 'the tasks it disabled are recorded, for the failure path to re-enable' `
    ($script:UpdTasksDisabled.Count -eq 3) "recorded=$($script:UpdTasksDisabled -join ',')"

# ---- a CLEAN install: none of the tasks exists yet ---------------------------------------------
New-Harness @()
Invoke-Expression $region
Check 'a clean install, where no update task exists yet, is tolerated and not a failure' `
    ("$($script:Result.detail.upd_task_prestop)" -match 'QubesWindowsUpdateScan=absent') `
    "detail=$($script:Result.detail.upd_task_prestop)"
Check '...and nothing is recorded for re-enabling, because nothing was disabled' `
    ($script:UpdTasksDisabled.Count -eq 0) "recorded=$($script:UpdTasksDisabled -join ',')"

# ---- SEEN TO FAIL: drop the /end and a running instance survives into msiexec -------------------
# The control removes exactly the /end call. Without it the region still disables - so the shape
# looks healthy - and the instance Restart Manager is about to reap is still running, which is the
# defect this whole region exists for.
$noEnd = ($region -split "`n" | Where-Object { $_ -notmatch '/end' }) -join "`n"
if ($noEnd -eq $region) {
    Check 'SEEN TO FAIL: could not build the no-/end control' $false 'the /end line was not found to remove'
} else {
    New-Harness @('QubesWindowsUpdateScan', 'QubesWindowsUpdateRun', 'QubesWindowsUpdateDownload')
    Invoke-Expression $noEnd
    $seq2 = @($script:calls | Where-Object { $_ -notlike 'log:*' })
    Check 'SEEN TO FAIL: with the /end removed nothing ends the running instance - only /disable runs' `
        ((($seq2 | Where-Object { $_ -like 'end:*' }).Count -eq 0) -and `
         (($seq2 | Where-Object { $_ -like 'disable:*' }).Count -eq 3)) "seq=$($seq2 -join ' ')"
}

# ---- SEEN TO FAIL: the reporter's side of the contract is what makes this work ------------------
# If 0x41306/267014 were NOT already benign in the death reporter, ending the task politely would
# simply trade one notification for another. That is the premise of this whole fix, so it is checked
# against the shipped reporter rather than assumed.
$rep = Join-Path $repo 'guest/qwt-report-death.ps1'
$repText = if (Test-Path -LiteralPath $rep) { (Get-Content -LiteralPath $rep -Raw) } else { '' }
Check 'the premise holds: the shipped reporter already ignores 267014 as a stop that was asked for' `
    ($repText -match '267014' -and $repText -match 'asked for') `
    'guest/qwt-report-death.ps1 must already treat 0x41306 as benign, or ending the task just moves the toast'

''
"RESULT: $pass passed, $fail failed"
if ($fail -ne 0) { exit 1 }
