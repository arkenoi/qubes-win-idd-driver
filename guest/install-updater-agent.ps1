<#
.SYNOPSIS
  Deploy the QWT-NG Windows Update agent and register its scheduled scan (north-star: report
  update availability to dom0, non-blocking).

.DESCRIPTION
  Idempotent. Run elevated by the QWT installer (writes to Program Files) or standalone for test
  with -BinDir to a writable dir. Three steps:
    1. compile the relay from qubes-updates-relay.cs with the in-box csc (no build infra, matching
       the winenum.cs convention) -> <BinDir>\qubes-updates-relay.exe
    2. place qubes-windows-update.ps1 -> <BinDir>
    3. register scheduled task QubesWindowsUpdateScan (SYSTEM; at boot + every -Interval) that runs
       `-Action scan` only. Scan REPORTS availability; download/install stay on-demand so the task
       never blocks or reboots the guest on its own.

.PARAMETER SetupRoot  Dir holding qubes-updates-relay.cs and qubes-windows-update.ps1 (default: this script's dir).
.PARAMETER BinDir     Install dir for the exe + agent script.
.PARAMETER Interval   Scan cadence as an ISO-8601 duration (default PT6H).
#>
[CmdletBinding()]
param(
  [string]$SetupRoot = $PSScriptRoot,
  [string]$BinDir    = 'C:\Program Files\Qubes Tools\bin',
  [string]$Interval  = 'PT6H'
)
$ErrorActionPreference = 'Stop'
function Log($m){ Write-Output ((Get-Date -Format 'HH:mm:ss') + ' ' + $m) }

# INITIALISED HERE, NOT AT THE MUTEX BLOCK, because `trap` is hoisted to the whole script block:
# a throw from the SetupRoot recovery or the csc/source existence checks below fires the trap long
# before the mutex is created. Under the installer's inherited Set-StrictMode 1.0 the trap's read
# of an unset $haveUpdMutex raises "the variable cannot be retrieved because it has not been set",
# REPLACING the real message - so 'relay source not found at X' was reported as a StrictMode error
# and the actual cause never reached the log.
$updMutex     = $null
$haveUpdMutex = $false
# AND THE UNGATE, FOR THE SAME REASON - learned the hard way twice in one file. The update-task
# ungate further down is called from a trap, and a trap is HOISTED to the whole script block, so it
# can fire from a throw hundreds of lines ABOVE the line that assigns what it calls. When that
# happened, StrictMode turned the trap's read of the unset variable into
#   "The variable '$script:UpdUngate' cannot be retrieved because it has not been set."
# and THAT replaced the real error - measured 2026-10-09 in the WIN10-clean acceptance cell, which
# failed with updater_agent_failed and no indication of what had actually thrown. A no-op default
# here means the trap is always callable; the real ungate replaces it once the tasks are gated.
#
# THIS COMMENT DELIBERATELY DOES NOT REPRODUCE THE TRAP LINE. It used to quote it verbatim, and a
# scripted edit that replaced the FIRST occurrence of that text hit the copy in this comment rather
# than the real statement - injecting executable text into the middle of a comment line, where the
# trailing words became a bare comma that PowerShell then tried to run ("The term ',' is not
# recognized..."). It parsed clean and failed only on a guest. Describe the code here; do not echo it.
$script:updGatedList = @()
$script:UpdUngate    = { }

# $PSScriptRoot arrives EMPTY in some invocation contexts (measured 2026-08-19 via the
# qrexec->cmd->powershell -File chain on win11-fresh: the param default bound '', and the
# first Join-Path then died on 'Cannot bind argument to parameter Path' - which, under
# ErrorActionPreference=Stop, killed the installer BEFORE ITS FIRST LOG LINE, i.e. silently
# for any harness grepping for progress). Recover the script directory the long way.
if (-not $SetupRoot) {
    $SetupRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    if (-not $SetupRoot) { throw 'cannot determine SetupRoot; pass -SetupRoot explicitly' }
    Log "SetupRoot recovered from invocation path: $SetupRoot"
}

New-Item -ItemType Directory -Force $BinDir | Out-Null

# 1. compile the relay with the in-box csc
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$src = Join-Path $SetupRoot 'qubes-updates-relay.cs'
$exe = Join-Path $BinDir 'qubes-updates-relay.exe'
if (-not (Test-Path $csc)) { throw "in-box csc not found at $csc" }
if (-not (Test-Path $src)) { throw "relay source not found at $src" }
# ---- RELAYSOURCEVOUCH-BEGIN  (driven by tools/tests/relay-vouch-test.ps1)
# THE SOURCE WE COMPILE MUST CARRY THE CAPABILITY, AND UNTIL NOW NOTHING CHECKED IT.
# MEASURED on win11de-tup, 2026-10-22, three template-update rounds: this deploy logged
# "updater agent deployed" and every relay launched afterwards bound the PASS'S OWN PID as its
# listen port (600, 2880, 4184, 5548, 6688, 8228) with NO `parent=` field - the field the shipped
# source writes unconditionally on its listen line. So WinHTTP pointed at 8082, nothing served it,
# every pass ended SILENT, and dom0 was never told. The exe placed by this deploy was therefore not
# built from the shipped source: $SetupRoot on a guest is a COPY (C:\qwt-improved-setup), and a
# stale copy left by an earlier install compiles an old binary while every step here reports
# success. The move below already throws when the exe is locked, so the failure was never the move.
# Three markers, each a positive string in the shipped .cs: the flag is PARSED, a bare integer is the
# port ONLY in the first positional slot, and the listen line carries parent=. A source missing any
# of them is a stale payload and this deploy must not compile it.
# EACH MARKER IS CODE, NEVER A HUMAN-FACING MESSAGE. A vouch keyed on the wording of an error string
# refuses a perfectly good deploy the day someone rewords it, and that failure would land on a
# guest. These three are the flag name the launcher passes, the positional-port rule itself, and the
# log field - all contract. A reword or reformat still breaks them, so it is caught where it is
# cheap: tools/tests/relay-vouch-test.ps1 asserts the SHIPPED source passes this vouch, in CI,
# before any guest sees it.
$vouch = @{
    '--parent-pid'          = 'the relay must PARSE --parent-pid, or the launcher''s flag value becomes its listen port'
    'i == 1 && int.TryParse' = 'a bare integer may be the port ONLY in the first positional slot; without that rule an unknown flag''s VALUE silently becomes the listen port (measured 2026-10-19: --parent-pid 3312 bound port 3312)'
    'parent='               = 'the listen line must declare parent=, which is the only receipt that the shipped binary is running'
}
$srcText = Get-Content -LiteralPath $src -Raw
foreach ($k in $vouch.Keys) {
    if ($srcText -notlike "*$k*") {
        throw ("QWTRELAYSTALESRC: $src does not carry '$k' - $($vouch[$k]). " +
               "That is a STALE staged payload, not this release's relay source; compiling it would " +
               "reinstate the pid-as-port relay and every update pass would go silent. Re-stage the " +
               "setup tree from the release package and run install.cmd /updatesonly again.")
    }
}
Log "relay source vouched at $src (parses --parent-pid, refuses unknown flags, declares parent=)"
# ---- RELAYSOURCEVOUCH-END
# Serialise with the updater itself. On an UPGRADE the previous install's QubesWindowsUpdateScan
# (boot+2 min) overlaps the resumed stage 2 (boot+1 min): the scan sets the machine-wide proxy and
# starts the relay, then this deploy's relay replacement (until 2026-10-03 a kill by name) and task
# rewrite land under it - the pass dies 0x80072EFD through a dead proxy and dom0 gets no availability answer until
# the next 6-hourly scan. qubes-windows-update.ps1 serialises its passes on this mutex; take it here
# too, so a running pass finishes first and one starting later yields (its scan uses WaitOne(0)).
#
# HOW LONG TO WAIT is the holder's property, not a constant of ours. Until 2026-09-16 this waited
# 15 min - a figure copied from the updater's "real work waits 15 min", which is how long a pass
# waits to START, not how long it may RUN - then declared the holder hung and PROCEEDED: relay
# stopped, tasks rewritten, under a pass that QubesWindowsUpdateRun/Download allow to run for PT2H
# (findings/issues.md installer audit, item 16). A 40-minute cumulative-update install was the
# ordinary case being misread as the anomaly. Now:
#   - the bound is the LONGEST ExecutionTimeLimit among the tasks that can hold the mutex: read from
#     each task AS REGISTERED (on an upgrade, the previous install's - the very pass being waited
#     on) and from the limits this script is about to register, whichever is longer, plus a grace
#     for the scheduler's own stop-then-terminate at that limit;
#   - the wait is the kernel wait on the mutex, not a poll: it returns the moment the holder
#     releases, and a holder the scheduler kills at its limit ABANDONS the mutex, which wakes the
#     waiter with AbandonedMutexException (= ours now);
#   - a mutex still held past that bound is a FAILURE, thrown as QWTUPDMUTEXHELD: nothing below
#     runs, the installer's catch records the error, a direct run exits non-zero. There is no
#     "proceed anyway" branch to take.
# ONE source for the limits this script registers (steps 3, 4, 7); the bound reads them too.
# QubesWindowsUpdateScan. PT2H, NOT PT20M, and the twenty minutes were measured to be too few:
# a FIRST scan after Windows servicing ran >25 min and >66 min on the reporter's template. Task
# Scheduler then ends the instance at the limit (event 111), the 201 records a non-zero result, the
# death reporter correctly turns that into a dom0 notification, and the user is told "The Windows
# Update scan task failed" about a scan that was working and simply had not finished. Killing it
# sooner is not a fix and neither is hiding the report: the scan gets the time it actually needs,
# which is the same budget the install and download passes already have.
$ScanTaskLimit = 'PT2H'
$PassTaskLimit = 'PT2H'    # QubesWindowsUpdateRun and QubesWindowsUpdateDownload
# At its limit a task is first asked to stop and only then terminated (AllowHardTerminate=true) -
# minutes, not instantaneous. The grace covers that; it is not a second deadline.

# ---- DEPLOY-HELPERS-BEGIN   (tools/tests/wu-deploy-loud-test.ps1 dot-sources this region, then replaces Get-UpdTaskState with a fake)
# The registered tasks AS THEY ARE on this guest - on an upgrade, the previous install's. State 'Running' is the scheduler's own
# word for an instance in flight (an enum, never the localized text schtasks prints); the limit is the one THAT task runs under;
# LastRunTime is when the current instance started. 'unreadable' is not 'Ready': a holder whose task state cannot be read is
# not identified, and the caller refuses rather than guesses.
function Get-UpdTaskState([string]$Name) {
    $r = @{ state = 'unreadable'; limit = ''; lastRun = $null }
    try {
        $t = Get-ScheduledTask -TaskName $Name -ErrorAction Stop
        $r.state = "$($t.State)"
        try { $r.limit = "$($t.Settings.ExecutionTimeLimit)" } catch { }
        try {
            $i = Get-ScheduledTaskInfo -TaskName $Name -ErrorAction Stop
            if ($i -and ($i.LastRunTime -is [datetime]) -and $i.LastRunTime.Year -gt 2000) { $r.lastRun = $i.LastRunTime }
        } catch { }
    } catch {
        if ("$($_.CategoryInfo.Category)" -eq 'ObjectNotFound' -or "$($_.Exception.Message)" -match 'No MSFT_ScheduledTask') { $r.state = 'absent' }
    }
    return $r
}
# ISO-8601 duration -> whole seconds. Empty, unparseable or PT0S (Task Scheduler's "no limit") -> the default, so a wait is always
# bounded by SOMETHING we can name; the default may itself be an ISO duration.
function Get-UpdSeconds([string]$Iso, $Default) {
    $d = $Default
    if ($d -is [string]) { try { $d = [int][Xml.XmlConvert]::ToTimeSpan($d).TotalSeconds } catch { $d = 0 } }
    if (-not $Iso) { return [int]$d }
    $s = 0
    try { $s = [int][Xml.XmlConvert]::ToTimeSpan($Iso).TotalSeconds } catch { return [int]$d }
    if ($s -le 0) { return [int]$d }
    return $s
}
# TRUE when the status record was written by the scan instance that is RUNNING now: its ts (local time, second resolution, written
# by every updater's Save within a second or two of taking the mutex) is not older than that instance's start, the task's
# LastRunTime (same clock). A 'scan' record left by an EARLIER scan says nothing about who holds the mutex now - e.g. a pass
# started by dom0 or by hand that has not written its own record yet, while a scan instance waits for the mutex.
function Test-UpdRecordFresh($Record, $Since) {
    if (-not $Record -or -not $Since -or -not ($Record.PSObject.Properties.Name -contains 'ts')) { return $false }
    $t = [datetime]::MinValue
    if ($Record.ts -is [datetime]) { $t = $Record.ts }   # pwsh 7 (the offline suites) reads the ISO string back as a DateTime
    elseif (-not [datetime]::TryParseExact("$($Record.ts)", 'yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture,
                                            [Globalization.DateTimeStyles]::None, [ref]$t)) { return $false }
    return ($t -ge $Since.AddSeconds(-1))   # both sides at second resolution
}
# The wait for a running scan (DEPLOY-MUTEX below) is ONE kernel wait on the mutex, taken in slices of this length only so that a
# line is logged while it lasts: the 2026-09-23 reason for removing every wait here was a silent one, graded STALLED at 300 s by
# the harness and indistinguishable from a wedged guest by a human. A slice ends the moment the holder releases.
$UpdWaitSliceMs   = 30000
# Added to the scan task's own limit: at that limit the scheduler asks the task to stop and only then terminates it
# (AllowHardTerminate) - minutes, not instantaneous (the note above). Our margin for that, not a second deadline.
$UpdScanWaitGrace = 'PT3M'
# ---- DEPLOY-HELPERS-END

# NO UNDEFINED PATH AROUND THIS MUTEX (2026-09-23; the wait for a running SCAN added 2026-10-04). Every path is one of these:
#  1. A RUNNING SCAN IS WAITED FOR, on the mutex itself, bounded by the scan task's own ExecutionTimeLimit (DEPLOY-MUTEX below).
#     The field report of 2026-10-04 (a German 25H2 template upgraded to 4.3.33 right after it booted): the previous updater's
#     boot scan (QubesWindowsUpdateScan, boot+2 min, limit PT20M) held the mutex while this deploy ran; the deploy refused, the
#     installer recorded that as one WARN line nobody reads, the install said INSTALL COMPLETE, and the guest kept its OLD
#     updater - dom0 showed no updates while Windows Update listed one. A scan installs nothing and ends on its own; what it
#     needs is the time its task already has. So: a WaitOne with a deadline - a wait on the observed release, never a poll, never
#     a fixed sleep - that returns the moment the scan lets go, logged when it starts, while it lasts and when it ends.
#  2. A RUNNING INSTALL OR DOWNLOAD PASS IS NOT WAITED FOR: it may run PT2H and ends in a restart. Refused loudly (QWTUPDMUTEXHELD),
#     with the remedy; the installer records an ERROR, the RESULT is red (updater_agent_failed), dom0 is notified.
#  3. THE BOUND EXPIRING IS A FAILURE (QWTUPDSCANWAITEXPIRED): the scheduler ends a scan at its limit, so a holder still there past
#     it is not a scan doing its work. Refused loudly, same reporting. There is no "proceed anyway" branch.
#  4. ABANDONED: the holder died with the mutex. Not the detector it looks like (MEASURED 3/3 on win10-acc: a killed owner raises
#     nothing in a waiter that opens the mutex afterwards; it does wake one that already holds a handle, which the wait in 1 is).
#     After a SCAN the deploy proceeds and says so - the updater's own rule for a cut-off scan (D3): a scan installs nothing, so
#     nothing is unknown. After anything else it refuses: what that pass was doing is unknown.
#  5. THE KILLED PASS is detected from the status file the PASS maintains - a non-terminal phase whose owner process is gone -
#     checked before the mutex is touched (DEPLOY-PREVPASS). A pass that ends intending a reboot sets phase='done' first, so a
#     planned servicing reboot is already terminal and needs nothing extra.
# ---- DEPLOY-PREVPASS-BEGIN   (tools/tests/wu-deploy-prevpass-test.ps1 runs this region)
$UpdaterStatusFile = 'C:\ProgramData\Qubes\update-status.json'
$UpdTerminalPhases = @('done','error','skipped-unknown','skipped-standalone','skipped-appvm')
$updPrev = $null
try { if (Test-Path -LiteralPath $UpdaterStatusFile) { $updPrev = Get-Content -LiteralPath $UpdaterStatusFile -Raw | ConvertFrom-Json } } catch { $updPrev = $null }
if ($updPrev -and $updPrev.phase -and ($UpdTerminalPhases -notcontains $updPrev.phase)) {
    $pPid = 0; $pStart = ''
    if ($updPrev.PSObject.Properties.Name -contains 'owner_pid')       { $pPid   = [int]$updPrev.owner_pid }
    # The guest's Windows PowerShell 5.1 reads the ISO owner_pid_start back as a string; pwsh 7 (the offline suites) as a DateTime.
    if ($updPrev.PSObject.Properties.Name -contains 'owner_pid_start') { if ($updPrev.owner_pid_start -is [datetime]) { $pStart = $updPrev.owner_pid_start.ToString('s') } else { $pStart = "$($updPrev.owner_pid_start)" } }
    $alive = $false
    if ($pPid -gt 0) {
        $po = Get-Process -Id $pPid -ErrorAction SilentlyContinue
        if ($po) { $alive = $true; if ($pStart) { try { if ($po.StartTime.ToString('s') -ne $pStart) { $alive = $false } } catch { $alive = $false } } }
    }
    if (-not $alive) {
        # THE UPDATER'S OWN RULE FOR A CUT-OFF PASS (its WU-PREVPASS-GATE, the owner's D3 decision 2026-10-02), applied here too. Until
        # 2026-10-04 this refused EVERY cut-off pass, and the rz39 gate's upgrade from 4.3.33 failed on it: the boot scan had been cut off
        # at phase 'init' (in an earlier boot), and the deploy refused with QWTUPDSTATEUNKNOWN - updater_agent=error on a correct upgrade.
        $prevAction = "$($updPrev.action)"
        $prevTs = "$($updPrev.ts)"; if ($updPrev.ts -is [datetime]) { $prevTs = $updPrev.ts.ToString('s') }
        $bootT = $null
        try { $bootT = (Get-CimInstance Win32_OperatingSystem -EA Stop).LastBootUpTime } catch { $bootT = $null }
        if (-not $bootT) { try { $bootT = (Get-Date).AddMilliseconds(-[double]([Environment]::TickCount -band [int]::MaxValue)) } catch { } }
        $bootS = ''; if ($bootT) { $bootS = $bootT.ToString('s') }
        $refusedBoot = ''
        if ($updPrev.PSObject.Properties.Name -contains 'refused_boot') {
            if ($updPrev.refused_boot -is [datetime]) { $refusedBoot = $updPrev.refused_boot.ToString('s') } else { $refusedBoot = "$($updPrev.refused_boot)" }
        }
        $lastT = [datetime]::MinValue
        $lastKnown = [datetime]::TryParseExact($prevTs, 'yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture,
                                               [Globalization.DateTimeStyles]::None, [ref]$lastT)
        $what = "the last update pass ('$prevAction', last written $prevTs) stopped at phase '$($updPrev.phase)' and its process ($pPid) is gone"
        # A 4.3.32 updater never recorded its owner (its status object was defined after the ownership write; owner_pid is 0 in every
        # record it wrote), so "gone" is not known for one of its records - said so, and DEPLOY-MUTEX below asks the scheduler instead.
        if ($pPid -le 0) { $what = "the last update pass ('$prevAction', last written $prevTs) stopped at phase '$($updPrev.phase)' and recorded no owner process (an updater before 4.3.33 never did), so whether it still runs is not known from this record" }
        if ($prevAction -eq 'scan') {   # GUARD:deployscan
            Log "$what - a scan only searches and installs nothing, so nothing is unknown; deploying (the updater's own rule)"
        } elseif ($bootT -and $lastKnown -and $lastT -lt $bootT) {   # GUARD:deployboot
            Log "$what before this qube's last restart ($bootS) - Windows completes or rolls back pending servicing during boot, so that work is settled; deploying"
        } elseif ($refusedBoot -and $bootS -and $refusedBoot -ne $bootS) {   # GUARD:deployrefused
            Log "$what; a pass refused it in an earlier boot ($refusedBoot) and requested a restart, which has happened ($bootS) - deploying"
        } else {
            $msg = ("QWTUPDSTATEUNKNOWN: $what - it was terminated partway in THIS boot, so what it was doing is unknown; refusing " +
                    "to stop the relay or rewrite the updater tasks on top of it, nothing was changed and the mutex was not touched. " +
                    "Read " + $UpdaterStatusFile + " and the agent log; restart this qube (Windows settles pending servicing during " +
                    "boot) and rerun.")
            Log $msg
            throw $msg
        }
    }
}
# ---- DEPLOY-PREVPASS-END
# ---- DEPLOY-MUTEX-BEGIN   (tools/tests/wu-deploy-loud-test.ps1 runs this region after DEPLOY-PREVPASS, against a second process that really holds the mutex)
# NO UPDATE TASK FIRES BEFORE ALL COMPONENTS ARE IN PLACE. Owner 2026-10-09: "on updates, no
# update task should ever fire prematurely before all components are in place."
# The mutex below serialises a pass that is ALREADY RUNNING, but it does not stop the previous
# install's tasks from STARTING during this deploy - and a scan that starts here sets the
# machine-wide proxy and launches the relay underneath the relay replacement and task rewrite that
# follow. So the tasks are disabled for the duration and re-enabled at the end. On a fresh install
# they do not exist yet and every call below is a no-op.
$UpdTasks = @('QubesWindowsUpdateScan','QubesWindowsUpdateRun','QubesWindowsUpdateDownload')
$updGated = @()
function Set-UpdTaskState([string]$name, [string]$how) {
    # schtasks, not Disable-ScheduledTask: this runs on guests where the cmdlet set has been
    # unavailable, and /change is the one spelling present everywhere.
    #
    # THE PREFERENCE IS LOWERED FOR THIS CALL, AND THAT IS THE WHOLE POINT. `2>&1` merges schtasks'
    # stderr into the output stream, which PowerShell turns into a NativeCommandError - and under
    # the inherited $ErrorActionPreference = 'Stop' that error is TERMINATING. On a CLEAN install
    # none of these tasks exists yet, so the very first call threw
    #     RemoteException: ERROR: The specified task name "QubesWindowsUpdateScan" does not exist
    #                      in the system.
    # before any Log ran. Measured on win10-acc 2026-10-09, both arms: absent task -> THREW,
    # existing task -> RETURNED True. That is why the WIN10-clean acceptance cell failed with
    # updater_agent_failed while WIN10-upgrade passed - the upgrade path HAS the tasks.
    # An absent task is not a failure here: the caller keeps only the ones it really disabled, so
    # "false" is the correct answer and must be returned, not thrown.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try   { $out = & schtasks /change /tn $name "/$how" 2>&1 }
    finally { $ErrorActionPreference = $prev }
    return ($LASTEXITCODE -eq 0)
}
foreach ($t in $UpdTasks) {
    if (Set-UpdTaskState $t 'disable') { $updGated += $t }
}
if ($updGated.Count) { Log ("update tasks disabled for the deploy: " + ($updGated -join ', ')) }
else { Log 'no pre-existing update tasks to disable (fresh install)' }
# RE-ENABLED ON EVERY EXIT, including a throw: a failed deploy must not leave the guest with
# updates switched off, which dom0 would see as a guest that simply never reports anything.
$script:UpdUngate = {
    foreach ($t in $script:updGatedList) {
        if (Set-UpdTaskState $t 'enable') { Log "update task re-enabled: $t" }
        else { Log "WARN could not re-enable $t - do it by hand (schtasks /change /tn $t /enable)" }
    }
}
$script:updGatedList = $updGated
# The comment above is only true if something actually runs on the failure path. A trap fires for a
# terminating error anywhere below, re-enables, and rethrows so the deploy still fails loudly.
# `break`, not a bare throw: a bare throw inside a trap raises ScriptHalted and the original
# message is LOST (measured offline in three arms). The mutex trap further down already does this.
trap { try { & $script:UpdUngate } catch { Log ("WARN ungate failed on the error path: " + $_.Exception.Message) }; break }

$updMutex = New-Object System.Threading.Mutex($false, 'Global\QubesWindowsUpdate')
$haveUpdMutex = $false
$updAbandoned = $false
try {
    $haveUpdMutex = $updMutex.WaitOne(0)   # take it, or find out who holds it
} catch [System.Threading.AbandonedMutexException] {
    $haveUpdMutex = $true; $updAbandoned = $true   # .NET hands us the mutex WITH the exception: we own it now
}
$updPrevAction = ''; $updPrevPhase = ''
if ($updPrev) { $updPrevAction = "$($updPrev.action)"; $updPrevPhase = "$($updPrev.phase)" }
$updRemedy = 'Then run install.cmd /updatesonly from this install medium to install the Windows Update agent.'
if ($updAbandoned) {
    if ($updPrevAction -eq 'scan') {   # GUARD:abandonedscan
        Log ("QWTUPDMUTEXABANDONED: a previous updater pass ended without releasing Global\QubesWindowsUpdate, and the last status record is a " +
             "scan (phase '$updPrevPhase') - a scan only searches and installs nothing, so nothing is unknown; the mutex is ours now and the " +
             "deploy proceeds (the updater's own rule for a cut-off scan)")
    } else {
        # Give it back before refusing, or this process exits owning it and every later run inherits the abandonment.
        try { $updMutex.ReleaseMutex() } catch { }
        $haveUpdMutex = $false
        $msg = ("QWTUPDMUTEXABANDONED: a previous updater pass ('$updPrevAction', phase '$updPrevPhase') was terminated without releasing " +
                "Global\QubesWindowsUpdate, so what it was doing is unknown; refusing to stop the relay or rewrite the updater tasks on top " +
                "of it, nothing was changed. Read $UpdaterStatusFile and the agent log; restart this qube (Windows settles pending servicing " +
                "during boot). $updRemedy")
        Log $msg; throw $msg   # GUARD:abandonedfull
    }
}
if (-not $haveUpdMutex) {
    # WHO HOLDS IT. Two witnesses for "a running scan"; either suffices, and the status record must say 'scan' for both:
    #   A. the record names a LIVE owner - owner_pid with a matching owner_pid_start is a running process (recorded since 4.3.33);
    #   B. the registered QubesWindowsUpdateScan task is Running while neither QubesWindowsUpdateRun nor QubesWindowsUpdateDownload
    #      is, AND the 'scan' record was written by that running instance (Test-UpdRecordFresh) - the only way to see a 4.3.29 or
    #      4.3.32 scan, whose records carry no owner (see DEPLOY-PREVPASS).
    # Anything else - an install/download pass, a record with another action or none, a dead recorded owner with no running scan
    # task, an unreadable task state - is not a scan that will end on its own: refused, named, with the remedy.
    $hPid = 0; $hStart = ''
    if ($updPrev) {
        if ($updPrev.PSObject.Properties.Name -contains 'owner_pid')       { $hPid = [int]$updPrev.owner_pid }
        if ($updPrev.PSObject.Properties.Name -contains 'owner_pid_start') { if ($updPrev.owner_pid_start -is [datetime]) { $hStart = $updPrev.owner_pid_start.ToString('s') } else { $hStart = "$($updPrev.owner_pid_start)" } }
    }
    $hAlive = $false; $hSince = $null
    if ($hPid -gt 0) {
        $hp = Get-Process -Id $hPid -ErrorAction SilentlyContinue
        if ($hp) { try { if (-not $hStart -or $hp.StartTime.ToString('s') -eq $hStart) { $hAlive = $true; $hSince = $hp.StartTime } } catch { $hAlive = $false } }
    }
    $scanTask = Get-UpdTaskState 'QubesWindowsUpdateScan'
    $runTask  = Get-UpdTaskState 'QubesWindowsUpdateRun'
    $dlTask   = Get-UpdTaskState 'QubesWindowsUpdateDownload'
    $updFresh = Test-UpdRecordFresh $updPrev $scanTask.lastRun   # GUARD:freshrecord
    $witness = ''
    if ($updPrevAction -eq 'scan' -and $hAlive) {
        $witness = "its owner process $hPid (started $($hSince.ToString('s'))) is running"
    } elseif ($updPrevAction -eq 'scan' -and $updFresh -and $scanTask.state -eq 'Running' -and $runTask.state -ne 'Running' -and $dlTask.state -ne 'Running') {
        $witness = "the QubesWindowsUpdateScan task is Running, no install/download task is, and the scan record was written by that running instance (it names no live owner, pid $hPid - an updater before 4.3.33 never recorded one)"
        if ($scanTask.lastRun) { $hSince = $scanTask.lastRun }
    }
    if ($witness) {   # GUARD:scanwait
        # Bounded by the scan task's limit AS REGISTERED (our own default when it is unreadable or unlimited), less the time the
        # scan has already run, plus the grace for the scheduler's stop-then-terminate.
        $limitS   = Get-UpdSeconds $scanTask.limit $ScanTaskLimit
        $graceS   = Get-UpdSeconds $UpdScanWaitGrace 180
        # Floor, never [int]: PowerShell's [int] cast ROUNDS (0.6 s -> 1), which would end the wait before its bound.
        $elapsedS = 0; if ($hSince) { $elapsedS = [int][math]::Floor([math]::Max(0, ((Get-Date) - $hSince).TotalSeconds)) }
        $boundS   = [int]([math]::Max(0, $limitS - $elapsedS) + $graceS)
        Log ("QWTUPDSCANWAIT: Global\QubesWindowsUpdate is held by a running SCAN ($witness) - waiting for it to release the mutex, bounded " +
             "by the scan task's own limit ('$($scanTask.limit)' -> ${limitS}s, ${elapsedS}s of it already run) plus ${graceS}s for the scheduler's " +
             "stop-then-terminate: at most ${boundS}s")
        $t0 = Get-Date
        while (-not $haveUpdMutex) {
            $leftMs = [int]($boundS * 1000 - ((Get-Date) - $t0).TotalMilliseconds)
            if ($leftMs -le 0) { break }   # GUARD:waitbound
            $sliceMs = [int][math]::Min($leftMs, $UpdWaitSliceMs)
            try { $haveUpdMutex = $updMutex.WaitOne($sliceMs) }   # the kernel wait: returns the moment the scan releases
            catch [System.Threading.AbandonedMutexException] {
                $haveUpdMutex = $true
                Log ("the scan was terminated without releasing the mutex while this deploy waited (abandoned after " +
                     "$([math]::Floor(((Get-Date) - $t0).TotalSeconds))s) - a scan installs nothing, so nothing is unknown; the mutex is ours now")
            }
            if (-not $haveUpdMutex) { Log "still waiting for the scan to release the updater mutex: $([math]::Floor(((Get-Date) - $t0).TotalSeconds))s of at most ${boundS}s" }
        }
        if ($haveUpdMutex) {
            Log "the scan released Global\QubesWindowsUpdate after $([math]::Floor(((Get-Date) - $t0).TotalSeconds))s - deploying"
        } else {
            $msg = ("QWTUPDSCANWAITEXPIRED: the running scan still held Global\QubesWindowsUpdate after ${boundS}s - past its own execution " +
                    "time limit, so it is not a scan doing its work; refusing to stop the relay or rewrite the updater tasks under it, nothing " +
                    "was changed. End it (schtasks /end /tn QubesWindowsUpdateScan) or let Task Scheduler end it. $updRemedy")
            Log $msg; throw $msg
        }
    } else {
        $who = "a running updater pass"
        if ($updPrevAction) { $who = "a running updater pass (last status record: '$updPrevAction', phase '$updPrevPhase'" + $(if ($hAlive) { ", its owner process $hPid is running)" } else { ")" }) }
        $tasks = "tasks: Scan=$($scanTask.state) Run=$($runTask.state) Download=$($dlTask.state)"
        if ($updPrevAction -eq 'scan' -and -not $updFresh) { $tasks += "; the scan record (ts '$($updPrev.ts)') predates the Scan task's current run ('$(if ($scanTask.lastRun) { $scanTask.lastRun.ToString('s') } else { 'unknown' })')" }
        $msg = ("QWTUPDMUTEXHELD: Global\QubesWindowsUpdate is held by $who - not a scan that ends on its own ($tasks), so it is not waited for " +
                "(an install pass may run for $PassTaskLimit and ends in a restart); refusing to stop the relay or rewrite the updater tasks " +
                "under it, nothing was changed. Let it finish (schtasks /query /tn QubesWindowsUpdateRun /v) or end it (schtasks /end /tn <task>). $updRemedy")
        Log $msg; throw $msg   # GUARD:fullrefuse
    }
}
# ---- DEPLOY-MUTEX-END
# Every failure below throws. Without this the installer process (which runs us with `&`) would keep
# the mutex until it exits - skipping every scan and stalling dom0-driven passes for that long.
trap { if ($haveUpdMutex -and $updMutex) { try { $updMutex.ReleaseMutex() } catch { } }; break }
# ---- WU-INSTALLER-RELAY-WAIT-BEGIN   (tools/tests/wu-installer-relay-test.ps1 extracts this region by these markers)
# THE RELAY IS NOT KILLED (docs/ADR-updater.md 12.4, 2026-10-03). Until that day this read
#     Get-Process -Name 'qubes-updates-relay' | Stop-Process -Force
# - every process with that name, whoever started it. The reason it existed: on an UPGRADE the previous relay can be RUNNING and
# holds the exe open, so the compiled exe cannot be moved into place (measured on the 4.3.6->4.3.7 upgrade e2e, 2026-08-25). Now:
# this script holds the updater mutex (above), so no PASS is running, and a pass's relay exits by its own --parent-pid watchdog
# within seconds of its pass's exit (ParentCheckMs, 5 s). So wait, bounded to four watchdog periods (40 x 500 ms), for
# 127.0.0.1:8082's LISTEN owner to go away - found by the PORT, identified by its PID, never by a name. A listener still there
# afterwards is not ours to stop: the compile is skipped, the previous exe is kept, and the pid is named. Without a previous exe
# there is nothing to keep, and a deploy must not report a relay it cannot vouch for: it refuses (Jev 2026-10-03, throw 0.80).
# Get-RelayPortOwner mirrors qubes-windows-update.ps1 and wu-update.ps1 (0 = free, -1 = unreadable, UNKNOWN IS NOT ZERO); keep the
# three in step.
function Get-RelayPortOwner {
    $ev = @()
    try { $l = @(Get-NetTCPConnection -LocalPort 8082 -State Listen -ErrorAction SilentlyContinue -ErrorVariable ev) } catch { return -1 }
    if ($l.Count -gt 0) { return [int]$l[0].OwningProcess }
    foreach ($e in $ev) { if ("$($e.CategoryInfo.Category)" -ne 'ObjectNotFound') { return -1 } }
    return 0
}
$relayFirst = Get-RelayPortOwner
$relayOwner = $relayFirst
$relayWaits = 0
while ($relayOwner -gt 0 -and $relayWaits -lt 40) { Start-Sleep -Milliseconds 500; $relayWaits++; $relayOwner = Get-RelayPortOwner }   # GUARD:relaywait
if ($relayFirst -gt 0 -and $relayOwner -eq 0) { Log "a relay (pid $relayFirst) was still listening on 127.0.0.1:8082 and exited on its own after $($relayWaits * 500) ms - not killed" }
if ($relayOwner -ne 0) {   # GUARD:relaynokill
    $reason = 'cannot read who listens on 127.0.0.1:8082 (Get-NetTCPConnection failed), so a running relay cannot be ruled out'
    if ($relayOwner -gt 0) {
        $who = 'unknown'
        $ownerPath = $null
        try { $op = Get-Process -Id $relayOwner -ErrorAction SilentlyContinue; if ($op) { $who = $op.ProcessName; try { $who += ' at ' + $op.Path; $ownerPath = $op.Path } catch { } } } catch { }
        # ---- RELAY-ORPHAN-STOP-BEGIN  (driven by tools/tests/wu-installer-relay-test.ps1)
        # AN UPGRADE THAT CANNOT REPLACE ITS OWN COMPONENT IS STUCK, NOT SAFE. Until now this refused
        # whenever anything still held 8082 and a previous exe existed. That condition is
        # SELF-PERPETUATING: the stale relay holds the port AND holds the exe open, so the deploy
        # refuses; because it refuses, the stale relay is never replaced. On win11de-tup a relay has
        # squatted 8082 SINCE SEPTEMBER and every Windows Update pass on that template has failed
        # since, each deploy refusing into a log nobody read. Owner, 2026-10-21: "how upgrade process
        # can DELIBERATELY refuse to land the updated component?"
        # THIS IS NOT STOPPING BY NAME, which is what the standing rule forbids because a pattern
        # matches the matcher. The pid comes from the PORT (Get-NetTCPConnection -LocalPort 8082) and
        # is acted on ONLY when its executable path is THIS deploy's own relay exe. Anything else
        # holding 8082 is not ours and still refuses, below, unchanged.
        # AND IT CANNOT BE A LIVE PASS'S RELAY: this deploy holds the updater mutex, so no pass is
        # running, and a pass's relay exits by its own --parent-pid watchdog within ~5 s. A listener
        # still here after the 20 s wait, with the mutex held, is an orphan by construction.
        # Jev on this fork: stop_the_identified_orphan 0.81, refusing_forever 0.21, rename_around 0.16.
        if ($ownerPath -and $exe -and ($ownerPath -ieq $exe)) {
            Log ("the listener on 127.0.0.1:8082 is OUR OWN relay exe (pid {0} at {1}) and no pass is running - ending that pid so this deploy can replace it" -f $relayOwner, $ownerPath)
            # BY ID, NEVER BY NAME. -Name would match every process called qubes-updates-relay,
            # whoever started it, which is the 2026-10-03 defect this file's own suite exists to
            # keep out (Test-NothingKilled counts any by-name lookup as a failure).
            try { Stop-Process -Id $relayOwner -Force -ErrorAction Stop } catch { Log ("could not end pid {0}: {1}" -f $relayOwner, $_.Exception.Message) }
            $stopWaits = 0
            while ((Get-RelayPortOwner) -ne 0 -and $stopWaits -lt 40) { Start-Sleep -Milliseconds 500; $stopWaits++ }   # GUARD:orphanstop
            $relayOwner = Get-RelayPortOwner
            if ($relayOwner -eq 0) {
                Log ("port 127.0.0.1:8082 freed after {0} ms - continuing to compile and replace the relay" -f ($stopWaits * 500))
            } else {
                Log ("the orphan was ended but 127.0.0.1:8082 is STILL held (owner now {0}) - refusing below rather than compiling over an unknown state" -f $relayOwner)
            }
        }
        # ---- RELAY-ORPHAN-STOP-END
        $reason = "QWTRELAYBUSY: pid $relayOwner ($who) is still listening on 127.0.0.1:8082 after 20 s while this deploy holds the updater mutex - it is not a running pass's relay (that exits with its pass) and it is NOT killed (nothing is killed by name, ADR-updater 12.4)"
    }
}
# THE REFUSAL IS A SEPARATE DECISION FROM THE WAIT, and it has to re-read the state. When the orphan
# branch above ends our own squatter and the port comes free, $relayOwner is 0 - but that assignment
# cannot re-open the `if` that was already entered, so the refusal below ran anyway and the deploy
# threw over a port that was now free. Caught by the suite's own orphan leg on its first run.
if ($relayOwner -ne 0) {
    if (Test-Path -LiteralPath $exe) {
        # A DEPLOY MUST NOT REPORT A RELAY IT CANNOT VOUCH FOR, and until today that principle was
        # applied only when NO exe existed - so the one case that actually happens went through
        # silently. KEEPING the exe is unchanged and still deliberate (nothing killed, nothing
        # compiled, Jev 0.80); what changes is that the deploy stops calling it a success.
        #
        # WHY, measured and then measured again. Recorded 2026-10-17 (findings/updates.md
        # QWTRELAYBUSY) and written up as "proposed, not implemented - the owner's call", which was
        # my error: a relay that binds the wrong port can never work, so there was nothing to
        # decide. It then failed the 4.3.37 release acceptance, feature test template-update, on
        # win11de-tup, all three rounds:
        #   05:04:00  QWTRELAYBUSY: pid 9648 (qubes-updates-relay at C:\Program Files\...) is still
        #             listening on 127.0.0.1:8082 after 20 s
        #   05:04:00  kept the previous relay exe ... (compile skipped - see above)
        #   05:22:08  relay, its OWN log: listen 127.0.0.1:3312 ...     <- 3312 is the pass's PID
        #   05:22:26  relay pid 1320 is not accepting connections on 127.0.0.1:8082
        # The kept exe predates --parent-pid, so RunListen's catch-all takes that flag's VALUE as
        # the listen port: the relay binds the updater's own pid and never 8082. SELF-PERPETUATING,
        # because a relay with no parent watchdog outlives its pass and is what makes the next
        # deploy skip the compile too - pid 9648 had been squatting 8082 on that template since
        # September. Every Windows Update pass on it has been dead since, and the deploy said ok.
        $msg = $reason + ". The relay is NOT recompiled and the previous exe at $exe is KEPT - a running copy holds it open, and nothing here is killed. But this deploy cannot vouch for that exe: a binary predating a flag this release's script passes takes the flag's VALUE as its listen port, so the relay binds the updater's PID and never 8082, and every update pass then fails through a proxy nothing serves. Refusing instead of reporting a relay it cannot vouch for. Find out what that listener is, stop it, then rerun this deploy to replace the exe."
        Log $msg
        throw $msg   # GUARD:vouchexe
    } else {
        $msg = $reason + ". No previous relay exe exists at $exe to keep, so this deploy cannot leave the guest with a relay it can vouch for: refusing - nothing compiled, nothing killed. Find out what that listener is and rerun."
        Log $msg
        throw $msg
    }
}
# ---- WU-INSTALLER-RELAY-WAIT-END
# Compile to a TEMP name and move into place only on success: a failed compile (or a lock
# that survives the retries) must leave the PREVIOUS working relay untouched. The first
# version of this fix deleted $exe before compiling, which could strand an upgraded guest
# with no relay at all - worse than the failure it fixed.
$exeNew = "$exe.new"
$cscOut = $null
# ---- RELAYBYIMAGE-BEGIN  (driven by tools/tests/relay-vouch-test.ps1)
# A STALE RELAY IS IDENTIFIED BY ITS BINARY, NOT BY THE PORT IT HOLDS. Everything above finds a
# relay through Get-NetTCPConnection -LocalPort 8082, and its comment says so: "found by the PORT,
# identified by its PID, never by a name". That is exactly what the real orphan defeats. MEASURED on
# win11de-tup across three template-update rounds, 2026-10-22: the stale relay binds the PASS'S OWN
# PID as its port (600, 2880, 4184, 5548, 6688, 8228), so NOTHING holds 8082, the port-keyed branch
# never fires, and a process launched from the very path we are about to replace keeps running.
# Replacing the file does not stop it, so it can go on serving a port nobody asked for.
# So: Win32_Process by ExecutablePath - our exe, whatever port it is on - and each one ended BY ITS
# OWN PID. Never by name: a pattern matches the matcher, which has cost this project its own shell.
# The mutex is held here, so no PASS is running and anything still on our image is an orphan.
# A MISS IS NEVER SILENT. The comparison is a plain path equality - deliberately. The normalising
# alternative ([IO.Path]::GetFullPath) behaves differently off Windows: under Linux pwsh it prepends
# the working directory to a 'C:\...' path and does not collapse '..' at all, so the offline suite
# could not exercise it and it would be untested code guarding an untested case. Instead every relay
# process whose image is NOT the file being replaced is LOGGED, so a match that fails for a
# path-spelling reason says so in the log rather than reporting nothing found.
$allRelay = @()
try {
    $allRelay = @(Get-CimInstance Win32_Process -Filter "Name='qubes-updates-relay.exe'" -EA Stop)
} catch { Log "could not enumerate relay processes by image ($($_.Exception.Message)) - continuing; the exe vouch below is the backstop" }
$stale = @($allRelay | Where-Object { "$($_.ExecutablePath)" -and ("$($_.ExecutablePath)" -ieq $exe) })
foreach ($other in @($allRelay | Where-Object { "$($_.ExecutablePath)" -and ("$($_.ExecutablePath)" -ine $exe) })) {
    Log ("a relay is running from a DIFFERENT image (pid {0} at {1}) - left alone; this deploy only ends relays running from {2}" -f $other.ProcessId, $other.ExecutablePath, $exe)
}
foreach ($sp in $stale) {
    $spid = [int]$sp.ProcessId
    Log ("a relay is running from the exe this deploy replaces (pid {0} at {1}) - ending that pid, whatever port it holds" -f $spid, $sp.ExecutablePath)
    try { Stop-Process -Id $spid -Force -EA Stop } catch { Log ("could not end pid {0}: {1}" -f $spid, $_.Exception.Message) }
}
if ($stale.Count) {
    # UNKNOWN IS NOT ZERO. This loop used to swallow a failed query into an empty array, break on
    # it, and log "relay processes on our image after the stop: 0" - reporting SUCCESS for a query
    # that never ran, which is the same shape of lie as the deploy that logged "deployed" over a
    # relay it never built. Get-RelayOwner in qubes-windows-update.ps1 returns -1 rather than 0 for
    # this exact reason ("UNKNOWN IS NOT ZERO" in its own comment), so this follows that convention.
    $leftCount = -1
    for ($w = 0; $w -lt 20; $w++) {
        try {
            $leftCount = @(Get-CimInstance Win32_Process -Filter "Name='qubes-updates-relay.exe'" -EA Stop |
                           Where-Object { "$($_.ExecutablePath)" -ieq $exe }).Count
        } catch { $leftCount = -1 }
        if ($leftCount -eq 0) { break }
        Start-Sleep -Milliseconds 500
    }
    if ($leftCount -lt 0) {
        Log ("could not confirm the stale relays are gone (the process query failed) - NOT claiming " +
             "zero; if one still holds $exe the move below throws and this deploy fails loudly")
    } else {
        Log ("relay processes on our image after the stop: {0}" -f $leftCount)
    }
}
# ---- RELAYBYIMAGE-END
# NO SKIP BRANCH ANY MORE. It existed for the case where something still holds 8082 and a previous
# exe is kept; that case now REFUSES above (GUARD:vouchexe), so reaching here means the deploy is
# compiling. A branch that can no longer be taken is decoration, and this one hid the defect.
# ---- RELAYDEADBLOCK: THE BRACES THAT MADE ALL OF THIS DEAD CODE ARE GONE.
# A bare `{ ... }` in PowerShell is a ScriptBlock LITERAL: it is constructed and discarded, and the
# statements inside it NEVER RUN. When the `if (...)` that used to guard this block was removed, its
# braces were left behind - so the compile, the move and the log line below became a scriptblock
# nobody invoked, and every deploy since then printed "updater agent deployed" having touched
# nothing.
# MEASURED on win11de-tup, 2026-10-22, the guest the owner has been asking about every day:
#   C:\Program Files\Qubes Tools\bin\qubes-updates-relay.exe  written=2026-09-16T16:33:26Z
# - five weeks stale, carrying none of the shipped binary's markers, while NO install log on that
# guest has ever contained a "compiled relay ->" line. The relay that then runs predates
# --parent-pid, so the launcher's flag VALUE becomes its listen port and 8082 is never served, which
# is why every update pass went silent. Proven, not inferred: `{ $ran = $true }` leaves $ran False.
# Nothing else in this file could have fixed that, and nothing that keyed on who holds 8082 was ever
# going to find it.
    for ($cscTry = 1; $cscTry -le 3; $cscTry++) {
        Remove-Item $exeNew -Force -EA SilentlyContinue
        $cscOut = & $csc /nologo /optimize /target:exe /out:"$exeNew" "$src" 2>&1
        if ($LASTEXITCODE -eq 0 -and (Test-Path $exeNew)) { break }
        Log "relay compile attempt $cscTry failed (rc=$LASTEXITCODE); retrying"
        Start-Sleep -Seconds 2
    }
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $exeNew)) {
        throw "relay compile failed (csc rc=$LASTEXITCODE): $((@($cscOut) | Select-Object -First 2) -join ' | ')"
    }
    $moved = $false
    for ($mvTry = 1; $mvTry -le 3; $mvTry++) {
        try { Move-Item $exeNew $exe -Force -EA Stop; $moved = $true; break }
        catch { Start-Sleep -Seconds 2 }   # the old exe can still be releasing its handle
    }
    if (-not $moved) { throw "relay compiled but could not replace $exe (still locked)" }
    Log "compiled relay -> $exe"
    # ---- RELAYEXEVOUCH-BEGIN  (driven by tools/tests/relay-vouch-test.ps1)
    # AND THE PLACED BINARY MUST CARRY IT TOO. The source vouch above catches a stale payload; this
    # catches everything else between the source and the file that will actually be launched - a
    # compile that silently used a different input, a move that landed somewhere else, a binary
    # restored by anything after us. .NET string literals sit in the PE as UTF-16, so the marker is
    # searched as UTF-16 bytes: no execution, no port bound, nothing to leave behind. This is the
    # check whose absence let "updater agent deployed" be logged over a relay that could never
    # serve 8082 (win11de-tup, 2026-10-22, three rounds, zero `parent=` lines).
    $want = [Text.Encoding]::Unicode.GetBytes('parent=')
    # THE READ IS RETRIED, BECAUSE A REFUSAL MUST MEAN "WRONG BINARY" AND NOTHING ELSE. Defender
    # scans a freshly written exe and holds it briefly, so a single ReadAllBytes seconds after
    # Move-Item can raise a sharing violation - and an unhandled IO error here would fail a
    # perfectly good install. A vouch that cannot tell "not our binary" from "could not read it
    # yet" refuses good deploys, which is worse than the gap it closes.
    $bytes = $null
    $readErr = ''
    for ($rt = 1; $rt -le 4; $rt++) {
        try { $bytes = [IO.File]::ReadAllBytes($exe); $readErr = ''; break }
        catch { $readErr = "$($_.Exception.Message)"; Start-Sleep -Milliseconds 500 }
    }
    if ($null -eq $bytes) {
        throw ("QWTRELAYUNREADABLE: the relay was compiled and placed at $exe but could not be read " +
               "back to vouch it after 4 attempts ($readErr). This is NOT a stale-binary refusal - " +
               "the file is there and may be fine; something is holding it. Re-run install.cmd " +
               "/updatesonly; if it repeats, find what holds $exe.")
    }
    $found = $false
    for ($i = 0; $i -le $bytes.Length - $want.Length; $i++) {
        $hit = $true
        for ($j = 0; $j -lt $want.Length; $j++) { if ($bytes[$i + $j] -ne $want[$j]) { $hit = $false; break } }
        if ($hit) { $found = $true; break }
    }
    if (-not $found) {
        throw ("QWTRELAYSTALEEXE: the relay now at $exe does not contain the shipped binary's " +
               "'parent=' marker, so it was not built from the vouched source. A relay without " +
               "--parent-pid takes the launcher's flag value as its listen port and never serves " +
               "8082, which makes every update pass silent and tells dom0 nothing.")
    }
    Log "relay exe vouched at $exe (carries the shipped binary's parent= marker)"
    # ---- RELAYEXEVOUCH-END

