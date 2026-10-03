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
      text       what died, the code with its meaning, the run time, "death n this boot", the evidence by prefix
                 (no WER hash), the route accepts it (no redaction refusal, under its size)
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

# 2. number parsing: the radix is the caller's
Check 'parse: "0x1a2c" -> 6700' ((ConvertTo-QwtDeathUInt32 '0x1a2c') -eq 6700)
Check 'parse: "c0000409" -Hex -> 0xC0000409' ((ConvertTo-QwtDeathUInt32 'c0000409' -Hex) -eq [uint32]0xC0000409L)
Check 'parse: "40000015" -Hex is hex, not decimal' ((ConvertTo-QwtDeathUInt32 '40000015' -Hex) -eq [uint32]0x40000015L)
Check 'parse: "3221226505" -> 0xC0000409' ((ConvertTo-QwtDeathUInt32 '3221226505') -eq [uint32]0xC0000409L)
Check 'parse: "%%1460" -> 1460' ((ConvertTo-QwtDeathUInt32 '%%1460') -eq 1460)
Check 'parse: "1460 (0x5B4)" -> 1460 (the b is not a radix hint)' ((ConvertTo-QwtDeathUInt32 '1460 (0x5B4)') -eq 1460)
Check 'parse: "-1073741819" -> 0xC0000005' ((ConvertTo-QwtDeathUInt32 '-1073741819') -eq [uint32]0xC0000005L)
Check 'parse: garbage -> $null' ($null -eq (ConvertTo-QwtDeathUInt32 'ERROR'))
Check 'meaning: 0xC0000409 names the fast-fail' ((Get-QwtDeathCodeMeaning ([uint32]0xC0000409L)) -like 'fast-fail*')
Check 'meaning: 1460 is a timeout' ((Get-QwtDeathCodeMeaning ([uint32]1460)) -eq 'timeout')
Check 'format: a large code renders as 0x%08X with its meaning' ((Format-QwtDeathCode ([uint32]0xC0000005L) 'exception') -eq 'exception 0xC0000005 (access violation)')
Check 'format: a small code renders in decimal' ((Format-QwtDeathCode ([uint32]1460) 'error') -eq 'error 1460 (timeout)')
Check 'format: an unknown code is said so' ((Format-QwtDeathCode $null 'exit code') -eq 'exit code unknown')
Check 'format: 754000 ms -> 0:12:34' ((Format-QwtDeathRun 754000) -eq '0:12:34')
Check 'format: an unknown run time is said so' ((Format-QwtDeathRun $null) -eq 'an unknown time')
Check 'component: a task name is lowered, stripped and bounded to 24' (((ConvertTo-QwtDeathComponent 'QubesWindowsUpdateDownload').Length -le 24) -and ((ConvertTo-QwtDeathComponent 'QubesPvNic') -eq 'qubespvnic'))

