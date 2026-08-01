$boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
Write-Output "=== NETFORENSICS $(Get-Date -Format o) boot=$($boot.ToString('o')) ==="
Write-Output "=== XENBUS enum (did a VIF device ever appear?) ==="
Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\XENBUS' -ErrorAction SilentlyContinue |
  ForEach-Object { "ENUM $($_.PSChildName)" }
Write-Output "=== XEN Unplug values (was the NIC unplug armed?) ==="
$u = 'HKLM:\SYSTEM\CurrentControlSet\Services\XEN\Unplug'
if (Test-Path $u) { (Get-ItemProperty $u).PSObject.Properties |
  Where-Object { $_.Name -notmatch '^PS' } | ForEach-Object { "UNPLUG $($_.Name)=$($_.Value)" } }
else { Write-Output "UNPLUG key ABSENT" }
Write-Output "=== XENVIF enum (did xenvif enumerate a NET child?) ==="
Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\XENVIF' -ErrorAction SilentlyContinue |
  ForEach-Object { "ENUMVIF $($_.PSChildName)" }
Write-Output "=== xenvif Settings (did PdoParseMibTable see the aliasing NIC?) ==="
Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\xenvif\Settings' -Recurse -ErrorAction SilentlyContinue |
  ForEach-Object { "VIFSET $($_.Name -replace '.*\\Settings','Settings')" }
Write-Output "=== xenbus_monitor Request (volatile, boot-1 reboot request) ==="
Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\xenbus_monitor\Request' -ErrorAction SilentlyContinue |
  ForEach-Object { "MONREQ $($_.PSChildName)" }
Write-Output "=== XENFILT active device (unplug gate) ==="
$xf = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\XENFILT\Parameters' -ErrorAction SilentlyContinue
if ($xf) { $xf.PSObject.Properties | Where-Object { $_.Name -match '^Active' } |
  ForEach-Object { "XENFILT $($_.Name)=$($_.Value)" } } else { Write-Output "XENFILT Parameters ABSENT" }
Write-Output "=== testsigning ==="
bcdedit /enum '{current}' 2>$null | Select-String -Pattern 'testsigning' | ForEach-Object { "BCD $($_.Line.Trim())" }
Write-Output "=== xenvif/xennet service + driver store ==="
foreach ($s in 'xenvif','xennet','xenbus','xenfilt','xeniface') {
  $svc = Get-Service $s -ErrorAction SilentlyContinue
  $reg = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\$s" -ErrorAction SilentlyContinue
  "SVC $s status=$(if($svc){$svc.Status}else{'absent'}) start=$(if($reg){$reg.Start}else{'-'})"
}
pnputil /enum-drivers 2>$null | Select-String -Context 0,4 'xenvif|xennet' | ForEach-Object { "DRVSTORE $($_.Line) $($_.Context.PostContext -join ' | ')" }
Write-Output "=== PnP devices ==="
Get-PnpDevice -ErrorAction SilentlyContinue |
  Where-Object { $_.InstanceId -match 'XENBUS|XENVIF' -or $_.FriendlyName -match 'Xen|Realtek|Ethernet' } |
  ForEach-Object { "PNP [$($_.Status)] $($_.FriendlyName) :: $($_.InstanceId) problem=$($_.ProblemCode)" }
Write-Output "=== setupapi: xenvif/xennet install attempts ==="
$sa = 'C:\Windows\INF\setupapi.dev.log'
if (Test-Path $sa) {
  Get-Content $sa -Tail 4000 | Select-String -Pattern 'xenvif|xennet|XENBUS\\VEN' |
    Select-Object -Last 25 | ForEach-Object { "SETUPAPI $($_.Line.Trim())" }
} else { Write-Output "no setupapi.dev.log" }
Write-Output "=== driver file identity (are these the stock ITL bits?) ==="
foreach ($f in 'xenvif.sys','xennet.sys','xenbus.sys') {
  $p = "C:\Windows\System32\drivers\$f"
  if (Test-Path $p) { "FILE $f $((Get-FileHash $p -Algorithm SHA256).Hash.ToLower()) size=$((Get-Item $p).Length)" }
  else { "FILE $f ABSENT" }
}
Write-Output "=== recent system errors ==="
Get-WinEvent -FilterHashtable @{LogName='System'; Level=1,2; StartTime=(Get-Date).AddHours(-2)} -MaxEvents 15 -ErrorAction SilentlyContinue |
  ForEach-Object { "EVT $($_.TimeCreated.ToString('HH:mm:ss')) $($_.ProviderName) id=$($_.Id) $(($_.Message -split "`n")[0])" }
