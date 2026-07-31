$ErrorActionPreference='SilentlyContinue'
# Restart the agent so every window gets a traced CREATE/MAP. Without it, windows that existed
# before the trace started have no announced origin, the occlusion check skips them, and the
# run reports PASS while proving nothing.
Get-Process gui-agent -EA SilentlyContinue | Stop-Process -Force
Start-Sleep 14
$f=(Get-ChildItem 'C:\Program Files\Qubes Tools\log' -Filter 'gui-agent*.log'|Sort LastWriteTime -Desc|Select -First 1)
Write-Output "LOGFILE $($f.Name)"
Get-Content $f.FullName | Select-String 'QGAPROTO (on|off)' | Select-Object -Last 1 | ForEach-Object { "GATE: $_" }
$mark=0   # log is fresh after the restart: read all of it, or startup CREATEs are missed
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @"
using System;using System.Text;using System.Collections.Generic;using System.Runtime.InteropServices;
public class M{
 public delegate bool Cb(IntPtr h,IntPtr l);
 [DllImport("user32.dll")]public static extern bool EnumWindows(Cb c,IntPtr l);
 [DllImport("user32.dll")]public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")]public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")]public static extern IntPtr FindWindow(string c,string n);
 [DllImport("user32.dll")]public static extern bool GetWindowRect(IntPtr h,out R r);
 [DllImport("user32.dll")]public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")]public static extern int GetWindowLong(IntPtr h,int i);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)]public static extern int GetClassNameW(IntPtr h,StringBuilder s,int n);
 public struct R{public int l,t,r,b;}
 public static List<string> Go(){var o=new List<string>();
  EnumWindows((h,l)=>{ if(!IsWindowVisible(h))return true; R r; GetWindowRect(h,out r);
   int w=r.r-r.l,ht=r.b-r.t; if(w<8||ht<8)return true;
   var c=new StringBuilder(256); GetClassNameW(h,c,256);
   o.Add(string.Format("{0}\t{1}\t{2}\t{3}\t{4}\t{5}\t{6}",h.ToInt64(),r.l,r.t,w,ht,
     GetWindowLong(h,-16), c.ToString())); return true;},IntPtr.Zero); return o;}}
"@
$p=Get-Process notepad -EA SilentlyContinue|Select -First 1
if(-not $p){$p=Start-Process notepad -PassThru;Start-Sleep 4}
[M]::SetForegroundWindow($p.MainWindowHandle)|Out-Null
Start-Sleep 1
[System.Windows.Forms.SendKeys]::SendWait("%f")
Start-Sleep 2
$menu=[M]::FindWindow("#32768",$null)
if($menu -ne [IntPtr]::Zero){
  $rc=New-Object M+R;[M]::GetWindowRect($menu,[ref]$rc)|Out-Null
  Write-Output ("MENUHWND {0}" -f $menu.ToInt64())
  for($i=0;$i -lt 6;$i++){ [M]::SetCursorPos($rc.l+40,$rc.t+15+($i*20))|Out-Null; Start-Sleep -Milliseconds 400 }
}
Start-Sleep 1
Write-Output "GUESTSTART"
foreach($l in [M]::Go()){ Write-Output $l }
Write-Output "GUESTEND"
Write-Output "TRACESTART"
Get-Content $f.FullName | Select-Object -Skip $mark | Select-String 'QGAPROTO,' | ForEach-Object { $_.Line }
Write-Output "TRACEEND"
[System.Windows.Forms.SendKeys]::SendWait("{ESC}")
