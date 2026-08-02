# 2A-chrome regression: chromerepro creates 1 real window + 4 Office-style shadow strips.
# Acceptance is measured from the AGENT's own SendWindowMap lines, never from screenshot PNGs
# (import -window silently fails on layered/transparent windows, which produced a false PASS
# before the fix was even installed - see tools/chromerepro/README.md).
$ErrorActionPreference='SilentlyContinue'
$exe="$env:USERPROFILE\Documents\QubesIncoming\win-idd-mgmt\chromerepro.exe"
if(-not (Test-Path $exe)){ Write-Output "RESULT=CHROMEREPRO MISSING"; exit 1 }
Write-Output ("RESULT=EXEHASH {0}" -f (Get-FileHash $exe -Algorithm SHA256).Hash)

Get-Process chromerepro -EA SilentlyContinue | Stop-Process -Force
Start-Sleep 2
# fresh agent log so the SendWindowMap census covers exactly this run
Get-Process gui-agent -EA SilentlyContinue | Stop-Process -Force
Start-Sleep 16
$log=(Get-ChildItem 'C:\Program Files\Qubes Tools\log' -Filter 'gui-agent*.log'|Sort LastWriteTime -Desc|Select -First 1)
Write-Output ("RESULT=LOGFILE {0}" -f $log.Name)

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
  public struct R { public int l,t,r,b; }
  public static List<string> ByPid(uint want) {
    var o = new List<string>();
    EnumWindows((h,l) => {
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (pid != want) return true;
      if (!IsWindowVisible(h)) return true;
      R r; GetWindowRect(h, out r);
      var c = new StringBuilder(256); GetClassNameW(h,c,256);
      var t = new StringBuilder(256); GetWindowTextW(h,t,256);
      o.Add(string.Format("{0}\t0x{0:x}\t{1},{2}\t{3}x{4}\tstyle=0x{5:x8}\tex=0x{6:x8}\t{7}\t{8}",
        h.ToInt64(), r.l, r.t, r.r-r.l, r.b-r.t,
        (uint)GetWindowLong(h,-16), (uint)GetWindowLong(h,-20), c.ToString(), t.ToString().Replace("\t"," ")));
      return true;
    }, IntPtr.Zero);
    return o;
  }
}
"@

$p = Start-Process $exe -PassThru
Start-Sleep 8
Write-Output ("RESULT=CHROMEPID {0}" -f $p.Id)
$rows = [C]::ByPid([uint32]$p.Id)
Write-Output ("RESULT=GUEST-COUNT {0}" -f $rows.Count)
Write-Output "OURWINSTART"
foreach($r in $rows){ Write-Output $r }
Write-Output "OURWINEND"

Start-Sleep 4
# how many of OUR hwnds the agent announced to dom0
$maps = @(Get-Content $log.FullName | Select-String 'SendWindowMap')
$ours = @()
foreach($r in $rows){
  $hex = ('0x{0:x}' -f ([int64]($r.Split("`t")[0])))
  $hit = @($maps | Where-Object { $_.Line -match [regex]::Escape($hex) })
  if($hit.Count -gt 0){ $ours += $hex }
}
Write-Output ("RESULT=MAPPED-OF-OURS {0}" -f $ours.Count)
Write-Output ("RESULT=MAPPED-HWNDS {0}" -f ($ours -join ' '))
Write-Output ("RESULT=TOTAL-SENDWINDOWMAP {0}" -f $maps.Count)
Write-Output "MAPSTART"
foreach($m in $maps){ Write-Output $m.Line }
Write-Output "MAPEND"
Write-Output "INVSTART"
Get-Content "$env:TEMP\chromerepro.txt" -EA SilentlyContinue | ForEach-Object { $_ }
Write-Output "INVEND"
Write-Output "REJECTSTART"
Get-Content $log.FullName | Select-String 'rejecting|sub-floor|fully transparent' | ForEach-Object { $_.Line }
Write-Output "REJECTEND"
Write-Output "RESULT=CHROMEDONE"
