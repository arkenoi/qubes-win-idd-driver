# What is actually installed on this guest: QWT itself, and our updater agent on top of it.
$ErrorActionPreference = 'Continue'
$qt = $env:QUBES_TOOLS; if (-not $qt) { $qt = 'C:\Program Files\Qubes Tools' }
Write-Output '=== RESULT ==='
Write-Output ("QUBES_TOOLS = " + $qt + "   exists=" + (Test-Path $qt))
Write-Output ("bin exes   : " + ((Get-ChildItem (Join-Path $qt 'bin') -Filter *.exe -EA SilentlyContinue |
                                  Select-Object -ExpandProperty Name) -join ', '))
Write-Output ("rpc svcs   : " + ((Get-ChildItem (Join-Path $qt 'qubes-rpc') -EA SilentlyContinue |
                                  Select-Object -ExpandProperty Name) -join ', '))
foreach ($svc in 'QubesGuiAgent', 'QubesQrexecAgent', 'QubesDB', 'QubesUpdatesRelay') {
    $s = Get-Service -Name $svc -EA SilentlyContinue
    if ($s) { Write-Output ("service    : {0} = {1}" -f $svc, $s.Status) }
}
$agent = Join-Path $qt 'bin\qubes-windows-update.ps1'
Write-Output ("our updater: " + (Test-Path $agent))
Write-Output ("our relay  : " + (Test-Path (Join-Path $qt 'bin\qubes-updates-relay.exe')))
foreach ($t in 'QubesWindowsUpdateScan', 'QubesWindowsUpdateRun', 'QubesAutologonGuard') {
    $x = Get-ScheduledTask -TaskName $t -EA SilentlyContinue
    Write-Output ("task       : {0} = {1}" -f $t, $(if ($x) { $x.State } else { 'ABSENT' }))
}
