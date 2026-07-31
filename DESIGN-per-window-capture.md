# Design: per-window capture for the Windows GUI agent

> **UPDATE 2026-08-01 — implemented; capture engine changed from WGC to PrintWindow.**
> This document was written before implementation and analyzes Windows.Graphics.Capture
> as the capture API. The SHIPPED build (`agent/perwindow`, package
> `qwt-improved 4.2.2+agent.ec55f39`) uses **`PrintWindow(PW_RENDERFULLCONTENT)`
> instead**: WGC cannot be activated in the agent's process context (SYSTEM token,
> session 1 — `IsSupported()` returns 0x8007000E, `CreateForWindow` throws), while
> PrintWindow works under GDI there and was proven byte-correct on occluded windows
> (Gate 0). The protocol/grant/daemon analysis below (§1, §2, §4–§7) is unchanged and
> was validated end to end. What changed: the per-frame cost numbers in §3 measured WGC
> and DO NOT describe the shipped engine — re-measure PrintWindow before quoting §3
> upstream. The idle-redelivery (§3 hazard 1) and session-churn (§3 hazard 2) hazards
> are WGC-specific and do not apply to the PrintWindow engine (which captures only on
> DDA-dirty trigger + a 250 ms round-robin sweep, row-diffed). See FINDINGS.md
> 2026-08-01 for the as-built engine and the acceptance results.

Status: DRAFT for user review — terminal deliverable of SESSION-PLAN-per-window-capture.md.
Nothing here has been proposed upstream; per CLAUDE.md Phase 3, upstream contact happens
only after the user approves this writeup and the accompanying issue text.

Everything below is either measured in this repo this session (FINDINGS.md 2026-07-31,
instrumentation/perwin-*.txt) or cited to source with file:line. The Q1 citations were
re-derived from source by three independent adversarial verification passes (automated),
and checked byte-identical between gui-daemon master (f66fb34c) and release4.3 (b996d00c).

Measurement scope, stated once and applying to every number below: ONE guest —
win-idd-test, Win10 build 19044, 4 vCPU, no GPU (WARP + Basic Display Adapter), stock
QWT 4.2.2. No claim below is offered as universal across builds or hardware.

## 1. Summary

Every hard visual defect in the seamless model (menu-hover corruption, drag debris,
mid-drag slicing, wobble, stale clip bands) is one defect: the guest captures a single
composited desktop and the agent slices per-window rectangles out of it by screen
coordinates. The fix is for the guest to supply per-window content and stop caring where
windows are or what covers them.

The decisive discovery of this session: **that fix is not a protocol change. It is the
protocol.** The Qubes GUI protocol and gui-daemon already support per-window framebuffers
as their mainline path — it is what the Linux agent does today. The Windows agent's
window-0 whole-screen dump is the legacy fallback. Converging the Windows agent with the
Linux agent's model requires zero daemon changes and zero protocol changes.

The honest price (measured, §3): the current transport's zero-copy property is
**abandoned** — per-window capture introduces a per-damaged-window CPU copy of roughly
2 ms (800x600) to 8 ms (1080p) per frame that does not exist today. The claim of this
document is that the trade is worth it, and §3 argues it with numbers rather than
assuming it.

## 2. Q1 — the daemon already does this (verified, R4.3-identical)

- Dispatch is per-window: `handle_message` resolves `hdr.window` via `remote2local` and
  hands the resolved window to `handle_window_dump` (xside.c:3942, 4025-4029).
- No window-0 special case was found on that path. Method, honestly scoped: every
  occurrence of the `FULLSCREEN_WINDOW_ID` symbol in xside.c was examined (455, 2066,
  3988 — none on the dump path); this does not rule out an indirect special case not
  using the symbol, but the Linux agent exercising this exact path per-window in
  production is the stronger evidence.
- The dump attaches to that window: image dims + SHM segment stored per-window
  (xside.c:3899-3900, 3634).
- Composition prefers the window's own buffer: `do_shm_update` uses WINDOW-RELATIVE
  damage coords against the window's own image when `shmseg` is set (xside.c:2277-2290,
  blit at 2452-2453), and only otherwise slices `g->screen_window`'s image offset by the
  window position (branch xside.c:2292-2352, blit at 2454-2462).
