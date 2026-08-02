$ErrorActionPreference='SilentlyContinue'
Get-Process notepad,chromerepro -EA SilentlyContinue | Stop-Process -Force
Start-Sleep 2
Add-Type -TypeDefinition @"
using System;using System.Runtime.InteropServices;
public class P{
 [DllImport("user32.dll")]public static extern bool MoveWindow(IntPtr h,int x,int y,int w,int t,bool r);
 [DllImport("user32.dll")]public static extern bool SetForegroundWindow(IntPtr h);}
"@
# 1. Notepad with real content: drag it (wobble) and open its menus (menu corruption / border)
$n1 = Start-Process notepad -PassThru; Start-Sleep 4
[P]::MoveWindow($n1.MainWindowHandle, 200, 150, 900, 650, $true) | Out-Null
[P]::SetForegroundWindow($n1.MainWindowHandle) | Out-Null
Start-Sleep 1
Add-Type -AssemblyName System.Windows.Forms
$body = (1..25 | ForEach-Object { "Line $_ - drag this window, then open the File and Edit menus." }) -join "`r"
[System.Windows.Forms.SendKeys]::SendWait($body)
Start-Sleep 2

# 2. A second Notepad overlapping the first: drag one across the other (occlusion / debris)
$n2 = Start-Process notepad -PassThru; Start-Sleep 4
[P]::MoveWindow($n2.MainWindowHandle, 750, 400, 800, 550, $true) | Out-Null
[P]::SetForegroundWindow($n2.MainWindowHandle) | Out-Null
Start-Sleep 1
[System.Windows.Forms.SendKeys]::SendWait("Overlapping window - drag me across the other one.")
Start-Sleep 2

# 3. chromerepro: 5 real top-level windows in the guest (1 main + 4 layered shadow strips).
#    Only the main one should be bordered in dom0 - that is the Office chrome fix.
$exe = 'C:\qwt-final2\optional\idd-driver\chromerepro.exe'
if (Test-Path $exe) { Start-Process $exe; Start-Sleep 3 }

# Settle: force a full repaint of every top-level window and let the damage drain, so the
# capture is of a settled desktop rather than a race. Without this the same binary measures
# both PASS and FAIL on consecutive runs.
Add-Type -TypeDefinition @"
using System;using System.Runtime.InteropServices;
public class S{
 public delegate bool Cb(IntPtr h,IntPtr l);
 [DllImport("user32.dll")]public static extern bool EnumWindows(Cb c,IntPtr l);
 [DllImport("user32.dll")]public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")]public static extern bool InvalidateRect(IntPtr h,IntPtr r,bool e);
 [DllImport("user32.dll")]public static extern bool UpdateWindow(IntPtr h);
 public static void Repaint(){
   EnumWindows((h,l)=>{ if(IsWindowVisible(h)){ InvalidateRect(h,IntPtr.Zero,true); UpdateWindow(h);} return true;},IntPtr.Zero);}}
"@
for ($r=0; $r -lt 3; $r++) { [S]::Repaint(); Start-Sleep -Milliseconds 900 }
Start-Sleep 3

Write-Output "=== guest top-level windows now visible ==="
Add-Type -TypeDefinition @"
using System;using System.Text;using System.Collections.Generic;using System.Runtime.InteropServices;
public class E{
 public delegate bool Cb(IntPtr h,IntPtr l);
 [DllImport("user32.dll")]public static extern bool EnumWindows(Cb c,IntPtr l);
 [DllImport("user32.dll")]public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")]public static extern bool GetWindowRect(IntPtr h,out R r);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)]public static extern int GetClassNameW(IntPtr h,StringBuilder s,int n);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)]public static extern int GetWindowTextW(IntPtr h,StringBuilder s,int n);
 public struct R{public int l,t,r,b;}
 public static List<string> Go(){var o=new List<string>();
  EnumWindows((h,l)=>{ if(!IsWindowVisible(h))return true; R r; GetWindowRect(h,out r);
   int w=r.r-r.l,ht=r.b-r.t; if(w<40||ht<40)return true;
   var c=new StringBuilder(256); GetClassNameW(h,c,256);
   var t=new StringBuilder(256); GetWindowTextW(h,t,256);
   o.Add(string.Format("  {0,5},{1,-5} {2,5}x{3,-5} {4}  [{5}]",r.l,r.t,w,ht,t.ToString(),c.ToString()));
   return true;},IntPtr.Zero); return o;}}
"@
foreach($l in [E]::Go()){ Write-Output $l }
