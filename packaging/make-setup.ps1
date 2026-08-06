<#
.SYNOPSIS
    Assemble the `qwt-improved-setup` artifact: a self-contained, fully installable
    Qubes Windows Tools package for a CLEAN Windows guest.

.DESCRIPTION
    Unlike packaging/make-package.ps1 (which builds the OVERLAY updater that needs a
    working QWT already present), this assembles everything a fresh guest needs:

        installer.msi       the real QWT 4.2.2 MSI rebuilt from upstream WiX sources with
                            OUR gui-agent, produced by the `qwt-full` workflow
        vc_redist.x64.exe   the Burn bundle's prerequisite package
        certs/              the six ITL component certs + our CI test-signing cert
        idd-driver/         the IddCx driver + devcon.exe (optional payload;
                            install.cmd /idd installs AND ACTIVATES it)
        install.cmd         entry point
        Install-QwtImproved.ps1
        README.txt
        MANIFEST.json       provenance + per-file sha256
        SHA256SUMS.txt      what the installer verifies before touching the machine

    Fails loudly on any missing input. A packaging step that silently drops a payload
    produces an artifact whose install fails on the user's machine instead of in CI.

.PARAMETER MsiArtifact   Directory the `qwt-full-package` artifact was downloaded into.
.PARAMETER IddArtifact   Directory the IddCx driver artifact was downloaded into (optional).
.PARAMETER VcRedist      Path to vc_redist.x64.exe.
.PARAMETER RepoRoot      Repository root (default: current directory).
.PARAMETER OutDir        Staging directory to create (default: qwt-improved-setup).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$MsiArtifact,
    [string]$IddArtifact,
    [Parameter(Mandatory = $true)][string]$VcRedist,
    [string]$RepoRoot = '.',
    [string]$OutDir = 'qwt-improved-setup'
)

$ErrorActionPreference = 'Stop'

function Need {
    param([string]$Path, [string]$What)
    if (-not (Test-Path -LiteralPath $Path)) { throw "$What not found: $Path" }
    return (Resolve-Path -LiteralPath $Path).Path
}

$RepoRoot    = Need $RepoRoot    'repository root'
$MsiArtifact = Need $MsiArtifact 'qwt-full artifact directory'
$VcRedist    = Need $VcRedist    'vc_redist.x64.exe'
$setupSrc    = Need (Join-Path $RepoRoot 'packaging\setup') 'packaging/setup directory'
$vendorCerts = Need (Join-Path $RepoRoot 'vendor\qwt-4.2.2\certs') 'vendored ITL certs'

# ------------------------------------------------------------------ provenance from qwt-full
# The qwt-full job already recorded which commits produced the MSI. Re-deriving it here
# could disagree with what is actually inside installer.msi; reading it cannot.
$upstreamManifest = Join-Path $MsiArtifact 'MANIFEST.json'
if (-not (Test-Path -LiteralPath $upstreamManifest)) {
    throw "qwt-full artifact has no MANIFEST.json - refusing to ship a package with unknown provenance"
}
$um = Get-Content -LiteralPath $upstreamManifest -Raw | ConvertFrom-Json
foreach ($f in 'repo_sha', 'agent_sha', 'installer_sha', 'stock_msi_sha256') {
    if ($um.PSObject.Properties.Name -notcontains $f) {
        throw "qwt-full MANIFEST.json is missing '$f'"
    }
}

function EnvOr {
    param([string]$Name, [string]$Fallback)
    $v = [Environment]::GetEnvironmentVariable($Name)
    if ($v) { return $v.Trim() }
    return $Fallback
}

$repoSha   = EnvOr 'QWT_REPO_SHA'  $um.repo_sha
$agentSha  = $um.agent_sha
$agentDesc = if ($um.PSObject.Properties.Name -contains 'agent_describe') { $um.agent_describe } else { $agentSha }
$baseQwt   = '4.2.2'
$shortAgent = if ($agentSha -and $agentSha -ne 'unknown') { $agentSha.Substring(0, 12) } else { 'unknown' }
$version    = "$baseQwt+agent.$shortAgent"

# --------------------------------------------------------------------------------- stage
if (Test-Path -LiteralPath $OutDir) { Remove-Item -LiteralPath $OutDir -Recurse -Force }
foreach ($d in 'msi', 'certs', 'idd-driver', 'reference') {
    New-Item -ItemType Directory -Force -Path (Join-Path $OutDir $d) | Out-Null
}

# --- scripts + doc ---------------------------------------------------------------------
foreach ($f in 'install.cmd', 'Install-QwtImproved.ps1', 'README.txt') {
    Copy-Item (Join-Path $setupSrc $f) $OutDir -Force
}

