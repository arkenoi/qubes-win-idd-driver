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
# THE NOTIFICATION. Each NEW death is sent as component <machine id>, id death-<n> (n = this boot's death
# count), severity ACTION: a distinct id per death, so the route's once-per-(component, id)-per-boot rule
# cannot hide a second death; the route's cap of 8 per boot still bounds a crash storm. Past the cap - and
# whatever the route decides - every death is logged at ERROR here first, in qwt-deaths.log. The text has
# the ONE shape every sender uses (qwt-notify-error.ps1, the agent's notifyerr.h; rz39):
#   header   "The <human name> crashed / exited unexpectedly / stopped answering / service stopped with an
#            error / task failed ..." - human names only, no codes, no file names, no counts
#   line 1   what it means and what happens next: who relaunches it (the watchdog, the agent, Windows'
#            recovery as the registry has it armed), what is withheld meanwhile, what the user can do
#   line 2   "Cause: <meaning> - <code>." The meaning comes from the table of the code's SOURCE: the process
#            table for a crash's exception or a supervisor's exit code (plus the codes an executable
#            documents), the Windows-error table for the SCM's 7023, no table for a service-specific 7024
#            (the service defines it), the task-result table for 201/203. Never the process table for the
#            others ("ended by TerminateProcess" for a task result was rz39 defect 3).
#   line 3   the technical line: executable, pid, code, run time, "death n this boot", the evidence (this
#            log, the WER folder by prefix, the event log and id)
# No window titles, no user data: every name in the text comes from the tables below, every number is
# parsed and re-rendered, the WER folder is named by its prefix (its hash would trip the route's redaction
# and tells a human nothing), and a .NET exception type the route would refuse is left out.
#
# Windows PowerShell 5.1 (no ternary, no ??, no && chains). Offline suites: tools/tests/death-reporter-test.ps1
# (identity, count, parsing) and tools/tests/notify-render-test.ps1 (every rendering held to the text rules),
# both under pwsh on Linux; they dot-source this file with $script:QwtDeathLibraryOnly = $true and the hooks
# below replaced; lines tagged `# GUARD:<name>` are each replaced by tools/tests/death-reporter-selftest.sh or
# tools/tests/notify-render-selftest.sh to prove the suite sees that guard fail. Keep each guard on ONE line.
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
# THE SCM'S RECOVERY SETTINGS of a service of ours, from the registry (what guest/health-check.ps1 reads): whether a restart is
# armed, after how long, and whether it also applies to an exit with an error (FailureActionsOnNonCrashFailures - without it the
# SCM restarts a service only after a crash). The text says what Windows will do, from this; $null = unreadable, and then it
# says "only if its recovery is armed" rather than guessing. A test replaces the probe.
if (-not $script:QwtDeathRecoveryProbe) {
    $script:QwtDeathRecoveryProbe = {
        param([string]$Key)
        if (-not $Key) { return $null }
        $k = "HKLM:\SYSTEM\CurrentControlSet\Services\$Key"
        if (-not (Test-Path -LiteralPath $k)) { return $null }
        $r = @{ restart = $false; delayMs = 0; onError = $false }
        $fa = (Get-ItemProperty -LiteralPath $k -Name 'FailureActions' -ErrorAction SilentlyContinue).FailureActions
        if ($fa -and $fa.Count -ge 20) {
            $n = [int][BitConverter]::ToUInt32($fa, 12)
            $off = [int][BitConverter]::ToUInt32($fa, 16)
            if ($n -gt 0 -and ($off + 8) -le $fa.Count -and [BitConverter]::ToUInt32($fa, $off) -eq 1) {   # SC_ACTION_RESTART first
                $r.restart = $true
                $r.delayMs = [int][BitConverter]::ToUInt32($fa, $off + 4)
            }
        }
        $flag = (Get-ItemProperty -LiteralPath $k -Name 'FailureActionsOnNonCrashFailures' -ErrorAction SilentlyContinue).FailureActionsOnNonCrashFailures
        if ($null -ne $flag) { $r.onError = ([int]$flag -eq 1) }
        return $r
    }
}

