# ITERATION 2, corrected method.
#
# What went wrong last time: the test ran through pushrun, i.e. over a live qrexec connection, and
# DISM work on a 4.8 GB WIM-based .msu starved the guest until qrexec timed out - so the
# experiment died with the connection and produced nothing. Servicing work must run DETACHED and
# report through a FILE, so guest unresponsiveness costs a poll, not the result.
#
# Also checks first that the earlier kill did not leave CBS mid-transaction. Testing "does the
# cumulative install cleanly" on a dirty servicing state would be unattributable.
$ErrorActionPreference = 'Continue'
$out = 'C:\ProgramData\Qubes\wu\lcu-alone-result.txt'
$cbs = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing'

Write-Output '=== RESULT ==='
# CORRECTED 2026-08-14. The previous rule here was `Test-Path SessionsPending` -> dirty, which is
# wrong: that key exists on every healthy Windows and holds COMPLETED session history. Measured on
# a virgin win11-24h2 clone (guest/wu-cbs-subkeys.ps1): 5 subkeys, every one Complete=1, Exclusive=0,
# no pending.xml, DISM /CheckHealth clean. The old rule would have refused to run on a pristine image
# and it produced a false "DIRTY" verdict that was briefly mistaken for a cause of the 24H2 rollback.
# What actually indicates an interrupted transaction: a session that never reached Complete=1, an
# exclusive session still held, or a poqexec plan staged on disk.
$incomplete = @(Get-ChildItem (Join-Path $cbs 'SessionsPending') -EA SilentlyContinue |
                Where-Object { (Get-ItemProperty $_.PSPath -EA SilentlyContinue).Complete -ne 1 })
$exclusive    = [int](Get-ItemProperty (Join-Path $cbs 'SessionsPending') -Name Exclusive -EA SilentlyContinue).Exclusive
$rebootPending = Test-Path (Join-Path $cbs 'RebootPending')
$pendingXml    = Test-Path 'C:\Windows\WinSxS\pending.xml'
Write-Output ("cbs_incomplete_sessions = {0}" -f $incomplete.Count)
Write-Output ("cbs_exclusive           = {0}" -f $exclusive)
Write-Output ("cbs_reboot_pending      = {0}   (staged-awaiting-reboot, NOT corruption)" -f $rebootPending)
Write-Output ("winsxs_pending_xml      = {0}" -f $pendingXml)
if ($incomplete.Count -gt 0 -or $exclusive -ne 0 -or $pendingXml) {
    foreach ($s in $incomplete) { Write-Output ("   incomplete: " + $s.PSChildName) }
    Write-Output 'DIRTY: a servicing transaction is genuinely mid-flight. REBUILD the template'
    Write-Output 'instead of testing on this image - the result would not be attributable.'
    exit 2
}

$lcu = Get-ChildItem 'C:\ProgramData\Qubes\wu' -Recurse -Filter '*kb5121003*.msu' -EA SilentlyContinue |
       Select-Object -First 1
if (-not $lcu) { Write-Output 'cumulative .msu not cached - nothing to test'; exit 1 }
Write-Output ("package = {0} ({1:N0} bytes)" -f $lcu.Name, $lcu.Length)

# The detached worker: everything it learns goes to $out, nothing depends on a live connection.
$worker = @'
$out = "C:\ProgramData\Qubes\wu\lcu-alone-result.txt"
function W($m) { Add-Content -LiteralPath $out -Value ((Get-Date -Format "HH:mm:ss") + " " + $m) }
Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
$cv = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
W ("build_before=" + $cv.CurrentBuild + "." + $cv.UBR)
$lcu = Get-ChildItem "C:\ProgramData\Qubes\wu" -Recurse -Filter "*kb5121003*.msu" | Select-Object -First 1
W ("package=" + $lcu.Name)
$t0 = Get-Date
& DISM /Online /Add-Package /PackagePath:"$($lcu.FullName)" /NoRestart /Quiet /LogPath:"C:\ProgramData\Qubes\wu\dism-lcu-alone.log" | Out-Null
W ("dism_rc=" + $LASTEXITCODE + " minutes=" + [math]::Round(((Get-Date)-$t0).TotalMinutes,1))
W ("cbs_reboot_pending=" + (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"))
$pkgRoot = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages"
$hit = @(Get-ChildItem $pkgRoot -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match "5121003" })
W ("cbs_packages_matching=" + $hit.Count)
foreach ($h in ($hit | Select-Object -First 3)) {
  W ("  " + $h.PSChildName + " CurrentState=" + (Get-ItemProperty $h.PSPath -ErrorAction SilentlyContinue).CurrentState)
}
W "DONE"
'@
$workerPath = 'C:\ProgramData\Qubes\wu\lcu-alone-worker.ps1'
Set-Content -LiteralPath $workerPath -Value $worker -Encoding ASCII

$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>QWT-NG diagnostic: install the cumulative alone, detached</Description></RegistrationInfo>
  <Triggers />
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <ExecutionTimeLimit>PT2H</ExecutionTimeLimit>
    <AllowHardTerminate>true</AllowHardTerminate>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
  </Settings>
  <Actions Context="Author"><Exec><Command>powershell.exe</Command><Arguments>-NoProfile -ExecutionPolicy Bypass -File "$workerPath"</Arguments></Exec></Actions>
</Task>
"@
$f = Join-Path $env:TEMP 'lcu-alone.xml'
[IO.File]::WriteAllText($f, $xml, [Text.Encoding]::Unicode)
& schtasks /create /tn QwtLcuAlone /xml "$f" /f | Out-Null
& schtasks /run /tn QwtLcuAlone | Out-Null
Write-Output ("armed_detached_task = rc " + $LASTEXITCODE)
Write-Output ("poll: type " + $out)
