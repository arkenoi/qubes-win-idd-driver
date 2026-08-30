# RND-7 / SG8 VACUITY PROOF — enumerate chromerepro's compound-window set guest-side, so that
# "dom0 mapped exactly 1" is a filter RESULT: the 4 shadow strips are proven to have existed and
# been evaluated. Reports styles/exstyles so the acceptance predicate is checkable, not assumed.
#
# WAS IN JOB SCRATCH UNTIL 2026-08-31 (see guest/startproof.ps1 for why that mattered).
$ErrorActionPreference='Continue'
# CharSet.Unicode is load-bearing: with Ansi, GetWindowText truncated every title to one
# character for a whole session here.
Add-Type -TypeDefinition @"
using System; using System.Text; using System.Runtime.InteropServices;
public class W {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetWindowLongW(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint c);
}
"@
$rows = New-Object System.Collections.ArrayList
$cb = [W+EnumProc]{ param($h,$l)
  if ([W]::IsWindowVisible($h)) {
    $t = New-Object Text.StringBuilder 256; [void][W]::GetWindowTextW($h,$t,256)
    $c = New-Object Text.StringBuilder 256; [void][W]::GetClassNameW($h,$c,256)
    $style = [W]::GetWindowLongW($h,-16); $ex = [W]::GetWindowLongW($h,-20)
    $owner = [W]::GetWindow($h,4)
    if ($c.ToString() -match 'ChromeRepro|Shadow' -or $t.ToString() -match 'ChromeRepro|Shadow') {
      [void]$rows.Add(('HWND 0x{0:X} class={1} title="{2}" style=0x{3:X8} exstyle=0x{4:X8} layered={5} transparent={6} toolwin={7} owner=0x{8:X}' -f `
        $h.ToInt64(), $c.ToString(), $t.ToString(), $style, $ex, [bool]($ex -band 0x80000), [bool]($ex -band 0x20), [bool]($ex -band 0x80), $owner.ToInt64()))
    }
  }
  return $true
}
[void][W]::EnumWindows($cb,[IntPtr]::Zero)
Write-Output ('CHROMEREPRO_HWNDS ' + $rows.Count)
$rows | ForEach-Object { Write-Output $_ }
