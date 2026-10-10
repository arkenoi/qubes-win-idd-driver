# log-sweep-collect.ps1 - the PROACTIVE LOG SWEEP's GUEST-SIDE COLLECTOR (mgmt/harness/log-sweep.sh; the
# analyzer is tools/log-sweep.py). Lives under mgmt/harness/, NOT guest/: guest/*.ps1 may be staged into the
# shipped package, and this is rig instrumentation.
#
# Runs as SYSTEM over qubes.VMShell:
#   tools/qtest pushrun mgmt/harness/log-sweep-collect.ps1 -SinceUtc 2026-10-07T08:00:00Z
#
# WHAT IT GATHERS (every log of ours modified since -SinceUtc, read with FileShare.ReadWrite because the agent,
# the watchdog and the bridge hold theirs open):
#   * everything under the configured LogDir (registry LogDir, normally Q:\Qubes Logs - memory gui-agent-log-location):
#     gui-agent-*, gui-watchdog-*, qrexec-*, qubesdb-*, etw-proxy.log, file-receiver / network-setup / relocate-dir /
#     set-gui-mode / qwtng-netsetup logs, bind-dirs, the module-bases and reboot-audit records - recursively;
#     the NEWEST gui-watchdog and gui-agent logs are always included so the boot's launch lines are present;
#   * bridge.log (+ .old) - under LogDir since 7e349bac, which is why it is in the first bullet now;
#     C:\ProgramData\qubes-toast-bridge stays in $StrayLogDirs only to pick up a pre-7e349bac copy
#     left on an upgraded guest, and holds the bridge's CONTROL surfaces (stop file, heartbeat,
#     banner markers), which are not logs;
#   * EVERY OTHER LOG OF OURS OUTSIDE LogDir - the updater's C:\ProgramData\Qubes\wu\*.log (relay,
#     relay-handler, agent), C:\ProgramData\QubesPvNic.log, QubesNetSetup.log, QubesIDD-diag.log, and
#     the C:\ root's qubes-*/qwt-*/relocate-dir-* logs. Eight of these were read by NOTHING until
#     2026-10-07, so the gate had never seen the update path, the PV NIC or the display driver;
#   * the installer's logs: C:\qwt-improved-install.log (Install-QwtImproved.ps1 Write-Log), C:\qwt-install.log and
#     C:\qwt-uninstall.log (msiexec /l*v, UTF-16 - re-encoded as UTF-8 here);
#   * Windows event records since -SinceUtc, pre-filtered to what the sweep reads (docs/ADR-supervision.md):
#     Application: our source 'Qubes Windows Tools' (4001-4004), 1000/1001/1026 naming our executables;
#     System: 7000/7009/7011/7023/7024/7031/7034/7036/7040/7043/7045 naming our services, the boot and shutdown markers
#     (1074/1076, 13, 12 Kernel-General, 6005/6006/6008/6009/6013, Kernel-Power 41/109, BugCheck 1001);
#     TerminalServices-LocalSessionManager/Operational 21-25/54 (logon, logoff, "received system shutdown message");
#     TaskScheduler/Operational 201/203 naming our tasks (the channel is optional: client Windows ships it disabled).
#
# OUTPUT: one stream the rig DECODES AND VERIFIES (the proven transfer shape of the toast-hold harness - trust
# counts, not streams). Every line the harness reads starts with 'LSW ' - a marker that never appears on the
# command line qtest echoes back (the a0-lib self-match lesson). Paths and other values that may contain spaces
# travel base64-encoded (pathb64=).
#   LSW BEGIN v=1 now=<local yyyy-MM-ddTHH:mm:ss.fff> nowutc=<...Z> tz=<+hh:mm> host=<b64> user=<b64> session=<n> since=<utc> sincelocal=<local>
#   LSW LOGDIR pathb64=<b64> exists=<0|1>
#   LSW FILE id=f<n> pathb64=<b64> family=<hint> bytes=<n> lines=<n> written=<local> created=<local> partial=<0|1> total_lines=<n>
#   LSW PULL name=f<n> lines=<count> bytes=<utf8 bytes> sha256=<hex> b64lines=<m>
#   LSW B|<76 base64 chars>  (m lines)
#   LSW PULLEND name=f<n> b64lines=<m>
#   LSW FILEERR pathb64=<b64> error=<b64>            a log that exists but could not be read - the analyzer FAILS on it
#   LSW FILESKIPPED n=<k>                            more files than -MaxFiles: the oldest were not pulled (INCOMPLETE)
#   LSW EVENTS channels=<n> required_missing=<list|->
#   LSW PULL name=events ... (the EV block)
#   LSW END files=<n> pulled=<n> errors=<n> event_errors=<n>
# Event block lines:  EV yyyy-MM-dd HH:mm:ss.fff [LogName] id=<n> level=<n> <Provider>: <message, newlines -> ' / '>
#                     EV NONE [LogName]  (channel readable, nothing matched)   EV ERR [LogName] <why>  (channel unreadable)
#
# A file over -MaxLines / -MaxBytes is NOT silently truncated: its head, every W/E/suspicious line and its tail are
# sent with partial=1 and the true line count, and the analyzer marks the sweep INCOMPLETE (the content is still
# analysed - a log that large is itself a finding).
param(
    [Parameter(Mandatory = $true)][string]$SinceUtc,
    [int]$MaxLines = 30000,
    [int]$MaxBytes = 6291456,
    [int]$MaxFiles = 60,
    [switch]$NoEvents
)
$ErrorActionPreference = 'Continue'
$Mark = 'LSW '
$BridgeDir = 'C:\ProgramData\qubes-toast-bridge'
$InstallerLogs = @('C:\qwt-improved-install.log', 'C:\qwt-install.log', 'C:\qwt-uninstall.log')

