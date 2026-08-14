# Is PowerShell's case-insensitive matching ORDINAL, as docs/LOCALE-TESTING.md currently claims?
#
# Two of my own statements are under test here:
#   * LOCALE-TESTING.md says `-match`/`-eq` are "Ordinal", so the Turkish dotless-i trap cannot
#     reach our matching;
#   * FINDINGS says `-eq` is NOT ordinal, because it ignored an invisible LRM mark.
# Both cannot be right. The likely truth is INVARIANT-CULTURE comparison, which would explain both
# observations at once: invariant casing maps i<->I the English way (so Turkish does not bite), but
# it is still LINGUISTIC, so zero-width marks carry no weight.
#
# Also tests health-check.ps1:229, which lowercases a device identifier with .ToLower() - that one
# IS culture-sensitive and would produce a dotless i under tr-TR.
$ErrorActionPreference = 'Continue'
Write-Output '=== RESULT ==='
foreach ($c in 'en-US','tr-TR') {
    [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($c)
    $tl  = 'XENIFACE'.ToLower()
    $tli = 'XENIFACE'.ToLowerInvariant()
    # Print code points: the console code page cannot be trusted to show a dotless i honestly.
    $cp  = (([int[]][char[]]$tl)  | ForEach-Object { '{0:X4}' -f $_ }) -join ' '
    Write-Output ("{0}  'XENIFACE'.ToLower()          = '{1}'  [{2}]" -f $c, $tl, $cp)
    Write-Output ("{0}  'XENIFACE'.ToLowerInvariant() = '{1}'" -f $c, $tli)
    Write-Output ("{0}  ToLower() -eq 'xeniface'      : {1}   <- health-check.ps1:229 depends on this" -f $c, ($tl -eq 'xeniface'))
    Write-Output ("{0}  ToLower() -ceq 'xeniface'     : {1}   (case-SENSITIVE, the honest test)" -f $c, ($tl -ceq 'xeniface'))
    Write-Output ("{0}  'XENIFACE' -match 'xeniface'  : {1}" -f $c, ('XENIFACE' -match 'xeniface'))
    Write-Output ("{0}  'XENIFACE' -like  'xeniface'  : {1}" -f $c, ('XENIFACE' -like 'xeniface'))
    Write-Output ("{0}  'i' -eq 'I'                   : {1}" -f $c, ('i' -eq 'I'))
    Write-Output ("{0}  'i' -match 'I'                : {1}" -f $c, ('i' -match 'I'))
}
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('en-US')

# Ordinal vs invariant: an invisible LRM has no linguistic weight but IS a distinct code unit.
$LRM = [char]0x200E
$a = 'Update'; $b = "Update$LRM"
Write-Output ("-eq with invisible LRM        : {0}   (True => linguistic, i.e. NOT ordinal)" -f ($a -eq $b))
Write-Output ("Ordinal comparison of the same: {0}" -f ([string]::Equals($a, $b, [StringComparison]::OrdinalIgnoreCase)))
