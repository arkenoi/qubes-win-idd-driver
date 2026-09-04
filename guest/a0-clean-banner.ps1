# a0-clean-banner.ps1 — remove the toast-bridge demo residue for one AUMID in the CURRENT
# user's hive (run via run-as-user.ps1 -Script): the ShowBanner=0 suppression the 2026-09-04
# PS bridge demo left standing, plus any bridge stop/marker files. Prints the resulting state.
param(
    [string]$Aumid = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
)
$ErrorActionPreference = 'Continue'
$k = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\$Aumid"
Remove-ItemProperty -Path $k -Name ShowBanner -EA SilentlyContinue
$v = (Get-ItemProperty -Path $k -EA SilentlyContinue).ShowBanner
Remove-Item 'C:\ProgramData\qubes-toast-bridge\stop' -Force -EA SilentlyContinue
Remove-Item 'C:\ProgramData\qubes-toast-bridge\banner-*.prev' -Force -EA SilentlyContinue
Write-Output ('SHOWBANNER-NOW=' + $(if ($null -eq $v) { 'absent' } else { $v }))