# --- the tables: what is OURS (kept in step with Register-QwtDeathReporter's subscription by
#     tools/tests/death-reporter-xpath-selftest.py) ------------------------------------------------
# executable -> component name for the route (its MACHINE ID: <= 24 chars of [a-z0-9-], the route's name rule)
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
# executable -> its HUMAN NAME, what the header says ("The GUI agent crashed"); the agent's Event Log records
# (include/deathevent.h) and its own notifications (notifytexts.h) use the same names
$script:QwtDeathHuman = @{
    'gui-agent.exe' = 'GUI agent'; 'gui-watchdog.exe' = 'GUI agent watchdog'; 'qubesdb-daemon.exe' = 'QubesDB daemon'
    'qubesdb-cmd.exe' = 'QubesDB command tool'; 'qrexec-agent.exe' = 'Qubes RPC agent'; 'qrexec-client-vm.exe' = 'Qubes RPC client'
    'qrexec-wrapper.exe' = 'Qubes RPC command wrapper'; 'network-setup.exe' = 'network setup tool'; 'advertise-tools.exe' = 'tools advertiser'
    'clipboard-copy.exe' = 'clipboard copy tool'; 'clipboard-paste.exe' = 'clipboard paste tool'; 'file-receiver.exe' = 'file receiver'
    'file-sender.exe' = 'file sender'; 'get-image-rgba.exe' = 'icon exporter'; 'open-in-vm.exe' = 'open-in-VM handler'
    'open-url.exe' = 'URL opener'; 'set-gui-mode.exe' = 'GUI mode switch'; 'vm-file-editor.exe' = 'file editor handler'
    'wait-for-logon.exe' = 'logon waiter'; 'relocate-dir.exe' = 'directory relocator'; 'autologon.exe' = 'autologon tool'
    'wgcbroker.exe' = 'notification and menu capture helper'; 'notifhost.exe' = 'notification bridge'; 'etwproxy.exe' = 'ETW signal proxy'
    'bind-dirs.exe' = 'bind-dirs tool'; 'qubesdb-read.exe' = 'QubesDB reader'
    'qubes-updates-relay.exe' = 'updates relay'; 'qwtng-netsetup.exe' = 'PV NIC address applier'
}
# WHAT HAPPENS NEXT when one of ours dies, by executable - the supervisors' measured behaviour (watchdog.c, main.c,
# etwproxy.c); a service's answer comes from the SCM's recovery settings (below), a one-shot tool's is "nothing"
$script:QwtDeathNextByExe = @{
    'gui-agent.exe' = 'The GUI agent watchdog relaunches it (backing off while it keeps dying quickly); this qube''s windows close in dom0 until it is back - if they do not reopen, restart the qube.'
    'wgcbroker.exe' = 'The GUI agent relaunches it within about 8 s; until then, menus, modern app windows and notification windows do not appear in dom0.'
    'notifhost.exe' = 'The GUI agent relaunches it, at most once per 60 s; guest toasts show as plain windows meanwhile.'
    'etwproxy.exe' = 'The GUI agent relaunches it, waiting 5 s to 5 min between tries; notifications still reach dom0 meanwhile, through the bridge''s other two sources.'
    'qubes-updates-relay.exe' = 'Nothing relaunches it; the update pass it was serving has lost its network path and cannot finish.'
}
# the ETW signal proxy's rights failures (its exit codes 5 and 9): the agent parks it instead of relaunching
$script:QwtDeathEtwParked = 'The GUI agent stops relaunching it for this boot (a rights problem a relaunch cannot fix); notifications still reach dom0 through the bridge''s other two sources.'
# one-shot programs: the RPC handlers dom0 invokes, and the setup/boot-time tools
$script:QwtDeathRpcExes = @('clipboard-copy.exe', 'clipboard-paste.exe', 'file-receiver.exe', 'file-sender.exe', 'get-image-rgba.exe',
                            'open-in-vm.exe', 'open-url.exe', 'vm-file-editor.exe', 'set-gui-mode.exe', 'qrexec-client-vm.exe',
                            'qrexec-wrapper.exe', 'qubesdb-cmd.exe', 'qubesdb-read.exe')
$script:QwtDeathNextRpc = 'Nothing relaunches it: the request it was handling failed - repeat the action from dom0.'
$script:QwtDeathNextOneShot = 'Nothing relaunches it; the step it was performing did not complete.'
# where each supervised child's own evidence is (the technical line), beyond this log and the event record
$script:QwtDeathLogHints = @{
    'gui-agent.exe' = 'the gui-agent and watchdog logs in {0}'
    'wgcbroker.exe' = 'gui-agent log lines QGABROKEREXIT and QGABROKERDIED in {0}'
    'notifhost.exe' = 'bridge.log in ProgramData\qubes-toast-bridge'
    'etwproxy.exe' = 'etw-proxy.log and gui-agent log line ETWPROXYSUP in {0}'
}
$script:QwtDeathLogHintHung = 'gui-agent log lines QGABROKERHUNG and QGABROKERDIED in {0}'
# OUR MANAGED executables (compiled on the guest from C#): the only ones a .NET Runtime 1026 can be ours for - a 1026 carries no path,
# so a foreign .NET program that shares one of our generic names (autologon.exe, bind-dirs.exe ...) must not count
$script:QwtDeathManagedExes = @('qubes-updates-relay.exe', 'qwtng-netsetup.exe')
# service DISPLAY name (what the SCM's param1 carries) -> executable
$script:QwtDeathServices = @{
    'QubesDB daemon' = 'qubesdb-daemon.exe'; 'Qubes RPC agent' = 'qrexec-agent.exe'
    'Qubes GUI agent watchdog' = 'gui-watchdog.exe'; 'Qubes PV NIC address applier' = 'qwtng-netsetup.exe'
}
# service DISPLAY name -> its service key (the recovery settings live under it)
$script:QwtDeathServiceKeys = @{
    'QubesDB daemon' = 'QdbDaemon'; 'Qubes RPC agent' = 'QrexecAgent'
    'Qubes GUI agent watchdog' = 'QubesGuiWatchdog'; 'Qubes PV NIC address applier' = 'QwtngNetSetup'
}
# what a service's absence means (line 1, after what Windows does)
$script:QwtDeathServiceImpact = @{
    'qrexec-agent.exe' = 'while it is down this qube cannot be reached from dom0'
    'qubesdb-daemon.exe' = 'while it is down the Qubes RPC agent, which depends on it, cannot run'
    'gui-watchdog.exe' = 'while it is down the GUI agent is not supervised'
    'qwtng-netsetup.exe' = 'while it is down a newly attached PV NIC gets no address'
}
# tasks whose action IS a helper of ours (its 201 is another record of the helper's death)
$script:QwtDeathHelperTasks = @{ '\Qubes-WgcBroker' = 'wgcbroker.exe'; '\Qubes-NotifBridge' = 'notifhost.exe' }
# tasks whose action is a script of ours (a non-zero 201 or a 203 is a death of its own)
$script:QwtDeathScriptTasks = @('\QubesPvNic', '\QubesPvNicRearm', '\QubesNetworkReapply', '\QubesQuietDesktopGuard',
                                '\QubesAutologonGuard', '\QubesWindowsUpdateScan', '\QubesWindowsUpdateRun',
                                '\QubesWindowsUpdateDownload', '\QwtImprovedSetup')