# 2. place the agent script
$agent = Join-Path $BinDir 'qubes-windows-update.ps1'
Copy-Item (Join-Path $SetupRoot 'qubes-windows-update.ps1') $agent -Force
Log "placed agent -> $agent"

# 3. register the scheduled scan task. Past StartBoundary is fine - the repetition schedules the
#    next occurrence. Runs as SYSTEM/HighestAvailable so it works with no user logged on.
$cmd  = 'powershell.exe'
# -Scheduled marks this as the AUTOMATIC background refresh: the only pass allowed to be skipped
# when another has just completed (the debounce in the agent). It belongs to this task alone -
# QubesWindowsUpdateRun/Download and the rpc handlers must never carry it, or a pass dom0 asked
# for could be silently dropped.
$args = "-NoProfile -ExecutionPolicy Bypass -File `"$agent`" -Action scan -Scheduled -RelayExe `"$exe`""
$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>QWT-NG: scan Windows Update over the Qubes proxy and report availability to dom0</Description></RegistrationInfo>
  <Triggers>
    <BootTrigger><Enabled>true</Enabled><Delay>PT2M</Delay></BootTrigger>
    <TimeTrigger><Enabled>true</Enabled><StartBoundary>2026-01-01T03:00:00</StartBoundary><Repetition><Interval>$Interval</Interval></Repetition></TimeTrigger>
  </Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <StartWhenAvailable>true</StartWhenAvailable>
    <ExecutionTimeLimit>$ScanTaskLimit</ExecutionTimeLimit>
    <AllowHardTerminate>true</AllowHardTerminate>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
  </Settings>
  <Actions Context="Author"><Exec><Command>$cmd</Command><Arguments>$args</Arguments></Exec></Actions>
