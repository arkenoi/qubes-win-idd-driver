$ErrorActionPreference='SilentlyContinue'
$logdir='C:\Program Files\Qubes Tools\log'
function NewestLog { Get-ChildItem $logdir -Filter 'gui-agent*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1 }
$pre = NewestLog
$prePid = (Get-Process gui-agent).Id
Write-Output ("RESULT=PRE_LOG:{0}|len={1}" -f $pre.Name, $pre.Length)
Write-Output ("RESULT=PRE_PID:{0}" -f $prePid)
Write-Output ("RESULT=PRE_LOGCOUNT:{0}" -f (Get-ChildItem $logdir -Filter 'gui-agent*.log').Count)
Write-Output ("RESULT=T_LAUNCH:{0}" -f (Get-Date).ToString('o'))

$edge='C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
$p = Start-Process $edge -PassThru
Write-Output ("RESULT=EDGE_PID:{0}" -f $p.Id)

Start-Sleep -Seconds 60

Write-Output ("RESULT=T_SETTLED:{0}" -f (Get-Date).ToString('o'))
$post = NewestLog
Write-Output ("RESULT=POST_LOG:{0}|len={1}" -f $post.Name, $post.Length)
Write-Output ("RESULT=POST_LOGCOUNT:{0}" -f (Get-ChildItem $logdir -Filter 'gui-agent*.log').Count)
$pp = Get-Process gui-agent
foreach($q in $pp){ Write-Output ("RESULT=POST_PID:{0}|start={1}" -f $q.Id, $q.StartTime.ToString('o')) }
Write-Output ("RESULT=EDGE_PROCS:{0}" -f (@(Get-Process msedge).Count))

Add-Type -TypeDefinition @"
using System; using System.Text; using System.Collections.Generic; using System.Runtime.InteropServices;
public class C {
  public delegate bool Cb(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(Cb c, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern bool GetLayeredWindowAttributes(IntPtr h, out uint key, out byte alpha, out uint flags);
  public struct R { public int l,t,r,b; }
  public static List<string> All() {
    var o = new List<string>();
    EnumWindows((h,l) => {
      if (!IsWindowVisible(h)) return true;
      uint pid; GetWindowThreadProcessId(h, out pid);
      R r; GetWindowRect(h, out r);
      var c = new StringBuilder(256); GetClassNameW(h,c,256);
      var t = new StringBuilder(256); GetWindowTextW(h,t,256);
      int ex = GetWindowLong(h,-20);
      uint k; byte a; uint f; bool glwa = GetLayeredWindowAttributes(h, out k, out a, out f);
      o.Add(string.Format("0x{0:x}\tpid={1}\t{2},{3}\t{4}x{5}\tstyle=0x{6:x8}\tex=0x{7:x8}\tglwa={8}\t{9}\t{10}",
        h.ToInt64(), pid, r.l, r.t, r.r-r.l, r.b-r.t,
        (uint)GetWindowLong(h,-16), (uint)ex, glwa, c.ToString(), t.ToString().Replace("\t"," ")));
      return true;
    }, IntPtr.Zero);
    return o;
  }
}
"@
Write-Output "WINSTART"
foreach($r in [C]::All()){ Write-Output $r }
Write-Output "WINEND"
Write-Output "RESULT=DONE"
