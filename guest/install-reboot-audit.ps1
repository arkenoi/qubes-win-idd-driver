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
$ev = Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = $EventId } -MaxEvents 1
$stamp = (Get-Date).ToString('yyyyMMdd.HHmmss')
$up = [math]::Round(((Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime).TotalSeconds)
if ($ev) {
    $msg = ($ev.Message -replace '\s*\r?\n\s*', ' ').Trim()
    Add-Content -Path $out -Value "[$stamp] id=$EventId uptime=${up}s provider=$($ev.ProviderName) :: $msg"
} else {
    Add-Content -Path $out -Value "[$stamp] id=$EventId uptime=${up}s :: (triggered, but the record could not be read back)"
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
  <Triggers>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="System"&gt;&lt;Select Path="System"&gt;*[System[EventID=$EventId]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
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
