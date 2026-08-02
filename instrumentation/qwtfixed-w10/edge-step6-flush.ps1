# Flush driver: the agent log is block-buffered (LogSafeFlush=0) and the guest went idle
# right after Edge closed, so the tail of the Edge close sequence is stuck in the write
# buffer. Generate ~10 s of frame volume with a throwaway Notepad, then close it.
$ErrorActionPreference='SilentlyContinue'
Write-Output ("RESULT=FLUSH_BEGIN:{0}" -f (Get-Date).ToString('o'))
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public class M {
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr a,int x,int y,int w,int t,uint f);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h,uint m,IntPtr w,IntPtr l);
}
"@
$p = Start-Process notepad -PassThru
Start-Sleep 4
$p.Refresh()
$h = $p.MainWindowHandle
Write-Output ("RESULT=NOTEPAD_HWND:0x{0:x}" -f $h.ToInt64())
for($i=0;$i -lt 200;$i++){
  $x = 200 + ($i % 60) * 12
  $y = 200 + [int]([math]::Abs(30 - ($i % 60)) * 8)
  [M]::SetWindowPos($h,[IntPtr]::Zero,$x,$y,900,600,0x0014) | Out-Null
  Start-Sleep -Milliseconds 45
}
[M]::PostMessage($h,0x0010,[IntPtr]::Zero,[IntPtr]::Zero) | Out-Null
Start-Sleep 6
Write-Output ("RESULT=NOTEPAD_PROCS:{0}" -f (@(Get-Process notepad)).Count)
Write-Output ("RESULT=FLUSH_END:{0}" -f (Get-Date).ToString('o'))
$logdir='C:\Program Files\Qubes Tools\log'
$log = Get-ChildItem $logdir -Filter 'gui-agent*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Write-Output ("RESULT=LOG:{0}|len={1}" -f $log.Name,$log.Length)
Write-Output ("RESULT=LOGCOUNT:{0}" -f (Get-ChildItem $logdir -Filter 'gui-agent*.log').Count)
$q=Get-Process gui-agent
Write-Output ("RESULT=PID:{0}|start={1}" -f $q.Id,$q.StartTime.ToString('o'))
Write-Output "RESULT=DONE"
