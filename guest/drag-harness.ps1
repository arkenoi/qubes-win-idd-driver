# Scripted window drag via SendInput (CLAUDE.md Phase 1A step 4 harness).
# Drags the Notepad window's title bar in circles for -Seconds, emitting precise start/end
# timestamps so QGAPERF lines can be windowed to the ACTIVE DRAG period.
# Output: === RESULT === JSON with t0/t1 (guest clock, ISO), window rect before/after, moves sent.
param(
    [string]$ProcName = 'notepad',
    [int]$Seconds = 10,
    [int]$Hz = 60,
    [int]$Radius = 120
)
$ErrorActionPreference = 'Continue'
$r = [ordered]@{}

Add-Type @'
using System;
using System.Runtime.InteropServices;
public class Drag {
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT { public uint type; public MOUSEINPUT mi; }
    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
    [DllImport("user32.dll", SetLastError=true)]
    public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr h, out RECT rc);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int i);
    public const uint MOVE = 0x0001, ABS = 0x8000, LDOWN = 0x0002, LUP = 0x0004;
    public static void Send(int dx, int dy, uint flags) {
        INPUT[] i = new INPUT[1];
        i[0].type = 0; i[0].mi.dx = dx; i[0].mi.dy = dy; i[0].mi.dwFlags = flags;
        SendInput(1, i, Marshal.SizeOf(typeof(INPUT)));
    }
}
'@

# The drag target is a window THIS run started, by handle (owner 2026-10-07: a process found by name is someone
# else's - never adopted as ours). A bounded wait for its main window replaces the old reuse-or-start.
$p = Start-Process $ProcName -PassThru -ErrorAction SilentlyContinue
$deadline = (Get-Date).AddSeconds(10)
while ($p -and (Get-Date) -lt $deadline) { try { $p.Refresh() } catch { }; if ($p.MainWindowHandle -ne 0) { break }; Start-Sleep -Milliseconds 250 }
if ($p -and $p.MainWindowHandle -eq 0) { $p = $null }
if (-not $p) { Write-Output '=== RESULT ==='; @{ ok=$false; error='no target window (the process started here showed no main window within 10 s)' } | ConvertTo-Json; exit 1 }
$h = $p.MainWindowHandle
[Drag]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 300

$rc = New-Object Drag+RECT
[Drag]::GetWindowRect($h, [ref]$rc) | Out-Null
$r.rect_before = "$($rc.L),$($rc.T) $($rc.R - $rc.L)x$($rc.B - $rc.T)"

# Grab the title bar 40% across, 12px down. Absolute coords normalized to primary screen.
$sw = [Drag]::GetSystemMetrics(0)   # SM_CXSCREEN
$sh = [Drag]::GetSystemMetrics(1)   # SM_CYSCREEN
$r.screen = "${sw}x${sh}"
function AbsX([int]$x) { [int]([math]::Round($x * 65535 / ($sw - 1))) }
function AbsY([int]$y) { [int]([math]::Round($y * 65535 / ($sh - 1))) }

$gx = $rc.L + [int](($rc.R - $rc.L) * 0.4)
$gy = $rc.T + 12
$cx = $gx; $cy = $gy + $Radius   # circle center below the grab point

[Drag]::Send((AbsX $gx), (AbsY $gy), ([Drag]::MOVE -bor [Drag]::ABS))
Start-Sleep -Milliseconds 120
[Drag]::Send(0, 0, [Drag]::LDOWN)
Start-Sleep -Milliseconds 120

$interval = [int](1000 / $Hz)
$steps = $Seconds * $Hz
$r.t0 = (Get-Date).ToString('yyyyMMdd.HHmmss.fff')
$sw0 = [System.Diagnostics.Stopwatch]::StartNew()
$moves = 0
for ($i = 0; $i -lt $steps; $i++) {
    $ang = 2 * [math]::PI * $i / $Hz          # one full circle per second
    $x = $cx + [int]($Radius * [math]::Sin($ang))
    $y = $cy - [int]($Radius * [math]::Cos($ang))
    [Drag]::Send((AbsX $x), (AbsY $y), ([Drag]::MOVE -bor [Drag]::ABS))
    $moves++
    $targetMs = ($i + 1) * $interval
    $lag = $targetMs - $sw0.ElapsedMilliseconds
    if ($lag -gt 0) { Start-Sleep -Milliseconds $lag }
}
$r.t1 = (Get-Date).ToString('yyyyMMdd.HHmmss.fff')
[Drag]::Send(0, 0, [Drag]::LUP)
Start-Sleep -Milliseconds 300

[Drag]::GetWindowRect($h, [ref]$rc) | Out-Null
$r.rect_after = "$($rc.L),$($rc.T) $($rc.R - $rc.L)x$($rc.B - $rc.T)"
$r.moves = $moves
$r.elapsed_ms = $sw0.ElapsedMilliseconds
$r.ok = $true
Write-Output '=== RESULT ==='
$r | ConvertTo-Json
