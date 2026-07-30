<#
.SYNOPSIS
    Assemble the qwt-improved-package artifact from the two CI build artifacts.

.DESCRIPTION
    Run from the repository root on a runner that has already downloaded:
      * the 'gui-agent-package'  artifact (gui-agent.exe / gui-watchdog.exe / dump-windows.exe + pdbs)
      * the 'idd-driver-package' artifact (optional; IddCx driver + ddaprobe.exe)

    Produces a self-describing directory that actions/upload-artifact uploads as-is, so the
    user downloads one zip and gets install script + README + MANIFEST + binaries.

    The dependency refs recorded in MANIFEST.json are PARSED OUT of the gui-agent job's
    env: block in .github/workflows/build.yml, rather than duplicated here, so this file
    cannot drift away from what CI actually built with. If parsing fails the manifest says
    so instead of guessing.

.PARAMETER AgentArtifact   Directory the gui-agent-package artifact was downloaded into.
.PARAMETER DriverArtifact  Directory the idd-driver-package artifact was downloaded into (optional).
.PARAMETER OutDir          Staging directory to create (default: package-qwt).
.PARAMETER RepoRoot        Repository root (default: current directory).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$AgentArtifact,
    [string]$DriverArtifact,
    [string]$OutDir = 'package-qwt',
    [string]$RepoRoot = '.'
)

$ErrorActionPreference = 'Stop'

function Need {
    param([string]$Path, [string]$What)
    if (-not (Test-Path -LiteralPath $Path)) { throw "$What not found: $Path" }
    return (Resolve-Path -LiteralPath $Path).Path
}

$RepoRoot      = Need $RepoRoot       'repository root'
$AgentArtifact = Need $AgentArtifact  'gui-agent artifact directory'
$payload       = Need (Join-Path $RepoRoot 'packaging\payload') 'packaging payload directory'

# ---------------------------------------------------------------- version / provenance
function Git {
    param([string[]]$GitArgs, [string]$Fallback = 'unknown')
    # $ErrorActionPreference is 'Stop' for this script, which turns ANYTHING a native command
    # writes to stderr into a terminating NativeCommandError - and git writes to stderr
    # routinely even when it succeeds. That made every provenance field silently fall back to
    # 'unknown' in CI (agent_commit, driver_repo_commit, agent_describe), which is
    # unacceptable for a package people are meant to install. Drop to Continue for the call.
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # -c safe.directory=* is REQUIRED on a GitHub runner. actions/checkout adds the
        # workspace to safe.directory inside a TEMPORARY HOME and then restores HOME, so by
        # the time a later step runs, git sees "detected dubious ownership" and fails - which
        # is why every provenance field came back 'unknown' in CI while working locally.
        $v = & git '-c' 'safe.directory=*' @GitArgs 2>$null
        if ($LASTEXITCODE -eq 0 -and $v) { return ($v | Select-Object -First 1).Trim() }
    } catch {
    } finally {
        $ErrorActionPreference = $saved
    }
    return $Fallback
}

$agentSha  = Git @('-C', (Join-Path $RepoRoot 'agent'), 'rev-parse', 'HEAD')
$agentDesc = Git @('-C', (Join-Path $RepoRoot 'agent'), 'describe', '--always', '--dirty', '--tags')
$repoSha   = Git @('-C', $RepoRoot, 'rev-parse', 'HEAD')
$shortAgent = if ($agentSha -ne 'unknown') { $agentSha.Substring(0, 12) } else { 'unknown' }

# QWT release this overlay targets. Bump deliberately if the agent is ever rebased onto a
# different upstream QWT version - it is what install-qwt-improved.ps1's README promises.
$baseQwt = '4.2.2'
$version = "$baseQwt+agent.$shortAgent"

# ---------------------------------------------------------------- dependency refs, parsed
# from the workflow rather than duplicated. Read the gui-agent job's env: block.
$depRefs = [ordered]@{}
$wf = Join-Path $RepoRoot '.github\workflows\build.yml'
if (Test-Path -LiteralPath $wf) {
    $lines = @(Get-Content -LiteralPath $wf)
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^  gui-agent:\s*$') { $start = $i + 1; break }
    }
    if ($start -ge 0) {
        $inEnv = $false
        for ($i = $start; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if ($line -match '^  [A-Za-z0-9_.-]+:') { break }   # next top-level job
            if ($line -match '^    env:\s*$') { $inEnv = $true; continue }
            if ($inEnv) {
                if ($line -match '^      ([A-Za-z0-9_]+):\s*(\S+)') { $depRefs[$Matches[1]] = $Matches[2] }
                elseif ($line -match '^    \S') { $inEnv = $false }
            }
        }
    }
}
if ($depRefs.Count -eq 0) {
    $depRefs['_note'] = 'UNRESOLVED: could not parse the gui-agent job env: block from .github/workflows/build.yml'
}

# ---------------------------------------------------------------- stage
if (Test-Path -LiteralPath $OutDir) { Remove-Item -LiteralPath $OutDir -Recurse -Force }
foreach ($d in 'bin', 'symbols', 'tools', 'optional\idd-driver') {
    New-Item -ItemType Directory -Force -Path (Join-Path $OutDir $d) | Out-Null
}

