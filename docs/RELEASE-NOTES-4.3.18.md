# QWT-NG 4.3.18 (agent d45428e, code 9379eb3)

MSI ProductVersion **4.3.18** — a real bump over 4.3.17, so an in-place MajorUpgrade lands cleanly
on an existing guest (no uninstall, no PV-disk gate, no reboot loop).

## What's in this release

**Menu rendering, de-sliced.** Seamless menus and shell surfaces are now mapped as a single
pixel-accurate surface instead of stitched slices. This is the completion of the menu
pixel-perfect work (edge-trim + crop-before-show map-defer) followed by the 3-step de-slice plan,
with the WGC capture broker **default-on for win11 24H2+** and the legacy slice/retire knobs
removed (agent code `9379eb3`; broker-default-on + retire cleanup `d45428e`).

## Verified

**Benchmarked (canonical stock-vs-ours suite, interleaved, 6 valid reps, 45 s settle):**
- **win10**: ours dramatically better on every phase, ranges disjoint — scroll −88%, typing −87%,
  drag −45%, idle −70…−87% (the fork's performance win, reproduced on this build).
- **win11 24H2**: indistinguishable from stock, as expected (the platform bounds all agents there);
  the OS-aware gate treats that as the pass condition.

**Full acceptance protocol — all five parts, zero product-defect failures:**
- **Install/upgrade matrix**: 94/94 cells passed (clean install, reinstall, upgrade, AppVM).
- **Network (P2)**: immediate netvm attach binds the PV NIC in the *same boot* (zero reboots,
  emulated adapter unplugged); a real 25 MB transfer crossed the PV NIC, cross-checked on the
  adapter's own rx counter.
- **Updates (P3)**: dom0-owned update scan reaches dom0 on a TemplateVM; stack/tasks/relay intact.
- **Rendering (P4, win10)**: menu de-slice (synth-crop), toast delivery, resolution-liveness,
  Start-hidden-in-seamless — all pass.
- **Safeguards (P5)**: fullscreen/secure-desktop gates, containment, autologon re-arm, agent-image
  identity, fault-build swap/restore — all pass; the live fail-proof drills are the deferred
  human-confirmed layer.

Remaining gaps in the acceptance ledger are exclusively that deferred layer (live fail-proofs and
attended feature-on checks) — nothing in the build failed a check.

## Known issue (tracked separately)

**win11 24H2 resolution-change capture freeze** (`0x887a0026`, "keyed mutex abandoned"): after a
guest resolution change or a seamless↔fullscreen mode switch, the recovered capture can re-send a
stale frame. It is on the resize/mode-switch path — **not** exercised by steady-state seamless
(drag/scroll/menus/typing), and **win10 is unaffected** (the passing control). Pre-existing
(the Phase 2B-resize prerequisite bug); the fix is a one-time full capture-stack rebuild + re-grant
on the resolution-change event. Tracked as its own item; it does not affect the de-slice deliverable.
