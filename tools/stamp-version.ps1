<#
.SYNOPSIS
    Generate the version header that EVERY QWT-NG binary stamps its VERSIONINFO from.
    Drop-in replacement for qubes-builderv2's `set-version.ps1 <versionfile> <header>`.

.DESCRIPTION
    WHAT THIS IS FOR - PER-COMPONENT ASSERTABILITY. Before this script the shipped binaries carried
    no version that could be mapped to a release: the core-agent exes were stamped 4.2.2.0 (== stock),
    the helpers (wgcbroker, notifhost, etwproxy, qwt-bootstrap, qubesdb-read) had no version resource
    at all, and the driver used a wall-clock minute counter. So "did THIS component come from THIS
    build" could not be asked of a file - only of a whole package, and the package_version
    (<ver>+agent.<agentsha>) could not tell two packages built from one driver-repo fix apart either
    (two 4.3.21 asset directories both read "4.3.21+agent.a1956929c319"; only MANIFEST.json's
    driver_repo_commit and a grep for the fix distinguished them).

    With this generator every OURS binary reads FILEVERSION == <release>.<build_rev>, where build_rev
    is the release-package run number. That is what the release verifier's OURS_VERSION gate asserts
    per file, what makes two packages of one version differ in every binary, and what lets a guest be
    asked "which build is installed" component by component.

    WHAT THIS IS NOT. It does NOT fix MSI upgrades, and nothing here should be read as if it did:
      - the Windows Installer per-FILE versioning rule ("keep an installed file whose version is >=
        the incoming one") is already neutralised by packaging/setup/Install-QwtImproved.ps1, which
        passes REINSTALLMODE=amus - so an equal or lower FILEVERSION would be overwritten anyway;
      - a rebuild at the SAME agent/version is not an install path at all: the MSI ProductVersion
        uses only the first three fields, and tools/cut-release.sh invariant 2 refuses to release a
        version that already has a tag (the v4.3.0/v4.3.1 same-ProductVersion case), so "package B of
        version X over package A of version X" never happens through the installer.

    THE MAPPING, stated once. A VERSIONINFO FILEVERSION is four 16-bit integers. The release version
    is MAJOR.MINOR.PATCH (agent/version, enforced 3-field). So:

        FILEVERSION  =  MAJOR , MINOR , PATCH , BUILD_REV

    THE FOURTH FIELD has three disjoint meanings, and no two producers may share a value:
      - release-package.yml: BUILD_REV = that run's github.run_number (>= 1 always), exported as
        QWTNG_BUILD_REV to every job and passed as `build_rev` to the reusable workflows;
      - build.yml (dev overlay): sets QWTNG_BUILD_REV=0 EXPLICITLY. A dev overlay therefore reads
        <ver>.0 = "not a release" - the exact shape the release gates reject - and can never collide
        with, or out-number, a release stamped <ver>.<run>. Two independent run counters in one field
        would let an overlay look newer than a later release; 0 is the only value a run number never
        takes;
      - a local build with QWTNG_BUILD_REV unset: 0 with a warning (same meaning as the overlay).
    In CI (GITHUB_ACTIONS set) an UNSET fourth field is an error, never a default: a release build
    that quietly stamped .0 would look like a local build and tell nobody which run produced it.

    CONTRACT. Positional arguments are IDENTICAL to upstream's set-version.ps1, so CI can copy this
    file over `deps-src\builderv2\qubesbuilder\plugins\build_windows\scripts\set-version.ps1` and
    every PreBuildEvent / target that already calls `$(QB_SCRIPTS)\set-version.ps1` (gui-agent,
    watchdog, windows-utils, core-agent's qwt-version.props) stamps <ver>.<rev> with no source change
    in those repos. The file is self-contained on purpose - it is copied alone, so it may import
    nothing. All paths are resolved ONCE against PowerShell's current location and used as absolute
    paths everywhere: Test-Path follows $PWD but System.IO.File follows the PROCESS working directory,
    and a caller that has done Set-Location would otherwise test one file and write another.

    FAIL CLOSED. Every failure prints one line `stamp-version: FAIL code=<CODE> k=v` to stderr and
    throws, so msbuild <Exec>, a workflow step and an in-process `& script.ps1` all see a non-zero
    result. Codes: BAD_VERSION_FILE, MISSING_BUILD_REV, USAGE, BAD_FILEDESCRIPTION - each driven
    with the defect re-introduced by packaging/version-stamp/selftest.sh.

.PARAMETER VersionFile
    Path to the 3-field version file (agent/version). Positional 0, as upstream.
.PARAMETER Header
    Output header path. Positional 1, as upstream. Left untouched when the content is already
    identical so rc.exe is not forced to recompile - and the linker to relink - a binary whose
    version did not change. The header is per PROJECT (each .props generates into its own $(IntDir)),
    so no two builds ever write one file and a plain write is sufficient.
.PARAMETER FileDescription
    Optional positional 2. When given, the header also defines QWT_FILEDESCRIPTION_STR so a
    project with no .rc of its own can use packaging/version-stamp/qwtng_version.rc unchanged.
    Printable ASCII, no quotes or backslashes (it becomes a C string literal via cmd.exe).
.PARAMETER BuildRev
    Explicit fourth field; wins over env QWTNG_BUILD_REV. For tests and for callers that already
    resolved the run number.
.PARAMETER Print
    Print the resolved "MAJOR.MINOR.PATCH.REV" to stdout and exit without writing a header - the
    one resolver workflows and packaging/version-stamp/stamp-inf-driverver.ps1 use, so no second
    copy of the mapping exists anywhere.

.EXAMPLE
    powershell -NoProfile -File tools\stamp-version.ps1 agent\version obj\qwtng_version.h "Qubes WGC capture broker"
.EXAMPLE
    $env:QWTNG_BUILD_REV = $env:GITHUB_RUN_NUMBER; tools\stamp-version.ps1 agent\version -Print
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)] [string]$VersionFile,
    [Parameter(Position = 1)] [string]$Header,
    [Parameter(Position = 2)] [string]$FileDescription,
    [string]$BuildRev,
    [switch]$Print
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# The 16-bit ceiling of every VERSIONINFO field. Not a style choice: rc.exe silently truncates
# larger values, so a run number past this would stamp a WRONG version that still looks valid.
$FieldMax = 65535

