# sup-qdbtimeout.ps1 - ADR-supervision item 3, which had RUNNER: none.
#
#   A forced WaitForQdb timeout (QrexecAgent) yields System 7023 with error 1460 and 7031 with the
#   restart, and the SCM restart happens.
#
# Run as SYSTEM, DETACHED, because the stimulus takes this guest's own control channel down:
#   powershell -NoProfile -ExecutionPolicy Bypass -File <this> -Out <transcript> [-Control]
#
# THE STIMULUS IS A SUSPEND, NOT A STOP, AND A MEASUREMENT FORCED THAT. The first cut stopped the
# QdbDaemon service. It cannot work: packaging/setup/Install-QwtImproved.ps1:815-819 quotes
# `sc qc QrexecAgent` showing `DEPENDENCIES : QdbDaemon`, so (a) `sc stop QdbDaemon` is REFUSED
# while QrexecAgent runs - measured on win11r-sup 1024-1731, `qubesdb_state_stopped|RUNNING` with
# the disarm provably applied (`reset=0 actions=none`) - and (b) even with QrexecAgent stopped
# first, the SCM refuses to START it while its dependency is stopped, so WaitForQdb would never
# execute and no 1460 could ever be produced. Jev on the replacement:
# suspend-the-daemon-process 1.00, against stop-with-dependents-first 0.00 and block-the-pipe 0.00.
#
# AND THE DEPENDENTS COME DOWN FIRST, because the chain has a service ABOVE the subject too.
# Install-QwtImproved.ps1:938 states it: "QrexecAgent declares ServiceDependency QdbDaemon,
# QubesGuiWatchdog declares QrexecAgent. QdbDaemon itself depends on xenagent". MEASURED on
# win11r-sup 1024-1804, with sc.exe's own words kept this time:
#     qrexecagent_stop_said|[SC] ControlService FAILED 1051: A stop control has been sent to a
#                            service that other running services are dependent on.
#     qrexecagent_start_said|[SC] StartService FAILED 1056: An instance of the service is already running.
# So `sc stop QrexecAgent` is refused by QubesGuiWatchdog exactly as `sc stop QdbDaemon` is refused
# by QrexecAgent, the service never restarted, and no WaitForQdb ran. Stop-Service -Force takes the
# dependents down with it, which is the only way to stop a service in this chain; they are started
# again on the way out.
#
# SUSPENDING THE DAEMON'S PROCESS leaves the service RUNNING from the SCM's view, so the dependency
# is satisfied and QrexecAgent is allowed to start, while no qdb_open can be answered. The primitive
# is the one L3 already uses on the broker: NtSuspendProcess/NtResumeProcess on a HANDLE from the
# pid, never a name. No SCM configuration is touched at all now - no recovery disarm, nothing to
# restore - which removes the configuration-drift hazard the first cut carried.
#
# AND IT IS NOT THE PRODUCTION CONDITION, which this cell says out loud rather than implying. Jev:
# matches_production 0.13. In the field the daemon is RUNNING and mid-sync - it may answer the pipe
# and fail later (guest/qubes-windows-update.ps1:2430 calls it "a service-startup ORDERING race");
# suspended, it does not answer the connect at all. Both leave qdb_open failing for the whole
# window, which is exactly what WaitForQdb measures and what the SCM then records, so this drives
# the same CODE PATH - but it is a different internal state and no claim is made that it is the same
# failure.
#
# HYPOTHESIS: with the QdbDaemon process SUSPENDED, QrexecAgent's WaitForQdb burns its
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
# VARIABLE: the QdbDaemon process suspended. Exactly one thing, and -Control runs the whole
#   sequence WITHOUT it.
# INSTRUMENT: this transcript, appended line by line and flushed, so a run that loses the channel
#   still leaves its evidence on disk. Validated both ways: the -Control arm exercises every line of
#   it on a healthy guest (data on a known-good subject), and its 7023 delta MUST be 0 - so a
#   nonzero delta in the control is this instrument failing, not the product.
# BUDGET: ~8 min for the injected arm (6 of them the product's own wait by design). Deadline 11 min.
#   Terminal states, each reported by name rather than waited out: the daemon not suspendable or no
#   longer suspended, QrexecAgent absent, the transcript's own deadline.
# IF THIS SCRIPT IS HARD-KILLED MID-WINDOW the daemon stays suspended and the guest's control
#   channel stays down until a reboot recreates the process - which the cell does immediately after
#   itself. The resume is in a finally for every other path.
#
# THE RESUME IS IN A finally, because a run that dies mid-window would otherwise leave this guest
# with its qubesdb suspended and therefore without a control channel. Nothing else needs restoring:
# this stimulus touches no SCM configuration at all. The process is recreated by a reboot, which the
# cell performs immediately after itself, so that is the backstop.
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