# each script task's MACHINE ID (the route component, in the same style as the executables'), its HUMAN NAME, and what its
# failure means (line 1) - from the tasks' own registrations (their <Description>)
$script:QwtDeathTaskNames = @{
    '\QubesPvNic'                 = @{ id = 'pvnic';           human = 'PV NIC setup task';             impact = 'The PV NIC setup did not complete: the guest''s network may stay unconfigured until it runs again.' }
    '\QubesPvNicRearm'            = @{ id = 'pvnic-rearm';     human = 'PV NIC re-arm task';            impact = 'The PV NIC latch was not re-armed at shutdown: the next boot''s PV NIC binding is at risk.' }
    '\QubesNetworkReapply'        = @{ id = 'network-reapply'; human = 'network re-apply task';         impact = 'The network configuration was not re-applied for the interface that appeared.' }
    '\QubesQuietDesktopGuard'     = @{ id = 'quiet-desktop';   human = 'quiet-desktop guard task';      impact = 'The consumer-nag policies were not re-asserted this boot; Windows may show its nags again.' }
    '\QubesAutologonGuard'        = @{ id = 'autologon-guard'; human = 'autologon guard task';          impact = 'Autologon was not re-asserted: after an update or a sign-out this qube may stop at the sign-in screen, unreachable in seamless mode.' }
    '\QubesWindowsUpdateScan'     = @{ id = 'update-scan';     human = 'Windows Update scan task';      impact = 'The Windows Update scan did not complete; dom0 gets no fresh availability report from it.' }
    '\QubesWindowsUpdateRun'      = @{ id = 'update-run';      human = 'Windows Update install task';   impact = 'The Windows update pass did not complete; dom0''s update run reports the failure.' }
    '\QubesWindowsUpdateDownload' = @{ id = 'update-download'; human = 'Windows Update download task';  impact = 'The update download pass did not complete; dom0''s update run reports the failure.' }
    '\QwtImprovedSetup'           = @{ id = 'qwt-setup';       human = 'Qubes Tools setup task';        impact = 'The Qubes Tools setup step did not complete; the install may be unfinished - its log says where it stopped.' }
}
# our own source: event id -> the supervisor that wrote it (include/deathevent.h)
$script:QwtDeathSupervisorIds = @{ 4001 = 'the GUI agent watchdog'; 4002 = 'the GUI agent'; 4003 = 'the GUI agent'; 4004 = 'the GUI agent' }