- The Linux agent sends a per-window `MSG_WINDOW_DUMP` for every mapped window (set on
  map vmside.c:1032, sent on next damage vmside.c:379-381, also on configure-resize
  1178-1181 and reconnect 1677), fed by per-window X pixmaps under XComposite
  redirection (vmside.c:2737-2742; xf86-input-mfndev qubes.c:594-681).
- `MSG_WINDOW_DUMP_ACK` (protocol >= 0x00010007, qubes-gui-protocol.h:83-84) already
  provides the re-grant handshake needed on resize.
- **Lifecycle obligation the Windows implementation inherits:** on MSG_UNMAP the daemon
  releases a non-screen window's buffers (xside.c:3988), so the agent must re-send
  MSG_WINDOW_DUMP on every remap — minimize/restore costs one re-dump + re-grant
  (~5 ms at 1080p, §3). The Linux agent's dump-on-map logic is the model.
- R4.3: gui-daemon xside.c/xside.h byte-identical to master — applies to the user's
  dom0 unmodified.

## 3. Feasibility measurements

### Premise (Gate 0) — occluded content is retrievable: PASSED
`PrintWindow(PW_RENDERFULLCONTENT)` on a fully occluded window returned byte-exact
content 3/3 runs (100.0% match, occlusion asserted, negative control failed at 0.0% as
required). Even `flags=0` worked — DWM keeps a redirection surface per top-level window.

### WGC (Q4) — works, occlusion-independent; GPU-side and dirty-rect-less
`Windows.Graphics.Capture` is supported and delivered byte-exact occluded content 3/3.
- No `DirtyRegions` API on this build: WGC frames carry no damage info.
- `IsBorderRequired` absent: the system capture border around captured windows CANNOT be
  disabled on 19044. See §7 — this matters during the migration's mixed mode.
- Cursor exclusion available (`IsCursorCaptureEnabled`).
- Frames are GPU surfaces; CPU access requires staging copy + Map (priced below).

### The zero-copy question (the plan's Step 2 headline), answered plainly
Today's transport is zero-copy: the framebuffer is granted once and only dirty-rect
metadata crosses per frame; the agent's measured per-frame pixel-copy cost is ~zero
(damage extraction + send = sub-ms, PHASE1A-RESULT.md). **Per-window WGC capture
abandons that property.** Each damaged window costs a staging copy + Map + readback into
its granted buffer:

| surface | per-frame CPU cost (mapP50) | evidence |
|---|---|---|
| 800x600 | ~1.7-2.2 ms | K=1 and K=4, 3 rounds each |
| 1920x1080, full damage | ~8 ms | 2 rounds |

Cost scales with damaged AREA, not window count (constant per-window mapP50 from K=1 to
K=30). Delivery is DWM-paced at ~30 fps/window; aggregate throughput saturated at
~310-355 frames/s at 800x600 in single observations (n=1-2), with 30 concurrent windows
still streaming evenly at ~11 fps each (n=1). The DDA control on the same scene acquired
whole-desktop frames at ~24-32 acquire/s (median 31-36 ms).

Why the trade is still right, argued not assumed: (a) on a real desktop only a handful
of windows are damaged in any frame — the cost is per-DAMAGED-window, and idle windows
cost nothing once redelivery is filtered (hazard 1); (b) the cost eliminated is not CPU
but CORRECTNESS — the entire measured artifact class (menu corruption, drag debris,
z-order bleed, wobble clipping) cannot be fixed in the composited model at any CPU
price (OVERLAP-IN-MOTION.md, ARTIFACT-ZORDER.md); (c) worst case degrades smoothly
(even 30 animating windows kept streaming). If the user judges 2-8 ms per damaged
window per frame unacceptable on GPU-less guests, the honest alternative is staying
with the composited model and its artifacts — there is no measured third option.

### Two implementation hazards (both observed; causes noted honestly)
1. **Idle-window redelivery**: static, undamaged windows still received ~40 fps of
   frames (2 rounds). Cause not established (instrument-side effects were not ruled
   out); the design consequence stands regardless — with no DirtyRegions API the agent
   MUST diff per-window (or hash frames) to avoid burning ~2 ms x 40 fps per idle
   window and flooding the daemon with no-op damage.
