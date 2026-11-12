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
#     TaskScheduler/Operational 201/203/329 naming our tasks (the channel is optional: client Windows ships it disabled).
#     329 is the time-limit kill - a hang, and the one record that says so, since the 201 of that kill
#     carries the same ResultCode the shutdown reap leaves. tools/log-sweep.py counts it as a failure.
#
# OUTPUT: one stream the rig DECODES AND VERIFIES (the proven transfer shape of the toast-hold harness - trust
# counts, not streams). Every line the harness reads starts with 'LSW ' - a marker that never appears on the
# command line qtest echoes back (the a0-lib self-match lesson). Paths and other values that may contain spaces
# travel base64-encoded (pathb64=).
#   LSW BEGIN v=1 now=<local yyyy-MM-ddTHH:mm:ss.fff> nowutc=<...Z> tz=<+hh:mm> host=<b64> user=<b64> session=<n> since=<utc> sincelocal=<local>
#   LSW LOGDIR pathb64=<b64> exists=<0|1>
#   LSW LOGDIREXTRA pathb64=<b64> exists=<0|1> files=<n>   (one per OTHER candidate LogDir)
#   LSW FILE id=f<n> pathb64=<b64> family=<hint> bytes=<n> lines=<n> written=<local> created=<local> partial=<0|1> total_lines=<n>
#   LSW PULL name=f<n> lines=<count> bytes=<utf8 bytes> sha256=<hex> b64lines=<m>
#   LSW B|<76 base64 chars>  (m lines)
#   LSW PULLEND name=f<n> b64lines=<m>
#   LSW FILEERR pathb64=<b64> error=<b64>            a log that exists but could not be read - the analyzer FAILS on it
#   LSW FILESKIPPED n=<k>                            more files than -MaxFiles: the oldest were not pulled (INCOMPLETE)
#   LSW DROPPED reason=window seen=<n> kept=<n> n=<k> newestdropped=<iso|none> capped=<m> namesb64=<b64,...>
#       what the --since filter excluded, ALWAYS emitted. newestdropped= is the newest stamp among the
#       dropped files and is what settles "was anything from this run excluded?" - the name
#       list is a SAMPLE of at most 40, and capped= counts the names NOT recorded.
#   LSW ACCT pathb64=<b64> origin=<logdir|exception|oldpath> relb64=<b64 path inside LogDir, logdir only> written=<local> inwin=<0|1> bytes=<n> lines=<n|-1>
#   LSW ACCTEND n=<rows>
#       THE ACCOUNTING LISTING (docs/ADR-logging.md item 7): every file in LogDir (any extension,
#       subdirectories included), item 6's logs at their fixed paths and item 4's old paths, each with
#       its line count by the ONE rule tools/log-sweep.py read_lines also counts by (-1: unreadable).
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
# THE ACCOUNTING SCOPE OUTSIDE LogDir (docs/ADR-logging.md item 7). Item 6's declared exceptions that
# are logs, at their fixed paths, and item 4's OLD PATHS - the "was" column; the old path INSIDE the
# directory (reboot-audit.log) is listed with the directory. Each is listed whatever its age, and
# pulled when it was written inside the window. tools/log-sweep.py ACCT_FIXED_RULES is the other half:
# a path listed here that no rule there accounts for is `unaccounted-file`, which is how the two lists
# are kept from drifting apart.
$AcctExceptionPaths = @('C:\qwt-improved-install.log', 'C:\qwt-install.log', 'C:\qwt-uninstall.log',
    'C:\ProgramData\QubesIDD-diag.log', 'C:\qubes-win-idd-setup.log', 'C:\qubes-de-firstlogon.log')
