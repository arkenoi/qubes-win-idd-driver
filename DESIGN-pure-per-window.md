# Design study: PURE per-window bitmaps — full compositing + damage handoff to dom0

Status: FEASIBILITY VERDICT, 2026-09-02. Owner-requested study. Nothing here is implemented,
scheduled, or proposed upstream. Method: 6 parallel evidence passes over the 4.3.17 agent
tree, gui-daemon + gui-agent-linux sources (`upstream/ro/`), repo findings, and capture-API
research; then an architect synthesis and an adversarial refutation pass. Adversary
corrections are folded in below — where architect and adversary disagreed, the adversary's
arithmetic won and is presented as the verdict.

## 0. The pinned goal (owner, 2026-09-02)

Every guest window is a mere **bitmap with zero machinery** at the window layer: allocate,
grant, `MSG_WINDOW_DUMP`; pixels get written in; whole-window `MSG_SHMIMAGE` ticks. No
guest-side diffing, no dirty rects, no occlusion/z-order logic, no slice bookkeeping, and
**no part of the composited desktop granted to dom0 in seamless mode**. Compositing is
fully dom0's; "damage" degenerates to "blit this window now". The Linux agent is the
reference model.

## 1. Verdict

**Feasible with concessions — but the honest shape is "the shipped hybrid minus the desktop
grant", not a machinery-free agent.** The protocol side is fully confirmed: gui-daemon
needs no screen window whatsoever, and the Linux agent already runs the granted-bitmaps-only
model. The desktop grant is removable in seamless almost surgically, and removing it closes
two standing defects for free. But the literal zero-machinery ideal is unreachable on
Windows — there is no out-of-process per-window paint signal, the surfaces that must keep
working (toasts above all) have no pixel source except the composited desktop, and
whole-window ticks at measured PrintWindow prices break the project's own
disjoint-below-stock performance bar at ordinary maximized-window sizes. Every deletion the
ideal promises was checked; about half survive. What this redesign buys is **structure and
tidiness** (grant removal, the never-reclaimed staging-grant leak gone, no longer copying the
whole desktop to dom0, thousands of lines of state machine deleted); what it costs is
**measured performance headroom** (typing ~2.5–3×, scroll ~3–4× the shipped hybrid — still
far below stock) unless the foreground fast path is retained. Drag outcome is unknown, not
predicted-won.

> **Owner ruling 2026-09-02: this is NOT a security/isolation win.** Removing the desktop
> grant does not change the qube boundary or gui-daemon's trust model (dom0/the GUI domain
> already receives guest window content; a hostile guest can grant what it likes regardless).
> The value is hygiene — fewer/leak-free grants, less redundant copying, a simpler agent.
> Wherever this doc earlier said "security" or "exposure closure", read "tidiness/correctness".

## 2. What is CONFIRMED (source-verified this study)

- **gui-daemon requires no screen window.** `g->screen_window` is NULL-initialized
  (xside.c:733), set only if the agent creates remote id 0, and every use is NULL-guarded;
  a damage message for a window with no attached image hits a safe no-op branch
  (clamp + optional border, xside.c:2352–2367). A pure agent needs no fallback for dom0's
  sake. [verified]
- **The Linux agent IS the pinned model** — `XCompositeRedirectSubwindows`, per-window
  composite pixmaps granted via the X driver, no window 0, no root grant, no non-seamless
  mode (guest fullscreen = `WINDOW_FLAG_FULLSCREEN` on an ordinary window). One deviation:
  its damage is FINE-grained (`XDamageReportRawRectangles` forwarded verbatim), so
  whole-window ticks are *coarser than the reference model* — protocol-legal, but more
  dom0 blit volume than Linux guests produce. [verified]
- **Cursor is dom0-rendered and capture-independent** (`MSG_CURSOR` = whitelisted font
  cursor ID, no guest pixels). [verified]
- **Un-granting the desktop is nearly surgical.** Under the default staging design every
  in-agent pixel consumer already reads the staging buffer, not the DXGI surface; skipping
  `XcGnttabPermitForeignAccess2` in `StagingEnsure` + suppressing `SendScreenGrants` in
  seamless leaves all agent-side code working. The identity assumption (granted buffer ==
  DDA image) survives only in the direct-map fallback path, which dies. [verified]