2. **Session creation intermittently fails**: across identical 30-session runs,
   creation succeeded for 30/18/11/10/7/0 sessions before failing with 0x80070057
   (E_INVALIDARG — not an obvious resource code). The refusal is measured; its CAUSE is
   not established, and leakage by the probe itself has not been excluded. Fresh boot
   gave the best result (30/30). Consequence for the design: sessions must be
   long-lived, creation must be retried, and — because opened=0 WAS observed — the
   degraded mode for windows that cannot get a session is reversion to the legacy
   screen path (per-window fallback to PrintWindow at p50 ~18 ms is viable only for
   idle-tail refresh, not as a primary path).

### Grant budget (Q2) — ≥64 windows demonstrated; true ceiling not located
One ceiling run granted 64 windows simultaneously (232,425 pages ≈ 908 MB, sizes mixed
720p/1080p/4K) without hitting any limit — the probe's own 64-window cap ended the run,
so the REAL ceiling (Xen grant-table limits) was not located and remains an open item.
Grant cost ≈ 2.5 µs/page (p50: 2.6 ms @720p, 5.2 ms @1080p, 21 ms @4K); resize re-grant
of a 1080p window p50 ~5-7 ms (3 runs); revoke ~0.1 ms. The protocol bound
(MAX_GRANT_REFS_COUNT ≈ 98k pages/window) is far above realistic windows.
Caveats: guest-side numbers only — no dom0 consumer mapped these grants, so dom0-side
mapping cost is unmeasured; the ceiling arm is a single run.

## 4. Q5 — migration is incremental BY CONSTRUCTION

The daemon decides per-window, per-frame: window has own `shmseg` → own buffer;
otherwise → screen slice (xside.c:2277/2292). Any subset of windows can migrate; the
composited window-0 path keeps working for the rest. Natural rollout inside the agent:

1. Stage 1: per-window dumps for ordinary top-level windows only; fullscreen/exclusive
   surfaces stay on the DDA screen path.
2. Stage 2: widen to popups/override-redirect windows (small, high-frequency — menus are
   the worst artifact source and the cheapest buffers).
3. A config flag can force the legacy path for A/B and for regression escape.
4. Implementation must include the remap lifecycle (§2): re-dump on map, matching the
   Linux agent, and per-window diffing (§3 hazard 1) from day one.

Known cosmetic cost of the mixed mode on Win10 (§3): while ANY window remains on the
DDA screen path, the screen capture contains the undisableable capture border drawn
around every WGC-captured window, and screen slices can show it. Mitigations, in
preference order: capture via PrintWindow for the small legacy set instead of DDA;
suppress screen-slice damage in regions owned by migrated windows; or accept the border
during rollout behind the A/B flag. This must be resolved in stage-1 design review, not
discovered by users.

