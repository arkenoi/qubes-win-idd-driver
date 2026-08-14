<#
.SYNOPSIS
  Where did servicing time actually go? Aggregates CBS.log IN-GUEST and returns a small digest.

.DESCRIPTION
  CBS.log routinely exceeds 250 MB, so streaming it over qrexec costs more than the analysis.
  This streams it once with a reader (Get-Content on 250 MB is unusably slow) and reports:

    * wall-clock span and where the big inter-line GAPS are - the honest "what was slow"
    * CBS's own `Perf:` timings, which name the expensive operations directly
    * how the line volume splits across components (CSI vs CBS vs SQM), i.e. what the log I/O
      itself is being spent on
    * how many packages were evaluated, and how many of those were language variants - the
      planning phase walks every language present in the image, which is the usual reason a
      cumulative takes far longer on a small VM than the download did

  Everything here is measurement. No optimisation is recommended by this script; the numbers
  decide, and an optimisation that is not visible in these numbers is not worth its risk.

.PARAMETER Tail  Analyse only the last N MB (default 0 = whole file). Use while an install is
                 still running so the read does not compete with the servicing I/O.
#>
param([int]$Tail = 0, [string]$Path = '')
$ErrorActionPreference = 'Continue'
Write-Output '=== RESULT ==='
# CBS archives CBS.log into CbsPersist_<timestamp>.log, and a reboot that applies an update almost
# always rotates it - so the log covering the install is usually NOT CBS.log by the time you look.
# Default to the largest recently-written log in the folder rather than silently analysing an empty
# post-reboot CBS.log and reporting "nothing was slow".
$log = $Path
if (-not $log) {
    $cands = @(Get-ChildItem 'C:\Windows\Logs\CBS\*.log' -EA SilentlyContinue | Sort-Object Length -Descending)
    Write-Output '--- available CBS logs ---'
    foreach ($c in ($cands | Select-Object -First 6)) {
        Write-Output ("  {0,-34} {1,8:N1} MB  last_write {2}" -f $c.Name, ($c.Length/1MB), $c.LastWriteTime.ToString('MM-dd HH:mm'))
    }
    if ($cands.Count) { $log = $cands[0].FullName }
}
if (-not $log -or -not (Test-Path $log)) { Write-Output 'no CBS log found'; exit 1 }
Write-Output ("analysing: {0}" -f $log)
$fi = Get-Item $log
Write-Output ("cbs_log_mb = {0:N1}   last_write = {1}" -f ($fi.Length/1MB), $fi.LastWriteTime.ToString('HH:mm:ss'))

$fs = [IO.File]::Open($log, 'Open', 'Read', 'ReadWrite')
if ($Tail -gt 0 -and $fs.Length -gt ($Tail * 1MB)) { [void]$fs.Seek(-($Tail * 1MB), 'End') }
$sr = New-Object IO.StreamReader($fs)
if ($Tail -gt 0) { [void]$sr.ReadLine() }   # discard the partial first line

$comp = @{}; $perf = New-Object System.Collections.ArrayList
$gaps = New-Object System.Collections.ArrayList
$pkgs = New-Object 'System.Collections.Generic.HashSet[string]'
$langPkgs = 0; $lines = 0
$prevT = $null; $prevLine = ''; $firstT = $null; $lastT = $null
$prevS = ''; $firstS = ''; $lastS = ''

while ($null -ne ($l = $sr.ReadLine())) {
    $lines++
    if ($l.Length -lt 30) { continue }
    # 2026-08-14 11:04:00, Info                  CBS    ...
    # No DateTime parsing. TryParseExact needs a typed [ref] and a real IFormatProvider, and both
    # ways of getting that wrong throw once per line - on a 266 MB log that is millions of
    # exceptions and no output. The prefix is a fixed-width "yyyy-MM-dd HH:mm:ss", so read the
    # digits directly: correct, and orders of magnitude faster.
    if ($l[4] -eq '-' -and $l[13] -eq ':' -and $l[16] -eq ':') {
        $day = [int]$l.Substring(8,2)
        $secs = ([int]$l.Substring(11,2))*3600 + ([int]$l.Substring(14,2))*60 + [int]$l.Substring(17,2)
        $t = $day*86400 + $secs
        if ($null -eq $firstT) { $firstT = $t; $firstS = $l.Substring(11,8) }
        $lastT = $t; $lastS = $l.Substring(11,8)
        if ($null -ne $prevT) {
            $d = $t - $prevT
            if ($d -ge 20) { [void]$gaps.Add([pscustomobject]@{ secs=$d; at=$prevS; after=$prevLine }) }
        }
        $prevT = $t; $prevS = $l.Substring(11,8); $prevLine = $l
    }
    if ($l -match '\s(CBS|CSI|SQM|DPX|WCP)\s') { $c = $Matches[1]; $comp[$c] = 1 + [int]$comp[$c] }
    if ($l -match 'Perf:\s*(.+)$') { [void]$perf.Add($Matches[1].Trim()) }
    if ($l -match 'package\s+([A-Za-z0-9\.\-]+~[^,\s]+)') {
        $p = $Matches[1]
        [void]$pkgs.Add($p)
        # ...~amd64~sv-SE~10.0... : a language variant of a package
        if ($p -match '~[a-z]{2}-[A-Z]{2}~') { $langPkgs++ }
    }
}
$sr.Close(); $fs.Close()

Write-Output ("lines_scanned = {0:N0}   span = {1} .. {2}" -f $lines, $firstS, $lastS)
if ($null -ne $firstT -and $null -ne $lastT) { Write-Output ("span_minutes = {0:N1}" -f (($lastT-$firstT)/60)) }

Write-Output '--- line volume by component (what the log I/O is spent on) ---'
foreach ($k in ($comp.Keys | Sort-Object { -$comp[$_] })) {
    Write-Output ("  {0,-5} {1,10:N0}  ({2,5:N1}%)" -f $k, $comp[$k], (100*$comp[$k]/[math]::Max($lines,1)))
}

Write-Output ("distinct_packages_seen = {0:N0}" -f $pkgs.Count)
Write-Output ("language_variant_MENTIONS = {0:N0}  (line hits, not distinct packages - do not read as a package count)" -f $langPkgs)

# NOT all gaps are stalls. This log spans downloads, idle time and a reboot as well as servicing,
# and the largest gaps in the first measured run were exactly those - a 468s gap that looked
# alarming was the guest rebooting. Read a gap together with the line that precedes it.
Write-Output '--- biggest gaps between consecutive log lines (idle counts as a gap - check the preceding line) ---'
foreach ($g in ($gaps | Sort-Object secs -Descending | Select-Object -First 10)) {
    $txt = $g.after; if ($txt.Length -gt 150) { $txt = $txt.Substring(0,150) }
    Write-Output ("  {0,7:N0}s at {1}  after: {2}" -f $g.secs, $g.at, $txt)
}

Write-Output '--- CBS Perf: entries (its own timings) ---'
if ($perf.Count -eq 0) { Write-Output '  (none in this window)' }
else { foreach ($p in ($perf | Select-Object -Last 20)) { $t=$p; if($t.Length -gt 160){$t=$t.Substring(0,160)}; Write-Output ("  " + $t) } }
