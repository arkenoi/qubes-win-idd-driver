# Toast probe v6: brute-force the HWND space (direct API calls are not z-band
# filtered) to find the 24H2 toast banner that EnumWindows/UIA cannot see.
# Marks each found window with enum=1/0 (whether EnumWindows also returned it).
$ErrorActionPreference = 'Continue'
$work = 'C:\toastprobe'
New-Item -ItemType Directory -Force $work | Out-Null
Remove-Item "$work\result6.txt","$work\error6.txt","$work\transcript6.txt" -ErrorAction SilentlyContinue

@'
$ErrorActionPreference = 'Stop'
Start-Transcript -Path C:\toastprobe\transcript6.txt -Force | Out-Null
$out = New-Object System.Collections.ArrayList
try {

Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public class Scan {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint c);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint f);
  [DllImport("user32.dll")] public static extern IntPtr GetDesktopWindow();
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out int v, int s);
  [DllImport("dwmapi.dll", EntryPoint="DwmGetWindowAttribute")] public static extern int DwmGetWindowAttributeRect(IntPtr h, int a, out RECT r, int s);
  [DllImport("user32.dll")] public static extern bool GetLayeredWindowAttributes(IntPtr h, out uint k, out byte a, out uint f);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }

  public static List<string> ScanOnce(long lo, long hi) {
    var enumSet = new HashSet<long>();
    EnumWindows((h, l) => { enumSet.Add(h.ToInt64()); return true; }, IntPtr.Zero);
    var res = new List<string>();
    IntPtr desk = GetDesktopWindow();
    for (long v = lo; v < hi; v += 2) {
      IntPtr h = new IntPtr(v);
      if (!IsWindow(h) || !IsWindowVisible(h)) continue;
      if (GetAncestor(h, 1) != desk) continue;          // GA_PARENT: top-level only
      RECT r; GetWindowRect(h, out r);
      if (r.R - r.L <= 0 || r.B - r.T <= 0) continue;
      uint pid; GetWindowThreadProcessId(h, out pid);
      var cls = new StringBuilder(256); GetClassName(h, cls, 256);
      var txt = new StringBuilder(256); GetWindowTextW(h, txt, 256);
      int style = GetWindowLong(h, -16), ex = GetWindowLong(h, -20);
      int cloak = -1; DwmGetWindowAttribute(h, 14, out cloak, 4);
      RECT ef; int hr = DwmGetWindowAttributeRect(h, 9, out ef, 16);
      byte alpha = 255; uint k = 0, f = 0; bool lwaOk = false;
      if ((ex & 0x80000) != 0) lwaOk = GetLayeredWindowAttributes(h, out k, out alpha, out f);
      res.Add(string.Format(
        "WIN h=0x{0:X} enum={1} pid={2} cls='{3}' style=0x{4:X} ex=0x{5:X} owner=0x{6:X} cloak={7} alpha={8} lwaOk={9} lwaFlags={10} rect={11},{12},{13},{14} ({15}x{16}) extframe(hr=0x{17:X})={18},{19},{20},{21} ({22}x{23}) txt='{24}'",
        v, enumSet.Contains(v) ? 1 : 0, pid, cls, style, ex, GetWindow(h, 4).ToInt64(),
        cloak, alpha, lwaOk, f, r.L, r.T, r.R, r.B, r.R - r.L, r.B - r.T,
        hr, ef.L, ef.T, ef.R, ef.B, ef.R - ef.L, ef.B - ef.T, txt));
    }
    return res;
  }
}
"@

[void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime]
$AppId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
$xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
$t = $xml.GetElementsByTagName('text')
[void]$t.Item(0).AppendChild($xml.CreateTextNode('QUBES TOAST PROBE 6'))
[void]$t.Item(1).AppendChild($xml.CreateTextNode('hwnd space scan'))
$xml.DocumentElement.SetAttribute('duration','long')
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($AppId).Show([Windows.UI.Notifications.ToastNotification]::new($xml))
[void]$out.Add(('FIRED @ ' + (Get-Date).ToString('HH:mm:ss.fff')))
Start-Sleep -Milliseconds 2000

$seen = New-Object 'System.Collections.Generic.HashSet[string]'
$procCache = @{}
for ($i = 0; $i -lt 5; $i++) {
  $stamp = (Get-Date).ToString('HH:mm:ss.fff')
  [void]$out.Add("SCAN $i @ $stamp")
  foreach ($line in [Scan]::ScanOnce(0x10000, 0x400000)) {
    if ($line -match 'pid=(\d+)') {
      $p = $Matches[1]
      if (-not $procCache.ContainsKey($p)) { $procCache[$p] = (Get-Process -Id ([int]$p) -ErrorAction SilentlyContinue).Name }
      $line = $line -replace "pid=$p ", ("pid={0}({1}) " -f $p, $procCache[$p])
    }
    if ($seen.Add($line)) { [void]$out.Add("[scan $i] $line") }
  }
  Start-Sleep -Milliseconds 1200
}
$out | Set-Content C:\toastprobe\result6.txt
} catch {
  (($_ | Out-String) + "`n" + $_.ScriptStackTrace) | Add-Content C:\toastprobe\error6.txt
  $out | Set-Content C:\toastprobe\result6.txt
}
Stop-Transcript | Out-Null
'@ | Set-Content "$work\fire6.ps1" -Encoding ASCII

& schtasks /create /tn QwtToastProbe /tr "powershell -NoProfile -ExecutionPolicy Bypass -File $work\fire6.ps1" /sc once /st 00:00 /ru user /it /f 2>&1 | Select-String SUCCESS,ERROR
& schtasks /run /tn QwtToastProbe 2>&1 | Select-String SUCCESS,ERROR
Write-Output 'TOASTPROBE6_SCHEDULED'