No flag day, no daemon coordination, reviewable in small PRs — matching upstream's
stated preference (qubes-issues #1861 context).

## 5. Q6 — placement ownership does NOT need to move

The feared protocol reversal (dom0 owning window position) is NOT required to kill the
artifact class. With per-window buffers, damage coords are window-relative: guest window
position affects only where dom0 places its (dom0-side) window, not which pixels belong
to it. Motion, occlusion and stacking disagreements stop corrupting content entirely.
`MSG_CONFIGURE` keeps flowing exactly as today, in both directions.

Resize: the guest side of a resize is covered by the existing WINDOW_DUMP_ACK handshake
plus a ~5 ms re-grant (§3). How a dom0-initiated resize reaches the guest today
(MSG_CONFIGURE vs `qubes.SetMonitorLayout`) was NOT analyzed this session and is listed
in §7 as an open item — it is the same question Phase 2B-resize needs answered anyway.

Host-owned placement remains a potential later optimization (it would eliminate
guest-roundtrip move latency), but it is severable, needs upstream design discussion,
and is deliberately OUT of this proposal.

## 6. Q7 — security review

- Same mechanism, same direction, same permissions: `XcGnttabPermitForeignAccess2`
  read-only grants from guest to gui-domain, exactly as the current single framebuffer
  grant (agent capture.c:528-537). No new IOCTLs, no new qrexec services, no policy
  change.
- dom0/gui-domain maps N smaller buffers instead of 1 large one. The daemon already
  sanitizes per-window dumps from Linux guests today (dims clamped xside.c:3894-3898,
  size check 3906-3914, grant-ref count bounded by MAX_GRANT_REFS_COUNT); the Windows
  agent becomes just another sender of already-parsed input. No parser paths are added.
- Guest influence on dom0 geometry is unchanged (MSG_CONFIGURE semantics untouched); the
  bordering/anti-spoofing model daemon-side is untouched (per CLAUDE.md 2A-chrome rule
  4, nothing weakens daemon-side borders).
- Resource pressure: N grants instead of 1, bounded by the daemon's existing per-window
  limits and the guest's grant table. A malicious guest could already grant maximal
  windows today; per-window capture does not extend what a guest may request, only what
  a benign agent does request.
- Net: no isolation-relevant change identified. Anything that would weaken isolation
  remains out of scope, period.

## 7. Costs and open items (honest list)

- **Zero-copy is abandoned** (§3): ~2-8 ms CPU per damaged window per frame on this
  GPU-less reference guest. This is the proposal's price; it buys correctness the
  composited model cannot provide.
- **Per-window diffing is mandatory** (§3 hazard 1) — idle-redelivery cause
  unestablished, consequence unconditional.
- **Session-failure degraded mode** (§3 hazard 2): retry + reversion to legacy screen
  path; opened=0 was observed and must be survivable. Root cause of refusals unknown.
- **Capture border in mixed mode on Win10** (§4): pick a mitigation at stage-1 review.
- **dom0-side mapping cost** of N segments: unmeasured from this qube; flag for the
  upstream design issue.
- **True grant ceiling**: not located (≥64 windows / ~908 MB demonstrated once).
- **dom0-initiated resize channel** (§5): unanalyzed; shared prerequisite with Phase
  2B-resize.
- **Cursor**: exclusion from capture works; who composites the pointer in per-window
  mode (dom0 cursor vs guest-drawn) needs one design decision — today's behavior is
  dom0-rendered cursor, which per-window capture does not disturb, but drag feedback
  drawn BY the guest (e.g. drag images) arrives via window damage and should be
  verified in stage 1.
- **Secure desktop / UAC / lock screen**: no capturable HWNDs exist there; the legacy
  screen path must remain available for those states (it does, by construction of Q5).
- **Layered / per-pixel-alpha windows**: historically weak under PrintWindow; WGC arm
  untested against them this session. Test in stage 1; fallback is the legacy path.
- **Multi-monitor**: untested; per-window buffers should make it EASIER (no desktop
  bounding-box slicing), but that is expectation, not measurement.
- **Win10 floor**: WGC needs 1803+; PrintWindow(PW_RENDERFULLCONTENT) (Win 8.1+) is the
  verified occluded-correct fallback for older guests.
- **DRM/protected content**: excluded from capture by Windows; legacy path fallback.
- **QWT 4.2.2 agent protocol version**: agent must negotiate >= 0x00010007 for
  WINDOW_DUMP_ACK; verify during implementation.
- **Measurement debts** (from the matrix crash + iteration budget): K=30 and the
  saturation figure rest on n=1; K=10 and 1080p on n=2; no static-scene DDA control was
  taken; the ceiling run is n=1. Rerun before quoting these numbers upstream as more
  than indicative.

## 8. Proposed next steps (all gated on user approval)

1. User reviews this document.
2. Optionally: rerun the n=1/n=2 cells above for a submission-grade evidence pack.
3. Upstream design issue (references #1861): summary of §1-§6 + the measurement tables
   with their stated scope, asking for concept-ACK on converging the Windows agent with
   the Linux per-window model.
4. Only after ACK: implementation phases per Q5, each with before/after artifact
   reproductions (ARTIFACT-ZORDER.md, ACCEPTANCE-PROTOCOL.md scenarios) as acceptance.
