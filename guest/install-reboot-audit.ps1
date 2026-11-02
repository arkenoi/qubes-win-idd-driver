# Record WHY this guest restarted, somewhere the restart cannot erase.
#
# WHY THIS EXISTS. Windows records who initiated a shutdown (System event 1074) and whether the
# last one was unclean (6008), but on an AppVM the System log is on C:, which is a discarded
# copy-on-write overlay - every reboot wipes the very record that explains it. Measured
# 2026-08-28: win11-app restarted itself unattended with "xenagent_9_1_0_0.exe" named as the
# initiator, and nothing survived to say whether that was dom0 asking (xenagent is the Xen PV
# agent that executes xenstore control/shutdown - a normal qvm-shutdown looks exactly like this)
# or the guest deciding by itself (a pending PV driver-install reboot, which is the mechanism
# behind the old AppVM reboot loop and is replayed on every boot of a volatile root).
#
# Those two are indistinguishable after the fact and have opposite fixes, so stop guessing:
# capture the record into the one log directory (LogDir, on the private volume, which persists).
#
# Two event-TRIGGERED tasks, not a poll: 1074 is written seconds before the machine goes down, so
# a 5-minute poll would miss it every time.
#   1074 -> who asked for the shutdown/restart, which process, and the reason code
#   6008 -> the previous shutdown was unexpected (written early in the NEXT boot)
#   41   -> kernel power: the system rebooted without cleanly shutting down first
#
# Idempotent: re-running replaces the tasks. Harmless on a StandaloneVM, where the System log
# survives anyway - it just makes the same facts easier to find.
$ErrorActionPreference = 'Continue'
$changed = 0
$failed = 0

# THE RECORDER IS A SCRIPT, so it goes to bin (docs/ADR-logging.md, Decision 2026-11-01, item 5) and
# writes record-reboot-cause.ps1-<yyyyMMdd>.log in the one log directory through the shipped sink.
# It used to fall back to the log directory itself when the vmupdate-shim directory was absent - as
# it is at this point of a clean install, before the updater deploy later in stage 2 creates it.
$scriptDir = 'C:\Program Files\Qubes Tools\bin'
$recorder = Join-Path $scriptDir 'record-reboot-cause.ps1'
Write-Output "info   audit log: record-reboot-cause.ps1-<yyyyMMdd>.log in the Qubes Tools log directory"

# THE SINK FIRST: the recorder exits 1 without log.ps1 beside it, so it is placed before the recorder
# can be started, from beside this script (the payload root). Without it nothing below is installed -
# tasks left by an earlier install keep their old recorder rather than point at one that cannot log.
$sinkOk = $false
try {
    $sinkSrc = Join-Path $PSScriptRoot 'log.ps1'
    if (-not (Test-Path -LiteralPath $sinkSrc)) { throw "log.ps1 is not beside this script ($sinkSrc)" }
    New-Item -ItemType Directory -Path $scriptDir -Force -ErrorAction Stop | Out-Null
    $sinkDst = Join-Path $scriptDir 'log.ps1'
    if (-not ((Test-Path -LiteralPath $sinkDst) -and
              (Get-FileHash -LiteralPath $sinkDst).Hash -eq (Get-FileHash -LiteralPath $sinkSrc).Hash)) {
        Copy-Item -LiteralPath $sinkSrc -Destination $sinkDst -Force -ErrorAction Stop
    }
    Write-Output "ok     log sink in place: $sinkDst"
    $sinkOk = $true
} catch {
    Write-Output "FAIL   could not place the log sink beside the recorder: $($_.Exception.Message) - recorder and tasks NOT installed"
    $failed++
}

