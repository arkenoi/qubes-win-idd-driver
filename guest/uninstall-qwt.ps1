$ErrorActionPreference='SilentlyContinue'
$roots='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
$p=@(Get-ItemProperty $roots | Where-Object { $_.DisplayName -match 'Qubes' })
foreach ($q in $p) {
  Write-Output ("UNINSTALLING=" + $q.DisplayName + " " + $q.PSChildName)
  $pr = Start-Process msiexec.exe -Wait -PassThru -ArgumentList @('/x',$q.PSChildName,'/qn','/norestart','REBOOT=ReallySuppress','/l*v!','C:\qwt-uninst.log')
  Write-Output ("UNINSTALL_RC=" + $pr.ExitCode)
}
$after=@(Get-ItemProperty $roots | Where-Object { $_.DisplayName -match 'Qubes' })
Write-Output ("QWT_REMAINING=" + $after.Count)
