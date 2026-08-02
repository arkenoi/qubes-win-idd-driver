$ErrorActionPreference = 'SilentlyContinue'
$logdir = 'C:\Program Files\Qubes Tools\log'
Write-Output "RESULT=LOGDIR_EXISTS:$(Test-Path $logdir)"
$logs = Get-ChildItem -Path $logdir -Filter 'gui-agent*.log' | Sort-Object LastWriteTime -Descending
Write-Output "RESULT=LOGCOUNT:$($logs.Count)"
foreach ($l in $logs | Select-Object -First 8) {
  Write-Output ("RESULT=LOG:{0}|{1}|{2}" -f $l.Name, $l.LastWriteTime.ToString('o'), $l.Length)
}
$p = Get-Process -Name gui-agent
foreach ($q in $p) {
  Write-Output ("RESULT=PID:{0}|start={1}|path={2}" -f $q.Id, $q.StartTime.ToString('o'), $q.Path)
}
Write-Output "RESULT=NOW:$((Get-Date).ToString('o'))"
# Edge presence / first-run state
$edge = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
Write-Output "RESULT=EDGEEXE:$(Test-Path $edge)"
if (Test-Path $edge) { Write-Output "RESULT=EDGEVER:$((Get-Item $edge).VersionInfo.FileVersion)" }
$profdir = "$env:LOCALAPPDATA\Microsoft\Edge\User Data"
Write-Output "RESULT=EDGEPROFILE_EXISTS:$(Test-Path $profdir)"
if (Test-Path $profdir) {
  Write-Output "RESULT=EDGEPROFILE_ITEMS:$((Get-ChildItem $profdir -Recurse -ErrorAction SilentlyContinue).Count)"
}
Write-Output "RESULT=EDGERUNNING:$((Get-Process -Name msedge -ErrorAction SilentlyContinue | Measure-Object).Count)"
# what windows exist now
Add-Type @"
using System;using System.Runtime.InteropServices;using System.Text;
public class W {
 [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
 public delegate bool EnumWindowsProc(IntPtr h, IntPtr l);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h,StringBuilder s,int n);
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h,StringBuilder s,int n);
 [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h,int i);
}
"@
$sb = New-Object System.Text.StringBuilder 512
$list = New-Object System.Collections.ArrayList
$cb = [W+EnumWindowsProc]{ param($h,$l)
  if ([W]::IsWindowVisible($h)) {
    $sb.Clear() | Out-Null; [W]::GetWindowTextW($h,$sb,512) | Out-Null; $t = $sb.ToString()
    $sb.Clear() | Out-Null; [W]::GetClassNameW($h,$sb,512) | Out-Null; $c = $sb.ToString()
    if ($t.Length -gt 0) {
      $ex = [W]::GetWindowLong($h,-20)
      $null = $list.Add(("RESULT=WIN:0x{0:x}|ex=0x{1:x}|{2}|{3}" -f [int64]$h, $ex, $c, $t))
    }
  }
  return $true
}
[W]::EnumWindows($cb,[IntPtr]::Zero) | Out-Null
$list | ForEach-Object { Write-Output $_ }
Write-Output "RESULT=DONE"