# EVERY LOG OF OURS THAT IS NOT UNDER LogDir. MEASURED on a German 25H2 guest 2026-10-07, after an
# install and three boots: 386 logs under Q:\Qubes Logs and TWELVE outside it, of which EIGHT were
# collected by nothing - so the error gate had never read a line of them. They are not minor files:
#   C:\ProgramData\Qubes\wu\qubes-updates-relay.log   67 KB   the whole dom0-driven update path
#   C:\ProgramData\Qubes\wu\relay-handler.log         66 KB
#   C:\ProgramData\Qubes\wu\agent.log                          the updater agent
#   C:\ProgramData\QubesPvNic.log                               the PV NIC - and qwt-report-death's
#       own impact text tells the user "its log (C:\ProgramData\QubesPvNic.log) names the step",
#       pointing at a file the gate did not read
#   C:\ProgramData\QubesNetSetup.log
#   C:\ProgramData\QubesIDD-diag.log                            the display driver
#   C:\qubes-win-idd-setup.log, C:\qubes-de-firstlogon.log, C:\relocate-dir-*.log
# A clean error log is the gate condition, and a gate that reads some of the logs is not a gate.
# THE REAL FIX IS ONE LOCATION - the writers belong under LogDir and are being moved there (BLog
# went first, 7e349bac). This list closes the hole meanwhile, and keeps working for guests that
# still carry the old paths. Owner: "keep logs in single place, sweep them together".
$StrayLogDirs = @('C:\ProgramData', 'C:\ProgramData\Qubes', 'C:\ProgramData\Qubes\wu')
$StrayLogRootFiles = @('C:\qubes-win-idd-setup.log', 'C:\qubes-de-firstlogon.log')
$StrayLogRootGlobs = @('relocate-dir-*.log', 'qubes-*.log', 'qwt-*.log')
$StrayLogRx = '(?i)^(Qubes[A-Za-z]*(-[A-Za-z]+)?|qubes-[a-z-]+|qwt-[a-z-]+|agent|relay-handler|dism[a-z-]*|vmexec|vmupdate-shim)\.log$'
$OurExeRx = '(?i)\b(gui-agent|gui-watchdog|wgcbroker|notifhost|etwproxy|qrexec-agent|qrexec-wrapper|qrexec-client-vm|qubesdb-daemon|qwtng-netsetup|network-setup|relocate-dir|set-gui-mode|file-receiver|qubes-updates-relay|disable-autosleep|toastfire|winid|bind-dirs)(\.exe)?\b'
$OurSvcRx = '(?i)(QdbDaemon|QrexecAgent|QubesGuiWatchdog|QgaWatchdog|QwtngNetSetup|Qubes [A-Za-z ]*(DB|qrexec|GUI|PV NIC)|Qubes Windows Tools)'
$OurTaskRx = '(?i)\\?(Qwt[A-Za-z]+|Qubes[A-Za-z]+)'
# the lines a PARTIAL pull keeps besides head and tail (mirrors the analyzer's selection)
$KeepRx = '-[WE]\] |(?i)\b(died|death|relaunch|restart|crash|fallback|falls back|timed out|timeout|refus|stuck|hung|LOST|ANOMALY|A6LEAK|QGAHANDSHAKE|vchan client|disconnect|not running|going down|exited with code|is gone|to exit|preshutdown|terminat|backing off|exiting)\b|\[(WARN|ERROR|FATAL)\]|=== RESULT ===|FAIL|CRASH|WARN'

