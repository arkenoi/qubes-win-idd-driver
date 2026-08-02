$ErrorActionPreference='SilentlyContinue'
$logdir='C:\Program Files\Qubes Tools\log'
$log = Get-ChildItem $logdir -Filter 'gui-agent*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Write-Output ("RESULT=LOG:{0}|len={1}" -f $log.Name,$log.Length)
Write-Output ("RESULT=LOGCOUNT:{0}" -f (Get-ChildItem $logdir -Filter 'gui-agent*.log').Count)
foreach($l in (Get-ChildItem $logdir -Filter 'gui-agent*.log' | Sort-Object LastWriteTime -Descending)){
  Write-Output ("RESULT=LOGLIST:{0}|{1}" -f $l.Name,$l.LastWriteTime.ToString('o'))
}
$q = Get-Process gui-agent
Write-Output ("RESULT=PID:{0}|start={1}" -f $q.Id,$q.StartTime.ToString('o'))
Write-Output ("RESULT=EDGE_PROCS:{0}" -f (@(Get-Process msedge)).Count)
Write-Output "LOGSTART"
Get-Content $log.FullName -Encoding Unicode | ForEach-Object { Write-Output ("L:"+$_) }
Write-Output "LOGEND"
Write-Output "RESULT=DONE"
