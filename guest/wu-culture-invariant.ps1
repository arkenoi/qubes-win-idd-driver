<#
.SYNOPSIS
  The dom0 progress protocol must emit "75.0", never "75,0", whatever the guest's locale.

.DESCRIPTION
  dom0 parses progress with float(line) (qube_connection.py::_collect_stderr). PowerShell's -f
  operator formats with CurrentCulture, and in a CUSTOM numeric format string the "." is not a
  literal - it is the decimal-separator placeholder. On a German guest "{0:0.0}" -f 75 yields
  "75,0", float("75,0") raises, and every progress line the updater ever sends is unparseable.
  A real user runs a German edition, so this is not theoretical.

  No German image is needed to test it: the culture is settable in-process.

  Per CLAUDE.md, a check counts as evidence only once it has been seen to FAIL on the defect. So
  this runs BOTH forms under each culture - the old culture-bound one, which must FAIL under de-DE,
  and the shipped invariant one, which must PASS everywhere. A run where the old form passes under
  de-DE means the harness is not actually changing the culture and proves nothing.
#>
$ErrorActionPreference = 'Continue'
Write-Output '=== RESULT ==='
$fail = 0
foreach ($c in 'en-US', 'de-DE', 'fr-FR', 'ru-RU') {
    [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($c)
    foreach ($p in 0, 6.0, 75.0, 100.0) {
        $old = "{0:0.0}" -f $p                                                          # the defect
        $new = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.0}', $p)  # shipped
        # "Parseable by dom0" means exactly: Python float() accepts it. A comma is not accepted.
        $oldOk = ($old -notmatch ',')
        $newOk = ($new -notmatch ',')
        if (-not $newOk) { $fail++ }
        Write-Output ("{0}  p={1,-5}  culture-bound='{2}' {3}   invariant='{4}' {5}" -f `
            $c, $p, $old, $(if($oldOk){'ok '}else{'BREAKS'}), $new, $(if($newOk){'ok '}else{'BREAKS'}))
    }
}
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('en-US')

# The harness must have been able to break the OLD form, or it tested nothing.
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('de-DE')
$controlBroke = (("{0:0.0}" -f 75.0) -match ',')
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('en-US')
Write-Output ("control (defect re-introduced under de-DE) produced a comma = {0}" -f $controlBroke)
if (-not $controlBroke) { Write-Output 'INCONCLUSIVE: the harness never reproduced the defect - this proves nothing'; exit 2 }
if ($fail -gt 0)        { Write-Output "FAIL: the shipped invariant form emitted a comma in $fail case(s)"; exit 1 }
Write-Output 'PASS: shipped form is culture-invariant, and the defect was demonstrably reproducible'
