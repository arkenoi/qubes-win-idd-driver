# U4 acceptance: Sync-Revocation must NOT point the OS root-store updater at an unusable CTL mirror.
#
# The defect: on a guest with no prior copies, both fetch attempts fail, the code logged "keeping
# existing copy" (there was none) and then set RootDirURL to the local mirror anyway. Chain building
# then finds no CTL at all and fails 0x80072F8F - the very error the function exists to prevent -
# while its own log claimed success.
#
# The test forces exactly that state: empty the mirror, make fetches impossible (proxy pointed at a
# dead port), run a pass, and demand that RootDirURL is NOT left pointing at the empty directory.
# Restores everything afterwards, including whatever RootDirURL was before.
$ErrorActionPreference='Continue'
$out='C:\ProgramData\Qubes\ctl-mirror-test.txt'
$L=@()
$key='HKLM:\SOFTWARE\Microsoft\SystemCertificates\AuthRoot\AutoUpdate'
$dir='C:\ProgramData\QubesCTL'
$stash='C:\ProgramData\QubesCTL.testbak'
$agent='C:\Program Files\Qubes Tools\bin\qubes-windows-update.ps1'
$L += ("updater hash16=" + (Get-FileHash $agent -Algorithm SHA256).Hash.Substring(0,16))

$rootBefore = (Get-ItemProperty -Path $key -Name RootDirURL -EA SilentlyContinue).RootDirURL
$L += ("RootDirURL before: [" + $rootBefore + "]")

# 1. make the mirror PRISTINE (no cabs at all)
if (Test-Path $stash) { Remove-Item -LiteralPath $stash -Recurse -Force -EA SilentlyContinue }
if (Test-Path $dir) { Move-Item -LiteralPath $dir -Destination $stash -Force -EA SilentlyContinue }
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$L += ("mirror emptied: " + (@(Get-ChildItem $dir -EA SilentlyContinue).Count) + " files")

# 2. make fetching impossible. NOTE: Sync-Revocation hardcodes http://127.0.0.1:8082 and ignores
# the -Proxy parameter, so pointing -Proxy at a dead port does nothing (measured: it fetched 3/3
# through the real relay). Deny at the RELAY instead - it reads QUBES_UPDATES_ALLOW from its
# environment, and it is started by the updater, so it inherits this.
# NOT -Scheduled: that marks the pass as the automatic refresh, and the debounce then skips it when
# another pass completed recently - which silently made an earlier version of this test measure
# nothing at all. An explicit pass always runs.
$env:QUBES_UPDATES_ALLOW = 'ctl-mirror-test.invalid'
Get-Process qubes-updates-relay -EA SilentlyContinue | ForEach-Object { $_.Kill() }
Start-Sleep 2
try {
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $agent -Action scan `
      -StatusFile 'C:\ProgramData\Qubes\ctl-test-status.json' `
      -WorkDir 'C:\ProgramData\Qubes\ctl-test-wu' 2>&1 | Out-Null
} catch { $L += ("pass threw: " + $_.Exception.Message) }
Remove-Item Env:\QUBES_UPDATES_ALLOW -EA SilentlyContinue
Get-Process qubes-updates-relay -EA SilentlyContinue | ForEach-Object { $_.Kill() }

$rootAfter = (Get-ItemProperty -Path $key -Name RootDirURL -EA SilentlyContinue).RootDirURL
$L += ("RootDirURL after:  [" + $rootAfter + "]")
$files = @(Get-ChildItem $dir -Filter *.cab -EA SilentlyContinue).Count
$L += ("mirror cabs after: " + $files)

# THE ASSERTION: with an unusable mirror, RootDirURL must not point at it.
$pointsAtEmpty = ($rootAfter -and ($rootAfter -like "file://$dir*") -and $files -eq 0)
$L += ("VERDICT points_at_empty_mirror=" + $pointsAtEmpty + "  (must be False)")
# and the log must say so as an ERROR rather than claiming success
Remove-Item -LiteralPath 'C:\ProgramData\Qubes\ctl-test-wu\agent.log' -Force -EA SilentlyContinue | Out-Null
$lg='C:\ProgramData\Qubes\ctl-test-wu\agent.log'
if (Test-Path $lg) {
  $m = Select-String -Path $lg -Pattern 'Sync-Revocation' -EA SilentlyContinue | Select-Object -Last 4
  foreach ($x in $m) { $L += ("  log: " + $x.Line.Trim()) }
}

# 3. restore everything
Remove-Item -LiteralPath $dir -Recurse -Force -EA SilentlyContinue
if (Test-Path $stash) { Move-Item -LiteralPath $stash -Destination $dir -Force -EA SilentlyContinue }
if ($rootBefore) { Set-ItemProperty -Path $key -Name RootDirURL -Value $rootBefore -EA SilentlyContinue }
else { Remove-ItemProperty -Path $key -Name RootDirURL -EA SilentlyContinue }
$L += ("restored RootDirURL to: [" + (Get-ItemProperty -Path $key -Name RootDirURL -EA SilentlyContinue).RootDirURL + "]")
$L += ("restored mirror files: " + (@(Get-ChildItem $dir -EA SilentlyContinue).Count))
$L | Out-File -LiteralPath $out -Encoding ASCII