function Fail([string]$Code, [string]$Detail) {
    # One machine-readable line on stderr for whoever greps a CI log, then a terminating error so
    # every caller shape - msbuild <Exec>, a workflow step, `powershell script.ps1 a b`, an
    # in-process `& script.ps1` - sees a non-zero result. Never Write-Error + continue: a stamp
    # that "failed but the build went on" is the silent class this whole tree exists to end.
    [Console]::Error.WriteLine("stamp-version: FAIL code=$Code $Detail")
    throw "${Code}: $Detail"
}

function Resolve-Absolute([string]$PathText) {
    # Resolves relative to PowerShell's $PWD (not the process cwd) and does not require the file to
    # exist. The ONE place paths are interpreted; everything below uses the result.
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PathText)
}

# ---------------------------------------------------------------- release version (3 fields)
if ([string]::IsNullOrEmpty($VersionFile)) {
    Fail 'USAGE' 'usage: stamp-version.ps1 <versionfile> <header> [<filedescription>] | <versionfile> -Print'
}
$VersionFile = Resolve-Absolute $VersionFile
if (-not (Test-Path -LiteralPath $VersionFile -PathType Leaf)) {
    Fail 'BAD_VERSION_FILE' "file=$VersionFile reason=missing"
}
$raw = [System.IO.File]::ReadAllText($VersionFile)
$release = $raw.Trim()
# Exactly three dot-separated fields of at most five digits each: the shape make-setup.ps1,
# make-package.ps1, qwt-full.yml and cut-release.sh all enforce, re-enforced here because THIS is
# the place where a 4-field file would otherwise be stamped as-is and silently shift the build
# revision into the fifth position rc.exe does not have.
if ($release -notmatch '^(\d{1,5})\.(\d{1,5})\.(\d{1,5})$') {
    Fail 'BAD_VERSION_FILE' "file=$VersionFile got='$release' want=MAJOR.MINOR.PATCH"
}
$major = [int]$Matches[1]; $minor = [int]$Matches[2]; $patch = [int]$Matches[3]
foreach ($f in @($major, $minor, $patch)) {
    if ($f -gt $FieldMax) {
        Fail 'BAD_VERSION_FILE' "file=$VersionFile got='$release' reason=field_${f}_exceeds_$FieldMax"
    }
}

# ---------------------------------------------------------------- build revision (4th field)
# An explicit -BuildRev wins; otherwise the environment. GITHUB_RUN_NUMBER is deliberately NOT
# read: inside a reusable workflow it is the CALLER's run number, which happens to be what we want
# but is an accident of GitHub semantics rather than a contract. release-package.yml passes the
# number explicitly as `build_rev` to qwt-full / pv-xenvif / pv-xencons and exports it as
# QWTNG_BUILD_REV in every job, so one name means one thing everywhere.
$inCi = -not [string]::IsNullOrEmpty($env:GITHUB_ACTIONS)
$revRaw = $BuildRev
$revSrc = 'parameter -BuildRev'
if ([string]::IsNullOrEmpty($revRaw)) {
    $revRaw = $env:QWTNG_BUILD_REV
    $revSrc = 'env QWTNG_BUILD_REV'
}
if ([string]::IsNullOrEmpty($revRaw)) {
    if ($inCi) {
        # No default in CI, ever. A release binary stamped .0 is indistinguishable from a local
        # build and would sail through as "versioned" while telling nobody which run made it.
        # (A dev-overlay build that MEANS 0 sets QWTNG_BUILD_REV=0 explicitly - see .DESCRIPTION.)
        Fail 'MISSING_BUILD_REV' "QWTNG_BUILD_REV is unset in CI (GITHUB_ACTIONS=$env:GITHUB_ACTIONS); export it from the release-package run number in every job, or set it to 0 explicitly for a non-release build"
    }
    Write-Warning 'stamp-version: QWTNG_BUILD_REV unset outside CI - stamping build revision 0 (a LOCAL build; the release gates reject this shape by design)'
    $rev = 0
    $revSrc = 'local default'
} else {
    $revRaw = $revRaw.Trim()
    # A SET but unusable value is never downgraded to the local default: it means the plumbing
    # that was supposed to carry the run number is broken, and that must stop the build.
    if ($revRaw -notmatch '^\d{1,5}$' -or [int]$revRaw -gt $FieldMax) {
        Fail 'MISSING_BUILD_REV' "$revSrc='$revRaw' is not an integer in 0..$FieldMax"
    }
    $rev = [int]$revRaw
}

