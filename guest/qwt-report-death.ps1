# qwt-report-death.ps1 - the ONE death reporter (docs/ADR-supervision.md 3): every unexpected death of a
# Qubes Windows Tools component, detected from the SYSTEM'S OWN RECORDS, reported to dom0 as an ACTION
# notification through the error-notify route, every death counted, none hidden by de-duplication.
#
# HOW IT IS RUN. The installer (Register-QwtDeathReporter) registers the SYSTEM task QwtDeathReporter with an
# EventTrigger whose XPath subscription covers, filtered to OUR components:
#   Application  1000 / 1001 (Application Error / Windows Error Reporting: a crash), .NET Runtime 1026
#                (an unhandled managed exception), and every event of our source "Qubes Windows Tools"
#                (ids 4001-4004: a supervisor's child exited unasked - the one death Windows cannot see)
#   System       7031 / 7034 / 7023 / 7024 (Service Control Manager: a service of ours ended)
#   TaskScheduler/Operational  201 with a non-zero result, and 203 (a task of ours failed)
# The task hands this script ONLY the record's channel and EventRecordID (ValueQueries); the event is read
# back here with Get-WinEvent, so no event text ever travels through a command line.
#
# WHAT ONE DEATH IS. One death leaves several records: a crash is a 1000, then a 1001, then (for a service)
# a 7031; a managed crash is a 1026 then a 1000; a helper crash is our 4002 and the Task Scheduler's 201.
# A death is identified by (executable, pid) when the record carries a pid (1000, 4001-4004); a record that
# carries none attaches to the newest death of the same executable within QwtDeathWindowSec. Records that
# can only be a NEW death (7023/7024: an error exit; 203: a launch failure; 201 of a script task; 1026, the
# first record of a managed crash, whose 1000 then adopts its pid) always open one. The per-boot ledger
# that holds this is keyed by the route's per-boot token (the volatile registry key qwt-notify-error.ps1
# and the agent share), so a reboot starts the count at 1.
#
# THE NOTIFICATION. Each NEW death is sent as component <exe stem>, id death-<n> (n = this boot's death
# count), severity ACTION: a distinct id per death, so the route's once-per-(component, id)-per-boot rule
# cannot hide a second death; the route's cap of 8 per boot still bounds a crash storm. Past the cap - and
# whatever the route decides - every death is logged at ERROR here first, in qwt-deaths.log. Content: what
# died, the exit or exception code with its meaning when known, how long it ran, the death count this
# boot, where the evidence is. No window titles, no user data: every name in the text comes from the
# tables below, every number is parsed and re-rendered, the WER folder is named by its prefix (its hash
# would trip the route's redaction and tells a human nothing).
#
# Windows PowerShell 5.1 (no ternary, no ??, no && chains). Offline suite: tools/tests/death-reporter-test.ps1
# (pwsh on Linux) dot-sources this file with $script:QwtDeathLibraryOnly = $true and the hooks below replaced;
# lines tagged `# GUARD:<name>` are each replaced by tools/tests/death-reporter-selftest.sh to prove the suite
# sees that guard fail. Keep each guard on ONE line for that reason.
param(
    [string]$Channel = '',
    [long]$RecordId = 0,
    [string]$EventXmlFile = ''      # the event's XML from a file instead of the log (offline use, tests)
)

