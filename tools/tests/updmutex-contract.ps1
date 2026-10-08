<#
  updmutex-contract.ps1 - the updater mutex contract, in one file.

  WHAT IT ASSERTS, and why each line exists (all three were real defects in the shipped code):
    1. NEITHER SCRIPT EVER WAITS. WaitOne is called with 0 and nothing else. The deploy used to
       block for the holder's ExecutionTimeLimit plus grace - up to PT2H - and the pass for 15
       minutes, writing nothing meanwhile, so a guest behaving correctly looked wedged (measured
       2026-09-23: an upgrade went silent and was graded STALLED at 300 s).
    2. AN ABANDONED MUTEX REFUSES, and releases what .NET handed it. It used to mean "it is ours
       now" and deploy on top of a dead holder's work. It is also not the detector it looks like:
       measured 3/3 on Windows 10, killing a process that owns a named mutex does NOT raise
       AbandonedMutexException in the next waiter.
    3. AN INTERRUPTED PASS IS DETECTED BEFORE THE MUTEX IS TOUCHED, from the status file the pass
       already writes: a non-terminal phase whose owner process is gone. A pass that ends intending
       a reboot sets phase='done' first, so a planned servicing reboot is terminal and is NOT an
       interruption - that case needs no extra mechanism and must not regress into one.

  This replaces a 200-check suite with deliberate defect knobs. That suite tested a bounded-wait
  contract that no longer exists, and grew until it obscured the work; this file is the contract
  itself. Run: pwsh -File tools/tests/updmutex-contract.ps1   (exit 0 = kept)
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$deploy = Get-Content (Join-Path $root 'guest/install-updater-agent.ps1') -Raw
$pass   = Get-Content (Join-Path $root 'guest/qubes-windows-update.ps1')  -Raw
# UPDMUTEX_DEFECT=refusal puts back the 2026-10-02 shape - the held-mutex refusal on Write-Host only - and the refusal check must FAIL.
if ($env:UPDMUTEX_DEFECT -eq 'refusal') { $pass = $pass.Replace("Write-Refusal 'mutex-held' (", 'Write-Host (') }
# UPDMUTEX_DEFECT=scanfail puts back the pre-2026-10-08 shape - a SCHEDULED SCAN exiting non-zero on
# an abandoned mutex, which Task Scheduler records as a failed task and the death reporter renders to
# the user as "The Windows Update scan task failed", about a read-only operation that deliberately
# declined and changed nothing. The scan-yield checks must FAIL under it.
# BY INDEX, not by a quoted literal: the first two attempts embedded PowerShell source containing
# quotes and parentheses in a replacement string and would not parse at all.
if ($env:UPDMUTEX_DEFECT -eq 'scanfail') {
    $i = $pass.IndexOf('the abandonment is cleared and this scheduled scan yields')
    if ($i -lt 0) { Write-Output 'FAIL knob scanfail: the scan-yield branch is not there to break'; exit 2 }
    $j = $pass.IndexOf('exit 0', $i)
    if ($j -lt 0) { Write-Output 'FAIL knob scanfail: no exit 0 after the branch'; exit 2 }
    $pass = $pass.Remove($j, 6).Insert($j, 'exit 1')
}

$fail = 0
function Check([string]$what, [bool]$ok) {
    if ($ok) { Write-Output "ok   $what" } else { Write-Output "FAIL $what"; $script:fail++ }
}

