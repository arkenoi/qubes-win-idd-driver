# Count capture-reset events and their triggers across the newest agent log.
$ErrorActionPreference = 'Continue'
$logdir = (Get-ItemProperty 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -ErrorAction SilentlyContinue).LogDir
if (-not $logdir) { $logdir = 'Q:\Qubes Logs' }
$log = Get-ChildItem $logdir -Filter 'gui-agent-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Write-Output "=== LOG $($log.Name) $($log.Length) ==="
$pats = [ordered]@{
    cap_timeout = 'error/timeout waiting for frame processing'
    xcopen      = 'XcOpen: XenIface handle'
    screengrant = 'SendScreenGrants'
    recreate    = 'RecreateDuplication'
    acqfail     = 'AcquireNextFrame.*fail|0x887a0026|keyed mutex'
    workarea    = 'SPI_SETWORKAREA failed'
    realrect    = 'GetRealWindowRect failed'
    toastlookup = 'ToastCropLookup'
    desktopatt  = 'AttachToInputDesktop.*SetThreadDesktop=ok'
}
foreach ($k in $pats.Keys) {
    $m = Get-Content $log.FullName | Select-String -Pattern $pats[$k]
    Write-Output "--- $k = $(($m | Measure-Object).Count)"
    $m | Select-Object -Last 5 | ForEach-Object { $_.Line }
}
Write-Output '=== END ==='
