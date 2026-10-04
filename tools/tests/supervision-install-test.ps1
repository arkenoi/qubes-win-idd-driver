<#
.SYNOPSIS
    Offline suite for the installer's supervision registration (docs/ADR-supervision.md 2-4): Set-QubesServiceRecovery
    over the three MSI services, Register-QwtEventSource (our Event Log source), Register-QwtDeathReporter (the ONE
    event-triggered reporter task), and pvnic-selfprime.ps1's NETSETUP-RECOVERY region (the fourth service, armed
    where it is created). Runs under pwsh on Linux: no rig, no guest, no SCM, no Task Scheduler.

.DESCRIPTION
    Each region is extracted from the SHIPPED file by its marker lines (never by brace-hunting) and dot-sourced into a
    scope that provides what the surrounding script would (Write-Log, $script:Result, $script:DefaultBinDir, $fail,
    ...). sc.exe, reg.exe, wevtutil.exe and schtasks.exe are functions here that record every call - the schtasks one
    reads the task XML at call time, since the region deletes the file afterwards - so "what the installer told the
    system" is measured, not read off the code. Exit 0 = every check matched; 1 = at least one FAIL.

.PARAMETER Defect
    Re-introduces one defect in the extracted copy (the shipped files are never modified) at the region's
    '# GUARD:<name>' line: recovthree (the watchdog service is not armed), evsrc (the message file is not written),
    tasklog (TaskScheduler/Operational is not enabled), selftrigger (the reporter subscribes to its own task),
    argsinject (event text on the command line), netsetuprecov (QwtngNetSetup gets no non-crash flag).
    tools/tests/supervision-install-selftest.sh runs the clean leg and every knob and requires each knob to FAIL its target.
#>
[CmdletBinding()]
param([string]$Defect = '')

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))   # tools/tests/x.ps1 -> repo

$script:run = 0; $script:nfail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    $script:run++
    if (-not $ok) { $script:nfail++ }
    $tag = 'FAIL'
    if ($ok) { $tag = 'ok  ' }
    $suffix = ''
    if (-not $ok -and $detail) { $suffix = "  [$detail]" }
    Microsoft.PowerShell.Utility\Write-Host "$tag $name$suffix"
}

