$ErrorActionPreference='SilentlyContinue'
Write-Output "GATE0START"
$exe='C:\Program Files\Qubes Tools\bin\gui-agent.exe'
if(Test-Path $exe){
  $h=(Get-FileHash $exe -Algorithm SHA256).Hash
  Write-Output "RESULT=AGENTHASH $h"
} else { Write-Output "RESULT=AGENTHASH MISSING" }
$orig=@(Get-ChildItem 'C:\Program Files\Qubes Tools\bin' -Filter '*.orig' -EA SilentlyContinue)
Write-Output ("RESULT=ORIGCOUNT {0}" -f $orig.Count)
$bc = & bcdedit /enum '{current}' 2>&1 | Select-String 'testsigning'
Write-Output ("RESULT=TESTSIGNING {0}" -f (($bc -join ' ').Trim()))
$svc=@(Get-Service | Where-Object { $_.DisplayName -match 'Qubes' } | ForEach-Object { "$($_.Name)=$($_.Status)" })
Write-Output ("RESULT=SERVICES {0}" -f ($svc -join ';'))
$p=Get-Process gui-agent -EA SilentlyContinue
if($p){ Write-Output ("RESULT=AGENTPID {0} start {1}" -f $p.Id, $p.StartTime.ToString('yyyy-MM-dd HH:mm:ss')) } else { Write-Output "RESULT=AGENTPID NONE" }
$k='HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools\gui-agent'
$kp='HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools'
foreach($key in @($k,$kp)){
  if(Test-Path $key){
    $it=Get-ItemProperty $key
    $vals=@()
    foreach($n in @('LogLevel','ProtoTrace','PerfLog','PerfEveryN')){
      if($it.PSObject.Properties.Name -contains $n){ $vals += "$n=$($it.$n)" } else { $vals += "$n=<absent>" }
    }
    Write-Output ("RESULT=REG [{0}] {1}" -f $key, ($vals -join ' '))
  } else { Write-Output ("RESULT=REG [{0}] KEYABSENT" -f $key) }
}
$logs=@(Get-ChildItem 'C:\Program Files\Qubes Tools\log' -Filter 'gui-agent*.log' -EA SilentlyContinue | Sort-Object LastWriteTime -Desc)
Write-Output ("RESULT=LOGCOUNT {0}" -f $logs.Count)
if($logs.Count -gt 0){ Write-Output ("RESULT=NEWESTLOG {0} {1} {2}" -f $logs[0].Name,$logs[0].Length,$logs[0].LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')) }
Write-Output ("RESULT=INCOMING {0}" -f "$env:USERPROFILE\Documents\QubesIncoming")
Get-ChildItem "$env:USERPROFILE\Documents\QubesIncoming" -EA SilentlyContinue | ForEach-Object { Write-Output ("RESULT=INCOMINGSUB {0}" -f $_.Name) }
Write-Output "GATE0END"
