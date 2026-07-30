# Deploy + smoke-test the IDD driver package inside win-idd-test.
# Usage: powershell -File deploy-and-test.ps1 [-PackageDir <dir>] [-HwId root\qubesidd] [-Uninstall]
# Emits a '=== RESULT ===' JSON block on stdout for the orchestrator to parse.
param(
    [string]$PackageDir = "$(Split-Path $MyInvocation.MyCommand.Path)",
    [string]$HwId = 'root\qubesidd',
    [switch]$Uninstall
)
$ErrorActionPreference = 'Continue'
$result = [ordered]@{ ok = $false; steps = [ordered]@{} }

$inf    = Get-ChildItem $PackageDir -Filter *.inf | Select-Object -First 1
$devcon = Join-Path $PackageDir 'devcon.exe'

if ($Uninstall) {
    if (Test-Path $devcon) { & $devcon remove $HwId | Write-Output }
    if ($inf) { pnputil /delete-driver $inf.Name /uninstall /force | Write-Output }
    Write-Output '=== RESULT ==='; @{ ok = $true; action = 'uninstall' } | ConvertTo-Json; exit 0
}

# 1. stage driver
$out = pnputil /add-driver $inf.FullName /install 2>&1 | Out-String
$result.steps.pnputil = ($LASTEXITCODE -eq 0); Write-Output $out

# 2. create the root-enumerated software device (this instantiates the virtual monitor)
if (Test-Path $devcon) {
    $out = & $devcon install $inf.FullName $HwId 2>&1 | Out-String
    $result.steps.devcon = ($LASTEXITCODE -eq 0); Write-Output $out
} else {
    $result.steps.devcon = 'devcon.exe missing from package'
}
Start-Sleep -Seconds 5

# 3. what does the display stack look like now?
$result.steps.display_devices = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
    Select-Object FriendlyName, Status, InstanceId
$result.steps.monitors = Get-CimInstance -Namespace root\wmi -Class WmiMonitorBasicDisplayParams -ErrorAction SilentlyContinue |
    Measure-Object | Select-Object -ExpandProperty Count
$result.steps.video_controllers = Get-CimInstance Win32_VideoController |
    Select-Object Name, CurrentHorizontalResolution, CurrentVerticalResolution, Status

# 4. DDA probe (built by CI if tools/ddaprobe is in the repo): reports per-output
#    DesktopImageInSystemMemory + AcquireNextFrame timing — THE scoping question.
$probe = Join-Path $PackageDir 'ddaprobe.exe'
if (Test-Path $probe) {
    $result.steps.ddaprobe = (& $probe 2>&1 | Out-String)
} else {
    $result.steps.ddaprobe = 'ddaprobe.exe not in package (add tools/ddaprobe to repo)'
}

# 5. QWT agent still alive?
$result.steps.qwt_services = Get-Service | Where-Object { $_.DisplayName -match 'Qubes' } |
    Select-Object Name, Status

$result.ok = ($result.steps.pnputil -eq $true)
Write-Output '=== RESULT ==='
$result | ConvertTo-Json -Depth 5