# --- extraction by marker ------------------------------------------------------------------------------------------
function Get-Region([string]$file, [string]$name) {
    $lines = @(Get-Content -LiteralPath (Join-Path $repoRoot $file))
    $b = @(0..($lines.Count - 1) | Where-Object { $lines[$_].Trim() -like "# ---- $name-BEGIN*" })
    $e = @(0..($lines.Count - 1) | Where-Object { $lines[$_].Trim() -like "# ---- $name-END*" })
    if ($b.Count -ne 1 -or $e.Count -ne 1 -or $b[0] -ge $e[0]) {
        Microsoft.PowerShell.Utility\Write-Host "FAIL marker extraction $file ${name}: expected exactly one BEGIN before one END, got $($b.Count)/$($e.Count)"
        exit 1
    }
    return ,@($lines[($b[0] + 1)..($e[0] - 1)])
}
$R = [ordered]@{
    'recovery' = Get-Region 'packaging/setup/Install-QwtImproved.ps1' 'SVC-RECOVERY'
    'reporter' = Get-Region 'packaging/setup/Install-QwtImproved.ps1' 'DEATH-REPORTER'
    'netsetup' = Get-Region 'guest/pvnic-selfprime.ps1' 'NETSETUP-RECOVERY'
}
function Set-GuardLine([string[]]$region, [string]$guard, [string]$replacement) {
    $hit = @($region | Where-Object { $_ -match "# GUARD:$guard`$" })
    if ($hit.Count -ne 1) { Microsoft.PowerShell.Utility\Write-Host "FAIL defect: expected exactly 1 '# GUARD:$guard' line, found $($hit.Count)"; exit 1 }
    return ,@($region | ForEach-Object { if ($_ -match "# GUARD:$guard`$") { $replacement } else { $_ } })
}
switch ($Defect) {
    '' { }
    'recovthree'    { $R['recovery'] = Set-GuardLine $R['recovery'] 'recovthree'    "    foreach (`$svc in 'QdbDaemon', 'QrexecAgent') {   # DEFECT: the watchdog service is not armed" }
    'evsrc'         { $R['reporter'] = Set-GuardLine $R['reporter'] 'evsrc'         '        $global:LASTEXITCODE = 0   # DEFECT: EventMessageFile never written - every event renders as "description not found"' }
    'tasklog'       { $R['reporter'] = Set-GuardLine $R['reporter'] 'tasklog'       '        $global:LASTEXITCODE = 0   # DEFECT: the TaskScheduler/Operational channel stays disabled - 201/203 are never written' }
    'selftrigger'   { $R['reporter'] = Set-GuardLine $R['reporter'] 'selftrigger'   "                      '\QubesWindowsUpdateDownload', '\QwtImprovedSetup', '\QwtDeathReporter')   # DEFECT: the reporter subscribes to its own failures" }
    'argsinject'    { $R['reporter'] = Set-GuardLine $R['reporter'] 'argsinject'    '        $arguments = ''-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'' + $reporter + ''" -Channel "$(Channel)" -RecordId $(RecordId) -Faulting "$(Faulting)"''   # DEFECT: event text on the command line' }
    'netsetuprecov' { $R['netsetup'] = Set-GuardLine $R['netsetup'] 'netsetuprecov' '                $global:LASTEXITCODE = 0   # DEFECT: no failureflag - an error exit never triggers the actions' }
    default { Microsoft.PowerShell.Utility\Write-Host "FAIL unknown -Defect '$Defect'"; exit 1 }
}

