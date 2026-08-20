# Add -Scheduled to an ALREADY-REGISTERED QubesWindowsUpdateScan task.
# New installs get it from install-updater-agent.ps1; guests installed before that keep a task whose
# command line lacks the switch, which leaves the scan debounce inert on exactly the machines that
# have been running longest. Idempotent: re-running changes nothing.
# Only ever touches the SCAN task - Run/Download must never carry the switch.
$ErrorActionPreference = 'Continue'
$res = [ordered]@{}
$t = Get-ScheduledTask -TaskName 'QubesWindowsUpdateScan' -EA SilentlyContinue
if (-not $t) { $res['error']='QubesWindowsUpdateScan not registered'; $res['ok']=$false
               Write-Output ("=== RESULT === " + ($res | ConvertTo-Json -Compress)); exit 1 }
$act = @($t.Actions)[0]
$res['before'] = $act.Arguments
if ($act.Arguments -match '\-Scheduled\b') {
  $res['changed'] = $false; $res['after'] = $act.Arguments; $res['ok'] = $true
} else {
  # insert right after "-Action scan" so the line stays readable
  $new = $act.Arguments -replace '(-Action\s+scan)', '$1 -Scheduled'
  if ($new -eq $act.Arguments) { $new = $act.Arguments + ' -Scheduled' }
  $newAction = New-ScheduledTaskAction -Execute $act.Execute -Argument $new
  try {
    Set-ScheduledTask -TaskName 'QubesWindowsUpdateScan' -Action $newAction -EA Stop | Out-Null
    $chk = @((Get-ScheduledTask -TaskName 'QubesWindowsUpdateScan').Actions)[0].Arguments
    $res['after'] = $chk
    $res['changed'] = $true
    $res['ok'] = [bool]($chk -match '\-Scheduled\b')
  } catch { $res['error'] = $_.Exception.Message; $res['ok'] = $false }
}
# and prove the sibling tasks were NOT touched
foreach ($n in 'QubesWindowsUpdateRun','QubesWindowsUpdateDownload') {
  $s = Get-ScheduledTask -TaskName $n -EA SilentlyContinue
  if ($s) { $res[$n + '_has_scheduled'] = [bool](@($s.Actions)[0].Arguments -match '\-Scheduled\b') }
}
Write-Output ("=== RESULT === " + ($res | ConvertTo-Json -Compress))