</Task>
"@
$f = Join-Path $env:TEMP 'qubes-wu-scan.xml'
[IO.File]::WriteAllText($f, $xml, [Text.Encoding]::Unicode)
$o = & schtasks /create /tn QubesWindowsUpdateScan /xml "$f" /f 2>&1
Log ("REGISTER QubesWindowsUpdateScan rc=$LASTEXITCODE : " + ($o -join ' '))
if ($LASTEXITCODE -ne 0) { throw "schtasks register failed (rc=$LASTEXITCODE)" }

# 4. the dom0-DRIVEN update path, Linux-updater style (update runs only when dom0 asks):
#    - QubesWindowsUpdateRun: on-demand SYSTEM task running `-Action full` (rpc handlers are
#      unelevated and DISM needs admin; the SYSTEM-task path is proven). No triggers - fires
#      only via schtasks /run.
#    - qubes.WindowsUpdate rpc service: dom0 calls it to start the run; the handler
#      (wu-update.ps1) kicks the task, tails update-status.json, and speaks the qubes-vm-update
#      protocol (float progress on stderr, exit 100 = no updates). dom0-initiated, no policy.
# XML with an EMPTY Triggers block: purely on-demand, and no schtasks /st-in-the-past warning
# (which, on stderr under ErrorActionPreference=Stop, would kill this script mid-deploy).
$runXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>QWT-NG: perform a full Windows update pass (dom0-driven via qubes.WindowsUpdate; never fires on its own)</Description></RegistrationInfo>
  <Triggers />
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <StartWhenAvailable>false</StartWhenAvailable>
    <ExecutionTimeLimit>$PassTaskLimit</ExecutionTimeLimit>
    <AllowHardTerminate>true</AllowHardTerminate>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
  </Settings>
  <Actions Context="Author"><Exec><Command>powershell.exe</Command><Arguments>-NoProfile -ExecutionPolicy Bypass -File "$agent" -Action full -RelayExe "$exe"</Arguments></Exec></Actions>
