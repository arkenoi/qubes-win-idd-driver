# Ground truth: sample Notepad's GetWindowRect AND the DWM extended frame bounds (what the
# agent's GetRealWindowRect reads) every ~25ms for -Seconds, to a file. Drag Notepad during
# it. Reveals whether the window GENUINELY oscillates (GetWindowRect moves) or the agent reads
# a settling/jittering DWM value from a static window.
param([int]$Seconds = 8)
$ErrorActionPreference = 'Continue'
Add-Type -Namespace P -Name S -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int s);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
'@
$p = Get-Process notepad -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $p) { Write-Output '=== RESULT ==='; @{ error='no notepad window' } | ConvertTo-Json; exit }
$h = $p.MainWindowHandle
$out = 'C:\Windows\Temp\possamp.txt'
"t_ms  winrect_LT  dwmbounds_LT" | Set-Content $out
$sw = [System.Diagnostics.Stopwatch]::StartNew()
while ($sw.ElapsedMilliseconds -lt ($Seconds * 1000)) {
    $wr = New-Object P.S+RECT; [void][P.S]::GetWindowRect($h, [ref]$wr)
    $dr = New-Object P.S+RECT; [void][P.S]::DwmGetWindowAttribute($h, 9, [ref]$dr, 16)  # DWMWA_EXTENDED_FRAME_BOUNDS
    ("{0}  {1},{2}  {3},{4}" -f $sw.ElapsedMilliseconds, $wr.L, $wr.T, $dr.L, $dr.T) | Add-Content $out
    Start-Sleep -Milliseconds 25
}
# print only the rows where either value CHANGED (compress static runs)
Write-Output '=== RESULT ==='
$prev = ''
Get-Content $out | ForEach-Object {
    $cols = ($_ -split '\s+'); $key = "$($cols[1]) $($cols[2])"
    if ($key -ne $prev) { $_; $prev = $key }
}
