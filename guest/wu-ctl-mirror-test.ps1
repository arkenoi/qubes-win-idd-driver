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

# 0. the port must be FREE for the pass's own relay to bind. A relay already serving belongs to a
# running pass and is NOT this test's to end (owner 2026-10-07: it used to be killed by name here,
# before and after the pass): refuse and name the owner instead - BEFORE the mirror is touched.
$ro = Join-Path $PSScriptRoot 'relay-own.ps1'
if (-not (Test-Path -LiteralPath $ro)) { $L += 'relay-own.ps1 not pushed next to this script (tools/qtest push guest/relay-own.ps1)'; $L | Out-File -LiteralPath $out -Encoding ASCII; exit 3 }
. $ro
$owner = Get-RelayPortOwner
if ($owner -ne 0) { $L += (Format-RelayRefusal $owner); $L | Out-File -LiteralPath $out -Encoding ASCII; exit 2 }

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
# THE ONE LOG DIRECTORY (docs/ADR-logging.md, Decision 2026-11-01), by log.ps1's rule, inlined because this probe runs
# without it: the registry LogDir, else <SystemDrive>\Qubes Logs. A moved log is its per-day files there,
# <module>-<yyyyMMdd>.log, newest last; only a guest with none of them reads the file at its old path.
function Get-MovedLogFiles([string]$Module, [string]$Old) {
  $d = $null
  try { $d = Get-ItemPropertyValue 'HKLM:\Software\Invisible Things Lab\Qubes Tools' LogDir -ErrorAction Stop } catch { }
  if (-not $d) { $d = Join-Path $env:SystemDrive 'Qubes Logs' }
  $rx = '^' + [regex]::Escape($Module) + '-\d{8}\.log$'
  $f = @(Get-ChildItem -LiteralPath $d -Filter "$Module-*.log" -File -EA SilentlyContinue | Where-Object { $_.Name -match $rx } | Sort-Object Name | ForEach-Object { $_.FullName })
  if ($f.Count -eq 0 -and $Old -and (Test-Path -LiteralPath $Old)) { $f = @($Old) }
  $f
}
# The lines a pass appended to the per-day files: each from its length in $Mark, a file born since then whole.
function Get-LinesSince([hashtable]$Mark, [string[]]$Files) {
  $t = New-Object System.Collections.Generic.List[string]
  foreach ($p in $Files) {
    $off = [int64]0; if ($Mark.ContainsKey($p)) { $off = [int64]$Mark[$p] }
    try {
      $fs = [IO.File]::Open($p, 'Open', 'Read', 'ReadWrite')
      try {
        if ($off -le $fs.Length) { [void]$fs.Seek($off, 'Begin') }
        $sr = New-Object IO.StreamReader($fs)
        while ($null -ne ($ln = $sr.ReadLine())) { $t.Add($ln) }
      } finally { $fs.Dispose() }
    } catch { }
  }
  $t.ToArray()
}
# THE PASS LOG IS SHARED NOW: qubes-windows-update.ps1-<yyyyMMdd>.log in the one log directory, whatever -WorkDir says,
# holds every pass of the day, so the read below is bounded to what THIS pass appends - the per-day files' lengths are
# marked here. An older build writes its own log under -WorkDir, emptied here for the same reason: it used to be
# deleted only after the pass, right before it was read, so its lines were never shown.
$logMark = @{}; foreach ($p in @(Get-MovedLogFiles 'qubes-windows-update.ps1' '')) { $logMark[$p] = (Get-Item -LiteralPath $p).Length }
Remove-Item -LiteralPath 'C:\ProgramData\Qubes\ctl-test-wu\agent.log' -Force -EA SilentlyContinue | Out-Null
try {
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $agent -Action scan `
      -StatusFile 'C:\ProgramData\Qubes\ctl-test-status.json' `
      -WorkDir 'C:\ProgramData\Qubes\ctl-test-wu' 2>&1 | Out-Null
} catch { $L += ("pass threw: " + $_.Exception.Message) }
Remove-Item Env:\QUBES_UPDATES_ALLOW -EA SilentlyContinue
# The pass's relay leaves with the pass (--parent-pid): wait for the port to free, never end it.
if (-not (Wait-RelayPortFree -TimeoutSec 20)) { $L += ("WARN: port 8082 still served by pid " + (Get-RelayPortOwner) + " after the pass - not this test's to stop") }

$rootAfter = (Get-ItemProperty -Path $key -Name RootDirURL -EA SilentlyContinue).RootDirURL
$L += ("RootDirURL after:  [" + $rootAfter + "]")
$files = @(Get-ChildItem $dir -Filter *.cab -EA SilentlyContinue).Count
$L += ("mirror cabs after: " + $files)

# THE ASSERTION: with an unusable mirror, RootDirURL must not point at it.
$pointsAtEmpty = ($rootAfter -and ($rootAfter -like "file://$dir*") -and $files -eq 0)
$L += ("VERDICT points_at_empty_mirror=" + $pointsAtEmpty + "  (must be False)")
# and the log must say so as an ERROR rather than claiming success: what this pass appended
$lg='C:\ProgramData\Qubes\ctl-test-wu\agent.log'
$lgs = @(Get-MovedLogFiles 'qubes-windows-update.ps1' '')
if ($lgs.Count -or (Test-Path $lg)) {
  $lines = @(if ($lgs.Count) { Get-LinesSince $logMark $lgs } else { Get-Content -LiteralPath $lg -EA SilentlyContinue })
  $m = $lines | Select-String -Pattern 'Sync-Revocation' | Select-Object -Last 4
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
