# qubes.WindowsUpdate rpc handler (QWT-NG): dom0-DRIVEN update, Linux-updater style.
#
# Mirrors the qubes-vm-update agent contract (core-admin-linux vmupdate/qube_connection.py):
#   - progress = bare float lines 0..100 on STDERR (dom0 parses float(line); 100.0 ends progress,
#     later stderr lines are shown as messages)
#   - exit 0 = success, exit 100 = no updates, anything else = error
#   - stdout = logs
#
# The actual work runs in the QubesWindowsUpdateRun SYSTEM scheduled task (registered by
# install-updater-agent.ps1) - rpc handlers run unelevated and DISM needs admin, while the
# SYSTEM-task path is proven. This handler is just the protocol shim: baseline the status file,
# kick the task, tail update-status.json (rewritten at every phase by qubes-windows-update.ps1),
# and translate phases into the float protocol. Bounded: never blocks dom0 forever.
#
# -Task selects which on-demand task to drive. The rpc service passes nothing (full pass);
# vmupdate-shim.ps1 passes QubesWindowsUpdateDownload when dom0 asked for --download-only, so a
# download-only request can never install - that decision stays with dom0.
param([string]$Task = 'QubesWindowsUpdateRun')
$ErrorActionPreference = 'SilentlyContinue'
$Status = 'C:\ProgramData\Qubes\update-status.json'
$qtRootForAl = $env:QUBES_TOOLS; if (-not $qtRootForAl) { $qtRootForAl = 'C:\Program Files\Qubes Tools' }
$Err    = [Console]::Error

