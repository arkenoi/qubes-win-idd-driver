# PREMATURE REBOOT DIALOG DETECTOR - run inside the guest ACROSS an install.
#
# WHY THIS EXISTS
# "Premature reboot dialogs are gone" is an acceptance criterion with no instrument behind it.
# The record contains a confident claim that the xenbus prompt suppressor loses a race, and that
# claim was RETRACTED (f530d2c, 2026-08-28): the cell that "measured" it had seeded the pending
# reboot Request itself, so it was measuring its own injection. Absence of the dialog has never
# been measured at all - nothing was ever watching.
#
# This watches, and is built so that its NEGATIVE result means something:
#   * Every sample is recorded, including the ones that see nothing. An "no dialog appeared"
#     verdict is therefore backed by a timestamped record of HAVING LOOKED, at a known rate,
#     over a known interval. Missing samples are a coverage GAP and are reported as such - they
#     are never silently treated as clean.
#   * A reboot that kills this watcher shows up as exactly that gap, which is itself the signal.
#   * -SelfTest proves the detector can FIRE (a check never seen to fail is worthless). It writes
#     to a SEPARATE file and tags every record injected=true, so seeded evidence can never be
#     read back as an observation. That separation is the direct lesson of the retraction above.
#   * If it cannot see interactive windows at all (running in session 0 as a service), it reports
#     blind=true and ok=false. It will NOT report "no dialogs" from a vantage point that could
#     never have seen one.
#
# It also samples the MECHANISM, not just the symptom: the xenbus_monitor pending-reboot Request
# key and AutoReboot value, per sample. A dialog is the visible end of that chain; the registry
# state says whether the chain was ever armed, which is what distinguishes "suppressed in time"
# from "never requested".
#
# Output: append-only JSONL, one record per sample, on a path that survives a reboot.
#   -Summary re-reads that file and prints one '=== REBOOTWATCH ===' JSON line; exit 0 iff
#   ok -eq $true. Designed to be parsed by the harness, not read by eye.
[CmdletBinding()]
param(
    [string]$OutFile          = 'C:\qwt-improved-setup\reboot-dialog-watch.jsonl',
    [int]   $IntervalSeconds  = 2,
    [int]   $DurationSeconds  = 1800,   # BOUNDED. Never runs forever.
    [switch]$Summary,                   # analyse an existing log instead of sampling
    [switch]$SelfTest                   # prove the detector fires; writes to a separate file
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------------------------
# Window enumeration. Get-Process MainWindowTitle is NOT sufficient: a modal restart prompt is
# frequently owned by csrss/consent and has no MainWindow, so it is invisible to that API. Walk
# the real top-level list.
# ---------------------------------------------------------------------------------------------
if (-not ('Win32Enum' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public class Win32Enum {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr h, EnumProc cb, IntPtr l);
    // The TITLE of a driver-trust prompt says almost nothing ("Windows Security"). What it is
    // actually asking lives in its CHILD CONTROLS. Without this the watcher can prove a dialog
    // blocked the install but not WHICH question it asked, which is the difference between
    // knowing the mechanism and knowing the cause.
    public static List<string> ChildText(IntPtr parent) {
        var outp = new List<string>();
        EnumChildWindows(parent, (h, l) => {
            var t = new StringBuilder(1024); GetWindowTextW(h, t, 1024);
            var c = new StringBuilder(128);  GetClassNameW(h, c, 128);
            string s = t.ToString().Trim();
            if (s.Length > 0) outp.Add(c.ToString() + ": " + s);
            return true;
        }, IntPtr.Zero);
        return outp;
    }
    public static List<string[]> Top() {
        var outp = new List<string[]>();
        EnumWindows((h, l) => {
            var t = new StringBuilder(512); GetWindowTextW(h, t, 512);
            var c = new StringBuilder(256); GetClassNameW(h, c, 256);
            uint pid; GetWindowThreadProcessId(h, out pid);
            // Keep invisible windows too: a prompt can be caught between create and show.
            outp.Add(new string[] { h.ToString(), c.ToString(), t.ToString(),
                                    IsWindowVisible(h) ? "1" : "0", pid.ToString() });
            return true;
        }, IntPtr.Zero);
        return outp;
    }
}
'@ -Language CSharp
}

# Patterns for a restart/reboot prompt. Deliberately broad: a false positive costs one look at a
# recorded title, a false negative costs the whole verdict.
$TITLE_PAT = '(?i)restart|reboot|reiniciar|neu\s*start'
$CLASS_PAT = '(?i)^(#32770|Xen.*|ConsentUI|CredentialDialog)'
# csrss "hard error" prompts - the shape the Xen pending-reboot request takes with AutoReboot=0.
$PROC_PAT  = '(?i)^(csrss|consent|winlogon|msiexec|drvinst|rundll32)$'

function Get-Candidates {
    $hits = @()
    foreach ($w in [Win32Enum]::Top()) {
        $handle = $w[0]; $class = $w[1]; $title = $w[2]; $vis = ($w[3] -eq '1'); $wpid = $w[4]
        $pname = $null
        try { $pname = (Get-Process -Id ([int]$wpid) -ErrorAction Stop).ProcessName } catch { $pname = '?' }
        $titleHit = ($title -and $title -match $TITLE_PAT)
        $classHit = ($class -match $CLASS_PAT -and $title)
        $procHit  = ($pname -match $PROC_PAT -and $title -and $vis)
        if ($titleHit -or ($classHit -and $procHit)) {
            $hits += [ordered]@{
                handle = $handle; class = $class; title = $title
                visible = $vis; pid = $wpid; process = $pname
                matched = @(@{n='title';v=$titleHit},@{n='class';v=$classHit},@{n='proc';v=$procHit} |
                            Where-Object { $_.v } | ForEach-Object { $_.n }) -join '+'
                # WHAT IT ASKS, not just that it exists.
                text = @([Win32Enum]::ChildText([IntPtr]::new([int64]$handle)))
            }
        }
    }
    return $hits
}

# The MECHANISM behind the dialog, sampled alongside it.
function Get-XenbusState {
    $s = [ordered]@{ request_keys = @(); auto_reboot = $null; monitor_start = $null; monitor_running = $null }
    try {
        $root = 'HKLM:\SOFTWARE\Citrix\XenToolsMonitor'
        $req  = 'HKLM:\SYSTEM\CurrentControlSet\Services\xenbus_monitor\Request'
        foreach ($p in @($req, 'HKLM:\SOFTWARE\Xen\XenBusMonitor\Request')) {
            if (Test-Path $p) {
                $s.request_keys += @{ path = $p; children = @((Get-ChildItem $p -ErrorAction SilentlyContinue).PSChildName) }
            }
        }
        foreach ($p in @($root, 'HKLM:\SOFTWARE\Xen\XenBusMonitor')) {
            $v = Get-ItemProperty -LiteralPath $p -Name 'AutoReboot' -ErrorAction SilentlyContinue
            if ($v) { $s.auto_reboot = $v.AutoReboot }
        }
        $svc = Get-Service -Name 'xenbus_monitor' -ErrorAction SilentlyContinue
        if ($svc) { $s.monitor_running = [string]$svc.Status }
        $k = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\xenbus_monitor' -ErrorAction SilentlyContinue
        if ($k) { $s.monitor_start = $k.Start }
        # The monitor as a PROCESS, which is not the same as the service (81d2b79: killing the
        # service left the process running, and the process is what acted).
        $s.monitor_proc = @(Get-Process -ErrorAction SilentlyContinue |
                            Where-Object { $_.ProcessName -match '(?i)xenbus_monitor' } |
                            ForEach-Object { $_.Id })
    } catch {}
    return $s
}

# Can this vantage point see interactive windows AT ALL? A session-0 service cannot, and would
# otherwise report a clean run it was never able to observe.
function Test-Blind {
    try {
        $sid = (Get-Process -Id $PID).SessionId
        $n   = ([Win32Enum]::Top()).Count
        # Session 0 with no windows, or an enumeration that returns almost nothing, is blind.
        return @{ blind = ($sid -eq 0 -or $n -lt 5); session = $sid; toplevel_count = $n }
    } catch { return @{ blind = $true; session = -1; toplevel_count = -1 } }
}

$stamp = { (Get-Date).ToUniversalTime().ToString('o') }

# ---------------------------------------------------------------------------------------------
if ($Summary) {
    if (-not (Test-Path $OutFile)) {
        Write-Output ('=== REBOOTWATCH === ' + (@{ ok=$false; reason='no log at ' + $OutFile } | ConvertTo-Json -Compress))
        exit 1
    }
    $recs = @(Get-Content -LiteralPath $OutFile | ForEach-Object {
        try { $_ | ConvertFrom-Json } catch { $null } } | Where-Object { $_ })
    $samples  = @($recs | Where-Object { $_.kind -eq 'sample' -and -not $_.injected })
    $hits     = @($samples | Where-Object { $_.hits.Count -gt 0 })
    $blind    = @($samples | Where-Object { $_.blind })

    # Coverage: absence only counts over the interval we can prove we were looking.
    $gaps = @()
    for ($i = 1; $i -lt $samples.Count; $i++) {
        $dt = ([datetime]$samples[$i].t - [datetime]$samples[$i-1].t).TotalSeconds
        if ($dt -gt ($IntervalSeconds * 3)) {
            $gaps += @{ after = $samples[$i-1].t; before = $samples[$i].t; seconds = [math]::Round($dt,1) }
        }
    }
    $ok = ($samples.Count -gt 0) -and ($hits.Count -eq 0) -and ($blind.Count -eq 0) -and ($gaps.Count -eq 0)

    # Computed as statements, not as inline if-expressions inside the hashtable literal: the guest
    # runs Windows PowerShell 5.1 and this file must parse there, not only under pwsh 7.
    $first = $null; $last = $null
    if ($samples.Count -gt 0) { $first = $samples[0].t; $last = $samples[$samples.Count - 1].t }

    # Say plainly why a false verdict is false, so nobody has to infer it.
    $reason = 'clean: continuous coverage, no dialog, no blind samples'
    if     ($samples.Count -eq 0) { $reason = 'NO SAMPLES - the watcher never ran; this is not a clean result' }
    elseif ($blind.Count -gt 0)   { $reason = 'BLIND samples present - ran where interactive windows are invisible' }
    elseif ($gaps.Count -gt 0)    { $reason = 'COVERAGE GAPS - unwatched intervals, a dialog could have come and gone' }
    elseif ($hits.Count -gt 0)    { $reason = 'DIALOG OBSERVED' }

    $out = [ordered]@{
        ok                = $ok
        samples           = $samples.Count
        dialogs_seen      = $hits.Count
        dialog_records    = @($hits | Select-Object -First 10)
        blind_samples     = $blind.Count
        coverage_gaps     = $gaps
        first             = $first
        last              = $last
        reason            = $reason
    }
    Write-Output ('=== REBOOTWATCH === ' + ($out | ConvertTo-Json -Compress -Depth 6))
    if ($ok) { exit 0 } else { exit 1 }
}

# ---------------------------------------------------------------------------------------------
if ($SelfTest) {
    # Prove the detector FIRES. Separate file, every record tagged injected=true, so this can
    # never be mistaken for an observation of the real thing.
    $OutFile = [IO.Path]::ChangeExtension($OutFile, '.selftest.jsonl')
    $dir = Split-Path $OutFile -Parent
    # Split-Path of 'C:\rbw.jsonl' is 'C:\', and New-Item -ItemType Directory on a DRIVE ROOT
    # throws InvalidArgument. Measured on win10-u10 2026-08-29 - the self-test died here before
    # it could prove anything, which is exactly what a self-test is for.
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Remove-Item -LiteralPath $OutFile -ErrorAction SilentlyContinue

    Add-Type -AssemblyName System.Windows.Forms
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'You must restart your computer to apply these changes'
    $form.Show(); [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 400

    $hits = Get-Candidates
    $rec = [ordered]@{ kind='sample'; t=(& $stamp); injected=$true
                       hits=$hits; xenbus=(Get-XenbusState); blind=$false
                       note='SELF-TEST: decoy window created by this script' }
    Add-Content -LiteralPath $OutFile -Value ($rec | ConvertTo-Json -Compress -Depth 6)
    $form.Close(); $form.Dispose()

    $fired = ($hits.Count -gt 0)
    Write-Output ('=== REBOOTWATCH-SELFTEST === ' +
        (@{ detector_fires = $fired; matched = @($hits | ForEach-Object { $_.title })
            file = $OutFile } | ConvertTo-Json -Compress -Depth 5))
    if ($fired) { exit 0 } else { exit 1 }   # cannot be trusted if it did not fire
}

# ---------------------------------------------------------------------------------------------
# Sampling run.
$dir = Split-Path $OutFile -Parent
# Split-Path of 'C:\rbw.jsonl' is 'C:\', and New-Item -ItemType Directory on a DRIVE ROOT
# throws InvalidArgument. Measured on win10-u10 2026-08-29 - the self-test died here before
# it could prove anything, which is exactly what a self-test is for.
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
$vantage = Test-Blind
Add-Content -LiteralPath $OutFile -Value ([ordered]@{
    kind='start'; t=(& $stamp); interval=$IntervalSeconds; duration=$DurationSeconds
    session=$vantage.session; blind=$vantage.blind; toplevel_count=$vantage.toplevel_count
    pid=$PID } | ConvertTo-Json -Compress)

$deadline = (Get-Date).AddSeconds($DurationSeconds)
while ((Get-Date) -lt $deadline) {
    $v = Test-Blind
    $rec = [ordered]@{
        kind    = 'sample'
        t       = (& $stamp)
        blind   = $v.blind
        session = $v.session
        hits    = @(Get-Candidates)
        xenbus  = (Get-XenbusState)
    }
    Add-Content -LiteralPath $OutFile -Value ($rec | ConvertTo-Json -Compress -Depth 6)
    Start-Sleep -Seconds $IntervalSeconds
}
Add-Content -LiteralPath $OutFile -Value ([ordered]@{ kind='stop'; t=(& $stamp) } | ConvertTo-Json -Compress)
