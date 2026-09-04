# a0-consent.ps1 — set the UserNotificationListener consent value in the CURRENT user's hive
# (run via run-as-user.ps1 -Script) to Allow or Deny, for the toast-bridge fail-open proof.
param([ValidateSet('Allow','Deny')][string]$Value = 'Allow')
$ErrorActionPreference = 'Continue'
$k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\userNotificationListener'
if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
Set-ItemProperty -Path $k -Name Value -Value $Value
Write-Output ('CONSENT-NOW=' + (Get-ItemProperty -Path $k -Name Value).Value)
