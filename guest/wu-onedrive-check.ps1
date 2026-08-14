# Does the OneDrive first-run popup fire BEFORE our post-install tuning, or in spite of it?
# quiet-desktop.ps1 is NOT part of install-updater-agent.ps1, so on a freshly cloned image nothing
# has suppressed OneDrive at the point the first logon happens. This prints the evidence either way:
# whether the suppression policies exist at all, and what is still wired to run at logon.
$ErrorActionPreference = 'Continue'
Write-Output '=== RESULT ==='

$pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive'
Write-Output ("policy_DisableFileSyncNGSC = {0}" -f (Get-ItemProperty $pol -Name DisableFileSyncNGSC -EA SilentlyContinue).DisableFileSyncNGSC)
Write-Output ("policy_key_exists          = {0}" -f (Test-Path $pol))

# What actually launches it at logon.
foreach ($hive in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
                    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run')) {
    $it = Get-Item $hive -EA SilentlyContinue
    if ($it) {
        foreach ($n in $it.GetValueNames()) {
            if ($n -match 'OneDrive|Onedrive') {
                Write-Output ("run_entry {0}\{1} = {2}" -f $hive, $n, (Get-ItemProperty $hive -Name $n).$n)
            }
        }
    }
}
$setup = 'C:\Windows\SysWOW64\OneDriveSetup.exe','C:\Windows\System32\OneDriveSetup.exe'
foreach ($s in $setup) { if (Test-Path $s) { Write-Output ("present: {0}" -f $s) } }
Write-Output ("onedrive_running = {0}" -f @(Get-Process OneDrive -EA SilentlyContinue).Count)

# Did the desktop tuning ever run on this image? These are the keys quiet-desktop.ps1 writes.
$cdm = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
Write-Output ("tuning_marker_SilentInstalledAppsEnabled = {0}" -f (Get-ItemProperty $cdm -Name SilentInstalledAppsEnabled -EA SilentlyContinue).SilentInstalledAppsEnabled)
$exp = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
Write-Output ("tuning_marker_ShowSyncProviderNotifications = {0}" -f (Get-ItemProperty $exp -Name ShowSyncProviderNotifications -EA SilentlyContinue).ShowSyncProviderNotifications)
