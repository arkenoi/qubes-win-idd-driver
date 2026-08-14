<#
.SYNOPSIS
  How much of the 4.8 GB cumulative was actually USED? Exact accounting from the CBS install log.

.DESCRIPTION
  CBS narrates a verdict for every package inside the payload:

    Appl: Evaluating package applicability for package <P>, applicable state: Absent|Installed
    Plan: Skipping package since its start state and target state are both absent for package: <P>

  Counting those verdicts gives an EXACT package-level split of the payload into "applied" and
  "walked past". It also groups by language tag (~xx-XX~), because the usual reason a Windows 11
  cumulative is measured in gigabytes is that it carries every language and every edition, while a
  given image needs one.

  HONEST LIMIT, stated up front: this is a PACKAGE count, not a BYTE count. CBS does not log the
  compressed size of each payload member, and the .msu is deleted after a successful install
  (qubes-windows-update.ps1:546), so a byte-exact split cannot be recovered from the log alone.
  Anything byte-level below is measured from the FILE SYSTEM, not inferred.
#>
param([string]$Path = '')
$ErrorActionPreference = 'Continue'
Write-Output '=== RESULT ==='
$log = $Path
if (-not $log) {
    $c = @(Get-ChildItem 'C:\Windows\Logs\CBS\*.log' -EA SilentlyContinue | Sort-Object Length -Descending)
    if ($c.Count) { $log = $c[0].FullName }
}
if (-not $log -or -not (Test-Path $log)) { Write-Output 'no CBS log'; exit 1 }
Write-Output ("analysing: {0}  ({1:N1} MB)" -f $log, ((Get-Item $log).Length/1MB))

$applicable = New-Object 'System.Collections.Generic.HashSet[string]'
$absent     = New-Object 'System.Collections.Generic.HashSet[string]'
$installed  = New-Object 'System.Collections.Generic.HashSet[string]'
$langCount  = @{}
$lines = 0

$fs = [IO.File]::Open($log, 'Open', 'Read', 'ReadWrite')
$sr = New-Object IO.StreamReader($fs)
while ($null -ne ($l = $sr.ReadLine())) {
    $lines++
    if ($l -notmatch 'package') { continue }
    if ($l -match 'Evaluating package applicability for package ([^,]+), applicable state:\s*(\w+)') {
        $p = $Matches[1].Trim(); $state = $Matches[2]
        [void]$applicable.Add($p)
        if ($state -eq 'Absent') { [void]$absent.Add($p) } else { [void]$installed.Add($p) }
        if ($p -match '~([a-z]{2}-[A-Z]{2})~') { $lang = $Matches[1] } else { $lang = '(neutral)' }
        $langCount[$lang] = 1 + [int]$langCount[$lang]
    }
}
$sr.Close(); $fs.Close()

Write-Output ("lines_scanned            = {0:N0}" -f $lines)
Write-Output ("packages_evaluated       = {0:N0}" -f $applicable.Count)
Write-Output ("  -> applicable/installed = {0:N0}" -f $installed.Count)
Write-Output ("  -> absent (walked past) = {0:N0}" -f $absent.Count)
if ($applicable.Count) {
    Write-Output ("  package-level waste     = {0:N1}% of evaluated packages were Absent" -f (100*$absent.Count/$applicable.Count))
}

Write-Output '--- payload packages by language tag (top 15) ---'
foreach ($k in ($langCount.Keys | Sort-Object { -$langCount[$_] } | Select-Object -First 15)) {
    Write-Output ("  {0,-10} {1,7:N0}" -f $k, $langCount[$k])
}
$langTotal = 0; foreach ($k in $langCount.Keys) { if ($k -ne '(neutral)') { $langTotal += $langCount[$k] } }
$grand = 0; foreach ($k in $langCount.Keys) { $grand += $langCount[$k] }
if ($grand) {
    Write-Output ("language-tagged evaluations = {0:N0} of {1:N0} ({2:N1}%)" -f $langTotal, $grand, (100*$langTotal/$grand))
    Write-Output ("distinct language tags      = {0}" -f (@($langCount.Keys | Where-Object { $_ -ne '(neutral)' }).Count))
}

# Byte-level, measured rather than inferred: what the installed payload actually occupies.
Write-Output '--- measured on disk (not from the log) ---'
$wsx = Get-ChildItem 'C:\Windows\WinSxS' -Recurse -File -Force -EA SilentlyContinue |
       Measure-Object Length -Sum
Write-Output ("winsxs_apparent_gb = {0:N2}   files = {1:N0}   (hardlinked: apparent size overstates real usage)" -f ($wsx.Sum/1GB), $wsx.Count)
$d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
Write-Output ("disk_used_gb = {0:N2} of {1:N2}" -f (($d.Size-$d.FreeSpace)/1GB), ($d.Size/1GB))
