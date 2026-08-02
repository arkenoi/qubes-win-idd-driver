$ErrorActionPreference='SilentlyContinue'
Write-Output ("RESULT=T_CLOSE_BEGIN:{0}" -f (Get-Date).ToString('o'))
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public class K {
  [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeout(IntPtr h, uint m, IntPtr w, IntPtr l, uint fl, uint to, out IntPtr res);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
}
"@
$procs = @(Get-Process msedge)
Write-Output ("RESULT=EDGE_PROCS_BEFORE:{0}" -f $procs.Count)
foreach($p in $procs){
  if ($p.MainWindowHandle -ne 0) {
    Write-Output ("RESULT=CLOSING:0x{0:x}|pid={1}" -f $p.MainWindowHandle.ToInt64(), $p.Id)
    [K]::PostMessage($p.MainWindowHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
  }
}
Start-Sleep 12
$left = @(Get-Process msedge)
Write-Output ("RESULT=EDGE_PROCS_AFTER_WMCLOSE:{0}" -f $left.Count)
if ($left.Count -gt 0) {
  Write-Output "RESULT=FORCE_KILL:yes"
  $left | Stop-Process -Force
  Start-Sleep 8
}
Write-Output ("RESULT=EDGE_PROCS_FINAL:{0}" -f (@(Get-Process msedge)).Count)
Start-Sleep 10
Write-Output ("RESULT=T_CLOSE_END:{0}" -f (Get-Date).ToString('o'))
$logdir='C:\Program Files\Qubes Tools\log'
$log = Get-ChildItem $logdir -Filter 'gui-agent*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Write-Output ("RESULT=LOG:{0}|len={1}" -f $log.Name,$log.Length)
Write-Output ("RESULT=LOGCOUNT:{0}" -f (Get-ChildItem $logdir -Filter 'gui-agent*.log').Count)
$q = Get-Process gui-agent
Write-Output ("RESULT=PID:{0}|start={1}" -f $q.Id, $q.StartTime.ToString('o'))
Write-Output "RESULT=DONE"
