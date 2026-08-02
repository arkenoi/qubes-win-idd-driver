# Win10 protocol regression, part 2: close the held menu, then DRAG the front Notepad by its
# title bar with synthetic SendInput (the #1861 workload). Emits the geometry snapshot at
# rest and the full QGAPROTO trace for check-protocol.py.
$ErrorActionPreference='SilentlyContinue'
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
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out R r, int s);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
  [DllImport("user32.dll", SetLastError=true)] static extern uint SendInput(uint n, INPUT[] p, int cb);
  [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Explicit)]   public struct U { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
  [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public U u; }
  public struct R { public int l,t,r,b; }
  const uint MOVE=0x0001, LDOWN=0x0002, LUP=0x0004, ABS=0x8000, VDESK=0x4000;
  static int vx,vy,vw,vh;
  public static string InitScreen(){ vx=GetSystemMetrics(76); vy=GetSystemMetrics(77); vw=GetSystemMetrics(78); vh=GetSystemMetrics(79);
    if(vw<2)vw=2; if(vh<2)vh=2; return vx+","+vy+" "+vw+"x"+vh; }
  static void Send(INPUT[] a){ uint n=SendInput((uint)a.Length,a,Marshal.SizeOf(typeof(INPUT)));
    if(n!=a.Length) throw new Exception("SendInput "+n+"/"+a.Length+" err="+Marshal.GetLastWin32Error()); }
  public static void MoveTo(int x,int y){ INPUT[] a=new INPUT[1]; a[0].type=0;
    a[0].u.mi.dx=(int)((long)(x-vx)*65535/(vw-1)); a[0].u.mi.dy=(int)((long)(y-vy)*65535/(vh-1));
    a[0].u.mi.dwFlags=MOVE|ABS|VDESK; Send(a); }
  public static void Button(bool down){ INPUT[] a=new INPUT[1]; a[0].type=0; a[0].u.mi.dwFlags=down?LDOWN:LUP; Send(a); }
  // Circular title-bar drag at ~60 Hz, run in C# so PowerShell object churn is not in the loop.
  public static string Drag(IntPtr h,int cx,int cy,int radius,double seconds,int hz){
    MoveTo(cx+radius,cy); System.Threading.Thread.Sleep(120); Button(true); System.Threading.Thread.Sleep(120);
    var sw=System.Diagnostics.Stopwatch.StartNew(); int n=0; double period=2.0;
    while(sw.Elapsed.TotalSeconds<seconds){
      double t=sw.Elapsed.TotalSeconds; double ang=2*Math.PI*t/period;
      MoveTo(cx+(int)(radius*Math.Cos(ang)), cy+(int)(radius*Math.Sin(ang))); n++;
      System.Threading.Thread.Sleep(1000/hz);
    }
    Button(false); System.Threading.Thread.Sleep(200);
    return n+" moves in "+sw.Elapsed.TotalSeconds.ToString("0.00")+"s";
  }
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

Write-Output ("RESULT=SCREEN {0}" -f [E]::InitScreen())

# close the menu left open by scn1
[System.Windows.Forms.SendKeys]::SendWait("{ESC}")
Start-Sleep 2
Write-Output ("PHASE menu-closed {0}" -f (Stamp))
Start-Sleep 2

# --- drag the front Notepad by its title bar ---------------------------------
$p=@(Get-Process notepad -EA SilentlyContinue | Sort-Object StartTime -Desc)
if($p.Count -lt 2){ Write-Output "RESULT=DRAG NO-NOTEPAD"; }
else {
  $h=$p[0].MainWindowHandle
  Write-Output ("RESULT=DRAGHWND {0}" -f $h.ToInt64())
  [E]::SetForegroundWindow($h) | Out-Null
  Start-Sleep 1
  $rc=New-Object E+R; [E]::GetWindowRect($h,[ref]$rc) | Out-Null
  # grab point: middle of the title bar
  $gx=[int](($rc.l+$rc.r)/2); $gy=$rc.t+14
  Write-Output ("PHASE drag {0}" -f (Stamp))
  $r=[E]::Drag($h,$gx,$gy,180,10.0,60)
  Write-Output ("RESULT=DRAGCADENCE {0}" -f $r)
  Write-Output ("PHASE drag-end {0}" -f (Stamp))
}
Start-Sleep 3

Emit 'GEO' ([E]::Go())
Write-Output "TRACESTART"
Get-Content $log.FullName | Select-String 'QGAPROTO,' | ForEach-Object { $_.Line }
Write-Output "TRACEEND"
Write-Output "RESULT=SCN2DONE"