$AcctExceptionRootGlobs = @('relocate-dir-*.log')
$AcctOldPaths = @('C:\ProgramData\Qubes\wu\agent.log', 'C:\ProgramData\Qubes\wu\dism.log',
    'C:\ProgramData\Qubes\wu\qubes-updates-relay.log', 'C:\ProgramData\Qubes\wu\relay-handler.log',
    'C:\ProgramData\Qubes\vmupdate-shim.log', 'C:\ProgramData\QubesPvNic.log', 'C:\ProgramData\QubesNetSetup.log',
    'Q:\qwtng-netsetup.log', 'C:\qwt-idd-activate.log', 'C:\qwt-idd-deactivate.log',
    'C:\Users\Public\Documents\Qubes Logs\reboot-audit.log')
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
    # LOOK WHERE THE PRODUCT WOULD HAVE WRITTEN, in the product's own order.
    #
    # winutils/src/log.c:282 with winutils/include/log.h:59: when LogInit gets no
    # directory it builds "<system drive>\Qubes Logs" (LOG_DEFAULT_DIR is L"Qubes Logs", with the
    # space) and CREATES it. That path was missing from this chain entirely, so a guest whose
    # registry carries no LogDir at all wrote its logs to C:\Qubes Logs and this collector looked at
    # Q:\Qubes Logs and C:\Program Files\Qubes Tools\log and reported exists=0 - a blind sweep over a
    # guest that was logging perfectly well.
    #
    # It does NOT rescue the appvm case, and nothing here can: when the registry DOES name a path
    # and CreateDirectory fails on it - the inherited Z:\qwt-logs\<churn> on a volume that is not
    # mounted at agent start - log.c calls LogStart(NULL) and goes to its fallback label, which is
    # stderr only. No file is written anywhere, so there is nothing for any collector to find. That
    # one is fixed by making the LogDir valid before the agent starts, not here.
    $r = Get-ItemProperty 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -ErrorAction SilentlyContinue
    if ($r -and $r.LogDir) { return [string]$r.LogDir }
    # Join-Path turns 'C:' into 'C:\Qubes Logs', which is exactly what log.c builds from
    # GetSystemDirectory truncated at index 3 plus LOG_DEFAULT_DIR.
    $productDefault = Join-Path $env:SystemDrive 'Qubes Logs'
    if (Test-Path -LiteralPath $productDefault) { return $productDefault }
    if (Test-Path -LiteralPath 'Q:\Qubes Logs') { return 'Q:\Qubes Logs' }
    return 'C:\Program Files\Qubes Tools\log'
}

