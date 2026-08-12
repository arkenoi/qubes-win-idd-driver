# Toast probe v7: find banner HWND by scan, then UIA FromHandle -> walk subtree
# for the INNER visible-card BoundingRectangle (rect==extframe, so the card bounds
# exist only in the XAML layer).
$ErrorActionPreference = 'Continue'
$work = 'C:\toastprobe'
New-Item -ItemType Directory -Force $work | Out-Null
Remove-Item "$work\result7.txt","$work\error7.txt","$work\transcript7.txt" -ErrorAction SilentlyContinue

@'
$ErrorActionPreference = 'Stop'
Start-Transcript -Path C:\toastprobe\transcript7.txt -Force | Out-Null
$out = New-Object System.Collections.ArrayList
try {

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public class S7 {
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint f);
  [DllImport("user32.dll")] public static extern IntPtr GetDesktopWindow();
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  public static List<long> FindByText(string needle) {
    var res = new List<long>();
    IntPtr desk = GetDesktopWindow();
    for (long v = 0x10000; v < 0x400000; v += 2) {
      IntPtr h = new IntPtr(v);
      if (!IsWindow(h) || !IsWindowVisible(h)) continue;
      if (GetAncestor(h, 1) != desk) continue;
      var txt = new StringBuilder(256); GetWindowTextW(h, txt, 256);
      if (txt.ToString().Contains(needle)) res.Add(v);
    }
    return res;
  }
}
"@

[void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime]
$AppId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
$xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
$t = $xml.GetElementsByTagName('text')
[void]$t.Item(0).AppendChild($xml.CreateTextNode('QUBES TOAST PROBE 7'))
[void]$t.Item(1).AppendChild($xml.CreateTextNode('uia subtree bounds'))
$xml.DocumentElement.SetAttribute('duration','long')
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($AppId).Show([Windows.UI.Notifications.ToastNotification]::new($xml))
[void]$out.Add(('FIRED @ ' + (Get-Date).ToString('HH:mm:ss.fff')))
Start-Sleep -Milliseconds 2500

$hwnds = [S7]::FindByText('New notification')
[void]$out.Add(("BANNER HWNDS: " + (($hwnds | ForEach-Object { '0x{0:X}' -f $_ }) -join ' ')))
foreach ($v in $hwnds) {
  $h = [IntPtr]$v
  $r = New-Object S7+RECT; [void][S7]::GetWindowRect($h, [ref]$r)
  [void]$out.Add(("HWND 0x{0:X} rect={1},{2},{3},{4} ({5}x{6})" -f $v,$r.L,$r.T,$r.R,$r.B,($r.R-$r.L),($r.B-$r.T)))
  $el = [Windows.Automation.AutomationElement]::FromHandle($h)
  $walker = [Windows.Automation.TreeWalker]::ControlViewWalker
  # BFS over the subtree, depth-limited
  $queue = New-Object System.Collections.Queue
  $queue.Enqueue(@($el, 0))
  while ($queue.Count -gt 0) {
    $pair = $queue.Dequeue()
    $e = $pair[0]; $d = $pair[1]
    try {
      $c = $e.Current
      $b = $c.BoundingRectangle
      [void]$out.Add(("UIA{0} name='{1}' cls='{2}' type={3} rect={4},{5} {6}x{7} offscreen={8}" -f `
        ('  ' * $d), $c.Name, $c.ClassName, $c.ControlType.ProgrammaticName, [int]$b.X, [int]$b.Y, [int]$b.Width, [int]$b.Height, $c.IsOffscreen))
    } catch { [void]$out.Add("UIA depth $d : props failed") }
    if ($d -lt 4) {
      $ch = $walker.GetFirstChild($e)
      while ($ch -ne $null) { $queue.Enqueue(@($ch, $d+1)); $ch = $walker.GetNextSibling($ch) }
    }
  }
}
$out | Set-Content C:\toastprobe\result7.txt
} catch {
  (($_ | Out-String) + "`n" + $_.ScriptStackTrace) | Add-Content C:\toastprobe\error7.txt
  $out | Set-Content C:\toastprobe\result7.txt
}
Stop-Transcript | Out-Null
'@ | Set-Content "$work\fire7.ps1" -Encoding ASCII

& schtasks /create /tn QwtToastProbe /tr "powershell -NoProfile -ExecutionPolicy Bypass -File $work\fire7.ps1" /sc once /st 00:00 /ru user /it /f 2>&1 | Select-String SUCCESS,ERROR
& schtasks /run /tn QwtToastProbe 2>&1 | Select-String SUCCESS,ERROR
Write-Output 'TOASTPROBE7_SCHEDULED'
