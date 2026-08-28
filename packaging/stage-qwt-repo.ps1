# stage-qwt-repo.ps1 — build the QUBES_REPO tree the upstream WiX sources expect.
#
# The installer's .wxs files reference every payload file as
#   Source="$(env.QUBES_REPO)\<component>\bin\<file>"
# plus one Binary per component:
#   SourceFile="$(env.QUBES_REPO)\<component>\sign.crt"
# This script satisfies every such reference from a SUBSTITUTION TABLE mapping refs to the
# things this workflow builds, with the admin-extracted stock QWT 4.2.2 MSI image as the
# deliberate remainder (kernel driver packages, wave-2/3 exes — ITL signatures kept).
#
# THE RULE THAT MATTERS: a ref the table claims must come from OUR sources THROWS when the
# source is missing. It never falls back to stock. Every post-install overlay in this repo
# (the rpc sweep, the bin\ *.qwt-stock dance) exists only because a stock byte shipped where
# ours should have; a staging that quietly re-ships stock re-creates that entire bug class
# with CI green (the 2026-08-25 rpc incident, the qrexec-wrapper months-of-stock incident).
# It fails loudly on anything missing or ambiguous; a staging that cannot fail is worthless.

param(
    [Parameter(Mandatory)][string]$InstallerRepo,  # checkout of qubes-installer-qubes-os-windows-tools
    [Parameter(Mandatory)][string]$AdminImage,     # msiexec /a TARGETDIR of the stock installer.msi
    [Parameter(Mandatory)][string]$AgentBins,      # dir with OUR gui-agent.exe + gui-watchdog.exe (signed)
    [Parameter(Mandatory)][string]$CoreAgentBins,  # dir with OUR fork-built, signed qrexec-wrapper.exe
                                                   # (carries the drain-race fix; agent/client-vm stay
                                                   # stock by recorded policy — ours-wins.psd1 Binaries)
    [Parameter(Mandatory)][string]$RpcSources,     # core-agent/src/qubes-rpc-services checkout: the
                                                   # qubes.* service defs + handler scripts (plain text,
                                                   # no build step)
    [Parameter(Mandatory)][string]$VMExecSource,   # guest/VMExec.ps1 — the MAINTAINED VMExec handler.
                                                   # The $RpcSources copy is a guard-enforced DeadEnd
                                                   # (ours-wins.psd1): staging it would regress guests
                                                   # to the stock handler. Single source of truth.
    [Parameter(Mandatory)][string]$DepsBins,       # dir with OUR built+signed user-mode dep DLLs:
                                                   # windows-utils.dll, libvchan.dll, libxenvchan.dll,
                                                   # qubesdb-client.dll (qwt-full builds these already;
                                                   # this param is what stops them being discarded)
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

# --- 3. the substitution table -----------------------------------------------------------
# Order matters: FIRST match wins, so the VMExec.ps1 special case must precede the general
# rpc-script rule (VMExec.ps1 also matches *.ps1). A ref matching no rule ships from the
# stock image — that set is now only the kernel driver packages, catalog-covered service
# exes (xenagent/xenbus_monitor: byte swap invalidates the signed .cat), and the wave-2/3
# binaries with recorded holds (see the migration table / ours-wins.psd1).
#
# Min = how many refs the rule MUST satisfy, counted against the pinned installer sources
# (v4.2.2-1). Fewer means the wxs stopped referencing something we ship — our file would
# silently ship NOWHERE, the same incident class as a stock fallback, so it throws too.
$subst = @(
    @{  Name   = 'gui-agent-windows'
        # Our gui-agent fork: the original model this table replicates.
        Match  = { param($comp, $leaf) $comp -eq 'gui-agent-windows' }
        Source = { param($leaf) Join-Path $AgentBins $leaf }
        Binary = $true
        Min    = 2   # gui-agent.exe, gui-watchdog.exe
    }
    @{  Name   = 'core-agent qrexec-wrapper'
        # Fork-built wrapper (drain-race fix ac33bc9/e5e94b8). ONLY the wrapper:
        # qrexec-agent.exe / qrexec-client-vm.exe are built but withheld by recorded
        # policy — unmodified source means no benefit, and qrexec-agent is the service
        # dom0 talks to. They fall through to stock ON PURPOSE; ours-wins.psd1
        # CompiledSources fails the build the moment either source diverges.
        Match  = { param($comp, $leaf) $comp -eq 'core-agent-windows' -and $leaf -eq 'qrexec-wrapper.exe' }
        Source = { param($leaf) Join-Path $CoreAgentBins $leaf }
        Binary = $true
        Min    = 1
    }
    @{  Name   = 'VMExec.ps1 (maintained, guest/)'
        # MUST precede the rpc rule below. guest/VMExec.ps1 is the maintained handler
        # (exit-code propagation, UTF-8 decode, vmupdate-shim routing, audit log); the
        # $RpcSources copy is stock 4.2.2 kept for upstream diffing (DeadEnd). Sourcing
        # from $RpcSources here would ship the STOCK handler with CI green.
        Match  = { param($comp, $leaf) $comp -eq 'core-agent-windows' -and $leaf -eq 'VMExec.ps1' }
        Source = { param($leaf) $VMExecSource }
        Binary = $false
        Min    = 1
    }
    @{  Name   = 'rpc defs + handler scripts'
        # Plain text from the core-agent checkout — identical bytes to what the A1/A2
        # overlays already place on every guest, now delivered in the MSI itself so those
        # overlays can die. qubes.GetAppMenus/qubes.GetAppmenus differ only by case and
        # are byte-identical (verified 2026-08-28), so a case-insensitive runner
        # materializing one file satisfies the wxs's qubes.GetAppMenus ref either way.
        # A new .ps1/.bat/qubes.* appearing in the wxs that is NOT in $RpcSources throws:
        # extend the checkout (or this table) deliberately, never fall back to stock.
        Match  = { param($comp, $leaf) $comp -eq 'core-agent-windows' -and
                   ($leaf -like 'qubes.*' -or $leaf -like '*.ps1' -or $leaf -like '*.bat') }
        Source = { param($leaf) Join-Path $RpcSources $leaf }
        Binary = $false
        Min    = 20  # 14 qubes.* defs + 6 handler scripts (VMExec.ps1 matched above)
    }
    @{  Name   = 'user-mode dep DLLs'
        # The DLLs qwt-full already builds and used to DISCARD (only .libs were staged).
        # Exact leaf list — matching wider would hijack xencontrol.dll (WDK build unproven,
        # wave 3) or xenagent.dll/xenbus_monitor.dll: we do not BUILD those, so there is
        # nothing of ours to put in their place. Note the older rationale here - "catalog-
        # covered, permanently stock" - was too strong and it hid a real fix for a whole
        # afternoon: the catalog is signed with OUR throwaway cert on a testsigning guest,
        # and patch-xenbus-inf.ps1 now edits xenbus.inf and regenerates xenbus.cat as a
        # matter of course. Catalog coverage is a step to redo, not a wall.
        # qubesdb-client.dll ships only under the settled version pin (QUBESDB_REF vs the
        # 4.2.2 daemon — workflow-side decision); this script's job is just fail-loud
        # sourcing of whatever the workflow signed into $DepsBins.
        Match  = { param($comp, $leaf) $leaf -in @('windows-utils.dll', 'libvchan.dll',
                                                   'libxenvchan.dll', 'qubesdb-client.dll') }
        Source = { param($leaf) Join-Path $DepsBins $leaf }
        Binary = $true
        Min    = 4
    }
)

# --- 4. stage every ref: table first, stock only for refs no rule claims ------------------
$counts = [ordered]@{}
foreach ($r in $subst) { $counts[$r.Name] = 0 }
$fromStock = 0
$oursBinaries = @()   # rel paths of substituted BINARIES, for the differ-from-stock tripwire

foreach ($rel in $refs) {
    $comp = ($rel -split '\\')[0]
    $leaf = Split-Path $rel -Leaf
    $dest = Join-Path $OutRepo $rel
    New-Item -ItemType Directory -Force (Split-Path $dest -Parent) | Out-Null

    $rule = $null
    foreach ($r in $subst) { if (& $r.Match $comp $leaf) { $rule = $r; break } }

    if ($rule) {
        $src = & $rule.Source $leaf
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
            throw ("substitution '$($rule.Name)' claims $rel but its source is missing: $src`n" +
                   "REFUSING to fall back to stock — a silent stock fallback with CI green is the " +
                   "exact failure this table exists to end. Fix the build step that produces the " +
                   "source, or remove the claim from the table deliberately.")
        }
        Copy-Item -LiteralPath $src $dest -Force
        $counts[$rule.Name]++
        if ($rule.Binary) { $oursBinaries += $rel }
        continue
    }

    # No rule claims it -> stock, by basename. Legitimate ONLY for the deliberate remainder;
    # anything we start building must gain a table entry, or it ships stock forever, silently.
    $hits = @($index[$leaf])
    if (-not $hits -or $hits.Count -eq 0) { throw "not in admin image: $leaf (for $rel)" }
    if ($hits.Count -gt 1) {
        $hashes = $hits | ForEach-Object { (Get-FileHash $_ -Algorithm SHA256).Hash } | Sort-Object -Unique
        if ($hashes.Count -gt 1) { throw "ambiguous basename with differing content: $leaf`n$($hits -join "`n")" }
    }
    Copy-Item $hits[0] $dest -Force
    $fromStock++
}

# A rule that fired fewer times than its floor means a file we maintain no longer ships —
# same severity as a stock fallback (e.g. an installer-pin bump dropping qrexec-wrapper.exe
# from the wxs would otherwise pass, and the drain-race fix would ship nowhere again).
foreach ($r in $subst) {
    if ($counts[$r.Name] -lt $r.Min) {
        throw "substitution '$($r.Name)' matched only $($counts[$r.Name]) wxs refs (expected >= $($r.Min)) — a file we maintain stopped shipping; did the installer pin change?"
    }
}

$fromOurs = ($counts.Values | Measure-Object -Sum).Sum
Write-Host "staged: $fromOurs ours / $fromStock stock (of $($refs.Count) wxs refs)"
foreach ($r in $subst) { Write-Host ("  ours: {0,2}  {1}" -f $counts[$r.Name], $r.Name) }

# --- 5. per-component sign.crt ------------------------------------------------------------
# Unchanged by the substitution work: mixed components keep ITL's cert. Our cert installs
# via gui-agent-windows\sign.crt — exactly how the MSI's our-signed gui-agent works today —
# and the guest trusts it from firstboot, so our-signed files inside ITL-cert components
# (qrexec-wrapper, the dep DLLs) verify fine at runtime.
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

# --- 6. sanity: every substituted BINARY must differ from its stock namesake --------------
# Byte-equal = our build did not land (a copy step staged the wrong dir, an artifact was
# stale). Generalized from the old gui-agent.exe-only check to everything the table staged.
# Scripts are exempt ON PURPOSE: an unmodified handler script is legitimately byte-identical
# to stock (modulo line endings), so equality proves nothing there — for binaries even an
# unmodified source produces different bytes (link timestamps, our signature).
foreach ($rel in $oursBinaries) {
    $leaf  = Split-Path $rel -Leaf
    $stock = @($index[$leaf])
    if (-not $stock -or $stock.Count -eq 0) {
        # No stock namesake: nothing to prove different against. Fine for a fork-new
        # binary, but say so — silence here would hide an admin-image extraction gap.
        Write-Warning "no stock counterpart for substituted binary $leaf — differ-check skipped"
        continue
    }
    $stockHash = (Get-FileHash $stock[0] -Algorithm SHA256).Hash
    $oursHash  = (Get-FileHash (Join-Path $OutRepo $rel) -Algorithm SHA256).Hash
    if ($stockHash -eq $oursHash) {
        throw "staged $rel is byte-identical to stock — our build did not land"
    }
    Write-Host "$leaf`: ours $($oursHash.Substring(0,16))… != stock $($stockHash.Substring(0,16))… (good)"
}

# --- 7. verify every wxs reference now resolves --------------------------------------------
$missing = @()
foreach ($rel in $refs) { if (-not (Test-Path (Join-Path $OutRepo $rel))) { $missing += $rel } }
foreach ($comp in @($certMap.Keys) + 'gui-agent-windows') {
    if (-not (Test-Path (Join-Path $OutRepo "$comp\sign.crt"))) { $missing += "$comp\sign.crt" }
}
if ($missing.Count) { throw "staging incomplete:`n$($missing -join "`n")" }
Write-Host "QUBES_REPO complete at $OutRepo"
