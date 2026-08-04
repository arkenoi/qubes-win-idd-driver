# Post-boot half of one A/B side. Assumes the intended gui-agent.exe is already in place
# and that the qube has just been cold-booted, so the agent under test is the one the
# gui-daemon connected to at boot. Restarting gui-agent in place is NOT an option: it
# reliably kills gui-daemon, which never returns (FINDINGS 2026-08-04).
param([string]$Which = 'new')

$ErrorActionPreference = 'Stop'
$bin      = 'C:\Program Files\Qubes Tools\bin'
$incoming = 'C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
$logdir   = 'C:\Program Files\Qubes Tools\log'
$expect   = if ($Which -eq 'orig') { '4B4CE2B1C5441C88' } else { '4DA9FE967A8A1012' }

$h = (Get-FileHash (Join-Path $bin 'gui-agent.exe')).Hash.Substring(0,16)
if ($h -ne $expect) { Write-Output "RESULT which=$Which status=FAIL reason=wrong_binary installed=$h expect=$expect"; exit 1 }
$p = Get-Process gui-agent -ErrorAction SilentlyContinue
if (-not $p) { Write-Output "RESULT which=$Which status=FAIL reason=no_agent_process"; exit 1 }

# the agent instance that came up with this boot
$log = Get-ChildItem $logdir -Filter 'gui-agent-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1

# --- scene ------------------------------------------------------------------------
Get-Process chromerepro -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 1
Start-Process (Join-Path $incoming 'chromerepro.exe') -ArgumentList '--mso'
Start-Sleep -Seconds 6
if (-not (Get-Process chromerepro -ErrorAction SilentlyContinue)) {
  Write-Output "RESULT which=$Which status=FAIL reason=chromerepro_not_running"; exit 1
}

Start-Process (Join-Path $incoming 'dump-windows.exe') -WorkingDirectory 'C:\Users\user'
Start-Sleep -Seconds 3
Get-Process dump-windows -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

$vis  = Get-Content 'C:\Users\user\windows-visible.txt'
$mark = ($vis | Select-String -Pattern '^###' | Select-Object -Last 1).LineNumber
$snap = $vis[($mark-1)..($vis.Count-1)]

$strips = @(); $mains = @()
foreach ($line in $snap) {
  if ($line -match '^(0x[0-9a-f]+): .*? "([^"]*)"') {
    if ($matches[2] -eq 'MSO_BORDEREFFECT_WINDOW_CLASS') { $strips += $matches[1] }
    if ($matches[2] -eq 'QubesChromeReproMain')          { $mains  += $matches[1] }
  }
}
$strips = @($strips | Sort-Object -Unique)
$mains  = @($mains  | Sort-Object -Unique)

$lines  = Get-Content $log.FullName
$mapped = @()
foreach ($l in $lines) {
  if ($l -match 'SendWindowMap: Mapping window (0x[0-9a-f]+)') { $mapped += $matches[1] }
}
$mapped = @($mapped | Sort-Object -Unique)

$stripsMapped = @($strips | Where-Object { $mapped -contains $_ })
$mainMapped   = @($mains  | Where-Object { $mapped -contains $_ })

if ($strips.Count -eq 0)     { Write-Output "RESULT which=$Which status=FAIL reason=no_strips_in_scene"; exit 1 }
if ($mains.Count  -eq 0)     { Write-Output "RESULT which=$Which status=FAIL reason=no_main_window";    exit 1 }
if ($mainMapped.Count -eq 0) {
  $awaiting = @($lines | Select-String -Pattern 'Awaiting for a vchan client').Count
  Write-Output ("RESULT which=$Which status=FAIL reason=main_window_not_mapped total_mapped=" +
                $mapped.Count + " awaiting_vchan=" + $awaiting + " (gui-daemon gone)"); exit 1
}

Write-Output ("STRIPS_PRESENT=" + $strips.Count + " [" + ($strips -join ',') + "]")
Write-Output ("STRIPS_MAPPED="  + $stripsMapped.Count + " [" + ($stripsMapped -join ',') + "]")
Write-Output ("MAIN_MAPPED="    + $mainMapped.Count + " TOTAL_MAPPED=" + $mapped.Count)
Write-Output ("LOG=" + $log.Name + " AGENT_PID=" + $p.Id)
Write-Output ("RESULT which=$Which status=OK installed=$h strips_present=" + $strips.Count +
              " strips_mapped=" + $stripsMapped.Count)