# --- the code tables, ONE PER SOURCE (the meaning of a code depends on who reports it) --------------
$script:QwtDeathCodeTables = @{
    # a process exit or exception code: a crash record's exception, a supervisor's exit code
    process = @{
        [uint32]0xC0000005L = 'an access violation'
        [uint32]0xC0000409L = 'a fast-fail abort (stack buffer overrun, __fastfail or an abort)'
        [uint32]0xC0000374L = 'heap corruption'
        [uint32]0xC00000FDL = 'a stack overflow'
        [uint32]0xC0000017L = 'out of memory'
        [uint32]0xC000001DL = 'an illegal instruction'
        [uint32]0xC0000094L = 'an integer divide by zero'
        [uint32]0xC0000096L = 'a privileged instruction'
        [uint32]0xC0000008L = 'an invalid handle'
        [uint32]0xC0000420L = 'an assertion failure'
        [uint32]0xE06D7363L = 'an unhandled C++ exception'
        [uint32]0xE0434352L = 'an unhandled .NET exception'
        [uint32]0xC000013AL = 'a console control (Ctrl-C, or the console closed)'
        [uint32]0xC0000142L = 'a DLL failed to initialize'
        [uint32]0xC0000135L = 'a DLL was not found'
        [uint32]0 = 'a clean exit nobody asked for'
        [uint32]1 = 'exit code 1 - the code TerminateProcess imposes (an external force-kill), or the program''s own failure exit'
    }
    # a Windows error the Service Control Manager reports (event 7023: the service ended with this error)
    win32 = @{
        [uint32]2 = 'a file was not found'; [uint32]3 = 'a path was not found'; [uint32]5 = 'access denied'
        [uint32]6 = 'an invalid handle'; [uint32]8 = 'not enough memory'; [uint32]32 = 'a sharing violation'
        [uint32]87 = 'an invalid parameter'
        [uint32]1053 = 'the service did not respond to the start or control request in time'
        [uint32]1056 = 'an instance of the service is already running'; [uint32]1058 = 'the service is disabled'
        [uint32]1060 = 'the service does not exist'; [uint32]1062 = 'the service has not been started'
        [uint32]1067 = 'the process terminated unexpectedly'; [uint32]1068 = 'a service it depends on failed to start'
        [uint32]1069 = 'the service could not log on'; [uint32]1115 = 'a system shutdown is in progress'
        [uint32]1450 = 'insufficient system resources (on this guest: an exhausted Xen grant table, which only a reboot clears)'
        [uint32]1460 = 'the operation timed out'; [uint32]1722 = 'the RPC server is unavailable'
        [uint32]10054 = 'the connection was reset by the peer'
    }
    # a Task Scheduler result (events 201/203): HRESULTs, the scheduler's own codes, a script task's own exit code
    task = @{
        [uint32]0x80070002L = 'the file was not found'; [uint32]0x80070005L = 'access denied'
        [uint32]0x80070420L = 'an instance of the task is already running'
        [uint32]0x800710E0L = 'the operator or administrator refused the request'
        [uint32]0x80070569L = 'the account is not granted this logon type'
        [uint32]0x8007052EL = 'the account could not log on (its sign-in details were rejected)'
        [uint32]0x8007010BL = 'the working directory is invalid'; [uint32]0x80070001L = 'incorrect function'
        [uint32]0x41301 = 'the task is currently running'; [uint32]0x41303 = 'the task has not yet run'
        [uint32]0x41306 = 'the last run was ended by Task Scheduler'
        [uint32]1 = 'the script reported a failure or hit an error it did not handle'
    }
}
# exit codes an executable of ours documents (the process table's per-executable refinement)
$script:QwtDeathExeCodes = @{
    'notifhost.exe' = @{ [uint32]2 = 'notification access is denied for this user (the toast listener may not read toasts)'
                         [uint32]3 = 'the toast listener threw while starting' }
    'etwproxy.exe'  = @{ [uint32]5 = 'trace access was denied under the per-session DACL'
                         [uint32]7 = 'the trace consumer could not be opened'
                         [uint32]8 = 'its pipe could not be created'
                         [uint32]9 = 'it refused to run under an account that is not SYSTEM' }
}

