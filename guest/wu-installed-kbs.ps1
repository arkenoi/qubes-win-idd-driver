# Can we decide applicability BEFORE downloading? The two facts available for free are:
#   1. which KBs this image already has (CBS package list + Get-HotFix), and
#   2. the build this image is at (CurrentBuild.UBR)
# A catalog URL carries its KB in the filename, and a catalog title carries the build it produces
# ("(26100.9168)"). If those two suffice to reject kb5043080 while keeping kb5121003, the whole
# 4.8 GB of wasted transfer and the poisoned servicing session are avoidable up front.
$ErrorActionPreference = 'Continue'
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
Write-Output '=== RESULT ==='
Write-Output ("build = {0}.{1} ({2})" -f $cv.CurrentBuild, $cv.UBR, $cv.DisplayVersion)

# CBS is the authoritative list; Get-HotFix misses packages installed via DISM/CBS.
$pkgRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages'
$kbs = New-Object System.Collections.Generic.HashSet[string]
foreach ($k in (Get-ChildItem $pkgRoot -EA SilentlyContinue)) {
    if ($k.PSChildName -match 'KB(\d{6,7})') { [void]$kbs.Add('KB' + $Matches[1]) }
}
foreach ($h in (Get-HotFix -EA SilentlyContinue)) { if ($h.HotFixID) { [void]$kbs.Add($h.HotFixID) } }
Write-Output ("known_installed_kb_count = {0}" -f $kbs.Count)

foreach ($probe in @('KB5043080', 'KB5121003', 'KB5120710', 'KB5123304')) {
    Write-Output ("  {0} installed_according_to_image = {1}" -f $probe, $kbs.Contains($probe))
}

# Show a sample so the list is verifiable rather than trusted
Write-Output ("sample: " + (($kbs | Sort-Object | Select-Object -First 12) -join ', '))
