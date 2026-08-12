# Retrieve what capture-start-render.ps1 sampled (PNG as base64 + the geometry notes).
$ErrorActionPreference = 'Continue'
& schtasks /delete /tn QwtStartRender /f *>&1 | Out-Null
Write-Output '=== NOTES ==='
if (Test-Path 'C:\toastprobe\start-render.txt') { Get-Content 'C:\toastprobe\start-render.txt' } else { 'no notes' }
Write-Output '=== SHOT-B64 ==='
if (Test-Path 'C:\toastprobe\start-render.png') {
    [Convert]::ToBase64String([IO.File]::ReadAllBytes('C:\toastprobe\start-render.png'))
} else { 'NONE' }
Write-Output '=== END ==='