# --- the MSI ---------------------------------------------------------------------------
$msiSrc = Join-Path $MsiArtifact 'installer.msi'
if (-not (Test-Path -LiteralPath $msiSrc)) { throw "installer.msi missing from the qwt-full artifact ($MsiArtifact)" }
Copy-Item $msiSrc (Join-Path $OutDir 'msi') -Force
$msiHash = (Get-FileHash -LiteralPath (Join-Path $OutDir 'msi\installer.msi') -Algorithm SHA256).Hash.ToLowerInvariant()
# The MSI we ship must be the MSI the qwt-full manifest describes, or the provenance we
# print is provenance for a different file.
if ($um.files -and ($um.files.PSObject.Properties.Name -contains 'installer.msi')) {
    $claimed = ([string]$um.files.'installer.msi').ToLowerInvariant()
    if ($claimed -ne $msiHash) {
        throw "installer.msi sha256 $msiHash does not match the qwt-full manifest ($claimed)"
    }
    Write-Host "installer.msi sha256 $msiHash matches the qwt-full manifest"
} else {
    throw "qwt-full MANIFEST.json does not record installer.msi's sha256 - cannot corroborate the payload"
}

# --- VC++ runtime ----------------------------------------------------------------------
Copy-Item $VcRedist (Join-Path $OutDir 'msi\vc_redist.x64.exe') -Force

# --- certificates ----------------------------------------------------------------------
$itl = @(Get-ChildItem -LiteralPath $vendorCerts -Filter 'SigningCert*.cer')
if ($itl.Count -ne 6) { throw "expected 6 vendored ITL certs, found $($itl.Count)" }
$itl | ForEach-Object { Copy-Item $_.FullName (Join-Path $OutDir 'certs') -Force }

# Our throwaway CI signing cert: without it in Root/TrustedPublisher the guest will not
# load our test-signed gui-agent.exe. qwt-full exports it next to the binaries.
$ourCert = Join-Path $MsiArtifact 'sign.crt'
if (-not (Test-Path -LiteralPath $ourCert)) {
    throw "sign.crt missing from the qwt-full artifact - the guest could not trust our test-signed binaries"
}
Copy-Item $ourCert (Join-Path $OutDir 'certs\qwt-improved-testsign.cer') -Force

# --- reference binaries (never installed by the script; the MSI carries them) -----------
$refHashes = [ordered]@{}
foreach ($f in 'gui-agent.exe', 'gui-watchdog.exe') {
    $src = Join-Path $MsiArtifact $f
    if (-not (Test-Path -LiteralPath $src)) { throw "$f missing from the qwt-full artifact" }
    Copy-Item $src (Join-Path $OutDir 'reference') -Force
    $h = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash.ToLowerInvariant()
    # qwt-full recorded the hash of the binary it staged INTO the MSI. If the loose copy
    # beside it disagrees, the reference hash we publish - and that the guest installer
    # checks the installed agent against - would be for a different binary than the MSI
    # actually carries. That must fail here.
    $key = "agent-bins/$f"
    if ($um.files.PSObject.Properties.Name -contains $key) {
        $claimedBin = ([string]$um.files.$key).ToLowerInvariant()
        if ($claimedBin -ne $h) {
            throw "$f sha256 $h disagrees with the qwt-full manifest ($claimedBin)"
        }
    } else {
        throw "qwt-full MANIFEST.json does not record $key - cannot corroborate the agent binary"
    }
    $refHashes[$f] = $h
}
Set-Content -LiteralPath (Join-Path $OutDir 'reference\README.txt') -Encoding ASCII -Value @(
    'These are the exact gui-agent.exe / gui-watchdog.exe bytes embedded in ..\msi\installer.msi.',
    'The installer NEVER copies them anywhere - they are here so you can compare hashes offline,',
    'or hand-swap a binary while debugging. Installing QWT is what puts them on the system.'
)