# 3. ownership and parsing, record by record
$ev = ConvertFrom-QwtDeathEvent (New-Crash 'notepad.exe' 100 0xC0000005L $T0)
Check 'ours: a notepad.exe crash is not ours' (-not $ev.ours) $ev.reason
$ev = ConvertFrom-QwtDeathEvent (New-Crash 'gui-agent.exe' 100 0xC0000005L $T0 754 'C:\Users\u\Downloads\gui-agent.exe')
Check 'ours: a gui-agent.exe outside our install directory is not ours' (-not $ev.ours) $ev.reason
$ev = ConvertFrom-QwtDeathEvent (New-Crash 'gui-agent.exe' 6700 0xC0000409L $T0)
Check 'crash 1000: ours, kind crash, component gui-agent' ($ev.ours -and $ev.kind -eq 'crash' -and $ev.component -eq 'gui-agent')
Check 'crash 1000: pid from the hex field' ($ev.pid -eq 6700)
Check 'crash 1000: exception code from the hex field' ($ev.code -eq [uint32]0xC0000409L -and $ev.codeKind -eq 'exception')
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
Check 'our 4001: the label says who relaunches it' ($ev.label -like '*QubesGuiWatchdog service relaunches it*')
$ev = ConvertFrom-QwtDeathEvent (New-Super 4002 'wgcbroker.exe' '500' 'unknown' 'unknown' $T0)
Check 'our 4002: unknown code and run time stay unknown' ($ev.ours -and $null -eq $ev.code -and $null -eq $ev.ranMs)
$ev = ConvertFrom-QwtDeathEvent (New-Super 4999 'gui-agent.exe' '1' '0x0' '1' $T0)
Check 'our source, id 4999: not a death record' (-not $ev.ours)
$ev = ConvertFrom-QwtDeathEvent (New-Svc 7023 'Qubes RPC agent' $T0 @{ param2 = '%%1460' })
Check 'scm 7023: ours, always a new death, code 1460 from "%%1460"' ($ev.ours -and $ev.exe -eq 'qrexec-agent.exe' -and $ev.anchor -eq 'nopid' -and $ev.code -eq 1460)
$ev = ConvertFrom-QwtDeathEvent (New-Svc 7024 'QubesDB daemon' $T0 @{ param2 = '1287 (0x507)' })
Check 'scm 7024: service-specific error 1287' ($ev.ours -and $ev.code -eq 1287 -and $ev.codeKind -eq 'service-specific error')
$ev = ConvertFrom-QwtDeathEvent (New-Svc 7031 'Qubes GUI agent watchdog' $T0 @{ param2 = '1'; param3 = '5000'; param4 = 'Restart the service' })
Check 'scm 7031: ours, enrich, count and action rendered' ($ev.ours -and $ev.exe -eq 'gui-watchdog.exe' -and $ev.anchor -eq 'enrich' -and $ev.label -like '*time 1 per the SCM; recovery: Restart the service in 5000 ms')
$ev = ConvertFrom-QwtDeathEvent (New-Svc 7031 'Qubes PV NIC address applier' $T0 @{ param2 = 'x'; param3 = '<b>'; param4 = '<script>alert(1)</script>' })
Check 'scm 7031: fields that are not shaped as numbers/phrases are not rendered verbatim' ($ev.ours -and $ev.label -like '*time ? per the SCM; recovery: the configured action in ? ms')
$ev = ConvertFrom-QwtDeathEvent (New-Svc 7034 'Print Spooler' $T0 @{ param2 = '1' })
Check 'scm 7034: a foreign service is not ours' (-not $ev.ours)
$ev = ConvertFrom-QwtDeathEvent (New-Task 201 '\Qubes-WgcBroker' '3221226505' $T0)
Check 'task 201 helper: ours, the helper''s exe, join-only, result 0xC0000409' ($ev.ours -and $ev.exe -eq 'wgcbroker.exe' -and $ev.anchor -eq 'join-only' -and $ev.code -eq [uint32]0xC0000409L)
$ev = ConvertFrom-QwtDeathEvent (New-Task 201 '\QubesPvNic' '1' $T0)
Check 'task 201 script: ours, its own death, component from the task name' ($ev.ours -and $ev.anchor -eq 'nopid' -and $ev.component -eq 'qubespvnic')
$ev = ConvertFrom-QwtDeathEvent (New-Task 201 '\QubesPvNic' '0' $T0)
Check 'task 201 result 0: not a death' (-not $ev.ours)
$ev = ConvertFrom-QwtDeathEvent (New-Task 201 '\Qubes-NotifBridge' '267014' $T0)
Check 'task 201 result 0x41306: ended by Task Scheduler on request, ignored' (-not $ev.ours -and $ev.ignore)
$ev = ConvertFrom-QwtDeathEvent (New-Task 201 '\QwtDeathReporter' '1' $T0)
Check 'task 201 of the reporter itself: not ours (no self-trigger)' (-not $ev.ours)
$ev = ConvertFrom-QwtDeathEvent (New-Task 201 '\Microsoft\Windows\Defrag\ScheduledDefrag' '1' $T0)
Check 'task 201 of a Windows task: not ours' (-not $ev.ours)
$ev = ConvertFrom-QwtDeathEvent (New-Task 203 '\QubesAutologonGuard' '2147942402' $T0)
Check 'task 203: ours, launch failure, HRESULT rendered with its meaning' ($ev.ours -and $ev.kind -eq 'launchfail' -and (Format-QwtDeathCode $ev.code $ev.codeKind) -eq 'result 0x80070002 (file not found)')
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
Check 'text: names the component and says it died' ($text -like 'Qubes Windows Tools, gui-agent: DIED: gui-agent.exe crashed*')
Check 'text: the exception code with its meaning' ($text -like '*exception 0xC0000409 (fast-fail: stack buffer overrun, __fastfail or an abort)*')
Check 'text: how long it ran' ($text -like '*after running 0:12:34*')
Check 'text: the death count this boot' ($text -like '*death 1 this boot*')
Check 'text: id death-1' ($text -like '*Error id: death-1.*')
Check 'text: the evidence - our deaths log and the WER folder by prefix' ($text -like "*$logDir\qwt-deaths.log*" -and $text -like '*AppCrash_gui-agent.exe_**')
Check 'text: no 32-hex run, no window title, no user path' ($text -notmatch '[0-9A-Fa-f]{32,}' -and $text -notmatch 'Users\\')
Check 'text: under the route''s 600 bytes' ([Text.Encoding]::UTF8.GetByteCount($text) -le 600) "$([Text.Encoding]::UTF8.GetByteCount($text))"
Check 'log: death 1 is logged at ERROR as NEW with the pid' ((Get-DeathLog) -match '\[ERROR\] DEATH #1 NEW Application/1000#\d+: DIED: gui-agent\.exe crashed.*pid 6700')
$st = Invoke-QwtDeathReport (New-Wer 'gui-agent.exe' 0xC0000409L $T0.AddSeconds(3))
CheckStatus 'e2e: the WER record of death 1' $st 'enriched'
Check 'e2e: the WER record adds no notification' ($script:launched.Count -eq 1)
Check 'log: the WER record is logged as AGAIN with the full folder path' ((Get-DeathLog) -match '\[ERROR\] DEATH #1 AGAIN Application/1001#\d+:.*evidence .*\\WER\\ReportArchive\\AppCrash_gui-agent\.exe_')
$st = Invoke-QwtDeathReport (New-Crash 'gui-agent.exe' 7100 0xC0000005L $T0.AddSeconds(30) 25)
CheckStatus 'e2e: death 2 - a SECOND gui-agent crash 30 s later (another pid) is a second death' $st 'send'
Check 'e2e: death 2 notified (not hidden by the once-per-id rule)' ($script:launched.Count -eq 2 -and ([string]$script:launched[1]) -like '*death 2 this boot*' -and ([string]$script:launched[1]) -like '*Error id: death-2.*')
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
Check 'text: the managed death names the exception type' (([string]$script:launched[4]) -like '*unhandled .NET exception (System.NullReferenceException)*')
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
Check 'text: the service death names the service, the exe, the error and the SCM restart' (([string]$script:launched[5]) -like "*service 'Qubes RPC agent' (qrexec-agent.exe) ended with an error; SCM recovery restarts it; error 1460 (timeout); death 6 this boot*")
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
Check 'log: death 9 is STILL logged at ERROR as NEW (past the cap)' ((Get-DeathLog) -match '\[ERROR\] DEATH #9 NEW Application/4003#\d+: DIED: notifhost\.exe exited without being asked to')
Check 'log: and the suppression is logged at ERROR, naming the cap' ((Get-DeathLog) -match '\[ERROR\] DEATH #9 NOT notified: the route''s cap of 8 per boot')
$st = Invoke-QwtDeathReport (New-Task 201 '\Qubes-NotifBridge' '267014' $T0.AddSeconds(401))
CheckStatus 'e2e: a Task-Scheduler-ended helper is ignored' $st 'ignored'
Check 'ledger: nine deaths, the ignored record added none' ((@(Get-Ledger | Where-Object { $_ -like 'D|*' })).Count -eq 9)

# 5. a new boot: the count restarts and the first death is sent again
$script:QwtNotifyBootStamp = $BOOT + 1
$script:QwtNotifyBootCached = $null
$st = Invoke-QwtDeathReport (New-Crash 'gui-agent.exe' 6700 0xC0000409L $T0.AddHours(1))
CheckStatus 'boot: the first death of the next boot is sent' $st 'send'
Check 'boot: it is death 1 again, with id death-1' (([string]$script:launched[8]) -like '*death 1 this boot*' -and ([string]$script:launched[8]) -like '*Error id: death-1.*')
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
