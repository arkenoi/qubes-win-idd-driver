# Building out non-seamless mode

**Status: the switch works; the mode it switches into does not.** Written 2026-09-25 after a
session that made dom0's `qubes.SetGuiMode` actually reach the agent and then found that almost
nothing behind it had ever been exercised.

Jev, given the full symptom set and the measurements below, scoped this at
`build-out-nonseamless` **1.00** and rated a functional live switch **not a near-term deliverable
(0.16)**, with the instruction to say so plainly rather than keep iterating. This document is that.

## What already works, and should not be rebuilt

- The mode change executes in both directions and persists across a reboot (registry).
- The desktop grant is made on entry and P2 is preserved: a guest that never switches still never
  holds a whole-desktop grant.
- On a **first** entry after a fresh capture start, dom0 renders a correct live desktop in one
  window — verified by capture, 5120x1384, wallpaper and windows, not black and not frozen.
- Five switch-path defects were found by measurement and fixed this session; they stand.
- Safety is unchanged throughout: the geometry guard, Mode 1 (LogonUI never shown) and Mode 2
  (borderless fullscreen app windows still feature-gated) were not touched.
- **Seamless mode is unaffected by everything here.** It does not use the DDA frame path at all.

## Workstream 1 — frame supply (do first; everything else is unjudgeable until it is done)

**Symptom.** dom0's desktop window freezes. Measured with the guest untouched:
`loops=2, loop_age_ms>112000, inside=0, enabled=0` while `capture=1, degraded=0`.

**What that means.** The capture thread left its loop (`enabled=0`) and was *not* blocked inside
`AcquireNextFrame` (`inside=0`) — an earlier reading of mine that is retracted. The main loop still
held a live capture pointer and did not consider capture degraded, so neither the A7 degraded-retry
nor the CAPTUREGATE restart could ever fire. The code's own fault injection in `CaptureThread`
describes exactly this shape and says the main loop "currently has no way to notice" it.

**Done:** `QGACAPDEAD` notices it and drives the existing recovery path, fired once per departure.
`QGACAPENABLE` names which of the four sites cleared the flag.

**Not done:** the root cause. Jev: stop/restart race **0.71**; whether it predates this work is
**insufficient-evidence 0.80**.

**Known dead end — do not repeat it.** Forcing a capture replug on mode entry deadlocks:
`CAPTUREGATE capture error ... waiting for the gui-daemon confirm` with no matching confirm, and
capture stays down for ever. The replug depends on a daemon handshake that does not always
complete. Two separate attempts to build on it (gating entry on the grant, then on the window-0
dump) each produced a worse failure than the one they fixed.

**Acceptance (Jev, 1.00):** three full flip cycles, and within each non-seamless period two
captures taken while content changes must **differ** and must not be uniform-blank. A single
successful entry proves nothing — the defect only appears on the second and later entries.

## Workstream 2 — entry geometry

**Symptom (owner):** "why the fuck it was maximized at all?"

**Cause.** The desktop entered at 5120x1384 against a 5120x1440 host, so dom0 got a window covering
the screen. The geometry guard tests `>= 99% of host in BOTH dimensions` and is skipped entirely
when the size came from dom0, so 96% of height does not trip it.

Jev: this **violates** the project's binding never-fullscreen rule (0.60) — "never fucking ever
non-seamless mode goes fullscreen unless requested explicitly".

**To decide:** what size a *fresh* entry should use, and whether a dom0-remembered size from an
earlier session counts as "dom0 asked for it" in this entry. It currently does, and that is how the
window came up maximized without anyone asking.

## Workstream 3 — input

**Symptom (owner):** "does not deliver input to apps".

**Cause, from source.** `HandleKeypress` ignores the window entirely and carries the comment
`/* TODO: send to correct window */`; it synthesises input with `SendInput`, which lands on whatever
the guest currently focuses. Entering non-seamless calls `ResetWatch(FALSE)`, which removes every
watched window. Nothing in the input path is conditioned on the mode.

## Workstream 4 — resize

**Symptom (owner):** "never actually handled the resize".

This is already written down: CLAUDE.md Phase 2B-resize — the guest resolution following the dom0
window — is listed as **blocked and unbuilt**, and names the capture defect in Workstream 1 as its
prerequisite. It is a feature, not a regression.

## Rules this session paid for

- **Do not iterate on the owner's guest.** Three successive fixes each produced a new failure mode,
  and two of them left the guest unusable until it was reverted to the released agent.
- **A first entry proves nothing.** Every failure here appeared on re-entry or after time.
- **Seamless working proves nothing about this path.** Per-window capture does not touch the DDA
  frame path, so it stays healthy while the desktop path is entirely dead.
