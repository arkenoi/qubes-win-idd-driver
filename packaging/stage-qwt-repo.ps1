# stage-qwt-repo.ps1 — build the QUBES_REPO tree the upstream WiX sources expect.
#
# The installer's .wxs files reference every payload file as
#   Source="$(env.QUBES_REPO)\<component>\bin\<file>"
# plus one Binary per component:
#   SourceFile="$(env.QUBES_REPO)\<component>\sign.crt"
# This script satisfies every such reference from three inputs:
#   - OUR gui-agent binaries (component gui-agent-windows) — built by this workflow,
#   - the admin-extracted stock QWT 4.2.2 MSI image — everything else, ITL signatures kept,
#   - certs: our signing cert for gui-agent-windows, the vendored ITL certs for the rest.
# It fails loudly on anything missing or ambiguous; a staging that cannot fail is worthless.

param(
    [Parameter(Mandatory)][string]$InstallerRepo,  # checkout of qubes-installer-qubes-os-windows-tools
    [Parameter(Mandatory)][string]$AdminImage,     # msiexec /a TARGETDIR of the stock installer.msi
    [Parameter(Mandatory)][string]$AgentBins,      # dir with OUR gui-agent.exe + gui-watchdog.exe (signed)
    [Parameter(Mandatory)][string]$OurCert,        # DER cert our binaries are signed with
    [Parameter(Mandatory)][string]$VendorCerts,    # dir with the six vendored SigningCert*.cer
    [Parameter(Mandatory)][string]$OutRepo         # QUBES_REPO to create
)
$ErrorActionPreference = 'Stop'

# --- 1. the required file set, parsed from the .wxs sources (never hand-maintained) ------
$wxs = Get-ChildItem "$InstallerRepo\vs2022\installer\*.wxs"
$refs = $wxs | Select-String -Pattern 'Source="\$\(env\.QUBES_REPO\)\\([^"]+)"' -AllMatches |
    ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
if ($refs.Count -lt 60) { throw "only $($refs.Count) QUBES_REPO refs parsed from wxs — parser broken?" }
Write-Host "wxs reference $($refs.Count) QUBES_REPO files"

# --- 2. index the admin image by basename ------------------------------------------------
$index = @{}
Get-ChildItem $AdminImage -Recurse -File | ForEach-Object {
    if (-not $index.ContainsKey($_.Name)) { $index[$_.Name] = @() }
    $index[$_.Name] += $_.FullName
}

$fromOurs = 0; $fromStock = 0
foreach ($rel in $refs) {
    $comp = ($rel -split '\\')[0]
    $leaf = Split-Path $rel -Leaf
    $dest = Join-Path $OutRepo $rel
    New-Item -ItemType Directory -Force (Split-Path $dest -Parent) | Out-Null

    if ($comp -eq 'gui-agent-windows') {
        $src = Join-Path $AgentBins $leaf
        if (-not (Test-Path $src)) { throw "our agent binary missing: $src" }
        Copy-Item $src $dest -Force
        $fromOurs++
        continue
    }

    $hits = @($index[$leaf])
    if (-not $hits -or $hits.Count -eq 0) { throw "not in admin image: $leaf (for $rel)" }
    if ($hits.Count -gt 1) {
        $hashes = $hits | ForEach-Object { (Get-FileHash $_ -Algorithm SHA256).Hash } | Sort-Object -Unique
        if ($hashes.Count -gt 1) { throw "ambiguous basename with differing content: $leaf`n$($hits -join "`n")" }
    }
    Copy-Item $hits[0] $dest -Force
    $fromStock++
}
Write-Host "staged: $fromOurs ours (gui-agent-windows), $fromStock from stock MSI image"

# --- 3. per-component sign.crt ------------------------------------------------------------
$certMap = @{
    'vmm-xen-windows-pvdrivers' = 'SigningCertDrivers.cer'
    'core-vchan-xen'            = 'SigningCertVchan.cer'
    'windows-utils'             = 'SigningCertUtils.cer'
    'core-qubesdb'              = 'SigningCertDb.cer'
    'core-agent-windows'        = 'SigningCertAgent.cer'
}
foreach ($comp in $certMap.Keys) {
    $src = Join-Path $VendorCerts $certMap[$comp]
    if (-not (Test-Path $src)) { throw "vendored cert missing: $src" }
    New-Item -ItemType Directory -Force (Join-Path $OutRepo $comp) | Out-Null
    Copy-Item $src (Join-Path $OutRepo "$comp\sign.crt") -Force
}
if (-not (Test-Path $OurCert)) { throw "our cert missing: $OurCert" }
New-Item -ItemType Directory -Force (Join-Path $OutRepo 'gui-agent-windows') | Out-Null
Copy-Item $OurCert (Join-Path $OutRepo 'gui-agent-windows\sign.crt') -Force

# --- 4. sanity: our agent must differ from the stock one ----------------------------------
$stockAgent = @($index['gui-agent.exe'])
if ($stockAgent -and $stockAgent.Count -ge 1) {
    $stockHash = (Get-FileHash $stockAgent[0] -Algorithm SHA256).Hash
    $oursHash  = (Get-FileHash (Join-Path $OutRepo 'gui-agent-windows\bin\gui-agent.exe') -Algorithm SHA256).Hash
    if ($stockHash -eq $oursHash) { throw "staged gui-agent.exe is byte-identical to stock — our build did not land" }
    Write-Host "gui-agent.exe: ours $($oursHash.Substring(0,16))… != stock $($stockHash.Substring(0,16))… (good)"
} else {
    Write-Warning 'stock gui-agent.exe not found in admin image — differ-check skipped'
}

# --- 5. verify every wxs reference now resolves --------------------------------------------
$missing = @()
foreach ($rel in $refs) { if (-not (Test-Path (Join-Path $OutRepo $rel))) { $missing += $rel } }
foreach ($comp in @($certMap.Keys) + 'gui-agent-windows') {
    if (-not (Test-Path (Join-Path $OutRepo "$comp\sign.crt"))) { $missing += "$comp\sign.crt" }
}
if ($missing.Count) { throw "staging incomplete:`n$($missing -join "`n")" }
Write-Host "QUBES_REPO complete at $OutRepo"