function Get-LswLogDirCandidates {
    # EVERY DIRECTORY A windows-utils MODULE COULD HAVE RESOLVED - not only the one the registry
    # names at COLLECTION TIME. Get-LswLogDir returns the FIRST hit, and that single `return` is
    # the whole blindness: a module resolves its LogDir ONCE, at its own LogInit, and the harness
    # moves that value underneath it (logvol_bind_guest sets it, logvol_clear_guest removes it,
    # logvol_restore_now puts it back) - so by the time this collector runs, the registry can name
    # a directory that no module in the capture ever wrote to, and the ones they DID write to are
    # invisible. MEASURED twice on run 39880114972:
    #   * win11-upgrade: the restore reverted LogDir to Q:\Qubes Logs 18 s before collection, the
    #     collector listed Q: and reported the candidate build wrote nothing, while 27 QWTBIRTH
    #     lines sat on the bound volume (SWEEPGRADESTHEDEFAULTDIRNOTTHEBOUNDVOLUME, P1).
    #   * win10-clean boot 3: the unpark boot ran with LogDir CLEARED, so its boot-time modules
    #     resolved log.c's own default, and the collector - reading the re-asserted Z: - has no
    #     record of that boot at all (PARKBOOTAGENTINVISIBLETOTHESWEEP).
    # Owner's standing instruction on this file: "keep logs in single place, sweep them together".
    # One location is still the real fix; until every writer is there, SWEEP THE UNION.
    $root = 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools'
    $raw = New-Object 'System.Collections.Generic.List[string]'
    $r = Get-ItemProperty $root -ErrorAction SilentlyContinue
    if ($r) {
        $raw.Add([string]$r.LogDir)
        # LogDirPreLogvol is where the modules logged BEFORE a bind - the binder saves it for the
        # restore, which makes it a first-class witness of a capture's earlier boots.
        $raw.Add([string]$r.LogDirPreLogvol)
    }
    # a bind may set LogDir PER MODULE (and -Clear removes those too), so each module key is a
    # directory some module resolved.
    foreach ($k in (Get-ChildItem $root -ErrorAction SilentlyContinue)) {
        $raw.Add([string](Get-ItemProperty -Path $k.PSPath -Name LogDir -ErrorAction SilentlyContinue).LogDir)
    }
    # log.c:236-253 builds "<system drive>\Qubes Logs" and CREATES it (CreateDirectory at :256)
    # whenever LogInit gets no directory - the branch a cleared LogDir takes.
    $raw.Add((Join-Path $env:SystemDrive 'Qubes Logs'))
    $raw.Add('Q:\Qubes Logs')
    $raw.Add('C:\Program Files\Qubes Tools\log')
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $out = New-Object 'System.Collections.Generic.List[string]'
    foreach ($p in $raw) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $t = ([string]$p).TrimEnd('\')
        if ($seen.Add($t)) { $out.Add($t) }
    }
    # .ToArray(), NOT `return ,$out`: the comma idiom used elsewhere in this file wraps a List so the
    # pipeline does NOT enumerate it, which is right for Read-LswLines and wrong here - the caller
    # does `foreach ($d in (Get-LswLogDirCandidates))`, so a non-enumerating return binds $d to the
    # List itself and Test-Path is handed an object instead of a path. Caught by the functional leg
    # in tools/tests/collector-logdir-default-selftest.sh, which read Count=1 for three candidates.
    return $out.ToArray()
}

# ONE COUNTING RULE ON BOTH SIDES, because the sweep's ledger compares this count with its own
# (docs/ADR-logging.md item 7, "Lines"; tools/log-sweep.py read_lines is the other half): decode by the
# byte-order mark (UTF-16 LE/BE - the msiexec logs - or UTF-8 with the mark dropped), else as UTF-8;
# split on LF; drop one trailing CR from each piece; drop the empty piece after a final LF. Every other
# piece, an empty one included, is a line; an empty file has none. StreamReader.ReadLine, used here
# before, also broke on a lone CR. FileShare.ReadWrite: the writers hold their logs open.
function Get-LswText([string]$path) {
    $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try { $ms = New-Object System.IO.MemoryStream; $fs.CopyTo($ms); $b = $ms.ToArray() } finally { $fs.Dispose() }
    if ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) { return [System.Text.Encoding]::Unicode.GetString($b, 2, $b.Length - 2) }
    if ($b.Length -ge 2 -and $b[0] -eq 0xFE -and $b[1] -eq 0xFF) { return [System.Text.Encoding]::BigEndianUnicode.GetString($b, 2, $b.Length - 2) }
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { return [System.Text.Encoding]::UTF8.GetString($b, 3, $b.Length - 3) }
    return [System.Text.Encoding]::UTF8.GetString($b)
}

function Read-LswLines([string]$path) {
    $out = New-Object 'System.Collections.Generic.List[string]'
    $text = Get-LswText $path
    if ($text.Length -eq 0) { return ,$out }
    $pieces = $text.Split([char]10)
    $n = $pieces.Length
    if ($text[$text.Length - 1] -eq [char]10) { $n-- }
    for ($i = 0; $i -lt $n; $i++) {
        $p = $pieces[$i]
        if ($p.Length -gt 0 -and $p[$p.Length - 1] -eq [char]13) { $p = $p.Substring(0, $p.Length - 1) }
        $out.Add($p)
    }
    return ,$out
}