# THE SCM KEY NAME, RESOLVED FROM THE DISPLAY NAME THE INSTALLER OWNS. `sc.exe query` takes the KEY
# name, and 'QubesDB' is not it: MEASURED on win11r-sup 2026-10-24, where this cell reported
# `QubesDB=ABSENT QrexecAgent=RUNNING` and went INVALID - correctly, since its precondition was not
# met, but it measured nothing. Install-QwtImproved.ps1:1363 lists our services by DISPLAY name
# ('QubesDB daemon', 'Qubes RPC agent', 'Qubes GUI agent watchdog', 'Qubes PV NIC address applier'),
# so the display name is the stable handle and the key name is derived from it here.
# WHICH NAME WAS USED IS REPORTED, so the next ABSENT is diagnosable instead of being a dead end.
function Resolve-SvcName($display, $fallback) {
    foreach ($d in @($display, "*$display*", "*QubesDB*")) {
        $s = @(Get-Service -DisplayName $d -EA SilentlyContinue)
        if ($s.Count -ge 1) { return $s[0].Name }
    }
    $s = Get-Service -Name $fallback -EA SilentlyContinue
    if ($s) { return $s.Name }
    return $fallback
}
$QDB = Resolve-SvcName 'QubesDB daemon' 'QubesDB'
$QRX = 'QrexecAgent'

# THE SAME PRIMITIVE L3 USES ON THE BROKER: the debug API on a HANDLE from the pid, never a name.
Add-Type -Namespace W -Name T -MemberDefinition '
[DllImport("ntdll.dll")] public static extern int NtSuspendProcess(IntPtr h);
[DllImport("ntdll.dll")] public static extern int NtResumeProcess(IntPtr h);' -EA SilentlyContinue

function Svc-Pid($name) {
    # The SERVICE's own process id, from the SCM rather than from a name match: two processes can
    # share an image and only one of them is the service.
    try {
        $c = Get-CimInstance Win32_Service -Filter ("Name='" + $name + "'") -EA SilentlyContinue
        if ($c -and $c.ProcessId -gt 0) { return [int]$c.ProcessId }
    } catch { }
    return 0
}

