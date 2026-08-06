# Automated Office compound-window check (CLAUDE.md 2A-chrome acceptance).
# Launches Word, waits for its window set to settle, and enumerates every top-level HWND
# the agent could see - so the shadow-strip chrome that stock QWT maps as separate bordered
# windows is COUNTED, not eyeballed. Pairs with a qtest shot for the visual pass.
#
# Emits: OFFICE_HWNDS n=<total top-level>, one HWND line each (class/styles/exstyles/
# cloaked/owner/rect/alpha), and RESULT lines with the counts that matter.
param([int]$SettleSec = 20, [switch]$KeepOpen)
$ErrorActionPreference = 'Continue'

Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class W {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint c);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetLayeredWindowAttributes(IntPtr h, out uint k, out byte a, out uint f);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out int v, int s);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
'@

$word = 'C:\Program Files\Microsoft Office\root\Office16\WINWORD.EXE'
if (-not (Test-Path $word)) { Write-Output 'RESULT office_present=FALSE'; exit 1 }
$proc = Start-Process $word -PassThru
Start-Sleep -Seconds $SettleSec

$rows = New-Object System.Collections.ArrayList
$cb = [W+EnumProc]{
    param($h, $l)
    if (-not [W]::IsWindowVisible($h)) { return $true }
    $pid = 0; [void][W]::GetWindowThreadProcessId($h, [ref]$pid)
    if ($pid -ne $proc.Id) { return $true }
    $cls = New-Object Text.StringBuilder 256; [void][W]::GetClassName($h, $cls, 256)
    $txt = New-Object Text.StringBuilder 256; [void][W]::GetWindowTextW($h, $txt, 256)
    $style = [W]::GetWindowLong($h, -16); $ex = [W]::GetWindowLong($h, -20)
    $owner = [W]::GetWindow($h, 4)
    $r = New-Object W+RECT; [void][W]::GetWindowRect($h, [ref]$r)
    $cloak = 0; [void][W]::DwmGetWindowAttribute($h, 14, [ref]$cloak, 4)
    $alpha = 255; $k = 0; $f = 0
    if ($ex -band 0x80000) { [void][W]::GetLayeredWindowAttributes($h, [ref]$k, [ref]$alpha, [ref]$f) }
    [void]$rows.Add([pscustomobject]@{
        H = ('0x{0:X}' -f $h.ToInt64()); Class = $cls.ToString(); Title = $txt.ToString()
        Style = ('0x{0:X}' -f $style); Ex = ('0x{0:X}' -f $ex)
        Owner = ('0x{0:X}' -f $owner.ToInt64()); Cloaked = $cloak; Alpha = $alpha
        W = ($r.R - $r.L); Hgt = ($r.B - $r.T)
    })
    return $true
}
[void][W]::EnumWindows($cb, [IntPtr]::Zero)

Write-Output ("OFFICE_HWNDS n=" + $rows.Count)
foreach ($x in $rows) {
    Write-Output ("HWND {0} class={1} style={2} ex={3} owner={4} cloaked={5} alpha={6} size={7}x{8} title='{9}'" -f `
        $x.H, $x.Class, $x.Style, $x.Ex, $x.Owner, $x.Cloaked, $x.Alpha, $x.W, $x.Hgt, $x.Title)
}
# The classes that matter: the real frame vs the shadow strips the fork must drop.
$main   = @($rows | Where-Object { $_.Class -eq 'OpusApp' }).Count
$shadow = @($rows | Where-Object { $_.Class -like '*BorderEffect*' -or ($_.Ex -band 0x80000 -and $_.Alpha -eq 0) }).Count
Write-Output ("RESULT office_main_frames=$main office_shadow_candidates=$shadow total_visible=" + $rows.Count)
if (-not $KeepOpen) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
