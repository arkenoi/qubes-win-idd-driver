# One-shot interleaved-gate step: optionally set gui-agent LogLevel (agent restart via
# watchdog), run the SendInput circle drag, then emit the QGAPERF lines for the drag window.
# Output: === META === JSON, then === PERF === raw QGAPERF lines, === END ===.
param(
    [int]$SetProto = -1,     # 0/1: set gui-agent ProtoTrace and restart the agent first
    [int]$Seconds = 10,
    [int]$Hz = 60
)
$ErrorActionPreference = 'Continue'
$meta = [ordered]@{}
$reg = 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools'
$regGa = "$reg\gui-agent"

if ($SetProto -ge 0) {
    if (-not (Test-Path $regGa)) { New-Item $regGa -Force | Out-Null }
    Set-ItemProperty $regGa -Name ProtoTrace -Value $SetProto -Type DWord
    # Restart the agent THROUGH THE SERVICE THAT OWNS IT, turnover proven (guest/restart-gui-agent.ps1
    # pushed next to this script). Owner 2026-10-07: the old `Get-Process gui-agent | Stop-Process`
    # raced the watchdog's own relaunch, so the setting could be measured on the survivor.
    $helper = Join-Path $PSScriptRoot 'restart-gui-agent.ps1'
    if (-not (Test-Path -LiteralPath $helper)) { Write-Output '=== META ==='; $meta.error = 'restart-gui-agent.ps1 not pushed next to this script (tools/qtest push guest/restart-gui-agent.ps1)'; $meta | ConvertTo-Json; exit 3 }
    . $helper
    $ra = Restart-GuiAgent
    foreach ($ln in @($ra.lines)) { Write-Output $ln }
    $meta.restart = $ra.verdict
    if (-not $ra.ok) { Write-Output '=== META ==='; $meta.error = "agent restart not proven: $($ra.reason)"; $meta | ConvertTo-Json; exit 3 }
}
$meta.prototrace = (Get-ItemProperty $regGa -ErrorAction SilentlyContinue).ProtoTrace
$meta.loglevel = (Get-ItemProperty $reg).LogLevel
$p = Get-Process gui-agent -ErrorAction SilentlyContinue
$meta.agent_pid = if ($p) { $p.Id } else { $null }
if (-not $p) { Write-Output '=== META ==='; $meta.error='agent not running'; $meta | ConvertTo-Json; exit 1 }
$meta.bin_sha256 = (Get-FileHash 'C:\Program Files\Qubes Tools\bin\gui-agent.exe' -Algorithm SHA256).Hash
Start-Sleep -Seconds 3   # let the fresh agent settle (initial re-announce)

Add-Type @'
using System;
using System.Runtime.InteropServices;
public class Drag2 {
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

# The drag target is a notepad THIS run started, by handle (owner 2026-10-07: a process found by name is someone
# else's - never adopted as ours). A bounded wait for its main window replaces the old reuse-or-start.
$p = Start-Process notepad -PassThru -ErrorAction SilentlyContinue
$deadline = (Get-Date).AddSeconds(10)
while ($p -and (Get-Date) -lt $deadline) { try { $p.Refresh() } catch { }; if ($p.MainWindowHandle -ne 0) { break }; Start-Sleep -Milliseconds 250 }
if ($p -and $p.MainWindowHandle -eq 0) { $p = $null }
if (-not $p) { Write-Output '=== META ==='; $meta.error='no notepad (the one started here showed no main window within 10 s)'; $meta | ConvertTo-Json; exit 1 }
$h = $p.MainWindowHandle
[Drag2]::SetForegroundWindow($h) | Out-Null
Start-Sleep -Milliseconds 300

$rc = New-Object Drag2+RECT
[Drag2]::GetWindowRect($h, [ref]$rc) | Out-Null
$sw = [Drag2]::GetSystemMetrics(0); $sh = [Drag2]::GetSystemMetrics(1)
function AbsX([int]$x) { [int]([math]::Round($x * 65535 / ($sw - 1))) }
function AbsY([int]$y) { [int]([math]::Round($y * 65535 / ($sh - 1))) }

# Keep the drag inside a safe box so repeated runs don't walk the window offscreen.
$gx = [math]::Max(300, [math]::Min($sw - 500, $rc.L + [int](($rc.R - $rc.L) * 0.4)))
$gy = [math]::Max(30, $rc.T + 12)
$Radius = 120
$cx = $gx; $cy = $gy + $Radius

[Drag2]::Send((AbsX $gx), (AbsY $gy), ([Drag2]::MOVE -bor [Drag2]::ABS)); Start-Sleep -Milliseconds 120
[Drag2]::Send(0, 0, [Drag2]::LDOWN); Start-Sleep -Milliseconds 120

$interval = [int](1000 / $Hz)
$steps = $Seconds * $Hz
$meta.t0 = (Get-Date).ToString('yyyyMMdd.HHmmss.fff')
$sw0 = [System.Diagnostics.Stopwatch]::StartNew()
for ($i = 0; $i -lt $steps; $i++) {
    $ang = 2 * [math]::PI * $i / $Hz
    $x = $cx + [int]($Radius * [math]::Sin($ang))
    $y = $cy - [int]($Radius * [math]::Cos($ang))
    [Drag2]::Send((AbsX $x), (AbsY $y), ([Drag2]::MOVE -bor [Drag2]::ABS))
    $targetMs = ($i + 1) * $interval
    $lag = $targetMs - $sw0.ElapsedMilliseconds
    if ($lag -gt 0) { Start-Sleep -Milliseconds $lag }
}
$meta.t1 = (Get-Date).ToString('yyyyMMdd.HHmmss.fff')
[Drag2]::Send(0, 0, [Drag2]::LUP)
Start-Sleep -Milliseconds 500
$meta.elapsed_ms = $sw0.ElapsedMilliseconds

# Extract QGAPERF for the drag window from the newest log
$logdir = (Get-ItemProperty $reg).LogDir
if (-not $logdir) { $logdir = 'Q:\Qubes Logs' }
$log = Get-ChildItem $logdir -Filter 'gui-agent-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$meta.log = $log.Name

Write-Output '=== META ==='
$meta | ConvertTo-Json
Write-Output '=== PERF ==='
Get-Content $log.FullName | Where-Object {
    $_ -match '^\[(\d{8}\.\d{6}\.\d{3})' -and $Matches[1] -ge $meta.t0 -and $Matches[1] -le $meta.t1 -and $_ -match 'QGAPERF'
} | ForEach-Object { $_ }
Write-Output '=== END ==='
