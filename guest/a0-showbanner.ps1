# a0-showbanner.ps1 — report the ShowBanner state for one AUMID in the CURRENT user's hive
# (run via run-as-user.ps1 -Script). Used to prove the bridge RESTORED the user's setting on
# exit (fail-open ShowBanner lifecycle, DESIGN-toast-bridge.md P.6 top risk).
param([string]$Aumid = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe')
$ErrorActionPreference = 'Continue'
$v = (Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\$Aumid" -EA SilentlyContinue).ShowBanner
Write-Output ('SHOWBANNER-NOW=' + $(if ($null -eq $v) { 'absent' } else { $v }))
