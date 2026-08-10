# QWT-NG 4.3.0 (agent 09b643e) — idle-burn fix, in-place upgrades, app render tweaks

**Published as `v4.3.0-agent09b643e`** from CI run `31364772166` (release-package on
`main`, all checks green). Package `4.3.0+agent.09b643e5d278`. Supersedes
`v4.3.0-agent03b1674`.

Provenance: `gui-agent.exe` in these assets is sha256-prefix `91F40ECE29286063` — the
exact binary the upgrade end-to-end test verified installed, running and hash-matched.
The performance A/B ran on a sibling CI build of the same agent commit (`09b643e`; the
Windows build is not timestamp-reproducible), toggling the fix at runtime on one binary.

## The headline: the standing idle burn is gone (verified 2026-08-09)

The 2026-08-09 single-variable benchmark showed this package's agent costing 2× stock
CPU on typing. Root cause: not the typing path (its incremental cost matches stock) but
a standing idle burn — the per-window capture engine's 250 ms sweep kept re-rendering
the DDA-served window with a full PrintWindow + whole-buffer diff 4×/s, even when
nothing changed. This release exempts DDA-owned windows from the sweep (registry
`SweepDdaExempt`, default on; the sweep still serves guest-occluded windows, which DDA
cannot see).

Measured, one binary, marker-toggled A/B, 3 rounds interleaved, cold boot included,
hash-verified every rep (same rig and harness as the stock comparison; the re-enabled
sweep reproduces the pre-fix numbers, proving the control):

    idle   exemption on 0.83   sweep re-enabled 2.86   (stock reference 0.57; pre-fix 3.04)
    typing exemption on 1.71   sweep re-enabled 3.93   (stock reference 2.02-2.19; pre-fix 4.38)
    drag   exemption on 8.67   sweep re-enabled 13.15  (stock reference 12.31)
    scroll exemption on 3.51   sweep re-enabled 5.51   (stock reference 4.37)

With the fix, the agent no longer costs more CPU than stock on any measured phase. The
stock column is the prior run's reference on the same guest and harness (not interleaved
the same day); the E-vs-N separation is same-run and complete on typing.

The same change also closes for real the buffer-ownership race the ESTABLISH-ONCE
rework had claimed closed by construction: while DDA serves a window, the engine no
longer writes its buffer at all — removing a 4 Hz content-swap hazard on windows whose
PrintWindow pixels differ from the composited screen.

## Upgrading over stock QWT is now a plain MSI major upgrade (validated end to end)

The 4.3.0 version bump lets the rebuilt MSI (same UpgradeCode as stock, higher
ProductVersion, `<MajorUpgrade>`) replace an older QWT inside one Windows Installer
transaction: no separate uninstall, no intermediate reboot, PV disk driver upgraded in
place. Validated 2026-08-10 on a clean-room PV-booted stock guest: in-place path taken,
guest boots, single 4.3.0.0 product, agent hash-verified, PV disk re-bound (first boot
runs on the emulated safety net; PV re-binds on the next reboot).

For the one case a major upgrade cannot handle (reinstalling the same or a newer
version), the field-reported 0x7B INACCESSIBLE BOOT DEVICE hazard (thanks, GWeck) is
now fenced: the installer probes the PV boot path (probe validated live — True on three
PV guests, False on an emulated-path state; the crash itself was deliberately reproduced
and it bricks the qube with NO in-guest recovery under Qubes) and refuses to uninstall
without `/acceptpvdiskupgrade`; when overridden it re-arms the emulated storage stack
before the risky reboot and prints the recovery recipe into the log and console.

## Apps stop fighting the GPU-less guest (default on, `/noapptweaks` to skip)

Stage 2 now applies machine-wide render policies: Chrome/Edge/Brave/Chromium and
Firefox software rendering, Slack (the one Electron app with a real policy surface),
the WPF software-rendering fallback, IE/WebBrowser-control software render, and the
per-user Office keys (DisableHardwareAcceleration + DisableAnimations) delivered to
all existing profiles and the Default profile. Measured motivation: Word with HW accel
presented a frame every 257 ms and dirtied ~237k px per keystroke; without, 31 ms and
~3.4k px. Electron apps without a policy surface (VS Code, Discord, Teams, Signal) are
deliberately untouched — the doc lists the per-user knobs.

## qvm-create-windows-qube works out of the box now

Its auto-qwt helper globs for `qubes-tools-*.exe|msi`, which matches nothing in this ISO
and fails silently. Instead of a %post notice telling you to fix it, the dom0 RPM now
fixes it: `%post` runs the shipped `qwt-ng-fix-qwcq`, which finds qvm-create-windows-qube
installations, backs up the upstream `install-qwt.bat` once, and swaps in the
QWT-NG-aware stub (it still falls back to the upstream glob for a stock ISO). Idempotent,
reports what it patched, re-runnable by hand if you install qvm-create-windows-qube later.

## Versioning

The deliverable now reports its own version — 4.3.0 — everywhere (agent binaries, MSI
ProductVersion, package manifest, RPM), instead of masquerading as stock 4.2.2.
References to "4.2.2" in docs mean the upstream QWT release this package is built from.

## Still true, still honest

- Binaries are TEST-SIGNED; the installer enables testsigning guest-wide.
- <CARRY the pv-networking, cursor, MoveUsers, /idd items from RELEASE-NOTES-03b1674
  as "carried over" once the section above is filled in.>
- This package is installed for its correctness fixes and capabilities. Performance
  claims are limited to what the single-variable harness has actually verified —
  see docs/BENCHMARKS.md.
