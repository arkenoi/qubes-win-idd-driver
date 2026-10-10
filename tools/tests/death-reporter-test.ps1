<#
.SYNOPSIS
    Offline suite for guest/qwt-report-death.ps1, the ONE death reporter (docs/ADR-supervision.md 3). Runs under
    pwsh on Linux or Windows PowerShell 5.1; no rig, no event log, no notifhost: the reporter is dot-sourced as a
    library, the route (guest/qwt-notify-error.ps1, dot-sourced BY the reporter, as shipped) has its launcher, gate
    and boot stamp replaced by the same hooks tools/tests/notifyerr-test.ps1 uses, and the events are sample
    records of every id the installer's subscription covers.

.DESCRIPTION
    Exit 0 = every case matched; 1 = at least one FAIL. Each guard is proven to be seen failing by
    tools/tests/death-reporter-selftest.sh, which replaces the reporter's `# GUARD:<name>` line in a temporary copy
    and runs this suite against it with -ReporterPath; the suite MUST then exit 1.

    What it pins:
      ours       a crash of notepad.exe, or of a gui-agent.exe outside our install directory, is not ours; a task
                 not in the table, a service not in the table, result 0, a Task-Scheduler-ended helper (0x41306)
                 and the reporter's own task are never deaths
      parse      every id (1000 1001 1026 4001-4004 7023 7024 7031 7034 201 203) yields the fields the text needs:
                 exe, pid, code (hex for a crash, decimal for the SCM and Task Scheduler, "%%1460" and
                 "1460 (0x5B4)" alike), the run time from the crash record's start FILETIME, the WER folder
      identity   (exe, pid) keys a death; a pid-less record attaches to the newest death of that exe in the window;
                 a 1026 opens a death whose 1000 adopts the pid; 7023 always opens one; a SECOND death of the same
                 exe inside the window is a second death
      count      id death-<n> per boot, n counts every death; the 9th is suppressed by the route's cap and is STILL
                 logged at ERROR; a new boot token restarts the count
      text       the rz39 shape: header / what next / cause / technical line (every rendering and its rules are
                 tools/tests/notify-render-test.ps1's); here: the parts are present, the code and its meaning come from
                 the right source's table, the run time, "death n this boot", the evidence by prefix (no WER hash), the
                 route accepts it (no redaction refusal, under its size); a service's line 1 follows the SCM's recovery
                 settings as the registry has them (probe hooked)
#>
[CmdletBinding()]
param([string]$ReporterPath)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))   # tools/tests/x.ps1 -> repo
if (-not $ReporterPath) { $ReporterPath = Join-Path $repoRoot 'guest/qwt-report-death.ps1' }
$ReporterPath = (Resolve-Path -LiteralPath $ReporterPath).Path
$helperPath = (Resolve-Path -LiteralPath (Join-Path $repoRoot 'guest/qwt-notify-error.ps1')).Path

