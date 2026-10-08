# install-clock-sync.ps1 - register the boot-time clock pull as a SYSTEM task, idempotently.
#
# The PUSH half (dom0 -> qubes.SetDateTime -> set-time.ps1) has always existed. This is the PULL
# half at startup, which nothing ever ran: update-time.bat has been in the tree the whole time and
# is called by nothing but qubes.SuspendPostAll. A guest whose clock was wrong stayed wrong.
#
# Measured 2026-10-08 on win11r-logvol: three hours ahead of the host with its zone set to UTC, so
# every --since log window on it silently admitted three hours of older lines.
#
# The task is registered from XML for the same reason install-reboot-audit.ps1 is: schtasks' command
# line cannot express a boot trigger plus SYSTEM plus the settings together without quoting that
# breaks differently on every locale, and this product ships German guests.
param(
    [switch]$Remove
)
$ErrorActionPreference = 'Stop'
$TaskName = 'QwtClockSync'

function Result($ok, $detail) {
    Write-Output '=== RESULT ==='
    @{ ok = $ok; task = $TaskName; detail = $detail } | ConvertTo-Json -Compress
    if (-not $ok) { exit 1 }
    exit 0
}

if ($Remove) {
    & schtasks.exe /delete /tn $TaskName /f 2>&1 | Out-Null
    Result $true 'removed'
}

$tools = $env:QUBES_TOOLS
if (-not $tools) {
    try { $tools = (Get-ItemProperty 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -ErrorAction Stop).InstallDir } catch { }
}
if (-not $tools -or -not (Test-Path -LiteralPath $tools)) { Result $false 'QUBES_TOOLS unset and InstallDir unreadable' }

# THE ACTION PATH MUST OUTLIVE THE INSTALL, so this script INSTALLS the puller before registering
# anything. It runs from the setup payload, a temporary directory that is gone by the first boot the
# task fires on: resolving the puller beside THIS file (my first version) registered a task pointing
# at a path that no longer exists, and the clock would have stayed wrong with a task that "registered
# fine". install-reboot-audit.ps1 solves the same problem the same way - it materialises its recorder
# into the Qubes Tools tree rather than trusting the payload to still be there.
# The destination is the directory set-time.ps1 lives in, which is what the puller calls.
$dest = Join-Path $tools 'qubes-rpc-services'
$puller = Join-Path $dest 'sync-clock-from-dom0.ps1'
$staged = Join-Path $PSScriptRoot 'sync-clock-from-dom0.ps1'
if (Test-Path -LiteralPath $staged) {
    try {
        if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Path $dest -Force -ErrorAction Stop | Out-Null }
        Copy-Item -LiteralPath $staged -Destination $puller -Force -ErrorAction Stop
    } catch {
        Result $false "could not install the puller to $puller : $($_.Exception.Message)"
    }
}
if (-not (Test-Path -LiteralPath $puller)) { Result $false "sync-clock-from-dom0.ps1 is neither staged beside this script nor already installed at $puller (helpers ship only if staged)" }

# BootTrigger with a short delay: qrexec is not up the instant the system starts, and the puller's
# own bounded wait covers the rest. ExecutionTimeLimit is above that wait, so the task is never
# killed mid-pull and reported as a terminated instance.
$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Qubes Windows Tools: pull the clock from dom0 at every boot</Description></RegistrationInfo>
  <Triggers>
    <BootTrigger><Enabled>true</Enabled><Delay>PT15S</Delay></BootTrigger>
  </Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <StartWhenAvailable>true</StartWhenAvailable>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <AllowHardTerminate>true</AllowHardTerminate>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <Priority>4</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -ExecutionPolicy Bypass -NonInteractive -File "$puller"</Arguments>
    </Exec>
  </Actions>
</Task>
"@

$tmp = Join-Path $env:TEMP "$TaskName.xml"
# UTF-16 with a BOM: schtasks /xml refuses anything else, silently on some builds.
[IO.File]::WriteAllText($tmp, $xml, [Text.UnicodeEncoding]::new($false, $true))
$out = & schtasks.exe /create /tn $TaskName /xml $tmp /f 2>&1
$rc = $LASTEXITCODE
Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
if ($rc -ne 0) { Result $false "schtasks /create rc=$rc : $(($out | Out-String).Trim())" }

# ASSERT IT IS THERE, and that its command line is the one intended - a registration that "succeeded"
# and registered something else is the failure mode this project has paid for before.
$q = & schtasks.exe /query /tn $TaskName /xml ONE 2>&1
if ($LASTEXITCODE -ne 0) { Result $false "registered but not queryable: $(($q | Out-String).Trim())" }
$qs = ($q | Out-String)
if ($qs -notmatch 'BootTrigger') { Result $false 'registered without a BootTrigger' }
if ($qs -notmatch 'sync-clock-from-dom0\.ps1') { Result $false 'registered with the wrong action' }
if ($qs -notmatch 'S-1-5-18') { Result $false 'registered without the SYSTEM principal' }
Result $true "registered with a BootTrigger as SYSTEM, action $puller"
