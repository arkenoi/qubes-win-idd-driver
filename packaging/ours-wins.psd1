# ours-wins.psd1 - THE single list of files where THIS repo's copy must beat the stock
# QWT 4.2.2 image in the shipped package.
#
# Read by packaging/check-ours-wins.ps1, the CI guard release-package.yml runs on every
# package build. The guard FAILS the build when a file we maintain sources for would ship
# from the stock image, or not ship at all (the 2026-08-25 incident class: an edit to
# core-agent/src/qubes-rpc-services/*.ps1 reached no guest while CI stayed green, because
# the staging was a hardcoded 2-file list and everything else silently resolved to the
# stock MSI copy).
#
# TWO VERIFICATION ROOTS since stage-qwt-repo.ps1's substitution table started putting our
# bytes INSIDE the built installer.msi (wave 1 of the stock-elimination migration):
#   - a plain path resolves against -PackageRoot (the assembled qwt-improved-setup tree),
#     exactly as before. These entries verify the post-install OVERLAY channel (rpc/,
#     bin/, reference/), which keeps shipping - and being applied by the guest installer -
#     until wave 1 is e2e-proven (install -> reboot -> assert) and the overlays die.
#     Delete each payload-side entry together with its overlay, never before.
#   - a path prefixed 'msi-image/' resolves against the guard's SECOND root: the admin
#     extract (msiexec /a) of the BUILT qwt-improved-setup\msi\installer.msi. These
#     entries prove our bytes are inside the MSI that actually installs - stage-qwt-repo's
#     throw-on-missing guards the staging STEP, these guard the RESULT, end to end.
#   Image layout (read out of the MSI's Directory table 2026-08-28; the built MSI compiles
#   from the same pinned v4.2.2-1 wxs, so stock and built layouts are identical):
#     msi-image/PFiles64/Qubes Tools/{bin,qubes-rpc,qubes-rpc-services}/...
#     msi-image/System64/*.dll
#
# HOW TO ADD A FILE in the future:
#   - a new/changed rpc handler or qubes.* service definition in
#     core-agent/src/qubes-rpc-services: NO step needed - make-setup.ps1 sweeps that
#     directory into the payload, stage-qwt-repo.ps1's rpc rule stages it into the MSI,
#     and the Mirrors rules below verify both.
#   - a new one-off guest file maintained outside that tree: add a Files entry here AND
#     stage it in make-setup.ps1; the guard fails until both agree.
#   - a binary newly claimed by stage-qwt-repo.ps1's substitution table: add a Binaries
#     entry (Required=$true) at its msi-image/ path IN THE SAME CHANGE - a substitution
#     is not "shipped" until the guard can fail on its absence.
#   - a new fork-built binary staged into the payload bin\ overlay: add a Binaries entry
#     (the orphan check fails the build until every bin\ file is enumerated).
# The guard also fails on STALE entries (a KnownGaps entry that stopped matching, a listed
# source file that no longer exists), so this list cannot silently rot in either direction.

