# Post-fix log evidence: RESDRIFT adopts, workarea outcome, A3CHECK values, capture resets,
# QGABUTTONABS/QGAPROTO switch states, toastcrop worker startup.
$ErrorActionPreference = 'Continue'
$logdir = (Get-ItemProperty 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -ErrorAction SilentlyContinue).LogDir
if (-not $logdir) { $logdir = 'Q:\Qubes Logs' }
$log = Get-ChildItem $logdir -Filter 'gui-agent-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Write-Output "=== LOG $($log.Name) $($log.Length) ==="
$content = Get-Content $log.FullName
$pats = 'RESDRIFT','RESAPPLIED','RESREQ','A3CHECK','work area set','SPI_SETWORKAREA failed','error/timeout waiting','main loop slow','main loop wedged','QGABUTTONABS','QGAPROTO ','QGATOASTCROP','toast card in','XcOpen'
foreach ($p in $pats) {
    $m = $content | Select-String -SimpleMatch $p
    Write-Output "--- '$p' = $(($m | Measure-Object).Count)"
    $m | Select-Object -Last 3 | ForEach-Object { $_.Line }
}
Write-Output '=== END ==='