# The same rule as a count: a CR never changes it, so it is the number of LFs, plus one for a last
# line with no LF after it.
function Get-LswLineCount([string]$path) {
    $text = Get-LswText $path
    if ($text.Length -eq 0) { return 0 }
    $n = $text.Length - $text.Replace([string][char]10, '').Length
    if ($text[$text.Length - 1] -ne [char]10) { $n++ }
    return $n
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
# one file can be reachable under two of the candidate directories at once - a junction bind leaves
# <LogDir> and the volume path naming the same files - so every add is deduplicated by full path.
$seenFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
# WHAT THE WINDOW EXCLUDED IS REPORTED, NEVER DROPPED IN SILENCE. Campaign 1025-0050: this filter
# examined 17 files and carried 12, and no line of the stream said so - the difference had to be
# found by counting INVENTORY against the FILE lines by hand, and the inventory counts a DIFFERENT
# population (non-recursive *.log) so even that subtraction was not arithmetic anyone should trust.
# A window excluding old files is NORMAL and this is not a verdict; it is the number the analyzer
# needs to say how much damage an unusable window did.
$dropWindow = 0
# The newest stamp among the dropped files. This - not the name list - is what answers "was
# anything from THIS run excluded?", because no cap can shorten one number. MaxValue as the
# empty value would read as a drop from the future, so the emptiness is explicit instead.
$dropNewest = $null
$dropCapped = 0
$dropNames = New-Object 'System.Collections.Generic.List[string]'
$seenCands = 0
if ($dirExists) {
    $all = @(Get-ChildItem -LiteralPath $logDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(log|txt|json|old)$' })
    $newestWd = @($all | Where-Object { $_.Name -match '^(?i)gui-watchdog-' } | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
    $newestAg = @($all | Where-Object { $_.Name -match '^(?i)gui-agent-' } | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
    foreach ($f in $all) {
        $seenCands++
        $always = ($newestWd.Count -gt 0 -and $f.FullName -eq $newestWd[0].FullName) -or ($newestAg.Count -gt 0 -and $f.FullName -eq $newestAg[0].FullName)
        if ($f.LastWriteTimeUtc -lt $sinceU -and -not $always) {
            # counted as a WINDOW drop only - a dedup hit below is a different thing and is not one.
            $dropWindow++
            if ($null -eq $dropNewest -or $f.LastWriteTimeUtc -gt $dropNewest) { $dropNewest = $f.LastWriteTimeUtc }
            if ($dropNames.Count -lt 40) { $dropNames.Add($f.Name) } else { $dropCapped++ }
            continue
        }
        if ($seenFiles.Add($f.FullName)) { $cands.Add($f) }
    }
}
# ---- THE OTHER DIRECTORIES A MODULE COULD HAVE RESOLVED ------------------------------------------
# The receipt above is UNCHANGED and still names the primary directory, because the analyzer and
# three selftests parse `LSW LOGDIR`. Each additional directory gets its own LOGDIREXTRA line, a new
# kind the current analyzer ignores (its dispatch is a startswith chain and "LOGDIREXTRA " does not
# match "LOGDIR "), so an older analyzer reading a newer capture loses nothing it had.
# THE --since FILTER IS THE ONLY ONE APPLIED HERE, deliberately: the `$always` exemption above
# exists so a capture never loses the agent's own current log, and extending it to a directory the
# product is NOT using would pull a STALE agent log - a predecessor build's, or a previous
# campaign's - and present it as this run's. That is the attribution hazard QWTBIRTH was added to
# close, and it is not worth reopening for a directory nothing is writing to.
# THE RESIDUAL HAZARD, judged and recorded rather than waved off: sweeping more directories can pull
# logs the product is not currently writing - a predecessor build's, or an earlier campaign's - which
# the gate would then grade as this run's work. Jev on this diff (receipt
# scratchpad/jev-union-out.json): stale_attribution_hazard = manageable-but-worth-noting 0.84
# (material 0.13, negligible 0.03), i.e. real but bounded by what is already here - the --since
# filter above, per-build attribution from QWTBIRTH, and _inst_prior scoping on every gated
# per-instance metric. verdict = land 0.83. If a capture ever shows a cell graded on a directory
# nothing wrote to in its window, this comment is where to start.
foreach ($d in (Get-LswLogDirCandidates)) {
    if ($d -ieq ([string]$logDir).TrimEnd('\')) { continue }
    if (-not (Test-Path -LiteralPath $d)) {
        Write-Output ("${Mark}LOGDIREXTRA pathb64=$(Get-LswB64 $d) exists=0 files=0")
        continue
    }
    $n = 0
    foreach ($f in @(Get-ChildItem -LiteralPath $d -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(log|txt|json|old)$' })) {
        $seenCands++
        if ($f.LastWriteTimeUtc -lt $sinceU) {
            $dropWindow++
            if ($dropNames.Count -lt 40) { $dropNames.Add($f.Name) }
            continue
        }
        if ($seenFiles.Add($f.FullName)) { $cands.Add($f); $n++ }
    }
    Write-Output ("${Mark}LOGDIREXTRA pathb64=$(Get-LswB64 $d) exists=1 files=$n")
}
# ALWAYS EMITTED, n=0 included: "0 dropped" and "this collector cannot say" are different facts, and
# an analyzer that cannot tell them apart would read an old capture as a clean one. Names are base64
# per name, the FILESKIPPED convention, because a log name is guest data and must not break the line.
$_dropEnc = @($dropNames | ForEach-Object { [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($_)) }) -join ','
# newestdropped= settles whether anything in-window was dropped; capped= says the name list is a
# SAMPLE. Without capped= a reader takes 40 names beside n=165 for the whole set, which is how
# this very marker misled its own author on 2026-10-25.
$_dropNewest = if ($null -ne $dropNewest) { $dropNewest.ToString("yyyy-MM-ddTHH:mm:ssZ") } else { "none" }
Write-Output ("${Mark}DROPPED reason=window seen=$seenCands kept=$($cands.Count) n=$dropWindow newestdropped=$_dropNewest capped=$dropCapped namesb64=$_dropEnc")
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
# ---- THE ACCOUNTING LIST (docs/ADR-logging.md item 7, "Scope") ----------------------------------
# Every file in LogDir, whatever its extension, hidden ones too; then the fixed paths. A file the
# ledger must count lines for is pulled when it was written inside the window and is not a candidate
# already - an old path such as Q:\qwtng-netsetup.log is in none of the lists above.
$acct = New-Object 'System.Collections.Generic.List[object]'
$acctSeen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
if ($dirExists) {
    # the separator by name, so this also runs where it is '/' (a parse-and-count check off the guest)
    $sep = [System.IO.Path]::DirectorySeparatorChar
    $acctBase = ([System.IO.Path]::GetFullPath([string]$logDir)).TrimEnd($sep)
    foreach ($f in @(Get-ChildItem -LiteralPath $logDir -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        if (-not $acctSeen.Add($f.FullName)) { continue }
        $rel = $f.FullName
        if ($rel.StartsWith($acctBase + $sep, [StringComparison]::OrdinalIgnoreCase)) { $rel = $rel.Substring($acctBase.Length + 1) }
        $acct.Add(@{ f = $f; origin = 'logdir'; rel = $rel.Replace('\', '/') })
    }
}
$acctFixed = @()
foreach ($p in $AcctExceptionPaths) { $acctFixed += ,@($p, 'exception') }
foreach ($g in $AcctExceptionRootGlobs) {
    foreach ($f in @(Get-ChildItem -LiteralPath 'C:\' -Filter $g -File -Force -ErrorAction SilentlyContinue)) { $acctFixed += ,@($f.FullName, 'exception') }
}
foreach ($p in $AcctOldPaths) { $acctFixed += ,@($p, 'oldpath') }
$candSeen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($c in $cands) { [void]$candSeen.Add($c.FullName) }
foreach ($pe in $acctFixed) {
    if (-not (Test-Path -LiteralPath $pe[0] -PathType Leaf)) { continue }
    $f = Get-Item -LiteralPath $pe[0] -Force -ErrorAction SilentlyContinue
    if (-not $f -or -not $acctSeen.Add($f.FullName)) { continue }
    $acct.Add(@{ f = $f; origin = $pe[1]; rel = '' })
    if ($f.LastWriteTimeUtc -ge $sinceU -and $candSeen.Add($f.FullName)) { $cands.Add($f) }
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
        # the file is etw-proxy.log; '^etwproxy' matched nothing, so it ranked 9 and a cap could drop it
        '^etw-proxy\.log' { 4 }
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
        # THE SAME SUBSYSTEMS UNDER THEIR NAMES IN LogDir since the log move (docs/ADR-logging.md item
        # 4). The old names above stay for upgraded guests' old paths; these are what the build under
        # test writes. Measured 2026-11-02 on a copy of a smoke run's directory pulled at the
        # collector's default cap: the updater, pvnic-boot and etw-proxy logs ranked 9 and were the
        # files the cap dropped.
        '^qubes-windows-update\.ps1-\d{8}\.log$'              { 5 }
        '^vmupdate-shim\.ps1-\d{8}\.log$'                     { 5 }
        '^(qubes-updates-relay|relay-handler)-\d{8}\.log$'     { 5 }
        '^dism-\d{8}\.log$'                                    { 5 }
        '^pvnic-boot\.ps1-\d{8}\.log$'                        { 5 }
        '^qwtng-netsetup-\d{8}\.log$'                          { 5 }
        '^record-reboot-cause\.ps1-\d{8}\.log$'               { 5 }
        '^(activate|deactivate)-idd\.ps1-\d{8}\.log$'         { 5 }
        '^(ensure-autologon|quiet-desktop)\.ps1-\d{8}\.log$'  { 5 }
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
# ---- THE ACCOUNTING LIST, emitted -----------------------------------------------------------------
# After the pull, so a file the ledger finds pulled is judged on its FILE record (the same read as its
# content); this count is the one used for a file that was not pulled. The inventory below reuses it.
$acctLines = @{}
foreach ($a in $acct) {
    $f = $a.f
    $lc = -1
    try { $lc = Get-LswLineCount $f.FullName } catch { $lc = -1 }
    $acctLines[$f.FullName] = $lc
    $relb64 = if ($a.rel) { Get-LswB64 $a.rel } else { '' }
    Write-Output ("${Mark}ACCT pathb64=$(Get-LswB64 $f.FullName) origin=$($a.origin) relb64=$relb64 written=$(Get-LswStamp $f.LastWriteTime) inwin=$(if ($f.LastWriteTimeUtc -ge $sinceU) { 1 } else { 0 }) bytes=$($f.Length) lines=$lc")
}
Write-Output ("${Mark}ACCTEND n=$($acct.Count)")
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
    # THE ACCOUNTING LIST'S COUNT, by the one rule (Get-LswLineCount opens with FileShare.ReadWrite).
    if ($acctLines.ContainsKey($f.FullName)) { $n = $acctLines[$f.FullName] }
    else { try { $n = Get-LswLineCount $f.FullName } catch { $n = -1 } }   # unreadable: reported as -1, never as zero - missing data must not read as empty
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
        @{ Log = 'System'; Ids = @(12, 13, 41, 104, 1001, 1074, 1076, 6005, 6006, 6008, 6009, 6013, 109, 7000, 7009, 7011, 7023, 7024, 7031, 7034, 7036, 7040, 7043, 7045); Required = $true },
        @{ Log = 'Application'; Ids = @(1000, 1001, 1026, 4001, 4002, 4003, 4004); Required = $true; MustOccur = $false },
        @{ Log = 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational'; Ids = @(21, 22, 23, 24, 25, 54); Required = $false },
        @{ Log = 'Microsoft-Windows-TaskScheduler/Operational'; Ids = @(201, 203, 329); Required = $false }
    )
    foreach ($ch in $channels) {
        $log = $ch.Log
        # THE 23-EXPRESSION XPATH CAP, and it made System blind on EVERY sweep ever run. Get-WinEvent
        # compiles the hashtable into ONE event selector; a selector holds at most 23 expressions, and
        # past that Windows does not report an invalid query - it reports "No events were found". System
        # carries 23 ids, so with StartTime that is 24. MEASURED 2026-11-08 on win11-acc: 22 ids +
        # StartTime -> 31 records; 23 ids + StartTime -> throws "No events were found"; the SAME 23 ids
        # WITHOUT StartTime -> 143; and with no id filter at all the channel read 810 records over the
        # window (ListLog: enabled=True, 1618 records, Circular). A superset returning less than its own
        # subset is a malformed query, not a quiet channel. This is the CAUSE of the blindness
        # GUARD:channelraw and GUARD:channelrawthrown detect: both fired correctly, neither could say
        # why, and the shutdown markers and SCM records they reported as lost were lost to this.
        $qerr = $null
        $nchunks = 0
        $ids = @($ch.Ids)
        $recs = New-Object 'System.Collections.Generic.List[object]'
        for ($qi = 0; $qi -lt $ids.Count; $qi += 22) {   # 22 ids + StartTime = 23, the maximum
            $grp = @($ids[$qi..([Math]::Min($qi + 21, $ids.Count - 1))])
            $nchunks++
            try {
                foreach ($rr in @(Get-WinEvent -FilterHashtable @{ LogName = $log; Id = $grp; StartTime = $sinceL } -ErrorAction Stop)) { $recs.Add($rr) }
            } catch {
                # "No events were found" is how this channel says zero for THIS chunk; any other failure
                # is the channel being unreadable and must not be rounded down to zero.
                # BY ITS ERROR ID, NEVER ITS TEXT. The message is localized: on the reporter's German
                # image it reads "Es wurden keine Ereignisse gefunden, ..." and every empty chunk made
                # System and Application "unreadable", grading the sweep DATA (measured 2026-11-12 on
                # win11de-os20, 4.3.41). The id there: NoMatchingEventsFound,...GetWinEventCommand.
                if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { $qerr = $_.Exception.Message; break }
            }
        }
        if ($qerr) {
            $evErrors++
            $ev.Add("EV ERR [$log] " + ($qerr -replace "[`r`n]+", ' '))
            if ($ch.Required) { $requiredMissing.Add("${log}=unreadable") }
            continue
        }
        $raw = $recs.Count
        $kept = 0
        try {
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
        } catch {
            $evErrors++
            $ev.Add("EV ERR [$log] decoding records: " + ($_.Exception.Message -replace "[`r`n]+", ' '))
            if ($ch.Required) { $requiredMissing.Add("${log}=undecodable") }
            continue
        }
        # TWO DIFFERENT NOTHINGS, AND THE DIFFERENCE IS THE EVIDENCE. Measured 2026-10-10 on win10-acc,
        # twice: the System channel reported `EV NONE [System]` with required_missing=- , so the sweep
        # was blind to every shutdown marker (109/1074/6006) and every SCM record (7023/7024/7031/7034)
        # while reporting itself complete. A REQUIRED channel that returns no records at all is missing
        # data and must fail; one that returned records this filter then dropped is an answer, and says
        # so. The chunked query above removes the CAUSE those two guards were detecting, so "no records
        # at all" now means the channel really was asked and really answered nothing.
        # (# GUARD:channelraw, # GUARD:channelrawthrown - one accounting, both doors)
        # THE VALUE CARRIES NO SPACES. tools/log-sweep.py kv_parse splits this line on whitespace, so
        # `System (no records at all),Application (no records at all)` reached the report as bare
        # `System`: the second blind channel vanished and the norecords/unreadable distinction - the
        # evidence this guard exists to carry - was discarded. Measured on campaign 42400226595's
        # supervision run, which named one affected channel out of two.
        if ($kept -eq 0) {
            # WHY IT IS EMPTY IS NOT RECORDED ANYWHERE, so the question cannot be settled from a
            # capture. A required channel reads zero for reasons that are opposite in meaning - the
            # log was cleared, the Event Log service is down, an id filter silently stopped matching
            # (which is what System did for weeks, above) - or because the records genuinely did not
            # occur, which for Application's 1000/1001/1026 crash ids is the HEALTHY case (Jev
            # must_not_occur_on_a_healthy_guest 0.98). Two cheap facts tell those apart: the same
            # window with NO id filter, and the channel's own listing. Both are RECORDED, and neither
            # is a wipe detector - see the note on event 104 below the predicate.
            $anyid = -1; $lgEn = '?'; $lgRec = -1
            try { $anyid = @(Get-WinEvent -FilterHashtable @{ LogName = $log; StartTime = $sinceL } -MaxEvents 2000 -ErrorAction Stop).Count }
            catch { if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { $anyid = 0 } }   # the id, not the localized text
            try { $l0 = Get-WinEvent -ListLog $log -ErrorAction Stop; $lgEn = [string]$l0.IsEnabled; $lgRec = [long]$l0.RecordCount } catch { }
            $ev.Add("EV NONE [$log] raw=$raw kept=0 chunks=$nchunks anyid=$anyid enabled=$lgEn records=$lgRec")
            # MUSTOCCUR, NOT Required. `Required` says three different things in this one file:
            # "must be readable" (=unreadable, above), "must be decodable" (=undecodable, above),
            # and "these ids must occur" - here. Only the third is false for Application. Its ids
            # are crash and hang records, and Jev application_ids_must_occur =
            # must_not_occur_on_a_healthy_guest 0.98: a guest that crashed nothing legitimately has
            # none, so their absence cannot be missing data. The predicate is UNCHANGED and still
            # strict for System, whose ids include the boot and shutdown markers that must occur in
            # any window a release sweep covers. `-ne $false`, not a plain truth test, so a channel
            # marked Required with no MustOccur key stays STRICT and adding one cannot silently
            # switch this guard off.
            # A CLEARED CHANNEL IS NOT DETECTABLE FROM A RECORD COUNT, and the attempt is recorded
            # here because the predicate that tried it SHIPPED AND COULD NOT FIRE. The question that had
            # stalled this - may a readable-but-empty required channel pass - scored 0.64 and then 0.44 on
            # the byte-identical state, an oscillation, so it was never a verdict. Replacing that
            # JUDGEMENT with the "decidable" property `enabled -and RecordCount -eq 0` looked right and
            # was wrong: MEASURED on win11r-sup 2026-11-09, `wevtutil cl Application` returned and the
            # very next read of that channel was already `numberOfLogRecords: 1`, and 4 a minute later,
            # because Windows is writing as the clear returns. Zero is not reachable on a live guest, so
            # that predicate was decoration and is gone rather than tuned to a threshold.
            # WHAT ENFORCES IT NOW: Windows records the clear ITSELF. Event 104 from
            # Microsoft-Windows-Eventlog is written to the System channel and names the log that was
            # cleared - measured at 2026-11-09T01:47:55 for the clear above - so 104 is in the System ids
            # at the top of this block and a wipe arrives as a CAPTURED EVENT carrying its own timestamp
            # and provider, judged like any other, instead of being inferred from a count.
            if ($raw -eq 0 -and $ch.Required -and $ch.MustOccur -ne $false) { $requiredMissing.Add("${log}=norecords") }
        }
    }
    $rm = if ($requiredMissing.Count -gt 0) { [string]::Join(',', $requiredMissing.ToArray()) } else { '-' }
    Write-Output ("${Mark}EVENTS channels=$($channels.Count) required_missing=$rm")
    Write-LswBlock 'events' $ev
}
Write-Output ("${Mark}END files=$($sorted.Count) pulled=$pulled errors=$errors event_errors=$evErrors")
