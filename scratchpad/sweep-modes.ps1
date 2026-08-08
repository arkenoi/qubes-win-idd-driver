# Register the desktop-size sweep's mode list with the Qubes IDD driver.
#
# The driver builds its monitor mode list as s_SampleDefaultModes plus the REG_MULTI_SZ
# 'Modes' under HKLM\SOFTWARE\QubesIDD (Driver.cpp: BuildQubesMonitorModes /
# QubesReadRegistryModes). That list is read at MONITOR ARRIVAL, so registering modes here
# does not make them available until the monitor re-arrives - the caller reboots.
#
# Once registered, individual modes are applied at runtime with `modeprobe --apply WxH`,
# which needs no further reboot. So the sweep costs exactly one reboot, not one per point.
#
# REQUIRES ELEVATION. Writing HKLM needs admin and qrexec runs UNELEVATED on clean-room
# guests (measured: ELEVATED=False, 'Requested registry access is not allowed'). A previous
# script in this repo called Set-ItemProperty with -ErrorAction Continue and then printed
# RESULT=OK unconditionally - it reported success while changing nothing. Refuse up front.
param(
    [string[]]$Modes = @('1920x1080','2560x1440','3440x1440','5120x2160','7680x4320')
)
$ErrorActionPreference = 'Continue'

$pr = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Output "RESULT=FAIL not elevated - cannot register modes from an unelevated session"
    exit 2
}

foreach ($m in $Modes) {
    if ($m -notmatch '^\d{3,5}x\d{3,5}$') { Write-Output "RESULT=FAIL bad mode '$m'"; exit 3 }
}

New-Item -Path 'HKLM:\SOFTWARE\QubesIDD' -Force -ErrorAction SilentlyContinue | Out-Null
try {
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\QubesIDD' -Name 'Modes' -Value $Modes `
                     -Type MultiString -ErrorAction Stop
} catch {
    Write-Output ("RESULT=FAIL could not write Modes: " + $_.Exception.Message); exit 4
}

# Read back. The request is never the evidence.
$rb = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\QubesIDD' -Name 'Modes' -ErrorAction SilentlyContinue).Modes
if (-not $rb) { Write-Output "RESULT=FAIL Modes absent after write"; exit 5 }
$missing = @($Modes | Where-Object { $rb -notcontains $_ })
if ($missing.Count -gt 0) {
    Write-Output ("RESULT=FAIL readback missing: " + ($missing -join ',')); exit 6
}
foreach ($m in $rb) { Write-Output "REGMODE=$m" }
Write-Output ("RESULT=OK registered=" + $rb.Count + " (effective after the monitor re-arrives - reboot)")
