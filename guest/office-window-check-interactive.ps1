# Office compound-window check (CLAUDE.md 2A-chrome acceptance) that ACTUALLY RUNS.
#
# WHY A WRAPPER: guest/office-window-check.ps1 launches Word and enumerates its windows, but
# over qrexec it runs in SESSION 0, which has no interactive desktop - WINWORD starts and
# exits within ~2 s (measured: "WORD_EXITED after 2s exitcode=0"), so the enumeration always
# reported n=0 and the check silently proved nothing. Same trap as cpu-bench.ps1 (its load
# ran in session 0, so both benchmark sides read 0.05 %) and the toast probe.
#
# So the real work is handed to a scheduled task with /ru user /it, which runs in the
# interactive session where Word can actually open a window.
#
# Emits: OFFICE_* lines identical to the direct script, plus OFFICEPROBE_DONE.
param([int]$SettleSec = 35)
$ErrorActionPreference = 'Continue'
$work = 'C:\officeprobe'
New-Item -ItemType Directory -Force $work | Out-Null
Remove-Item "$work\result.txt" -ErrorAction SilentlyContinue

$inner = @'
$word = 'C:\Program Files\Microsoft Office\root\Office16\WINWORD.EXE'
$out = New-Object System.Collections.ArrayList
if (-not (Test-Path $word)) {
    [void]$out.Add('RESULT office_present=FALSE')
} else {
    $proc = Start-Process $word -PassThru
    Start-Sleep -Seconds __SETTLE__
    Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class OW {
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
"@
    $rows = New-Object System.Collections.ArrayList
    $cb = [OW+EnumProc]{
        param($h, $l)
        if (-not [OW]::IsWindowVisible($h)) { return $true }
        $procId = 0; [void][OW]::GetWindowThreadProcessId($h, [ref]$procId)
        $pn = (Get-Process -Id $procId -ErrorAction SilentlyContinue).Name
        if ($pn -ne 'WINWORD') { return $true }
        $cls = New-Object Text.StringBuilder 256; [void][OW]::GetClassName($h, $cls, 256)
        $txt = New-Object Text.StringBuilder 256; [void][OW]::GetWindowTextW($h, $txt, 256)
        $style = [OW]::GetWindowLong($h, -16); $ex = [OW]::GetWindowLong($h, -20)
        $owner = [OW]::GetWindow($h, 4)
        $r = New-Object OW+RECT; [void][OW]::GetWindowRect($h, [ref]$r)
        $cloak = 0; [void][OW]::DwmGetWindowAttribute($h, 14, [ref]$cloak, 4)
        $alpha = 255; $k = 0; $f = 0
        if ($ex -band 0x80000) { [void][OW]::GetLayeredWindowAttributes($h, [ref]$k, [ref]$alpha, [ref]$f) }
        [void]$rows.Add([pscustomobject]@{
            H=('0x{0:X}' -f $h.ToInt64()); Class=$cls.ToString(); Title=$txt.ToString()
            Style=('0x{0:X}' -f $style); Ex=('0x{0:X}' -f $ex); ExRaw=$ex
            Owner=('0x{0:X}' -f $owner.ToInt64()); Cloaked=$cloak; Alpha=$alpha
            W=($r.R-$r.L); Hgt=($r.B-$r.T)
        })
        return $true
    }
    [void][OW]::EnumWindows($cb, [IntPtr]::Zero)
    [void]$out.Add("OFFICE_HWNDS n=" + $rows.Count)
    foreach ($x in $rows) {
        [void]$out.Add(("HWND {0} class={1} style={2} ex={3} owner={4} cloaked={5} alpha={6} size={7}x{8} title='{9}'" -f `
            $x.H, $x.Class, $x.Title, $x.Style, $x.Ex, $x.Owner, $x.Cloaked, $x.Alpha, $x.W, $x.Hgt) -replace '\s+$','')
    }
    $main   = @($rows | Where-Object { $_.Class -eq 'OpusApp' }).Count
    $shadow = @($rows | Where-Object { $_.Class -like '*BorderEffect*' -or (($_.ExRaw -band 0x80000) -and $_.Alpha -eq 0) }).Count
    [void]$out.Add("RESULT office_main_frames=$main office_shadow_candidates=$shadow total_visible=" + $rows.Count)
}
$out | Set-Content C:\officeprobe\result.txt
'@ -replace '__SETTLE__', $SettleSec

Set-Content "$work\inner.ps1" -Value $inner -Encoding ASCII
& schtasks /create /tn QwtOfficeProbe /tr "powershell -NoProfile -ExecutionPolicy Bypass -File $work\inner.ps1" /sc once /st 00:00 /ru user /it /f *>&1 | Out-Null
& schtasks /run /tn QwtOfficeProbe *>&1 | Out-Null
for ($i = 0; $i -lt ($SettleSec + 60); $i++) { Start-Sleep 1; if (Test-Path "$work\result.txt") { break } }
Start-Sleep 2
& schtasks /delete /tn QwtOfficeProbe /f *>&1 | Out-Null
if (Test-Path "$work\result.txt") { Get-Content "$work\result.txt" } else { Write-Output 'OFFICEPROBE_NO_RESULT (task produced nothing)' }
Write-Output 'OFFICEPROBE_DONE'