# --- hooks (script scope; a test may set them before dot-sourcing) -----------------------------
if ($null -eq $script:QwtDeathLibraryOnly) { $script:QwtDeathLibraryOnly = $false }
if (-not $script:QwtDeathHelper) { $script:QwtDeathHelper = Join-Path $PSScriptRoot 'qwt-notify-error.ps1' }
if (-not $script:QwtDeathStateDir) {
    if ($env:ProgramData) { $script:QwtDeathStateDir = Join-Path $env:ProgramData 'Qubes\notify-errors' }
    else { $script:QwtDeathStateDir = '/tmp/qwt-notify-errors' }
}
if (-not $script:QwtDeathLogDir) { $script:QwtDeathLogDir = $null }   # $null = resolve LogDir from the registry
if (-not $script:QwtDeathWindowSec) { $script:QwtDeathWindowSec = 600 }
if (-not $script:QwtDeathAdoptSec) { $script:QwtDeathAdoptSec = 30 }
# OUR INSTALL DIRECTORY - where a crash record's faulting path must be for the crash to be ours. Resolved like the installer's
# Get-QwtBinDir (the registry's InstallDir), else from where this script lives (<install dir>\bin), else the default. A hard-coded
# default alone would refuse every crash of ours on an install in any other directory - a hidden death.
function Resolve-QwtDeathInstallDir {
    param([string]$RegistryDir, [string]$ScriptRoot)
    $dir = $null
    if ($RegistryDir) { $dir = $RegistryDir }   # GUARD:installdir
    elseif ($ScriptRoot) { $dir = ($ScriptRoot.TrimEnd('\', '/') -replace '[\\/][^\\/]+$', '') }   # the folder above bin, either separator
    if (-not $dir) { $dir = 'C:\Program Files\Qubes Tools' }
    return ($dir.TrimEnd('\') + '\')
}
function Get-QwtDeathRegistryInstallDir {
    foreach ($k in 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools', 'HKLM:\SOFTWARE\WOW6432Node\Invisible Things Lab\Qubes Tools') {
        try { $v = (Get-ItemProperty -LiteralPath $k -Name 'InstallDir' -ErrorAction SilentlyContinue).InstallDir; if ($v) { return [string]$v } } catch { }
    }
    return $null
}
if (-not $script:QwtDeathInstallDir) { $script:QwtDeathInstallDir = Resolve-QwtDeathInstallDir (Get-QwtDeathRegistryInstallDir) $PSScriptRoot }

# --- the tables: what is OURS (kept in step with Register-QwtDeathReporter's subscription by
#     tools/tests/death-reporter-xpath-selftest.py) ------------------------------------------------
# executable -> component name for the route (<= 24 chars of [a-z0-9-], its name rule)
$script:QwtDeathExes = @{
    'gui-agent.exe' = 'gui-agent'; 'gui-watchdog.exe' = 'gui-watchdog'; 'qubesdb-daemon.exe' = 'qubesdb-daemon'
    'qubesdb-cmd.exe' = 'qubesdb-cmd'; 'qrexec-agent.exe' = 'qrexec-agent'; 'qrexec-client-vm.exe' = 'qrexec-client-vm'
    'qrexec-wrapper.exe' = 'qrexec-wrapper'; 'network-setup.exe' = 'network-setup'; 'advertise-tools.exe' = 'advertise-tools'
    'clipboard-copy.exe' = 'clipboard-copy'; 'clipboard-paste.exe' = 'clipboard-paste'; 'file-receiver.exe' = 'file-receiver'
    'file-sender.exe' = 'file-sender'; 'get-image-rgba.exe' = 'get-image-rgba'; 'open-in-vm.exe' = 'open-in-vm'
    'open-url.exe' = 'open-url'; 'set-gui-mode.exe' = 'set-gui-mode'; 'vm-file-editor.exe' = 'vm-file-editor'
    'wait-for-logon.exe' = 'wait-for-logon'; 'relocate-dir.exe' = 'relocate-dir'; 'autologon.exe' = 'autologon'
    'wgcbroker.exe' = 'wgcbroker'; 'notifhost.exe' = 'notifhost'; 'etwproxy.exe' = 'etwproxy'
    'bind-dirs.exe' = 'bind-dirs'; 'qubesdb-read.exe' = 'qubesdb-read'
    'qubes-updates-relay.exe' = 'updates-relay'; 'qwtng-netsetup.exe' = 'qwtng-netsetup'
}
# OUR MANAGED executables (compiled on the guest from C#): the only ones a .NET Runtime 1026 can be ours for - a 1026 carries no path,
# so a foreign .NET program that shares one of our generic names (autologon.exe, bind-dirs.exe ...) must not count
$script:QwtDeathManagedExes = @('qubes-updates-relay.exe', 'qwtng-netsetup.exe')
# service DISPLAY name (what the SCM's param1 carries) -> executable
$script:QwtDeathServices = @{
    'QubesDB daemon' = 'qubesdb-daemon.exe'; 'Qubes RPC agent' = 'qrexec-agent.exe'
    'Qubes GUI agent watchdog' = 'gui-watchdog.exe'; 'Qubes PV NIC address applier' = 'qwtng-netsetup.exe'
}
# tasks whose action IS a helper of ours (its 201 is another record of the helper's death)
$script:QwtDeathHelperTasks = @{ '\Qubes-WgcBroker' = 'wgcbroker.exe'; '\Qubes-NotifBridge' = 'notifhost.exe' }
# tasks whose action is a script of ours (a non-zero 201 or a 203 is a death of its own)
$script:QwtDeathScriptTasks = @('\QubesPvNic', '\QubesPvNicRearm', '\QubesNetworkReapply', '\QubesQuietDesktopGuard',
                                '\QubesAutologonGuard', '\QubesWindowsUpdateScan', '\QubesWindowsUpdateRun',
                                '\QubesWindowsUpdateDownload', '\QwtImprovedSetup')
# our own source: event id -> which supervisor wrote it, and what it does next (agent include/deathevent.h)
$script:QwtDeathSupervisorIds = @{
    4001 = 'the QubesGuiWatchdog service relaunches it'
    4002 = 'the agent relaunches it within ~8 s'
    4003 = 'the agent relaunches it within 60 s'
    4004 = 'the agent relaunches it on a backoff, or parks the ETW toast tier for this boot'
}
# the meaning of the common codes - ONE table, for dom0 and for our log alike
$script:QwtDeathMeanings = @{
    [uint32]0xC0000005L = 'access violation'
    [uint32]0xC0000409L = 'fast-fail: stack buffer overrun, __fastfail or an abort'
    [uint32]0xC0000374L = 'heap corruption'
    [uint32]0xC00000FDL = 'stack overflow'
    [uint32]0xE06D7363L = 'unhandled C++ exception'
    [uint32]0xE0434352L = 'unhandled .NET exception'
    [uint32]0xC000013AL = 'console control: Ctrl-C or the console closed'
    [uint32]0xC0000142L = 'DLL initialization failed'
    [uint32]0xC0000135L = 'a DLL was not found'
    [uint32]0x80070002L = 'file not found'
    [uint32]0x80070005L = 'access denied'
    [uint32]0x80070420L = 'an instance of the task is already running'
    [uint32]1460 = 'timeout'
    [uint32]1 = 'ended by TerminateProcess, or exit 1'
    [uint32]0 = 'exit 0 - a clean exit nobody asked for'
}

# --- the route (qwt-notify-error.ps1, shipped next to this file) -------------------------------
if (-not (Get-Command Send-QwtError -ErrorAction SilentlyContinue)) {
    if (Test-Path -LiteralPath $script:QwtDeathHelper) { . $script:QwtDeathHelper }
}

# --- our own log: ERROR for every death, before anything else --------------------------------
function Get-QwtDeathLogDir {
    if ($script:QwtDeathLogDir) { return $script:QwtDeathLogDir }
    $dir = $null
    try {
        $v = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -Name 'LogDir' -ErrorAction SilentlyContinue).LogDir
        if ($v -and (Test-Path -LiteralPath $v)) { $dir = $v }
    } catch { }
    if (-not $dir) {
        if ($env:ProgramData) { $dir = Join-Path $env:ProgramData 'Qubes' } else { $dir = '/tmp' }
    }
    $script:QwtDeathLogDir = $dir
    return $dir
}
function Write-QwtDeathLog {
    param([string]$Level, [string]$Message)
    $line = '{0} [{1}] {2}' -f ([DateTime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss')), $Level, $Message
    try { Write-Host $line } catch { }
    try {
        $dir = Get-QwtDeathLogDir
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [IO.File]::AppendAllText((Join-Path $dir 'qwt-deaths.log'), $line + "`r`n", [Text.Encoding]::UTF8)
    } catch { }
}

# --- parsing helpers -----------------------------------------------------------------------------
# "0x1a2c", "1460", "3221226505", "-1073741819", "%%1460", "1460 (0x5b4)" -> [uint32], or $null. The
# RADIX IS THE CALLER'S: the crash record's code/pid/start fields are hex without a prefix ("c0000409",
# but also "40000015"), so those callers pass -Hex; the SCM's and Task Scheduler's fields are decimal.
function ConvertTo-QwtDeathUInt32 {
    param([string]$Text, [switch]$Hex)
    if (-not $Text) { return $null }
    $t = ($Text.Trim() -replace '^%+', '')
    if ($t -match '^0[xX]([0-9A-Fa-f]{1,8})\b') { try { return [uint32]([Convert]::ToUInt32($Matches[1], 16)) } catch { return $null } }
    if ($Hex) {
        if ($t -match '^([0-9A-Fa-f]{1,8})\b') { try { return [uint32]([Convert]::ToUInt32($Matches[1], 16)) } catch { return $null } }
        return $null
    }
    if ($t -match '^(-?\d{1,10})\b') {
        try {
            $v = [long]$Matches[1]
            if ($v -lt 0) { $v += 4294967296 }
            if ($v -ge 0 -and $v -le 4294967295) { return [uint32]$v }
        } catch { }
        return $null
    }
    return $null
}
function Get-QwtDeathCodeMeaning {
    param($Code)
    if ($null -eq $Code) { return '' }
    $m = $script:QwtDeathMeanings[[uint32]$Code]
    if ($m) { return $m }
    return ''
}
function Format-QwtDeathCode {
    param($Code, [string]$Kind = 'code')
    if ($null -eq $Code) { return "$Kind unknown" }
    $c = [uint32]$Code
    $txt = $null
    if ($c -ge 0x10000) { $txt = ('0x{0:X8}' -f $c) } else { $txt = "$c" }
    $m = Get-QwtDeathCodeMeaning $c
    if ($m) { return "$Kind $txt ($m)" }
    return "$Kind $txt"
}
function Format-QwtDeathRun {
    param($Ms)
    if ($null -eq $Ms) { return 'an unknown time' }
    $ts = [TimeSpan]::FromMilliseconds([double]$Ms)
    return ('{0}:{1:00}:{2:00}' -f [int][Math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds)
}
# a task or service name -> the route's component form (<= 24 chars, [a-z0-9-])
function ConvertTo-QwtDeathComponent {
    param([string]$Name)
    $c = ($Name.ToLowerInvariant() -replace '[^a-z0-9-]', '').Trim('-')
    if ($c.Length -gt 24) { $c = $c.Substring(0, 24).Trim('-') }
    if (-not $c) { $c = 'component' }
    return $c
}
function Get-QwtDeathNodeText {
    param([xml]$Doc, [string]$Name)
    $n = $Doc.GetElementsByTagName($Name)
    if ($n.Count -gt 0) { return "$($n[0].InnerText)" }
    return ''
}

# --- the event -> a death record, or $null when the record is not one of ours --------------------
# Returns [ordered]@{ ours; ignore; reason; kind; origin; time; exe; component; pid; code; codeKind; ranMs;
#                     anchor; label; evidence; detail }
function ConvertFrom-QwtDeathEvent {
    param([Parameter(Mandatory)][string]$XmlText)
    $doc = [xml]$XmlText
    $provider = ''
    $pn = $doc.GetElementsByTagName('Provider')
    if ($pn.Count -gt 0) { $provider = "$($pn[0].GetAttribute('Name'))" }
    $eventId = [int](Get-QwtDeathNodeText $doc 'EventID')
    $channel = Get-QwtDeathNodeText $doc 'Channel'
    $recordId = Get-QwtDeathNodeText $doc 'EventRecordID'
    $time = [DateTime]::UtcNow
    $tc = $doc.GetElementsByTagName('TimeCreated')
    if ($tc.Count -gt 0) {
        try { $time = [DateTime]::Parse("$($tc[0].GetAttribute('SystemTime'))", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal) } catch { }
    }
    $positional = New-Object System.Collections.ArrayList
    $named = @{}
    foreach ($d in $doc.GetElementsByTagName('Data')) {
        $nm = "$($d.GetAttribute('Name'))"
        if ($nm) { $named[$nm] = "$($d.InnerText)" } else { [void]$positional.Add("$($d.InnerText)") }
    }
    $pos = { param($i) if ($i -lt $positional.Count) { return "$($positional[$i])" } else { return '' } }

    $r = [ordered]@{ ours = $false; ignore = $false; reason = ''; kind = ''; origin = "$channel/$eventId#$recordId"; time = $time
                     exe = ''; component = ''; pid = $null; code = $null; codeKind = 'code'; ranMs = $null
                     anchor = 'enrich'; label = ''; evidence = ''; detail = ''; rec = '' }

    # OWNERSHIP: the executable must be one of ours; for 1000 the faulting-application PATH, when the
    # record carries one, must be under our install directory (a foreign gui-agent.exe is not ours).
    $owned = {
        param([string]$exe, [string]$path)
        $e = $exe.ToLowerInvariant()
        if (-not $script:QwtDeathExes.ContainsKey($e)) { return $false }   # GUARD:ours
        if ($path -and -not $path.ToLowerInvariant().StartsWith($script:QwtDeathInstallDir.ToLowerInvariant())) { return $false }
        return $true
    }

    switch ($provider) {
        'Application Error' {
            if ($eventId -ne 1000) { $r.reason = "Application Error $eventId is not a crash record"; return $r }
            $exe = & $pos 0; $path = & $pos 10
            if (-not (& $owned $exe $path)) { $r.reason = "faulting application '$exe' ($path) is not ours"; return $r }
            $r.ours = $true; $r.kind = 'crash'; $r.rec = 'crash'; $r.exe = $exe.ToLowerInvariant(); $r.component = $script:QwtDeathExes[$r.exe]
            $r.pid = ConvertTo-QwtDeathUInt32 (& $pos 8) -Hex
            $r.code = ConvertTo-QwtDeathUInt32 (& $pos 6) -Hex; $r.codeKind = 'exception'
            $r.anchor = 'pid'
            $start = & $pos 9
            if ($start -match '^(0x)?([0-9A-Fa-f]{1,16})$') {
                try { $ft = [DateTime]::FromFileTimeUtc([Convert]::ToInt64($Matches[2], 16)); $ms = ($time - $ft).TotalMilliseconds; if ($ms -ge 0 -and $ms -lt 3.2e10) { $r.ranMs = [long]$ms } } catch { }
            }
            $r.detail = "faulting module $(& $pos 3) at offset $(& $pos 7)"
            $r.label = "$($r.exe) crashed"
            return $r
        }
        'Windows Error Reporting' {
            if ($eventId -ne 1001) { $r.reason = "Windows Error Reporting $eventId is not a report record"; return $r }
            $exe = & $pos 5
            if (-not (& $owned $exe '')) { $r.reason = "report for '$exe' is not ours"; return $r }
            $r.ours = $true; $r.kind = 'wer'; $r.rec = 'wer'; $r.exe = $exe.ToLowerInvariant(); $r.component = $script:QwtDeathExes[$r.exe]
            $r.code = ConvertTo-QwtDeathUInt32 (& $pos 11) -Hex; $r.codeKind = 'exception'
            # JOINS, NEVER OPENS: a 1001 carries no path, so it cannot prove the executable is OURS (a foreign autologon.exe's 1000 is
            # refused by its path - its 1001 must not then open a death of ours), and a 1001 alone is a report, e.g. a hang, not a death.
            $r.anchor = 'join-only'   # GUARD:werjoin
            foreach ($p in $positional) { if ($p -match '\\WER\\Report(Queue|Archive)\\') { $r.evidence = $p.Trim(); break } }
            # the WER event name is system text (APPCRASH, BEX64, AppHangB1 ...): rendered only if it is shaped so
            $werEvent = & $pos 2
            if ($werEvent -notmatch '^[A-Za-z0-9]{1,24}$') { $werEvent = 'a report' }
            $r.detail = "WER event $werEvent"
            $r.label = "$($r.exe): Windows Error Reporting recorded $werEvent"
            return $r
        }
        '.NET Runtime' {
            if ($eventId -ne 1026) { $r.reason = ".NET Runtime $eventId is not an unhandled-exception record"; return $r }
            $text = & $pos 0
            $exe = ''
            if ($text -match '(?m)^Application:\s*(\S+)') { $exe = $Matches[1] }
            if (-not (& $owned $exe '') -or $script:QwtDeathManagedExes -notcontains $exe.ToLowerInvariant()) { $r.reason = "managed application '$exe' is not ours"; return $r }   # GUARD:managedonly
            $r.ours = $true; $r.kind = 'clr'; $r.rec = 'clr'; $r.exe = $exe.ToLowerInvariant(); $r.component = $script:QwtDeathExes[$r.exe]
            $r.anchor = 'nopid-adoptable'
            $type = ''
            if ($text -match '(?m)^Exception Info:\s*([A-Za-z0-9_.`+]+)') { $type = $Matches[1] }
            $r.detail = "exception type $type"
            $r.label = "$($r.exe) died of an unhandled .NET exception"
            if ($type) { $r.label += " ($type)" }
            return $r
        }
        'Qubes Windows Tools' {
            if (-not $script:QwtDeathSupervisorIds.ContainsKey($eventId)) { $r.reason = "event $eventId of our source is not a death record"; return $r }
            $exe = & $pos 1
            if (-not (& $owned $exe '')) { $r.reason = "supervised child '$exe' is not in the table"; return $r }
            $r.ours = $true; $r.kind = 'supervisor'; $r.rec = 'supervisor'; $r.exe = $exe.ToLowerInvariant(); $r.component = $script:QwtDeathExes[$r.exe]
            $r.pid = ConvertTo-QwtDeathUInt32 (& $pos 2)
            $codeText = & $pos 3
            if ($codeText -ne 'unknown') { $r.code = ConvertTo-QwtDeathUInt32 $codeText }
            $r.codeKind = 'exit code'
            $ran = & $pos 4
            if ($ran -match '^\d{1,12}$') { $r.ranMs = [long]$ran }
            $r.anchor = 'pid'
            $r.detail = (& $pos 5)
            $r.label = "$($r.exe) exited without being asked to; $($script:QwtDeathSupervisorIds[$eventId])"
            return $r
        }
        'Service Control Manager' {
            if ($eventId -notin 7031, 7034, 7023, 7024) { $r.reason = "Service Control Manager $eventId is not a service-death record"; return $r }
            $display = "$($named['param1'])"
            if (-not $script:QwtDeathServices.ContainsKey($display)) { $r.reason = "service '$display' is not ours"; return $r }
            $r.ours = $true; $r.kind = 'service'; $r.exe = $script:QwtDeathServices[$display]; $r.component = $script:QwtDeathExes[$r.exe]
            if ($eventId -in 7023, 7024) { $r.rec = 'scm-error' } else { $r.rec = 'scm-unexpected' }
            # the SCM's own fields are rendered only through a number or a known phrase, never verbatim
            $count = "$($named['param2'])"
            if ($count -notmatch '^\d{1,6}$') { $count = '?' }
            $delay = "$($named['param3'])"
            if ($delay -notmatch '^\d{1,9}$') { $delay = '?' }
            $action = "$($named['param4'])"
            if ($action -notmatch '^[A-Za-z ]{1,40}$') { $action = 'the configured action' }
            switch ($eventId) {
                7023 { $r.code = ConvertTo-QwtDeathUInt32 "$($named['param2'])"; $r.codeKind = 'error'; $r.anchor = 'nopid'
                       $r.label = "service '$display' ($($r.exe)) ended with an error; SCM recovery restarts it" }
                7024 { $r.code = ConvertTo-QwtDeathUInt32 "$($named['param2'])"; $r.codeKind = 'service-specific error'; $r.anchor = 'nopid'
                       $r.label = "service '$display' ($($r.exe)) ended with an error; SCM recovery restarts it" }
                7031 { $r.anchor = 'enrich'
                       $r.label = "service '$display' ($($r.exe)) terminated unexpectedly, time $count per the SCM; recovery: $action in $delay ms" }
                7034 { $r.anchor = 'enrich'
                       $r.label = "service '$display' ($($r.exe)) terminated unexpectedly, time $count per the SCM; NO recovery action is configured" }
            }
            return $r
        }
        'Microsoft-Windows-TaskScheduler' {
            if ($eventId -notin 201, 203) { $r.reason = "TaskScheduler $eventId is not a task-failure record"; return $r }
            $task = "$($named['TaskName'])"
            $code = ConvertTo-QwtDeathUInt32 "$($named['ResultCode'])"
            if ($script:QwtDeathHelperTasks.ContainsKey($task)) {
                # JOINS, NEVER OPENS: the agent supervises its helpers and writes 4002/4003 (pid, exit code) for every exit it did not
                # ask for; the task's 201 is a second record of that death. When the agent itself ends the task (schtasks /delete ends a
                # running instance), there is no 4002/4003 and the 201 is not a death.
                $r.exe = $script:QwtDeathHelperTasks[$task]; $r.component = $script:QwtDeathExes[$r.exe]; $r.anchor = 'join-only'   # GUARD:helperjoin
            } elseif ($task -in $script:QwtDeathScriptTasks) {
                $r.exe = ("task:" + $task.TrimStart('\')).ToLowerInvariant(); $r.component = ConvertTo-QwtDeathComponent $task.TrimStart('\'); $r.anchor = 'nopid'
            } else {
                $r.reason = "task '$task' is not ours"; return $r
            }
            if ($eventId -eq 201) {
                if ($null -eq $code -or $code -eq 0) { $r.reason = "task '$task' ended with result 0"; return $r }
                if ($code -eq 267014) { $r.ignore = $true; $r.reason = "task '$task' was ENDED by Task Scheduler (0x41306) - a stop that was asked for, not a death"; return $r }
                $r.ours = $true; $r.kind = 'task'; $r.rec = 'task-result'; $r.code = $code; $r.codeKind = 'result'
                if ($script:QwtDeathHelperTasks.ContainsKey($task)) { $r.label = "$($r.exe) (task $($task.TrimStart('\'))) ended with a non-zero result" }
                else { $r.label = "task $($task.TrimStart('\')) ended with a non-zero result" }
            } else {
                $r.ours = $true; $r.kind = 'launchfail'; $r.rec = 'task-launch'; $r.code = $code; $r.codeKind = 'result'; $r.anchor = 'nopid'
                $r.label = "task $($task.TrimStart('\')) could not start its action"
            }
            return $r
        }
        default { $r.reason = "provider '$provider' event $eventId is not in the subscription"; return $r }
    }
}

# --- the per-boot ledger: which death is this? -----------------------------------------------------
function Read-QwtDeathLedger {
    param([long]$Boot)
    $path = Join-Path $script:QwtDeathStateDir 'deaths.ledger'
    $deaths = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $path)) { return ,$deaths }   # the comma keeps an empty list a list
    $lines = @([IO.File]::ReadAllLines($path))
    if ($lines.Count -eq 0 -or $lines[0] -ne "boot=$Boot") { return ,$deaths }   # another boot's ledger: start afresh
    foreach ($l in $lines) {
        $f = $l -split '\|'
        if ($f.Count -ge 7 -and $f[0] -eq 'D') {
            $p = $null
            if ($f[4] -match '^\d+$') { $p = [uint32]$f[4] }
            $recs = ''
            if ($f.Count -ge 8) { $recs = $f[7] }
            [void]$deaths.Add([pscustomobject]@{ n = [int]$f[1]; t = [long]$f[2]; exe = $f[3]; pid = $p; kind = $f[5]; origin = $f[6]; recs = $recs })
        }
    }
    return ,$deaths
}
function Write-QwtDeathLedger {
    param([long]$Boot, $Deaths, [string]$Append)
    $path = Join-Path $script:QwtDeathStateDir 'deaths.ledger'
    if (-not (Test-Path -LiteralPath $script:QwtDeathStateDir)) { New-Item -ItemType Directory -Path $script:QwtDeathStateDir -Force | Out-Null }
    $out = New-Object System.Collections.ArrayList
    [void]$out.Add("boot=$Boot")
    foreach ($d in $Deaths) {
        $p = ''
        if ($null -ne $d.pid) { $p = "$($d.pid)" }
        [void]$out.Add(('D|{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f $d.n, $d.t, $d.exe, $p, $d.kind, $d.origin, $d.recs))
    }
    if ($Append) { [void]$out.Add($Append) }
    [IO.File]::WriteAllText($path, (($out -join "`n") + "`n"), [Text.Encoding]::ASCII)
}
function ConvertTo-QwtDeathEpoch { param([DateTime]$T) return [long](($T.ToUniversalTime() - [DateTime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)).TotalSeconds) }

# Decides NEW vs. another record of a counted death; returns @{ new; number }. Never throws.
function Register-QwtDeath {
    param([Parameter(Mandatory)]$Death, [Parameter(Mandatory)][long]$Boot)
    $deaths = Read-QwtDeathLedger -Boot $Boot
    $t = ConvertTo-QwtDeathEpoch $Death.time
    $w = [long]$script:QwtDeathWindowSec
    $match = $null
    $sameExe = @($deaths | Where-Object { $_.exe -eq $Death.exe -and [Math]::Abs($_.t - $t) -le $w } | Sort-Object t -Descending)
    switch ($Death.anchor) {
        'pid' {
            $match = @($sameExe | Where-Object { $null -ne $_.pid -and $_.pid -eq $Death.pid }) | Select-Object -First 1   # GUARD:anchorpid
            if ($match -and @($match.recs -split ',') -contains $Death.rec) { $match = $null }   # GUARD:pidreuse
            if (-not $match) {
                # a managed crash: the 1026 came first with no pid; its 1000 carries the pid - adopt it
                $adopt = @($sameExe | Where-Object { $null -eq $_.pid -and $_.kind -eq 'clr' -and [Math]::Abs($_.t - $t) -le $script:QwtDeathAdoptSec }) | Select-Object -First 1
                if ($adopt) { $adopt.pid = $Death.pid; $match = $adopt }
            }
        }
        # ONE RECORD OF EACH TYPE PER DEATH: a pid-less record (a 1001, a 7031/7034, a helper task's 201) joins the newest death of
        # its executable that does not hold a record of its type yet. A second 7031 inside the window is a SECOND death - a service
        # that keeps exiting without a crash record leaves nothing but 7031s, and the SCM restarts it at 5 s, 15 s and 60 s (measured
        # offline 2026-10-03: three such deaths in 80 s were one notification before this rule).
        'enrich' { $match = @($sameExe | Where-Object { @($_.recs -split ',') -notcontains $Death.rec }) | Select-Object -First 1 }   # GUARD:onerec
        'join-only' {
            $match = @($sameExe | Where-Object { @($_.recs -split ',') -notcontains $Death.rec }) | Select-Object -First 1
            if (-not $match) { return @{ new = $false; number = 0; joined = $false } }   # nothing to join: not a death on its own
        }
        default { $match = $null }   # nopid, nopid-adoptable: always a new death
    }
    if ($match) {
        if (@($match.recs -split ',') -notcontains $Death.rec) { $match.recs = "$($match.recs),$($Death.rec)" }
        Write-QwtDeathLedger -Boot $Boot -Deaths $deaths -Append ('E|{0}|{1}|{2}' -f $match.n, $t, $Death.origin)
        return @{ new = $false; number = [int]$match.n; joined = $true }
    }
    $n = $deaths.Count + 1
    $kind = $Death.kind
    if ($Death.anchor -eq 'nopid-adoptable') { $kind = 'clr' }
    [void]$deaths.Add([pscustomobject]@{ n = $n; t = $t; exe = $Death.exe; pid = $Death.pid; kind = $kind; origin = $Death.origin; recs = $Death.rec })
    Write-QwtDeathLedger -Boot $Boot -Deaths $deaths -Append ''
    return @{ new = $true; number = $n; joined = $false }
}

# --- the text ----------------------------------------------------------------------------------------
function Format-QwtDeathNotice {
    param([Parameter(Mandatory)]$Death, [Parameter(Mandatory)][int]$Number)
    $parts = New-Object System.Collections.ArrayList
    [void]$parts.Add("DIED: $($Death.label)")
    if ($Death.kind -in 'crash', 'wer', 'supervisor', 'service', 'task', 'launchfail') {
        if ($null -ne $Death.code -or $Death.kind -in 'crash', 'supervisor') { [void]$parts.Add((Format-QwtDeathCode $Death.code $Death.codeKind)) }
    }
    if ($Death.kind -in 'crash', 'supervisor') { [void]$parts.Add("after running " + (Format-QwtDeathRun $Death.ranMs)) }
    [void]$parts.Add("death $Number this boot")
    $summary = ($parts -join '; ')
    $logDir = Get-QwtDeathLogDir
    $hint = "$logDir\qwt-deaths.log"
    switch ($Death.kind) {
        'crash'      { $hint += "; WER ReportQueue or ReportArchive, folder AppCrash_$($Death.exe)_*; Application log event 1000" }
        'wer'        { $hint += "; WER ReportQueue or ReportArchive, folder AppCrash_$($Death.exe)_*; Application log event 1001" }
        'clr'        { $hint += "; Application log, .NET Runtime event 1026" }
        'supervisor' { $hint += "; Application log, source Qubes Windows Tools" }
        'service'    { $hint += "; System log, Service Control Manager" }
        default      { $hint += "; Task Scheduler history (TaskScheduler/Operational)" }
    }
    return @{ Component = $Death.component; Summary = $summary; LogPath = $hint }
}

# --- the whole thing for one record: log at ERROR, count, notify ----------------------------------
# Returns the route's status for a new death, 'enriched' for another record of a counted one,
# 'not-ours' / 'ignored' otherwise.
function Invoke-QwtDeathReport {
    param([Parameter(Mandatory)][string]$XmlText)
    $ev = ConvertFrom-QwtDeathEvent -XmlText $XmlText
    if (-not $ev.ours) {
        if ($ev.ignore) { Write-QwtDeathLog 'INFO' "$($ev.origin) ignored: $($ev.reason)"; return 'ignored' }
        Write-QwtDeathLog 'INFO' "$($ev.origin) not ours: $($ev.reason)"
        return 'not-ours'
    }
    $boot = $null
    if (Get-Command Get-QwtNotifyBootStamp -ErrorAction SilentlyContinue) { $boot = Get-QwtNotifyBootStamp }
    if ($null -eq $boot) {
        # No boot identity: the death cannot be counted and the route will refuse. Still an ERROR here.
        Write-QwtDeathLog 'ERROR' "DEATH $($ev.origin) $($ev.label) - NO per-boot token (qwt-notify-error.ps1 absent or its volatile key unreadable): not counted, not notified; the record is in the event log"
        return 'failed:transport'
    }
    $reg = Register-QwtDeath -Death $ev -Boot $boot
    if (-not $reg.new -and $reg.number -eq 0) {
        Write-QwtDeathLog 'INFO' "$($ev.origin) $($ev.label) - a $($ev.rec) record joins a death another record reported, and no death of $($ev.exe) in the last $($script:QwtDeathWindowSec) s lacks one: not a death on its own"
        return 'not-a-death'
    }
    $notice = Format-QwtDeathNotice -Death $ev -Number $reg.number
    $tag = 'AGAIN'
    if ($reg.new) { $tag = 'NEW' }
    $extra = ''
    if ($ev.evidence) { $extra += "; evidence $($ev.evidence)" }
    if ($ev.detail) { $extra += "; $($ev.detail)" }
    if ($null -ne $ev.pid) { $extra += "; pid $($ev.pid)" }
    Write-QwtDeathLog 'ERROR' "DEATH #$($reg.number) $tag $($ev.origin): $($notice.Summary)$extra"   # GUARD:logfirst
    if (-not $reg.new) { return 'enriched' }
    if (-not (Get-Command Send-QwtError -ErrorAction SilentlyContinue)) {
        Write-QwtDeathLog 'ERROR' "DEATH #$($reg.number) NOT notified: qwt-notify-error.ps1 is not next to this script (packaging gap in the reporting path)"
        return 'failed:transport'
    }
    $id = 'death-' + $reg.number   # GUARD:deathid
    $st = Send-QwtError -Component $notice.Component -Id $id -Severity ACTION -Summary $notice.Summary -LogPath $notice.LogPath
    if ($st -eq 'send') { Write-QwtDeathLog 'INFO' "DEATH #$($reg.number) notified to dom0 as $($notice.Component).$id" }
    elseif ($st -eq 'suppressed:cap') { Write-QwtDeathLog 'ERROR' "DEATH #$($reg.number) NOT notified: the route's cap of 8 per boot is reached (a crash storm); every further death is still logged here" }
    else { Write-QwtDeathLog 'ERROR' "DEATH #$($reg.number) NOT notified: route status $st" }
    return $st
}

# --- main: the task's action ------------------------------------------------------------------------
if (-not $script:QwtDeathLibraryOnly) {
    $exitCode = 0
    try {
        $xmlText = $null
        if ($EventXmlFile) {
            $xmlText = [IO.File]::ReadAllText($EventXmlFile)
        } elseif ($Channel -and $RecordId -gt 0) {
            $e = Get-WinEvent -LogName $Channel -FilterXPath "*[System[EventRecordID=$RecordId]]" -MaxEvents 1 -ErrorAction Stop
            $xmlText = $e.ToXml()
        } else {
            Write-QwtDeathLog 'ERROR' 'usage: -Channel <log> -RecordId <n> (the task''s ValueQueries), or -EventXmlFile <file>'
            $exitCode = 2
        }
        if ($xmlText) { [void](Invoke-QwtDeathReport -XmlText $xmlText) }
    } catch {
        Write-QwtDeathLog 'ERROR' "reporter failed on $Channel record $RecordId : $($_.Exception.Message)"
        $exitCode = 1
    }
    exit $exitCode
}
