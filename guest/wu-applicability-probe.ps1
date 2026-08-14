# Does DISM tell us, BEFORE installing, that a catalog sibling does not apply to this image?
# This is the whole premise of the applicability gate. Prediction from DISM's own earlier log
# ("Not applicable ... Feature: CumulativeUpdate_KB5043080"):
#   kb5043080 -> Applicable : No     kb5121003 -> Applicable : Yes
# If BOTH say Yes, the gate cannot work and iteration 1 is dead - say so.
$ErrorActionPreference = 'Continue'
$files = @(Get-ChildItem 'C:\ProgramData\Qubes\wu' -Recurse -Filter *.msu -EA SilentlyContinue)
Write-Output '=== RESULT ==='
if (-not $files) { Write-Output 'no .msu cached - nothing to probe'; exit 1 }
foreach ($f in $files) {
    $out = & DISM /Online /Get-PackageInfo /PackagePath:"$($f.FullName)" /English 2>&1
    $applicable = 'unknown'; $state = 'unknown'; $identity = ''
    foreach ($l in $out) {
        if     ($l -match '^\s*Applicable\s*:\s*(\S+)')        { $applicable = $Matches[1] }
        elseif ($l -match '^\s*State\s*:\s*(.+?)\s*$')          { $state      = $Matches[1] }
        elseif ($l -match '^\s*Package Identity\s*:\s*(\S+)')   { $identity   = $Matches[1] }
    }
    Write-Output ("{0}" -f $f.Name)
    Write-Output ("   applicable = {0}   state = {1}   rc = {2}" -f $applicable, $state, $LASTEXITCODE)
    Write-Output ("   identity   = {0}" -f $identity)
    if ($applicable -eq 'unknown') {
        Write-Output '   RAW (parser found nothing - first 12 lines):'
        foreach ($l in ($out | Select-Object -First 12)) { Write-Output ("     " + $l) }
    }
}