</Task>
"@
$fr = Join-Path $env:TEMP 'qubes-wu-run.xml'
[IO.File]::WriteAllText($fr, $runXml, [Text.Encoding]::Unicode)
$o = & schtasks /create /tn QubesWindowsUpdateRun /xml "$fr" /f 2>&1
Log ("REGISTER QubesWindowsUpdateRun rc=$LASTEXITCODE : " + ($o -join ' '))
if ($LASTEXITCODE -ne 0) { throw "schtasks register (run task) failed (rc=$LASTEXITCODE)" }

# ---- WU-TASKSCHED-OPLOG   (tools/tests/wu-autologon-guard-test.ps1 asserts this block is shipped)
# Enable the Task Scheduler operational log, so the NEXT terminated pass names its requester.
# Measured 2026-09-17 on the German 25H2 template: a QubesWindowsUpdateRun instance was ended by
# the scheduler on request (LastTaskResult 0x41306) 90 s into a pass, and nothing on the guest
# recorded by whom - Microsoft-Windows-TaskScheduler/Operational is disabled by default
# (`wevtutil gl` -> enabled: false), so the scheduler's own record of the stop did not exist.
# Idempotent. A failure to enable is a WARN, never fatal: nothing the deploy does depends on it.
# wevtutil writes to stderr on failure and this script runs under ErrorActionPreference=Stop, so
# the calls sit in a try - a redirected stderr line is a terminating error here (see the XML note).
function Get-TaskSchedLogEnabled {
    $o = @(& wevtutil gl 'Microsoft-Windows-TaskScheduler/Operational' 2>&1)
    foreach ($line in $o) { if ("$line" -match '^\s*enabled:\s*(\S+)') { return $Matches[1] } }
    return 'unknown'
}
try {
    $tsBefore = Get-TaskSchedLogEnabled
    & wevtutil sl 'Microsoft-Windows-TaskScheduler/Operational' /e:true 2>&1 | Out-Null
    $tsAfter = Get-TaskSchedLogEnabled
    Log "task scheduler operational log: enabled $tsBefore -> $tsAfter"
    if ($tsAfter -ne 'true') { Log "WARN: Microsoft-Windows-TaskScheduler/Operational is still enabled: $tsAfter - the next terminated pass will not name its requester" }
} catch { Log "WARN: could not enable the Task Scheduler operational log ($($_.Exception.Message)) - the next terminated pass will not name its requester" }