- **Payoff that survives every refutation (hygiene, not security — owner ruling):** the
  7200-page-per-start staging-grant leak (findings/capture.md open defect) closes
  structurally, and the agent stops copying the whole desktop — secure-desktop pixels
  included — into a dom0-mapped grant (`StagingCopyFrame` has no secure gate) *for sessions
  that never enter non-seamless*. This is a correctness/tidiness gain (dom0 already receives
  guest window content and is trusted; it is NOT an isolation improvement). Caveat honestly:
  grants are irrevocable in practice (xeniface
  release builds never revoke), so the first entry into non-seamless grants the desktop
  mirror for the process lifetime; a hard guarantee needs a separately-granted
  non-seamless buffer (~30 MB @5120×1440 + copy plumbing) or acceptance of
  mode-history-conditionality. [verified]
- **MSG_SHMIMAGE is 28 bytes on the wire; the ring (64 KiB) holds ~2340 ticks** — the ring
  is not the constraint against a healthy daemon. The daemon has NO coalescing, rate
  limiting, or pushback: each tick is one unthrottled `xcb_shm_put_image`, and the X server
  copies w·h·4 per tick (1080p@60Hz ≈ 500 MB/s per window). dom0-side sustained blit
  throughput is unmeasured. [verified / UNVERIFIED for dom0 throughput]
- **Track-B interaction is a retired risk, not a blocker**: `DesktopImageInSystemMemory`
  measured TRUE on retail 19045 and on the IDD-solo desktop (findings/capture.md
  [verified 2026-08-15]); an oracle-only DDA additionally needs only dirty metadata, not
  the mapped image.

## 3. Why literal zero-machinery is unreachable (each alternative checked)

- **No tick source exists without capture**: Windows has no per-window repaint signal an
  out-of-process SYSTEM agent can consume — no paint WinEvent, WM_PAINT hooking needs DLL
  injection and misses DX presents, DWM timing APIs are global clocks.
- **WGC** — the one API whose `FrameArrived` *is* the wanted tick and whose coverage *is*
  the NRB gap — cannot activate in the agent's SYSTEM/session-1 context (0x8007000E,
  re-confirmed as an activation-context failure, not necessarily a platform block), and on
  Win10 19045 its capture border is UNREMOVABLE (`IsBorderRequired` needs build 20348) —
  production-disqualified on Win10 regardless of activation workarounds. On Win11 the
  border is removable (22000+) and 24H2 adds `DirtyRegions`/`MinUpdateInterval` — a real
  future upgrade via a user-session broker process (Chrome-Remote-Desktop-style), Win11
  only, never a dependency.
- **Fixed cadence fails arithmetic**: holding the canonical idle (0.33–0.50) allows
  ≤0.6–0.9 captures/s TOTAL across all windows; 10 idle windows at even 1 Hz equals stock
  idle. Ungated ticks erase the 87–93 % idle win.
