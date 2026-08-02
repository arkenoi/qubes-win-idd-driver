$ErrorActionPreference='SilentlyContinue'
$p = "$env:LOCALAPPDATA\Microsoft\Edge\User Data"
Get-ChildItem $p -Recurse -Force | ForEach-Object {
  Write-Output ("RESULT=ITEM:{0}|{1}|{2}" -f $_.FullName.Replace($p,''), $_.LastWriteTime.ToString('o'), $(if($_.PSIsContainer){'DIR'}else{$_.Length}))
}
Write-Output "RESULT=FIRSTRUNSENTINEL:$(Test-Path "$p\First Run")"
Write-Output "RESULT=DEFAULTPROFILE:$(Test-Path "$p\Default")"
Write-Output "RESULT=LOCALSTATE:$(Test-Path "$p\Local State")"
Write-Output "RESULT=DONE"
