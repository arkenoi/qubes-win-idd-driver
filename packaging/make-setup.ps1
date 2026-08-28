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
    [string]$PvArtifact,          # xenvif build (PV network fix) + its signer cert
    [Parameter(Mandatory = $true)][string]$MsiArtifact,
    [string]$IddArtifact,
    # Compiled tools\qwt-bootstrap\qwt-bootstrap.exe, staged at the package root as
    # qubes-tools-<version>.exe - see the STOCK-SHAPE COMPATIBILITY block below.
    [string]$BootstrapExe,
    [string]$QubesdbReadExe,       # tools\qubesdb-read.exe (guest-side reliable qubesdb CLI reader)
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
$baseQwt   = '4.2.2'   # upstream QWT release these sources were rebuilt from (compat field)
# SINGLE SOURCE OF TRUTH for the deliverable version: agent/version - the SAME file qwt-full.yml
# reads (line ~311) to stamp the MSI ProductVersion. Reading it here instead of a second hardcoded
# literal is what stops package_version and the MSI's ProductVersion from drifting apart - the very
# split that let a "v4.3.1" release ship a payload still stamped 4.3.0, so it could never upgrade a
# 4.3.0 guest. One file drives both; bump it every release. Windows Installer only compares the
# first THREE fields, so the release counter is the THIRD field: 4.3.0 -> 4.3.1 -> 4.3.2 ...
$ngVersionFile = Join-Path $RepoRoot 'agent/version'
if (-not (Test-Path -LiteralPath $ngVersionFile)) { throw "agent/version not found at $ngVersionFile - cannot determine the deliverable version" }
$ngVersion = (Get-Content -LiteralPath $ngVersionFile -Raw).Trim()
if ($ngVersion -notmatch '^\d+\.\d+\.\d+$') { throw "agent/version must be MAJOR.MINOR.PATCH (3 fields, MSI-comparable); got '$ngVersion'" }
$shortAgent = if ($agentSha -and $agentSha -ne 'unknown') { $agentSha.Substring(0, 12) } else { 'unknown' }
$version    = "$ngVersion+agent.$shortAgent"

# --------------------------------------------------------------------------------- stage
if (Test-Path -LiteralPath $OutDir) { Remove-Item -LiteralPath $OutDir -Recurse -Force }
foreach ($d in 'msi', 'certs', 'idd-driver', 'pv-drivers', 'reference', 'tools') {
    New-Item -ItemType Directory -Force -Path (Join-Path $OutDir $d) | Out-Null
}
# Diagnostic tools shipped as C# source (compile on-guest with the in-box csc - no binary to
# trust, no build step). winenum: top-level HWND dumper for the Win11 companion-window bugs.
Copy-Item (Need (Join-Path $RepoRoot 'tools\winenum.cs') 'winenum diagnostic source') (Join-Path $OutDir 'tools') -Force
# qubesdb-read.exe: the reliable guest-side qubesdb value reader (stock qubesdb-cmd mis-parses
# '/'-prefixed keys). Built by the workflow and passed in via -QubesdbReadExe; staged into tools\.
if ($QubesdbReadExe -and (Test-Path -LiteralPath $QubesdbReadExe)) {
    Copy-Item (Resolve-Path -LiteralPath $QubesdbReadExe).Path (Join-Path $OutDir 'tools\qubesdb-read.exe') -Force
    Write-Host 'staged tools\qubesdb-read.exe'
} else {
    Write-Warning 'qubesdb-read.exe not provided (-QubesdbReadExe) - guest CLI qubesdb reader will be absent'
}

