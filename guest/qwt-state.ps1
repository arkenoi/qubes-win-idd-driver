# Pushed state probe for the e2e upgrade test - KEY=VALUE output, no nested quoting
# (inline PowerShell through qtest run collapses quotes; pushed scripts do not - the
# same trap documented for run-elevated -Arguments).
$ErrorActionPreference = 'SilentlyContinue'

# BOTH Uninstall roots, because Get-InstalledQwt in the installer reads both. Reading only the
# 64-bit root here (as this did until 2026-08-29) lets the probe report "no QWT installed" about a
# guest the installer will find a product on and treat as an upgrade. That mismatch - probe and
# code-under-test reading different signals - is exactly what voided the 2026-08-28 WIN10 matrix,
# where a cell logged "precondition real (no QWT installed)" 25 s before the installer found
# QWT 4.3.2.0. A probe that can disagree with the branch it is predicting is worse than none.
$roots = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
           'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
$prods = @(Get-ItemProperty $roots | Where-Object { $_.DisplayName -match 'Qubes' })
Write-Output ("QWTVERS=" + (($prods | ForEach-Object { $_.DisplayVersion }) -join ','))
Write-Output ("QWTCOUNT=" + $prods.Count)

# The two signals step-0 needs that this probe never reported, read the SAME WAY the installer
# reads them so the answers cannot diverge.
# testsigning: SystemStartOptions reflects the CURRENT boot; bcdedit reflects the NEXT one. Only
# the former says whether the kernel will load test-signed binaries right now
# (mirrors Test-TestSigningActive, Install-QwtImproved.ps1).
$sso = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control' `
                         -Name SystemStartOptions -ErrorAction SilentlyContinue).SystemStartOptions
Write-Output ("TESTSIGNING=" + [bool]($sso -and $sso -match 'TESTSIGNING'))
Write-Output ("SYSTEMSTARTOPTIONS=" + $sso)

# Boot disk bus - 'SCSI' is the PV path (mirrors Test-BootDiskOnPvPath).
try {
    $disk = Get-Partition -DriveLetter C -ErrorAction Stop | Get-Disk -ErrorAction Stop
    Write-Output ("BUSTYPE=" + [string]$disk.BusType)
} catch {
    Write-Output "BUSTYPE=PROBE-ERROR"
}

# xenbus_monitor: service state and live PIDs are DIFFERENT things and are reported separately -
# 81d2b79 exists because the service was Disabled while the process was still running and acting.
$svc = Get-Service -Name 'xenbus_monitor' -ErrorAction SilentlyContinue
if ($svc) { Write-Output ("XBMSTATUS=" + [string]$svc.Status) } else { Write-Output "XBMSTATUS=ABSENT" }
$xk = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\xenbus_monitor' -ErrorAction SilentlyContinue
if ($xk) { Write-Output ("XBMSTART=" + $xk.Start) } else { Write-Output "XBMSTART=ABSENT" }
Write-Output ("XBMPIDS=" + ((@(Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessName -match 'xenbus_monitor' } | ForEach-Object { $_.Id })) -join ','))

$ga = 'C:\Program Files\Qubes Tools\bin\gui-agent.exe'
if (Test-Path -LiteralPath $ga) {
    Write-Output ("AGENTFILEVER=" + (Get-Item -LiteralPath $ga).VersionInfo.FileVersion)
} else {
    Write-Output "AGENTFILEVER=ABSENT"
}

$cp = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Google\Chrome' -ErrorAction SilentlyContinue
if ($null -ne $cp -and $null -ne $cp.HardwareAccelerationModeEnabled) {
    Write-Output ("CHROMEPOLICY=" + $cp.HardwareAccelerationModeEnabled)
} else {
    Write-Output "CHROMEPOLICY=ABSENT"
}