function Get-LswB64([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return '-' }
    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($s))
}
function Get-LswStamp([datetime]$d) { return $d.ToString('yyyy-MM-ddTHH:mm:ss.fff') }

function Get-LswLogDir {
    $r = Get-ItemProperty 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -ErrorAction SilentlyContinue
    if ($r -and $r.LogDir) { return [string]$r.LogDir }
    if (Test-Path -LiteralPath 'Q:\Qubes Logs') { return 'Q:\Qubes Logs' }
    return 'C:\Program Files\Qubes Tools\log'
}

# FileShare.ReadWrite: the writers hold their logs open. detectEncodingFromByteOrderMarks: the msiexec logs are UTF-16.
function Read-LswLines([string]$path) {
    $out = New-Object 'System.Collections.Generic.List[string]'
    $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $true)
        try { while ($null -ne ($l = $sr.ReadLine())) { $out.Add($l) } } finally { $sr.Dispose() }
    } finally { $fs.Dispose() }
    return ,$out
}

function Write-LswBlock([string]$name, $lines) {
    $arr = @($lines)
    $text = [string]::Join("`n", $arr)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    $sha = [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)).Replace('-', '').ToLower()
    $b64 = [Convert]::ToBase64String($bytes)
    $m = [int][math]::Ceiling($b64.Length / 76.0)
    $outl = New-Object 'System.Collections.Generic.List[string]'
    $outl.Add("${Mark}PULL name=$name lines=$($arr.Count) bytes=$($bytes.Length) sha256=$sha b64lines=$m")
    for ($i = 0; $i -lt $b64.Length; $i += 76) {
        $outl.Add($Mark + 'B|' + $b64.Substring($i, [math]::Min(76, $b64.Length - $i)))
    }
    $outl.Add("${Mark}PULLEND name=$name b64lines=$m")
    Write-Output $outl.ToArray()
}

function Get-LswFamily([string]$name) {
    if ($name -match '^(?i)gui-agent-') { return 'agent' }
    if ($name -match '^(?i)gui-watchdog-') { return 'watchdog' }
    if ($name -match '^(?i)qrexec-(agent|wrapper|client-vm)-') { return 'qrexec' }
    if ($name -match '^(?i)qubesdb-daemon-') { return 'qubesdb' }
    if ($name -match '^(?i)etw-proxy\.log') { return 'etwproxy' }
    if ($name -match '^(?i)bridge\.log') { return 'bridge' }
    if ($name -match '^(?i)qwt-improved-install\.log$') { return 'installer' }
    if ($name -match '^(?i)qwt-(un)?install\.log$') { return 'msi' }
    if ($name -match '^(?i)bind-dirs') { return 'binddirs' }
    if ($name -match '^(?i)qwt-fi-') { return 'marker' }
    return 'auto'
}

# ---- since -------------------------------------------------------------------------------------------------------
$styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
$sinceU = [datetime]::Parse($SinceUtc, [System.Globalization.CultureInfo]::InvariantCulture, $styles)
$sinceL = $sinceU.ToLocalTime()
$nowL = Get-Date
$nowU = $nowL.ToUniversalTime()
$tz = [TimeZoneInfo]::Local.GetUtcOffset($nowL)
$tzs = ('{0}{1:00}:{2:00}' -f $(if ($tz.Ticks -lt 0) { '-' } else { '+' }), [math]::Abs($tz.Hours), [math]::Abs($tz.Minutes))
$ident = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$sess = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
Write-Output ("${Mark}BEGIN v=1 now=$(Get-LswStamp $nowL) nowutc=$($nowU.ToString('yyyy-MM-ddTHH:mm:ss.fff'))Z tz=$tzs host=$(Get-LswB64 $env:COMPUTERNAME) user=$(Get-LswB64 $ident) session=$sess since=$($sinceU.ToString('yyyy-MM-ddTHH:mm:ss'))Z sincelocal=$(Get-LswStamp $sinceL)")