# INVARIANT CULTURE IS LOAD-BEARING, do not simplify this back to `"{0:0.0}" -f $p`.
#
# PowerShell's -f operator formats with CurrentCulture, and in a custom numeric format string the
# "." is not a literal - it is the decimal-separator PLACEHOLDER, substituted with
# NumberFormatInfo.NumberDecimalSeparator. On a German guest that is a comma, so this emitted
# "0,0" / "75,0". dom0 parses progress with float(line) (qube_connection.py::_collect_stderr), and
# float("75,0") raises - so EVERY progress line, starting with the very first, was unparseable and
# fell through to being displayed as a message instead. A real user runs a German edition.
#
# Only formatting that crosses the dom0 protocol needs this; log text does not.
function Prog([double]$p) {
    if ($p -gt $script:LastP) {
        $script:LastP = $p
        $Err.WriteLine([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.0}', $p))
    }
}
$script:LastP = -1

# dom0 shows any stderr line that is NOT a number as a message, interleaved with the progress
# bar (qube_connection.py::_collect_stderr), so the operator can see WHICH update is running
# rather than a bare percentage.
#
# CAREFUL: dom0 tries float(line) and then float(line.split()[-1]), so a message ENDING in a
# number is silently swallowed as a progress value - "downloading KB5120708 184.5" would be
# read as 184.5 %. Every message here must therefore end in a non-numeric word.
# De-duplicate against EVERY message already sent, not just the previous one. The status file is
# polled every 3 s and two different messages can be live at once ("found N update(s)" is
# re-derived on every poll while "installing <file>" comes from the phase), so a last-value-only
# check let them alternate forever: found / installing / found / installing ... - which is
# exactly the repetition seen in the first GUI run.
$script:SentMsgs = @{}
function Msg([string]$m) {
    if ($m -and -not $script:SentMsgs.ContainsKey($m)) {
        $script:SentMsgs[$m] = $true
        $Err.WriteLine($m)
    }
}

# ---- WU-OUTCOME-BEGIN   (tools/tests/wu-update-render-test.ps1 extracts this region by these markers)
# Judge the OUTCOME of a finished pass, not its phase: `done` only means the pass ran to the end.
# Results are grouped per KB by qubes-windows-update.ps1 ({kb, ok, state, files} or
# {kb, ok, files, reason}); every row here came through ConvertFrom-Json, so it is a
# PSCustomObject whose property list IS its key list (the OrderedDictionary trap of b996dc8 is on
# the writer's side only).
#
# ok=false is NOT "failed". The writer records four ok=false shapes, and only the last is a failure:
#   state=deferred        the one-staged-package-per-CBS-session rule left this KB for the NEXT pass
#                         (the pass commits a reboot; the boot scan re-reports it). Its explanation
#                         is files.why. Measured 2026-09-16 on win11de-gwt (German 25H2, 4.3.29):
#                         this row was rendered "FAILED KB5129195: DISM rejected every package file"
#                         + exit 1 while DISM was never handed the file - the code read $row.reason
#                         (absent on this shape) and fell to a hard-coded fallback, so dom0 showed a
#                         healthy Patch Tuesday as a DISM failure. Every guest more than one reboot
#                         behind produces such a row on its first pass.
#   reason='deferred: ..' the same rule applied to the Windows-Update-native fallback (no state key)
#   severity=info or      an informational ceiling (not installable on this guest by any path); the
#   state=informational   writer already excludes it from the count it reports to dom0
#   anything else         a real failure. Its reason is the row's own record - $row.reason, or per
#                         file files.why / files.error / files.rc - never a cause invented here.
function Get-RowWhy($row) {
    if ("$($row.reason)" -ne '') { return "$($row.reason)" }
    # files is a list for multi-file KBs and a single object where the writer had one row (as in
    # the captured status: "files": { "rc": "deferred", "why": ... }); @() answers both.
    $whys = @()
    foreach ($f in @($row.files)) {
        if ($null -eq $f) { continue }
        if     ("$($f.why)" -ne '')    { $whys += "$($f.why)" }
        elseif ("$($f.error)" -ne '')  { $whys += "$($f.error)" }
        elseif ("$($f.reason)" -ne '') { $whys += "$($f.reason)" }
        elseif ("$($f.rc)" -ne '')     { $whys += "$($f.file) rc=$($f.rc)" }   # glued: never a bare trailing number
    }
    $whys = @($whys | Select-Object -Unique)
    if ($whys.Count) { return ($whys -join '; ') }
    return 'no reason recorded'
}
function Get-Outcome($st) {
    $ok = @(); $deferred = @(); $info = @(); $failed = @()
    foreach ($r in @($st.result)) {
        # per-KB rows only; tolerate the older flat (per-file) shape by skipping what has no kb
        if ($null -eq $r -or -not (@($r.PSObject.Properties.Name) -contains 'kb')) { continue }
        if ($r.ok) { $ok += $r; continue }
        if ($r.state -eq 'deferred' -or "$($r.reason)" -like 'deferred:*') { $deferred += $r; continue }   # GUARD:deferred
        if ($r.severity -eq 'info' -or $r.state -eq 'informational') { $info += $r; continue }              # GUARD:info
        $failed += $r
    }
    return [pscustomobject]@{ ok = $ok; deferred = $deferred; info = $info; failed = $failed }
}
# The outcome is written in two parts around the reboot block: what this pass did (head), then the
# reboot notice, then what failed (tail, which decides the exit code). After 100.0 every stderr line
# is shown by dom0 as a message, and a line must never END in a bare number (see Msg).
function Write-OutcomeHead($o, [bool]$rebootNeeded) {
    # WORD IT HONESTLY. DISM 3010 means the package is STAGED and applies during the next boot - it
    # is not proof that it landed. Measured 2026-08-13 on the 24H2 template: kb5121003.msu returned
    # 3010, the qube rebooted, and the build did NOT move because the boot-time servicing failed
    # with 0x80070490. The scan after the boot re-offers such an update, so the truth arrives
    # either way - but this line must not claim more than it knows.
    if ($o.ok.Count) {
        $verb = if ($rebootNeeded) { 'staged (completes at restart): ' } else { 'installed: ' }
        $Err.WriteLine($verb + (@($o.ok | ForEach-Object { $_.kb }) -join ', '))
    }
    foreach ($r in $o.deferred) { $Err.WriteLine("deferred $($r.kb): " + ((Get-RowWhy $r) -replace '^deferred:\s*', '')) }
    if ($o.deferred.Count) { $Err.WriteLine('run this update again after the restart to install what was deferred') }
    foreach ($r in $o.info) { $Err.WriteLine("informational $($r.kb): " + (Get-RowWhy $r)) }
}
function Write-OutcomeTail($o) {
    if (-not $o.failed.Count) { return 0 }
    foreach ($r in $o.failed) {
        $why = Get-RowWhy $r   # GUARD:rowwhy
        $Err.WriteLine("FAILED $($r.kb): $why")
    }
    $Err.WriteLine('see C:\ProgramData\Qubes\update-status.json on the qube for details')
    return 1
}
# ---- WU-OUTCOME-END

# If an update run is already in flight, attach to it instead of clobbering its status file.
# FRESHNESS GUARD. Deleting the status file is not enough on its own: other tasks write the same
# file, and one of them finishing can hand us a `done` that belongs to a different operation.
#
# SCOPE CORRECTED 2026-08-14. This guard does NOT prevent the 2026-08-13 collision it was written
# for (the 6-hourly scan firing mid-install and reporting a `done` with an empty result). Two
# reasons: that collision is now prevented at the WRITER, by the Global\QubesWindowsUpdate mutex a
# scan takes with waitMs=0 before any Save (qubes-windows-update.ps1); and a timestamp test could
# never have caught it anyway, because a scan running mid-install stamps a FRESH ts and passes.
# What this guard genuinely protects is the ATTACH path below, which deliberately skips the
# Remove-Item baseline when the task is already Running - there, a status left on disk by an
# EARLIER operation (e.g. the 03:00 scheduled scan) is still readable on the first poll.
# The `action -eq 'scan'` test further down is what covers the fresh-but-foreign case.
$script:StartedAt = (Get-Date).AddSeconds(-2)   # 2 s of slack for clock granularity

$running = (Get-ScheduledTask -TaskName $Task -EA SilentlyContinue).State -eq 'Running'
if (-not $running) {
    Remove-Item -LiteralPath $Status -Force -EA SilentlyContinue   # baseline: never read a stale run
    & schtasks /run /tn $Task 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { $Err.WriteLine("cannot start $Task (rc=$LASTEXITCODE) - is the updater agent installed?"); exit 1 }
}
Write-Output "qubes.WindowsUpdate: driving $Task (attach=$running)"
Prog 0

# ---- WU-POLL-BEGIN   (tools/tests/wu-dead-pass-test.ps1 extracts this region by these markers)
# Tail the status file. 2h hard bound (a full 5GB cumulative fetch+DISM fits well inside).
#
# DEAD-PASS DETECTION, on EVERY poll. Measured 2026-09-17 on the German 25H2 template: the Task
# Scheduler ended the QubesWindowsUpdateRun instance 90 s into a pass (LastTaskResult 0x41306),
# the pass process died hard (its finally never ran, the relay kept serving for hours),
# update-status.json froze at phase=scan, and this loop tailed the corpse for its whole 2 h bound
# before telling dom0 `update did not complete (last phase: scan)`. The task check that existed
# sat at the BOTTOM of the loop body, behind four `continue`s (no file yet, unparseable, stale
# ts, foreign scan) - a poll that took any of them never reached it. The verdict now comes
# first, needs no status of ours to be taken, and names the task's own result code.
$deadline = (Get-Date).AddHours(2)
$st = $null            # the last status that belongs to OUR pass (passed the guards below)
$script:Seen = $null   # the last status parsed from disk, ours or not - named in the DIED line
$script:Polls = 0
$script:TaskUnreadableSaid = $false
# The writer's own last phases (qubes-windows-update.ps1): done/error end a pass, scan-failed and
# skipped-* end it before any work. A task that is not Running while its status shows any of these
# simply finished; anything else is a pass that stopped writing.
function Test-TerminalPhase($phase) {
    return ("$phase" -in 'done', 'error', 'scan-failed' -or "$phase" -like 'skipped-*')
}
# The writer's ts is an invariant ISO string; pwsh 7's ConvertFrom-Json (tests, and any future host)
# hands it back as a DateTime, which would otherwise print culture-formatted.
function Format-Ts($t) { if ($t -is [datetime]) { return $t.ToString('s') }; return "$t" }
# LastTaskResult (Get-ScheduledTaskInfo) is the scheduler's own HRESULT for the last instance.
function Get-TaskResultMeaning([uint32]$r) {
    switch ($r) {
        0       { return 'exited normally' }
        0x41301 { return 'still running' }
        0x41302 { return 'task is disabled' }
        0x41303 { return 'has not yet run' }
        0x41306 { return 'terminated by the scheduler on request - its ExecutionTimeLimit, or somebody''s schtasks /end or Stop-ScheduledTask' }
        0x41325 { return 'queued' }
        default { return 'unmapped code' }
    }
}
# What a killed pass leaves behind, torn down the way qubes-windows-update.ps1's Remove-Proxy does
# it: WinHTTP proxy reset, WinINET proxy disabled, relay process stopped. That script is not
# dot-sourceable (it IS the pass - loading it runs one) and has no cleanup action, so the steps
# are mirrored here; keep them in step with Remove-Proxy. Every step reports its own outcome: this
# handler runs in the rpc caller's context and may lack the right to stop a SYSTEM relay, and a
# relay left serving is the one leftover that matters (see the temporal-gate comment there).
function Remove-DeadPassLeftovers {
    $isKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings'
    $done = @(); $failed = @()
    & netsh winhttp reset proxy 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { $done += 'winhttp proxy reset' } else { $failed += "winhttp proxy reset (netsh rc=$LASTEXITCODE)" }
    try {
        New-ItemProperty -Path $isKey -Name 'ProxyEnable' -Value 0 -PropertyType DWord -Force -EA Stop | Out-Null
        Remove-ItemProperty -Path $isKey -Name 'ProxyServer' -EA SilentlyContinue
        $done += 'wininet proxy disabled'
    } catch { $failed += "wininet proxy disable ($($_.Exception.Message))" }
    foreach ($p in @(Get-Process qubes-updates-relay -EA SilentlyContinue)) {
        $rp = $p
        try { $rp.Kill(); $done += "relay pid $($rp.Id) stopped" } catch { $failed += "relay pid $($rp.Id) NOT stopped ($($_.Exception.Message))" }
    }
    $left = @(Get-Process qubes-updates-relay -EA SilentlyContinue)
    if ($left.Count) { $failed += ('relay still running: pid ' + (@($left | ForEach-Object { $_.Id }) -join ', ') + ' - the proxy is still up') }
    # never end in a bare number (see Msg): the summary closes with a word
    if ($failed.Count) { $Err.WriteLine('leftovers: ' + (($done + $failed) -join '; ') + ' - CHECK the qube, its offline baseline is NOT restored') }
    else { $Err.WriteLine('leftovers: ' + ($done -join '; ') + ' - offline baseline restored') }
}
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    $script:Polls++
    # 1. the task, read BEFORE the status: a pass that ends between the two reads has already
    #    written its final status, so this order can never show "not Running" against a terminal
    #    status still to come. A task that cannot be read is not evidence of anything - say so
    #    once, loudly, and keep tailing rather than invent a verdict.
    $tk = Get-ScheduledTask -TaskName $Task -EA SilentlyContinue   # NOT $task: PowerShell names are case-insensitive, that is $Task
    $tstate = "$($tk.State)"
    if (-not $tk -and -not $script:TaskUnreadableSaid) {
        $script:TaskUnreadableSaid = $true
        $Err.WriteLine("WUDEADPASSBLIND: cannot read task $Task (Get-ScheduledTask returned nothing) - a dead pass cannot be detected on this qube")
    }
    # 2. the status: absent, unparseable, stale or foreign leaves $cur empty - never a skipped verdict
    $cur = $null
    $raw = Get-Content -LiteralPath $Status -Raw -EA SilentlyContinue   # empty: not written yet, or mid-rewrite
    if ($raw) { try { $cur = $raw | ConvertFrom-Json } catch { $cur = $null } }
    if ($cur) { $script:Seen = $cur }
    # belongs to an older operation - keep waiting for ours
    #
    # $stamp MUST start as a real DateTime. It used to be $null, and that guard NEVER FIRED once:
    # PowerShell converts a [ref] variable's CURRENT value to the ByRef parameter type during
    # overload resolution, and $null has no conversion to the non-nullable value type DateTime, so
    # the call raised MethodException "Cannot find an overload for TryParse and the argument
    # count: 2". $ErrorActionPreference='SilentlyContinue' (line 19) made that a SILENT
    # statement-terminating error: the whole `if` was abandoned, `continue` never ran, and one
    # exception per poll (~2400 over a 2 h tail) piled into $Error unseen.
    # Measured 2026-08-14 (guest/wu-guard-check.ps1): init=$null -> throws, errors=1, a status
    # stamped 2020 is ACCEPTED; init=[datetime]::MinValue -> the same status is correctly dropped
    # and a fresh one still accepted. Culture-independent - it fails identically on en-US.
    #
    # TryParseExact against the invariant Gregorian shape the writer emits
    # (qubes-windows-update.ps1:81 uses ToString('s'), measured calendar-invariant), so this guard
    # cannot silently become calendar-sensitive if that format is ever changed.
    if ($cur -and $cur.ts) {
        $stamp = [datetime]::MinValue
        if ([datetime]::TryParseExact($cur.ts, 'yyyy-MM-ddTHH:mm:ss',
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::None, [ref]$stamp) -and $stamp -lt $script:StartedAt) { $cur = $null }
    }
    # A SCAN's status never belongs to a dom0-driven run. This is what actually closes the
    # wrong-operation class: the timestamp test cannot, because any foreign writer stamps a FRESH
    # ts by construction and so passes it. A scan reports availability and never a result, so its
    # `done` would be read below as "finished, nothing to do" -> Prog 100 -> exit 100.
    if ($cur -and $cur.action -eq 'scan') { $cur = $null }
    if ($cur) { $st = $cur }
    # 3. the verdict. One poll of grace after the kick: schtasks /run returns before the instance
    #    exists, so the first poll may legitimately see Ready. From the second poll on, a task
    #    that is not Running while our status is not terminal is a pass that stopped writing.
    if ($tk -and $tstate -ne 'Running' -and $script:Polls -gt 1 -and -not (Test-TerminalPhase $st.phase)) {   # GUARD:deadpass
        $info = Get-ScheduledTaskInfo -TaskName $Task -EA SilentlyContinue
        $code = [uint32]0   # HRESULTs above 0x7FFFFFFF arrive as negative Int32 on some builds: mask, never truncate
        try { $code = [uint32]([int64]$info.LastTaskResult -band 0xFFFFFFFF) } catch { $code = [uint32]0 }
        $what = 'no status was written at all'
        if ($st) { $what = "status stale since $(Format-Ts $st.ts) at phase $($st.phase)" }
        elseif ($script:Seen) { $what = "the only status on disk is from an earlier operation (action $($script:Seen.action), ts $(Format-Ts $script:Seen.ts), phase $($script:Seen.phase))" }
        $Err.WriteLine([string]::Format([Globalization.CultureInfo]::InvariantCulture,
            'update pass DIED: task {0} is {1}, last result 0x{2:X} ({3}), {4}', $Task, $tstate, $code, (Get-TaskResultMeaning $code), $what))
        Remove-DeadPassLeftovers
        exit 1
    }
    if (-not $cur) { continue }
    # Announce WHICH updates as soon as the scan knows, independent of phase: the tail polls
    # every 3 s and a short-lived phase can pass between two polls unseen. Msg de-duplicates.
    if ([int]$st.count -gt 0 -and $st.available) {
        Msg ("found " + $st.count + " update(s): " + (@($st.available | ForEach-Object { $_.kb }) -join ', '))
    }

    switch ($st.phase) {
        'init'         { Prog 1 }
        'ensure-proxy' { Prog 1; Msg 'opening the Qubes updates proxy' }
        'scan'         { Prog 3; Msg 'scanning Windows Update' }
        'resolve'      { Prog 6 }
        'download'     {
            $p = 10; if ($st.downloading -and $st.downloading.pct) { $p = 10 + 0.6 * [double]$st.downloading.pct }; Prog $p
            if ($st.downloading) { Msg ("downloading " + $st.downloading.kb + " (" + $st.downloading.total_mb + " MB)") }
        }
        'install'      {
            # stderr ONLY. dom0 renders stderr lines as live messages AND displays collected
            # stdout, so writing the same text to both makes every line appear twice in the
            # updater output - which is exactly what it did.
            Prog 75
            if ($st.installing) { Msg ("installing " + $st.installing.file) }
        }
        'done'         { break }
        'error'        { break }
    }
    # done/error are rendered below; scan-failed and skipped-* fall to the default branch there
    # ("update did not complete"), exactly as they did when the old bottom check caught them.
    if (Test-TerminalPhase $st.phase) { break }
}
# ---- WU-POLL-END

