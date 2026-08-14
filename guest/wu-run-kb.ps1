<#
.SYNOPSIS
  Run a full update pass for ONE KB, detached, reporting through a file.

.DESCRIPTION
  Two lessons are baked in.

  DETACHED, ALWAYS. The previous attempt ran the pass through `pushrun`, i.e. over a live qrexec
  connection. DISM work on a multi-gigabyte package starved the guest, qrexec timed out, and the
  experiment died with the connection - producing no evidence at all. Here the work runs in a
  SYSTEM scheduled task and everything it learns lands in a file, so guest unresponsiveness costs
  a poll, not the result.

  ONE KB AT A TIME. The 24H2 failure was a batch: a superseded package was fed to CBS, then the
  cumulative rolled back at boot, and nothing could be attributed to either. -OnlyKb makes each
  package its own experiment.

  Records the build before the pass so the ONLY acceptance test - did CurrentBuild.UBR move - can
  be evaluated after the reboot without trusting any exit code. DISM rc=3010 means staged, not
  installed; that distinction is what made every earlier "success" unreliable.
#>
param(
  [Parameter(Mandatory=$true)][string]$Kb,
  [string]$TaskName = 'QwtWuRunKb'
)
$ErrorActionPreference = 'Continue'
$bin   = 'C:\Program Files\Qubes Tools\bin'
$agent = Join-Path $bin 'qubes-windows-update.ps1'
$relay = Join-Path $bin 'qubes-updates-relay.exe'
$wu    = 'C:\ProgramData\Qubes\wu'
$out   = Join-Path $wu ("run-$Kb.txt")
New-Item -ItemType Directory -Force $wu | Out-Null
Remove-Item -LiteralPath $out -Force -EA SilentlyContinue

$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
Write-Output '=== RESULT ==='
Write-Output ("build_before = {0}.{1}" -f $cv.CurrentBuild, $cv.UBR)

$worker = @"
`$ErrorActionPreference = 'Continue'
function W(`$m){ Add-Content -LiteralPath '$out' -Value ((Get-Date -Format 'HH:mm:ss') + ' ' + `$m) }
`$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
W ("build_before=" + `$cv.CurrentBuild + "." + `$cv.UBR)
`$t0 = Get-Date
& '$agent' -Action full -OnlyKb '$Kb' -RelayExe '$relay' *>&1 |
    ForEach-Object { Add-Content -LiteralPath '$out' -Value `$_ }
W ("agent_exit=" + `$LASTEXITCODE + " minutes=" + [math]::Round(((Get-Date)-`$t0).TotalMinutes,1))
`$cbs = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing'
W ("cbs_reboot_pending=" + (Test-Path (Join-Path `$cbs 'RebootPending')))
`$inc = @(Get-ChildItem (Join-Path `$cbs 'SessionsPending') -EA SilentlyContinue |
         Where-Object { (Get-ItemProperty `$_.PSPath -EA SilentlyContinue).Complete -ne 1 })
W ("cbs_incomplete_sessions=" + `$inc.Count)
`$cv2 = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
W ("build_after_noreboot=" + `$cv2.CurrentBuild + "." + `$cv2.UBR)
W 'DONE'
"@
$wp = Join-Path $wu "run-$Kb-worker.ps1"
Set-Content -LiteralPath $wp -Value $worker -Encoding ASCII

$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>QWT-NG: single-KB update pass ($Kb), detached</Description></RegistrationInfo>
  <Triggers />
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <ExecutionTimeLimit>PT24H</ExecutionTimeLimit>
    <AllowHardTerminate>true</AllowHardTerminate>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
  </Settings>
  <Actions Context="Author"><Exec><Command>powershell.exe</Command><Arguments>-NoProfile -ExecutionPolicy Bypass -File "$wp"</Arguments></Exec></Actions>
</Task>
"@
$f = Join-Path $env:TEMP "$TaskName.xml"
[IO.File]::WriteAllText($f, $xml, [Text.Encoding]::Unicode)
& schtasks /create /tn $TaskName /xml "$f" /f | Out-Null
& schtasks /run /tn $TaskName | Out-Null
Write-Output ("armed {0} for {1} (rc {2}); poll {3}" -f $TaskName, $Kb, $LASTEXITCODE, $out)