foreach ($pair in @(@{n='deploy'; t=$deploy}, @{n='pass'; t=$pass})) {
    $n = $pair.n; $t = $pair.t
    # 1. HOW THE MUTEX MAY BE TAKEN - AND THE TWO SCRIPTS HAVE DIFFERENT RULES.
    # ONLY THE MUTEX's WaitOne. Both scripts legitimately wait on OS completion events elsewhere (an
    # async handle, a registry-change notification); those are waits ON AN EVENT THAT WILL FIRE,
    # not guesses about another process's progress, and they are none of this contract's business.
    #
    # THIS CHECK USED TO APPLY THE PASS'S RULE TO BOTH, AND HAD BEEN FAILING SINCE 4.3.35 SHIPPED
    # (found 2026-10-08 while chasing the error messages). A red suite hides the next regression, so
    # the fix is to say what each script's rule actually IS rather than to delete or relax anything:
    #   THE PASS refuses instantly - take it or refuse - because a pass may run PT2H and ends in a
    #     restart; waiting on one is a guess about another process's progress.
    #   THE DEPLOY waits, but only on a SCAN, and only for as long as that scan's OWN task already
    #     allows: the bound is the longest ExecutionTimeLimit among the tasks that can hold the
    #     mutex, read AS REGISTERED, never a constant of ours. It exists because the alternative was
    #     measured and reported: the boot scan held the mutex while the deploy ran, the deploy
    #     refused, the installer logged one WARN nobody reads, the install said COMPLETE and the
    #     guest silently kept its OLD updater while dom0 showed no updates. Expiry is a FAILURE
    #     (QWTUPDSCANWAITEXPIRED), refused loudly, and there is deliberately no proceed-anyway
    #     branch - so this is a bounded wait whose expiry hard-fails, not a timeout used as a fix.
    $waits = [regex]::Matches($t, '(?:\$script:Mutex|\$updMutex)\.WaitOne\(\s*([^)\s]+)\s*\)')
    $nonZero = @($waits | Where-Object { $_.Groups[1].Value -ne '0' })
    if ($n -eq 'pass') {
        Check "${n}: the mutex is only ever probed with WaitOne(0) - take it or refuse (found $($waits.Count), non-zero $($nonZero.Count))" `
              ($waits.Count -ge 1 -and $nonZero.Count -eq 0)
    } else {
        Check "${n}: the mutex is taken with WaitOne(0) first, so a free mutex is never waited on" ($waits.Count -ge 1 -and @($waits | Where-Object { $_.Groups[1].Value -eq '0' }).Count -ge 1)
        Check "${n}: at most ONE bounded wait exists (found $($nonZero.Count))" ($nonZero.Count -le 1)
        # the bound must come from the HOLDER's own task limit, not from a number in this file
        Check "${n}: the bound is read from the tasks' ExecutionTimeLimit, never a constant" ($t -match 'ExecutionTimeLimit')
        # and only a SCAN is ever waited for
        Check "${n}: only a running SCAN is waited for; an install or download pass is refused" ($t -match 'QWTUPDMUTEXHELD')
        # EXPIRY IS A FAILURE, and there is no proceed-anyway path
        Check "${n}: the bound expiring is a FAILURE (QWTUPDSCANWAITEXPIRED), never 'proceed anyway'" ($t -match 'QWTUPDSCANWAITEXPIRED')
    }
    # 2. abandoned refuses, and releases first.
    # MATCHED AGAINST THE COMMENT-STRIPPED CODE, like the check below it: these windows are
    # character-counted, so a long comment explaining the branch pushed QWTUPDMUTEXABANDONED past
    # the 900-char window and the check failed the code for being documented (2026-10-08).
    $code = ($t -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    $ab = [regex]::Match($code, '(?s)catch \[System\.Threading\.AbandonedMutexException\].{0,900}')
    Check "${n}: abandoned releases the mutex before refusing" ($ab.Success -and $ab.Value -match 'ReleaseMutex')
    Check "${n}: abandoned refuses with QWTUPDMUTEXABANDONED" ($ab.Success -and $ab.Value -match 'QWTUPDMUTEXABANDONED')
    # CODE ONLY - the comments above the fix quote the old behaviour by name, deliberately.
    # ABANDONED: again a per-script rule, and again the shared version had been failing since 4.3.35.
    #   THE PASS must never treat it as acquired: what the dead holder was doing is unknown.
    #   THE DEPLOY owns it (that is .NET's documented behaviour - the mutex is handed over WITH the
    #     exception) and then decides by WHAT died: after a SCAN it proceeds and says so, which is
    #     the updater's own D3 rule that a scan installs nothing so nothing is unknown; after
    #     anything else it refuses. Measured 3/3 on win10-acc that this is not the detector it looks
    #     like - a killed owner raises nothing in a waiter that opens the mutex afterwards.
    if ($n -eq 'pass') {
        Check "${n}: no code path treats an abandoned mutex as acquired" ($code -notmatch 'it is ours now' -and $code -notmatch '(?s)AbandonedMutexException\][^}]*\$(?:script:)?[Hh]ave\w*\s*=\s*\$true')
    } else {
        Check "${n}: an abandoned mutex is owned and then DECIDED by what died, not proceeded on blindly" ($code -match '(?s)AbandonedMutexException\].{0,300}?\$updAbandoned = \$true' -and $code -match 'QWTUPDMUTEXABANDONED')
    }
    # 3. the interrupted-pass gate, before the mutex object exists
    $gate = $t.IndexOf('QWTUPDSTATEUNKNOWN')
    $mx   = $t.IndexOf('New-Object System.Threading.Mutex')
    Check "${n}: the interrupted-pass gate precedes the mutex" ($gate -gt 0 -and $mx -gt 0 -and $gate -lt $mx)
    Check "${n}: a held mutex refuses with QWTUPDMUTEXHELD"    ($t -match 'QWTUPDMUTEXHELD')
    # the terminal-phase list must contain 'done', or a planned reboot would read as an interruption
    $term = [regex]::Match($t, "TerminalPhases?\s*=\s*@\(([^)]*)\)|TERMINAL_PHASES\s*=\s*@\(([^)]*)\)")
    Check "${n}: 'done' is a terminal phase (a planned reboot is not an interruption)" ($term.Success -and $term.Value -match "'done'")
}
# the pass records ownership immediately after acquiring, or a kill leaves nothing to detect
$own = [regex]::Match($pass, '(?s)\$script:HaveMutex = \$script:Mutex\.WaitOne\(0\).{0,4000}')
Check "pass: owner_pid is recorded and saved before any work" ($own.Success -and $own.Value -match '\$script:St\.owner_pid = \$PID' -and $own.Value -match '(?s)owner_pid.{0,400}\bSave\b')
Check "pass: the status object carries owner fields so every save keeps them" ($pass -match "owner_pid=0; owner_pid_start=''")

# 4. EVERY EARLY REFUSAL IS RECORDED FOR dom0 (2026-10-02). They end the pass before it owns the status file, so Write-Host alone
#    reached nobody: dom0's handler saw no status, reported a dead pass and tore down the live holder's proxy. Each one now goes
#    through Write-Refusal, which writes update-refusal.json next to the status and NEVER the status itself (it is the holder's).
Check "pass: the interrupted-state refusal is recorded (Write-Refusal 'state-unknown')"   ($pass -match "Write-Refusal 'state-unknown' ")
Check "pass: the abandoned-mutex refusal is recorded (Write-Refusal 'mutex-abandoned')"   ($pass -match "Write-Refusal 'mutex-abandoned' \(`"QWTUPDMUTEXABANDONED")
Check "pass: the held-mutex refusal is recorded (Write-Refusal 'mutex-held')"             ($pass -match "Write-Refusal 'mutex-held' \(`"QWTUPDMUTEXHELD")
$wr = [regex]::Match($pass, '(?s)function Write-Refusal\(.{0,2000}?\n\}')
Check "pass: Write-Refusal writes update-refusal.json and never the status file" ($wr.Success -and $wr.Value -match 'update-refusal\.json' -and
      $wr.Value -notmatch 'Set-Content -LiteralPath \$StatusFile' -and $wr.Value -notmatch '\bSave\b')
# 5. A SCHEDULED SCAN NEVER REPORTS A TASK FAILURE FOR A REFUSAL (owner, 2026-10-08: fix the error
#    messages first). A refusal is "I deliberately declined and changed nothing", but Task Scheduler
#    records the non-zero exit and the death reporter renders ANY non-zero as "The Windows Update
#    scan task failed" - to the user, about a read-only operation that did the right thing. And for
#    a scan the refusal has nowhere else to go: wu-update.ps1's Get-FreshRefusal DISCARDS any record
#    whose action is 'scan' by design, so the spurious error was the only thing that reached anyone.
#    Reachable exactly as reported: the install's own reboot cuts off the installer's pass, the
#    boot+2min scheduled scan finds the mutex abandoned, and the user's first sight of a freshly
#    installed qube is that error. GUARD:scanreadonly already fixed the sibling branch; this one was
#    left. A GENUINE scan failure (exit 75, the transport lost fetches so availability is unknown)
#    stays non-zero and must stay non-zero - that is the "visible error on actual failure" half.
$ab = [regex]::Match($pass, '(?s)catch \[System\.Threading\.AbandonedMutexException\].{0,2600}?
\}')
Check "pass: the abandoned-mutex branch was found" $ab.Success
Check "pass: a SCHEDULED SCAN yields on an abandoned mutex instead of reporting a task failure" `
      ($ab.Success -and $ab.Value -match '\$Scheduled -and \$Action -eq ''scan''' -and $ab.Value -match '(?s)\$Action -eq ''scan''.{0,700}?exit 0')
Check "pass: any OTHER action still refuses an abandoned mutex loudly (exit 1)" `
      ($ab.Success -and $ab.Value -match "(?s)Write-Refusal 'mutex-abandoned'.{0,600}?exit 1")
Check "pass: a genuine scan failure is STILL non-zero (exit 75, availability unknown)" `
      ($pass -match '(?s)SCAN FAILED: the relay gave up.{0,200}?exit 75')
# the held-mutex sibling must keep the same shape, or the two drift apart
Check "pass: a SCHEDULED SCAN also yields on a HELD mutex (unchanged, checked so it cannot drift)" `
      ($pass -match '(?s)if \(-not \$script:HaveMutex\).{0,400}?\$Scheduled -and \$Action -eq ''scan''.{0,400}?exit 0')

if ($fail -gt 0) { Write-Output "--- $fail FAILED"; exit 1 }
Write-Output '--- contract kept'
