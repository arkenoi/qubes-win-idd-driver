# Switch this guest between the IddCx display and the emulated Basic Display Adapter,
# WITHOUT reinstalling, so the benchmark can separate two variables the four-row table
# conflated on Windows 11:
#
#   ours  win11 = our agent + IddCx
#   stock win11 = stock agent + BDA
#
# Those differ in BOTH the agent and the display stack, so "ours costs more CPU on Win11"
# cannot be attributed to either. Running OUR agent on BDA gives the missing third point:
#   - if ours-on-BDA ~ stock  -> the cost is the IddCx path
#   - if ours-on-BDA stays high -> the cost is our agent on Windows 11
#
# -Mode bda : enable the emulated VGA, disable the IDD, and set NoTopologyApply so the agent
#             does not re-assert IDD-solo on the next boot.
# -Mode idd : the reverse, restoring the shipped configuration.
# A reboot is required either way; the caller does that and re-checks.
param([ValidateSet('bda','idd')][string]$Mode = 'bda')
$ErrorActionPreference = 'Continue'

# REQUIRES ELEVATION. Changing HKLM and PnP device state needs admin, and qrexec runs
# UNELEVATED on clean-room guests (measured: ELEVATED=False, HKLM write 'Requested registry
# access is not allowed'). An earlier version of this script called Set-ItemProperty and
# Enable-PnpDevice with -ErrorAction Continue and then printed RESULT=OK unconditionally -
# it reported success while changing nothing. Refuse up front instead.
$pr = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Output "RESULT=FAIL not elevated - cannot change display topology from an unelevated session"
    exit 2
}

function Show-State {
    Get-CimInstance Win32_VideoController | ForEach-Object {
        Write-Output ("VC " + $_.Name + " avail=" + $_.Availability +
                      " " + $_.CurrentHorizontalResolution + "x" + $_.CurrentVerticalResolution)
    }
    $k = Get-ItemProperty 'HKLM:\SOFTWARE\QubesIDD' -Name NoTopologyApply -ErrorAction SilentlyContinue
    Write-Output ("KILLSWITCH=" + $(if ($k) { $k.NoTopologyApply } else { 'ABSENT' }))
}

Write-Output "=== before ==="
Show-State

$vga = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
       Where-Object { $_.InstanceId -like 'PCI\VEN_1234*' } | Select-Object -First 1
$idd = Get-PnpDevice -ErrorAction SilentlyContinue |
       Where-Object { $_.InstanceId -like 'ROOT\DISPLAY*' } | Select-Object -First 1

if ($Mode -eq 'bda') {
    # Order matters: bring the VGA up BEFORE taking the IDD down, or the guest can be left
    # with no attached display at all and no qrexec to fix it from.
    if (-not $vga) { Write-Output "RESULT=FAIL no VGA devnode found"; exit 1 }
    New-Item -Path 'HKLM:\SOFTWARE\QubesIDD' -Force -ErrorAction SilentlyContinue | Out-Null
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\QubesIDD' -Name NoTopologyApply -Value 1 -Type DWord
    Enable-PnpDevice  -InstanceId $vga.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
    if ($idd) { Disable-PnpDevice -InstanceId $idd.InstanceId -Confirm:$false -ErrorAction SilentlyContinue }
    $k = (Get-ItemProperty 'HKLM:\SOFTWARE\QubesIDD' -Name NoTopologyApply -ErrorAction SilentlyContinue).NoTopologyApply
    if ($k -ne 1) { Write-Output "RESULT=FAIL NoTopologyApply did not take (read back '$k')"; exit 3 }
    Write-Output "RESULT=OK mode=bda (VGA enabled, IDD disabled, topology apply suppressed)"
} else {
    if ($idd) { Enable-PnpDevice -InstanceId $idd.InstanceId -Confirm:$false -ErrorAction SilentlyContinue }
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\QubesIDD' -Name NoTopologyApply -ErrorAction SilentlyContinue
    if ($vga) { Disable-PnpDevice -InstanceId $vga.InstanceId -Confirm:$false -ErrorAction SilentlyContinue }
    Write-Output "RESULT=OK mode=idd (IDD enabled, topology apply restored, VGA disabled)"
}

Write-Output "=== after (pre-reboot; the topology only settles on the next boot) ==="
Show-State