# --- IddCx driver (optional) ------------------------------------------------------------
$iddIncluded = $false
$iddFiles = @()
if ($IddArtifact -and (Test-Path -LiteralPath $IddArtifact)) {
    $IddArtifact = (Resolve-Path -LiteralPath $IddArtifact).Path
    # Driver-package members plus devcon.exe, which the /idd activation path uses to
    # create the root-enumerated device (devcon install root\iddsampledriver). Console
    # probes from the build job are not part of an installable payload and must not end
    # up in the directory pnputil is pointed at.
    $wanted = @(Get-ChildItem -LiteralPath $IddArtifact -File |
                Where-Object { (@('.inf', '.cat', '.dll') -contains $_.Extension.ToLowerInvariant()) -or
                               ($_.Name -ieq 'devcon.exe') })
    $inf = @($wanted | Where-Object { $_.Extension.ToLowerInvariant() -eq '.inf' })
    if ($inf.Count -ne 1) { throw "expected exactly 1 .inf in the driver artifact, found $($inf.Count)" }
    if (-not @($wanted | Where-Object { $_.Name -ieq 'devcon.exe' })) {
        throw 'devcon.exe missing from the driver artifact - install.cmd /idd ACTIVATES the driver with it and would fail on the guest'
    }
    $wanted | ForEach-Object { Copy-Item $_.FullName (Join-Path $OutDir 'idd-driver') -Force }
    $iddFiles = @($wanted | ForEach-Object { $_.Name })
    $iddIncluded = $true
    Write-Host "idd-driver: $($iddFiles -join ', ')"
} else {
    Write-Warning 'no IddCx driver artifact supplied; idd-driver/ will carry a placeholder and /idd will refuse'
    Set-Content -LiteralPath (Join-Path $OutDir 'idd-driver\NOT-INCLUDED.txt') -Encoding ASCII `
        -Value 'The IddCx driver was not built for this package. install.cmd /idd will fail loudly.'
}

# ------------------------------------------------------------------------------ manifest
$outFull = (Resolve-Path -LiteralPath $OutDir).Path

function RelPath { param([string]$Full) return ($Full.Substring($outFull.Length + 1) -replace '\\', '/') }

$files = [ordered]@{}
Get-ChildItem -LiteralPath $outFull -Recurse -File | Sort-Object FullName | ForEach-Object {
    $files[(RelPath $_.FullName)] = [ordered]@{
        size    = $_.Length
        sha256  = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        version = $_.VersionInfo.FileVersion
    }
}

$manifest = [ordered]@{
    package         = 'qwt-improved-setup'
    package_kind    = 'full-installer'
    package_version = $version
    description     = 'Full Qubes Windows Tools 4.2.2 install for a clean Windows guest: the upstream WiX MSI rebuilt from source with our gui-agent, plus certs, VC++ runtime and a two-stage install script. Not an overlay.'
    targets_qwt_version = $baseQwt
    built_utc       = (Get-Date).ToUniversalTime().ToString('o')
    source = [ordered]@{
        driver_repo_commit         = $repoSha
        agent_commit               = $agentSha
        agent_describe             = $agentDesc
        agent_upstream             = 'https://github.com/QubesOS/qubes-gui-agent-windows'
        installer_upstream_commit  = $um.installer_sha
        installer_upstream         = 'https://github.com/QubesOS/qubes-installer-qubes-os-windows-tools'
        stock_msi_sha256           = $um.stock_msi_sha256
    }
    ci = [ordered]@{
        workflow    = $env:GITHUB_WORKFLOW
        run_id      = $env:GITHUB_RUN_ID
        run_number  = $env:GITHUB_RUN_NUMBER
        run_attempt = $env:GITHUB_RUN_ATTEMPT
        repository  = $env:GITHUB_REPOSITORY
        ref         = $env:GITHUB_REF
        sha         = $env:GITHUB_SHA
    }
    installs = [ordered]@{
        msi_features   = @('PvDriversCore', 'Core', 'Gui', 'PvDriversNetwork (unless /nonet)')
        also           = @('6 ITL signing certs + our test cert into Root and TrustedPublisher',
                           'VC++ 2015-2022 x64 runtime',
                           'bcdedit /set testsigning on',
                           'gui-agent registry defaults: SeamlessMode=1, DisableCursor=0, LogDir')
    }
    never_installs = @('reference/', 'PvDriversDisk', 'MoveUsers', 'Autologon',
                       'any WDDM/video driver (QWT 4.2.2 has none)',
                       'the dom0-side resize service',
                       'idd-driver/ unless install.cmd /idd is passed; with /idd the driver is installed AND ACTIVATED (the IDD becomes the display, the emulated VGA adapter is disabled)')
    known_issues = @('Attaching a netvm makes the guest unusable on Qubes 4.3: xenvif installs but never starts, ~2 vCPUs burn, qrexec stops answering. Not yet attributed to this package vs the upstream PV drivers. Use this build on an offline qube.')
    idd_driver_included = $iddIncluded
    idd_driver_files    = $iddFiles
    reference_binaries  = $refHashes
    files               = $files
}
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $OutDir 'MANIFEST.json') -Encoding UTF8

# --------------------------------------------------------------------------- SHA256SUMS
# Covers MANIFEST.json too, and is what Install-QwtImproved.ps1 verifies against.
$sums = Get-ChildItem -LiteralPath $outFull -Recurse -File |
    Where-Object { $_.Name -ne 'SHA256SUMS.txt' } |
    Sort-Object FullName |
    ForEach-Object { '{0}  {1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), (RelPath $_.FullName) }
$sums | Set-Content -LiteralPath (Join-Path $OutDir 'SHA256SUMS.txt') -Encoding ASCII

Write-Host "Staged $version in $outFull"
Get-ChildItem -LiteralPath $outFull -Recurse -File | ForEach-Object { RelPath $_.FullName } | Sort-Object
