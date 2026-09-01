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
security** (grant removal, secure-desktop exposure closure, thousands of lines of state
machine deleted); what it costs is **measured performance headroom** (typing ~2.5–3×,
scroll ~3–4× the shipped hybrid — still far below stock) unless the foreground fast path is
retained. Drag outcome is unknown, not predicted-won.

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
- **Payoff that survives every refutation:** the 7200-page-per-start staging-grant leak
  (findings/capture.md open defect) closes structurally, and the secure-desktop residual
  exposure (StagingCopyFrame copies secure-desktop pixels into a dom0-mapped grant during
  the seamless freeze — it has no secure gate) ceases to exist *for sessions that never
  enter non-seamless*. Caveat honestly: grants are irrevocable in practice (xeniface
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
screen-slice contract for unattached windows; the secure-desktop staging exposure (with
the §2 caveat). Net: ProcessNewFrame's seamless arm collapses substantially — but the
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
- **P1 — PrintWindow area scaling** at 800×600 / 1080p / 1440p / 5120×1440 under the IDD,
  100 ticks each, CPU-ms and wall-ms. Bar: ≤~10 ms CPU/tick at maximized size (NOT 30 ms —
  that bar ships below-stock scroll regressions). Expected per current extrapolation: FAIL
  above ~1 Mpx, confirming concession 1.
- **P3 — prototype canonical bench + two scenarios the canonical suite lacks**: drag over
  a maximized Writer-A window, and focused-editor caret idle at maximized size (caret blink
  is real pixel change the hash cannot gate; ungated it extrapolates to worse-than-stock
  idle for a maximized editor). All four canonical phases must stay disjoint-below stock
  (45 s-settle bars: idle 3.91, drag 29.0, scroll 41.0, typing 22.8).
- **P4** — Win11 idle hash-on/hash-off on one binary (defect-reintroduced instrument proof).
- **P5** — dom0 blit/ring flood: 4×1080p windows ticking whole-window 30 Hz × 60 s; zero
  degraded-mode drops, live pixels, no dom0 freeze.
- **P6** — occluded staleness: mutate covered window, reveal, correct within one tick.
- **P7** — toast + context-menu acceptance under Writer B (a blank toast fails the model).
- **P8 (non-gating)** — WGC broker A/B (SYSTEM-in-session-1 vs `schtasks /ru user`, interop
  `CreateForWindow` on an NRB window): the Win11-only upgrade path question.

## 7. Recommendation

Do P2 regardless of the rest — desktop-grant removal in seamless stands on its own as a
security/structure win with near-zero blast radius. Treat the full pinned model as
conditionally attractive: commit only if P1 lands under the corrected bar or the owner
accepts the concession set in §4 (which amounts to "hybrid minus desktop grant", keeping
DDA-owned and drag attribution). Do not chase WGC on Win10; re-evaluate a Win11 broker
after 24H2 `DirtyRegions` (P8). Any protocol-visible follow-up (alpha channel for layered
surfaces, dom0-side damage) is Phase 3: design writeup + owner review + upstream design
issue first.
