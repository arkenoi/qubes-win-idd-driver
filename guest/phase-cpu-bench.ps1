# Per-phase gui-agent CPU: runs instrumentation/drag-harness.ps1 (idle/drag/scroll/type
# phases with ### PHASE markers) as a child process while sampling gui-agent's cumulative
# CPU seconds every 250 ms. The caller joins samples to phase windows and computes %core
# per phase - the metric behind README's performance table (agent 09b643e, 2026-08-10).
param([string]$Harness = 'C:\Users\user\Documents\QubesIncoming\win-idd-mgmt\drag-harness.ps1')
$ErrorActionPreference = 'Continue'
$out = 'C:\Windows\Temp\phasecpu-harness.txt'
Remove-Item $out -ErrorAction SilentlyContinue
$a = Get-Process gui-agent -ErrorAction SilentlyContinue
if (-not $a) { Write-Output '=== META ==='; Write-Output '{"error":"no agent"}'; exit 1 }
# Chained property access on a cmdlet that can return $null throws on exactly the broken state a
# probe exists to report (lint L6). Resolve the hash defensively so a missing binary is REPORTED,
# not turned into a terminating error in the middle of the META block.
$binPath = 'C:\Program Files\Qubes Tools\bin\gui-agent.exe'
$binHash = 'unavailable'
$fh = Get-FileHash $binPath -Algorithm SHA256 -ErrorAction SilentlyContinue
if ($fh -and $fh.Hash) { $binHash = $fh.Hash.Substring(0,16) }
# The screen width came from System.Windows.Forms, whose assembly is not loaded in a bare
# -NoProfile session, so this field silently produced nothing. Use the Win32 metric instead.
$screenW = 0
try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
      $screenW = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width } catch { }
Write-Output '=== META ==='
@{ agent_pid = $a.Id
   bin_sha256 = $binHash
   screen = $screenW } | ConvertTo-Json -Compress
# -KeepNotepad: the scene must survive the run so the CALLER can verify by PIXELS that the window
# the numbers came from was actually rendering. A wedged Notepad (client area white, typing
# invisible) survives agent restarts and binary swaps and faked two regressions here on
# 2026-08-12; nothing in the agent's own output can detect it.
$proc = Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$Harness`" -KeepNotepad" `
    -RedirectStandardOutput $out -PassThru -WindowStyle Hidden
$samples = New-Object System.Collections.Generic.List[string]
while (-not $proc.HasExited) {
    $g = Get-Process gui-agent -ErrorAction SilentlyContinue
    $t = (Get-Date).ToString('yyyyMMdd.HHmmss.fff')
    if ($g) { $samples.Add(("{0} {1:F4}" -f $t, [double]$g.CPU)) }
    Start-Sleep -Milliseconds 250
}
Write-Output '=== SAMPLES ==='
$samples
Write-Output '=== HARNESS ==='
Get-Content $out | Select-String '### PHASE|cadence|RESULT|error' | ForEach-Object { $_.Line }
Write-Output '=== END ==='
