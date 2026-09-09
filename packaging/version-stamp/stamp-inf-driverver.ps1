<#
.SYNOPSIS
    Rewrite an INF's DriverVer to `<mm/dd/yyyy>,<MAJOR.MINOR.PATCH.BUILD_REV>` - the same four
    numbers the driver binary next to it was stamped with.

.DESCRIPTION
    WHY. stampinf's default DriverVer VERSION is the BUILD TIME as HH.MM.SS.ms. Versions with
    leading fields like 21.x / 23.x land in the WDDM driver-version encoding space that graphics
    compat logic parses - measured 2026-08-27: packages versioned 21.22.* and 23.53.* never
    surfaced the registry modes and rejected the QIDD ioctl while 15.51.* and 8.1.* worked, SAME
    BYTES. Evening builds were broken and morning builds worked. Both workflows then pinned the
    version to 4.3.<epoch-minute> - correct in the 4.x space, but implemented twice (build.yml and
    release-package.yml, copy-pasted) and unrelated to the release number, so the INF could not be
    mapped back to a release and the two copies could drift. This is the ONE implementation; both
    workflows call it. The version comes from tools/stamp-version.ps1 -Print, so the INF, the
    driver DLL's FILEVERSION and every other OURS binary read the identical <ver>.<rev>, and
    activate-idd's existing bound-DriverVer == INF-DriverVer assertion then proves the RELEASE
    version reached the device, not just "some INF did".

    MISSING DATA FAILS. An INF with no DriverVer line, or with more than one, throws
    (INF_DRIVERVER_COUNT) - a regex replace that matched nothing and wrote the file back unchanged
    would look exactly like success.

    BYTES OUTSIDE THE STAMPED LINE ARE PRESERVED, or the script fails. A re-encoded INF is a
    different .cat input. The encoding is detected from the BOM (stampinf writes UTF-16LE with BOM;
    a hand-written INF may be UTF-8 with or without BOM) and the SAME encoding writes the result.
    Every decoder is constructed with throwOnInvalidBytes: a BOM-less file containing a byte that is
    not valid UTF-8 (a Latin-1 0xA9 in a copyright string - the normal shape of an "ANSI" INF) FAILS
    with INF_ENCODING and the file is left untouched. Without that flag the decoder substitutes
    U+FFFD and the write silently mangles a string table somewhere else in the INF while the
    DriverVer line looks perfect. packaging/version-stamp/selftest.sh byte-compares the whole file
    against an independently constructed expectation for each encoding.

.PARAMETER Inf          The INF to stamp, in place.
.PARAMETER VersionFile  The 3-field release version file (agent/version).
.PARAMETER BuildRev     Optional explicit fourth field; otherwise env QWTNG_BUILD_REV (see
                        tools/stamp-version.ps1 for the fail-closed rules).
.PARAMETER Date         Optional DriverVer date as mm/dd/yyyy; defaults to today (UTC). Exists so a
                        fixture can assert an exact line. pnputil ranks candidate drivers by date
                        FIRST and version second, so the default is always "now" - a release can
                        never carry an older date than the one it supersedes.

.EXAMPLE
    powershell -NoProfile -File packaging\version-stamp\stamp-inf-driverver.ps1 -Inf idd-package\IddSampleDriver.inf -VersionFile agent\version
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]$Inf,
    [Parameter(Mandatory = $true)] [string]$VersionFile,
    [string]$BuildRev,
    [string]$Date
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Fail([string]$Code, [string]$Detail) {
    [Console]::Error.WriteLine("stamp-inf-driverver: FAIL code=$Code $Detail")
    throw "${Code}: $Detail"
}

# Resolve once against PowerShell's current location; System.IO below follows the process cwd.
$Inf = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Inf)
if (-not [System.IO.File]::Exists($Inf)) { Fail 'INF_MISSING' "inf=$Inf" }

