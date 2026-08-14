# Interventional test, run ONLY after wu-do-timer-probe.ps1 identifies the engine.
#
# Candidate causes of a fixed ~4 s refill tick, in the order they are cheap to kill:
#   F1 DO policy never took effect: qubes-windows-update.ps1 writes the DeliveryOptimization
#      policies and then immediately calls Download(). DoSvc reads much of its policy at service
#      start, so the running DoSvc may still be throttling on the DEFAULT background profile.
#      Restarting DoSvc after the write is the fix; if the tick period does not move, F1 is dead.
#   F2 background QoS floor: DOMinBackgroundQoS is the documented knob for "how hard DO pulls from
#      the HTTP source in background mode". The handover's dead levers were all bandwidth CAPS,
#      never the FLOOR.
#
# Every registry value written here is recorded and restored by -Revert. Scoped experiment only.

param(
  [ValidateSet('F1','F2','Revert','Show')][string]$Mode = 'Show',
  [int]$MinQoSKBs = 20000
)
$ErrorActionPreference = 'Continue'
$DO   = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
$save = 'C:\ProgramData\Qubes\wu\do-intervene-backup.json'
function W($s) { Write-Output $s }

function Snapshot {
  $h = @{}
  if (Test-Path $DO) {
    (Get-Item $DO).GetValueNames() | ForEach-Object { $h[$_] = (Get-ItemProperty $DO -Name $_).$_ }
  }
  return $h
}
function ShowState {
  W '=== DO policy (registry) ==='
  if (Test-Path $DO) { Get-ItemProperty $DO | Format-List * | Out-String -Width 200 | Write-Output }
  else { W '(no DeliveryOptimization policy key)' }
  W '=== services ==='
  Get-CimInstance Win32_Service | Where-Object { $_.Name -in @('DoSvc','BITS','wuauserv','UsoSvc') } |
    Select-Object Name,State,ProcessId,StartMode | Format-Table -AutoSize | Out-String -Width 200 | Write-Output
  W '=== DoSvc uptime (policy read at start; a long uptime means our writes were never re-read) ==='
  try {
    $p = (Get-CimInstance Win32_Service -Filter "Name='DoSvc'").ProcessId
    if ($p -gt 0) {
      $proc = Get-Process -Id $p -ErrorAction SilentlyContinue
      W ("DoSvc pid=$p started=" + $proc.StartTime.ToString('HH:mm:ss') +
         " age_s=" + [int]((Get-Date) - $proc.StartTime).TotalSeconds)
    } else { W 'DoSvc not running' }
  } catch { W "DoSvc uptime unavailable: $_" }
}

switch ($Mode) {
  'Show' { ShowState }

  'F1' {
    if (-not (Test-Path $save)) { Snapshot | ConvertTo-Json | Out-File $save -Encoding UTF8 }
    W 'F1: restarting DoSvc so the already-written DO policy is actually re-read'
    ShowState
    & sc.exe stop DoSvc  | Out-Null
    Start-Sleep -Seconds 3
    & sc.exe start DoSvc | Out-Null
    Start-Sleep -Seconds 3
    W '--- after restart ---'
    ShowState
  }

  'F2' {
    if (-not (Test-Path $save)) { Snapshot | ConvertTo-Json | Out-File $save -Encoding UTF8 }
    W "F2: setting the background QoS FLOOR to $MinQoSKBs KB/s (every dead lever so far was a CAP)"
    New-Item -Path $DO -Force | Out-Null
    New-ItemProperty -Path $DO -Name 'DOMinBackgroundQoS' -Value $MinQoSKBs -PropertyType DWord -Force | Out-Null
    & sc.exe stop DoSvc  | Out-Null
    Start-Sleep -Seconds 3
    & sc.exe start DoSvc | Out-Null
    Start-Sleep -Seconds 3
    ShowState
  }

  'Revert' {
    if (-not (Test-Path $save)) { W 'no backup to revert -- refusing to guess'; exit 1 }
    $h = Get-Content $save -Raw | ConvertFrom-Json
    W 'reverting DO policy to the recorded snapshot'
    if (Test-Path $DO) {
      (Get-Item $DO).GetValueNames() | ForEach-Object {
        if (-not ($h.PSObject.Properties.Name -contains $_)) {
          Remove-ItemProperty -Path $DO -Name $_ -Force -ErrorAction SilentlyContinue
          W "  removed $_"
        }
      }
    }
    $h.PSObject.Properties | ForEach-Object {
      Set-ItemProperty -Path $DO -Name $_.Name -Value $_.Value -Force -ErrorAction SilentlyContinue
      W ("  restored " + $_.Name + " = " + $_.Value)
    }
    & sc.exe stop DoSvc  | Out-Null
    Start-Sleep -Seconds 2
    & sc.exe start DoSvc | Out-Null
    ShowState
  }
}
W '=== DONE ==='
