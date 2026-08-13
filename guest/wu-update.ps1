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
$Err    = [Console]::Error

function Prog([double]$p) {
    if ($p -gt $script:LastP) { $script:LastP = $p; $Err.WriteLine(("{0:0.0}" -f $p)) }
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
        if ($okKbs.Count) { $Err.WriteLine("installed: " + ($okKbs -join ', ')) }
        if ($st.reboot_needed) { $Err.WriteLine('updates installed - RESTART REQUIRED to finish') }
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
