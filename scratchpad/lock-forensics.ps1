# WHAT LOCKED THE SESSION? Answer from the guest's own records rather than by guessing.
# 4800 = workstation locked, 4801 = unlocked, 4802/4803 = screensaver invoked/dismissed,
# 7002 = logoff, 42/107 = sleep/resume. Correlate with the effective idle policies.
Write-Output "=== lock/unlock/screensaver events (Security) ==="
Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4800,4801,4802,4803} -MaxEvents 20 -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Output ("EV {0} {1} {2}" -f $_.TimeCreated.ToString('s'), $_.Id,
        (($_.Message -split "`n")[0])) }
Write-Output "=== power transitions (Kernel-Power / sleep-resume) ==="
Get-WinEvent -FilterHashtable @{LogName='System'; Id=42,107,1,506,507} -MaxEvents 12 -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Output ("PW {0} {1} {2}" -f $_.TimeCreated.ToString('s'), $_.Id, $_.ProviderName) }
Write-Output "=== effective idle policy ==="
Write-Output ("InactivityTimeoutSecs=" + (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name InactivityTimeoutSecs -EA 0).InactivityTimeoutSecs)
Write-Output ("NoLockScreen=" + (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization' -Name NoLockScreen -EA 0).NoLockScreen)
Write-Output ("ScreenSaveActive=" + (Get-ItemProperty 'HKCU:\Control Panel\Desktop' -Name ScreenSaveActive -EA 0).ScreenSaveActive)
Write-Output ("ScreenSaverIsSecure=" + (Get-ItemProperty 'HKCU:\Control Panel\Desktop' -Name ScreenSaverIsSecure -EA 0).ScreenSaverIsSecure)
Write-Output ("ScreenSaveTimeOut=" + (Get-ItemProperty 'HKCU:\Control Panel\Desktop' -Name ScreenSaveTimeOut -EA 0).ScreenSaveTimeOut)
Write-Output "=== monitor/standby timeouts (0 = never) ==="
powercfg /query SCHEME_CURRENT SUB_VIDEO VIDEOIDLE 2>$null | Select-String 'Current AC Power Setting Index' | ForEach-Object { Write-Output ("VIDEOIDLE " + $_.Line.Trim()) }
powercfg /query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 2>$null | Select-String 'Current AC Power Setting Index' | ForEach-Object { Write-Output ("STANDBYIDLE " + $_.Line.Trim()) }
Write-Output "=== any leftover lock probe task? (ours, from earlier diagnostics) ==="
$t = schtasks /query /tn QubesLockProbe 2>$null
Write-Output ("QubesLockProbe=" + $(if ($LASTEXITCODE -eq 0) { 'PRESENT' } else { 'absent' }))