@{
    # ---------------------------------------------------------------------------- Mirrors
    # Tree rules mirroring the two staging sweeps: every top-level file of SourceDir
    # matching Include (minus Exclude) must exist in the package at PackageDir/<name>,
    # byte-identical to the repo copy. Each source tree appears TWICE - once for the
    # payload overlay (layout mirrors the guest install tree under
    # 'C:\Program Files\Qubes Tools'), once for the built MSI's admin image.
    Mirrors = @(
        @{
            # qubes.* qrexec service definitions -> payload overlay (A1/A2 channel;
            # dies with the overlays after wave-1 e2e proof)
            SourceDir  = 'core-agent/src/qubes-rpc-services'
            Include    = 'qubes.*'
            Exclude    = @()
            PackageDir = 'rpc/qubes-rpc'
        }
        @{
            # rpc handler scripts (.ps1/.bat) -> payload overlay
            # VMExec.ps1 is excluded ON PURPOSE: the maintained copy is guest/VMExec.ps1
            # (see Files + DeadEnds below); the core-agent copy is kept stock for
            # upstream diffing and must NOT ship.
            SourceDir  = 'core-agent/src/qubes-rpc-services'
            Include    = '*'
            Exclude    = @('qubes.*', 'VMExec.ps1')
            PackageDir = 'rpc/qubes-rpc-services'
        }
        @{
            # qubes.* service definitions INSIDE the built MSI (stage-qwt-repo.ps1's
            # 'rpc defs + handler scripts' rule; identical bytes to the overlay copies).
            # qubes.GetAppMenus/qubes.GetAppmenus differ only by case: a case-insensitive
            # CI checkout materializes one file, and the image lookup is case-insensitive
            # too, so either casing satisfies this rule.
            SourceDir  = 'core-agent/src/qubes-rpc-services'
            Include    = 'qubes.*'
            Exclude    = @()
            PackageDir = 'msi-image/PFiles64/Qubes Tools/qubes-rpc'
        }
        @{
            # rpc handler scripts INSIDE the built MSI. Same VMExec.ps1 exclusion as the
            # overlay rule: the MSI's VMExec.ps1 is sourced from guest/VMExec.ps1 by
            # stage-qwt-repo.ps1 and verified by the Files entry below.
            SourceDir  = 'core-agent/src/qubes-rpc-services'
            Include    = '*'
            Exclude    = @('qubes.*', 'VMExec.ps1')
            PackageDir = 'msi-image/PFiles64/Qubes Tools/qubes-rpc-services'
        }
    )

    # ------------------------------------------------------------------------------ Files
    # One-off "ours wins" files: Source (repo path) must be present in the package at
    # Package, byte-identical.
    Files = @(
        @{
            # The MAINTAINED VMExec handler (exit-code propagation, UTF-8 decode,
            # vmupdate-shim routing, audit log) - payload overlay copy, so the
            # guest gets it even under /noupdates.
            Source  = 'guest/VMExec.ps1'
            Package = 'rpc/qubes-rpc-services/VMExec.ps1'
        }
        @{
            # The same maintained VMExec handler INSIDE the built MSI (stage-qwt-repo.ps1
            # special-cases the wxs's VMExec.ps1 ref to guest/VMExec.ps1 - sourcing the
            # core-agent copy there would ship the STOCK handler with CI green).
            Source  = 'guest/VMExec.ps1'
            Package = 'msi-image/PFiles64/Qubes Tools/qubes-rpc-services/VMExec.ps1'
        }
    )

    # --------------------------------------------------------------------------- Binaries
    # Fork-built binaries that must NOT be byte-identical to the stock image copy
    # (byte-equal = our build did not land; the gui-agent.exe tripwire of
    # stage-qwt-repo.ps1, generalized). Stock = basename looked up in the extracted
    # stock admin image. Required=$false entries may be absent from the package, but
    # ONLY if a KnownGaps entry below documents the absence.
    #
    # msi-image/ entries = everything stage-qwt-repo.ps1's substitution table stages as a
    # BINARY. That table and this list must stay in lockstep: a substitution without an
    # entry here ships unverified, an entry without a substitution fails as missing.
    Binaries = @(
        # -- payload channels (die with their overlays after wave-1 e2e proof) ------------
        @{ Package = 'reference/gui-agent.exe';    Stock = 'gui-agent.exe';      Required = $true }
        @{ Package = 'reference/gui-watchdog.exe'; Stock = 'gui-watchdog.exe';   Required = $true }
        # The fork qrexec-wrapper via the bin\ overlay (A4). Kept while the overlay ships:
        # absence means the build silently fell back to stock - the exact failure that let
        # the drain-race fix miss every guest for a week.
        @{ Package = 'bin/qrexec-wrapper.exe';     Stock = 'qrexec-wrapper.exe'; Required = $true }
        # User-session HELPERS staged into bin\ by make-setup.ps1 (Install-QwtImproved's
        # bin-overlay installs them next to gui-agent.exe). NoStock: these do not exist in the
        # stock 4.2.2 image, so there is no differ-from-stock check - the entry exists so they
        # are NOT orphans and Required proves they shipped. Absence here is exactly the
        # 2026-09-04 gap that shipped the de-slice broker with no wgcbroker.exe on the guest.
        @{ Package = 'bin/wgcbroker.exe';          NoStock = $true;             Required = $true }
        @{ Package = 'bin/notifhost.exe';          NoStock = $true;             Required = $true }

        # -- inside the built MSI (stage-qwt-repo.ps1 substitution table) -----------------
        # Our gui-agent fork - the original substitution the table replicates.
        @{ Package = 'msi-image/PFiles64/Qubes Tools/bin/gui-agent.exe';      Stock = 'gui-agent.exe';      Required = $true }
        @{ Package = 'msi-image/PFiles64/Qubes Tools/bin/gui-watchdog.exe';   Stock = 'gui-watchdog.exe';   Required = $true }
        # Fork-built wrapper (drain-race fix), now delivered by the MSI itself.
        @{ Package = 'msi-image/PFiles64/Qubes Tools/bin/qrexec-wrapper.exe'; Stock = 'qrexec-wrapper.exe'; Required = $true }
        # The user-mode dep DLLs qwt-full builds and used to DISCARD (.libs staged, DLLs
        # dropped): now signed and staged into the MSI. NOT xencontrol.dll (WDK build
        # unproven, wave 3) and NEVER xenagent.dll/xenbus_monitor.dll (catalog-covered by
        # the signed xeniface/xenbus driver packages - permanently stock).
        @{ Package = 'msi-image/System64/windows-utils.dll';   Stock = 'windows-utils.dll';   Required = $true }
        @{ Package = 'msi-image/System64/libvchan.dll';        Stock = 'libvchan.dll';        Required = $true }
        @{ Package = 'msi-image/System64/libxenvchan.dll';     Stock = 'libxenvchan.dll';     Required = $true }
        # qubesdb-client.dll ships under the QUBESDB_REF version-pin decision (client
        # built from a newer tag than the stock 4.2.2 daemon it talks to - re-pin or
        # verify before relying on it); the entry only enforces that whatever the
        # workflow signed into deps-bins is what the MSI carries, never the stock copy.
        @{ Package = 'msi-image/System64/qubesdb-client.dll';  Stock = 'qubesdb-client.dll';  Required = $true }
        # qrexec-agent.exe / qrexec-client-vm.exe are deliberately NOT shipped. Their sources
        # are unmodified against the 4.2.2 base, so our build would be functionally identical -
        # no benefit - while qrexec-agent is the service dom0 talks to and a bad swap costs the
        # guest's manageability entirely. They are built (qrexec-agent.vcxproj also generates
        # qwt_version.h) and kept in the artifact for diagnostics, not staged into the MSI.
        # The moment either source diverges, CompiledSources fails the build until it ships.
    )

    # --------------------------------------------------------------------------- DeadEnds
    # Repo copies that must remain IDENTICAL to the stock image: they exist only for
    # upstream diffing and do not ship, so an edit here would be silently lost. The guard
    # fails with the Reason the moment such a copy diverges from stock.
    DeadEnds = @(
        @{
            Source = 'core-agent/src/qubes-rpc-services/VMExec.ps1'
            Reason = 'guest/VMExec.ps1 is the copy that ships (in the MSI via stage-qwt-repo.ps1, plus the rpc overlay and the updater agent); this core-agent copy is stock 4.2.2 kept for upstream diffing. Apply your change to guest/VMExec.ps1, or make the submodule copy the single source and update Mirrors/Files here.'
        }
    )

    # -------------------------------------------------------------------- StockShadowSweep
    # Maintained source trees swept against the stock admin image BY BASENAME: any file
    # here that differs from its stock counterpart must be shipped (covered by Mirrors or
    # Files above), a documented DeadEnd, or listed in SweepExclude - otherwise the guard
    # fails, because the guest would run the STOCK copy of a file we maintain. This is the
    # automatic detector for the incident class: no listing needed to DETECT a new
    # divergence, listing is the FIX.
    SweepTrees = @(
        'core-agent/src/qubes-rpc-services'
        'guest'
    )
    # Repo paths (relative, '/'-separated) excluded from the sweep with a reason - for
    # accidental basename collisions with unrelated stock files. Keep empty unless a
    # collision actually occurs; every entry weakens the tripwire.
    SweepExclude = @()

    # -------------------------------------------------------------------- CompiledSources
    # Sources that compile into binaries. The guard diffs the submodule against the pinned
    # upstream base: any change under Root must either land in a shipped file (MirrorDir
    # top-level files ship inside the built MSI via stage-qwt-repo.ps1's rpc rule, and via
    # the payload rpc/ overlay until that dies), or belong to a DirBinaries dir whose
    # built binary is present in the package at the mapped path (and enumerated in
    # Binaries) - otherwise the change ships NOWHERE and the build fails. This is what
    # makes the qrexec-wrapper incident (fix merged, CI green, every guest still running
    # the stock binary) impossible to reintroduce silently.
    CompiledSources = @{
        Submodule    = 'core-agent'
        # 'version 4.2.2' - the stock QWT 4.2.2 base commit of the core-agent fork.
        UpstreamBase = 'f79d290ae62ab9ed0f361680331cf805cc611752'
        Root         = 'src'
        MirrorDir    = 'src/qubes-rpc-services'
        # Paths are where the binary ships (or would ship): inside the built MSI, at the
        # image path stage-qwt-repo.ps1's table stages it to. qrexec-agent/client-vm are
        # withheld by recorded policy (see Binaries above): their mappings point at the
        # image path a future substitution would use, so a source divergence fails the
        # build until they actually ship there.
        DirBinaries  = @{
            'src/qrexec-wrapper'   = 'msi-image/PFiles64/Qubes Tools/bin/qrexec-wrapper.exe'
            'src/qrexec-agent'     = 'msi-image/PFiles64/Qubes Tools/bin/qrexec-agent.exe'
            'src/qrexec-client-vm' = 'msi-image/PFiles64/Qubes Tools/bin/qrexec-client-vm.exe'
        }
    }

    # -------------------------------------------------------------------------- KnownGaps
    # Standing, deliberately-tolerated violations. Each entry MUST still match a finding
    # (the guard fails on stale entries), and each downgrade is a loud ::warning:: in the
    # build log, never silence. Remove the entry the moment the gap is closed so the
    # guard starts enforcing it.
    # (Empty. G1 - the qrexec-wrapper drain-race fix shipping nowhere - was closed on
    # 2026-08-28 by building core-agent in qwt-full and staging it via -CoreAgentBins; its
    # entry was deleted in the same commit, which is what this list's stale-entry check
    # demands. Wave 1 of the stock-elimination migration closed no further entries -
    # this list was already empty. Add an entry here only for a gap that is deliberately
    # tolerated, never to quiet a guard.)
    KnownGaps = @()
}
