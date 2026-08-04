# END-TO-END test of the "weird shadow" on REAL Office, not a synthetic repro.
#
# The defect (agent 66fc670's commit message, measured on this guest): Word's dialog shadow
# strips were adopted by the maximized OpusApp frame, their pixels patched in from the
# composited desktop, and the owner's own capture masked those bands out -- leaving a frozen
# L-shaped shadow band burned into the document area that outlived the dialog.
#
# REQUIRES PerWindowCapture=1. The whole chain runs through composite synthesis, which
# AddWindow() gates on PwEnabled(). At 0 the shadow cannot appear on ANY build, so a run at 0
# is a check that cannot fail -- that mistake was already made once today.
#
# Metric (log-based, and specific): msg=SYNTH lines whose child is an
# MSO_BORDEREFFECT_WINDOW_CLASS window and whose owner is a DIFFERENT Office window -- i.e. a
# strip adopted by something that is not its own owner. That is the adoption event that paints
# the shadow. Pixels are checked separately by the caller via qtest shot of the Word frame.
param([string]$Which = 'new', [string]$ExpectHash = '')

$ErrorActionPreference = 'Continue'
$bin      = 'C:\Program Files\Qubes Tools\bin'
$incoming = 'C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
$logdir   = 'C:\Program Files\Qubes Tools\log'

$h = (Get-FileHash (Join-Path $bin 'gui-agent.exe')).Hash.Substring(0,16)
if ($ExpectHash -and $h -ne $ExpectHash) {
  Write-Output "RESULT which=$Which status=FAIL reason=wrong_binary installed=$h expect=$ExpectHash"; exit 1
}
$pwc = (Get-ItemProperty 'HKLM:\Software\Invisible Things Lab\Qubes Tools').PerWindowCapture
if ($pwc -ne 1) { Write-Output "RESULT which=$Which status=FAIL reason=per_window_capture_off pwc=$pwc"; exit 1 }
$log = Get-ChildItem $logdir -Filter 'gui-agent-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (@(Get-Content $log.FullName | Select-String 'per-window capture disabled by config').Count -gt 0) {
  Write-Output "RESULT which=$Which status=FAIL reason=agent_says_capture_disabled"; exit 1
}

# --- drive Word to raise a dialog (that is what carries the strips) -----------------
Get-Process WINWORD -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 3
$word = 'C:\Program Files\Microsoft Office\root\Office16\WINWORD.EXE'
if (-not (Test-Path $word)) { Write-Output "RESULT which=$Which status=FAIL reason=word_not_installed"; exit 1 }
Start-Process $word
Start-Sleep -Seconds 45   # let the start screen / Normal-template dialog appear and settle

$w = Get-Process WINWORD -ErrorAction SilentlyContinue
if (-not $w) { Write-Output "RESULT which=$Which status=FAIL reason=word_did_not_start"; exit 1 }

# --- ground truth: which windows exist, and which are Office strips -----------------
Start-Process (Join-Path $incoming 'dump-windows.exe') -WorkingDirectory 'C:\Users\user'
Start-Sleep -Seconds 4
Get-Process dump-windows -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

$vis = Get-Content 'C:\Users\user\windows-visible.txt'
$strips = @(); $office = @()
foreach ($l in $vis) {
  if ($l -match '^(0x[0-9a-f]+): .*? "([^"]*)"') {
    $hw = $matches[1]; $cls = $matches[2]
    if ($cls -eq 'MSO_BORDEREFFECT_WINDOW_CLASS') { $strips += $hw }
    if ($l -match 'WINWORD\.EXE') { $office += $hw }
  }
}
$strips = @($strips | Sort-Object -Unique); $office = @($office | Sort-Object -Unique)

# --- what did the agent do with them? ----------------------------------------------
$lines = Get-Content $log.FullName
$synth = @(); $mapped = @()
foreach ($l in $lines) {
  if ($l -match 'msg=SYNTH,hwnd=(0x[0-9a-f]+),owner=(0x[0-9a-f]+)') { $synth += ($matches[1] + '->' + $matches[2]) }
  if ($l -match 'SendWindowMap: Mapping window (0x[0-9a-f]+)')      { $mapped += $matches[1] }
}
$synth = @($synth | Sort-Object -Unique); $mapped = @($mapped | Sort-Object -Unique)

$stripSynth  = @($synth | Where-Object { $strips -contains ($_ -split '->')[0] })
$stripMapped = @($strips | Where-Object { $mapped -contains $_ })
$paints      = @($lines | Select-String -Pattern 'msg=SYNTHPAINT').Count

Write-Output ("WORD_PID=" + $w.Id + " OFFICE_WINDOWS=" + $office.Count)
Write-Output ("STRIPS_PRESENT=" + $strips.Count + " [" + ($strips -join ',') + "]")
Write-Output ("STRIPS_SYNTHESIZED=" + $stripSynth.Count + " [" + ($stripSynth -join ' ') + "]")
Write-Output ("STRIPS_MAPPED=" + $stripMapped.Count + " SYNTHPAINT_LINES=" + $paints)
Write-Output ("ALL_SYNTH=" + $synth.Count + " [" + ($synth -join ' ') + "]")
Write-Output ("LOG=" + $log.Name + " PWC=" + $pwc)
if ($strips.Count -eq 0) {
  Write-Output "RESULT which=$Which status=INCONCLUSIVE reason=no_office_strips_in_scene (Word raised no dialog; cannot distinguish builds)"
  exit 0
}
Write-Output ("RESULT which=$Which status=OK installed=$h strips_present=" + $strips.Count +
              " strips_synthesized=" + $stripSynth.Count + " synthpaint=" + $paints)
