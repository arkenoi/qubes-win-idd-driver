# menu-stim.ps1 - open a Win11 context menu N times and report the popup HWNDs it created.
#
# The agent logs one `QGASLICEMAP hwnd=0x.. held_ms=..` per first map; held_ms is how long
# crop-before-show DEFERRED that window's map. To attribute those lines to menus (and not to
# every other window that happens to map), this prints the HWND of each popup it actually
# created, so the host side can match on hwnd instead of guessing by time.
#
# Output: one `POPUP=<hex> t=<ms-since-start>` per opened menu, then `=== RESULT === {json}`.
param([int]$Count = 12, [int]$SettleMs = 1500, [int]$HoldMs = 1800)
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
Add-Type @'
using System; using System.Runtime.InteropServices; using System.Text; using System.Collections.Generic;
public class M {
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
 [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, UIntPtr e);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p, IntPtr l);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
 public delegate bool EnumProc(IntPtr h, IntPtr l);
 [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
 public static List<IntPtr> Tops(){ var r=new List<IntPtr>(); EnumWindows((w,l)=>{ if(IsWindowVisible(w)) r.Add(w); return true;}, IntPtr.Zero); return r; }
 public static string Cls(IntPtr h){ var s=new StringBuilder(160); GetClassName(h,s,160); return s.ToString(); }
}
'@
# A menu popup on Win11 is a WinUI windowed-popup host; the classic path is #32768.
function PopupSet(){
  $d=@{}
  foreach($w in [M]::Tops()){ $c=[M]::Cls($w); if($c -match '32768|PopupWindowSiteBridge|PopupHost|DropDown'){ $d[[int64]$w]=$c } }
  return $d
}
$exp=$null
foreach($w in [M]::Tops()){ if([M]::Cls($w) -eq 'CabinetWClass'){ $exp=$w; break } }
if(-not $exp){
  Start-Process explorer.exe 'C:\Users\Public'
  for($i=0;$i -lt 40 -and -not $exp;$i++){ Start-Sleep -Milliseconds 500; foreach($w in [M]::Tops()){ if([M]::Cls($w) -eq 'CabinetWClass'){ $exp=$w; break } } }
}
if(-not $exp){ Write-Host '=== RESULT === {"ok":false,"error":"no explorer window"}'; exit 2 }
$r=New-Object M+RECT; [M]::GetWindowRect($exp,[ref]$r) | Out-Null
$x=$r.L+[int](($r.R-$r.L)*0.55); $y=$r.T+[int](($r.B-$r.T)*0.72)
$sw=[Diagnostics.Stopwatch]::StartNew()
$opened=0
for($n=1; $n -le $Count; $n++){
  [M]::SetForegroundWindow($exp) | Out-Null; Start-Sleep -Milliseconds 250
  $before = PopupSet
  [M]::SetCursorPos($x,$y) | Out-Null; Start-Sleep -Milliseconds 150
  [M]::mouse_event(0x0008,0,0,0,[UIntPtr]::Zero); Start-Sleep -Milliseconds 90; [M]::mouse_event(0x0010,0,0,0,[UIntPtr]::Zero)
  # Poll for a NEW popup rather than sleeping a fixed time: the guest-side render latency is
  # Windows' own and is not what we are measuring - we want the HWND, and the agent's own
  # held_ms carries the part we can actually reduce.
  $new=$null
  for($k=0;$k -lt 60 -and -not $new;$k++){
    Start-Sleep -Milliseconds 50
    foreach($kv in (PopupSet).GetEnumerator()){ if(-not $before.ContainsKey($kv.Key)){ $new=$kv; break } }
  }
  if($new){ $opened++; Write-Host ("POPUP=0x{0:x} t={1} cls={2}" -f [int64]$new.Key, $sw.ElapsedMilliseconds, $new.Value) }
  else { Write-Host ("POPUP=none t={0}" -f $sw.ElapsedMilliseconds) }
  # HOLD THE MENU OPEN before dismissing. crop-before-show can defer a menu's map for up to
  # CROP_BEFORE_SHOW_TIMEOUT_MS (700 ms); dismissing the instant the HWND appears destroys the
  # window while it is STILL DEFERRED, so it never maps, emits no timing line, and the run
  # measures nothing (observed 2026-09-11: nine opens, one map, zero QGAHELDMAP). $HoldMs must
  # therefore exceed the ceiling - a real user holding a menu open is the case being measured.
  Start-Sleep -Milliseconds $HoldMs
  [System.Windows.Forms.SendKeys]::SendWait('{ESC}')
  Start-Sleep -Milliseconds $SettleMs
}
Write-Host ("=== RESULT === {`"ok`":true,`"requested`":$Count,`"opened`":$opened}")
