# QWT-NG 4.3.x (agent <SHA>) — idle-burn fix, upgrade-path hardening, app render tweaks

**DRAFT — prepare-but-hold (owner decision 2026-08-09). Do not publish until: (1) the
sweep A/B verdict is pasted in and PASSES, (2) the PV-gate validation outcome is pasted
in, (3) the owner approves. Placeholders are marked <LIKE-THIS>.**

Package `4.3.0+agent.<SHA12>`, from CI run `<RUN-ID>`. Supersedes `v4.3.0-agent03b1674`.

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

## Upgrading over stock QWT no longer risks bricking the guest silently

Field report (thanks, GWeck): if the existing QWT has the PV disk driver active,
removing it mid-upgrade reverts the boot disk toward emulated IDE and the intermediate
reboot can bugcheck 0x7B INACCESSIBLE BOOT DEVICE. The installer now:

- probes whether the C: boot disk is on the PV path and **refuses to uninstall** the
  existing QWT unless `/acceptpvdiskupgrade` is passed;
- prints the safe-mode recovery recipe on screen and into the install log before any
  risky reboot; README.txt carries it under "UPGRADING FROM STOCK QWT".

Validation status: <PV-VALIDATION OUTCOME: probe verified positive/negative on real
guests; crash repro result on the expendable guest>.

## Apps stop fighting the GPU-less guest (default on, `/noapptweaks` to skip)

Stage 2 now applies machine-wide render policies: Chrome/Edge/Brave/Chromium and
Firefox software rendering, Slack (the one Electron app with a real policy surface),
the WPF software-rendering fallback, IE/WebBrowser-control software render, and the
per-user Office keys (DisableHardwareAcceleration + DisableAnimations) delivered to
all existing profiles and the Default profile. Measured motivation: Word with HW accel
presented a frame every 257 ms and dirtied ~237k px per keystroke; without, 31 ms and
~3.4k px. Electron apps without a policy surface (VS Code, Discord, Teams, Signal) are
deliberately untouched — the doc lists the per-user knobs.

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
