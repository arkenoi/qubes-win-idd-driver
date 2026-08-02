# Joint owner+child motion probe.
#
# The maskpush claim under test: while an owner and its SYNTHESIZED child move together, the
# recomputed mask is identical to the memo, so SynthUpdateMask must push nothing
# (QGADRAG,ev=maskpush absent). scn2's drag cannot show this - it closes the menu first, so
# there is no synthesized child at all during the drag.
#
# Here the File menu is opened (synthesized) and the OWNER is then moved in small steps while
# the menu stays up. The script also samples the menu's own rect each step, so the transcript
# records whether the child actually travelled with the owner (joint motion) or stayed put
# (in which case the mask legitimately changes and maskpush is expected - reported as such,
# not silently counted as a pass).
$ErrorActionPreference='SilentlyContinue'

Get-Process notepad -EA SilentlyContinue | Stop-Process -Force
Start-Sleep 2
Get-Process gui-agent -EA SilentlyContinue | Stop-Process -Force
Start-Sleep 16
$log=(Get-ChildItem 'C:\Program Files\Qubes Tools\log' -Filter 'gui-agent*.log'|Sort LastWriteTime -Desc|Select -First 1)
Write-Output ("RESULT=LOGFILE {0}" -f $log.Name)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @"
using System; using System.Text; using System.Runtime.InteropServices;
public class J {
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h,int x,int y,int w,int ht,bool rp);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr FindWindow(string c, string n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  public struct R { public int l,t,r,b; }
}
"@
function Stamp { (Get-Date).ToString('yyyyMMdd.HHmmss.fff') }

$p = Start-Process notepad -PassThru; Start-Sleep 4
$h = $p.MainWindowHandle
[J]::MoveWindow($h,400,300,700,500,$true) | Out-Null
Start-Sleep 2
[J]::SetForegroundWindow($h) | Out-Null
Start-Sleep 2
Write-Output ("RESULT=OWNERHWND {0}" -f $h.ToInt64())

[System.Windows.Forms.SendKeys]::SendWait("%f")
Start-Sleep 3
$menu=[J]::FindWindow("#32768",$null)
if($menu -eq [IntPtr]::Zero){ Write-Output "RESULT=MENUHWND NONE"; }
else {
  $rc=New-Object J+R; [J]::GetWindowRect($menu,[ref]$rc) | Out-Null
  Write-Output ("RESULT=MENUHWND {0} rect {1},{2} {3}x{4}" -f $menu.ToInt64(),$rc.l,$rc.t,($rc.r-$rc.l),($rc.b-$rc.t))
}

Write-Output ("PHASE jointmove {0}" -f (Stamp))
Write-Output "TRACKSTART"
for($i=0;$i -lt 40;$i++){
  $x = 400 + ($i*6)
  $y = 300 + ($i*3)
  [J]::MoveWindow($h,$x,$y,700,500,$true) | Out-Null
  Start-Sleep -Milliseconds 60
  $orc=New-Object J+R; [J]::GetWindowRect($h,[ref]$orc) | Out-Null
  $vis=0; $ml=-1; $mt=-1
  if($menu -ne [IntPtr]::Zero -and [J]::IsWindowVisible($menu)){
    $vis=1; $mrc=New-Object J+R; [J]::GetWindowRect($menu,[ref]$mrc) | Out-Null; $ml=$mrc.l; $mt=$mrc.t
  }
  Write-Output ("STEP {0} t={1} owner={2},{3} menuvis={4} menu={5},{6}" -f $i,(Stamp),$orc.l,$orc.t,$vis,$ml,$mt)
}
Write-Output "TRACKEND"
Write-Output ("PHASE jointmove-end {0}" -f (Stamp))
Start-Sleep 2
[System.Windows.Forms.SendKeys]::SendWait("{ESC}")
Start-Sleep 2
Write-Output ("PHASE closed {0}" -f (Stamp))

Write-Output "DRAGSTART"
Get-Content $log.FullName | Select-String 'QGADRAG,' | ForEach-Object { $_.Line }
Write-Output "DRAGEND"
Write-Output "TRACESTART"
Get-Content $log.FullName | Select-String 'QGAPROTO,' | ForEach-Object { $_.Line }
Write-Output "TRACEEND"
Write-Output "RESULT=JOINTDONE"