$qdbBefore = $null
$restoreNeeded = $false
try {
    T 'qubesdb_service_name' $QDB
    T 'arm' $(if ($Control) { 'CONTROL (QubesDB is NOT stopped)' } else { 'INJECT' })
    T 'started' $script:started.ToUniversalTime().ToString('s')

    # ---- baseline, on the same signals the verdict uses -----------------------------------------
    $t0 = (Get-Date).AddSeconds(-5)
    T 'qrexecagent_state_before' (Svc-State $QRX)
    T 'qubesdb_state_before'     (Svc-State $QDB)
    T 'qrexecagent_failure_cfg'  (Failure-Config $QRX)
    $qdbBefore = Failure-Config $QDB
    T 'qubesdb_failure_cfg_before' $qdbBefore
    $base = Scm-Events $t0
    T 'scm_7023_base' $base['7023']
    T 'scm_7031_base' $base['7031']

    if ((Svc-State $QRX) -eq 'ABSENT' -or (Svc-State $QDB) -eq 'ABSENT') {
        T 'terminal' 'a service this cell drives is ABSENT - nothing to measure'
        T 'verdict' 'TERMINAL'
        return
    }

    # ---- stop the subject (and whatever depends on it) BEFORE suspending -------------------------
    # ORDER MATTERS TWICE: a stop is refused while a dependent runs, and stopping QrexecAgent AFTER
    # the daemon is suspended could hang in its own shutdown path, which talks to qubesdb.
    $deps = @()
    try { $deps = @((Get-Service -Name $QRX -EA SilentlyContinue).DependentServices | ForEach-Object { $_.Name }) } catch { }
    T 'qrexecagent_dependents' (($deps -join ',') + '')
    T 'qrexecagent_stop_said' ((Stop-Service -Name $QRX -Force -PassThru -EA SilentlyContinue | ForEach-Object { $_.Name + '=' + $_.Status }) -join ' ')
    $deadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $deadline -and (Svc-State $QRX) -ne 'STOPPED') { Start-Sleep -Seconds 2 }
    T 'qrexecagent_state_stopped' (Svc-State $QRX)
    if ((Svc-State $QRX) -ne 'STOPPED') {
        T 'terminal' "$QRX did not stop even with its dependents forced down, so it cannot be restarted into the wait"
        T 'verdict' 'TERMINAL'
        return
    }

    # ---- the single variable ---------------------------------------------------------------------
    $qdbProc = $null
    if (-not $Control) {
        $qpid = Svc-Pid $QDB
        T 'qubesdb_pid' $qpid
        if (-not $qpid) {
            T 'terminal' "the SCM reports no process id for $QDB, so it cannot be suspended"
            T 'verdict' 'TERMINAL'
            return
        }
        $qdbProc = Get-Process -Id $qpid -EA SilentlyContinue
        if (-not $qdbProc) {
            T 'terminal' "pid $qpid is not running, so there is nothing to suspend"
            T 'verdict' 'TERMINAL'
            return
        }
        T 'qubesdb_process' $qdbProc.ProcessName
        [void][W.T]::NtSuspendProcess($qdbProc.Handle)
        $restoreNeeded = $true
        T 'qubesdb_suspended' (Get-Date -Format 'HH:mm:ss.fff')
        T 'qubesdb_state_while_suspended' (Svc-State $QDB)
        if ((Svc-State $QDB) -ne 'RUNNING') {
            T 'terminal' "the service left RUNNING while suspended, so the dependency is no longer satisfied"
            T 'verdict' 'TERMINAL'
            return
        }
    }

    # ---- start QrexecAgent into the wait ---------------------------------------------------------
    $tStart = (Get-Date).AddSeconds(-5)
    T 'qrexecagent_start_said' ((& sc.exe start $QRX 2>&1 | Out-String) -replace '\s+', ' ').Trim()
    T 'qrexecagent_start_issued' (Get-Date).ToUniversalTime().ToString('s')
    T 'qrexecagent_state_after_start' (Svc-State $QRX)

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
        if (-not $Control -and $qdbProc -and $qdbProc.HasExited) {
            $why = 'TERMINAL: the qubesdb process exited, so the suspend no longer holds'; $seen = $cur; break
        }
        if ($Control -and (Svc-State $QRX) -eq 'RUNNING' -and $now -gt $script:started.AddSeconds(90)) {
            $why = 'control: QrexecAgent is RUNNING and no 7023 appeared'; $seen = $cur; break
        }
        if ($now -gt $wDeadline) { $why = "the deadline ($DeadlineSec s) expired"; $seen = $cur; break }
        if (($now - $lastProgress).TotalSeconds -gt $StallSec) { $why = "no progress for $StallSec s"; $seen = $cur; break }
        Start-Sleep -Seconds 10
    }
    T 'wait_exit' $why
    # THE CAST GOES INSIDE THE PARENTHESES. `T 'waited_s' [int](...)` passes the TYPE LITERAL as the
    # argument and the value is lost - it parses cleanly, so no parse gate sees it. Measured under
    # pwsh 7.4: v=[[int]]. Same family as the `-f` index with no argument behind it, filed as
    # PSFORMATINDEXUNCHECKED.
    T 'waited_s' ([int]((Get-Date) - $script:started).TotalSeconds)
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
    if ($restoreNeeded -and $qdbProc) {
        [void][W.T]::NtResumeProcess($qdbProc.Handle)
        T 'qubesdb_resumed' (Get-Date -Format 'HH:mm:ss.fff')
        # ASSERTED, NOT ASSUMED: a resume that did not take leaves this guest without a control
        # channel, so the daemon is read back and a client connect is attempted through it.
        Start-Sleep -Seconds 3
        T 'qubesdb_state_after_resume' (Svc-State $QDB)
        T 'qubesdb_process_alive' ($null -ne (Get-Process -Id $qdbProc.Id -EA SilentlyContinue))
    }
    # QrexecAgent back, whichever arm ran: the SCM may already have restarted it, and starting a
    # running service is harmless.
    T 'qrexecagent_restore_said' ((& sc.exe start $QRX 2>&1 | Out-String) -replace '\s+', ' ').Trim()
    # THE DEPENDENTS TOO: Stop-Service -Force took them down, and a guest left without its GUI agent
    # watchdog is a guest this cell degraded.
    foreach ($d in $deps) {
        if ($d) { T ('dependent_' + $d + '_start_said') ((& sc.exe start $d 2>&1 | Out-String) -replace '\s+', ' ').Trim() }
    }
    $deadline = (Get-Date).AddSeconds(180)
    while ((Get-Date) -lt $deadline -and (Svc-State $QRX) -ne 'RUNNING') { Start-Sleep -Seconds 3 }
    T 'qrexecagent_state_restored' (Svc-State $QRX)
    T 'qubesdb_state_end' (Svc-State $QDB)
    # THE LAST LINE IS THE MARKER THE HARNESS WAITS FOR. Without it a transcript that stops early is
    # indistinguishable from one still being written, and the harness would grade a partial run.
    T 'done' (Get-Date).ToUniversalTime().ToString('s')
}
