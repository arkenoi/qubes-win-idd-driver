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
Write-Output '=== META ==='
@{ agent_pid = $a.Id
   bin_sha256 = (Get-FileHash 'C:\Program Files\Qubes Tools\bin\gui-agent.exe' -Algorithm SHA256).Hash.Substring(0,16)
   screen = "$([System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width)" } | ConvertTo-Json -Compress
$proc = Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$Harness`"" `
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
