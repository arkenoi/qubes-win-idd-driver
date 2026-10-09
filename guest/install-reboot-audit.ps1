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
# capture the record AT THE MOMENT it is written, into Q:\ (the private volume, which persists).
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

# The private volume is where a Windows Tools guest keeps its logs (LogDir); fall back to
# C:\Users, which MoveUsers also places on the private volume.
$logDir = (Get-ItemProperty 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -Name LogDir -EA SilentlyContinue).LogDir
if (-not $logDir -or -not (Test-Path (Split-Path $logDir -Qualifier) -EA SilentlyContinue)) {
    $logDir = 'C:\Users\Public\Documents\Qubes Logs'
}
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$auditLog = Join-Path $logDir 'reboot-audit.log'
Write-Output "info   audit log: $auditLog"

$scriptDir = 'C:\Program Files\Qubes Tools\vmupdate-shim'
if (-not (Test-Path $scriptDir)) { $scriptDir = $logDir }
$recorder = Join-Path $scriptDir 'record-reboot-cause.ps1'

# The recorder: pull the triggering record itself, not a summary, and append it verbatim.
$recorderBody = @'
param([int]$EventId = 1074)
$ErrorActionPreference = 'SilentlyContinue'
$logDir = (Get-ItemProperty 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -Name LogDir).LogDir
if (-not $logDir) { $logDir = 'C:\Users\Public\Documents\Qubes Logs' }
$out = Join-Path $logDir 'reboot-audit.log'
$stamp = (Get-Date).ToString('yyyyMMdd.HHmmss')
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
$wmFile = Join-Path $logDir 'reboot-audit.last'
$wm = 0
try { if (Test-Path -LiteralPath $wmFile) { $wm = [long](Get-Content -LiteralPath $wmFile -Raw).Trim() } } catch { $wm = 0 }
$new = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = $EventId } -MaxEvents 20 |
         Where-Object { [long]$_.RecordId -gt $wm } | Sort-Object { [long]$_.RecordId })
if ($new.Count -eq 0) {
    Add-Content -Path $out -Value "[$stamp] id=$EventId uptime=${up}s :: (boot pass: no new shutdown record)"
} else {
    foreach ($ev in $new) {
        $msg = ($ev.Message -replace '\s*\r?\n\s*', ' ').Trim()
        Add-Content -Path $out -Value "[$stamp] id=$EventId uptime=${up}s provider=$($ev.ProviderName) :: $msg"
    }
    try { Set-Content -Path $wmFile -Value ([string][long]$new[-1].RecordId) -EA SilentlyContinue } catch { }
}
'@
try {
    Set-Content -Path $recorder -Value $recorderBody -Encoding UTF8 -Force
    Write-Output "ok     recorder written: $recorder"
    $changed++
} catch {
    Write-Output "FAIL   could not write the recorder: $($_.Exception.Message)"
    $failed++
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

if (New-EventTask 'QWT-NG reboot audit 1074' 1074 'QWT-NG: record who initiated a restart, onto the private volume which survives it') { $changed++ } else { $failed++ }
if (New-EventTask 'QWT-NG reboot audit 6008' 6008 'QWT-NG: record that the previous shutdown was unexpected') { $changed++ } else { $failed++ }
if (New-EventTask 'QWT-NG reboot audit 41'   41   'QWT-NG: record a restart without a clean shutdown (kernel power 41)') { $changed++ } else { $failed++ }

Write-Output ''
Write-Output "=== RESULT === changed=$changed failed=$failed"
if ($failed -gt 0) { exit 2 }
exit 0
