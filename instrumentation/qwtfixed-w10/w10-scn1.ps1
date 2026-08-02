# Win10 protocol regression, part 1: occlusion (two overlapping Notepads, typing into the
# front one) + menu synthesis (File menu opened and HELD; the script exits with the menu
# still on screen so the host can photograph dom0 while it is up).
# Restarts the agent first so every window in the run has a traced CREATE - a window that
# predates the trace has no announced origin and the occlusion invariant silently skips it.
$ErrorActionPreference='SilentlyContinue'

Get-Process notepad -EA SilentlyContinue | Stop-Process -Force
Start-Sleep 2
Get-Process gui-agent -EA SilentlyContinue | Stop-Process -Force
Start-Sleep 16
$log=(Get-ChildItem 'C:\Program Files\Qubes Tools\log' -Filter 'gui-agent*.log'|Sort LastWriteTime -Desc|Select -First 1)
Write-Output ("RESULT=LOGFILE {0}" -f $log.Name)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @"
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
public class E {
  public delegate bool Cb(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(Cb c, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h,int x,int y,int w,int ht,bool rp);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr FindWindow(string c, string n);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out R r, int s);
  public struct R { public int l,t,r,b; }
  public static List<string> Go() {
    var o = new List<string>();
    EnumWindows((h,l) => {
      if (!IsWindowVisible(h)) return true;
      R r; if (!GetWindowRect(h, out r)) return true;
      int w = r.r-r.l, ht = r.b-r.t;
      if (w < 4 || ht < 4) return true;
      var t = new StringBuilder(256); GetWindowTextW(h, t, 256);
      var c = new StringBuilder(256); GetClassNameW(h, c, 256);
      R e; if (DwmGetWindowAttribute(h, 9, out e, 16) != 0) { e = r; }
      o.Add(string.Format("{0}\t{1}\t{2}\t{3}\t{4}\t{5}\t{6}\t{7}\t{8}\t{9}\t{10}\t{11}",
        h.ToInt64(), r.l, r.t, w, ht, GetWindowLong(h,-20), t.ToString().Replace("\t"," "), c.ToString(),
        e.l, e.t, e.r-e.l, e.b-e.t));
      return true;
    }, IntPtr.Zero);
    return o;
  }
}
"@
function Stamp { (Get-Date).ToString('yyyyMMdd.HHmmss.fff') }
function Emit($tag,$rows){ Write-Output "${tag}START"; foreach($r in $rows){ Write-Output $r }; Write-Output "${tag}END" }

# --- two overlapping Notepads -------------------------------------------------
$a = Start-Process notepad -PassThru; Start-Sleep 3
$b = Start-Process notepad -PassThru; Start-Sleep 3
$ha = $a.MainWindowHandle; $hb = $b.MainWindowHandle
[E]::MoveWindow($ha,150,120,700,500,$true) | Out-Null
[E]::MoveWindow($hb,500,320,700,500,$true) | Out-Null
Start-Sleep 3
Write-Output ("RESULT=BACKHWND {0}" -f $ha.ToInt64())
Write-Output ("RESULT=FRONTHWND {0}" -f $hb.ToInt64())

# FRONT (hb) on top, overlapping BACK's right/bottom. Type into FRONT: every keystroke
# repaints inside FRONT, and BACK must never receive damage in the covered region.
[E]::SetForegroundWindow($hb) | Out-Null
Start-Sleep 2
Write-Output ("PHASE type {0}" -f (Stamp))
foreach($i in 1..40){
  [System.Windows.Forms.SendKeys]::SendWait("qubes$i ")
  Start-Sleep -Milliseconds 120
}
Write-Output ("PHASE type-end {0}" -f (Stamp))
Start-Sleep 2

# --- File menu opened and HELD ------------------------------------------------
[E]::SetForegroundWindow($hb) | Out-Null
Start-Sleep 1
Write-Output ("PHASE menu {0}" -f (Stamp))
[System.Windows.Forms.SendKeys]::SendWait("%f")
Start-Sleep 3
$menu=[E]::FindWindow("#32768",$null)
if($menu -ne [IntPtr]::Zero){
  $rc=New-Object E+R; [E]::GetWindowRect($menu,[ref]$rc) | Out-Null
  Write-Output ("RESULT=MENUHWND {0} rect {1},{2} {3}x{4}" -f $menu.ToInt64(),$rc.l,$rc.t,($rc.r-$rc.l),($rc.b-$rc.t))
  for($i=0;$i -lt 6;$i++){ [E]::SetCursorPos($rc.l+40,$rc.t+15+($i*20)) | Out-Null; Start-Sleep -Milliseconds 400 }
} else {
  Write-Output "RESULT=MENUHWND NONE"
}
Write-Output ("PHASE menu-held {0}" -f (Stamp))
Start-Sleep 2

# geometry snapshot WITH the menu up (check-protocol.py ground truth)
Emit 'GEO' ([E]::Go())
Write-Output "TRACESTART"
Get-Content $log.FullName | Select-String 'QGAPROTO,' | ForEach-Object { $_.Line }
Write-Output "TRACEEND"
Write-Output "RESULT=SCN1DONE menu-left-open"