$script:run = 0; $script:fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    $script:run++
    if (-not $ok) { $script:fail++ }
    $tag = 'FAIL'
    if ($ok) { $tag = 'ok  ' }
    $suffix = ''
    if (-not $ok -and $detail) { $suffix = "  [$detail]" }
    Microsoft.PowerShell.Utility\Write-Host "$tag $name$suffix"
}
function CheckStatus([string]$name, [string]$got, [string]$want) { Check "$name (want $want, got $got)" ($got -eq $want) }

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('death-reporter-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
$stateDir = Join-Path $tmpRoot 'store'
$logDir = Join-Path $tmpRoot 'logs'
New-Item -ItemType Directory -Path $stateDir, $logDir -Force | Out-Null

# --- hooks: the route's (as notifyerr-test.ps1 sets them) and the reporter's ----------------------
$BOOT = [long]1759480000
$script:logLines = New-Object System.Collections.ArrayList
$script:launched = New-Object System.Collections.ArrayList
$script:QwtNotifyStateDir = $stateDir
$script:QwtNotifyHostExe = Join-Path $tmpRoot 'notifhost.exe'
[IO.File]::WriteAllText($script:QwtNotifyHostExe, 'fake')          # present: the launcher hook is what records a send
$script:QwtNotifyGate = $true
$script:QwtNotifyBootStamp = $BOOT
$script:QwtNotifyLog = { param($m) [void]$script:logLines.Add($m) }
$script:QwtNotifyLauncher = { param($exe, $file) [void]$script:launched.Add([IO.File]::ReadAllText($file, [Text.Encoding]::Unicode)) }
$script:QwtNotifyLogged = @{}
$script:QwtDeathLibraryOnly = $true
$script:QwtDeathHelper = $helperPath
$script:QwtDeathStateDir = $stateDir
$script:QwtDeathLogDir = $logDir
$script:QwtDeathInstallDir = 'C:\Program Files\Qubes Tools\'   # the samples' paths; the resolver itself is checked in 6d
$script:QwtDeathRecoveryProbe = { param($Key) return @{ restart = $true; delayMs = 5000; onError = $true } }   # as the installer arms it
function Write-Host { }   # the reporter and the route echo; the suite's own output goes through the qualified name above

. $ReporterPath

function Reset-World {
    Get-ChildItem -LiteralPath $stateDir -Force | Remove-Item -Force -Recurse
    Get-ChildItem -LiteralPath $logDir -Force | Remove-Item -Force -Recurse
    $script:logLines.Clear(); $script:launched.Clear(); $script:QwtNotifyLogged.Clear()
    $script:QwtNotifyStateDir = $stateDir; $script:QwtNotifyGate = $true; $script:QwtNotifyBootStamp = $BOOT
}
function Get-DeathLog { $p = Join-Path $logDir 'qwt-deaths.log'; if (Test-Path -LiteralPath $p) { return [IO.File]::ReadAllText($p) }; return '' }
function Get-Ledger { $p = Join-Path $stateDir 'deaths.ledger'; if (Test-Path -LiteralPath $p) { return @([IO.File]::ReadAllLines($p)) }; return @() }

# --- sample records ----------------------------------------------------------------------------------
$NS = 'http://schemas.microsoft.com/win/2004/08/events/event'
$T0 = [DateTime]::new(2026, 10, 3, 10, 0, 0, [DateTimeKind]::Utc)
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
function New-Crash([string]$exe, [int]$procId, [uint32]$code, [DateTime]$time, [int]$ranSec = 754, [string]$path = '') {
    if (-not $path) { $path = $INST + $exe }
    $start = $time.AddSeconds(-$ranSec)
    $pos = @($exe, '4.3.33.0', '68dd1234', 'ucrtbase.dll', '10.0.26100.1', '5e1f3dcb', ('{0:x8}' -f $code), '000000000007f61e',
             ('0x{0:x}' -f $procId), ('0x{0:x16}' -f $start.ToFileTimeUtc()), $path, 'C:\WINDOWS\System32\ucrtbase.dll',
             '5f0d2b3e-7a1c-4f7e-9c2a-1b2c3d4e5f60', '', '')
    return New-EvXml 'Application Error' 1000 'Application' $time $pos $null $true
}
function New-Wer([string]$exe, [uint32]$code, [DateTime]$time) {
    $folder = "\\?\C:\ProgramData\Microsoft\Windows\WER\ReportArchive\AppCrash_${exe}_f5a3c2a4b84a0d3d1e07e4ba9fc34f5b4ac1b4e9_00000000_cab_0d5fe2d0"
    $pos = @('0', '4', 'APPCRASH', 'Not available', '0', $exe, '4.3.33.0', '68dd1234', 'ucrtbase.dll', '10.0.26100.1', '5e1f3dcb',
             ('{0:x8}' -f $code), '7f61e', '', '', '\\?\C:\ProgramData\Microsoft\Windows\WER\Temp\WER1234.tmp.dmp', $folder, '', '0',
             '5f0d2b3e-7a1c-4f7e-9c2a-1b2c3d4e5f60', '268435456', '1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d', 'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d')
    return New-EvXml 'Windows Error Reporting' 1001 'Application' $time $pos $null $true
}
function New-Clr([string]$exe, [string]$type, [DateTime]$time) {
    $text = "Application: $exe`nFramework Version: v4.0.30319`nDescription: The process was terminated due to an unhandled exception.`nException Info: $type`n   at QwtngNetSetup.Work()`n"
    return New-EvXml '.NET Runtime' 1026 'Application' $time @($text) $null $true
}
function New-Super([int]$id, [string]$exe, [string]$procId, [string]$code, [string]$ran, [DateTime]$time, [string]$detail = 'the supervisor relaunches it') {
    $text = "$exe (PID $procId) exited without being asked to: exit code $code, after running $ran ms. $detail"
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

# =====================================================================================================
# 1. the tables agree with the route's name rule
$badNames = @($script:QwtDeathExes.Values | Where-Object { -not (Test-QwtNotifyName $_ 24) })
Check 'tables: every component name passes the route''s name rule (<= 24 chars of [a-z0-9-])' ($badNames.Count -eq 0) ($badNames -join ',')
$badSvc = @($script:QwtDeathServices.Values | Where-Object { -not $script:QwtDeathExes.ContainsKey($_) })
Check 'tables: every service maps to an executable in the table' ($badSvc.Count -eq 0) ($badSvc -join ',')
Check 'tables: helper tasks map to helper executables' ($script:QwtDeathExes.ContainsKey($script:QwtDeathHelperTasks['\Qubes-WgcBroker']) -and $script:QwtDeathExes.ContainsKey($script:QwtDeathHelperTasks['\Qubes-NotifBridge']))
Check 'tables: the reporter''s own task is not in any task list' (-not $script:QwtDeathHelperTasks.ContainsKey('\QwtDeathReporter') -and ('\QwtDeathReporter' -notin $script:QwtDeathScriptTasks))
$noHuman = @($script:QwtDeathExes.Keys | Where-Object { -not $script:QwtDeathHuman.ContainsKey($_) })
Check 'tables: every executable has a human name (the header never says an exe name)' ($noHuman.Count -eq 0) ($noHuman -join ',')
$badTask = @($script:QwtDeathScriptTasks | Where-Object { -not $script:QwtDeathTaskNames.ContainsKey($_) -or -not (Test-QwtNotifyName $script:QwtDeathTaskNames[$_].id 24) -or -not $script:QwtDeathTaskNames[$_].human -or -not $script:QwtDeathTaskNames[$_].impact })
Check 'tables: every script task has a machine id (the route''s name rule), a human name and an impact' ($badTask.Count -eq 0) ($badTask -join ',')
$noKey = @($script:QwtDeathServices.Keys | Where-Object { -not $script:QwtDeathServiceKeys.ContainsKey($_) -or -not $script:QwtDeathServiceImpact.ContainsKey($script:QwtDeathServices[$_]) })
Check 'tables: every service has its service key and an impact line' ($noKey.Count -eq 0) ($noKey -join ',')

# 2. number parsing: the radix is the caller's
Check 'parse: "0x1a2c" -> 6700' ((ConvertTo-QwtDeathUInt32 '0x1a2c') -eq 6700)
Check 'parse: "c0000409" -Hex -> 0xC0000409' ((ConvertTo-QwtDeathUInt32 'c0000409' -Hex) -eq [uint32]0xC0000409L)
Check 'parse: "40000015" -Hex is hex, not decimal' ((ConvertTo-QwtDeathUInt32 '40000015' -Hex) -eq [uint32]0x40000015L)
Check 'parse: "3221226505" -> 0xC0000409' ((ConvertTo-QwtDeathUInt32 '3221226505') -eq [uint32]0xC0000409L)
Check 'parse: "%%1460" -> 1460' ((ConvertTo-QwtDeathUInt32 '%%1460') -eq 1460)
Check 'parse: "1460 (0x5B4)" -> 1460 (the b is not a radix hint)' ((ConvertTo-QwtDeathUInt32 '1460 (0x5B4)') -eq 1460)
Check 'parse: "-1073741819" -> 0xC0000005' ((ConvertTo-QwtDeathUInt32 '-1073741819') -eq [uint32]0xC0000005L)
Check 'parse: garbage -> $null' ($null -eq (ConvertTo-QwtDeathUInt32 'ERROR'))
Check 'meaning: 0xC0000409 names the fast-fail (process table)' ((Get-QwtDeathCodeMeaning ([uint32]0xC0000409L) 'process') -like '*fast-fail abort*')
Check 'meaning: 1460 is a timeout in the Windows-error table (the SCM''s 7023)' ((Get-QwtDeathCodeMeaning ([uint32]1460) 'win32') -eq 'the operation timed out')
Check 'meaning: 1460 means nothing in the process table (the tables are per source)' ((Get-QwtDeathCodeMeaning ([uint32]1460) 'process') -eq '')
Check 'meaning: a service-specific code has no table of ours (the service defines it)' ((Get-QwtDeathCodeMeaning ([uint32]1) 'service') -eq '')
Check 'meaning: a task result 1 is the script''s own exit, never TerminateProcess' (((Get-QwtDeathCodeMeaning ([uint32]1) 'task') -like 'the script reported a failure*') -and ((Get-QwtDeathCodeMeaning ([uint32]1) 'task') -notlike '*TerminateProcess*'))
Check 'meaning: a crash code in a task result is said to be its program''s crash' ((Get-QwtDeathCodeMeaning ([uint32]0xC0000005L) 'task') -eq 'its program crashed with an access violation')
Check 'meaning: an executable''s documented exit code comes first (notifhost 2)' ((Get-QwtDeathCodeMeaning ([uint32]2) 'process' 'notifhost.exe') -like 'notification access is denied*')
Check 'meaning: exit code 1 of a process is the TerminateProcess/own-failure ambiguity, said as such' ((Get-QwtDeathCodeMeaning ([uint32]1) 'process') -like 'exit code 1 - the code TerminateProcess imposes*')
# 0x40010004 is DBG_TERMINATE_PROCESS: what Windows imposes on every process of a session it tears down - the commonest exit code at
# shutdown. Measured 2026-10-10 on win10-acc: four records of our source carried it (gui-agent.exe twice, notifhost.exe twice) and the
# table had no row, so qwt-deaths.log and the dom0 notification read "Cause: exit code 0x40010004 - not a code this reporter knows".
Check 'meaning: 0x40010004 is Windows'' own session teardown (DBG_TERMINATE_PROCESS), a code this reporter knows' ((Get-QwtDeathCodeMeaning ([uint32]0x40010004L) 'process') -like 'Windows'' own session teardown (DBG_TERMINATE_PROCESS)*')
Check 'exception: 0xC... and 0xE... codes are exceptions, HRESULTs and small codes are not' ((Test-QwtDeathExceptionCode ([uint32]0xC0000005L)) -and (Test-QwtDeathExceptionCode ([uint32]0xE06D7363L)) -and -not (Test-QwtDeathExceptionCode ([uint32]0x80070002L)) -and -not (Test-QwtDeathExceptionCode ([uint32]1)))
Check 'format: a large code renders as 0x%08X' ((Format-QwtDeathCode ([uint32]0xC0000005L) 'exception') -eq 'exception 0xC0000005')
Check 'format: a small code renders in decimal' ((Format-QwtDeathCode ([uint32]1460) 'Windows error') -eq 'Windows error 1460')
Check 'format: an unknown code is said so' ((Format-QwtDeathCode $null 'exit code') -eq 'exit code unknown')
Check 'format: 754000 ms -> 0:12:34' ((Format-QwtDeathRun 754000) -eq '0:12:34')
Check 'format: an unknown run time renders empty (the technical line omits it)' ((Format-QwtDeathRun $null) -eq '')
Check 'cause: meaning then the code' ((Format-QwtDeathCause ([uint32]0xC0000005L) 'process' '' 'exception 0xC0000005' 'the WER report') -eq 'Cause: an access violation - exception 0xC0000005.')
Check 'cause: an unknown code is said to be unknown, never guessed' ((Format-QwtDeathCause ([uint32]0xC0000AAAL) 'process' '' 'exception 0xC0000AAA' 'the WER report') -eq 'Cause: exception 0xC0000AAA - not a code this reporter knows; the WER report has the detail.')
Check 'component: a script task''s machine id comes from its table, in the executables'' style' ($script:QwtDeathTaskNames['\QubesPvNic'].id -eq 'pvnic' -and $script:QwtDeathTaskNames['\QubesAutologonGuard'].id -eq 'autologon-guard' -and $script:QwtDeathTaskNames['\QubesWindowsUpdateDownload'].id -eq 'update-download')
Check 'recovery: armed -> Windows restarts it; armed for crashes only -> not after an error exit; unreadable -> no guess' (((Format-QwtDeathRecovery @{ restart = $true; delayMs = 5000; onError = $true } $true) -like 'Windows restarts it automatically*5 s)') -and ((Format-QwtDeathRecovery @{ restart = $true; delayMs = 5000; onError = $false } $true) -like 'Windows does NOT restart it after an error exit*') -and ((Format-QwtDeathRecovery @{ restart = $true; delayMs = 5000; onError = $false } $false) -like 'Windows restarts it automatically*') -and ((Format-QwtDeathRecovery @{ restart = $false; delayMs = 0; onError = $true } $true) -like 'Windows does NOT restart it (no restart is armed)*') -and ((Format-QwtDeathRecovery $null $true) -like 'Windows restarts it only if its recovery is armed*'))

# 3. ownership and parsing, record by record
$ev = ConvertFrom-QwtDeathEvent (New-Crash 'notepad.exe' 100 0xC0000005L $T0)
Check 'ours: a notepad.exe crash is not ours' (-not $ev.ours) $ev.reason
$ev = ConvertFrom-QwtDeathEvent (New-Crash 'gui-agent.exe' 100 0xC0000005L $T0 754 'C:\Users\u\Downloads\gui-agent.exe')
Check 'ours: a gui-agent.exe outside our install directory is not ours' (-not $ev.ours) $ev.reason
$ev = ConvertFrom-QwtDeathEvent (New-Crash 'gui-agent.exe' 6700 0xC0000409L $T0)
Check 'crash 1000: ours, kind crash, component gui-agent' ($ev.ours -and $ev.kind -eq 'crash' -and $ev.component -eq 'gui-agent')
Check 'crash 1000: pid from the hex field' ($ev.pid -eq 6700)
Check 'crash 1000: exception code from the hex field, an exception-class code' ($ev.code -eq [uint32]0xC0000409L -and (Test-QwtDeathExceptionCode $ev.code))
Check 'crash 1000: run time from the start FILETIME (754 s)' ($null -ne $ev.ranMs -and [Math]::Abs($ev.ranMs - 754000) -lt 1000) "$($ev.ranMs)"
Check 'crash 1000: keyed by pid' ($ev.anchor -eq 'pid')
Check 'crash 1000: the EventID with Qualifiers still parses' ($ev.origin -like 'Application/1000#*')
$ev = ConvertFrom-QwtDeathEvent (New-Crash 'GUI-Agent.EXE' 6700 0xC0000409L $T0 754 'C:\PROGRAM FILES\Qubes Tools\bin\GUI-Agent.EXE')
Check 'crash 1000: the name and path compare case-insensitively' ($ev.ours -and $ev.exe -eq 'gui-agent.exe')
$ev = ConvertFrom-QwtDeathEvent (New-Wer 'gui-agent.exe' 0xC0000409L $T0)
Check 'wer 1001: ours, join-only, code from P7' ($ev.ours -and $ev.kind -eq 'wer' -and $ev.anchor -eq 'join-only' -and $ev.code -eq [uint32]0xC0000409L)
Check 'wer 1001: the report folder is the evidence' ($ev.evidence -like '*\WER\ReportArchive\AppCrash_gui-agent.exe_*')
Check 'wer 1001: the WER event name is rendered' ($ev.label -like '*recorded APPCRASH*')
$ev = ConvertFrom-QwtDeathEvent (New-Wer 'explorer.exe' 0xC0000409L $T0)
Check 'wer 1001: a foreign report is not ours' (-not $ev.ours)
$ev = ConvertFrom-QwtDeathEvent (New-Clr 'qwtng-netsetup.exe' 'System.NullReferenceException' $T0)
Check 'clr 1026: ours, exe from the Application: line, opens a death that a 1000 may adopt' ($ev.ours -and $ev.exe -eq 'qwtng-netsetup.exe' -and $ev.anchor -eq 'nopid-adoptable')
Check 'clr 1026: the exception type is in the label' ($ev.label -like '*System.NullReferenceException*')
$ev = ConvertFrom-QwtDeathEvent (New-Clr 'contoso.exe' 'System.Exception' $T0)
Check 'clr 1026: a foreign managed crash is not ours' (-not $ev.ours)
$ev = ConvertFrom-QwtDeathEvent (New-Super 4001 'gui-agent.exe' '4321' '0xC0000005' '60000' $T0)
Check 'our 4001: ours, keyed by pid, exit code and run time from the structured strings' ($ev.ours -and $ev.kind -eq 'supervisor' -and $ev.anchor -eq 'pid' -and $ev.pid -eq 4321 -and $ev.code -eq [uint32]0xC0000005L -and $ev.ranMs -eq 60000)
Check 'our 4001: the label says it exited unasked, the event id is kept' ($ev.label -like '*exited without being asked to*' -and $ev.eventId -eq 4001)
$ev = ConvertFrom-QwtDeathEvent (New-Super 4002 'wgcbroker.exe' '500' 'unknown' 'unknown' $T0)
Check 'our 4002: unknown code and run time stay unknown, and unknown is not a hang' ($ev.ours -and $null -eq $ev.code -and $null -eq $ev.ranMs -and -not $ev.hung)
$ev = ConvertFrom-QwtDeathEvent (New-Super 4002 'wgcbroker.exe' '500' 'hung' '125000' $T0)
Check 'our 4002: "hung" is a hang - no exit code, the label says it stopped answering and was ended' ($ev.ours -and $ev.hung -and $null -eq $ev.code -and $ev.ranMs -eq 125000 -and $ev.label -like '*stopped answering (a hang) and was ended by the GUI agent*')
$ev = ConvertFrom-QwtDeathEvent (New-Super 4999 'gui-agent.exe' '1' '0x0' '1' $T0)
Check 'our source, id 4999: not a death record' (-not $ev.ours)
$ev = ConvertFrom-QwtDeathEvent (New-Svc 7023 'Qubes RPC agent' $T0 @{ param2 = '%%1460' })
Check 'scm 7023: ours, always a new death, code 1460 from "%%1460"' ($ev.ours -and $ev.exe -eq 'qrexec-agent.exe' -and $ev.anchor -eq 'nopid' -and $ev.code -eq 1460)
$ev = ConvertFrom-QwtDeathEvent (New-Svc 7024 'QubesDB daemon' $T0 @{ param2 = '1287 (0x507)' })
Check 'scm 7024: service-specific error 1287, its service key for the recovery probe' ($ev.ours -and $ev.code -eq 1287 -and $ev.eventId -eq 7024 -and $ev.svcKey -eq 'QdbDaemon')
$ev = ConvertFrom-QwtDeathEvent (New-Svc 7031 'Qubes GUI agent watchdog' $T0 @{ param2 = '1'; param3 = '5000'; param4 = 'Restart the service' })
Check 'scm 7031: ours, enrich, count and action kept' ($ev.ours -and $ev.exe -eq 'gui-watchdog.exe' -and $ev.anchor -eq 'enrich' -and $ev.svcCount -eq '1' -and $ev.svcDelay -eq '5000' -and $ev.svcAction -eq 'Restart the service' -and $ev.label -like '*(failure 1); recovery: Restart the service in 5000 ms')
$ev = ConvertFrom-QwtDeathEvent (New-Svc 7031 'Qubes PV NIC address applier' $T0 @{ param2 = 'x'; param3 = '<b>'; param4 = '<script>alert(1)</script>' })
Check 'scm 7031: fields that are not shaped as numbers/phrases are not rendered verbatim' ($ev.ours -and $ev.svcCount -eq '?' -and $ev.svcDelay -eq '?' -and $ev.svcAction -eq 'the configured action' -and $ev.label -like '*(failure ?); recovery: the configured action in ? ms')
$ev = ConvertFrom-QwtDeathEvent (New-Svc 7034 'Print Spooler' $T0 @{ param2 = '1' })
Check 'scm 7034: a foreign service is not ours' (-not $ev.ours)
$ev = ConvertFrom-QwtDeathEvent (New-Task 201 '\Qubes-WgcBroker' '3221226505' $T0)
Check 'task 201 helper: ours, the helper''s exe, join-only, result 0xC0000409' ($ev.ours -and $ev.exe -eq 'wgcbroker.exe' -and $ev.anchor -eq 'join-only' -and $ev.code -eq [uint32]0xC0000409L)
$ev = ConvertFrom-QwtDeathEvent (New-Task 201 '\QubesPvNic' '1' $T0)
Check 'task 201 script: ours, its own death, the component is the task''s machine id from the table' ($ev.ours -and $ev.anchor -eq 'nopid' -and $ev.component -eq 'pvnic' -and $ev.task -eq '\QubesPvNic' -and $ev.taskName -eq 'QubesPvNic')
$ev = ConvertFrom-QwtDeathEvent (New-Task 201 '\QubesPvNic' '0' $T0)

# --- a TERMINATED task instance: ended by a shutdown is not a death, ended for any other reason is
# Measured 2026-10-07: \QubesWindowsUpdateScan 201 ResultCode 2147943691 (0x8007050B) with a 111 for
# the same instance at the same second, because the guest was shut down mid-scan - and dom0 was told
# "The Windows Update scan task failed" about a scan that was working and was stopped. 267014 was
# already ignored on this principle; the terminated-instance case was not. Both probes are driven
# here, because Get-WinEvent cannot run off Windows and would otherwise fail closed and test nothing.
$script:QwtTaskEndedProbe    = { param([string]$i) return $true }
$script:QwtShutdownNearProbe = { param([datetime]$t) return $true }
$ev = ConvertFrom-QwtDeathEvent (New-Task 201 '\QubesWindowsUpdateScan' '2147943691' $T0)
Check 'ended by shutdown: a 201 whose instance Task Scheduler ended while the system went down is ignored, not a death' `
      ($ev.ignore -eq $true -and -not $ev.ours) "ignore=$($ev.ignore) ours=$($ev.ours) reason=$($ev.reason)"
$script:QwtShutdownNearProbe = { param([datetime]$t) return $false }
$ev = ConvertFrom-QwtDeathEvent (New-Task 201 '\QubesWindowsUpdateScan' '2147943691' $T0)
Check 'ended NOT by shutdown: an instance ended at its execution time limit is STILL a death - nothing is concealed' `
      ($ev.ours -eq $true -and $ev.ignore -ne $true) "ignore=$($ev.ignore) ours=$($ev.ours)"
$script:QwtTaskEndedProbe    = { param([string]$i) return $false }
$ev = ConvertFrom-QwtDeathEvent (New-Task 201 '\QubesWindowsUpdateScan' '2147943691' $T0)
Check 'not ended: an ordinary non-zero task result is a death as before' ($ev.ours -eq $true -and $ev.ignore -ne $true)
# THIS CASE HAD NO EVENT. The line below was missing, so the check asserted on the PREVIOUS case's
# event - a non-zero result, which is a death - and had been failing ever since, permanently, which
# is how a suite stops being able to report a real regression ("142 checks, 1 failed" was the
# expected output). A 201 whose result is 0 is a task that SUCCEEDED and is not a death.
$ev = ConvertFrom-QwtDeathEvent (New-Task 201 '\QubesWindowsUpdateScan' '0' $T0)
Check 'task 201 result 0: not a death' (-not $ev.ours)
# AN EXE EXIT THAT MEANS "I AM ALREADY RUNNING" IS NOT A DEATH. FIELD-REPORTED by GWeck on 4.3.35
# (forum 42717 post 175, screenshot): "a lot of notifications pop up" on VM start, FOUR of them
# "The notification bridge exited unexpectedly ... Cause: a clean exit nobody asked for - exit code
# 0", pids 8772/6796/10168/1232, each ran 0:00:00, numbered death 1, 2, 4 and 6 of ONE boot.
# Asserted STRUCTURALLY rather than by building a 4003 record: my first version invented a helper
# name that does not exist, and guessing an event's positional shape is how this class of mistake
# starts. The agent-side fix (main.c adopts exit 4 without reporting) is the primary one; this map
# covers a record written by an older binary on an upgraded guest.
$src = Get-Content $ReporterPath -Raw
Check 'exe benign map: notifhost exit 4 is recorded as already running, not a death' `
      ($src -match "(?s)QwtDeathExeBenignResults.{0,400}notifhost\.exe.{0,200}'4'")
# Simple and robust: the map name must appear with ContainsKey nearby. My first pattern tried to
# escape $Death.exe through two layers of quoting and matched nothing, failing code that was right.
Check 'exe benign map: the supervisor branch consults it before judging a death' `
      ($src -match '(?s)QwtDeathExeBenignResults.{0,160}ContainsKey')
Check 'exe benign map: a REAL non-zero exit is still a death (the map is keyed by exact code)' `
      ($src -notmatch "(?s)QwtDeathExeBenignResults.{0,400}'0'\s*=")

# A RESULT A TASK USES TO MEAN SOMETHING OTHER THAN FAILURE (owner 2026-10-08: user-facing error
# lines are top priority). ensure-autologon.ps1's own contract: 0 armed, 2 NOT armed, 3 could not be
# VERIFIED - "no positive finding either way", and "3 is deliberately not 2". The updater honoured
# that; the user was told "The autologon guard task failed" for a probe that could not run.
$ev = ConvertFrom-QwtDeathEvent (New-Task 201 '\QubesAutologonGuard' '3' $T0)
Check 'task 201 QubesAutologonGuard result 3: could not VERIFY is not a death' `
      (-not $ev.ours -and $ev.ignore -and "$($ev.reason)" -match 'not a failure')
# AND 2 IS STILL A DEATH - a qube that cannot log itself back in is exactly what the user must hear.
$ev = ConvertFrom-QwtDeathEvent (New-Task 201 '\QubesAutologonGuard' '2' $T0)
Check 'task 201 QubesAutologonGuard result 2: NOT armed IS still a death' ($ev.ours -and $ev.ignore -ne $true)
# and the exemption is per TASK, not global: the same code from another task is still a death
$ev = ConvertFrom-QwtDeathEvent (New-Task 201 '\QubesWindowsUpdateScan' '3' $T0)
Check 'task 201 another task result 3: still a death (the exemption is per task)' ($ev.ours -and $ev.ignore -ne $true)

$ev = ConvertFrom-QwtDeathEvent (New-Task 201 '\Qubes-NotifBridge' '267014' $T0)
Check 'task 201 result 0x41306: ended by Task Scheduler on request, ignored' (-not $ev.ours -and $ev.ignore)
$ev = ConvertFrom-QwtDeathEvent (New-Task 201 '\QwtDeathReporter' '1' $T0)
Check 'task 201 of the reporter itself: not ours (no self-trigger)' (-not $ev.ours)
$ev = ConvertFrom-QwtDeathEvent (New-Task 201 '\Microsoft\Windows\Defrag\ScheduledDefrag' '1' $T0)
Check 'task 201 of a Windows task: not ours' (-not $ev.ours)
$ev = ConvertFrom-QwtDeathEvent (New-Task 203 '\QubesAutologonGuard' '2147942402' $T0)
Check 'task 203: ours, launch failure, HRESULT rendered from the task table' ($ev.ours -and $ev.kind -eq 'launchfail' -and (Format-QwtDeathCode $ev.code 'result') -eq 'result 0x80070002' -and (Get-QwtDeathCodeMeaning $ev.code 'task') -eq 'the file was not found')
$ev = ConvertFrom-QwtDeathEvent (New-EvXml 'Application Error' 1002 'Application' $T0 @('gui-agent.exe') $null $true)
Check 'application error 1002 (a hang) is not in the subscription: not ours' (-not $ev.ours)

# 4. identity and count, end to end through the route
Reset-World
$st = Invoke-QwtDeathReport (New-Crash 'notepad.exe' 100 0xC0000005L $T0)
CheckStatus 'e2e: a foreign crash' $st 'not-ours'
Check 'e2e: a foreign crash touches no ledger and sends nothing' ((Get-Ledger).Count -eq 0 -and $script:launched.Count -eq 0)
$st = Invoke-QwtDeathReport (New-Crash 'gui-agent.exe' 6700 0xC0000409L $T0)
CheckStatus 'e2e: death 1 - gui-agent crash' $st 'send'
Check 'e2e: death 1 notified once' ($script:launched.Count -eq 1)
$text = [string]$script:launched[0]
Check 'text: the header names the GUI agent in human words and says it crashed' ($text.StartsWith("The GUI agent crashed`r`n"))
Check 'text: four lines - header, what next, the cause, the technical line' (@($text -split "`r`n").Count -eq 4)
Check 'text: what next - Windows restarts the watchdog service, which starts a new agent (nothing of ours relaunches)' ($text -like "*`r`nIts watchdog service ends itself so Windows restarts it*" -and $text -notlike '*relaunches it*')
Check 'text: the cause with the exception code and its meaning from the process table' ($text -like '*Cause: a fast-fail abort (stack buffer overrun, __fastfail or an abort) - exception 0xC0000409.*')
Check 'text: how long it ran' ($text -like '*; ran 0:12:34;*')
Check 'text: the death count this boot, never "once per boot"' ($text -like '*death 1 this boot*' -and $text -notlike '*once per boot*')
Check 'text: id death-1 (the route''s marker)' (Test-Path -LiteralPath (Join-Path $stateDir 'gui-agent.death-1'))
Check 'text: the evidence - our deaths log and the WER folder by prefix' ($text -like "*$logDir\qwt-deaths.log*" -and $text -like '*AppCrash_gui-agent.exe_**')
Check 'text: no 32-hex run, no window title, no user path' ($text -notmatch '[0-9A-Fa-f]{32,}' -and $text -notmatch 'Users\\')
Check 'text: under the route''s 600 bytes' ([Text.Encoding]::UTF8.GetByteCount($text) -le 600) "$([Text.Encoding]::UTF8.GetByteCount($text))"
Check 'log: death 1 is logged at ERROR as NEW with the pid' ((Get-DeathLog) -match '\[ERROR\] DEATH #1 NEW Application/1000#\d+: The GUI agent crashed \| gui-agent\.exe crashed.*pid 6700')
$st = Invoke-QwtDeathReport (New-Wer 'gui-agent.exe' 0xC0000409L $T0.AddSeconds(3))
CheckStatus 'e2e: the WER record of death 1' $st 'enriched'
Check 'e2e: the WER record adds no notification' ($script:launched.Count -eq 1)
Check 'log: the WER record is logged as AGAIN with the full folder path' ((Get-DeathLog) -match '\[ERROR\] DEATH #1 AGAIN Application/1001#\d+:.*evidence .*\\WER\\ReportArchive\\AppCrash_gui-agent\.exe_')
$st = Invoke-QwtDeathReport (New-Crash 'gui-agent.exe' 7100 0xC0000005L $T0.AddSeconds(30) 25)
CheckStatus 'e2e: death 2 - a SECOND gui-agent crash 30 s later (another pid) is a second death' $st 'send'
Check 'e2e: death 2 notified (not hidden by the once-per-id rule)' ($script:launched.Count -eq 2 -and ([string]$script:launched[1]) -like '*death 2 this boot*' -and (Test-Path -LiteralPath (Join-Path $stateDir 'gui-agent.death-2')))
Check 'ledger: two deaths, keyed by pid' ((@(Get-Ledger | Where-Object { $_ -like 'D|*' })).Count -eq 2 -and (Get-Ledger)[1] -like 'D|1|*|gui-agent.exe|6700|crash|*' -and (Get-Ledger)[2] -like 'D|2|*|gui-agent.exe|7100|crash|*')
$st = Invoke-QwtDeathReport (New-Super 4002 'wgcbroker.exe' '500' '0xC0000005' '12000' $T0.AddSeconds(60))
CheckStatus 'e2e: death 3 - the agent''s broker record' $st 'send'
$st = Invoke-QwtDeathReport (New-Task 201 '\Qubes-WgcBroker' '3221225477' $T0.AddSeconds(61))
CheckStatus 'e2e: the broker task''s 201 attaches to death 3' $st 'enriched'
$st = Invoke-QwtDeathReport (New-Super 4002 'wgcbroker.exe' '600' '0xC0000005' '8000' $T0.AddSeconds(80))
CheckStatus 'e2e: death 4 - the relaunched broker dies again 20 s later (another pid)' $st 'send'
Check 'e2e: four notifications so far' ($script:launched.Count -eq 4)
$st = Invoke-QwtDeathReport (New-Clr 'qwtng-netsetup.exe' 'System.NullReferenceException' $T0.AddSeconds(120))
CheckStatus 'e2e: death 5 - a managed crash, the 1026 comes first' $st 'send'
Check 'text: the managed death names the exception type' (([string]$script:launched[4]) -like '*Cause: an unhandled .NET exception, System.NullReferenceException.*')
$st = Invoke-QwtDeathReport (New-Crash 'qwtng-netsetup.exe' 900 0xE0434352L $T0.AddSeconds(121) 3600)
CheckStatus 'e2e: its 1000 adopts death 5' $st 'enriched'
Check 'ledger: death 5 now carries the adopted pid' (@(Get-Ledger | Where-Object { $_ -like 'D|5|*|qwtng-netsetup.exe|900|clr|*' }).Count -eq 1)
$st = Invoke-QwtDeathReport (New-Wer 'qwtng-netsetup.exe' 0xE0434352L $T0.AddSeconds(122))
CheckStatus 'e2e: its 1001 attaches to death 5' $st 'enriched'
$st = Invoke-QwtDeathReport (New-Svc 7031 'Qubes PV NIC address applier' $T0.AddSeconds(122) @{ param2 = '1'; param3 = '5000'; param4 = 'Restart the service' })
CheckStatus 'e2e: the SCM''s 7031 for the same service attaches to death 5' $st 'enriched'
Check 'e2e: still five notifications' ($script:launched.Count -eq 5)
$st = Invoke-QwtDeathReport (New-Svc 7023 'Qubes RPC agent' $T0.AddSeconds(200) @{ param2 = '%%1460' })
CheckStatus 'e2e: death 6 - QrexecAgent ended with error 1460' $st 'send'
Check 'text: the service death - the header, Windows'' armed restart, the Windows error from its own table, the count' (([string]$script:launched[5]).StartsWith("The Qubes RPC agent service stopped with an error`r`nWindows restarts it automatically (its recovery is armed; the first restart after 5 s); while it is down this qube cannot be reached from dom0.`r`nCause: the operation timed out - Windows error 1460.`r`nqrexec-agent.exe (service QrexecAgent); Windows error 1460; death 6 this boot.") -and ([string]$script:launched[5]) -notlike '*TerminateProcess*')
$st = Invoke-QwtDeathReport (New-Svc 7031 'Qubes RPC agent' $T0.AddSeconds(200) @{ param2 = '1'; param3 = '5000'; param4 = 'Restart the service' })
CheckStatus 'e2e: its 7031 attaches to death 6' $st 'enriched'
$st = Invoke-QwtDeathReport (New-Svc 7023 'Qubes RPC agent' $T0.AddSeconds(210) @{ param2 = '%%1460' })
CheckStatus 'e2e: death 7 - the restarted QrexecAgent fails again 10 s later (a second error exit)' $st 'send'
$st = Invoke-QwtDeathReport (New-Task 203 '\QubesAutologonGuard' '2147942402' $T0.AddSeconds(300))
CheckStatus 'e2e: death 8 - a task of ours could not start' $st 'send'
Check 'e2e: eight notifications, the route''s cap' ($script:launched.Count -eq 8)
$st = Invoke-QwtDeathReport (New-Super 4003 'notifhost.exe' '777' '0x00000002' '30000' $T0.AddSeconds(400))
CheckStatus 'e2e: death 9 - past the cap, the route suppresses' $st 'suppressed:cap'
Check 'e2e: death 9 sent nothing' ($script:launched.Count -eq 8)
Check 'log: death 9 is STILL logged at ERROR as NEW (past the cap)' ((Get-DeathLog) -match '\[ERROR\] DEATH #9 NEW Application/4003#\d+: The notification bridge exited unexpectedly \| notifhost\.exe exited without being asked to')
Check 'log: and the suppression is logged at ERROR, naming the cap' ((Get-DeathLog) -match '\[ERROR\] DEATH #9 NOT notified: the route''s cap of 8 per boot')
$st = Invoke-QwtDeathReport (New-Task 201 '\Qubes-NotifBridge' '267014' $T0.AddSeconds(401))
CheckStatus 'e2e: a Task-Scheduler-ended helper is ignored' $st 'ignored'
Check 'ledger: nine deaths, the ignored record added none' ((@(Get-Ledger | Where-Object { $_ -like 'D|*' })).Count -eq 9)

# 5. a new boot: the count restarts and the first death is sent again
$script:QwtNotifyBootStamp = $BOOT + 1
$script:QwtNotifyBootCached = $null
$st = Invoke-QwtDeathReport (New-Crash 'gui-agent.exe' 6700 0xC0000409L $T0.AddHours(1))
CheckStatus 'boot: the first death of the next boot is sent' $st 'send'
Check 'boot: it is death 1 again, with id death-1 under the new boot' (([string]$script:launched[8]) -like '*death 1 this boot*' -and ([IO.File]::ReadAllText((Join-Path $stateDir 'gui-agent.death-1')) -like "boot=$($BOOT + 1)*"))
Check 'boot: the ledger belongs to the new boot and holds one death' ((Get-Ledger)[0] -eq "boot=$($BOOT + 1)" -and (@(Get-Ledger | Where-Object { $_ -like 'D|*' })).Count -eq 1)

# 6. the gate off: counted and logged, not sent
Reset-World
$script:QwtNotifyGate = $false
$st = Invoke-QwtDeathReport (New-Crash 'gui-agent.exe' 6700 0xC0000409L $T0)
CheckStatus 'gate off: the route reports gated' $st 'gated'
Check 'gate off: still logged at ERROR and counted' ((Get-DeathLog) -match 'DEATH #1 NEW' -and (@(Get-Ledger | Where-Object { $_ -like 'D|*' })).Count -eq 1)

# 6b. a service that keeps exiting WITHOUT a crash record leaves only 7031s - each one is a death (one record of each type per death;
#     before that rule three such deaths in 80 s were ONE notification, found in review 2026-10-03)
Reset-World
$st1 = Invoke-QwtDeathReport (New-Svc 7031 'Qubes RPC agent' $T0 @{ param2 = '1'; param3 = '5000'; param4 = 'Restart the service' })
$st2 = Invoke-QwtDeathReport (New-Svc 7031 'Qubes RPC agent' $T0.AddSeconds(20) @{ param2 = '2'; param3 = '15000'; param4 = 'Restart the service' })
$st3 = Invoke-QwtDeathReport (New-Svc 7031 'Qubes RPC agent' $T0.AddSeconds(80) @{ param2 = '3'; param3 = '60000'; param4 = 'Restart the service' })
Check 'svc loop: three bare 7031s of one service at 0/20/80 s are three deaths and three notifications' ($st1 -eq 'send' -and $st2 -eq 'send' -and $st3 -eq 'send' -and $script:launched.Count -eq 3)
$st4 = Invoke-QwtDeathReport (New-Crash 'qrexec-agent.exe' 5100 0xC0000005L $T0.AddSeconds(120))
$st5 = Invoke-QwtDeathReport (New-Svc 7031 'Qubes RPC agent' $T0.AddSeconds(121) @{ param2 = '4'; param3 = '60000'; param4 = 'Restart the service' })
$st6 = Invoke-QwtDeathReport (New-Svc 7031 'Qubes RPC agent' $T0.AddSeconds(150) @{ param2 = '5'; param3 = '60000'; param4 = 'Restart the service' })
Check 'svc loop: a crash''s own 7031 joins that crash, and the next bare 7031 is the next death' ($st4 -eq 'send' -and $st5 -eq 'enriched' -and $st6 -eq 'send' -and $script:launched.Count -eq 5)

# 6c. records that only JOIN a death never open one; a reused pid cannot hide a second crash (review 2026-10-03)
Reset-World
$st = Invoke-QwtDeathReport (New-Crash 'autologon.exe' 4321 0xC0000005L $T0 754 'C:\Tools\Sysinternals\autologon.exe')
$st2 = Invoke-QwtDeathReport (New-Wer 'autologon.exe' 0xC0000005L $T0.AddSeconds(2))
Check 'wer join: a foreign autologon.exe - its 1000 refused by its path, its 1001 alone - opens no death and sends nothing' ($st -eq 'not-ours' -and $st2 -eq 'not-a-death' -and $script:launched.Count -eq 0)
$st = Invoke-QwtDeathReport (New-Task 201 '\Qubes-WgcBroker' '1' $T0.AddSeconds(30))
Check 'helper join: a helper task''s 201 with no 4002/4003 (the agent ended the task itself) opens no death' ($st -eq 'not-a-death' -and $script:launched.Count -eq 0)
$st = Invoke-QwtDeathReport (New-Crash 'gui-agent.exe' 6100 0xC0000409L $T0.AddSeconds(60))
$st2 = Invoke-QwtDeathReport (New-Crash 'gui-agent.exe' 6100 0xC0000409L $T0.AddSeconds(360))
Check 'pid reuse: a second crash record of the SAME pid 5 min later is a second death' ($st -eq 'send' -and $st2 -eq 'send' -and $script:launched.Count -eq 2)
$st = Invoke-QwtDeathReport (New-Super 4001 'gui-agent.exe' '7001' '0xC0000005' '90000' $T0.AddSeconds(400))
$st2 = Invoke-QwtDeathReport (New-Crash 'gui-agent.exe' 7002 0xC0000409L $T0.AddSeconds(410))
Check 'pid identity: a crash of ANOTHER pid right after the watchdog''s record of the first is a second death' ($st -eq 'send' -and $st2 -eq 'send' -and $script:launched.Count -eq 4)

# 6d. what is OURS: a .NET 1026 only for our managed executables; the install dir from the registry or the script's own place
Reset-World
$clrForeign = New-EvXml '.NET Runtime' 1026 'Application' $T0 @("Application: autologon.exe`nFramework Version: v4.0.30319`nDescription: The process was terminated due to an unhandled exception.`nException Info: System.InvalidOperationException") $null
$st = Invoke-QwtDeathReport $clrForeign
Check 'clr not ours: a foreign .NET program named like one of our native executables (autologon.exe) is not ours' ($st -eq 'not-ours' -and $script:launched.Count -eq 0)
Check 'install dir: the registry InstallDir decides, else the folder above the script''s bin, else the default' `
      ((Resolve-QwtDeathInstallDir 'D:\QWT' 'C:\Program Files\Qubes Tools\bin') -eq 'D:\QWT\' -and
       (Resolve-QwtDeathInstallDir '' 'E:\Tools\QWT\bin') -eq 'E:\Tools\QWT\' -and
       (Resolve-QwtDeathInstallDir '' '') -eq 'C:\Program Files\Qubes Tools\')

# 6e. THE WATCHDOG'S OWN EXIT AFTER THE AGENT'S DEATH (2026-10-07, docs/ADR-supervision.md 5): the service ends itself with
#     QGA_SVC_EXIT_AGENT_DIED (0x20514710 = 541853456) for the SCM's recovery; its 7024 with that code and the 7031 of the restart
#     are records of the agent's 4001 death - ONE notification. A launch failure (0x20514711) and a 7024 with any other code
#     are the watchdog's own deaths; a watchdog 7031 with no agent death nearby is its own death too.
Reset-World
$st = Invoke-QwtDeathReport (New-Super 4001 'gui-agent.exe' '6100' '0xC0000005' '90000' $T0)
CheckStatus 'wd exit: death 1 - the agent''s 4001' $st 'send'
$st = Invoke-QwtDeathReport (New-Svc 7024 'Qubes GUI agent watchdog' $T0.AddSeconds(1) @{ param2 = '542197520' })
CheckStatus 'wd exit: the watchdog''s 7024 with QGA_SVC_EXIT_AGENT_DIED attaches to the agent''s death' $st 'enriched'
$st = Invoke-QwtDeathReport (New-Svc 7031 'Qubes GUI agent watchdog' $T0.AddSeconds(2) @{ param2 = '1'; param3 = '5000'; param4 = 'Restart the service' })
CheckStatus 'wd exit: the SCM''s 7031 for that end attaches to the agent''s death too' $st 'enriched'
Check 'wd exit: ONE notification for the agent death, its service exit and the restart record' ($script:launched.Count -eq 1)
Check 'wd exit: the ledger holds one death with the three record types' ((@(Get-Ledger | Where-Object { $_ -like 'D|*' })).Count -eq 1 -and (Get-Ledger)[1] -like 'D|1|*|gui-agent.exe|6100|supervisor|*|supervisor,scm-agentdied,scm-unexpected')
Check 'wd exit: the AGAIN lines say it is a record of the agent''s death' ((Get-DeathLog) -match 'DEATH #1 AGAIN System/7024#\d+:.*ended itself after the GUI agent died \(service error 542197520\) - a record of the agent''s death')
$st = Invoke-QwtDeathReport (New-Svc 7024 'Qubes GUI agent watchdog' $T0.AddSeconds(700) @{ param2 = '542197520' })
CheckStatus 'wd exit: the same 7024 with NO agent death to join (outside the window) opens a death of the watchdog''s own' $st 'send'
Check 'wd exit: that death''s text names the cause from the watchdog''s code table and what Windows does next' (([string]$script:launched[1]) -like "The GUI agent watchdog service stopped with an error`r`nWindows restarts it automatically*`r`nCause: the GUI agent it supervises died, so the service ended itself for Windows to restart it and a new GUI agent - service error 0x20514710.`r`n*")
$st = Invoke-QwtDeathReport (New-Svc 7024 'Qubes GUI agent watchdog' $T0.AddSeconds(1400) @{ param2 = '542197521' })
CheckStatus 'wd exit: a launch failure (QGA_SVC_EXIT_LAUNCH_FAILED) is the watchdog''s own death' $st 'send'
Check 'wd exit: the launch failure says so' (([string]$script:launched[2]) -like "*`r`nCause: the GUI agent could not be started, so the service ended itself for Windows to restart it and retry - service error 0x20514711.`r`n*")
$st = Invoke-QwtDeathReport (New-Svc 7024 'Qubes GUI agent watchdog' $T0.AddSeconds(2100) @{ param2 = '7' })
CheckStatus 'wd exit: a watchdog 7024 with any other code is its own death, as before' $st 'send'
$st = Invoke-QwtDeathReport (New-Svc 7034 'Qubes GUI agent watchdog' $T0.AddSeconds(2800) @{ param2 = '1' })
CheckStatus 'wd exit: a watchdog 7034 with no agent death nearby is its own death (a genuine watchdog crash)' $st 'send'
$st = Invoke-QwtDeathReport (New-Crash 'gui-watchdog.exe' 3300 0xC0000005L $T0.AddSeconds(3500) 20)
$st2 = Invoke-QwtDeathReport (New-Svc 7031 'Qubes GUI agent watchdog' $T0.AddSeconds(3501) @{ param2 = '2'; param3 = '15000'; param4 = 'Restart the service' })
Check 'wd exit: a watchdog CRASH (1000) and its 7031 are one death of the watchdog, not of the agent' ($st -eq 'send' -and $st2 -eq 'enriched' -and $script:launched.Count -eq 6)

# 6f. THE SESSION TEARDOWN CODE IN A RECORD OF OUR SOURCE (2026-10-10, win10-acc): qwt-deaths.log DEATH #2 at 07:39:33 for notifhost.exe
#     pid 2248 (4003, exit 0x40010004, ran 27734 ms) said "not a code this reporter knows", and dom0 was told a component died of a major
#     error. The agent writes such an end under 4011-4014 since cd73a56, but a record a PRE-cd73a56 binary wrote is still replayed by
#     -CatchUp on an upgraded guest, so the rendering must name the code. Rendered directly: whether the record is escalated at all is a
#     separate decision with its own rows, and these must hold either way.
Reset-World
$ev = ConvertFrom-QwtDeathEvent (New-Super 4003 'notifhost.exe' '2248' '0x40010004' '27734' $T0)
$n = Format-QwtDeathNotice -Death $ev -Number 2
Check 'teardown code: the cause names Windows'' own session teardown (DBG_TERMINATE_PROCESS) with the code, never "not a code this reporter knows"' `
      ($n.Cause -like "Cause: Windows' own session teardown (DBG_TERMINATE_PROCESS)*- exit code 0x40010004." -and $n.Cause -notlike '*not a code this reporter knows*') $n.Cause
$full = Format-QwtNotifyText -Header $n.Header -Next $n.Next -Cause $n.Cause -Tech $n.Tech
Check 'teardown code: the full text stays inside the route''s 600 bytes' ([Text.Encoding]::UTF8.GetByteCount($full) -le 600) "$([Text.Encoding]::UTF8.GetByteCount($full))"
# AND THE OTHER TWO PARTS ARE TRUE AS WELL (Jev 2026-10-10 chose: keep the escalation, fix the header and the advice). The family's
# header said "exited unexpectedly" and line 1 promised "Task Scheduler restarts it on failure" - a restart into a session that is
# going away - for a process Windows ended with its session. The record stays a counted, logged, notified death; its text changes.
$st = Invoke-QwtDeathReport (New-Super 4003 'notifhost.exe' '2248' '0x40010004' '27734' $T0)
Check 'teardown text: still escalated - sent as death 1, logged at ERROR, in the ledger' ($st -eq 'send' -and $script:launched.Count -eq 1 -and (Get-DeathLog) -match '\[ERROR\] DEATH #1 NEW Application/4003#' -and (@(Get-Ledger | Where-Object { $_ -like 'D|*' })).Count -eq 1) "status=$st launched=$($script:launched.Count)"
$lines = @()
if ($script:launched.Count) { $lines = @(([string]$script:launched[0]) -split "`r`n") }
Check 'teardown text: the header says Windows ended it, not that it exited unexpectedly or crashed' ($lines.Count -ge 4 -and $lines[0] -eq 'The notification bridge ended by Windows') "$($lines | Select-Object -First 1)"
Check 'teardown text: line 1 names the session end and the next sign-in, and promises no Task Scheduler restart' ($lines.Count -ge 4 -and $lines[1] -eq 'Windows ended it when its sign-in session ended; the GUI agent starts it again at the next sign-in.' -and $lines[1] -notlike '*Task Scheduler*' -and $lines[1] -notlike '*restarts it on failure*') "$($lines | Select-Object -Index 1)"
Check 'teardown text: the cause and the technical line carry the code, and it is death 1 this boot' ($lines.Count -ge 4 -and $lines[2] -like 'Cause: Windows'' own session teardown (DBG_TERMINATE_PROCESS)*- exit code 0x40010004.' -and $lines[3] -like '*notifhost.exe pid 2248; exit code 0x40010004; ran 0:00:27; death 1 this boot.*')
Check 'teardown text: the header obeys the header rules (no code, no file name, no count, no colon, a sentence)' ($lines.Count -ge 4 -and $lines[0] -notmatch '[0-9]' -and $lines[0] -notmatch '(?i)\.(exe|dll|log)\b' -and $lines[0] -notmatch ':' -and $lines[0] -cmatch '^[A-Z]' -and -not $lines[0].EndsWith('.'))
Check 'teardown text: the whole notification is within the route''s 600 bytes' ($script:launched.Count -eq 1 -and [Text.Encoding]::UTF8.GetByteCount([string]$script:launched[0]) -le 600)
# the GUI agent's own record (an older watchdog's 4001): line 1 names the watchdog service, which starts a new agent, not the agent
$st = Invoke-QwtDeathReport (New-Super 4001 'gui-agent.exe' '4028' '0x40010004' '175546' $T0.AddSeconds(5))
Check 'teardown text: the GUI agent''s own record - its header, and line 1 says the watchdog starts a new agent at the next sign-in' ($st -eq 'send' -and $script:launched.Count -eq 2 -and ([string]$script:launched[1]) -like "The GUI agent ended by Windows`r`nWindows ended it when its sign-in session ended; the watchdog service starts a new GUI agent at the next sign-in.`r`nCause: Windows' own session teardown*") "$(if ($script:launched.Count -ge 2) { ([string]$script:launched[1]) -replace "`r`n", ' | ' })"
# the longest human name keeps the header within the 60 characters the route's suite holds every header to
$ev2 = ConvertFrom-QwtDeathEvent (New-Super 4002 'wgcbroker.exe' '4100' '0x40010004' '125000' $T0.AddSeconds(10))
$n2 = Format-QwtDeathNotice -Death $ev2 -Number 3
Check 'teardown text: the longest name''s header stays within 60 characters' ($n2.Header.Length -le 60 -and $n2.Header -eq 'The notification and menu capture helper ended by Windows') "$($n2.Header.Length): $($n2.Header)"
# and the family's wording is untouched for every other code: the same child, exit 2, still "exited unexpectedly" with its restart line
$st = Invoke-QwtDeathReport (New-Super 4003 'notifhost.exe' '2249' '0x00000002' '30000' $T0.AddSeconds(20))
Check 'teardown text: any other exit code keeps the family''s header and its Task Scheduler restart line' ($st -eq 'send' -and $script:launched.Count -eq 3 -and ([string]$script:launched[2]) -like "The notification bridge exited unexpectedly`r`nTask Scheduler restarts it on failure*")

# 7. no boot token: an ERROR, nothing counted, nothing sent, no exception to the caller
Reset-World
$script:QwtNotifyBootStamp = $null; $script:QwtNotifyBootCached = $null
function Get-QwtNotifyBootStamp { return $null }
$st = Invoke-QwtDeathReport (New-Crash 'gui-agent.exe' 6700 0xC0000409L $T0)
CheckStatus 'no boot token: the reporter says failed:transport' $st 'failed:transport'
Check 'no boot token: logged at ERROR, no ledger, no send' ((Get-DeathLog) -match '\[ERROR\] DEATH .*NO per-boot token' -and (Get-Ledger).Count -eq 0 -and $script:launched.Count -eq 0)

Microsoft.PowerShell.Utility\Write-Host "$($script:run) checks, $($script:fail) failed"
Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
if ($script:fail -gt 0) { exit 1 }
exit 0
