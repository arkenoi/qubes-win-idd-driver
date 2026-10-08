# uac-startup-sample.ps1 - DOES A NORMAL STARTUP RAISE AN ELEVATION PROMPT AT ALL?
#
# Jev's named decisive measurement for the owner's question of 2026-10-08 ("so we DO have elevation
# on startup that suddenly becomes interactive when UAC is on?"): a UAC-ON startup cell, graded on
# whether any consent.exe appears at all - `uac-on-startup-cell` 0.81 at confidence 0.76. The source
# sweep says nothing of ours elevates on that path (docs/ADR-uac.md section 10), and Jev would not
# clear us on it: no-startup-elevation 0.49 against the MSI advertised-shortcut residual 0.39, at
# confidence 0.32. This closes that by measurement instead of by reading.
#
# WHY THE PROCESS LIST AND NOT THE WINDOWS. This runs as SYSTEM from an ONSTART task, which lives in
# SESSION 0: EnumWindows there enumerates session 0's desktop and would never see the user session's
# windows, so a window-based probe would return "nothing" on a guest that had a prompt up the whole
# time - a check that cannot fail. The process list is global and is the necessary condition: no
# consent.exe, no prompt. Windows are sampled only when this runs in a user session (-WindowScan),
# and it says which of the two it did.
#
# THE TRAP THIS INHERITS (findings/autologon.md): a RUNNING consent.exe is not by itself evidence a
# prompt is SHOWN - it also runs under ConsentPromptBehaviorAdmin=0 and exits by itself after ~4 s.
# So every sighting is recorded with its start time and its lifetime, and the summary separates a
# short-lived consent.exe from one that PERSISTS. The question here is the weaker one ("does any
# appear at all"), and a zero answer settles it outright.
#
# Validated in both directions: driven with a deliberate user-session elevation it must record the
# sighting (uac-elev-trigger.ps1); on a UAC-OFF guest the same trigger produces none, which is the
# control that shows the guest - not the instrument - is what differs.
[CmdletBinding()]
param(
    [int]    $Seconds = 180,
    [string] $Tag = 'boot',
    [double] $IntervalMs = 500,
    [switch] $WindowScan,
    [string] $Out
)

$ErrorActionPreference = 'Continue'

