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
# THREE OUTCOMES, NOT TWO. The broken case is only constructed when a REGISTRY DefaultPassword
# exists ($saved). Our installer deliberately stores that credential as the LSA secret instead -
# no plaintext in the registry, and not consumed by AutoLogonCount - so on a correctly installed
# guest $saved is always $null, the broken case SKIPS, $broken stays -1, and the old two-way
# verdict then printed "GUARD DID NOT BEHAVE" about a guard it had never exercised. Measured
# 2026-08-30 on win10-tpl: healthy_exit=0 broken_exit=-1, reported as a guard failure when the
# real state was AutoAdminLogon=1, AutoLogonCount ABSENT, re-assert task Ready - i.e. healthy.
# A selftest that cannot construct its negative must say so, not render a verdict.
$verdict = if ($healthy -eq 0 -and $broken -eq 2) { 'GUARD WORKS' }
           elseif ($broken -eq -1) { 'INCONCLUSIVE: broken case NOT constructed (no registry DefaultPassword - expected, the credential lives in the LSA secret). This selftest cannot exercise the guard on this build; it must break the LSA secret instead.' }
           else { 'GUARD DID NOT BEHAVE' }
Write-Output "healthy_exit=$healthy broken_exit=$broken verdict=$verdict"
