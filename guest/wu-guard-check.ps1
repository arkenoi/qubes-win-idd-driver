# Does the freshness guard in wu-update.ps1:88-91 actually fire? Reproduce it verbatim.
#
# Claim under test: `$stamp = $null` then `[ref]$stamp` into TryParse(String, out DateTime) cannot
# bind - PowerShell converts the [ref] variable's CURRENT value to the ByRef parameter type during
# overload resolution, and $null has no conversion to the non-nullable value type DateTime. With
# $ErrorActionPreference='SilentlyContinue' (wu-update.ps1:19) the resulting MethodException is a
# SILENT statement-terminating error: the whole `if` is abandoned and `continue` never runs, so the
# guard fails OPEN on every poll.
#
# This is the same trap that broke wu-cbs-analyze.ps1 this morning ("Cannot find an overload for
# TryParseExact and the argument count: 5"), which is why it is worth pinning down rather than
# patching by feel. Tests the exact shape, plus an initializer sweep, plus the fix.
$ErrorActionPreference = 'SilentlyContinue'   # same as the handler
Write-Output '=== RESULT ==='
$StartedAt = (Get-Date).AddSeconds(-2)
$staleTs   = '2020-08-14T14:35:55'    # unambiguously older than StartedAt
$freshTs   = (Get-Date).AddSeconds(30).ToString('s')

# --- 1. initializer sweep: which starting value lets the overload bind? -----------------------
foreach ($init in @('null','zero','mindate','now')) {
    $Error.Clear()
    switch ($init) {
        'null'    { $stamp = $null }
        'zero'    { $stamp = 0 }
        'mindate' { $stamp = [datetime]::MinValue }
        'now'     { $stamp = Get-Date }
    }
    $r = 'NO VALUE (threw)'
    $r = [datetime]::TryParse($staleTs, [ref]$stamp)
    Write-Output ("init={0,-8} TryParse returned '{1}'  errors={2}" -f $init, $r, $Error.Count)
}

# --- 2. the guard in its REAL shape: a loop with `continue` ----------------------------------
function Test-Guard {
    param([string]$Ts, [switch]$Fixed)
    $script:reached = $false
    $Error.Clear()
    foreach ($i in 1..1) {
        if ($Ts) {
            if ($Fixed) {
                $stamp = [datetime]::MinValue
                if ([datetime]::TryParseExact($Ts, 'yyyy-MM-ddTHH:mm:ss',
                        [Globalization.CultureInfo]::InvariantCulture,
                        [Globalization.DateTimeStyles]::None, [ref]$stamp) -and $stamp -lt $StartedAt) { continue }
            } else {
                $stamp = $null
                if ([datetime]::TryParse($Ts, [ref]$stamp) -and $stamp -lt $StartedAt) { continue }
            }
        }
        $script:reached = $true      # reaching here means the status was ACCEPTED
    }
    [pscustomobject]@{ accepted = $script:reached; errors = $Error.Count }
}

$a = Test-Guard -Ts $staleTs
Write-Output ("CURRENT code, STALE status : accepted={0} errors={1}   (accepted=True means the guard never fired)" -f $a.accepted, $a.errors)
$b = Test-Guard -Ts $staleTs -Fixed
Write-Output ("FIXED   code, STALE status : accepted={0} errors={1}   (must be False)" -f $b.accepted, $b.errors)
$c = Test-Guard -Ts $freshTs -Fixed
Write-Output ("FIXED   code, FRESH status : accepted={0} errors={1}   (must be True - do not break the normal path)" -f $c.accepted, $c.errors)

Write-Output '--- verdict ---'
if ($a.accepted -and -not $b.accepted -and $c.accepted) {
    Write-Output 'CONFIRMED: the shipped guard never fires; the fix drops stale status and keeps fresh status'
} else {
    Write-Output 'NOT AS CLAIMED - read the rows above'
}
