# Ground truth for the believed-vs-actual screen geometry question:
# actual display mode, metrics, work area, and the agent's own belief from its log.
$ErrorActionPreference = 'Continue'
$r = [ordered]@{}

Add-Type -Namespace G -Name M -MemberDefinition @'
[DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
[DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint a, uint b, out RECT r, uint f);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
'@
$r.sm_screen = "$([G.M]::GetSystemMetrics(0))x$([G.M]::GetSystemMetrics(1))"
$r.sm_virtual = "$([G.M]::GetSystemMetrics(78))x$([G.M]::GetSystemMetrics(79))"
$wa = New-Object G.M+RECT
[void][G.M]::SystemParametersInfo(0x30, 0, [ref]$wa, 0)  # SPI_GETWORKAREA
$r.workarea = "$($wa.L),$($wa.T)-$($wa.R),$($wa.B)"

$r.displays = @(Get-CimInstance Win32_VideoController | ForEach-Object {
    "$($_.Name): $($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution)"
})

$logdir = (Get-ItemProperty 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -ErrorAction SilentlyContinue).LogDir
if (-not $logdir) { $logdir = 'Q:\Qubes Logs' }
$log = Get-ChildItem $logdir -Filter 'gui-agent-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$content = Get-Content $log.FullName
foreach ($p in 'RESREQ','RESEXACT','RESAPPLIED','RESKEEP','A3CHECK','M6SEAMLESS','work area set','SPI_SETWORKAREA failed','A4CLAMP','WorkAreaSetDom0','QGAWA') {
    $m = $content | Select-String -SimpleMatch $p
    $r["log_$($p -replace '[ _]','')"] = @($m | Select-Object -Last 3 | ForEach-Object { $_.Line })
}
Write-Output '=== RESULT ==='
$r | ConvertTo-Json -Depth 4
