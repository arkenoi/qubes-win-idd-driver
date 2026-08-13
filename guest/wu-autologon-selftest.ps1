# Negative control for the autologon guard: prove it FAILS when autologon cannot be guaranteed.
#
# Temporarily removes DefaultPassword (the exact state Windows leaves behind when it consumes it),
# runs the guard, and restores the value in a finally - so the guest cannot be left unable to log
# itself in even if this script dies halfway.
$ErrorActionPreference = 'Continue'
$WL = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$guard = Join-Path $PSScriptRoot 'ensure-autologon.ps1'
if (-not (Test-Path $guard)) { Write-Output "guard not found at $guard"; exit 1 }

$saved = (Get-ItemProperty -Path $WL -Name 'DefaultPassword' -EA SilentlyContinue).DefaultPassword

Write-Output '--- healthy state ---'
& $guard | Out-Null
Write-Output "  exit=$LASTEXITCODE (expect 0)"
$healthy = $LASTEXITCODE

$broken = -1
try {
    if ($null -ne $saved) {
        Remove-ItemProperty -Path $WL -Name 'DefaultPassword' -Force -EA SilentlyContinue
        Write-Output '--- DefaultPassword removed (simulating Windows consuming it) ---'
        $out = & $guard
        $broken = $LASTEXITCODE
        foreach ($l in $out) { if ($l -match '^WARN') { Write-Output "  $l" } }
        Write-Output "  exit=$broken (expect 2)"
    } else {
        Write-Output '  SKIP: DefaultPassword was not set to begin with'
    }
} finally {
    if ($null -ne $saved) {
        New-ItemProperty -Path $WL -Name 'DefaultPassword' -Value $saved -PropertyType String -Force | Out-Null
        $back = (Get-ItemProperty -Path $WL -Name 'DefaultPassword' -EA SilentlyContinue).DefaultPassword
        Write-Output "  restored DefaultPassword: $([bool]$back)"
    }
}

Write-Output '=== RESULT ==='
Write-Output "healthy_exit=$healthy broken_exit=$broken verdict=$(if ($healthy -eq 0 -and $broken -eq 2) { 'GUARD WORKS' } else { 'GUARD DID NOT BEHAVE' })"
