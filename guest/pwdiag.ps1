# pwdiag - QWT-NG black-window field diagnostic.
# Run INSIDE the Windows qube, in a normal (interactive) PowerShell:
#   powershell -NoProfile -ExecutionPolicy Bypass -File pwdiag.ps1
# Writes C:\pwdiag\pwdiag.txt and one PNG per visible window; zip and post C:\pwdiag.
# What it answers: for every visible top-level window - identity (class/title/rect/styles)
# and whether PrintWindow(PW_RENDERFULLCONTENT), the capture path the QWT-NG gui agent
# uses, returns real content or black for THAT window on THIS machine.
# CAVEAT: this runs in YOUR user context; the agent captures as SYSTEM in session 1,
# and PrintWindow results can differ between the two (a window can capture fine here
# and still blank in the agent). Treat pwdiag as window IDENTIFICATION plus a first
# pass; the agent's own WCBLACK/WCDEAD log lines (4.3.10+) are the authoritative view.
$ErrorActionPreference = 'SilentlyContinue'
Remove-Item -Recurse -Force C:\pwdiag -EA SilentlyContinue
New-Item -ItemType Directory -Force C:\pwdiag | Out-Null
$out = 'C:\pwdiag\pwdiag.txt'
"pwdiag $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  session=$([System.Diagnostics.Process]::GetCurrentProcess().SessionId)  user=$(whoami)" | Set-Content $out
(Get-CimInstance Win32_OperatingSystem).Version + ' ' + (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').DisplayVersion | Add-Content $out
"agent: $((Get-Item 'C:\Program Files\Qubes Tools\bin\gui-agent.exe').VersionInfo.FileVersion)" | Add-Content $out

Add-Type -AssemblyName System.Drawing
Add-Type @'
using System; using System.Text; using System.Runtime.InteropServices;
public static class PD {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int idx);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out int v, int sz);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
'@

$wins = New-Object System.Collections.ArrayList
$cb = [PD+EnumProc]{ param($hw, $l) if ([PD]::IsWindowVisible($hw)) { [void]$wins.Add($hw) }; $true }
[PD]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
"visible-toplevel: $($wins.Count)" | Add-Content $out

$idx = 0
foreach ($h in $wins) {
  $sb = New-Object System.Text.StringBuilder 256
  [PD]::GetClassNameW($h, $sb, 256) | Out-Null; $cls = $sb.ToString()
  $sb.Clear() | Out-Null
  [PD]::GetWindowTextW($h, $sb, 256) | Out-Null; $title = $sb.ToString()
  $r = New-Object PD+RECT
  [PD]::GetWindowRect($h, [ref]$r) | Out-Null
  $w = $r.R - $r.L; $ht = $r.B - $r.T
  $style = [PD]::GetWindowLong($h, -16); $ex = [PD]::GetWindowLong($h, -20)
  $cloak = 0; [PD]::DwmGetWindowAttribute($h, 14, [ref]$cloak, 4) | Out-Null
  $owner = [PD]::GetWindow($h, 4)
  $hx = '0x{0:x}' -f $h.ToInt64()
  $line = "WIN $hx cls=$cls rect=$($r.L),$($r.T),$w`x$ht style=0x$('{0:x8}' -f $style) ex=0x$('{0:x8}' -f $ex) cloaked=$cloak owner=0x$('{0:x}' -f $owner.ToInt64()) title=$title"
  if ($w -lt 40 -or $ht -lt 40 -or $cloak -ne 0) { Add-Content $out "$line  [skipped-capture]"; continue }
  $bmp = New-Object System.Drawing.Bitmap $w, $ht
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $dc = $g.GetHdc()
  $ok = [PD]::PrintWindow($h, $dc, 2)   # PW_RENDERFULLCONTENT - the agent's flag
  $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
  $g.ReleaseHdc($dc); $g.Dispose()
  $black = 0; $tot = 0
  for ($y = 0; $y -lt $ht; $y += 4) { for ($x = 0; $x -lt $w; $x += 4) {
    $c = $bmp.GetPixel($x, $y); $tot++
    if ($c.R -lt 12 -and $c.G -lt 12 -and $c.B -lt 12) { $black++ }
  } }
  $pct = if ($tot) { '{0:P1}' -f ($black / $tot) } else { '?' }
  $png = "C:\pwdiag\win$idx-$cls.png" -replace '[^\w\\:.\-]', '_'
  $bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  $errtxt = if ($ok) { '' } else { " err=$err" }
  Add-Content $out "$line`n  CAPTURE ok=$ok$errtxt black=$pct png=$(Split-Path $png -Leaf)"
  $idx++
}
Add-Content $out 'pwdiag done'
Get-Content $out
