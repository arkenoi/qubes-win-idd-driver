# sup-qdbtimeout.ps1 - ADR-supervision item 3, which had RUNNER: none.
#
#   A forced WaitForQdb timeout (QrexecAgent) yields System 7023 with error 1460 and 7031 with the
#   restart, and the SCM restart happens.
#
# Run as SYSTEM, DETACHED, because the stimulus takes this guest's own control channel down:
#   powershell -NoProfile -ExecutionPolicy Bypass -File <this> -Out <transcript> [-Control]
#
# HYPOTHESIS: with QubesDB stopped and its SCM recovery disarmed, QrexecAgent's WaitForQdb burns its
#   full QDB_WAIT_TIMEOUT_MS (core-agent/src/qrexec-agent/qrexec-agent.c:104 - (5*60+60)*1000, SIX
#   MINUTES), returns ERROR_TIMEOUT, and SvcMainLoop reports STOPPED carrying 1460; the SCM writes
#   System 7023 naming that error and takes the restart action the installer armed
#   (Install-QwtImproved.ps1:786, restart/5000/restart/15000/restart/60000). REFUTED by: no 7023 in
#   the window; a 7023 carrying a different error; or QrexecAgent never returning to RUNNING once
#   QubesDB is back.
# BASELINE: taken HERE, before the injection - both services' states, QrexecAgent's armed failure
#   actions, and the System-log counts of 7023/7031 for qrexec. The verdict is a DELTA over those
#   counts: the reporter's log and the System log both accumulate across runs, and a cumulative
#   count cannot answer "what did THIS injection produce" (measured on this project 2026-10-24,
#   where one correct report read as 2 because an earlier run's row sat in the same file).
# VARIABLE: QubesDB stopped. Exactly one thing, and -Control runs the whole sequence WITHOUT it.
# INSTRUMENT: this transcript, appended line by line and flushed, so a run that loses the channel
#   still leaves its evidence on disk. Validated both ways: the -Control arm exercises every line of
#   it on a healthy guest (data on a known-good subject), and its 7023 delta MUST be 0 - so a
#   nonzero delta in the control is this instrument failing, not the product.
# BUDGET: ~8 min for the injected arm (6 of them the product's own wait by design). Deadline 11 min.
#   Terminal states, each reported by name rather than waited out: QubesDB back up (the disarm did
#   not hold, so the timeout can never happen), QrexecAgent absent, the transcript's own deadline.
#
# EVERYTHING IS RESTORED IN A finally, because a run that dies mid-window would otherwise leave this
# subject with QubesDB's recovery disarmed and nothing saying so - a silent configuration drift onto
# whatever cell runs next. Both services are AUTO-START, so a reboot is the backstop if even that
# fails.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Out,
    [switch]$Control,
    [int]$DeadlineSec = 660,
    [int]$StallSec = 420
)

$ErrorActionPreference = 'Continue'
$script:started = Get-Date

function T($k, $v) {
    # ONE LINE PER FACT, APPENDED AND FLUSHED. Out-File -Append closes the handle each call, which is
    # what makes a killed run still readable; a buffered writer would lose exactly the window this
    # script exists to observe.
    $line = "L10|$k|$v"
    try { $line | Out-File -LiteralPath $Out -Append -Encoding ASCII } catch { }
    Write-Output $line
}

function Svc-State($name) {
    try {
        $q = (& sc.exe query $name 2>&1 | Out-String)
        if ($LASTEXITCODE -eq 1060) { return 'ABSENT' }
        $m = [regex]::Match($q, 'STATE\s*:\s*\d+\s+(\w+)')
        if ($m.Success) { return $m.Groups[1].Value.ToUpper() }
        return "UNREADABLE(rc=$LASTEXITCODE)"
    } catch { return "ERROR($($_.Exception.Message))" }
}

# The installer's own parse (Install-QwtImproved.ps1), reused rather than re-invented: its regexes
# are what a real `sc qfailure` answers on these guests.
function Failure-Config($name) {
    try {
        $q = (& sc.exe qfailure $name 2>&1 | Out-String)
        if ($LASTEXITCODE -ne 0) { return "unreadable(rc=$LASTEXITCODE)" }
        $reset = ([regex]::Match($q, 'RESET_PERIOD[^:]*:\s*(\d+)')).Groups[1].Value
        $acts = ([regex]::Matches($q, '(RESTART|RUN PROCESS|REBOOT)\s*--\s*Delay\s*=\s*(\d+)') |
                 ForEach-Object { "$($_.Groups[1].Value.ToLower())/$($_.Groups[2].Value)" }) -join '/'
        if (-not $reset) { $reset = '0' }
        return "reset=$reset actions=$(if ($acts) { $acts } else { 'none' })"
    } catch { return "error: $($_.Exception.Message)" }
}