$fileVersion = "$major.$minor.$patch.$rev"

if ($Print) {
    Write-Output $fileVersion
    exit 0
}

# ---------------------------------------------------------------- header
if ([string]::IsNullOrEmpty($Header)) {
    Fail 'USAGE' 'no header path given (usage: stamp-version.ps1 <versionfile> <header> [<filedescription>])'
}
$Header = Resolve-Absolute $Header
if (-not [string]::IsNullOrEmpty($FileDescription)) {
    # It is spliced into a C string literal and travels through cmd.exe (msbuild <Exec>) on the
    # way here, so the alphabet is deliberately small: a stray quote or backslash would either
    # break rc.exe or, worse, end the literal early and stamp a truncated description.
    if ($FileDescription -notmatch '^[A-Za-z0-9 ._,()+/:-]{1,120}$') {
        Fail 'BAD_FILEDESCRIPTION' "value='$FileDescription' allowed=[A-Za-z0-9 ._,()+/:-]{1,120}"
    }
}

# The header is a pure function of (version file content, rev, description): identical inputs must
# produce identical bytes, so nothing environment-dependent - not the rev's SOURCE, not a
# timestamp, not a path - goes into it. That is what makes the "unchanged header left untouched"
# rule below hold, and with it incremental builds.
$verFileName = Split-Path -Leaf $VersionFile
$lines = @(
    "// GENERATED by tools/stamp-version.ps1 from $verFileName - do not edit, do not commit.",
    "// release $release, build revision $rev. FILEVERSION = MAJOR,MINOR,PATCH,BUILD_REV.",
    '#pragma once',
    '',
    '// builderv2 contract (agent/include/version_common.rc, core-agent/src/version_common.rc,',
    '// packaging/version-stamp/qwtng_version.rc)',
    "#define QWT_FILEVERSION $major,$minor,$patch,$rev",
    "#define QWT_FILEVERSION_STR `"$fileVersion`"",
    '#define QWT_PRODUCTVERSION QWT_FILEVERSION',
    '#define QWT_PRODUCTVERSION_STR QWT_FILEVERSION_STR',
    '',
    '// the release as humans and cut-release.sh name it, and the build that produced this binary',
    "#define QWTNG_RELEASE_STR `"$release`"",
    "#define QWTNG_BUILD_REV $rev",
    '',
    '// driver family (driver/IddSampleDriver/IddSampleDriver.rc) - same four numbers, its own names',
    "#define QIDD_VER_MAJOR $major",
    "#define QIDD_VER_MINOR $minor",
    "#define QIDD_VER_BUILD $patch",
    "#define QIDD_VER_REV   $rev",
    "#define QIDD_VER_STR   `"$fileVersion`""
)
if (-not [string]::IsNullOrEmpty($FileDescription)) {
    $lines += ''
    $lines += '// per-project, from the build (packaging/version-stamp/qwtng-version.props QwtNgFileDescription)'
    $lines += "#define QWT_FILEDESCRIPTION_STR `"$FileDescription`""
}
# CRLF + ASCII: rc.exe is happiest with plain ASCII and the header is consumed on Windows only.
$content = ($lines -join "`r`n") + "`r`n"

$headerDir = [System.IO.Path]::GetDirectoryName($Header)
if (-not [string]::IsNullOrEmpty($headerDir) -and -not [System.IO.Directory]::Exists($headerDir)) {
    [System.IO.Directory]::CreateDirectory($headerDir) | Out-Null
}

$existing = $null
if ([System.IO.File]::Exists($Header)) {
    $existing = [System.IO.File]::ReadAllText($Header, [System.Text.Encoding]::ASCII)
}
if ($existing -eq $content) {
    Write-Host "stamp-version: $fileVersion already in $Header (unchanged; rev from $revSrc)"
    exit 0
}

# A plain write. The header is generated per project into that project's $(IntDir) (both .props
# files do this), so no other build reads or writes this path; there is nothing to be atomic
# against. (Windows PowerShell 5.1's Move-Item -Force is Delete()+MoveTo(), not a replace, so a
# "temp + rename" would not have bought atomicity on the interpreter msbuild invokes anyway.)
[System.IO.File]::WriteAllText($Header, $content, [System.Text.Encoding]::ASCII)
Write-Host "stamp-version: $fileVersion -> $Header (rev from $revSrc)"