if (-not $st) { $Err.WriteLine('no status produced - update task never started'); exit 1 }
switch ($st.phase) {
    'done' {
        Prog 100
        if ([int]$st.count -eq 0 -and -not $st.result) { Write-Output 'no updates available'; exit 100 }

        # A KB whose every .msu failed is a failed update and dom0 must hear about it, otherwise
        # this repeats the defect found in QWT's VMExec handler - reporting success regardless.
        # A deferred or informational row is NOT that (see the WU-OUTCOME region): the pass exits 0
        # and the staged reboot + boot scan carry the remainder.
        # After 100.0 every stderr line is shown as a message, so the outcome goes THERE - on
        # stdout it would only reach the log view, and the operator asked to see which updates
        # were installed.
        $outcome = Get-Outcome $st
        Write-OutcomeHead $outcome ([bool]$st.reboot_needed)
        if ($st.reboot_needed) {
            # An update that needs a reboot is not finished until it gets one, so the pass
            # commits it - for templates AND standalones alike (user direction 2026-08-13:
            # "we commit reboot if needed at the end of update ... it is user guided action
            # anyway, so no safeguard needed"). dom0 cannot do it for us: its restart machinery
            # is entirely template -> AppVM, and there is no restart-required marker a
            # StandaloneVM could carry.
            #
            # It also has to be a REBOOT, not a shutdown: Windows completes pending servicing
            # during BOOT. On a template, that boot is what commits the change to the template
            # root - shut down with the operation pending and it would instead replay inside
            # each AppVM's copy-on-write layer at every start and be discarded at every
            # shutdown, so the update would never land at all.
            #
            # Delayed 60 s so this rpc returns its result to dom0 first.
            # Call shutdown.exe DIRECTLY and check it worked. The first version used
            # Start-Process ... -EA SilentlyContinue, which scheduled nothing and said nothing:
            # the qube simply never rebooted, and the silenced error made it look like it had.
            # shutdown.exe schedules with the OS and returns at once, so there is nothing to
            # detach from.
            # NOTE what actually happens on Qubes: templates/libvirt/xen.xml sets
            # <on_reboot>destroy</on_reboot>, so a guest-initiated reboot DESTROYS the domain -
            # a qube can never restart itself, it can only end up halted. Measured: the qube sat
            # Halted for 4+ minutes after this call. Windows completes the pending servicing at
            # its NEXT boot, which is exactly what a template needs, so the outcome is right -
            # but the message must say "shutting down", not "rebooting", or it is a lie.
            # A qube that comes back to a sign-in screen is unreachable: with no interactive
            # session, qrexec service calls have nobody to run as, so dom0 cannot update it, run
            # apps in it, or read it. Windows servicing rewrites Winlogon values, so autologon
            # must be re-asserted HERE, before the reboot we are about to cause.
            $al = Join-Path $qtRootForAl 'qubes-rpc-services\ensure-autologon.ps1'
            $autologonOk = $true
            if (Test-Path $al) {
                foreach ($l in @(& $al 2>&1)) { if ($l -match '^(SET|WARN)') { $Err.WriteLine("autologon: $l") } }
                if ($LASTEXITCODE -eq 2) { $autologonOk = $false }
                elseif ($LASTEXITCODE -eq 3) {
                    # Exit 3 = the LSA probe itself failed; no finding either way. Rebooting is the
                    # deliberate choice - a probe fault must not withhold every dom0-driven update of
                    # an armed guest (ensure-autologon.ps1's contract) - but the choice is STATED, not
                    # implied by treating 3 like 0: if this qube does come back at a sign-in screen,
                    # this is the line that says autologon was never actually verified before the
                    # reboot, so the probe (not the password) is what gets diagnosed.
                    $Err.WriteLine('autologon UNVERIFIED (the LSA probe failed - see the autologon: WARN lines above) - rebooting anyway; a probe fault is not evidence the password is gone')
                }
            }
            if (-not $autologonOk) {
                # Rebooting now would leave the qube at a sign-in screen, where qrexec has nobody
                # to run as: no updates, no apps, no diagnostics until somebody logs in by hand.
                # A staged update is a smaller problem than an unreachable qube, so we stop here
                # and say so. The update completes at the next boot the operator chooses.
                $Err.WriteLine('NOT rebooting: autologon is not configured, so this qube would come back at a sign-in screen and be unreachable over qrexec')
                $Err.WriteLine('restart it yourself when convenient - the update completes during that boot')
                Write-Output 'reboot withheld: autologon not guaranteed'
                exit 0
            }
            & shutdown.exe /r /t 60 /c "Qubes: completing Windows update servicing"
            if ($LASTEXITCODE -eq 0) {
                $Err.WriteLine('updates installed - this qube shuts down in 60 seconds; start it again and the update finishes during boot')
            } else {
                $Err.WriteLine("updates installed - RESTART REQUIRED, but scheduling it failed (shutdown.exe rc=$LASTEXITCODE) - restart this qube yourself")
            }
        }
        if ((Write-OutcomeTail $outcome) -ne 0) { exit 1 }
        Write-Output ("updates processed: count=" + $st.count)
        exit 0
    }
    'error' { Prog 100; $Err.WriteLine("update failed: " + $st.error); exit 1 }
    default { Prog 100; $Err.WriteLine("update did not complete (last phase: " + $st.phase + ")"); exit 1 }
}