Copy-Item (Join-Path $payload 'install-qwt-improved.ps1') $OutDir -Force
Copy-Item (Join-Path $payload 'README.md')                $OutDir -Force

# installable binaries - hard requirement, fail loudly if the agent build did not produce them
foreach ($f in 'gui-agent.exe', 'gui-watchdog.exe') {
    $src = Join-Path $AgentArtifact $f
    if (-not (Test-Path -LiteralPath $src)) { throw "gui-agent artifact is missing $f" }
    Copy-Item $src (Join-Path $OutDir 'bin') -Force
}
# symbols - nice to have
foreach ($f in 'gui-agent.pdb', 'gui-watchdog.pdb') {
    $src = Join-Path $AgentArtifact $f
    if (Test-Path -LiteralPath $src) { Copy-Item $src (Join-Path $OutDir 'symbols') -Force }
    else { Write-Warning "no $f in the gui-agent artifact" }
}
# diagnostics - never installed by the install script
foreach ($f in 'dump-windows.exe') {
    $src = Join-Path $AgentArtifact $f
    if (Test-Path -LiteralPath $src) { Copy-Item $src (Join-Path $OutDir 'tools') -Force }
}

$driverIncluded = $false
if ($DriverArtifact -and (Test-Path -LiteralPath $DriverArtifact)) {
    $DriverArtifact = (Resolve-Path -LiteralPath $DriverArtifact).Path
    $probe = Join-Path $DriverArtifact 'ddaprobe.exe'
    if (Test-Path -LiteralPath $probe) { Copy-Item $probe (Join-Path $OutDir 'tools') -Force }
    Get-ChildItem -LiteralPath $DriverArtifact -File |
        Where-Object { $_.Name -ne 'ddaprobe.exe' } |
        ForEach-Object { Copy-Item $_.FullName (Join-Path $OutDir 'optional\idd-driver') -Force }
    $driverIncluded = $true
} else {
    Write-Warning 'no idd-driver artifact supplied; optional/idd-driver will be empty'
    Set-Content -LiteralPath (Join-Path $OutDir 'optional\idd-driver\NOT-INCLUDED.txt') `
        -Value 'The idd-driver artifact was not available for this build.' -Encoding ASCII
}

# ---------------------------------------------------------------- manifest
function FileEntry {
    param([string]$Path)
    $i = Get-Item -LiteralPath $Path
    [ordered]@{
        size    = $i.Length
        version = $i.VersionInfo.FileVersion
        sha256  = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
    }
}

$binFiles = [ordered]@{}
Get-ChildItem -LiteralPath (Join-Path $OutDir 'bin') -File |
    Sort-Object Name | ForEach-Object { $binFiles[$_.Name] = FileEntry $_.FullName }

$manifest = [ordered]@{
    package             = 'qwt-improved'
    package_kind        = 'overlay'
    package_version     = $version
    description         = 'Overlay updater: replaces the Qubes Windows Tools GUI agent only. Does not install or modify QWT itself or the Xen PV drivers.'
    targets_qwt_version = $baseQwt
    built_utc           = (Get-Date).ToUniversalTime().ToString('o')
    source = [ordered]@{
        driver_repo_commit = $repoSha
        agent_commit       = $agentSha
        agent_describe     = $agentDesc
        agent_upstream     = 'https://github.com/QubesOS/qubes-gui-agent-windows'
    }
    ci = [ordered]@{
        workflow   = $env:GITHUB_WORKFLOW
        run_id     = $env:GITHUB_RUN_ID
        run_number = $env:GITHUB_RUN_NUMBER
        repository = $env:GITHUB_REPOSITORY
        ref        = $env:GITHUB_REF
        sha        = $env:GITHUB_SHA
    }
    dependency_refs = $depRefs
    installs        = @('bin/gui-agent.exe')
    installs_optional = @('bin/gui-watchdog.exe')
    never_installs  = @('symbols/', 'tools/', 'optional/idd-driver/')
    idd_driver_included = $driverIncluded
    binaries        = $binFiles
}
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutDir 'MANIFEST.json') -Encoding UTF8

# ---------------------------------------------------------------- SHA256SUMS
$outFull = (Resolve-Path -LiteralPath $OutDir).Path
$sums = Get-ChildItem -LiteralPath $outFull -Recurse -File |
    Where-Object { $_.Name -ne 'SHA256SUMS.txt' } |
    Sort-Object FullName |
    ForEach-Object {
        $rel = $_.FullName.Substring($outFull.Length + 1) -replace '\\', '/'
        '{0}  {1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $rel
    }
$sums | Set-Content -LiteralPath (Join-Path $OutDir 'SHA256SUMS.txt') -Encoding ASCII

Write-Host "Staged $version in $outFull"
Get-ChildItem -LiteralPath $outFull -Recurse -File |
    ForEach-Object { $_.FullName.Substring($outFull.Length + 1) } | Sort-Object
