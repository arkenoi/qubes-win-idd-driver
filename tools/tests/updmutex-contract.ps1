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
$fail = 0
function Check([string]$what, [bool]$ok) {
    if ($ok) { Write-Output "ok   $what" } else { Write-Output "FAIL $what"; $script:fail++ }
}

foreach ($pair in @(@{n='deploy'; t=$deploy}, @{n='pass'; t=$pass})) {
    $n = $pair.n; $t = $pair.t
    # 1. no timed wait anywhere
    # ONLY THE MUTEX's WaitOne. The pass legitimately waits on OS completion events elsewhere (an
    # async handle, a registry-change notification); those are waits ON AN EVENT THAT WILL FIRE,
    # not guesses about another process's progress, and they are none of this contract's business.
    $waits = [regex]::Matches($t, '(?:\$script:Mutex|\$updMutex)\.WaitOne\(\s*([^)\s]+)\s*\)')
    $nonZero = @($waits | Where-Object { $_.Groups[1].Value -ne '0' })
    Check "${n}: the mutex is only ever probed with WaitOne(0) (found $($waits.Count), non-zero $($nonZero.Count))" ($waits.Count -ge 1 -and $nonZero.Count -eq 0)
    # 2. abandoned refuses, and releases first
    $ab = [regex]::Match($t, '(?s)catch \[System\.Threading\.AbandonedMutexException\].{0,900}')
    Check "${n}: abandoned releases the mutex before refusing" ($ab.Success -and $ab.Value -match 'ReleaseMutex')
    Check "${n}: abandoned refuses with QWTUPDMUTEXABANDONED" ($ab.Success -and $ab.Value -match 'QWTUPDMUTEXABANDONED')
    # CODE ONLY - the comments above the fix quote the old behaviour by name, deliberately.
    $code = ($t -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    Check "${n}: no code path treats an abandoned mutex as acquired" ($code -notmatch 'it is ours now' -and $code -notmatch '(?s)AbandonedMutexException\][^}]*\$(?:script:)?[Hh]ave\w*\s*=\s*\$true')
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

if ($fail -gt 0) { Write-Output "--- $fail FAILED"; exit 1 }
Write-Output '--- contract kept'
