# Post-boot half of one A/B side for agent 66fc670 (never re-home an owned popup whose
# GW_OWNER is untracked). Assumes the intended gui-agent.exe is already installed and the
# qube has just cold-booted, so the agent under test is the one gui-daemon connected to.
#
# Scene: chromerepro --orphan = main frame (tracked) + hidden owner (never tracked, dropped
# on !IsVisible by every build) + a popup owned by that hidden owner, sitting inside the
# frame. Pre-fix, SynthQualifies() falls through to the same-process fallback and adopts the
# popup into the frame, logging QGAPROTO,msg=SYNTH,hwnd=<popup>,owner=<frame>. Post-fix the
# popup is refused and no such line appears.
#
# NOTE: the control MUST be agent aaa8c37, not stock QWT - stock has no composite synthesis
# at all (fork commit 0a334c1) and would emit no SYNTH either way, a check that cannot fail.
param([string]$Which = 'new', [string]$ExpectHash = '')

$ErrorActionPreference = 'Stop'
$bin      = 'C:\Program Files\Qubes Tools\bin'
$incoming = 'C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
$logdir   = 'C:\Program Files\Qubes Tools\log'

$h = (Get-FileHash (Join-Path $bin 'gui-agent.exe')).Hash.Substring(0,16)
if ($ExpectHash -and $h -ne $ExpectHash) {
  Write-Output "RESULT which=$Which status=FAIL reason=wrong_binary installed=$h expect=$ExpectHash"; exit 1
}
$p = Get-Process gui-agent -ErrorAction SilentlyContinue
if (-not $p) { Write-Output "RESULT which=$Which status=FAIL reason=no_agent_process"; exit 1 }

$log = Get-ChildItem $logdir -Filter 'gui-agent-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1

# HARD PRECONDITION. AddWindow() gates synthesis on PwEnabled():
#     if (PwEnabled() && SynthQualifies(entry, &synthOwner))
# so with PerWindowCapture=0 no window is ever synthesized, both sides report zero SYNTH,
# and the comparison proves nothing. Fail loudly rather than measure a disabled code path.
$pwc = (Get-ItemProperty 'HKLM:\Software\Invisible Things Lab\Qubes Tools').PerWindowCapture
$pwOff = @(Get-Content $log.FullName | Select-String -Pattern 'per-window capture disabled by config').Count
if ($pwc -ne 1 -or $pwOff -gt 0) {
  Write-Output ("RESULT which=$Which status=FAIL reason=per_window_capture_off PerWindowCapture=" +
                $pwc + " log_says_disabled=" + $pwOff + " (synthesis cannot run; nothing to measure)")
  exit 1
}

Get-Process chromerepro -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 1
Start-Process (Join-Path $incoming 'chromerepro.exe') -ArgumentList '--orphan'
Start-Sleep -Seconds 8
if (-not (Get-Process chromerepro -ErrorAction SilentlyContinue)) {
  Write-Output "RESULT which=$Which status=FAIL reason=chromerepro_not_running"; exit 1
}

Start-Process (Join-Path $incoming 'dump-windows.exe') -WorkingDirectory 'C:\Users\user'
Start-Sleep -Seconds 3
Get-Process dump-windows -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

# Scan every snapshot in the file, not just the last one. dump-windows writes a "###"
# header and then enumerates, so killing it can leave a final EMPTY snapshot - which read
# as "the scene is missing" and failed a run that was actually fine. The scene is static
# across a 3 s capture, so scanning the whole file and deduping by HWND is both safe and
# race-free. (dump-windows truncates the file on each run, so nothing here is stale.)
$vis = Get-Content 'C:\Users\user\windows-visible.txt'

$orphans = @(); $mains = @()
foreach ($line in $vis) {
  if ($line -match '^(0x[0-9a-f]+): .*? "([^"]*)"') {
    if ($matches[2] -eq 'QubesChromeReproOrphan') { $orphans += $matches[1] }
    if ($matches[2] -eq 'QubesChromeReproMain')   { $mains   += $matches[1] }
  }
}
# only the VISIBLE orphan popup shows up in windows-visible.txt; the hidden owner does not
$orphans = @($orphans | Sort-Object -Unique)
$mains   = @($mains   | Sort-Object -Unique)

$lines  = Get-Content $log.FullName
$mapped = @(); $synth = @()
foreach ($l in $lines) {
  if ($l -match 'SendWindowMap: Mapping window (0x[0-9a-f]+)') { $mapped += $matches[1] }
  if ($l -match 'msg=SYNTH,hwnd=(0x[0-9a-f]+),owner=(0x[0-9a-f]+)') {
    $synth += ($matches[1] + '->' + $matches[2])
  }
}
$mapped = @($mapped | Sort-Object -Unique)
$synth  = @($synth  | Sort-Object -Unique)

if ($orphans.Count -eq 0) { Write-Output "RESULT which=$Which status=FAIL reason=no_orphan_popup_in_scene"; exit 1 }
if ($mains.Count   -eq 0) { Write-Output "RESULT which=$Which status=FAIL reason=no_main_window";           exit 1 }

# positive control: without a live gui-daemon the agent announces nothing and "no SYNTH"
# would be indistinguishable from the fix working
$mainMapped = @($mains | Where-Object { $mapped -contains $_ })
if ($mainMapped.Count -eq 0) {
  $awaiting = @($lines | Select-String -Pattern 'Awaiting for a vchan client').Count
  Write-Output ("RESULT which=$Which status=FAIL reason=main_window_not_mapped total_mapped=" +
                $mapped.Count + " awaiting_vchan=" + $awaiting + " (gui-daemon gone)"); exit 1
}

# did the orphan popup get adopted by anything?
$orphanSynth = @($synth | Where-Object { $orphans -contains ($_ -split '->')[0] })
# ...and specifically adopted INTO the main frame, which is the defect's signature
$adoptedByMain = @($orphanSynth | Where-Object { $mains -contains ($_ -split '->')[1] })

Write-Output ("ORPHAN_PRESENT=" + $orphans.Count + " [" + ($orphans -join ',') + "]")
Write-Output ("MAIN=" + ($mains -join ',') + " MAIN_MAPPED=" + $mainMapped.Count)
Write-Output ("SYNTH_ALL=" + $synth.Count + " [" + ($synth -join ' ') + "]")
Write-Output ("ORPHAN_SYNTH=" + $orphanSynth.Count + " ADOPTED_BY_MAIN=" + $adoptedByMain.Count)
# Second, independent signal running the OPPOSITE way: a synthesized popup is painted into
# its owner and never announced, so the control should show it adopted-but-unmapped, while
# the fix refuses synthesis and announces it as an ordinary window. If both counts move the
# same way, something other than the fix is driving them.
$orphanMapped = @($orphans | Where-Object { $mapped -contains $_ })
Write-Output ("ORPHAN_MAPPED=" + $orphanMapped.Count)
Write-Output ("LOG=" + $log.Name + " AGENT_PID=" + $p.Id)
Write-Output ("RESULT which=$Which status=OK installed=$h orphan_synth=" + $orphanSynth.Count +
              " adopted_by_main=" + $adoptedByMain.Count + " orphan_mapped=" + $orphanMapped.Count)
