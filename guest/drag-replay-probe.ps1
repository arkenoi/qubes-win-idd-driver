# Drag-replay probe: high-rate SendInput title-bar drag of Notepad (mimics dom0-forwarded
# input rate), then 8 s of 25 ms ground-truth sampling of the SAME window. Emits precise
# wall-clock press/release times so dom0-side geometry samples can be aligned.
# Assumes ProtoTrace already on. Output: === META === JSON, === SAMPLES === changed rows only.
param(
    [int]$DragSeconds = 6,
    [int]$Hz = 200,
    [int]$AmplX = 1100,
    [int]$SettleSeconds = 8
)
$ErrorActionPreference = 'Continue'
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class Drp {
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public MOUSEINPUT mi; }
    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
    [DllImport("user32.dll", SetLastError=true)]
    public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT rc);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int w, int hh, uint f);
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int L, T, R, B; }
    public const uint MOVE = 0x0001, ABS = 0x8000, LDOWN = 0x0002, LUP = 0x0004;
    public static void Send(int dx, int dy, uint flags) {
        INPUT[] i = new INPUT[1];
        i[0].type = 0; i[0].mi.dx = dx; i[0].mi.dy = dy; i[0].mi.dwFlags = flags;
        SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
    }
}
'@
$meta = [ordered]@{}
$p = Get-Process notepad -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $p) {
    Start-Process notepad; Start-Sleep -Seconds 3
    $p = Get-Process notepad -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
}
if (-not $p) { Write-Output '=== META ==='; @{ error = 'no notepad' } | ConvertTo-Json; exit 1 }
$h = $p.MainWindowHandle
$meta.hwnd = '0x{0:X}' -f $h.ToInt64()
[void][Drp]::SetForegroundWindow($h)
# Park the window at a known spot away from edges so the whole path stays on-screen.
[void][Drp]::SetWindowPos($h, [IntPtr]::Zero, 600, 400, 900, 600, 0x0004) # SWP_NOZORDER
Start-Sleep -Milliseconds 800

$vw = [Drp]::GetSystemMetrics(78); $vh = [Drp]::GetSystemMetrics(79)  # virtual screen
$meta.screen = "$vw x $vh"
$r = New-Object Drp+RECT; [void][Drp]::GetWindowRect($h, [ref]$r)
$meta.start_rect = "$($r.L),$($r.T)"
# Grab point: middle of the title bar (12 px below top edge clears the invisible border).
$gx = [int](($r.L + $r.R) / 2); $gy = $r.T + 12
function AbsX([int]$x) { [int]([math]::Round($x * 65535.0 / ($script:vw - 1))) }
function AbsY([int]$y) { [int]([math]::Round($y * 65535.0 / ($script:vh - 1))) }

[Drp]::Send((AbsX $gx), (AbsY $gy), ([Drp]::MOVE -bor [Drp]::ABS))
Start-Sleep -Milliseconds 120
$meta.press_utc = (Get-Date).ToUniversalTime().ToString('HH:mm:ss.fff')
[Drp]::Send((AbsX $gx), (AbsY $gy), ([Drp]::LDOWN -bor [Drp]::ABS))
Start-Sleep -Milliseconds 60

# Triangle-wave horizontal sweep: two full out-and-back periods over DragSeconds.
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$totalMs = $DragSeconds * 1000
$stepMs = 1000.0 / $Hz
$next = 0.0
$sent = 0
while ($sw.ElapsedMilliseconds -lt $totalMs) {
    $t = $sw.ElapsedMilliseconds
    if ($t -ge $next) {
        $phase = ($t / ($totalMs / 2.0)) % 1.0          # 2 periods
        $tri = if ($phase -lt 0.5) { $phase * 2 } else { 2 - $phase * 2 }
        $x = $gx + [int]($AmplX * $tri)
        $y = $gy + [int](60 * [math]::Sin($t / 180.0))
        [Drp]::Send((AbsX $x), (AbsY $y), ([Drp]::MOVE -bor [Drp]::ABS))
        $sent++
        $next = $next + $stepMs
    }
}
$meta.moves_sent = $sent
$meta.release_utc = (Get-Date).ToUniversalTime().ToString('HH:mm:ss.fff')
[Drp]::Send((AbsX $gx), (AbsY $gy), ([Drp]::LUP -bor [Drp]::ABS))

# Ground truth: sample the window rect for SettleSeconds after release.
$samples = New-Object System.Collections.Generic.List[string]
$sw2 = [System.Diagnostics.Stopwatch]::StartNew()
while ($sw2.ElapsedMilliseconds -lt ($SettleSeconds * 1000)) {
    $rr = New-Object Drp+RECT; [void][Drp]::GetWindowRect($h, [ref]$rr)
    $samples.Add(("{0} {1},{2}" -f $sw2.ElapsedMilliseconds, $rr.L, $rr.T))
    Start-Sleep -Milliseconds 25
}
$rf = New-Object Drp+RECT; [void][Drp]::GetWindowRect($h, [ref]$rf)
$meta.final_rect = "$($rf.L),$($rf.T)"
$meta.sample_end_utc = (Get-Date).ToUniversalTime().ToString('HH:mm:ss.fff')

Write-Output '=== META ==='
$meta | ConvertTo-Json
Write-Output '=== SAMPLES (changed rows) ==='
$prev = ''
foreach ($s in $samples) {
    $k = ($s -split ' ')[1]
    if ($k -ne $prev) { $s; $prev = $k }
}
Write-Output '=== END ==='