# The recorder: pull the triggering record itself, not a summary, and append it verbatim.
$recorderBody = @'
param([int]$EventId = 1074)
$ErrorActionPreference = 'SilentlyContinue'
# The log sink, from beside this script: record-reboot-cause.ps1-<yyyyMMdd>.log in the one log
# directory, the timestamp in each line's prefix (docs/ADR-logging.md).
$qwtLogPs1 = Join-Path $PSScriptRoot 'log.ps1'
try { . $qwtLogPs1 } catch { [Console]::Error.WriteLine("record-reboot-cause.ps1: cannot load $qwtLogPs1 ($($_.Exception.Message)) - no log sink"); exit 1 }
if (-not (Get-Command Write-QwtLogLine -EA SilentlyContinue)) { [Console]::Error.WriteLine("record-reboot-cause.ps1: $qwtLogPs1 has no Write-QwtLogLine - no log sink"); exit 1 }
# Uptime from the tick count, NOT from CIM. Get-CimInstance Win32_OperatingSystem takes seconds and
# talks to a WMI service that is being torn down at exactly the moment this task runs; TickCount64
# is a register read and needs no clock, which also makes it immune to this guest's boot-time clock
# flip (LastBootUpTime is stamped in the pre-correction phase and reads hours out).
# TickCount, not TickCount64: this runs under PowerShell 5.1 on .NET Framework, where TickCount64
# does not exist - with SilentlyContinue it returned nothing and the field read "uptime=0s" on every
# record (measured 2026-10-09, against "uptime=254s" from the old CIM value). The 32-bit counter
# wraps to negative after ~24.8 days, which the add corrects.
$ms = [long][Environment]::TickCount
if ($ms -lt 0) { $ms += 4294967296 }
$up = [math]::Round($ms / 1000)
# THE DURABLE WRITE COMES FIRST. This task is triggered BY the shutdown (User32 1074) and killed BY
# the same shutdown - measured 2026-10-09, rc=0x8007050B - and it used to do two slow reads before
# writing anything, so a reap cost the record AND left a non-zero result for the death reporter to
# deal with. The line that matters is written with what is already known; the event's own text is an
# enrichment appended afterwards, and losing it costs detail rather than the record.
# RUNS AT BOOT NOW, so it reports the shutdown(s) it has not recorded yet rather than "the newest
# one". The watermark is the EventRecordID it last wrote - monotonic, no clock involved, which
# matters on this guest because its clock flips hours during early boot.
# STATE, NOT A LOG, so it lives in C:\ProgramData\Qubes, never in the log directory. A watermark an
# earlier build left in the log directory is MOVED on first use (one rename); if the move fails it is
# read where it is and deleted after the first successful write here - an upgrade never records the
# same shutdown twice.
$wmDir = 'C:\ProgramData\Qubes'
$wmFile = Join-Path $wmDir 'reboot-audit.last'
$wmOld = Join-Path (Get-QwtLogDir) 'reboot-audit.last'
$wmRead = $wmFile
if (-not (Test-Path -LiteralPath $wmFile) -and (Test-Path -LiteralPath $wmOld)) {
    try {
        New-Item -ItemType Directory -Path $wmDir -Force -ErrorAction Stop | Out-Null
        Move-Item -LiteralPath $wmOld -Destination $wmFile -ErrorAction Stop
    } catch { $wmRead = $wmOld }
}
$wm = 0
try { if (Test-Path -LiteralPath $wmRead) { $wm = [long](Get-Content -LiteralPath $wmRead -Raw).Trim() } } catch { $wm = 0 }
$new = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = $EventId } -MaxEvents 20 |
         Where-Object { [long]$_.RecordId -gt $wm } | Sort-Object { [long]$_.RecordId })
if ($new.Count -eq 0) {
    $null = Write-QwtLogLine I "id=$EventId uptime=${up}s :: (boot pass: no new shutdown record)" -Module 'record-reboot-cause.ps1'
} else {
    foreach ($ev in $new) {
        $msg = ($ev.Message -replace '\s*\r?\n\s*', ' ').Trim()
        $null = Write-QwtLogLine I "id=$EventId uptime=${up}s provider=$($ev.ProviderName) :: $msg" -Module 'record-reboot-cause.ps1'
    }
    try {
        New-Item -ItemType Directory -Path $wmDir -Force -ErrorAction Stop | Out-Null
        Set-Content -LiteralPath $wmFile -Value ([string][long]$new[-1].RecordId) -ErrorAction Stop
        if ($wmRead -ne $wmFile) { Remove-Item -LiteralPath $wmOld -Force -ErrorAction SilentlyContinue }
    } catch { }
}
'@
if ($sinkOk) {
    try {
        Set-Content -Path $recorder -Value $recorderBody -Encoding UTF8 -Force
        Write-Output "ok     recorder written: $recorder"
        $changed++
    } catch {
        Write-Output "FAIL   could not write the recorder: $($_.Exception.Message)"
        $failed++
    }
}

