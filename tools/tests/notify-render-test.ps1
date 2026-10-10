<#
.SYNOPSIS
    The render test for the PowerShell senders of dom0 error notifications (rz39): every death the reporter
    (guest/qwt-report-death.ps1) can report - each record kind, the hang included - and every Send-QwtError call
    in the shipped guest scripts, rendered exactly as dom0 receives them (through the shipped route,
    guest/qwt-notify-error.ps1, with its launcher hooked) and held to the text rules:
      header    <= 60 characters; no hex code, no file name, no count, no product prefix; human names
      body      2 to 4 lines (what next, an optional cause, the technical line)
      tech      the technical line is present: the executable or task, the pid where there is one, the code, "death n
                this boot" for a death and "reported once per boot" for the others, "Evidence:"
      source    the code's meaning comes from the table of the code's SOURCE: the process table for an exception or
                an exit code, the Windows-error table for the SCM's 7023, none for a service-specific 7024, the
                task-result table for 201/203 - never the process table for the others
      route     the route's redaction accepts the text (a .NET type it would refuse is left out, the death still sent)
    plus the six rz39 defects by name: no "once per boot" in a death; a hang is a hang; no "TerminateProcess" for a
    task result or a service-specific code; no "per the SCM"; task components have the executables' id style.
    The agent's and notifhost's texts are rendered by the agent's notifyrender_test.c (C); this suite covers the
    PowerShell half. Prints every rendering verbatim (the AFTER state), then the checks.

.DESCRIPTION
    Exit 0 = every check passed; 1 = at least one FAIL. tools/tests/notify-render-selftest.sh runs it clean and
    then against copies of the reporter and the route with one `# GUARD:<name>` line replaced by its defect, and
    requires the suite to FAIL on that guard's check. Runs under pwsh on Linux; no rig, no event log, no notifhost.

.PARAMETER ReporterPath
    The reporter to test (default: guest/qwt-report-death.ps1 of this repo).
.PARAMETER HelperPath
    The route to test (default: guest/qwt-notify-error.ps1 of this repo).
.PARAMETER GuestDir
    Where the shipped scripts are (default: guest/ of this repo): every Send-QwtError call in them is rendered.
#>
[CmdletBinding()]
param([string]$ReporterPath, [string]$HelperPath, [string]$GuestDir)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))   # tools/tests/x.ps1 -> repo
if (-not $ReporterPath) { $ReporterPath = Join-Path $repoRoot 'guest/qwt-report-death.ps1' }
if (-not $HelperPath) { $HelperPath = Join-Path $repoRoot 'guest/qwt-notify-error.ps1' }
if (-not $GuestDir) { $GuestDir = Join-Path $repoRoot 'guest' }
$ReporterPath = (Resolve-Path -LiteralPath $ReporterPath).Path
$HelperPath = (Resolve-Path -LiteralPath $HelperPath).Path

