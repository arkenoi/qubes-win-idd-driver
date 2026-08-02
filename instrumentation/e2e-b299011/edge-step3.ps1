$ErrorActionPreference='SilentlyContinue'
$logdir='C:\Program Files\Qubes Tools\log'
$log = Get-ChildItem $logdir -Filter 'gui-agent*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Write-Output ("RESULT=LOG:{0}|len={1}|mtime={2}" -f $log.Name,$log.Length,$log.LastWriteTime.ToString('o'))
Write-Output ("RESULT=PID:{0}" -f (Get-Process gui-agent).Id)
$k='HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools'
foreach($n in @('LogLevel','LogDir','ProtoTrace')){
  Write-Output ("RESULT=REG:{0}={1}" -f $n, (Get-ItemProperty -Path $k -Name $n -EA SilentlyContinue).$n)
}
Get-ItemProperty -Path $k | Format-List | Out-String | ForEach-Object { $_ -split "`n" } | ForEach-Object { Write-Output ("REGDUMP:"+$_.TrimEnd()) }
Write-Output "LOGSTART"
Get-Content $log.FullName -Encoding Unicode | ForEach-Object { Write-Output ("L:"+$_) }
Write-Output "LOGEND"
Write-Output "RESULT=DONE"
