# Fire a toast IN THE INTERACTIVE SESSION and capture its window attributes there.
# Session 0 (where qrexec puts us) does not composite, so a toast fired directly never
# renders - the same limitation cpu-bench.ps1 hit with its load generator. The fix is the
# same: run the work through a scheduled task with /ru user /it.
#
# SUPERSEDED 2026-08-11: this script's EnumWindows loop can NEVER see the Win11 toast
# banner - on 24H2 the banner (ShellExperienceHost, class Windows.UI.Core.CoreWindow,
# text 'New notification') is created in a higher z-band (CreateWindowInBand), which
# EnumWindows and managed UIA root enumeration both filter out for normal processes.
# The task died silently only in the sense that its filter matched nothing; the real
# fix is direct-HWND access, which is NOT band-filtered:
#   toast-probe-scan.ps1 - brute-force the HWND space with IsWindow/IsWindowVisible/
#                          GetAncestor, dump full attributes incl. rect vs
#                          DWMWA_EXTENDED_FRAME_BOUNDS (found: they are IDENTICAL,
#                          396x133 - the margin is XAML shadow INSIDE the window).
#   toast-probe-uia.ps1  - find the banner HWND by window text, then UIA FromHandle
#                          walks the subtree: FlexibleToastView = the visible card
#                          (364x90 at +16,+30 inside the 396x133 window).
# Both wrap the fired task in try/catch + Start-Transcript (error.txt / transcript.txt
# under C:\toastprobe) so a dying task leaves the exception behind.
$ErrorActionPreference = 'Continue'
$work = 'C:\toastprobe'
New-Item -ItemType Directory -Force $work | Out-Null

@'
$AppId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
[void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime]
$xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
$t = $xml.GetElementsByTagName('text')
$t[0].AppendChild($xml.CreateTextNode('QUBES TOAST PROBE')) | Out-Null
$t[1].AppendChild($xml.CreateTextNode('attribute capture')) | Out-Null
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($AppId).Show([Windows.UI.Notifications.ToastNotification]::new($xml))
Start-Sleep -Milliseconds 1200

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class TI {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint c);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out int v, int s);
  [DllImport("user32.dll")] public static extern bool GetLayeredWindowAttributes(IntPtr h, out uint k, out byte a, out uint f);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
"@
$out = New-Object System.Collections.ArrayList
for ($pass = 0; $pass -lt 12; $pass++) {
  $cb = [TI+EnumProc]{
    param($h, $l)
    if (-not [TI]::IsWindowVisible($h)) { return $true }
    $r = New-Object TI+RECT; [void][TI]::GetWindowRect($h, [ref]$r)
    $w = $r.R - $r.L; $ht = $r.B - $r.T
    if ($w -le 0 -or $ht -le 0) { return $true }
    $procId = 0; [void][TI]::GetWindowThreadProcessId($h, [ref]$procId)
    $pn = (Get-Process -Id $procId -ErrorAction SilentlyContinue).Name
    $cls = New-Object Text.StringBuilder 256; [void][TI]::GetClassName($h, $cls, 256)
    if ($cls.ToString() -notmatch 'Toast|Windows\.UI\.Core|ShellFlyout|NativeHWNDHost|ApplicationFrame') { return $true }
    $txt = New-Object Text.StringBuilder 256; [void][TI]::GetWindowTextW($h, $txt, 256)
    $style = [TI]::GetWindowLong($h,-16); $ex = [TI]::GetWindowLong($h,-20)
    $cloak = 0; [void][TI]::DwmGetWindowAttribute($h, 14, [ref]$cloak, 4)
    $alpha = 255; $k = 0; $f = 0
    if ($ex -band 0x80000) { [void][TI]::GetLayeredWindowAttributes($h, [ref]$k, [ref]$alpha, [ref]$f) }
    [void]$out.Add(("TOAST h=0x{0:X} proc={1} cls={2} style=0x{3:X} ex=0x{4:X} owner=0x{5:X} cloak={6} alpha={7} topmost={8} caption={9} rect={10},{11} {12}x{13} txt='{14}'" -f `
      $h.ToInt64(), $pn, $cls.ToString(), $style, $ex, [TI]::GetWindow($h,4).ToInt64(), $cloak, $alpha,
      [bool]($ex -band 0x8), [bool]($style -band 0xC00000), $r.L, $r.T, $w, $ht, $txt.ToString()))
    return $true
  }
  [void][TI]::EnumWindows($cb, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 500
}
$out | Sort-Object -Unique | Set-Content C:\toastprobe\result.txt
'@ | Set-Content "$work\fire.ps1" -Encoding ASCII

Remove-Item "$work\result.txt" -ErrorAction SilentlyContinue
& schtasks /create /tn QwtToastProbe /tr "powershell -NoProfile -ExecutionPolicy Bypass -File $work\fire.ps1" /sc once /st 00:00 /ru user /it /f *>&1 | Out-Null
& schtasks /run /tn QwtToastProbe *>&1 | Out-Null
for ($i = 0; $i -lt 30; $i++) { Start-Sleep 1; if (Test-Path "$work\result.txt") { break } }
Start-Sleep 3
& schtasks /delete /tn QwtToastProbe /f *>&1 | Out-Null
if (Test-Path "$work\result.txt") { Get-Content "$work\result.txt" } else { Write-Output 'TOASTPROBE_NO_RESULT' }
Write-Output 'TOASTPROBE_DONE'