# ---- the file set ------------------------------------------------------------------------------------------------
$logDir = Get-LswLogDir
$dirExists = Test-Path -LiteralPath $logDir
Write-Output ("${Mark}LOGDIR pathb64=$(Get-LswB64 $logDir) exists=$(if ($dirExists) { 1 } else { 0 })")
$cands = New-Object 'System.Collections.Generic.List[object]'
if ($dirExists) {
    $all = @(Get-ChildItem -LiteralPath $logDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(log|txt|json|old)$' })
    $newestWd = @($all | Where-Object { $_.Name -match '^(?i)gui-watchdog-' } | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
    $newestAg = @($all | Where-Object { $_.Name -match '^(?i)gui-agent-' } | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
    foreach ($f in $all) {
        $always = ($newestWd.Count -gt 0 -and $f.FullName -eq $newestWd[0].FullName) -or ($newestAg.Count -gt 0 -and $f.FullName -eq $newestAg[0].FullName)
        if ($f.LastWriteTimeUtc -ge $sinceU -or $always) { $cands.Add($f) }
    }
}
# C:\Users\Public\qwt-fi-*.txt: the knob files a fault-injection broker build reads (wgcbroker.cpp FiDeafHwnd) - their presence is
# in-capture evidence of an injection; the analyzer keeps them as 'marker' files, never as a log.
$fiKnobs = @(Get-ChildItem -LiteralPath 'C:\Users\Public' -Filter 'qwt-fi-*.txt' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
# the stray logs enumerated above: only OUR names (StrayLogRx) from those directories, so a
# third-party log in C:\ProgramData is never pulled off the guest
$strays = [System.Collections.Generic.List[string]]::new()
foreach ($d in $StrayLogDirs) {
    if (-not (Test-Path -LiteralPath $d)) { continue }
    foreach ($f in (Get-ChildItem -LiteralPath $d -Filter *.log -File -ErrorAction SilentlyContinue)) {
        if ($f.Name -match $StrayLogRx) { $strays.Add($f.FullName) }
    }
}
foreach ($g in $StrayLogRootGlobs) {
    foreach ($f in (Get-ChildItem -LiteralPath 'C:\' -Filter $g -File -ErrorAction SilentlyContinue)) {
        if ($f.Name -match $StrayLogRx) { $strays.Add($f.FullName) }
    }
}
foreach ($p in @((Join-Path $BridgeDir 'bridge.log'), (Join-Path $BridgeDir 'bridge.log.old')) + $InstallerLogs + $StrayLogRootFiles + @($strays) + $fiKnobs) {
    if (Test-Path -LiteralPath $p) {
        $f = Get-Item -LiteralPath $p -ErrorAction SilentlyContinue
        if ($f -and $f.LastWriteTimeUtc -ge $sinceU) { $cands.Add($f) }
    }
}
# THE CAP MUST NAME WHAT IT DROPS, AND NEVER DROP A LOG THAT CARRIES A VERDICT (2026-10-07).
# It reported a COUNT only - "skipped n=5" - so after the lifecycle retest nothing could say whether an agent or
# watchdog log had been left behind, and "zero deaths" had to be established by cross-referencing pids instead of
# being read off. A count is not missing-data reporting; the names are.
# And the ORDER matters more than the count: the families that decide a verdict (the agent, its watchdog, the
# installer, our event log) are pulled FIRST, so a cap can only ever cost the chatty ones (qrexec-wrapper, qubesdb).
$verdictFirst = { param($f)
    switch -Regex ($f.Name) {
        '^gui-agent-'    { 0 }
        '^gui-watchdog-' { 1 }
        '^qwt-.*install' { 2 }
        'bridge\.log'    { 3 }
        '^etwproxy'      { 4 }
        # THE SOLE RECORD OF A WHOLE SUBSYSTEM IS NEVER CHATTY. These live outside LogDir, so each
        # is the ONLY log its subsystem has: the dom0-driven update path (relay, relay-handler,
        # agent), the PV NIC, the network setup, the display driver, and the first-boot/setup logs
        # at the root of C:. Measured 2026-10-07: added to the candidate list, they ranked `default`
        # and the 60-file cap - contested by 386 logs under LogDir - dropped them, so a WIDER window
        # returned FEWER of them than a narrow one. A cap that can cost the evidence is a cap on the
        # evidence, which is what the note below already says about the watchdog family.
        # qwt-deaths.log IS THE RECORD OF EVERY DEATH NOTIFIED TO dom0, including the one the owner
        # saw on his screen ("The Windows Update scan task failed"). Measured 2026-10-07: it ranked
        # `default` and the cap DROPPED IT, because 368 qrexec-wrapper logs - one file per qrexec
        # call - won the contest. The sweep could have reported on a run while discarding the list
        # of what died in it. Same for the reboot audit and bind-dirs: one small file each, and the
        # only record of their subject.
        '^qwt-deaths\.log$'           { 2 }
        '^reboot-audit\.log$'         { 5 }
        '^bind-dirs(\.prev)?\.log$'   { 5 }
        '^qubes-updates-relay\.log$'  { 5 }
        '^relay-handler\.log$'        { 5 }
        '^agent\.log$'                { 5 }
        '^QubesPvNic\.log$'           { 5 }
        '^QubesNetSetup\.log$'        { 5 }
        '^QubesIDD-diag\.log$'        { 5 }
        # VMExec's audit moved out of C:\ProgramData\Qubes and into LogDir, where rank 9 stops
        # meaning "always collected" and starts contesting the whole module population - the exact
        # mechanism described above, which once dropped qwt-deaths.log. This audit is how a non-zero
        # step code in a dom0-driven update is attributed to the step that produced it; dom0 keeps
        # code = max(all step codes) and does not say which step it was.
        '^(VMExec\.ps1-\d{8}|vmexec)\.log$' { 5 }
        '^qubes-win-idd-setup\.log$'  { 5 }
        '^qubes-de-firstlogon\.log$'  { 5 }
        '^relocate-dir-'               { 5 }
        default          { 9 }
    }
}
# A VERDICT-DECIDING LOG IS NEVER DROPPED - the cap falls ENTIRELY on the chatty families. Ordering them first was
# not enough: measured 2026-10-07 on the toast run, the budget ran out INSIDE the watchdog family and three watchdog
# logs went missing, so the sweep could say nothing about that boot's agents. A cap that can cost the evidence is a
# cap on the evidence. The chatty families (qrexec-wrapper, qubesdb, file-receiver) are what it may cut, newest first.
$verdict = @($cands | Where-Object { (& $verdictFirst $_) -lt 9 } | Sort-Object LastWriteTimeUtc -Descending)
$chatty  = @($cands | Where-Object { (& $verdictFirst $_) -eq 9 } | Sort-Object LastWriteTimeUtc -Descending)
$skipped = 0
$skippedNames = @()
$budget = $MaxFiles - $verdict.Count
if ($budget -lt 0) {
    # More verdict logs than the whole cap: pull them all anyway and say so loudly. Dropping them would make every
    # metric computed from them unsound, which is worse than a long pull.
    Write-Output ("${Mark}CAPRAISED verdict=$($verdict.Count) cap=$MaxFiles - the cap is raised to keep every agent/watchdog/installer log")
    $sorted = @($verdict)
    $skipped = $chatty.Count
    $skippedNames = @($chatty | ForEach-Object { $_.Name })
} else {
    $keepChatty = @($chatty | Select-Object -First $budget)
    $dropped = @($chatty | Select-Object -Skip $budget)
    $skipped = $dropped.Count
    $skippedNames = @($dropped | ForEach-Object { $_.Name })
    $sorted = @($verdict) + @($keepChatty)
}

# ---- pull every file ---------------------------------------------------------------------------------------------
$n = 0; $pulled = 0; $errors = 0
foreach ($f in $sorted) {
    $n++
    $id = "f$n"
    try {
        $lines = Read-LswLines $f.FullName
        $total = $lines.Count
        $partial = 0
        if ($total -gt $MaxLines -or $f.Length -gt $MaxBytes) {
            $partial = 1
            $kept = New-Object 'System.Collections.Generic.List[string]'
            $head = [math]::Min(300, $total)
            $tailStart = [math]::Max($head, $total - 3000)
            for ($i = 0; $i -lt $total; $i++) {
                if ($i -lt $head -or $i -ge $tailStart -or $lines[$i] -match $KeepRx) { $kept.Add($lines[$i]) }
            }
            $lines = $kept
        }
        Write-Output ("${Mark}FILE id=$id pathb64=$(Get-LswB64 $f.FullName) family=$(Get-LswFamily $f.Name) bytes=$($f.Length) lines=$($lines.Count) written=$(Get-LswStamp $f.LastWriteTime) created=$(Get-LswStamp $f.CreationTime) partial=$partial total_lines=$total")
        Write-LswBlock $id $lines
        $pulled++
    } catch {
        $errors++
        Write-Output ("${Mark}FILEERR pathb64=$(Get-LswB64 $f.FullName) error=$(Get-LswB64 $_.Exception.Message)")
    }
}
# ---- THE INVENTORY: what is actually THERE, not what we pulled ---------------------------------
# This is the measurement Jev named as the one that would most change the logging decision
# (missing_measurement = total-line-volume-per-boot, confidence 1.00) and that nothing reported, so
# "386 files, 368 of them one module's" had to be counted by hand once and was never seen again.
# It is deliberately INDEPENDENT of -MaxFiles: the cap decides what content comes back, never what
# the guest is told to have. Counted by streaming, so a large file costs time and not memory.
$invFiles = 0; $invBytes = [long]0; $invLines = [long]0
$invByModule = @{}
$invSrc = @()
$invOther = 0
if ($dirExists) {
    $invSrc = @(Get-ChildItem -LiteralPath $logDir -Filter *.log -File -ErrorAction SilentlyContinue)
    # EVERYTHING ELSE IN THE DIRECTORY IS COUNTED TOO. The per-module stats below are about *.log,
    # but a pile of .old / .txt / .etl / a subdirectory is still log volume, and an inventory that
    # cannot see it would report a clean directory while something else filled it.
    $invOther = @(Get-ChildItem -LiteralPath $logDir -File -Recurse -ErrorAction SilentlyContinue |
                  Where-Object { $_.Extension -ne '.log' }).Count
}
foreach ($f in $invSrc) {
    $invFiles++
    $invBytes += $f.Length
    $n = 0
    # SHARING: the LIVE file is held by its writer with FILE_SHARE_READ | FILE_SHARE_WRITE, and a
    # reader must permit what the existing opener holds - so FileShare.ReadWrite, not the
    # FileShare.Read that [System.IO.File]::ReadLines defaults to. Measured 2026-10-08 on
    # win11r-logvol: every module with a live file reported "1 UNREADABLE", i.e. the inventory could
    # not count the lines of exactly the files that matter.
    try {
        $fs = [System.IO.File]::Open($f.FullName, [System.IO.FileMode]::Open,
                                     [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $sr = New-Object System.IO.StreamReader($fs)
            try { while ($null -ne $sr.ReadLine()) { $n++ } } finally { $sr.Dispose() }
        } finally { $fs.Dispose() }
    }
    catch { $n = -1 }   # unreadable: reported as -1, never as zero - missing data must not read as empty
    if ($n -ge 0) { $invLines += $n }
    # the module is the name without the date (and without the old time-and-pid shape)
    $mod = $f.Name -replace '-\d{8}(-\d{6}-\d+)?\.log$','' -replace '\.log$',''
    if (-not $invByModule.ContainsKey($mod)) { $invByModule[$mod] = @{ files = 0; bytes = [long]0; lines = [long]0; unreadable = 0 } }
    $invByModule[$mod].files++
    $invByModule[$mod].bytes += $f.Length
    if ($n -ge 0) { $invByModule[$mod].lines += $n } else { $invByModule[$mod].unreadable++ }
}
Write-Output ("${Mark}INVENTORY direxists=$(if ($dirExists) { 1 } else { 0 }) files=$invFiles bytes=$invBytes lines=$invLines modules=$($invByModule.Count) otherfiles=$invOther")
foreach ($mod in ($invByModule.Keys | Sort-Object { -$invByModule[$_].files })) {
    $m = $invByModule[$mod]
    Write-Output ("${Mark}INVMODULE nameb64=$(Get-LswB64 $mod) files=$($m.files) bytes=$($m.bytes) lines=$($m.lines) unreadable=$($m.unreadable)")
}

if ($skipped -gt 0) {
    # base64 per name: a log name is data from the guest and must not break the stream's line format.
    $enc = @($skippedNames | ForEach-Object { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($_)) }) -join ','
    Write-Output ("${Mark}FILESKIPPED n=$skipped namesb64=$enc")   # GUARD:skipnames
}

# ---- the event records -------------------------------------------------------------------------------------------
$evErrors = 0
if (-not $NoEvents) {
    $ev = New-Object 'System.Collections.Generic.List[string]'
    $requiredMissing = New-Object 'System.Collections.Generic.List[string]'
    # channel -> ids queried; the message filters below narrow 1000/1001/1026 and the 7xxx records to ours
    $channels = @(
        @{ Log = 'System'; Ids = @(12, 13, 41, 1001, 1074, 1076, 6005, 6006, 6008, 6009, 6013, 109, 7000, 7009, 7011, 7023, 7024, 7031, 7034, 7036, 7040, 7043, 7045); Required = $true },
        @{ Log = 'Application'; Ids = @(1000, 1001, 1026, 4001, 4002, 4003, 4004); Required = $true },
        @{ Log = 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational'; Ids = @(21, 22, 23, 24, 25, 54); Required = $false },
        @{ Log = 'Microsoft-Windows-TaskScheduler/Operational'; Ids = @(201, 203); Required = $false }
    )
    foreach ($ch in $channels) {
        $log = $ch.Log
        try {
            $recs = @(Get-WinEvent -FilterHashtable @{ LogName = $log; Id = $ch.Ids; StartTime = $sinceL } -ErrorAction Stop)
            $raw = $recs.Count
            $kept = 0
            foreach ($r in ($recs | Sort-Object TimeCreated)) {
                $msg = $r.Message
                if ([string]::IsNullOrEmpty($msg)) {
                    try { $msg = ($r.Properties | ForEach-Object { [string]$_.Value }) -join ' | ' } catch { $msg = '(no message)' }
                }
                $msg = (($msg -replace "`r", '') -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 4) -join ' / '
                $prov = [string]$r.ProviderName
                $keep = $true
                if ($log -eq 'Application' -and $r.Id -in @(1000, 1001, 1026)) { $keep = ($msg -match $OurExeRx) }
                elseif ($log -eq 'System' -and $r.Id -ge 7000 -and $r.Id -lt 8000) { $keep = ($msg -match $OurSvcRx) }
                elseif ($log -like 'Microsoft-Windows-TaskScheduler*') { $keep = ($msg -match $OurTaskRx) }
                elseif ($log -eq 'System' -and $r.Id -eq 12) { $keep = ($prov -eq 'Microsoft-Windows-Kernel-General') }
                elseif ($log -eq 'System' -and $r.Id -eq 1001) { $keep = ($prov -like '*BugCheck*') }
                elseif ($log -eq 'System' -and $r.Id -in @(41, 109)) { $keep = ($prov -like '*Kernel-Power*') }
                if (-not $keep) { continue }
                $kept++
                $ev.Add("EV $($r.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss.fff')) [$log] id=$($r.Id) level=$($r.Level) ${prov}: $msg")
            }
            # TWO DIFFERENT NOTHINGS, AND THE DIFFERENCE IS THE EVIDENCE. Measured 2026-10-10 on
            # win10-acc, twice: the System channel reported `EV NONE [System]` with
            # required_missing=- , so the sweep was blind to every shutdown marker (109/1074/6006)
            # and every SCM record (7023/7024/7031/7034) while reporting itself complete. A
            # REQUIRED channel that returns no records at all is missing data and must fail; one
            # that returned records this filter then dropped is an answer, and says so.
            # (# GUARD:channelraw)
            if ($kept -eq 0) {
                $ev.Add("EV NONE [$log] raw=$raw kept=0")
                if ($raw -eq 0 -and $ch.Required) { $requiredMissing.Add("$log (no records at all)") }
            }
        } catch {
            $m = $_.Exception.Message
            if ($m -match 'No events were found') { $ev.Add("EV NONE [$log]") }
            else {
                $evErrors++
                $ev.Add("EV ERR [$log] " + ($m -replace "[`r`n]+", ' '))
                if ($ch.Required) { $requiredMissing.Add($log) }
            }
        }
    }
    $rm = if ($requiredMissing.Count -gt 0) { [string]::Join(',', $requiredMissing.ToArray()) } else { '-' }
    Write-Output ("${Mark}EVENTS channels=$($channels.Count) required_missing=$rm")
    Write-LswBlock 'events' $ev
}
Write-Output ("${Mark}END files=$($sorted.Count) pulled=$pulled errors=$errors event_errors=$evErrors")