# --- scripts + doc ---------------------------------------------------------------------
foreach ($f in 'install.cmd', 'Install-QwtImproved.ps1', 'README.txt') {
    Copy-Item (Join-Path $setupSrc $f) $OutDir -Force
}
# App HW-accel pre-tweak, run by stage 2 unless /noapptweaks. Single source of truth is
# guest/ (the same script the dev harness uses); staged here so Test-Payload covers it.
Copy-Item (Need (Join-Path $RepoRoot 'guest\disable-hw-accel.ps1') 'app hw-accel pre-tweak script') $OutDir -Force
# Consumer-nag silencer: OneDrive's "set up OneDrive" reminder pops over the seamless desktop
# and on an offline qube can never succeed at anything. Same switch as the hw-accel tweak.
Copy-Item (Need (Join-Path $RepoRoot 'guest\quiet-desktop.ps1') 'consumer-nag silencer') $OutDir -Force
# The guest must never take the input desktop away from dom0: a Windows lock screen is a
# secure-desktop surface the agent (correctly) refuses to map, so an idle lock makes the qube
# look frozen - and dom0's own screen lock is what actually protects the machine. This script
# existed since 6a447cd but was only ever run on test rigs; shipping it makes the shipped
# guests behave the way the project has always claimed they do.
Copy-Item (Need (Join-Path $RepoRoot 'guest\disable-session-lock.ps1') 'session-lock preventer') $OutDir -Force
# Autologon arming. Without it a guest whose account has a password comes back at the sign-in
# screen: no qrexec session for dom0 to use, and in seamless mode nothing displayed at all.
# Validates the credentials before writing anything and stores the password as an LSA secret.
Copy-Item (Need (Join-Path $RepoRoot 'guest\set-autologon.ps1') 'autologon arming script') $OutDir -Force
# IDD-only activator, run by `install.cmd /iddonly` to add/activate the IddCx driver on a guest
# that already has QWT (no MSI, no version/PV gate). Uses idd-driver/ staged below.
Copy-Item (Need (Join-Path $RepoRoot 'guest\activate-idd.ps1') 'IDD-only activator') $OutDir -Force
# The reverse, run by `install.cmd /iddoff`: back to the emulated VGA. This is the RECOVERY path
# for a guest whose display broke after activation, so it must be on the medium even though a
# normal install never calls it - a user who needs it cannot download a newer package from a
# qube with no display.
Copy-Item (Need (Join-Path $RepoRoot 'guest\deactivate-idd.ps1') 'IDD deactivator/recovery') $OutDir -Force
# Re-arms the inbox ATA/AHCI drivers as boot-start before the MSI swaps the PV disk driver.
# The upgrade moves the boot disk off the PV path for one boot; without a boot-start inbox
# driver that boot is 0x7B (forum 42717 post 27).
Copy-Item (Need (Join-Path $RepoRoot 'guest\rearm-inbox-disk-controllers.ps1') 'inbox storage re-arm') $OutDir -Force
# --- STOCK-SHAPE COMPATIBILITY -----------------------------------------------------------
# Everything that installs Qubes Windows Tools automatically looks for the shape the vendor
# has always shipped: ONE installer at the root of the ISO matching `qubes-tools-*.exe`, run
# with /passive. qvm-create-windows-qube's tools/auto-qwt/install-qwt.bat is exactly that
# glob. Against our installer TREE it matches nothing, raises no error, and the qube finishes
# provisioning with no tools installed at all (forum 42717 post 27).
# So ship a file with that name whose only job is to start install.cmd. Patching anybody
# else's checkout then stops being necessary for the common case.
if ($BootstrapExe -and (Test-Path -LiteralPath $BootstrapExe)) {
    Copy-Item (Resolve-Path -LiteralPath $BootstrapExe).Path (Join-Path $OutDir "qubes-tools-$ngVersion.exe") -Force
    Write-Host "stock-shape entry point: qubes-tools-$ngVersion.exe"
} else {
    # Not fatal - the package installs fine by hand without it - but it silently removes the
    # compatibility this block exists for, so say so at build time rather than in a bug report.
    Write-Warning 'no qwt-bootstrap.exe supplied: this package will NOT be found by qvm-create-windows-qube (its glob wants qubes-tools-*.exe at the root)'
}

# Windows Update agent, deployed by `install.cmd /updatesonly`: the deploy script compiles the
# relay (in-box csc, like winenum.cs), places the agent, and registers the scheduled scan that
# reports update availability to dom0. All three staged from guest/ (single source of truth).
# vmupdate-shim.ps1 + VMExec.ps1 + qubes-posix-cat.cs are what make dom0's STOCK qubes-vm-update
# (and therefore the Qubes Update GUI) able to drive this guest: dom0 injects a Python agent and
# runs it, which Windows cannot do, so we answer the same command shapes and run our updater.
foreach ($u in 'install-updater-agent.ps1', 'qubes-windows-update.ps1', 'qubes-updates-relay.cs', 'wu-update.ps1',
               'vmupdate-shim.ps1', 'VMExec.ps1', 'qubes-posix-cat.cs', 'ensure-autologon.ps1') {
    Copy-Item (Need (Join-Path $RepoRoot "guest\$u") "updater agent payload ($u)") $OutDir -Force
}

# Netvm-free PV NIC priming: the installer (Install-QwtImproved.ps1) seeds this on TEMPLATES only
# (default ON), reading the qube class LIVE from qubesdb. So pvnic-selfprime.ps1 must be on the
# medium. qubesdb-read.ps1 is the canonical reliable-read helper (a guest diagnostic; the
# installer and updater carry inline mirrors of it). health-check.ps1 is the guest self-check.
foreach ($g in 'pvnic-selfprime.ps1', 'qubesdb-read.ps1', 'health-check.ps1') {
    Copy-Item (Need (Join-Path $RepoRoot "guest\$g") "guest payload ($g)") $OutDir -Force
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

# --- PV network fix (xenvif) ---------------------------------------------------------
# SHIPPED BY DEFAULT. QWT 4.2.2's xenvif tops out at VIF REV_09000004 while its own
# xennet requires REV_09000005, so the NET child never binds and the guest runs on the
# emulated Realtek. Built from xenbits master (rev 5, via 4608bc1 "Use UNPLUG v3").
if ($PvArtifact -and (Test-Path $PvArtifact)) {
    $pvWanted = @(Get-ChildItem $PvArtifact -Recurse -Include xenvif.sys,xenvif.inf,xenvif.cat,xenvif-signer.cer)
    foreach ($f in 'xenvif.sys','xenvif.inf','xenvif.cat','xenvif-signer.cer') {
        if (-not ($pvWanted.Name -contains $f)) {
            throw "PV artifact is missing $f - the installer would leave PV networking on the emulated NIC"
        }
    }
    $pvWanted | ForEach-Object { Copy-Item $_.FullName (Join-Path $OutDir 'pv-drivers') -Force }
    Write-Host "pv-drivers: $($pvWanted.Name -join ', ')"
} else {
    Write-Warning 'no PV artifact supplied; pv-drivers/ empty and PV networking will stay on the emulated NIC'
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
    description     = 'QWT-NG 4.3 full install for a clean Windows guest: the upstream QWT 4.2.2 WiX MSI rebuilt from source with our gui-agent, plus certs, VC++ runtime and a two-stage install script. Not an overlay.'
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
                           'gui-agent registry defaults: SeamlessMode=1, DisableCursor=1, LogDir',
                           'Windows Update agent (unless /noupdates): reports availability via qubes.NotifyUpdates, answers dom0 qubes-vm-update so the Qubes Update GUI can drive the qube, and sets NoAutoUpdate=1 - dom0 owns installs')
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