- **PrintWindow-ineligible classes have no other pixel source**: override-redirect popups
  (Edge bubbles PrintWindow BLANK from this context), `WS_EX_NOREDIRECTIONBITMAP` — which
  is not just shell junk but every UWP app and Windows Terminal — ULW/colorkey layered, and
  **toasts** (CoreWindow NRB, MUST-KEEP by project rule). Only the composited desktop
  renders them correctly (dom0 has no per-pixel-alpha channel; the desktop pre-blends).
  `DwmGetDxSharedSurface` is rejected three ways (returns the GDI redirection surface NRB
  windows don't have; measured to fail on WARP/virtual adapters; undocumented).

## 4. The minimum realization (post-adversary)

Two writers + one local oracle + retained hot-path machinery:

- **Writer A** — whole-window `PrintWindow(PW_RENDERFULLCONTENT)` off-app-thread (the
  shipped engine) for eligible classes.
- **Writer B** — copy from a **local, UNGRANTED desktop mirror** (today's staging buffer,
  grant skipped) for the ineligible minority: o-r popups, NRB (incl. toasts), ULW/colorkey.
  Content stays position-dependent for this class only (full re-copy on move, drag-freeze +
  settle, toastcrop's crop measurement retained).
- **Oracle** — the existing DDA session kept locally, never granted: dirty-rect metadata
  intersected with window rects drives ticks; `FrameRedundant` hash retained at oracle
  level (Win11 over-reports ~5.2 idle frames/s, ~9/10 pixel-identical).
- **Concessions the adversary forced back in** (each was on the architect's delete list):
  1. **DDA-owned foreground channel stays.** Budget arithmetic: staying disjoint-below
     stock on 20 Hz scroll allows ≤~10 ms CPU/tick; linear-area extrapolation from the
     measured 5.1–6.2 ms @800×600 crosses that at ~0.9–2.9 Mpx — an ordinary maximized
     window. Whole-window ticks on the hot path fail the bar; sub-rect memcpy from the
     mirror (~121 µs/frame measured) does not.
  2. **Drag dirt-attribution stays.** A dragged window dirties its whole screen extent
     every frame; without attributing that dirt to the *moving* window, every window
     beneath the drag path gets whole-window ticks at oracle rate (~24–32 fps) — multiple
     cores extrapolated over a maximized window, plus ~0.7–0.9 GB/s of X-server copy. The
     "drag = pure metadata" win holds only for the dragged window itself (d64bca6, and
     InputDragFreezeContent=1 already freezes mid-drag content today).
  3. **A slow bounded repair tick replaces the 250 ms sweep** rather than nothing: the
     in-source soundness argument for hashing explicitly depends on a sweep converging
     missed updates; without repair, a hash collision / blank capture / dropped tick is
     permanent staleness — a defect class the shipped design does not have.
  4. **Menu synthesis and the shell-surface move-refusal are retained** — both are owner
     decisions (2026-08-16 RND-3; toastcrop anchor rules) that the pure model would have
     silently reverted. Any change there goes to the owner first.
  5. **A per-window tick pacer** (latest-wins, ~16 ms floor, same pattern as the configure
     pacer) — the daemon-side has no throttle at all, so the guest must be the backstop;
     plus re-tick-on-recovery for degraded-mode drops (the bounded-send fix's live proof is
     still UNVERIFIED per findings/capture.md).
  6. **Non-seamless keeps the desktop grant, period** — window 0 IS the desktop; the pinned
     model is a seamless-mode architecture. (Future alternative: IDD-fed window 0, Track B.)

## 5. What actually dies (surviving delete list)

Seamless desktop grant + `SendScreenGrants` + unconditional window-0 CREATE/DUMP; the
staging-grant-per-start leak; A6 park/ack/revoke screen-grant lifecycle (seamless side);
the direct-map fallback + identity assert; `GetFrameMoveRects` instrumentation;
`PwScreenUnchanged` per-window hash; drag-slice machinery for eligible windows; row-diff
as a *damage shape* generator (a change/no-change gate remains); the daemon-side legacy
screen-slice contract for unattached windows; and the redundant whole-desktop copy to a
dom0-mapped grant (secure-desktop pixels included — a tidiness gain, not a security one; §2
caveat). Net: ProcessNewFrame's seamless arm collapses substantially — but the
DDA pipeline, DDA-owned arbitration, synthesis, and a repair tick all remain. Order of a
few thousand lines, roughly half the architect's original claim.

## 6. Decision probes (serial, on the testbed, in this order)

- **P2 — ungranted staging: RUN 2026-09-02, PASS.** Probe = `SeamlessNoScreenGrant` registry
  flag (agent `p2/noscreengrant`, commit 6533765; artifact `ECA1317A…`): staging allocated
  but never granted, both window-0 dump sites suppressed, `CREATE(0)` kept. Subject:
  `win10-p2`, a StandaloneVM clone of win10-tpl (first attempt on win10-app was INVALID —
  an AppVM's root volume reverts the swapped binary and the HKLM flag on every boot; the
  rerun hash-gates every boot). Arms: baseline / probe-flag-off / flag-on ×3 cold boots /
  flag-off again, one binary. Result: flag-on markers `STAGING allocated UNGRANTED` +
  `P2NOGRANT window-0 dump suppressed` (+ the post-recreate suppression exercised by boot
  transitions) on all 3 boots, granted markers return in the off arms — instrument seen to
  fail both directions; **2 of 3 flag-on boots pixel-IDENTICAL (0/3.9M px) to the flag-off
  control**, third differs by a 1-px status-bar hairline (0.098%) — less than the granted
  arms' own boot-to-boot variation (0.15–0.24%); no attach failures, no `QGADESKSTUCK`, no
  fatal markers. Scope honestly: evidence of grant absence is agent-side (grant call never
  made + refs never sent — nothing for dom0 to map); toast fired `true` every arm but no
  arm's per-window capture contains the toast surface (instrument limitation, equal across
  arms), so toast rendering is unproven visually and rests on the path being
  grant-independent by construction. Perf was NOT measured (P3). Grant removal in seamless
  is hereby demonstrated viable on this rig; remaining before shipping it: reroute
  `PwForceLegacy`-class fallbacks to the guest-side sliceFed channel, gate on negotiated
  protocol ≥ 1.7, and grant-on-demand for a non-seamless switch.
- **P1 — PrintWindow area scaling: RAN 2026-09-02 (win10-p2), bar FAILED above ~2 Mpx as
  predicted → concession 1 (DDA-owned foreground channel) is MANDATORY, not conditional.**
  Measured CPU-ms per whole-window PrintWindow(PW_RENDERFULLCONTENT), 40 calls/size (800×600
  wall p50 16.1 ms validates the instrument vs the 15–18 ms anchor): 0.48 Mpx → 2.7 ms;
  1.02 Mpx → 1.6 ms; 2.07 Mpx → 12.9 ms; 3.69 Mpx → 14.5 ms; maximized 5122×1393 (7.13 Mpx)
  → 40.2 ms (wall p50 88 ms). The ≤10 ms/tick bar (to hold disjoint-below-stock 20 Hz scroll)
  is crossed between 1 and 2 Mpx — any ordinary maximized window — exactly the adversary's
  0.9–2.9 Mpx estimate. Whole-window PrintWindow therefore cannot feed the drag/scroll/typing
  hot path at real sizes; the mirror sub-rect path (~121 µs) must. (Measured 40 ms at
  maximized is ~half the design's 80–96 ms linear extrapolation — the extrapolation was
  pessimistic, ~5.6 ms/Mpx actual — but 40 ms is still 4× the bar, so the verdict is
  unchanged.) Instrument traps burned in: the probe MUST run as the interactive user
  (`schtasks /ru user /it`; session-0 qrun is desktop-blind → 0×0 rect), find Notepad via
  `Get-Process … MainWindowHandle` (FindWindowW(cls,$null) fails — PowerShell marshals $null
  as an empty-title match), write to a SYSTEM-precreated world-writable dir (`C:\Users\Public`;
  a non-admin task cannot mkdir under `C:\`), and flush results incrementally per size (the
  large sizes take minutes; a single final write always lost the poll race).
- **P3 — canonical bench, P2 flag OFF vs ON: RAN 2026-09-02 (win10-p2), PASS (perf-neutral).**
  One binary, flag flipped per side, cold boot + log-marker assertion per side, 3 interleaved
  rounds. Means (pct of one core) OFF vs ON: drag 14.6/15.1, scroll 3.2/3.4, typing 2.8/3.4,
  idle 0.5/0.4 — every phase's OFF and ON ranges OVERLAP, and the round-to-round variance
  within each side (drag swung 13–18 on both) exceeds any OFF/ON gap, so removing the desktop
  grant is statistically indistinguishable in cost. Both sides sit far below stock (drag 29.0,
  scroll 41.0, typing 22.8, idle 3.91). This is P2-scoped (flag toggles only the grant, not the
  engine), so it measures grant removal, not the full pure model. STILL OWED for the full
  model: the two scenarios the canonical suite lacks — drag over a maximized Writer-A window
  (the R1 tick-storm risk), and focused-editor caret idle at maximized size (real micro-dirt
  the hash cannot gate) — plus a Win11 arm (see below).
- **P4** — Win11 idle hash-on/hash-off on one binary (defect-reintroduced instrument proof).
- **P5** — dom0 blit/ring flood: 4×1080p windows ticking whole-window 30 Hz × 60 s; zero
  degraded-mode drops, live pixels, no dom0 freeze.
- **P6** — occluded staleness: mutate covered window, reveal, correct within one tick.
- **P7** — toast + context-menu acceptance under Writer B (a blank toast fails the model).
- **P8 (non-gating)** — WGC broker A/B (SYSTEM-in-session-1 vs `schtasks /ru user`, interop
  `CreateForWindow` on an NRB window): the Win11-only upgrade path question.

## 6a. Win11 arm (win11-p2, RAN 2026-09-02)

Win11 was run as its own suite (StandaloneVM clone of win11-tpl, probe installed and persisted)
because it was expected to differ — and it does, decisively on P1.

- **P2 (win11) — PASS, identical to Win10.** All 3 flag-on cold boots: `STAGING allocated
  UNGRANTED` + `P2NOGRANT window-0 dump suppressed`; flag-off control returns `STAGING granted`;
  no `A7DEGRADED`/`VCHANWEDGE`/`WCBLACK`/`WCDEAD`. Grant removal holds on Win11.
- **P1 (win11) — whole-window PrintWindow is ~2× costlier than Win10, and charges the TARGET
  process too.** CPU-ms/call (probe + target) and wall p50: 0.48 Mpx → 6.6+5.9=12.5 (38 ms);
  1.02 → 9.0+12.9=21.9 (59 ms); 2.07 → 17.6+13.3=30.9 (78 ms); 3.69 → 23.1+15.6=38.7 (80 ms);
  maximized 7.13 Mpx → 43.4+23.4=66.8 (141 ms). Win10 had ~0 target-side cost; Win11's
  PrintWindow pulls the target's DWM/render path in. The ≤10 ms/tick bar is blown at the
  SMALLEST size tested — so on Win11 whole-window PrintWindow is even less viable and the
  DDA-owned foreground channel is unconditionally required. This is the concrete reason the WGC
  broker (P8) is specifically a Win11 play: PrintWindow is worst exactly where WGC is best
  (border removable ≥22000, DirtyRegions ≥24H2).
- **P3 (win11) — drag perf-neutral; scroll/type/idle too noisy at N=3 to call, and the apparent
  scroll delta is an instrument artifact, not a grant cost.** Means OFF vs ON: drag 15.3/14.6
  (clean, overlapping), scroll 1.5/3.4, type 1.4/1.9, idle-pre 1.0/0.8. The scroll ranges do not
  overlap, BUT Win11's DDA over-reporting smears CPU across phase boundaries: the OFF side's
  "missing" scroll CPU shows up as inflated idle-mid spikes (4.3/5.0/12.8 vs ON's 0/2.0/2.5), and
  P2 cannot mechanistically change scroll cost (it removes only the grant, not the DDA-slice
  path). So the scroll "regression" co-varies with idle-mid mis-attribution and is rejected as a
  phase-boundary artifact; drag (the cleanest, longest phase) is identical off/on. All steady-state
  numbers remain far below stock. A clean Win11 disjointness verdict on scroll/type would need
  more rounds; the mechanism rules out a real P2 cost.
- Win11 P1 instrument note: same finder fix as Win10 needed (Get-Process MainWindowHandle; the
  suite's first P1 failed on a notepad-launch race, re-run with a window present succeeded).

## 7. Recommendation

Do P2 regardless of the rest — desktop-grant removal in seamless stands on its own as a
tidiness/structure win (leak gone, less redundant copying, simpler agent; NOT a security
win per the owner ruling in §1) with near-zero blast radius. Treat the full pinned model as
conditionally attractive: commit only if P1 lands under the corrected bar or the owner
accepts the concession set in §4 (which amounts to "hybrid minus desktop grant", keeping
DDA-owned and drag attribution). Do not chase WGC on Win10; re-evaluate a Win11 broker
after 24H2 `DirtyRegions` (P8). Any protocol-visible follow-up (alpha channel for layered
surfaces, dom0-side damage) is Phase 3: design writeup + owner review + upstream design
issue first.