function New-EventTask([string]$Name, [int]$EventId, [string]$Description) {
    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>$Description</Description></RegistrationInfo>
  <!-- BOOT, NOT THE SHUTDOWN EVENT. Measured twice on 2026-10-09: with an EventTrigger on this id
       the task is started BY the shutdown and killed BY the same shutdown, rc=0x8007050B every
       time, because the Task Scheduler service stops while the action is still running. No body can
       be made fast enough to win that, and the requirement is that a task hit by a shutdown
       terminates gracefully rather than being suppressed afterwards.
       It never needed to run then: the record it writes is READ OUT OF THE EVENT LOG, which is
       still there on the next boot. So it runs at boot and picks up whatever shutdown records are
       newer than the last one it recorded. One fewer task for the shutdown to reap. -->
  <Triggers>
    <BootTrigger><Enabled>true</Enabled><Delay>PT20S</Delay></BootTrigger>
  </Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <StartWhenAvailable>true</StartWhenAvailable>
    <ExecutionTimeLimit>PT2M</ExecutionTimeLimit>
    <AllowHardTerminate>true</AllowHardTerminate>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <Priority>4</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -File "$recorder" -EventId $EventId</Arguments>
    </Exec>
  </Actions>
</Task>
"@
    $f = Join-Path $env:TEMP "$Name.xml"
    # Task Scheduler wants UTF-16 for a task XML that declares it.
    [System.IO.File]::WriteAllText($f, $xml, [System.Text.Encoding]::Unicode)
    schtasks /Create /TN $Name /XML "$f" /F 2>&1 | Out-Null
    Remove-Item $f -Force -EA SilentlyContinue
    $q = schtasks /Query /TN $Name 2>&1
    if ($LASTEXITCODE -eq 0) { Write-Output "ok     task '$Name' registered (System event $EventId)"; return $true }
    Write-Output "FAIL   task '$Name' not registered"
    return $false
}

if ($sinkOk) {
    $tasksOk = 0
    if (New-EventTask 'QWT-NG reboot audit 1074' 1074 'QWT-NG: record who initiated a restart, onto the private volume which survives it') { $changed++; $tasksOk++ } else { $failed++ }
    if (New-EventTask 'QWT-NG reboot audit 6008' 6008 'QWT-NG: record that the previous shutdown was unexpected') { $changed++; $tasksOk++ } else { $failed++ }
    if (New-EventTask 'QWT-NG reboot audit 41'   41   'QWT-NG: record a restart without a clean shutdown (kernel power 41)') { $changed++; $tasksOk++ } else { $failed++ }
    # The copies an earlier build wrote, once no task of ours can still point at them: the one in the
    # log directory is a script where only logs belong.
    if ($tasksOk -eq 3) {
        $oldDirs = @('C:\Program Files\Qubes Tools\vmupdate-shim')
        $regLogDir = (Get-ItemProperty 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -Name LogDir -EA SilentlyContinue).LogDir
        if ($regLogDir) { $oldDirs += $regLogDir }
        foreach ($d in $oldDirs) {
            $old = Join-Path $d 'record-reboot-cause.ps1'
            if ((Test-Path -LiteralPath $old) -and $old -ne $recorder) {
                try { Remove-Item -LiteralPath $old -Force -ErrorAction Stop; Write-Output "ok     removed the old recorder copy: $old" }
                catch { Write-Output "WARN   could not remove the old recorder copy $old : $($_.Exception.Message)" }
            }
        }
    }
}

Write-Output ''
Write-Output "=== RESULT === changed=$changed failed=$failed"
if ($failed -gt 0) { exit 2 }
exit 0
