# ITERATION 2 TEST: install ONLY the cumulative, without the superseded catalog sibling.
#
# History: the catalog's DownloadDialog for KB5121003 returns TWO .msu - kb5043080 (a 2024-09
# cumulative, superseded on this 26100.8875 image) and kb5121003 (the one we want). We installed
# both. kb5043080 failed rc=552 ("Not applicable"), kb5121003 then reported 3010 and was ROLLED
# BACK at boot with 0x80070490 / CBS_E_INVALID_PACKAGE.
#
# Question this answers: does the cumulative install cleanly when the superseded sibling is not
# fed to CBS first? Uses the ALREADY CACHED file - no download.
$ErrorActionPreference = 'Continue'
$lcu = Get-ChildItem 'C:\ProgramData\Qubes\wu' -Recurse -Filter '*kb5121003*.msu' -EA SilentlyContinue |
       Select-Object -First 1
Write-Output '=== RESULT ==='
if (-not $lcu) { Write-Output 'cumulative .msu not cached - nothing to test'; exit 1 }

$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
Write-Output ("build_before = {0}.{1}" -f $cv.CurrentBuild, $cv.UBR)
Write-Output ("package      = {0} ({1:N0} bytes)" -f $lcu.Name, $lcu.Length)

$log = 'C:\ProgramData\Qubes\wu\dism-lcu-alone.log'
$t0 = Get-Date
& DISM /Online /Add-Package /PackagePath:"$($lcu.FullName)" /NoRestart /Quiet /LogPath:"$log" | Out-Null
$rc = $LASTEXITCODE
$mins = [math]::Round(((Get-Date) - $t0).TotalMinutes, 1)
Write-Output ("dism_rc      = {0}   (3010 = staged/reboot required, 0 = applied)   minutes={1}" -f $rc, $mins)

# CBS's own opinion AFTER the attempt - rc alone has lied before.
$pending = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
Write-Output ("cbs_reboot_pending = {0}" -f $pending)
$sess = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\SessionsPending'
Write-Output ("sessions_pending   = {0}" -f (Test-Path $sess))

# Did CBS register the package at all?
$pkgRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages'
$hit = @(Get-ChildItem $pkgRoot -EA SilentlyContinue | Where-Object { $_.PSChildName -match '5121003' })
Write-Output ("cbs_packages_matching_5121003 = {0}" -f $hit.Count)
foreach ($h in ($hit | Select-Object -First 3)) {
    $st = (Get-ItemProperty $h.PSPath -EA SilentlyContinue).CurrentState
    Write-Output ("   {0}  CurrentState={1}" -f $h.PSChildName, $st)
}
if ($rc -ne 0 -and $rc -ne 3010) {
    Write-Output '--- last DISM errors ---'
    Get-Content $log -Tail 400 -EA SilentlyContinue | Where-Object { $_ -match 'Error|0x8' } |
        Select-Object -Last 6 | ForEach-Object { Write-Output ("   " + $_.Trim()) }
}
