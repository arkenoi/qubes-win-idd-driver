# Pushed state probe for the e2e upgrade test - KEY=VALUE output, no nested quoting
# (inline PowerShell through qtest run collapses quotes; pushed scripts do not - the
# same trap documented for run-elevated -Arguments).
$ErrorActionPreference = 'SilentlyContinue'

$prods = @(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' |
           Where-Object { $_.DisplayName -match 'Qubes' })
Write-Output ("QWTVERS=" + (($prods | ForEach-Object { $_.DisplayVersion }) -join ','))
Write-Output ("QWTCOUNT=" + $prods.Count)

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