$qt = $env:QUBES_TOOLS; if (-not $qt) { $qt = 'C:\Program Files\Qubes Tools' }
$handlerDir = Join-Path $qt 'qubes-rpc-services'
$svcDir     = Join-Path $qt 'qubes-rpc'
if ((Test-Path $handlerDir) -and (Test-Path $svcDir)) {
    Copy-Item (Join-Path $SetupRoot 'wu-update.ps1') (Join-Path $handlerDir 'wu-update.ps1') -Force
    $map = 'c:\windows\system32\cmd.exe /c powershell.exe -executionpolicy bypass -noninteractive -inputformat none -file "%QUBES_TOOLS%\qubes-rpc-services\wu-update.ps1"'
    [IO.File]::WriteAllText((Join-Path $svcDir 'qubes.WindowsUpdate'), $map, [Text.Encoding]::ASCII)
    # retire the short-lived poll service - progress now streams over the update call itself
    Remove-Item (Join-Path $svcDir 'qubes.WindowsUpdateStatus'), (Join-Path $handlerDir 'wu-status.ps1') -Force -EA SilentlyContinue
    Log 'registered qubes.WindowsUpdate rpc service (dom0-driven update)'

    # 5. STOCK-TOOL COMPATIBILITY: make dom0's own `qubes-vm-update` - and therefore the Qubes
    #    Update GUI - drive this qube, so updating a Windows qube is the same click as any other
    #    and needs no dom0-side command. dom0 injects a Python agent and runs it; we answer the
    #    same command shapes and run ours instead. See guest/vmupdate-shim.ps1 for the sequence.
    Copy-Item (Join-Path $SetupRoot 'vmupdate-shim.ps1') (Join-Path $handlerDir 'vmupdate-shim.ps1') -Force
    # Re-asserted before every reboot the updater triggers: Windows servicing rewrites Winlogon,
    # and a qube that returns to a sign-in screen is unreachable over qrexec.
    if (Test-Path (Join-Path $SetupRoot 'ensure-autologon.ps1')) {
        Copy-Item (Join-Path $SetupRoot 'ensure-autologon.ps1') (Join-Path $handlerDir 'ensure-autologon.ps1') -Force
    }
    # Keep the ARMING script on disk too, not just the guard: re-arming is what a user needs
    # after changing the account password, and the setup payload is long gone by then.
    if (Test-Path (Join-Path $SetupRoot 'set-autologon.ps1')) {
        Copy-Item (Join-Path $SetupRoot 'set-autologon.ps1') (Join-Path $handlerDir 'set-autologon.ps1') -Force
    }
    $vmexec = Join-Path $handlerDir 'VMExec.ps1'
    $backup = Join-Path $handlerDir 'VMExec.ps1.qwt-orig'
    if ((Test-Path $vmexec) -and -not (Test-Path $backup)) { Copy-Item $vmexec $backup -Force }
    Copy-Item (Join-Path $SetupRoot 'VMExec.ps1') $vmexec -Force
    Log 'installed vmupdate-shim + VMExec.ps1 (exit-code propagation + updater dispatch)'
} else {
    Log 'qubes-rpc dirs missing - skipped rpc service (is QWT installed?)'
}