# ONE resolver for the version: the generator's -Print mode. Not re-implemented here on purpose -
# a second copy of "3 fields + run number" is a second place for the mapping to be wrong. A throw
# inside the generator (BAD_VERSION_FILE, MISSING_BUILD_REV) propagates out of this call unchanged.
$stamper = Join-Path $PSScriptRoot '..\..\tools\stamp-version.ps1'
if (-not (Test-Path -LiteralPath $stamper -PathType Leaf)) { Fail 'STAMPER_MISSING' "expected=$stamper" }
$stampArgs = @{ VersionFile = $VersionFile; Print = $true }
if (-not [string]::IsNullOrEmpty($BuildRev)) { $stampArgs['BuildRev'] = $BuildRev }
$fileVersion = [string](& $stamper @stampArgs | Select-Object -Last 1)

if ([string]::IsNullOrEmpty($Date)) {
    $Date = [DateTime]::UtcNow.ToString('MM/dd/yyyy', [System.Globalization.CultureInfo]::InvariantCulture)
} else {
    # DriverVer's date is mm/dd/yyyy and nothing else; SetupAPI rejects other shapes at install time,
    # which is the wrong place to learn about a typo in a fixture.
    $parsed = [DateTime]::MinValue
    if (-not [DateTime]::TryParseExact($Date, 'MM/dd/yyyy', [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        Fail 'BAD_DATE' "date='$Date' want=mm/dd/yyyy"
    }
}
$newLine = "DriverVer = $Date,$fileVersion"

# ---------------------------------------------------------------- read, preserving encoding
$bytes = [System.IO.File]::ReadAllBytes($Inf)
$enc = $null
$encName = ''
if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
    # UnicodeEncoding(bigEndian, byteOrderMark, throwOnInvalidBytes): UTF-16LE, BOM kept, strict
    $enc = New-Object System.Text.UnicodeEncoding($false, $true, $true)
    $encName = 'utf-16le-bom'
} elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    # UTF8Encoding(emitBOM, throwOnInvalidBytes): UTF-8, BOM kept, strict
    $enc = New-Object System.Text.UTF8Encoding($true, $true)
    $encName = 'utf-8-bom'
} else {
    # No BOM: only valid UTF-8 (which includes pure ASCII) round-trips byte-for-byte. Anything else
    # is refused rather than guessed - see INF_ENCODING in .DESCRIPTION.
    $enc = New-Object System.Text.UTF8Encoding($false, $true)
    $encName = 'utf-8'
}
$text = $null
try {
    $text = $enc.GetString($bytes)
} catch {
    # A .NET method throw reaches PowerShell wrapped (MethodInvocationException); unwrap to decide.
    $ex = $_.Exception
    while ($null -ne $ex -and -not ($ex -is [System.Text.DecoderFallbackException]) -and $null -ne $ex.InnerException) {
        $ex = $ex.InnerException
    }
    if ($ex -is [System.Text.DecoderFallbackException]) {
        Fail 'INF_ENCODING' "inf=$Inf encoding=$encName reason=invalid_bytes ($($ex.Message)) - a BOM-less INF must be valid UTF-8; re-save it as UTF-16LE with BOM (what stampinf writes) instead of letting the stamper guess"
    }
    throw
}
# Strip the BOM the decoder leaves as U+FEFF so the regex anchors see the real first line; the
# encoder puts it back on write for the two BOM'd encodings.
if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }

$rx = New-Object System.Text.RegularExpressions.Regex('^[ \t]*DriverVer[ \t]*=[ \t]*[^\r\n]*', 'Multiline')
$matches_ = $rx.Matches($text)
if ($matches_.Count -ne 1) {
    Fail 'INF_DRIVERVER_COUNT' "inf=$Inf found=$($matches_.Count) want=1"
}
$old = $matches_[0].Value
$text = $rx.Replace($text, $newLine, 1)

# ---------------------------------------------------------------- write
# The only bytes that differ from the input are the DriverVer line: a strict decoder proved the
# input round-trips, and the same encoder writes it back. (No re-read "verification" here on
# purpose: re-decoding what was just written with the identical encoder cannot disagree, so such a
# check could never fail; the byte-level proof lives in selftest.sh where it CAN.)
[System.IO.File]::WriteAllText($Inf, $text, $enc)
Write-Host "stamp-inf-driverver: $Inf ($encName)"
Write-Host "  was: $($old.Trim())"
Write-Host "  now: $newLine"