if (-not $Out) {
    $dir = 'Q:\Qubes Logs'
    if (-not (Test-Path -LiteralPath $dir)) { $dir = $env:SystemDrive + '\' }
    $Out = Join-Path $dir ("uac-sample-{0}.csv" -f $Tag)
}

# WATCHED: every process that can be part of an elevation, plus the two phase markers. consent.exe
# is the prompt itself; msiexec is the only mechanism in our package that can ask for one without a
# user (the advertised-shortcut residual); explorer and logonui say which phase of startup we are in,
# so a sighting can be placed on the timeline rather than merely counted.
$watch = @('consent', 'msiexec', 'explorer', 'LogonUI', 'winlogon')
$STANDIN = '$$$Secure UAP Dummy Window Class For Interim Dialog'

if ($WindowScan) {
    $src = @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class UacWinScan {
    delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    public static string Scan(string cls) {
        List<string> hits = new List<string>();
        EnumWindows(delegate(IntPtr h, IntPtr p) {
            StringBuilder sb = new StringBuilder(512);
            GetClassName(h, sb, sb.Capacity);
            if (sb.ToString() == cls) {
                uint pid; GetWindowThreadProcessId(h, out pid);
                hits.Add(String.Format("{0:X}/pid{1}/vis{2}", h.ToInt64(), pid, IsWindowVisible(h) ? 1 : 0));
            }
            return true;
        }, IntPtr.Zero);
        return String.Join(" ", hits.ToArray());
    }
}
'@
    try { Add-Type -TypeDefinition $src -Language CSharp -ErrorAction Stop }
    catch { $WindowScan = $false; $windowScanError = $_.Exception.Message }
}

# A FRESH FILE PER RUN, so a check can never fire on the previous run's sighting (experimenter rule
# 14). The header records the conditions the result has to be read against - a sample taken with
# EnableLUA=0 answers nothing about a UAC-ON guest, and that is the whole point of the cell.
$lua = $null; $cpba = $null; $pos = $null; $aam = $null
try {
    $k = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction Stop
    $lua = $k.EnableLUA; $cpba = $k.ConsentPromptBehaviorAdmin
    $pos = $k.PromptOnSecureDesktop; $aam = $k.TypeOfAdminApprovalMode
} catch { }

$session = -1
try { $session = (Get-Process -Id $PID).SessionId } catch { }
$boot = $null
try { $boot = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime } catch { }

$head = @()
$head += "# uac-startup-sample tag=$Tag seconds=$Seconds interval_ms=$IntervalMs"
$head += "# started=$((Get-Date).ToString('o')) lastboot=$(if ($boot) { $boot.ToString('o') } else { 'unknown' })"
$head += "# whoami=$([Security.Principal.WindowsIdentity]::GetCurrent().Name) session=$session pid=$PID"
$head += "# EnableLUA=$lua ConsentPromptBehaviorAdmin=$cpba PromptOnSecureDesktop=$pos TypeOfAdminApprovalMode=$aam"
$head += "# build=$([Environment]::OSVersion.Version.Build) windowscan=$([int][bool]$WindowScan)$(if ($windowScanError) { " (unavailable: $windowScanError)" })"
$head += "# NOTE: session 0 cannot see the user session's windows - a window scan from SYSTEM is meaningless"
$head += "ts_iso,uptime_s,consent,msiexec,explorer,LogonUI,winlogon,standin_windows"
Set-Content -LiteralPath $Out -Value $head -Encoding ASCII

$deadline = (Get-Date).AddSeconds($Seconds)
$samples = 0
$consentSeen = 0
$consentFirst = $null
$consentLast = $null
$consentPids = New-Object 'System.Collections.Generic.HashSet[string]'
$consentDetail = @()
$msiSeen = 0
$msiPids = New-Object 'System.Collections.Generic.HashSet[string]'
$standinSeen = 0
$prev = $null

while ((Get-Date) -lt $deadline) {
    $samples++
    $now = Get-Date
    $cells = @()
    $procs = @{}
    foreach ($name in $watch) {
        $p = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
        $procs[$name] = $p
        if ($p.Count -eq 0) { $cells += '-' }
        else { $cells += (($p | ForEach-Object { $_.Id }) -join '+') }
    }

    foreach ($p in $procs['consent']) {
        $consentSeen++
        if (-not $consentFirst) { $consentFirst = $now }
        $consentLast = $now
        $st = $null
        try { $st = $p.StartTime } catch { }
        if ($consentPids.Add([string]$p.Id)) {
            $consentDetail += ("pid={0} first_seen={1} start={2}" -f $p.Id, $now.ToString('o'),
                               $(if ($st) { $st.ToString('o') } else { 'unreadable' }))
        }
    }
    foreach ($p in $procs['msiexec']) { $msiSeen++; [void]$msiPids.Add([string]$p.Id) }

    $sw = '-'
    if ($WindowScan) {
        try { $hits = [UacWinScan]::Scan($STANDIN) } catch { $hits = '' }
        if ($hits) { $sw = $hits.Replace(',', ';'); $standinSeen++ }
    }

    $up = if ($boot) { [math]::Round(($now - $boot).TotalSeconds, 1) } else { -1 }
    $line = ('{0},{1},{2},{3}' -f $now.ToString('o'), $up, ($cells -join ','), $sw)

    # WRITE A CHANGE, NOT A HEARTBEAT: one line per changed state plus one every 20th sample, so the
    # file stays readable over three minutes without losing a single transition.
    $state = ($cells -join ',') + '|' + $sw
    if ($state -ne $prev -or ($samples % 20) -eq 0 -or $samples -eq 1) {
        Add-Content -LiteralPath $Out -Value $line -Encoding ASCII
        $prev = $state
    }
    Start-Sleep -Milliseconds $IntervalMs
}

$sum = @()
$sum += '# ---- SUMMARY ----'
$sum += "# ended=$((Get-Date).ToString('o')) samples=$samples"
$sum += "# CONSENT_SIGHTINGS=$consentSeen distinct_pids=$($consentPids.Count)"
if ($consentFirst) {
    $sum += ("# consent first={0} last={1} span_s={2}" -f $consentFirst.ToString('o'),
             $consentLast.ToString('o'), [math]::Round(($consentLast - $consentFirst).TotalSeconds, 1))
    foreach ($d in $consentDetail) { $sum += "# $d" }
    $sum += "# NOTE: a consent.exe alive for only a few seconds is NOT evidence a prompt was shown (CPBA=0 runs one too); a PERSISTING one is."
} else {
    $sum += '# consent: NONE AT ANY SAMPLE'
}
$sum += "# MSIEXEC_SIGHTINGS=$msiSeen distinct_pids=$($msiPids.Count)"
$sum += "# STANDIN_WINDOW_SAMPLES=$standinSeen (window scan $(if ($WindowScan) { 'ran' } else { 'DID NOT RUN - no verdict from windows' }))"
$sum += "# VERDICT_INPUT: consent=$(if ($consentSeen) { 'SEEN' } else { 'none' }) msiexec=$(if ($msiSeen) { 'SEEN' } else { 'none' }) standin=$(if ($standinSeen) { 'SEEN' } else { 'none' })"
Add-Content -LiteralPath $Out -Value $sum -Encoding ASCII

Write-Output ($sum -join "`n")
Write-Output "SAMPLE_FILE=$Out"