# 5b. AUTOLOGON GUARD AT EVERY BOOT. Asserting autologon before our own reboot is not enough:
#     Windows applies the update DURING the next boot and rewrites Winlogon there, after our
#     check has run. A SYSTEM task at boot repairs it for the boot after that, so a qube can
#     lose autologon at most once instead of permanently. SYSTEM/HighestAvailable, so it does
#     not itself need a logged-on user - which is the whole point.
$alPath = Join-Path $handlerDir 'ensure-autologon.ps1'
# The guard is load-bearing (the "at most once" guarantee above), so its absence is a deploy
# failure, not a skipped step: a task pointing at a script that is not there registers fine,
# does nothing at every boot, and the installer would still record updater_agent='deployed'.
if (-not (Test-Path $alPath)) { throw "autologon guard script missing at $alPath (qubes-rpc dirs absent or ensure-autologon.ps1 not in payload) - QubesAutologonGuard not registered" }
$alXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>QWT-NG: keep Windows autologon configured, so the qube stays reachable over qrexec after updates</Description></RegistrationInfo>
  <Triggers><BootTrigger><Enabled>true</Enabled><Delay>PT30S</Delay></BootTrigger></Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <StartWhenAvailable>true</StartWhenAvailable>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <AllowHardTerminate>true</AllowHardTerminate>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
  </Settings>
  <Actions Context="Author"><Exec><Command>powershell.exe</Command><Arguments>-NoProfile -ExecutionPolicy Bypass -File "$alPath"</Arguments></Exec></Actions>
