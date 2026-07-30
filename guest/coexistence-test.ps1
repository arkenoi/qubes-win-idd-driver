# Track B Phase 1B coexistence test — run ELEVATED in win-idd-test.
# Installs the IDD sample driver alongside the Basic Display Adapter, then re-runs ddaprobe
# to answer the Outcome-A gate: does an IDD monitor coexist AND keep
# DesktopImageInSystemMemory TRUE (so the existing QWT capture path survives)?
#
# Usage (from dev qube, after the VM is UAC-disabled so this token is elevated):
#   tools/qtest push artifacts/IddSampleDriver.dll artifacts/IddSampleDriver.inf \
#                    artifacts/iddsampledriver.cat artifacts/devcon.exe artifacts/ddaprobe.exe \
#                    guest/coexistence-test.ps1
#   tools/qtest ps "& '<incoming>\coexistence-test.ps1'"
param(
    [string]$Dir = "$(Split-Path $MyInvocation.MyCommand.Path)",
    [string]$HwId = 'Root\IddSampleDriver'
)
$ErrorActionPreference = 'Continue'
$r = [ordered]@{}

# confirm we are actually elevated (High integrity) - the whole test needs admin
$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$pr = New-Object Security.Principal.WindowsPrincipal($id)
$r.elevated = $pr.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $r.elevated) {
    Write-Output '=== RESULT ==='
    @{ ok = $false; error = 'not elevated - disable UAC on the VM first' } | ConvertTo-Json
    exit 1
}

$inf    = Get-ChildItem $Dir -Filter *.inf | Select-Object -First 1
$devcon = Join-Path $Dir 'devcon.exe'
$probe  = Join-Path $Dir 'ddaprobe.exe'

# display devices BEFORE
$r.before_displays = @(Get-CimInstance Win32_VideoController |
    Select-Object Name, CurrentHorizontalResolution, CurrentVerticalResolution, Status)

# 1. stage the driver package
$r.pnputil = (pnputil /add-driver $inf.FullName /install 2>&1 | Out-String)
$r.pnputil_ok = ($LASTEXITCODE -eq 0)

# 2. create the root-enumerated IDD device (instantiates the virtual monitor)
if (Test-Path $devcon) {
    $r.devcon = (& $devcon install $inf.FullName $HwId 2>&1 | Out-String)
    $r.devcon_ok = ($LASTEXITCODE -eq 0)
}
Start-Sleep -Seconds 6

# 3. display stack AFTER
$r.after_displays = @(Get-CimInstance Win32_VideoController |
    Select-Object Name, CurrentHorizontalResolution, CurrentVerticalResolution, Status)
$r.display_pnp = @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
    Select-Object FriendlyName, Status, InstanceId)
$r.monitor_count = (Get-CimInstance -Namespace root\wmi -Class WmiMonitorBasicDisplayParams -ErrorAction SilentlyContinue |
    Measure-Object | Select-Object -ExpandProperty Count)

# 4. THE gate: does DesktopImageInSystemMemory stay TRUE with the IDD present?
#    Generate activity so ddaprobe gets real frames (60s window; probe 150/20).
if (Test-Path $probe) {
    $act = Join-Path $Dir 'activity-gen.ps1'
    if (Test-Path $act) {
        Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$act`"",'-Seconds','30' -WindowStyle Minimized
        Start-Sleep -Seconds 2
    }
    $r.ddaprobe = (& $probe 150 20 2>&1 | Out-String)
} else {
    $r.ddaprobe = 'ddaprobe.exe not in dir'
}

# 5. QWT agent still alive + still capturing?
$r.qwt_services = @(Get-Service | Where-Object { $_.DisplayName -match 'Qubes' } |
    Select-Object Name, @{n='Status';e={"$($_.Status)"}})

Write-Output '=== RESULT ==='
$r | ConvertTo-Json -Depth 6