$script:run = 0; $script:fail = 0
function Say([string]$s) { Microsoft.PowerShell.Utility\Write-Host $s }
function Check([string]$case, [string]$name, [bool]$ok, [string]$detail = '') {
    $script:run++
    if (-not $ok) { $script:fail++ }
    $tag = 'FAIL'
    if ($ok) { $tag = 'ok  ' }
    $suffix = ''
    if (-not $ok -and $detail) { $suffix = "  [$detail]" }
    Say "$tag ${case}: $name$suffix"
}

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('notify-render-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
$stateDir = Join-Path $tmpRoot 'store'
$logDir = Join-Path $tmpRoot 'logs'
New-Item -ItemType Directory -Path $stateDir, $logDir -Force | Out-Null

# --- hooks: the route's and the reporter's (as the other suites set them) ---------------------------
$BOOT = [long]1759480000
$script:logLines = New-Object System.Collections.ArrayList
$script:launched = New-Object System.Collections.ArrayList
$script:QwtNotifyStateDir = $stateDir
$script:QwtNotifyHostExe = Join-Path $tmpRoot 'notifhost.exe'
[IO.File]::WriteAllText($script:QwtNotifyHostExe, 'fake')
$script:QwtNotifyGate = $true
$script:QwtNotifyBootStamp = $BOOT
$script:QwtNotifyLog = { param($m) [void]$script:logLines.Add($m) }
$script:QwtNotifyLauncher = { param($exe, $file) [void]$script:launched.Add([IO.File]::ReadAllText($file, [Text.Encoding]::Unicode)) }
$script:QwtNotifyLogged = @{}
$script:QwtNotifyBuild = '4.3.36.915'   # the installed build every technical line names; pinned (the resolver reads a guest's gui-agent.exe)
$script:QwtDeathLibraryOnly = $true
$script:QwtDeathHelper = $HelperPath
$script:QwtDeathStateDir = $stateDir
$script:QwtDeathLogDir = $logDir
$script:QwtDeathInstallDir = 'C:\Program Files\Qubes Tools\'
# the SCM's recovery settings as the installer leaves them (restart after 5 s, also for error exits); a case below changes it
$script:QwtDeathRecoveryProbe = { param($Key) return @{ restart = $true; delayMs = 5000; onError = $true } }
function Write-Host { }   # the reporter and the route echo; this suite's output goes through the qualified name

. $HelperPath
. $ReporterPath

function Reset-World {
    Get-ChildItem -LiteralPath $stateDir -Force | Remove-Item -Force -Recurse
    Get-ChildItem -LiteralPath $logDir -Force | Remove-Item -Force -Recurse
    $script:logLines.Clear(); $script:launched.Clear(); $script:QwtNotifyLogged.Clear()
    $script:QwtNotifyStateDir = $stateDir; $script:QwtNotifyGate = $true; $script:QwtNotifyBootStamp = $BOOT
}

# --- sample records (the shapes the installer's subscription delivers) ------------------------------
$NS = 'http://schemas.microsoft.com/win/2004/08/events/event'
$T0 = [DateTime]::new(2026, 10, 3, 12, 0, 0, [DateTimeKind]::Utc)
$script:rec = 1000
function Esc([string]$s) { return [Security.SecurityElement]::Escape($s) }
function New-EvXml([string]$Provider, [int]$Id, [string]$Channel, [DateTime]$Time, [string[]]$Positional, $Named, [bool]$Qualifiers = $false) {
    $script:rec++
    $data = ''
    foreach ($p in @($Positional)) { $data += "<Data>$(Esc $p)</Data>" }
    if ($Named) { foreach ($k in $Named.Keys) { $data += "<Data Name=`"$k`">$(Esc ([string]$Named[$k]))</Data>" } }
    $idEl = "<EventID>$Id</EventID>"
    if ($Qualifiers) { $idEl = "<EventID Qualifiers=`"0`">$Id</EventID>" }
    return "<Event xmlns=`"$NS`"><System><Provider Name=`"$(Esc $Provider)`" />$idEl<Level>2</Level><TimeCreated SystemTime=`"$($Time.ToUniversalTime().ToString('o'))`" /><EventRecordID>$($script:rec)</EventRecordID><Channel>$Channel</Channel><Computer>guest</Computer></System><EventData>$data</EventData></Event>"
}
$INST = 'C:\Program Files\Qubes Tools\bin\'
function New-Crash([string]$exe, [int]$procId, [uint32]$code, [DateTime]$time, [int]$ranSec = 754) {
    $start = $time.AddSeconds(-$ranSec)
    $pos = @($exe, '4.3.33.0', '68dd1234', 'ucrtbase.dll', '10.0.26100.1', '5e1f3dcb', ('{0:x8}' -f $code), '000000000007f61e',
             ('0x{0:x}' -f $procId), ('0x{0:x16}' -f $start.ToFileTimeUtc()), ($INST + $exe), 'C:\WINDOWS\System32\ucrtbase.dll',
             '5f0d2b3e-7a1c-4f7e-9c2a-1b2c3d4e5f60', '', '')
    return New-EvXml 'Application Error' 1000 'Application' $time $pos $null $true
}
function New-Clr([string]$exe, [string]$type, [DateTime]$time) {
    $text = "Application: $exe`nFramework Version: v4.0.30319`nDescription: The process was terminated due to an unhandled exception.`nException Info: $type`n   at QwtngNetSetup.Work()`n"
    return New-EvXml '.NET Runtime' 1026 'Application' $time @($text) $null $true
}
function New-Super([int]$id, [string]$exe, [string]$procId, [string]$code, [string]$ran, [DateTime]$time) {
    $detail = 'the supervisor relaunches it (its own words, in the event only)'
    $text = "$exe (PID $procId) exited without being asked to - exit code $code - after running $ran ms. $detail"
    return New-EvXml 'Qubes Windows Tools' $id 'Application' $time @($text, $exe, $procId, $code, $ran, $detail) $null
}
function New-Svc([int]$id, [string]$display, [DateTime]$time, $named) {
    $n = [ordered]@{ param1 = $display }
    foreach ($k in $named.Keys) { $n[$k] = $named[$k] }
    return New-EvXml 'Service Control Manager' $id 'System' $time @() $n
}
function New-Task([int]$id, [string]$task, [string]$result, [DateTime]$time) {
    $n = [ordered]@{ TaskName = $task; TaskInstanceId = '{1b2c3d4e-0000-4000-8000-000000000001}'; ActionName = 'C:\x\y.exe'; ResultCode = $result; EnginePID = '1234' }
    return New-EvXml 'Microsoft-Windows-TaskScheduler' $id 'Microsoft-Windows-TaskScheduler/Operational' $time @() $n
}

# --- the rules, applied to one rendered notification ------------------------------------------------
# THE PHRASES THE OWNER STRUCK (2026-10-10, reading the teardown notification: "too much prose") and their kin: reassurance,
# a line restating the header, the retry schedule, a packaging explanation, a log-line tag inside a sentence, SCM jargon. The
# knowledge they carried lives in the comment beside each string now.
$script:struck = @('not by a fault of its own', 'nobody asked for', 'Windows ended it when its sign-in session ended', 'relaunches nothing',
                   'a packaging gap', 'it is not repeated here', 'the whole story', 'a minute apart', '(log line', 'on a system that needs it',
                   'per the SCM')
# what a header can say happened (its tail after the human name): line 1 must not say it again
$script:whats = @('crashed', 'exited unexpectedly', 'ended by Windows', 'stopped answering', 'disappeared', 'is already running',
                  'stopped with an error', 'stopped unexpectedly', 'task ended with an error', 'failed', 'could not start',
                  'needs a reboot that was refused', 'could not be activated')
function Test-NotifyRules([string]$case, [string]$text, [string]$subject, [string]$countPhrase) {
    $lines = @($text -split "`r`n")
    $header = $lines[0]
    Check $case 'header <= 60 characters' ($header.Length -le 60) "$($header.Length): $header"
    Check $case 'header has no hex code' ($header -notmatch '0[xX][0-9A-Fa-f]')
    Check $case 'header has no file name' ($header -notmatch '(?i)\.(exe|dll|log|ps1|txt|sys)\b')
    Check $case 'header has no count' ($header -notmatch '[0-9]')
    Check $case 'header has no product prefix' ($header -notmatch 'Qubes Windows Tools' -and $header -notmatch ':')
    Check $case 'header is a sentence (capital first letter, no trailing period)' ($header -cmatch '^[A-Z]' -and -not $header.EndsWith('.'))
    Check $case 'body is 2 to 4 lines' ($lines.Count -ge 3 -and $lines.Count -le 5) "$($lines.Count - 1) body lines"
    # the shape (owner 2026-10-10): one clause for the condition, one for the consequence, then the facts - short lines, each
    # fact once, nothing he struck
    Check $case 'line 1 is at most 120 characters' ($lines[1].Length -le 120) "$($lines[1].Length): $($lines[1])"
    $what = ''
    foreach ($w in $script:whats) { if ($header.EndsWith(" $w")) { $what = $w; break } }
    Check $case 'the header ends in a known condition phrase' ($what -ne '') $header
    if ($what) { Check $case "line 1 does not restate the header (no '$what')" ($lines[1] -notlike "*$what*") $lines[1] }
    $hit = ''
    foreach ($p in $script:struck) { if ($text -like "*$p*") { $hit = $p; break } }
    Check $case 'none of the phrases the owner struck' ($hit -eq '') $hit
    $tech = $lines[-1]
    Check $case 'technical line names the executable or task first' ($tech.StartsWith($subject)) $tech
    Check $case 'technical line says how often it is reported, then the build' ($tech -like "*; $countPhrase; build *. Evidence: *") $tech
    Check $case 'technical line names the build that produced it' ($tech -like '*; build 4.3.36.915. Evidence: *') $tech
    Check $case 'technical line says where the evidence is - ONE pointer, no list' ($tech -match '\. Evidence: [^;]+\.$') $tech
    Check $case 'technical line is at most 220 characters' ($tech.Length -le 220) "$($tech.Length)"
    $exe = ($subject -split '[ ;]')[0]
    if ($exe -like '*.exe' -or $exe -like '*.ps1') {
        $above = @($lines | Select-Object -First ($lines.Count - 1) | Where-Object { $_ -like "*$exe*" })
        Check $case 'the executable is named in the technical line only (the header and line 1 use human names)' ($above.Count -eq 0) ($above -join ' | ')
    }
    Check $case 'the route''s redaction accepts the text' ($null -eq (Get-QwtNotifyRedactReason $text)) "$(Get-QwtNotifyRedactReason $text)"
    Check $case 'under the route''s 600 bytes' ([Text.Encoding]::UTF8.GetByteCount($text) -le 600) "$([Text.Encoding]::UTF8.GetByteCount($text))"
    if ($lines.Count -ge 4) {
        Check $case 'the cause line starts with Cause:' ($lines[2].StartsWith('Cause: ')) $lines[2]
        Check $case 'the cause is at most 100 characters' ($lines[2].Length -le 100) "$($lines[2].Length): $($lines[2])"
    }
}

# =====================================================================================================
Say "==== the deaths (guest/qwt-report-death.ps1 through guest/qwt-notify-error.ps1), as dom0 receives them ===="
# key -> @{ rec = the record; subject = the technical line's opening; code = the code phrase the cause and the technical line
#           carry; meaning = words the cause must carry; not = words the cause must NOT carry; header = words the header must carry;
#           comp = the route component the log must show }
$cases = [ordered]@{
    '1000 crash: gui-agent.exe 0xC0000409'          = @{ rec = { New-Crash 'gui-agent.exe' 6100 0xC0000409L $T0 754 }; subject = 'gui-agent.exe pid 6100'; code = 'exception 0xC0000409'; meaning = 'fast-fail abort'; header = 'The GUI agent crashed'; comp = 'gui-agent'; next = 'Windows restarts its watchdog service' }
    '1000 crash: qrexec-agent.exe 0xC0000005'       = @{ rec = { New-Crash 'qrexec-agent.exe' 2200 0xC0000005L $T0 30 }; subject = 'qrexec-agent.exe pid 2200'; code = 'exception 0xC0000005'; meaning = 'access violation'; header = 'The Qubes RPC agent crashed'; comp = 'qrexec-agent'; next = 'Windows restarts it in 5 s' }
    '1000 crash: clipboard-copy.exe 0xC0000005'     = @{ rec = { New-Crash 'clipboard-copy.exe' 4400 0xC0000005L $T0 2 }; subject = 'clipboard-copy.exe pid 4400'; code = 'exception 0xC0000005'; meaning = 'access violation'; header = 'The clipboard copy tool crashed'; comp = 'clipboard-copy'; next = 'Not relaunched' }
    '1000 crash: gui-agent.exe 0xC0000AAA (unknown code)' = @{ rec = { New-Crash 'gui-agent.exe' 6101 0xC0000AAAL $T0 10 }; subject = 'gui-agent.exe pid 6101'; code = 'exception 0xC0000AAA'; meaning = 'not a code this reporter knows'; header = 'The GUI agent crashed'; comp = 'gui-agent' }
    '1026 .NET: qubes-updates-relay.exe'            = @{ rec = { New-Clr 'qubes-updates-relay.exe' 'System.IO.IOException' $T0 }; subject = 'qubes-updates-relay.exe;'; meaning = 'System.IO.IOException'; header = 'The updates relay crashed'; comp = 'updates-relay' }
    '1026 .NET: a type the route would refuse'      = @{ rec = { New-Clr 'qwtng-netsetup.exe' 'System.IdentityModel.Tokens.SecurityTokenException' $T0 }; subject = 'qwtng-netsetup.exe;'; meaning = 'unhandled .NET exception'; not = 'Token'; header = 'The PV NIC address applier crashed'; comp = 'qwtng-netsetup' }
    '4001 watchdog: gui-agent.exe exit 0'           = @{ rec = { New-Super 4001 'gui-agent.exe' '6100' '0x00000000' '90000' $T0 }; subject = 'gui-agent.exe pid 6100'; code = 'exit code 0'; meaning = 'a clean exit'; header = 'The GUI agent exited unexpectedly'; comp = 'gui-agent' }
    '4002 agent: wgcbroker.exe exited 0xC0000005'   = @{ rec = { New-Super 4002 'wgcbroker.exe' '4100' '0xC0000005' '125000' $T0 }; subject = 'wgcbroker.exe pid 4100'; code = 'exception 0xC0000005'; meaning = 'access violation'; header = 'The notification and menu capture helper crashed'; comp = 'wgcbroker' }
    '4002 agent: wgcbroker.exe HUNG'                = @{ rec = { New-Super 4002 'wgcbroker.exe' '4100' 'hung' '125000' $T0 }; subject = 'wgcbroker.exe pid 4100'; techcode = 'hung (no exit code)'; meaning = 'a hang'; header = 'The notification and menu capture helper stopped answering'; comp = 'wgcbroker'; hang = $true }
    '4002 agent: wgcbroker.exe gone, no exit seen'  = @{ rec = { New-Super 4002 'wgcbroker.exe' '4100' 'unknown' '125000' $T0 }; subject = 'wgcbroker.exe pid 4100'; techcode = 'exit code unknown'; meaning = 'no exit was seen'; header = 'The notification and menu capture helper disappeared'; comp = 'wgcbroker' }
    '4003 agent: notifhost.exe exit 2'              = @{ rec = { New-Super 4003 'notifhost.exe' '777' '0x00000002' '30000' $T0 }; subject = 'notifhost.exe pid 777'; code = 'exit code 2'; meaning = 'notification access is denied'; header = 'The notification bridge exited unexpectedly'; comp = 'notifhost' }
    '4003 agent: notifhost.exe exit 0x40010004 (session end)' = @{ rec = { New-Super 4003 'notifhost.exe' '2248' '0x40010004' '27734' $T0 }; subject = 'notifhost.exe pid 2248'; code = 'exit code 0x40010004'; meaning = 'session teardown (DBG_TERMINATE_PROCESS)'; header = 'The notification bridge ended by Windows'; comp = 'notifhost'; next = 'at the next sign-in'; not = 'Task Scheduler restarts it' }
    '4004 agent: etwproxy.exe exit 1'               = @{ rec = { New-Super 4004 'etwproxy.exe' '3300' '0x00000001' '600000' $T0 }; subject = 'etwproxy.exe pid 3300'; code = 'exit code 1'; meaning = 'TerminateProcess'; header = 'The ETW signal proxy exited unexpectedly'; comp = 'etwproxy'; next = 'Not relaunched until the next GUI agent start' }
    '4004 agent: etwproxy.exe exit 5 (parked)'      = @{ rec = { New-Super 4004 'etwproxy.exe' '3300' '0x00000005' '600000' $T0 }; subject = 'etwproxy.exe pid 3300'; code = 'exit code 5'; meaning = 'trace access was denied'; header = 'The ETW signal proxy exited unexpectedly'; comp = 'etwproxy'; next = 'Parked by the GUI agent for this boot' }
    '7023 SCM: Qubes RPC agent error 1460'          = @{ rec = { New-Svc 7023 'Qubes RPC agent' $T0 @{ param2 = '%%1460' } }; subject = 'qrexec-agent.exe (service QrexecAgent)'; code = 'Windows error 1460'; meaning = 'the operation timed out'; not = 'TerminateProcess'; header = 'The Qubes RPC agent service stopped with an error'; comp = 'qrexec-agent'; next = 'Windows restarts it in 5 s' }
    '7024 SCM: QubesDB daemon service-specific 1'   = @{ rec = { New-Svc 7024 'QubesDB daemon' $T0 @{ param2 = '1' } }; subject = 'qubesdb-daemon.exe (service QdbDaemon)'; code = 'service error 1'; meaning = 'a service-specific code'; not = 'TerminateProcess'; header = 'The QubesDB daemon service stopped with an error'; comp = 'qubesdb-daemon' }
    '7031 SCM: Qubes RPC agent unexpected, restart' = @{ rec = { New-Svc 7031 'Qubes RPC agent' $T0 @{ param2 = '1'; param3 = '5000'; param4 = 'Restart the service' } }; subject = 'qrexec-agent.exe (service QrexecAgent)'; meaning = 'failure 1'; not = 'per the SCM'; header = 'The Qubes RPC agent service stopped unexpectedly'; comp = 'qrexec-agent'; next = 'Windows restarts it in 5 s' }
    '7034 SCM: Qubes GUI agent watchdog, no action' = @{ rec = { New-Svc 7034 'Qubes GUI agent watchdog' $T0 @{ param2 = '2' } }; subject = 'gui-watchdog.exe (service QubesGuiWatchdog)'; meaning = 'failure 2'; not = 'per the SCM'; header = 'The GUI agent watchdog service stopped unexpectedly'; comp = 'gui-watchdog'; next = 'Windows does not restart it' }
    '201 task: \QubesPvNic result 1'                = @{ rec = { New-Task 201 '\QubesPvNic' '1' $T0 }; subject = 'task QubesPvNic;'; code = 'result 1'; meaning = 'the script reported a failure'; not = 'TerminateProcess'; header = 'The PV NIC setup task failed'; comp = 'pvnic' }
    '201 task: \QubesWindowsUpdateRun result 0xC0000409' = @{ rec = { New-Task 201 '\QubesWindowsUpdateRun' '3221226505' $T0 }; subject = 'task QubesWindowsUpdateRun;'; code = 'result 0xC0000409'; meaning = 'its program crashed'; header = 'The Windows Update install task failed'; comp = 'update-run' }
    '203 task: \QubesAutologonGuard launch failed'  = @{ rec = { New-Task 203 '\QubesAutologonGuard' '2147942402' $T0 }; subject = 'task QubesAutologonGuard;'; code = 'result 0x80070002'; meaning = 'the file was not found'; header = 'The autologon guard task could not start'; comp = 'autologon-guard' }
}
foreach ($k in $cases.Keys) {
    $c = $cases[$k]
    Reset-World
    $st = Invoke-QwtDeathReport (& $c.rec)
    Say "`n---- $k (route status: $st) ----"
    if ($script:launched.Count) { Say ([string]$script:launched[-1]) } else { Say '(nothing sent)' }
    Check $k 'the death is sent' ($st -eq 'send' -and $script:launched.Count -eq 1) $st
    if (-not $script:launched.Count) { continue }
    $text = [string]$script:launched[-1]
    $lines = @($text -split "`r`n")
    Test-NotifyRules $k $text $c.subject 'death 1 this boot'
    Check $k 'the header names the component in human words and says what happened' ($lines[0] -eq $c.header) $lines[0]
    Check $k 'no "once per boot" (each death has its own id)' ($text -notlike '*once per boot*')
    if ($c.next) { Check $k 'line 1 says what happens next' ($lines[1] -like "*$($c.next)*") $lines[1] }
    if ($c.code) {
        Check $k 'the technical line carries the code, and the cause does not repeat it (a fact appears once)' (($lines[-1] -like "*; $($c.code);*") -and ($lines[2] -notlike "*$($c.code)*")) "$($lines[2]) | $($lines[-1])"
        Check $k 'the code phrase appears exactly once in the whole text' (([regex]::Matches($text, [regex]::Escape($c.code))).Count -eq 1) $c.code
        $num = ($c.code -split ' ')[-1]
        if ($num -like '0x*') { Check $k 'the hex code appears exactly once in the whole text' (([regex]::Matches($text, [regex]::Escape($num))).Count -eq 1) $num }
    }
    if ($c.techcode) {
        Check $k 'the technical line says there is no code' ($lines[-1] -like "*; $($c.techcode);*") "$($lines[2]) | $($lines[-1])"
    }
    Check $k 'the cause names the code''s meaning from its own source''s table' ($lines[2] -like "*$($c.meaning)*") $lines[2]
    if ($c.not) { Check $k "cause is not phrased by another table or in jargon (no '$($c.not)')" ($text -notlike "*$($c.not)*") $lines[2] }
    if ($c.hang) {
        Check $k 'the hang is rendered as a hang (stopped answering; ended by its supervisor; no "exited")' ($lines[0] -like '*stopped answering*' -and $lines[2] -like '*ended it*' -and $text -notlike '*exited*')
    }
    $sent = @($script:logLines | Where-Object { $_ -like "$($c.comp).death-1 sent to dom0*" })
    Check $k 'the component is the task''s or executable''s machine id' ($sent.Count -eq 1) ($script:logLines -join ' / ')
}

# the service wording follows the SCM's recovery settings as the registry has them
Say "`n==== a service death under each recovery state ===="
# ---- a long log directory: the full text would be over the route's limit; the death must still be sent (GUARD:lengthfallback) ----
# With ONE pointer the directory appears once, so only a directory of ~240 characters (a custom path near MAX_PATH) can push
# the text over 600 bytes; the pointer is then cut to the file name, and the build survives into that line (GUARD:shortbuild).
$k = '4002 HUNG with a log directory of ~270 characters (the full text is over the limit)'
Reset-World
# a realistic long path - words and separators; a 40-character run without one is the route's key-shaped rule, a different refusal
$longDir = $tmpRoot
foreach ($seg in 'Program Files', 'Invisible Things Lab', 'Qubes Tools', 'log', 'a custom directory for this qube', 'kept on the private volume',
                 'with a name long enough to push one pointer', 'past the six hundred bytes the route accepts', 'and then some more for the fallback', 'deaths') {
    $longDir = Join-Path $longDir $seg
}
New-Item -ItemType Directory -Force -Path $longDir | Out-Null
$savedLogDir = $script:QwtDeathLogDir; $script:QwtDeathLogDir = $longDir
$st = Invoke-QwtDeathReport (New-Super 4002 'wgcbroker.exe' '4100' 'hung' '125000' $T0)
Say "`n---- $k (route status: $st) ----"
if ($script:launched.Count) { Say ([string]$script:launched[-1]) } else { Say '(nothing sent)' }
Check $k 'the death is sent even when the full text is over the limit' ($st -eq 'send' -and $script:launched.Count -eq 1) $st
if ($script:launched.Count) {
    $text = [string]$script:launched[-1]
    Check $k 'the sent technical line names the deaths log by file name (the pointer cut to it)' ($text -like '*. Evidence: qwt-deaths.log.') ''
    Check $k 'the short form still carries the build' ($text -like '*; death 1 this boot; build 4.3.36.915. Evidence: qwt-deaths.log.') $text
    Check $k 'the shortening is logged' ((Get-Content -LiteralPath (Join-Path $longDir 'qwt-deaths.log') -Raw) -like '*pointer cut to the file name*') ''
}
$script:QwtDeathLogDir = $savedLogDir

foreach ($state in 'not-armed', 'crash-only', 'unreadable') {
    Reset-World
    switch ($state) {
        'not-armed'  { $script:QwtDeathRecoveryProbe = { param($Key) return @{ restart = $false; delayMs = 0; onError = $false } } }
        'crash-only' { $script:QwtDeathRecoveryProbe = { param($Key) return @{ restart = $true; delayMs = 5000; onError = $false } } }
        'unreadable' { $script:QwtDeathRecoveryProbe = { param($Key) return $null } }
    }
    $st = Invoke-QwtDeathReport (New-Svc 7023 'Qubes RPC agent' $T0 @{ param2 = '%%1460' })
    $text = [string]$script:launched[-1]
    $lines = @($text -split "`r`n")
    Say "`n---- 7023 with recovery $state ----"; Say $text
    switch ($state) {
        'not-armed'  { Check "7023 recovery $state" 'line 1 says Windows does not restart it and what to do' ($lines[1] -like 'Windows does not restart it: start it or restart the qube;*') $lines[1] }
        'crash-only' { Check "7023 recovery $state" 'line 1 says an error exit is not covered' ($lines[1] -like 'Windows does not restart it after an error exit: start it or restart the qube;*') $lines[1] }
        'unreadable' { Check "7023 recovery $state" 'line 1 does not guess' ($lines[1] -like 'Windows restarts it only if its recovery is armed*') $lines[1] }
    }
    Test-NotifyRules "7023 recovery $state" $text 'qrexec-agent.exe (service QrexecAgent)' 'death 1 this boot'
}
$script:QwtDeathRecoveryProbe = { param($Key) return @{ restart = $true; delayMs = 5000; onError = $true } }

# =====================================================================================================
Say "`n==== the guest scripts' own notifications (every Send-QwtError call in $GuestDir), as dom0 receives them ===="
$sample = @{ log = 'C:\Program Files\Qubes Tools\log\qwt-idd-activate.log' }
function Resolve-CallArg($el) {
    if ($el -is [System.Management.Automation.Language.StringConstantExpressionAst]) { return $el.Value }
    if ($el -is [System.Management.Automation.Language.VariableExpressionAst]) { return $sample.log }
    if ($el -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) { return ($el.Value -replace '\$\{?[A-Za-z_][A-Za-z0-9_:]*\}?', $sample.log) }
    if ($el -is [System.Management.Automation.Language.ParenExpressionAst]) {
        $pe = $el.Pipeline.PipelineElements
        if ($pe.Count -eq 1 -and $pe[0] -is [System.Management.Automation.Language.CommandAst] -and $pe[0].GetCommandName() -eq 'Format-QwtNotifyTechLine') {
            $args = @{}
            $els = $pe[0].CommandElements
            for ($i = 1; $i -lt $els.Count; $i++) {
                if ($els[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and ($i + 1) -lt $els.Count) {
                    $args[$els[$i].ParameterName] = Resolve-CallArg $els[$i + 1]
                    $i++
                }
            }
            return (Format-QwtNotifyTechLine @args)
        }
    }
    throw "an argument this test cannot render ($($el.GetType().Name): $($el.Extent.Text)) - make the text literal"
}
$scripts = @(Get-ChildItem -LiteralPath $GuestDir -Filter '*.ps1' | Where-Object { $_.Name -notin 'qwt-notify-error.ps1', 'qwt-report-death.ps1' } | Sort-Object Name)
$callsSeen = 0
foreach ($f in $scripts) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    $calls = @($ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.CommandAst] -and $a.GetCommandName() -eq 'Send-QwtError' }, $true))
    foreach ($call in $calls) {
        # the fail-open stub `function Send-QwtError { return 'unavailable:helper-absent' }` is a definition, not a call; FindAll
        # returns CommandAsts only, so only real calls arrive here
        $callsSeen++
        $args = @{}
        $els = $call.CommandElements
        $case = "$($f.Name):$($call.Extent.StartLineNumber)"
        try {
            for ($i = 1; $i -lt $els.Count; $i++) {
                if ($els[$i] -is [System.Management.Automation.Language.CommandParameterAst]) {
                    $name = $els[$i].ParameterName
                    if (($i + 1) -lt $els.Count -and -not ($els[$i + 1] -is [System.Management.Automation.Language.CommandParameterAst])) { $args[$name] = Resolve-CallArg $els[$i + 1]; $i++ }
                    else { $args[$name] = $true }
                }
            }
        } catch { Check $case 'every argument is renderable offline' $false "$($_.Exception.Message)"; continue }
        $case = "$($f.Name): $($args['Component']).$($args['Id'])"
        Check $case 'the call passes the four parts (no -Summary, no -LogPath)' ($args.ContainsKey('Header') -and $args.ContainsKey('Next') -and $args.ContainsKey('Tech') -and -not $args.ContainsKey('Summary') -and -not $args.ContainsKey('LogPath')) ($args.Keys -join ',')
        if (-not ($args.ContainsKey('Header') -and $args.ContainsKey('Next') -and $args.ContainsKey('Tech'))) { continue }
        Check $case 'component and id pass the route''s name rule' ((Test-QwtNotifyName $args['Component'] 24) -and (Test-QwtNotifyName $args['Id'] 40))
        $cause = ''
        if ($args.ContainsKey('Cause')) { $cause = $args['Cause'] }
        $text = Format-QwtNotifyText -Header $args['Header'] -Next $args['Next'] -Cause $cause -Tech $args['Tech']
        Say "`n---- $case (ACTION) ----"; Say $text
        Test-NotifyRules $case $text $f.Name 'reported once per boot'
        Check $case 'the technical line points at the script''s log' ($text -like "*Evidence: $($sample.log).")
        # end to end through the shipped route, so what the route sends is what was rendered
        Reset-World
        $st = Send-QwtError -Component $args['Component'] -Id $args['Id'] -Severity ACTION -Header $args['Header'] -Next $args['Next'] -Cause $cause -Tech $args['Tech']
        Check $case 'the route sends it unchanged' ($st -eq 'send' -and ([string]$script:launched[-1]) -eq $text) $st
    }
}
Check 'guest scripts' 'every known caller was found (activate-idd x2, deactivate-idd x1)' ($callsSeen -ge 3) "$callsSeen calls"

Say "`n$($script:run) checks, $($script:fail) failed"
Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
if ($script:fail -gt 0) { exit 1 }
exit 0
