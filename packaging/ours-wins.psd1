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
# HOW TO ADD A FILE in the future:
#   - a new/changed rpc handler or qubes.* service definition in
#     core-agent/src/qubes-rpc-services: NO step needed - make-setup.ps1 sweeps that
#     directory into the payload and the Mirrors rules below verify every swept file.
#   - a new one-off guest file maintained outside that tree: add a Files entry here AND
#     stage it in make-setup.ps1; the guard fails until both agree.
#   - a new fork-built binary staged into the payload bin\: add a Binaries entry here
#     (the orphan check fails the build until every bin\ file is enumerated).
# The guard also fails on STALE entries (a KnownGaps entry that stopped matching, a listed
# source file that no longer exists), so this list cannot silently rot in either direction.

@{
    # ---------------------------------------------------------------------------- Mirrors
    # Tree rules mirroring make-setup.ps1's payload sweep: every top-level file of
    # SourceDir matching Include (minus Exclude) must exist in the package at
    # PackageDir/<name>, byte-identical to the repo copy. Payload layout mirrors the
    # guest install tree under 'C:\Program Files\Qubes Tools'.
    Mirrors = @(
        @{
            # qubes.* qrexec service definitions -> guest qubes-rpc\
            SourceDir  = 'core-agent/src/qubes-rpc-services'
            Include    = 'qubes.*'
            Exclude    = @()
            PackageDir = 'rpc/qubes-rpc'
        }
        @{
            # rpc handler scripts (.ps1/.bat) -> guest qubes-rpc-services\
            # VMExec.ps1 is excluded ON PURPOSE: the maintained copy is guest/VMExec.ps1
            # (see Files + DeadEnds below); the core-agent copy is kept stock for
            # upstream diffing and must NOT ship.
            SourceDir  = 'core-agent/src/qubes-rpc-services'
            Include    = '*'
            Exclude    = @('qubes.*', 'VMExec.ps1')
            PackageDir = 'rpc/qubes-rpc-services'
        }
    )

    # ------------------------------------------------------------------------------ Files
    # One-off "ours wins" files: Source (repo path) must be present in the package at
    # Package, byte-identical.
    Files = @(
        @{
            # The MAINTAINED VMExec handler (exit-code propagation, UTF-8 decode,
            # vmupdate-shim routing, audit log). Ships through the rpc overlay so the
            # guest gets it even under /noupdates.
            Source  = 'guest/VMExec.ps1'
            Package = 'rpc/qubes-rpc-services/VMExec.ps1'
        }
    )

    # --------------------------------------------------------------------------- Binaries
    # Fork-built binaries that must NOT be byte-identical to the stock image copy
    # (byte-equal = our build did not land; the gui-agent.exe tripwire in
    # stage-qwt-repo.ps1 generalized). Stock = basename looked up in the extracted
    # stock admin image. Required=$false entries may be absent from the package, but
    # ONLY if a KnownGaps entry below documents the absence.
    Binaries = @(
        @{ Package = 'reference/gui-agent.exe';    Stock = 'gui-agent.exe';      Required = $true }
        @{ Package = 'reference/gui-watchdog.exe'; Stock = 'gui-watchdog.exe';   Required = $true }
        # The fork qrexec binaries. release-package builds core-agent in qwt-full and passes
        # -CoreAgentBins, so absence now means the build silently fell back to stock - the
        # exact failure that let the drain-race fix miss every guest for a week.
        @{ Package = 'bin/qrexec-wrapper.exe';     Stock = 'qrexec-wrapper.exe';   Required = $true }
        # qrexec-agent.exe / qrexec-client-vm.exe are deliberately NOT shipped. Their sources
        # are unmodified against the 4.2.2 base, so our build would be functionally identical -
        # no benefit - while qrexec-agent is the service dom0 talks to and a bad swap costs the
        # guest's manageability entirely. They are built (qrexec-agent.vcxproj also generates
        # qwt_version.h) and kept in the artifact for diagnostics, not staged into the payload.
        # The moment either source diverges, CompiledSources fails the build until it ships.
    )

    # --------------------------------------------------------------------------- DeadEnds
    # Repo copies that must remain IDENTICAL to the stock image: they exist only for
    # upstream diffing and do not ship, so an edit here would be silently lost. The guard
    # fails with the Reason the moment such a copy diverges from stock.
    DeadEnds = @(
        @{
            Source = 'core-agent/src/qubes-rpc-services/VMExec.ps1'
            Reason = 'guest/VMExec.ps1 is the copy that ships (rpc overlay + updater agent); this core-agent copy is stock 4.2.2 kept for upstream diffing. Apply your change to guest/VMExec.ps1, or make the submodule copy the single source and update Mirrors/Files here.'
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
    # Sources that compile into binaries the package currently takes from the stock MSI.
    # The guard diffs the submodule against the pinned upstream base: any change under
    # Root must either land in a shipped file (MirrorDir top-level files ship via
    # Mirrors), or belong to a DirBinaries dir whose built binary is present in the
    # package (and enumerated in Binaries) - otherwise the change ships NOWHERE and the
    # build fails. This is what makes the qrexec-wrapper incident (fix merged, CI green,
    # every guest still running the stock binary) impossible to reintroduce silently.
    CompiledSources = @{
        Submodule    = 'core-agent'
        # 'version 4.2.2' - the stock QWT 4.2.2 base commit of the core-agent fork.
        UpstreamBase = 'f79d290ae62ab9ed0f361680331cf805cc611752'
        Root         = 'src'
        MirrorDir    = 'src/qubes-rpc-services'
        DirBinaries  = @{
            'src/qrexec-wrapper'   = 'bin/qrexec-wrapper.exe'
            'src/qrexec-agent'     = 'bin/qrexec-agent.exe'
            'src/qrexec-client-vm' = 'bin/qrexec-client-vm.exe'
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
    # demands. Add an entry here only for a gap that is deliberately tolerated, never to
    # quiet a guard.)
    KnownGaps = @()
}