# --- the route (qwt-notify-error.ps1, shipped next to this file) -------------------------------
if (-not (Get-Command Send-QwtError -ErrorAction SilentlyContinue)) {
    if (Test-Path -LiteralPath $script:QwtDeathHelper) { . $script:QwtDeathHelper }
}
# the technical line's shape is the route's (Format-QwtNotifyTechLine); without the route nothing is notified, but the
# log line is still formed - the same shape, so the two cannot drift
if (-not (Get-Command Format-QwtNotifyTechLine -ErrorAction SilentlyContinue)) {
    function Format-QwtNotifyTechLine {
        param([string]$Subject, [long]$ProcessId = 0, [string]$Code = '', [string]$Ran = '', [string]$Count, [string]$Evidence)
        $t = $Subject
        if ($ProcessId -gt 0) { $t += " pid $ProcessId" }
        if ($Code) { $t += "; $Code" }
        if ($Ran) { $t += "; ran $Ran" }
        return "$t; $Count. Evidence: $Evidence."
    }
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
# an exception code (NTSTATUS error severity, or a customer-bit exception such as 0xE06D7363): a crash, whoever reports the number
function Test-QwtDeathExceptionCode {
    param($Code)
    if ($null -eq $Code) { return $false }
    return (([uint32]$Code -band [uint32]0xC0000000L) -eq [uint32]0xC0000000L)
}
# the meaning of a code FROM ITS SOURCE'S TABLE: process (with the executable's own codes first), win32, service (none of ours:
# the service defines it), task (a crash code in a task result is the program's exit status, said as such)
function Get-QwtDeathCodeMeaning {
    param($Code, [string]$Source = 'process', [string]$Exe = '')
    if ($null -eq $Code) { return '' }
    $c = [uint32]$Code
    if ($Source -eq 'service') { return '' }
    if ($Source -eq 'process' -and $Exe -and $script:QwtDeathExeCodes.ContainsKey($Exe) -and $script:QwtDeathExeCodes[$Exe].ContainsKey($c)) { return $script:QwtDeathExeCodes[$Exe][$c] }
    $table = $script:QwtDeathCodeTables[$Source]   # GUARD:codetable
    if ($Source -eq 'task' -and (Test-QwtDeathExceptionCode $c)) {
        $m = $script:QwtDeathCodeTables['process'][$c]
        if ($m) { return "its program crashed with $m" }
        return 'its program crashed'
    }
    if ($null -eq $table) { return '' }
    $m = $table[$c]
    if ($m) { return $m }
    return ''
}
# "<kind> <code>": hex (0x%08X) for a large code, decimal for a small one; "<kind> unknown" for none
function Format-QwtDeathCode {
    param($Code, [string]$Kind = 'code')
    if ($null -eq $Code) { return "$Kind unknown" }
    $c = [uint32]$Code
    $txt = $null
    if ($c -ge 0x10000) { $txt = ('0x{0:X8}' -f $c) } else { $txt = "$c" }
    return "$Kind $txt"
}
# "Cause: <meaning> - <code>." from the source's table; a code the table does not know is said to be unknown, never guessed
function Format-QwtDeathCause {
    param($Code, [string]$Source, [string]$Exe, [string]$CodeText, [string]$DetailWhere)
    $m = Get-QwtDeathCodeMeaning $Code $Source $Exe
    if ($m) {
        if ($m -like "$CodeText *") { return "Cause: $m." }   # the meaning already opens with the code (exit code 1)
        return "Cause: $m - $CodeText."
    }
    return "Cause: $CodeText - not a code this reporter knows; $DetailWhere has the detail."
}
function Format-QwtDeathRun {
    param($Ms)
    if ($null -eq $Ms) { return '' }
    $ts = [TimeSpan]::FromMilliseconds([double]$Ms)
    return ('{0}:{1:00}:{2:00}' -f [int][Math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds)
}
function Get-QwtDeathNodeText {
    param([xml]$Doc, [string]$Name)
    $n = $Doc.GetElementsByTagName($Name)
    if ($n.Count -gt 0) { return "$($n[0].InnerText)" }
    return ''
}

# --- the event -> a death record, or $null when the record is not one of ours --------------------
# Returns [ordered]@{ ours; ignore; reason; kind; origin; time; exe; component; pid; code; ranMs; anchor; label; evidence; detail;
#                     rec; eventId; hung; clrType; task; taskName; svcKey; svcCount; svcDelay; svcAction }
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
                     exe = ''; component = ''; pid = $null; code = $null; ranMs = $null
                     anchor = 'enrich'; label = ''; evidence = ''; detail = ''; rec = ''; eventId = $eventId
                     hung = $false; clrType = ''; task = ''; taskName = ''; svcKey = ''; svcCount = ''; svcDelay = ''; svcAction = '' }

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
            $r.code = ConvertTo-QwtDeathUInt32 (& $pos 6) -Hex
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
            $r.code = ConvertTo-QwtDeathUInt32 (& $pos 11) -Hex
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
            $r.clrType = $type
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
            # the exit-code field: a number, "unknown" (an exit nobody observed), or "hung" - the child was still running but
            # stopped answering and its supervisor ended it (include/deathevent.h DEATHEVENT_EXIT_HUNG); a hang is rendered as a hang
            $codeText = & $pos 3
            if ($codeText -eq 'hung') { $r.hung = $true }   # GUARD:hang
            if ($codeText -notin 'hung', 'unknown') { $r.code = ConvertTo-QwtDeathUInt32 $codeText }
            $ran = & $pos 4
            if ($ran -match '^\d{1,12}$') { $r.ranMs = [long]$ran }
            $r.anchor = 'pid'
            $r.detail = (& $pos 5)
            if ($r.hung) { $r.label = "$($r.exe) stopped answering (a hang) and was ended by $($script:QwtDeathSupervisorIds[$eventId])" }
            else { $r.label = "$($r.exe) exited without being asked to" }
            return $r
        }
        'Service Control Manager' {
            if ($eventId -notin 7031, 7034, 7023, 7024) { $r.reason = "Service Control Manager $eventId is not a service-death record"; return $r }
            $display = "$($named['param1'])"
            if (-not $script:QwtDeathServices.ContainsKey($display)) { $r.reason = "service '$display' is not ours"; return $r }
            $r.ours = $true; $r.kind = 'service'; $r.exe = $script:QwtDeathServices[$display]; $r.component = $script:QwtDeathExes[$r.exe]
            $r.svcKey = "$($script:QwtDeathServiceKeys[$display])"
            if ($eventId -in 7023, 7024) { $r.rec = 'scm-error' } else { $r.rec = 'scm-unexpected' }
            # the SCM's own fields are rendered only through a number or a known phrase, never verbatim
            $count = "$($named['param2'])"
            if ($count -notmatch '^\d{1,6}$') { $count = '?' }
            $delay = "$($named['param3'])"
            if ($delay -notmatch '^\d{1,9}$') { $delay = '?' }
            $action = "$($named['param4'])"
            if ($action -notmatch '^[A-Za-z ]{1,40}$') { $action = 'the configured action' }
            $r.svcCount = $count; $r.svcDelay = $delay; $r.svcAction = $action
            switch ($eventId) {
                7023 { $r.code = ConvertTo-QwtDeathUInt32 "$($named['param2'])"; $r.anchor = 'nopid'
                       $r.label = "service '$display' ($($r.exe)) ended with a Windows error" }
                7024 { $r.code = ConvertTo-QwtDeathUInt32 "$($named['param2'])"; $r.anchor = 'nopid'
                       $r.label = "service '$display' ($($r.exe)) ended with a service-specific error" }
                7031 { $r.anchor = 'enrich'
                       $r.label = "service '$display' ($($r.exe)) stopped unexpectedly (failure $count); recovery: $action in $delay ms" }
                7034 { $r.anchor = 'enrich'
                       $r.label = "service '$display' ($($r.exe)) stopped unexpectedly (failure $count); no recovery action is configured" }
            }
            return $r
        }
        'Microsoft-Windows-TaskScheduler' {
            if ($eventId -notin 201, 203) { $r.reason = "TaskScheduler $eventId is not a task-failure record"; return $r }
            $task = "$($named['TaskName'])"
            $code = ConvertTo-QwtDeathUInt32 "$($named['ResultCode'])"
            $r.taskName = $task.TrimStart('\')
            if ($script:QwtDeathHelperTasks.ContainsKey($task)) {
                # JOINS, NEVER OPENS: the agent supervises its helpers and writes 4002/4003 (pid, exit code) for every exit it did not
                # ask for; the task's 201 is a second record of that death. When the agent itself ends the task (schtasks /delete ends a
                # running instance), there is no 4002/4003 and the 201 is not a death.
                $r.exe = $script:QwtDeathHelperTasks[$task]; $r.component = $script:QwtDeathExes[$r.exe]; $r.anchor = 'join-only'   # GUARD:helperjoin
            } elseif ($task -in $script:QwtDeathScriptTasks) {
                $r.exe = ("task:" + $task.TrimStart('\')).ToLowerInvariant(); $r.task = $task; $r.anchor = 'nopid'
                $r.component = "$($script:QwtDeathTaskNames[$task].id)"   # GUARD:taskid
                if (-not $r.component) { $r.component = ($task.TrimStart('\').ToLowerInvariant() -replace '[^a-z0-9-]', '') }
            } else {
                $r.reason = "task '$task' is not ours"; return $r
            }
            if ($eventId -eq 201) {
                if ($null -eq $code -or $code -eq 0) { $r.reason = "task '$task' ended with result 0"; return $r }
                if ($code -eq 267014) { $r.ignore = $true; $r.reason = "task '$task' was ENDED by Task Scheduler (0x41306) - a stop that was asked for, not a death"; return $r }
                $r.ours = $true; $r.kind = 'task'; $r.rec = 'task-result'; $r.code = $code
                if ($script:QwtDeathHelperTasks.ContainsKey($task)) { $r.label = "$($r.exe) (task $($r.taskName)) ended with a non-zero result" }
                else { $r.label = "task $($r.taskName) ended with a non-zero result" }
            } else {
                $r.ours = $true; $r.kind = 'launchfail'; $r.rec = 'task-launch'; $r.code = $code; $r.anchor = 'nopid'
                $r.label = "task $($r.taskName) could not start its action"
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
# the human name of what died: the executable's, or the task's; a service record says "... service"
function Get-QwtDeathHuman {
    param([Parameter(Mandatory)]$Death)
    if ($Death.task -and $script:QwtDeathTaskNames.ContainsKey($Death.task)) { return "$($script:QwtDeathTaskNames[$Death.task].human)" }
    $h = "$($script:QwtDeathHuman[$Death.exe])"
    if (-not $h) { $h = $Death.exe }
    if ($Death.kind -eq 'service') { $h += ' service' }
    return $h
}
function Get-QwtDeathServiceKeyForExe {
    param([string]$Exe)
    foreach ($d in $script:QwtDeathServices.Keys) { if ($script:QwtDeathServices[$d] -eq $Exe) { return "$($script:QwtDeathServiceKeys[$d])" } }
    return ''
}
function Get-QwtDeathServiceRecovery {
    param([string]$Key)
    try { return (& $script:QwtDeathRecoveryProbe $Key) } catch { return $null }
}
# what Windows does for a service of ours that died: from its recovery settings; an error exit needs the non-crash flag as well
function Format-QwtDeathRecovery {
    param($Rec, [bool]$ErrorExit)
    if ($null -eq $Rec) { return 'Windows restarts it only if its recovery is armed; if it stays down, start it again or reboot this qube' }
    $armed = $Rec.restart -and ((-not $ErrorExit) -or $Rec.onError)
    if ($armed) {
        $d = [Math]::Round([double]$Rec.delayMs / 1000.0, 1)
        return "Windows restarts it automatically (its recovery is armed; the first restart after $d s)"
    }
    if ($ErrorExit -and $Rec.restart) { return 'Windows does NOT restart it after an error exit (its recovery is armed only for crashes): start it again or reboot this qube' }
    return 'Windows does NOT restart it (no restart is armed): start it again or reboot this qube'
}
# "N s" / "N ms" from the SCM's delay field, or the phrase when the field was not a number
function Format-QwtDeathDelay {
    param([string]$DelayMs)
    if ($DelayMs -notmatch '^\d+$') { return 'the configured delay' }
    $v = [long]$DelayMs
    if ($v % 1000 -eq 0) { return "$($v / 1000) s" }
    return "$v ms"
}
# line 1 for a crash or an unasked exit: what happens next, by executable (and the ETW proxy's parked codes)
function Get-QwtDeathNext {
    param([Parameter(Mandatory)]$Death)
    $exe = $Death.exe
    if ($exe -eq 'etwproxy.exe' -and $null -ne $Death.code -and (([uint32]$Death.code) -eq 5 -or ([uint32]$Death.code) -eq 9)) { return $script:QwtDeathEtwParked }
    if ($script:QwtDeathNextByExe.ContainsKey($exe)) { return "$($script:QwtDeathNextByExe[$exe])" }
    if ($script:QwtDeathServices.Values -contains $exe) {
        $rec = Get-QwtDeathServiceRecovery (Get-QwtDeathServiceKeyForExe $exe)
        return ((Format-QwtDeathRecovery $rec $false) + '; ' + $script:QwtDeathServiceImpact[$exe] + '.')
    }
    if ($exe -in $script:QwtDeathRpcExes) { return $script:QwtDeathNextRpc }
    return $script:QwtDeathNextOneShot
}
# the whole notification for one death: header / line 1 / cause / technical line (qwt-notify-error.ps1's shape)
function Format-QwtDeathNotice {
    param([Parameter(Mandatory)]$Death, [Parameter(Mandatory)][int]$Number)
    $human = Get-QwtDeathHuman $Death
    $logDir = Get-QwtDeathLogDir
    $ourLog = "$logDir\qwt-deaths.log"
    $what = ''; $next = ''; $cause = ''; $codeText = ''; $evidence = $ourLog; $subject = $Death.exe
    $ran = Format-QwtDeathRun $Death.ranMs
    $procId = 0
    if ($null -ne $Death.pid) { $procId = [long]$Death.pid }
    switch ($Death.kind) {
        'crash' {
            $what = 'crashed'
            $next = Get-QwtDeathNext $Death
            $codeText = Format-QwtDeathCode $Death.code 'exception'
            $cause = Format-QwtDeathCause $Death.code 'process' $Death.exe $codeText 'the WER report'
            $evidence = "$ourLog; WER folder AppCrash_$($Death.exe)_*; Application log event 1000"
        }
        'wer' {
            $what = 'crashed'
            $next = Get-QwtDeathNext $Death
            $codeText = Format-QwtDeathCode $Death.code 'exception'
            $cause = Format-QwtDeathCause $Death.code 'process' $Death.exe $codeText 'the WER report'
            $evidence = "$ourLog; WER folder AppCrash_$($Death.exe)_*; Application log event 1001"
        }
        'clr' {
            $what = 'crashed'
            $next = Get-QwtDeathNext $Death
            # the exception type is system text: rendered only when the route would accept it (a type named like a secret would
            # make the route refuse the whole notification - a silent death), else left to the event record
            $type = "$($Death.clrType)"
            if ($type -and (Get-Command Get-QwtNotifyRedactReason -ErrorAction SilentlyContinue) -and (Get-QwtNotifyRedactReason $type)) { $type = '' }   # GUARD:redactfallback
            if ($type) { $cause = "Cause: an unhandled .NET exception, $type." }
            else { $cause = 'Cause: an unhandled .NET exception (its type is in the event record).' }
            $evidence = "$ourLog; Application log, .NET Runtime event 1026"
        }
        'supervisor' {
            $hint = "$($script:QwtDeathLogHints[$Death.exe])"
            if ($Death.hung) {
                $what = 'stopped answering'
                $codeText = 'hung (no exit code)'
                $cause = "Cause: it stopped answering $($script:QwtDeathSupervisorIds[$Death.eventId])'s requests - a hang, not a crash; the agent ended it, so there is no exit code."
                $hint = $script:QwtDeathLogHintHung
            } elseif ($null -eq $Death.code) {
                # 'disappeared': found gone with no exit observed - and it keeps the longest name's header within 60 characters
                $what = 'disappeared'
                $codeText = 'exit code unknown'
                $cause = "Cause: $($script:QwtDeathSupervisorIds[$Death.eventId]) found it gone without observing an exit, so there is no exit code."
            } elseif (Test-QwtDeathExceptionCode $Death.code) {
                $what = 'crashed'
                $codeText = Format-QwtDeathCode $Death.code 'exception'
                $cause = Format-QwtDeathCause $Death.code 'process' $Death.exe $codeText 'the WER report'
            } else {
                $what = 'exited unexpectedly'
                $codeText = Format-QwtDeathCode $Death.code 'exit code'
                $cause = Format-QwtDeathCause $Death.code 'process' $Death.exe $codeText "the program's log"
            }
            $next = Get-QwtDeathNext $Death
            if (-not $hint) { $hint = "the program's log in $logDir" }
            $evidence = "$ourLog; $($hint -f $logDir); Application log, Qubes Windows Tools event $($Death.eventId)"
        }
        'service' {
            $impact = "$($script:QwtDeathServiceImpact[$Death.exe])"
            if (-not $impact) { $impact = 'its work stops while it is down' }
            switch ($Death.eventId) {
                7023 {
                    $what = 'stopped with an error'
                    $codeText = Format-QwtDeathCode $Death.code 'Windows error'
                    $cause = Format-QwtDeathCause $Death.code 'win32' $Death.exe $codeText "the service's log"
                    $next = (Format-QwtDeathRecovery (Get-QwtDeathServiceRecovery $Death.svcKey) $true) + "; $impact."
                }
                7024 {
                    $what = 'stopped with an error'
                    $codeText = Format-QwtDeathCode $Death.code 'service error'
                    $cause = "Cause: a code the service itself defines, not a Windows error - $codeText; its log has the meaning."
                    $next = (Format-QwtDeathRecovery (Get-QwtDeathServiceRecovery $Death.svcKey) $true) + "; $impact."
                }
                7031 {
                    $what = 'stopped unexpectedly'
                    $cause = "Cause: the service process ended without reporting a stop to Windows - failure $($Death.svcCount) in the current reset period."   # GUARD:scmwords
                    if ($Death.svcAction -eq 'Restart the service') { $next = "Windows restarts it in $(Format-QwtDeathDelay $Death.svcDelay); $impact." }
                    else { $next = "Windows runs its recovery action ($($Death.svcAction)) in $(Format-QwtDeathDelay $Death.svcDelay); $impact." }
                }
                7034 {
                    $what = 'stopped unexpectedly'
                    $cause = "Cause: the service process ended without reporting a stop to Windows - failure $($Death.svcCount) in the current reset period."
                    $next = "Windows does not restart it (no recovery action is configured): start it again or reboot this qube; $impact."
                }
            }
            $subject = "$($Death.exe) (service $($Death.svcKey))"
            $evidence = "$ourLog; System log, Service Control Manager event $($Death.eventId)"
        }
        'task' {
            if ($Death.task) {
                $what = 'failed'
                $next = "$($script:QwtDeathTaskNames[$Death.task].impact)"
                $subject = "task $($Death.taskName)"
            } else {
                $what = 'task ended with an error'   # a helper's 201: another record of the helper's death (never notified on its own)
                $next = Get-QwtDeathNext $Death
                $subject = "$($Death.exe) (task $($Death.taskName))"
            }
            $codeText = Format-QwtDeathCode $Death.code 'result'
            $cause = Format-QwtDeathCause $Death.code 'task' '' $codeText "the task's log"
            $evidence = "$ourLog; Task Scheduler history (TaskScheduler/Operational) event 201"
        }
        'launchfail' {
            $what = 'could not start'
            $next = "$($script:QwtDeathTaskNames[$Death.task].impact) Nothing ran, so it left no log of its own: the result code is the whole story."
            $subject = "task $($Death.taskName)"
            $codeText = Format-QwtDeathCode $Death.code 'result'
            $cause = Format-QwtDeathCause $Death.code 'task' '' $codeText 'the Task Scheduler history'
            $evidence = "$ourLog; Task Scheduler history (TaskScheduler/Operational) event 203"
        }
    }
    $header = "The $human $what"   # GUARD:hdrplain
    $tech = Format-QwtNotifyTechLine -Subject $subject -ProcessId $procId -Code $codeText -Ran $ran -Count "death $Number this boot" -Evidence $evidence   # GUARD:techline
    # the same line with the evidence cut to the deaths log (which holds the full record) - what is sent when the full text would
    # be over the route's byte limit; see GUARD:lengthfallback
    $techShort = Format-QwtNotifyTechLine -Subject $subject -ProcessId $procId -Code $codeText -Ran $ran -Count "death $Number this boot" -Evidence $ourLog
    return @{ Component = $Death.component; Header = $header; Next = $next; Cause = $cause; Tech = $tech; TechShort = $techShort }
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
    Write-QwtDeathLog 'ERROR' "DEATH #$($reg.number) $tag $($ev.origin): $($notice.Header) | $($ev.label) | $($notice.Cause) | $($notice.Tech)$extra"   # GUARD:logfirst
    if (-not $reg.new) { return 'enriched' }
    if (-not (Get-Command Send-QwtError -ErrorAction SilentlyContinue)) {
        Write-QwtDeathLog 'ERROR' "DEATH #$($reg.number) NOT notified: qwt-notify-error.ps1 is not next to this script (packaging gap in the reporting path)"
        return 'failed:transport'
    }
    $id = 'death-' + $reg.number   # GUARD:deathid
    # THE ROUTE REFUSES A TEXT OVER ITS BYTE LIMIT, AND A REFUSED DEATH IS A SILENT ONE. The text carries the log directory twice,
    # so a long LogDir (a legacy install, a custom path) could push a death past the limit. Then the evidence is cut to the
    # deaths log - which holds the full record - and the death is sent; the shortening is logged.
    $techSent = $notice.Tech; $shortened = $false
    $full = Format-QwtNotifyText -Header $notice.Header -Next $notice.Next -Cause $notice.Cause -Tech $notice.Tech
    $why = "$(Get-QwtNotifyRedactReason $full)"
    if ($why -like 'too long*' -and $notice.TechShort) { $techSent = $notice.TechShort; $shortened = $true }   # GUARD:lengthfallback
    if ($shortened) { Write-QwtDeathLog 'WARN' "DEATH #$($reg.number): the full text is $([Text.Encoding]::UTF8.GetByteCount($full)) bytes, over the route's limit - sent with the evidence cut to the deaths log" }
    $st = Send-QwtError -Component $notice.Component -Id $id -Severity ACTION -Header $notice.Header -Next $notice.Next -Cause $notice.Cause -Tech $techSent
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