</Task>
"@
$fa = Join-Path $env:TEMP 'qubes-autologon-guard.xml'
[IO.File]::WriteAllText($fa, $alXml, [Text.Encoding]::Unicode)
$o = & schtasks /create /tn QubesAutologonGuard /xml "$fa" /f 2>&1
Log ("REGISTER QubesAutologonGuard rc=$LASTEXITCODE : " + ($o -join ' '))
# Checked like the three sibling registrations: an unregistered guard otherwise surfaced as one
# rc= line nobody parses while the install reported 'deployed', and the first cumulative update
# that rewrote Winlogon left the qube at a sign-in screen for good (rc=117 over qrexec).
if ($LASTEXITCODE -ne 0) { throw "schtasks register (autologon guard) failed (rc=$LASTEXITCODE)" }

# Assert it once now, so a guest that is ALREADY one update away from losing autologon is fixed
# before that update rather than after it.
if (Test-Path $alPath) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { foreach ($l in @(& $alPath 2>&1)) { if ($l -match '^(SET|WARN)') { Log "autologon: $l" } } }
    finally { $ErrorActionPreference = $prev }
}

# 6. `cat` for the one step PATH can satisfy: dom0 ships its agent tarball in with
#    `cat > <file>` over qubes.VMShell, which goes straight to cmd.exe with no interception
#    point. (mkdir/rm/tar/python3 all arrive via qubes.VMExec and are handled by the shim.)
$shimDir = Join-Path $qt 'vmupdate-shim'
New-Item -ItemType Directory -Force $shimDir | Out-Null
$catSrc = Join-Path $SetupRoot 'qubes-posix-cat.cs'
$catExe = Join-Path $shimDir 'cat.exe'
if (Test-Path $catSrc) {
    & $csc /nologo /optimize /target:exe /out:"$catExe" "$catSrc" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "cat.exe compile failed (csc rc=$LASTEXITCODE)" }
    # Appended, never prepended: if a real POSIX toolset is installed later, it wins.
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ($machinePath -notlike "*$shimDir*") {
        [Environment]::SetEnvironmentVariable('Path', ($machinePath.TrimEnd(';') + ';' + $shimDir), 'Machine')
        Log "added $shimDir to the machine PATH"
    }
    Log "compiled cat -> $catExe"
}