# --- the world the regions talk to ---------------------------------------------------------------------------------
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('superv-inst-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$payload = Join-Path $tmp 'payload'; New-Item -ItemType Directory -Path $payload -Force | Out-Null
$bin = Join-Path $tmp 'bin'
$env:TEMP = $tmp
$script:W = @{ sc = New-Object System.Collections.ArrayList; reg = New-Object System.Collections.ArrayList
               wevtutil = New-Object System.Collections.ArrayList; schtasks = New-Object System.Collections.ArrayList
               taskXml = @{}; scFailFor = @{}; regRc = 0; wevtRc = 0; schtasksCreateRc = 0; schtasksQueryRc = 0 }
$script:logged = New-Object System.Collections.ArrayList
function Write-Log { param([string]$Message, [string]$Level = 'INFO') [void]$script:logged.Add("[$Level] $Message") }
function Write-Host { }
function sc.exe { param([Parameter(ValueFromRemainingArguments = $true)][string[]]$a)
    $call = ($a -join ' '); [void]$script:W.sc.Add($call)
    $svc = $a[1]
    if ($script:W.scFailFor.ContainsKey($svc)) { $global:LASTEXITCODE = [int]$script:W.scFailFor[$svc] } else { $global:LASTEXITCODE = 0 }
    return ''
}
function reg.exe { param([Parameter(ValueFromRemainingArguments = $true)][string[]]$a)
    [void]$script:W.reg.Add(($a -join ' ')); $global:LASTEXITCODE = $script:W.regRc; return ''
}
function wevtutil.exe { param([Parameter(ValueFromRemainingArguments = $true)][string[]]$a)
    [void]$script:W.wevtutil.Add(($a -join ' ')); $global:LASTEXITCODE = $script:W.wevtRc; return ''
}
function schtasks.exe { param([Parameter(ValueFromRemainingArguments = $true)][string[]]$a)
    $call = ($a -join ' '); [void]$script:W.schtasks.Add($call)
    if ($a[0] -eq '/create') {
        $i = [Array]::IndexOf($a, '/xml'); $tn = $a[[Array]::IndexOf($a, '/tn') + 1]
        if ($i -ge 0 -and (Test-Path -LiteralPath $a[$i + 1])) { $script:W.taskXml[$tn] = [IO.File]::ReadAllText($a[$i + 1], [Text.Encoding]::Unicode) }
        $global:LASTEXITCODE = $script:W.schtasksCreateRc
    } elseif ($a[0] -eq '/query') { $global:LASTEXITCODE = $script:W.schtasksQueryRc }
    else { $global:LASTEXITCODE = 0 }
    return ''
}
function Reset-World {
    $script:W.sc.Clear(); $script:W.reg.Clear(); $script:W.wevtutil.Clear(); $script:W.schtasks.Clear(); $script:W.taskXml.Clear()
    $script:W.scFailFor.Clear(); $script:W.regRc = 0; $script:W.wevtRc = 0; $script:W.schtasksCreateRc = 0; $script:W.schtasksQueryRc = 0
    $script:logged.Clear()
    $script:Result = [pscustomobject]@{ detail = [ordered]@{} }
    if (Test-Path -LiteralPath $bin) { Remove-Item -LiteralPath $bin -Recurse -Force }
    foreach ($f in 'qwt-report-death.ps1', 'qwt-notify-error.ps1') { [IO.File]::WriteAllText((Join-Path $payload $f), "# payload copy of $f") }
}
$script:DefaultBinDir = $bin
$script:QwtEventMessageDll = Join-Path $tmp 'EventLogMessages.dll'
[IO.File]::WriteAllText($script:QwtEventMessageDll, 'fake message dll')

# =====================================================================================================================
# 1. the installer's recovery arming: three services, each `sc failure` then `sc failureflag`
Reset-World
. ([scriptblock]::Create(($R['recovery'] -join "`n")))
Set-QubesServiceRecovery
$want = @('QdbDaemon', 'QrexecAgent', 'QubesGuiWatchdog')
Check 'recovery: three services armed, in order (detail.service_recovery)' (@($script:Result.detail.service_recovery.Keys) -join ',' -eq ($want -join ','))
foreach ($s in $want) {
    Check "recovery: $s = armed" ($script:Result.detail.service_recovery[$s] -eq 'armed')
    Check "recovery: $s - sc failure with reset 86400 and three restarts" (@($script:W.sc | Where-Object { $_ -eq "failure $s reset= 86400 actions= restart/5000/restart/15000/restart/60000" }).Count -eq 1)
    Check "recovery: $s - sc failureflag 1 (non-crash failures count)" (@($script:W.sc | Where-Object { $_ -eq "failureflag $s 1" }).Count -eq 1)
}
Check 'recovery: six sc calls, nothing else' ($script:W.sc.Count -eq 6)
Reset-World
$script:W.scFailFor['QubesGuiWatchdog'] = 1060
Set-QubesServiceRecovery
Check 'recovery: an sc failure on one service is recorded as such, the others stay armed' ($script:Result.detail.service_recovery['QubesGuiWatchdog'] -eq 'failed: sc failure=1060 failureflag=1060' -and $script:Result.detail.service_recovery['QdbDaemon'] -eq 'armed' -and $script:Result.detail.service_recovery['QrexecAgent'] -eq 'armed')
Check 'recovery: and said at WARN' (@($script:logged | Where-Object { $_ -like '[[]WARN[]] could not arm service recovery for QubesGuiWatchdog*' }).Count -eq 1)

# 2. our event source
Reset-World
. ([scriptblock]::Create(($R['reporter'] -join "`n")))
Register-QwtEventSource
$key = 'HKLM\SYSTEM\CurrentControlSet\Services\EventLog\Application\Qubes Windows Tools'
Check 'event source: registered' ($script:Result.detail.event_source -eq 'registered')
Check 'event source: EventMessageFile is REG_EXPAND_SZ to the message file, under the Application log, forced' (@($script:W.reg | Where-Object { $_ -eq "add $key /v EventMessageFile /t REG_EXPAND_SZ /d $($script:QwtEventMessageDll) /f" }).Count -eq 1) ($script:W.reg -join ' || ')
Check 'event source: TypesSupported = 7 (error, warning, information)' (@($script:W.reg | Where-Object { $_ -eq "add $key /v TypesSupported /t REG_DWORD /d 7 /f" }).Count -eq 1)
Check 'event source: two reg writes, nothing else' ($script:W.reg.Count -eq 2)
Check 'event source: the shipped default message file is the .NET Framework 64-bit one by %SystemRoot%' ((Get-Content -LiteralPath (Join-Path $repoRoot 'packaging/setup/Install-QwtImproved.ps1') -Raw) -match "QwtEventMessageDll = '%SystemRoot%\\Microsoft\.NET\\Framework64\\v4\.0\.30319\\EventLogMessages\.dll'")
Reset-World
$script:W.regRc = 1
Register-QwtEventSource
Check 'event source: a reg failure is recorded, at WARN, non-fatal' ($script:Result.detail.event_source -eq 'failed: reg add rc=1/1' -and @($script:logged | Where-Object { $_ -like '[[]WARN[]] could not register the event source*' }).Count -eq 1)
Reset-World
$saved = $script:QwtEventMessageDll
$script:QwtEventMessageDll = Join-Path $tmp 'absent.dll'
Register-QwtEventSource
Check 'event source: an absent message file is recorded and nothing is written' ($script:Result.detail.event_source -like 'failed: message file absent*' -and $script:W.reg.Count -eq 0)
$script:QwtEventMessageDll = $saved

# 3. the ONE reporter task
Reset-World
Register-QwtDeathReporter -Root $payload
Check 'reporter: registered' ($script:Result.detail.death_reporter -eq 'registered') "$($script:Result.detail.death_reporter)"
Check 'reporter: the reporter and the route helper are copied into bin' ((Test-Path -LiteralPath (Join-Path $bin 'qwt-report-death.ps1')) -and (Test-Path -LiteralPath (Join-Path $bin 'qwt-notify-error.ps1')))
Check 'reporter: TaskScheduler/Operational is enabled first' (@($script:W.wevtutil | Where-Object { $_ -eq 'set-log Microsoft-Windows-TaskScheduler/Operational /enabled:true' }).Count -eq 1)
Check 'reporter: schtasks /create /tn QwtDeathReporter /xml ... /f, then /query' (@($script:W.schtasks | Where-Object { $_ -like '/create /tn QwtDeathReporter /xml * /f' }).Count -eq 1 -and @($script:W.schtasks | Where-Object { $_ -eq '/query /tn QwtDeathReporter' }).Count -eq 1)
Check 'reporter: the task XML file is removed afterwards' (-not (Test-Path -LiteralPath (Join-Path $tmp 'qwt-death-reporter.xml')))
$xmlText = $script:W.taskXml['QwtDeathReporter']
# SUPERVISION_DUMP_TASKXML=<path>: write the captured task XML out, so it can be put through the REAL schtasks on a guest (the fake
# here cannot know Task Scheduler's own limits - 2026-10-04 its XPath term limit failed every install of the rz39 gate).
if ($env:SUPERVISION_DUMP_TASKXML -and $xmlText) { [IO.File]::WriteAllText($env:SUPERVISION_DUMP_TASKXML, $xmlText, [Text.Encoding]::Unicode) }
Check 'reporter: the task XML was written (UTF-16) and captured' ([bool]$xmlText)
$x = $null
try { $x = [xml]$xmlText } catch { }
Check 'reporter: the task XML parses' ($null -ne $x)
if ($x) {
    $ns = @{ t = 'http://schemas.microsoft.com/windows/2004/02/mit/task' }
    $sel = { param($path) $n = Select-Xml -Xml $x -XPath $path -Namespace $ns; if ($n) { return $n.Node } ; return $null }
    Check 'task: version 1.3 (ValueQueries need Task Scheduler 2.0)' ($x.Task.version -eq '1.3')
    Check 'task: principal SYSTEM, highest' ($x.Task.Principals.Principal.UserId -eq 'S-1-5-18' -and $x.Task.Principals.Principal.RunLevel -eq 'HighestAvailable')
    Check 'task: Queue, not IgnoreNew (a second death during a report must not be dropped)' ($x.Task.Settings.MultipleInstancesPolicy -eq 'Queue')
    Check 'task: hidden, never blocked by battery, bounded' ($x.Task.Settings.Hidden -eq 'true' -and $x.Task.Settings.DisallowStartIfOnBatteries -eq 'false' -and $x.Task.Settings.ExecutionTimeLimit -eq 'PT5M')
    $trig = $x.Task.Triggers.EventTrigger
    Check 'task: one enabled EventTrigger' ($null -ne $trig -and $trig.Enabled -eq 'true')
    $vq = @($trig.ValueQueries.Value)
    Check 'task: ValueQueries hand over the channel and the record id, nothing else' ($vq.Count -eq 2 -and @($vq | Where-Object { $_.name -eq 'Channel' -and $_.'#text' -eq 'Event/System/Channel' }).Count -eq 1 -and @($vq | Where-Object { $_.name -eq 'RecordId' -and $_.'#text' -eq 'Event/System/EventRecordID' }).Count -eq 1)
    $exec = $x.Task.Actions.Exec
    Check 'task: the action is powershell.exe on the reporter in bin' ($exec.Command -eq 'powershell.exe' -and $exec.Arguments -like "*-File `"$bin*qwt-report-death.ps1`"*")
    Check 'task: the arguments carry $(Channel) and $(RecordId) and no other event field' ($exec.Arguments -like '*-Channel "$(Channel)" -RecordId $(RecordId)*' -and ([regex]::Matches($exec.Arguments, '\$\(')).Count -eq 2) $exec.Arguments
    Check 'task: non-interactive, no profile, bypass' ($exec.Arguments -like '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File *')
    $subText = $trig.Subscription
    $sub = $null
    try { $sub = [xml]$subText } catch { }
    Check 'subscription: the escaped QueryList decodes to XML' ($null -ne $sub)
    if ($sub) {
        $queries = @($sub.QueryList.Query)
        Check 'subscription: three queries - Application, System, TaskScheduler/Operational' ($queries.Count -eq 3 -and (@($queries | ForEach-Object { $_.Path }) -join ',') -eq 'Application,System,Microsoft-Windows-TaskScheduler/Operational')
        $selects = @($queries | ForEach-Object { @($_.Select) } | ForEach-Object { $_.'#text' })
        # nine: the executables are two lists (Task Scheduler rejects one list of 28 - measured 2026-10-04), so 1000 and 1001 have two each
        Check 'subscription: nine selects (1000 and 1001 one per executable list)' ($selects.Count -eq 9) "$($selects.Count)"
        Check 'subscription: 1000 and 1001 are filtered to our executables, each by Data=' (@($selects | Where-Object { $_ -match "EventID=1000\] and EventData\[Data='gui-agent\.exe' or " }).Count -eq 1 -and @($selects | Where-Object { $_ -match "EventID=1001\] and EventData\[Data='gui-agent\.exe' or " }).Count -eq 1)
        Check 'subscription: 1026 is taken unfiltered (the script filters it)' (@($selects | Where-Object { $_ -eq "*[System[Provider[@Name='.NET Runtime'] and EventID=1026]]" }).Count -eq 1)
        Check 'subscription: every event of our source' (@($selects | Where-Object { $_ -eq "*[System[Provider[@Name='Qubes Windows Tools']]]" }).Count -eq 1)
        Check 'subscription: the SCM ids 7031/7034/7023/7024 for our four display names' (@($selects | Where-Object { $_ -match "\(EventID=7031 or EventID=7034 or EventID=7023 or EventID=7024\)\] and EventData\[Data\[@Name='param1'\]='QubesDB daemon' or .*'Qubes RPC agent' or .*'Qubes GUI agent watchdog' or .*'Qubes PV NIC address applier'\]\]$" }).Count -eq 1)
        Check 'subscription: 201 only with a non-zero result, for our tasks' (@($selects | Where-Object { $_ -match "EventID=201\] and EventData\[Data\[@Name='ResultCode'\]!=0 and \(Data\[@Name='TaskName'\]='\\Qubes-WgcBroker' or " }).Count -eq 1)
        Check 'subscription: 203 for our tasks' (@($selects | Where-Object { $_ -match "EventID=203\] and EventData\[Data\[@Name='TaskName'\]='\\Qubes-WgcBroker' or " }).Count -eq 1)
        Check 'subscription: the reporter never subscribes to its own task' ($subText -notlike '*QwtDeathReporter*')
        Check 'subscription: the generic cat.exe shim is not subscribed' ($subText -notlike "*Data='cat.exe'*")
    }
}
Reset-World
Remove-Item -LiteralPath (Join-Path $payload 'qwt-report-death.ps1') -Force
Register-QwtDeathReporter -Root $payload
Check 'reporter: a payload without the reporter is a recorded failure and registers no task' ($script:Result.detail.death_reporter -eq 'failed: qwt-report-death.ps1 is not in the payload' -and $script:W.schtasks.Count -eq 0)
Reset-World
$script:W.wevtRc = 1
Register-QwtDeathReporter -Root $payload
Check 'reporter: a channel that cannot be enabled is a recorded failure and registers no task' ($script:Result.detail.death_reporter -like 'failed: wevtutil could not enable Microsoft-Windows-TaskScheduler/Operational*' -and $script:W.schtasks.Count -eq 0)
Reset-World
$script:W.schtasksCreateRc = 1
Register-QwtDeathReporter -Root $payload
Check 'reporter: a schtasks /create failure is recorded with its rc, at WARN' ($script:Result.detail.death_reporter -like "failed: schtasks /create rc '1'*" -and @($script:logged | Where-Object { $_ -like '[[]WARN[]] death reporter NOT registered*' }).Count -eq 1)
Reset-World
$script:W.schtasksQueryRc = 1
Register-QwtDeathReporter -Root $payload
Check 'reporter: a create that cannot be read back is a failure' ($script:Result.detail.death_reporter -like "failed: schtasks /create reported success but 'QwtDeathReporter' does not exist*")

# 4. pvnic-selfprime: the fourth service, armed where it is created
Reset-World
$fail = @{}
. ([scriptblock]::Create(($R['netsetup'] -join "`n"))) *> $null
Check 'netsetup: sc failure QwtngNetSetup with the same reset and restarts' (@($script:W.sc | Where-Object { $_ -eq 'failure QwtngNetSetup reset= 86400 actions= restart/5000/restart/15000/restart/60000' }).Count -eq 1)
Check 'netsetup: sc failureflag QwtngNetSetup 1' (@($script:W.sc | Where-Object { $_ -eq 'failureflag QwtngNetSetup 1' }).Count -eq 1)
Check 'netsetup: no failure recorded when both succeed' ($fail.Count -eq 0)
Reset-World
$fail = @{}
$script:W.scFailFor['QwtngNetSetup'] = 5
. ([scriptblock]::Create(($R['netsetup'] -join "`n"))) *> $null
Check 'netsetup: a failed arming is a failed priming (fail.netsetup_recovery)' ($fail['netsetup_recovery'] -eq 'sc failure=5 failureflag=5')

Microsoft.PowerShell.Utility\Write-Host "$($script:run) checks, $($script:nfail) failed"
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
if ($script:nfail -gt 0) { exit 1 }
exit 0