# 7023/7031 FOR QREXEC ONLY, counted since a timestamp. Matching the MESSAGE rather than a display
# name this script would have to hard-code: the SCM writes the service's display name into the text
# and a name asserted from memory is how a check ends up measuring nothing.
function Scm-Events($sinceUtc) {
    $out = @{ '7023' = 0; '7031' = 0; detail = @() }
    try {
        $ev = Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 7023, 7031; StartTime = $sinceUtc } -EA SilentlyContinue
        foreach ($e in $ev) {
            $msg = ''
            try { $msg = $e.Message } catch { }
            if ($msg -notmatch 'qrexec') { continue }
            $out["$($e.Id)"] = $out["$($e.Id)"] + 1
            $out.detail += ("{0} id={1} {2}" -f $e.TimeCreated.ToString('s'), $e.Id, ($msg -replace '\s+', ' ').Trim())
        }
    } catch { $out.detail += "Get-WinEvent failed: $($_.Exception.Message)" }
    return $out
}

$qdbBefore = $null
$restoreNeeded = $false
try {
    T 'arm' $(if ($Control) { 'CONTROL (QubesDB is NOT stopped)' } else { 'INJECT' })
    T 'started' $script:started.ToUniversalTime().ToString('s')

    # ---- baseline, on the same signals the verdict uses -----------------------------------------
    $t0 = (Get-Date).AddSeconds(-5)
    T 'qrexecagent_state_before' (Svc-State 'QrexecAgent')
    T 'qubesdb_state_before'     (Svc-State 'QubesDB')
    T 'qrexecagent_failure_cfg'  (Failure-Config 'QrexecAgent')
    $qdbBefore = Failure-Config 'QubesDB'
    T 'qubesdb_failure_cfg_before' $qdbBefore
    $base = Scm-Events $t0
    T 'scm_7023_base' $base['7023']
    T 'scm_7031_base' $base['7031']

    if ((Svc-State 'QrexecAgent') -eq 'ABSENT' -or (Svc-State 'QubesDB') -eq 'ABSENT') {
        T 'terminal' 'a service this cell drives is ABSENT - nothing to measure'
        T 'verdict' 'TERMINAL'
        return
    }

    # ---- the single variable ---------------------------------------------------------------------
    if (-not $Control) {
        # DISARM FIRST OR THE STIMULUS CANNOT HOLD: QubesDB carries the same restart/5000 actions, so
        # the SCM would put it back five seconds in and WaitForQdb would succeed. '""' is a LITERAL
        # two-quote token - Windows PowerShell 5.1 drops a bare "" when calling a native exe and
        # sc.exe then answers 1639 - which is why the installer's own disarm never worked until
        # 2026-10-07.
        & sc.exe failure QubesDB reset= 0 actions= '""' 2>&1 | Out-Null
        & sc.exe failureflag QubesDB 0 2>&1 | Out-Null
        $restoreNeeded = $true
        # THE VERDICT IS THE READBACK, not the exit code: a command that wrote nothing exits 0 too.
        T 'qubesdb_failure_cfg_disarmed' (Failure-Config 'QubesDB')

        & sc.exe stop QubesDB 2>&1 | Out-Null
        $deadline = (Get-Date).AddSeconds(60)
        while ((Get-Date) -lt $deadline -and (Svc-State 'QubesDB') -ne 'STOPPED') { Start-Sleep -Seconds 2 }
        T 'qubesdb_state_stopped' (Svc-State 'QubesDB')
        if ((Svc-State 'QubesDB') -ne 'STOPPED') {
            T 'terminal' 'QubesDB did not stop, so the timeout cannot be produced'
            T 'verdict' 'TERMINAL'
            return
        }
        # AND IT MUST STAY STOPPED. The disarm is the precondition of the whole cell, asserted on the
        # same signal the product consults (whether qdb_open can connect), not on sc.exe's exit code.
        Start-Sleep -Seconds 20
        T 'qubesdb_state_after_20s' (Svc-State 'QubesDB')
        if ((Svc-State 'QubesDB') -ne 'STOPPED') {
            T 'terminal' 'the SCM restarted QubesDB despite the disarm - the precondition does not hold'
            T 'verdict' 'TERMINAL'
            return
        }
    }

    # ---- restart QrexecAgent into the wait -------------------------------------------------------
    & sc.exe stop QrexecAgent 2>&1 | Out-Null
    $deadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $deadline -and (Svc-State 'QrexecAgent') -ne 'STOPPED') { Start-Sleep -Seconds 2 }
    T 'qrexecagent_state_stopped' (Svc-State 'QrexecAgent')
    $tStart = (Get-Date).AddSeconds(-5)
    & sc.exe start QrexecAgent 2>&1 | Out-Null
    T 'qrexecagent_start_issued' (Get-Date).ToUniversalTime().ToString('s')
    T 'qrexecagent_state_after_start' (Svc-State 'QrexecAgent')

    # ---- THE WAIT, WITH ITS THREE EXITS ----------------------------------------------------------
    # the thing happened (a 7023 naming qrexec appears), a TERMINAL state (QubesDB came back, so the
    # timeout can no longer be produced), or no progress / the deadline. Each one is NAMED in the
    # transcript, because a wait that cannot say which exit it took is a hang with a timer on it.
    $why = ''
    $seen = $null
    $wDeadline = $script:started.AddSeconds($DeadlineSec)
    $lastProgress = Get-Date
    while ($true) {
        $now = Get-Date
        $cur = Scm-Events $tStart
        if ($cur['7023'] -gt 0) { $why = 'the SCM reported 7023'; $seen = $cur; break }
        if (-not $Control -and (Svc-State 'QubesDB') -ne 'STOPPED') {
            $why = 'TERMINAL: QubesDB came back up, so WaitForQdb can no longer time out'; $seen = $cur; break
        }
        if ($Control -and (Svc-State 'QrexecAgent') -eq 'RUNNING' -and $now -gt $script:started.AddSeconds(90)) {
            $why = 'control: QrexecAgent is RUNNING and no 7023 appeared'; $seen = $cur; break
        }
        if ($now -gt $wDeadline) { $why = "the deadline ($DeadlineSec s) expired"; $seen = $cur; break }
        if (($now - $lastProgress).TotalSeconds -gt $StallSec) { $why = "no progress for $StallSec s"; $seen = $cur; break }
        Start-Sleep -Seconds 10
    }
    T 'wait_exit' $why
    T 'waited_s' [int]((Get-Date) - $script:started).TotalSeconds
    T 'scm_7023_window' $seen['7023']
    T 'scm_7031_window' $seen['7031']
    foreach ($d in $seen.detail) { T 'scm_event' $d }
    # 1460 IS THE CLAIM, not merely "an error": ERROR_TIMEOUT is what WaitForQdb returns and what
    # SvcMainLoop puts in dwWin32ExitCode (tools/tests/svc-exitcode-test.c asserts that half
    # offline). A 7023 carrying any other code would mean the service died of something else and
    # this cell measured the wrong failure.
    $has1460 = $false
    foreach ($d in $seen.detail) { if ($d -match '1460|timeout period expired') { $has1460 = $true } }
    T 'scm_7023_names_1460' $has1460
}
finally {
    # ---- restore, always -------------------------------------------------------------------------
    if ($restoreNeeded) {
        & sc.exe start QubesDB 2>&1 | Out-Null
        $deadline = (Get-Date).AddSeconds(120)
        while ((Get-Date) -lt $deadline -and (Svc-State 'QubesDB') -ne 'RUNNING') { Start-Sleep -Seconds 3 }
        T 'qubesdb_state_restored' (Svc-State 'QubesDB')
        # RE-ARM TO EXACTLY WHAT WAS READ FIRST. The installer's arming string is the fallback, not
        # the default: restoring "no actions" because a second read saw the disarmed state is the
        # mistake its GUARD:recovsuspend comment records.
        $m = [regex]::Match([string]$qdbBefore, 'reset=(\d+) actions=(\S+)')
        if ($m.Success -and $m.Groups[2].Value -ne 'none') {
            & sc.exe failure QubesDB reset= $m.Groups[1].Value actions= $m.Groups[2].Value 2>&1 | Out-Null
        } else {
            & sc.exe failure QubesDB reset= 86400 actions= restart/5000/restart/15000/restart/60000 2>&1 | Out-Null
        }
        & sc.exe failureflag QubesDB 1 2>&1 | Out-Null
        T 'qubesdb_failure_cfg_restored' (Failure-Config 'QubesDB')
    }
    # QrexecAgent back, whichever arm ran: the SCM may already have restarted it, and starting a
    # running service is harmless.
    & sc.exe start QrexecAgent 2>&1 | Out-Null
    $deadline = (Get-Date).AddSeconds(180)
    while ((Get-Date) -lt $deadline -and (Svc-State 'QrexecAgent') -ne 'RUNNING') { Start-Sleep -Seconds 3 }
    T 'qrexecagent_state_restored' (Svc-State 'QrexecAgent')
    T 'qubesdb_state_end' (Svc-State 'QubesDB')
    # THE LAST LINE IS THE MARKER THE HARNESS WAITS FOR. Without it a transcript that stops early is
    # indistinguishable from one still being written, and the harness would grade a partial run.
    T 'done' (Get-Date).ToUniversalTime().ToString('s')
}