# 7. download-only pass, kept separate so `--download-only` can never install.
$dlXml = $runXml -replace 'QubesWindowsUpdateRun', 'QubesWindowsUpdateDownload' `
                 -replace '-Action full', '-Action download' `
                 -replace 'perform a full Windows update pass', 'download Windows updates only'
$fd = Join-Path $env:TEMP 'qubes-wu-dl.xml'
[IO.File]::WriteAllText($fd, $dlXml, [Text.Encoding]::Unicode)
$o = & schtasks /create /tn QubesWindowsUpdateDownload /xml "$fd" /f 2>&1
Log ("REGISTER QubesWindowsUpdateDownload rc=$LASTEXITCODE : " + ($o -join ' '))
if ($LASTEXITCODE -ne 0) { throw "schtasks register (download task) failed (rc=$LASTEXITCODE)" }
# Relay/proxy/task mutations end here - hand the updater back its mutex (steps 8-9 touch neither).
if ($haveUpdMutex) { try { $updMutex.ReleaseMutex() } catch { }; $haveUpdMutex = $false }

# 8. The updater workdir, pre-created ON PURPOSE - do not delete it.
#
#    dom0 chooses its transport per qube: qubesadmin's run_with_args() uses qubes.VMExec only
#    for qubes advertising the `vmexec` feature, and otherwise falls back to qubes.VMShell with
#    a shell-quoted line. We CANNOT advertise that feature from the guest: the Windows build of
#    qubesdb-cmd cannot write at all (`optind -= 2` in client/qubesdb-cmd.c leaves exactly one
#    trailing argument, so `write path value` always dies with "Invalid number of parameters" -
#    measured, every documented form). Do not re-add an advertisement step; it cannot work until
#    that upstream bug is fixed or dom0 sets the feature itself (`qvm-features <vm> vmexec 1`).
#
#    So the fallback path must work, and it does - with this one preparation. Over VMShell each
#    of dom0's POSIX commands fails on cmd.exe, but `& exit` returns 0 regardless (measured: a
#    bogus command still yields exit 0), so dom0 sees success and proceeds. The only step that
#    then matters is the agent run itself, and that ALWAYS travels over qubes.VMExec - the
#    progress path calls the service directly, with no feature check and no fallback - so our
#    shim still handles it. The one thing that must not fail is dom0 piping its agent tarball in
#    with `cat > <workdir>/agent.tar.gz`: if the directory is missing, cmd's redirection fails,
#    cmd exits immediately and dom0 is left writing a megabyte into a closed pipe. Hence the
#    directory exists from install time, and the shim's `rm` empties it rather than removing it.
$workdir = Join-Path $env:SystemDrive 'run\qubes-update'
New-Item -ItemType Directory -Force -Path $workdir | Out-Null
Log "prepared updater workdir $workdir (kept even when dom0 asks to remove it - see comment)"

# 9. Guest-side auto-update OFF: dom0 owns every install decision from now on. This is not
#    cosmetic - the updates proxy is raised only for the duration of a dom0-driven pass, which
#    is precisely the window in which a live Windows AU would find connectivity and start
#    installing behind dom0's back. The wuauserv/USO services stay ENABLED: the on-demand path
#    needs them; only the automatic behaviour is disabled.
$au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
New-Item -Path $au -Force | Out-Null
Set-ItemProperty -Path $au -Name NoAutoUpdate -Value 1 -Type DWord
Log 'set NoAutoUpdate=1 (dom0 owns updates; guest never installs on its own)'

# 10. (Retired) The guest-side AppVM guard no longer needs a deploy-time RootIdentity stamp. The
#     updater classifies the qube LIVE from qubesdb (/type) at every run - a derived AppVM reads
#     back as 'AppVM' and exits before any proxy activity, a StandaloneVM as 'StandaloneVM', a
#     template as 'TemplateVM'. The guest reads its own vm-type fine (the old "unreadable" belief
#     was a P/Invoke marshaling bug; see guest/qubesdb-read.ps1). Nothing is stamped here anymore.

# Every component is in place now - this is the only point at which an update task may fire.
& $script:UpdUngate

Log 'updater agent deployed'
