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

# If an update run is already in flight, attach to it instead of clobbering its status file.
# FRESHNESS GUARD. Deleting the status file is not enough on its own: other tasks write the same
# file, and one of them finishing can hand us a `done` that belongs to a different operation.
# Measured 2026-08-13 on a template: the scheduled scan fired 6 minutes into a dom0-driven
# install, wrote its own `done` with an empty result, and this handler reported the update
# complete while DISM was still running. So ignore any status stamped before we started.
$script:StartedAt = (Get-Date).AddSeconds(-2)   # 2 s of slack for clock granularity

$running = (Get-ScheduledTask -TaskName $Task -EA SilentlyContinue).State -eq 'Running'
if (-not $running) {
    Remove-Item -LiteralPath $Status -Force -EA SilentlyContinue   # baseline: never read a stale run
    & schtasks /run /tn $Task 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { $Err.WriteLine("cannot start $Task (rc=$LASTEXITCODE) - is the updater agent installed?"); exit 1 }
}
Write-Output "qubes.WindowsUpdate: driving $Task (attach=$running)"
Prog 0

# Tail the status file. 2h hard bound (a full 5GB cumulative fetch+DISM fits well inside).
$deadline = (Get-Date).AddHours(2)
$st = $null
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    $raw = Get-Content -LiteralPath $Status -Raw -EA SilentlyContinue
    if (-not $raw) { continue }                       # not written yet, or mid-rewrite
    try { $st = $raw | ConvertFrom-Json } catch { continue }
    # belongs to an older operation - keep waiting for ours
    if ($st.ts) {
        $stamp = $null
        if ([datetime]::TryParse($st.ts, [ref]$stamp) -and $stamp -lt $script:StartedAt) { continue }
    }
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
    if ($st.phase -eq 'done' -or $st.phase -eq 'error') { break }
    # If the task died without reaching done/error, stop tailing a corpse.
    $tstate = (Get-ScheduledTask -TaskName $Task -EA SilentlyContinue).State
    if ($tstate -ne 'Running') {
        Start-Sleep -Seconds 3   # grace: one final status rewrite may be in flight
        $raw = Get-Content -LiteralPath $Status -Raw -EA SilentlyContinue
        if ($raw) { try { $st = $raw | ConvertFrom-Json } catch {} }
        break
    }
}

if (-not $st) { $Err.WriteLine('no status produced - update task never started'); exit 1 }
switch ($st.phase) {
    'done' {
        Prog 100
        if ([int]$st.count -eq 0 -and -not $st.result) { Write-Output 'no updates available'; exit 100 }

        # Judge the OUTCOME, not the phase. `done` only means the pass ran to the end; a KB whose
        # every .msu failed in DISM is a failed update and dom0 must hear about it, otherwise this
        # repeats the defect found in QWT's VMExec handler - reporting success regardless.
        # Results are grouped per KB ({kb, ok, files}); tolerate the older flat shape too.
        $rows   = @($st.result)
        $perKb  = @($rows | Where-Object { $_.PSObject.Properties.Name -contains 'kb' })
        $failed = @($perKb | Where-Object { -not $_.ok } | ForEach-Object { $_.kb })
        $okKbs  = @($perKb | Where-Object { $_.ok }      | ForEach-Object { $_.kb })

        # After 100.0 every stderr line is shown as a message, so the outcome goes THERE - on
        # stdout it would only reach the log view, and the operator asked to see which updates
        # were installed. Ends with a KB id, never a bare number (see Msg).
        # WORD IT HONESTLY. DISM 3010 means the package is STAGED and applies during the next
        # boot - it is not proof that it landed. Measured 2026-08-13 on the 24H2 template:
        # kb5121003.msu returned 3010, the qube rebooted, and the build did NOT move because the
        # boot-time servicing failed with 0x80070490 (its checkpoint prerequisite had failed).
        # The scan after the boot re-offers such an update, so the truth arrives either way -
        # but this line must not claim more than it knows.
        if ($okKbs.Count) {
            $verb = if ($st.reboot_needed) { 'staged (completes at restart): ' } else { 'installed: ' }
            $Err.WriteLine($verb + ($okKbs -join ', '))
        }
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
        if ($failed.Count) {
            foreach ($f in @($perKb | Where-Object { -not $_.ok })) {
                $why = if ($f.reason) { $f.reason } else { "DISM rejected every package file" }
                $Err.WriteLine("FAILED $($f.kb): $why")
            }
            $Err.WriteLine("see C:\ProgramData\Qubes\update-status.json on the qube for details")
            exit 1
        }
        Write-Output ("updates processed: count=" + $st.count)
        exit 0
    }
    'error' { Prog 100; $Err.WriteLine("update failed: " + $st.error); exit 1 }
    default { Prog 100; $Err.WriteLine("update did not complete (last phase: " + $st.phase + ")"); exit 1 }
}
