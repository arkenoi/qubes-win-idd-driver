# T2 resize-sync v0 (guest side): make the guest desktop exactly match dom0-requested sizes.
#
# Mechanism (v1 driver t2/d4-registry-modes): the IDD reads HKLM\SOFTWARE\QubesIDD\Modes
# (REG_MULTI_SZ of WxH) at monitor arrival; a device restart replugs the monitor and re-reads
# the list. This script watches the gui-agent log for dom0-originated resolution requests
# (A1's "RESREQ WxH src=dom0" lines). When dom0 asks for a size that got snapped (RESSNAP
# differs), it publishes the exact size, replugs the IDD, and applies the exact mode.
#
# This is the harness prototype of the sync loop; the production home for this logic is the
# agent itself (mode-cache refresh + IOCTL instead of replug) — tracked in FINDINGS.
#
# Usage: -Once (single pass over recent log)  or default: poll loop every 2 s.
#        -DeviceId defaults to the D0/D4 root-enumerated instance.
param(
    [string]$SyncNow = '',   # one-shot: sync straight to this WxH and exit (stress harness)
    [string]$DeviceId = 'ROOT\DISPLAY\0000',
    [int]$PollSec = 2
)
$ErrorActionPreference = 'Continue'
$inc    = 'C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
$devcon = 'C:\qubes-idd\devcon.exe'
$modeprobe = Join-Path $inc 'modeprobe.exe'
$logdir = 'C:\Program Files\Qubes Tools\log'
$state  = 'C:\qubes-idd\resize-sync-state.txt'
$out    = 'C:\qubes-idd\resize-sync.log'

# File-only: functions below RETURN values through the pipeline, so Log must not emit to it.
function Log($m) { ("{0} {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $m) | Out-File $out -Append -Encoding ascii }

function CurrentRes {
    $j = & $modeprobe 2>$null | ConvertFrom-Json
    $c = ($j.devices | Where-Object { $_.primary }).current
    if (-not $c) { $c = $j.devices[0].current }
    "$($c.w)x$($c.h)"
}

function SyncTo([string]$size) {
    Log "SYNC start target=$size current=$(CurrentRes)"
    New-Item -Path 'HKLM:\SOFTWARE\QubesIDD' -Force | Out-Null
    Set-ItemProperty 'HKLM:\SOFTWARE\QubesIDD' -Name Modes -Value @($size) -Type MultiString
    & $devcon restart "@$DeviceId" | Out-Null
    if ($LASTEXITCODE -ne 0) { Log "SYNC fail=devcon_restart exit=$LASTEXITCODE"; return $false }
    # wait for the replugged monitor to offer the mode (CDS_TEST goes SUCCESSFUL)
    $ok = $false
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 700
        $t = (& $modeprobe --test $size 2>$null | ConvertFrom-Json).result.disp_change_name
        if ($t -eq 'DISP_CHANGE_SUCCESSFUL') { $ok = $true; break }
    }
    if (-not $ok) { Log "SYNC fail=mode_never_offered target=$size"; return $false }
    # Apply, then CONVERGE: while the replug's capture outage drains, gui-daemon can echo its
    # stale window size back as MSG_CONFIGURE and the agent applies it, overriding us
    # (measured 2026-08-05, stress cycle 9). Re-apply until the readback holds the target
    # across two spaced checks. Retries are reported — they are a measurement, not noise.
    $retries = 0
    for ($a = 0; $a -lt 4; $a++) {
        $r = (& $modeprobe --apply $size 2>$null | ConvertFrom-Json).result
        Log ("SYNC apply#$a disp=" + $r.disp_change_name + " readback=" + $r.readback.w + "x" + $r.readback.h)
        if (-not $r.match) { $retries++; Start-Sleep -Seconds 2; continue }
        Start-Sleep -Milliseconds 1800
        if ((CurrentRes) -eq $size) {
            Start-Sleep -Milliseconds 1800
            if ((CurrentRes) -eq $size) { Log "SYNC stable target=$size retries=$retries"; return $true }
        }
        $retries++
        Log "SYNC overridden (stale daemon echo), retrying target=$size"
    }
    Log "SYNC fail=never_stabilized target=$size retries=$retries"
    return $false
}

function LatestLog { Get-ChildItem $logdir -Filter 'gui-agent-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1 }

# Return the NEWEST dom0-originated request in the log, or ''. A drag produces a stream of
# MSG_CONFIGUREs; only the final one is intent - syncing to each one in order replugs the
# monitor mid-drag repeatedly (user-reported breakage 2026-08-05). Latest wins, always.
function LatestDom0Request {
    $log = LatestLog; if (-not $log) { return '' }
    $m = Select-String -Path $log.FullName -Pattern 'RESREQ (\d+)x(\d+) src=dom0' | Select-Object -Last 1
    if ($m) { $m.Matches[0].Groups[1].Value + 'x' + $m.Matches[0].Groups[2].Value } else { '' }
}

if ($SyncNow) {
    $ok = SyncTo $SyncNow
    Write-Output ("SYNCRESULT target=$SyncNow ok=$ok readback=" + (CurrentRes))
    if (-not $ok) { exit 1 }
} else {
    # Debounced follow loop: act only when the newest dom0 request has been STABLE for two
    # consecutive polls (the drag ended) and differs from the current resolution.
    Log "resize-sync loop started (debounced)"
    $pending = ''; $stable = 0
    while ($true) {
        Start-Sleep -Seconds $PollSec
        $req = LatestDom0Request
        if (-not $req) { continue }
        if ($req -ne $pending) { $pending = $req; $stable = 0; continue }
        $stable++
        if ($stable -lt 2) { continue }
        if ($req -eq (CurrentRes)) { continue }   # already there (or a snap echo settled equal)
        Log "REQUEST dom0 settled on $req - syncing exact"
        [void](SyncTo $req)
        $stable = 0
    }
}
