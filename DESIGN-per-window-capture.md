# Design: per-window capture for the Windows GUI agent

Status: DRAFT for user review — terminal deliverable of SESSION-PLAN-per-window-capture.md.
Nothing here has been proposed upstream; per CLAUDE.md Phase 3, upstream contact happens
only after the user approves this writeup and the accompanying issue text.

Everything below is either measured in this repo this session (FINDINGS.md 2026-07-31,
instrumentation/perwin-*.txt) or cited to source with file:line. Q1 citations were
adversarially verified by three independent reviewers and checked byte-identical between
gui-daemon master (f66fb34c) and release4.3 (b996d00c).

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

## 2. Q1 — the daemon already does this (verified, dual-verified, R4.3-identical)

- Dispatch is per-window: `handle_message` resolves `hdr.window` via `remote2local` and
  hands the resolved window to `handle_window_dump` (xside.c:3942, 4025-4029). No window-0
  special case exists anywhere on that path (exhaustive: `FULLSCREEN_WINDOW_ID` appears at
  xside.c:455, 2066, 3988 only — none on the dump path).
- The dump attaches to that window: image dims + SHM segment stored per-window
  (xside.c:3899-3900, 3634).
- Composition prefers the window's own buffer: `do_shm_update` uses WINDOW-RELATIVE damage
  coords against the window's own image when `shmseg` is set (xside.c:2277-2290, blit at
  2453), and only otherwise slices `g->screen_window`'s image offset by the window position
  (xside.c:2292-2343, 2452-2462).
- The Linux agent sends a per-window `MSG_WINDOW_DUMP` for every mapped window (set on map
  vmside.c:1032, sent on next damage vmside.c:379-381, also on configure-resize 1178-1181
  and reconnect 1677), fed by per-window X pixmaps under XComposite redirection
  (vmside.c:2737-2742; xf86-input-mfndev qubes.c:594-681).
- `MSG_WINDOW_DUMP_ACK` (protocol >= 0x00010007, qubes-gui-protocol.h:83-84) already
  provides the re-grant handshake needed on resize.
- R4.3: gui-daemon xside.c/xside.h byte-identical to master — applies to the user's dom0
  unmodified.

## 3. Feasibility measurements (win-idd-test, Win10 build 19044, stock QWT 4.2.2)

### Premise (Gate 0) — occluded content is retrievable: PASSED
`PrintWindow(PW_RENDERFULLCONTENT)` on a fully occluded window returned byte-exact content
3/3 runs (100.0% match, occlusion asserted, negative control failed at 0.0% as required).
Even `flags=0` worked — DWM keeps a redirection surface per top-level window.

### WGC (Q4) — works, occlusion-independent, but GPU-side and dirty-rect-less
`Windows.Graphics.Capture` is supported and delivered byte-exact occluded content 3/3.
Constraints measured on this build:
- No `DirtyRegions` API (dirty-regions-api=0): WGC frames carry no damage info here.
- `IsBorderRequired` absent (border-api=0): the capture border cannot be disabled; harmless
  in pure per-window mode (nothing captures the screen), visible only in a mixed mode that
  still screen-captures.
- Cursor exclusion available (cursor-api=1).
- Frames are GPU surfaces; CPU access requires staging copy + Map (measured below).

### Cost numbers (Q3/Q4 quantitative — 3-run medians, full tables in FINDINGS.md)

Per-frame CPU price of WGC→system-memory (staging copy + Map + full readback):
**~1.8 ms at 800x600, ~8 ms at 1920x1080 — scales with AREA, not with window count.**
Delivery is ~30 fps/window (DWM-paced) up to an aggregate saturation of ~310-355
frames/s at 800x600 (30 concurrent windows still stream, evenly, at ~11 fps each).
The DDA control on the same scene: ~30 acquire/s for the whole 3440x1440 desktop,
acquire median ~31-36 ms.

Interpretation for a real desktop (a handful of windows actually changing at once):
per-window WGC costs a few ms per damaged window per frame, comparable to the existing
whole-desktop path, while eliminating the entire artifact class. Worst-case (30 windows
all animating) degrades throughput smoothly rather than failing.

Two hazards the implementation MUST handle (both measured, not hypothetical):
1. **No dirty rects + ~40 fps redelivery of UNCHANGED windows** → a naive loop burns
   ~2 ms x 40 fps per idle window. Per-window diffing (agent-side) or damage inference
   is mandatory. (The current agent already walks damage; per-window diffing against the
   previous frame in the staging buffer is the direct analogue.)
2. **Session creation is intermittently refused under churn** (0x80070057; observed
   opened=30/18/11/10/7/0 across identical runs, best on fresh boot). Sessions must be
   long-lived, creation retried, and failures fall back to PrintWindow
   (PW_RENDERFULLCONTENT: proven byte-correct occluded; p50 ~18 ms per 400x300 refresh —
   too slow as the primary path, fine as damage-driven refresh for idle/tail windows).

### Grant budget (Q2) — effectively unconstrained at per-window scale

64 windows granted simultaneously (232,425 pages ≈ 908 MB, sizes mixed 720p/1080p/4K):
no ceiling hit. Grant cost ≈ 2.5 µs/page (p50: 2.6 ms @720p, 5.2 ms @1080p, 21 ms @4K);
resize re-grant of a 1080p window p50 ~5-7 ms one-off; revoke ~0.1 ms. The protocol
bound (MAX_GRANT_REFS_COUNT ≈ 98k pages/window) is far above realistic windows.
Caveat (by construction): guest-side ceiling and latency only; no dom0 consumer maps these
grants during the probe, so dom0-side mapping cost is an open item for the design issue.

## 4. Q5 — migration is incremental BY CONSTRUCTION

The daemon decides per-window, per-frame: window has own `shmseg` → own buffer;
otherwise → screen slice (xside.c:2277/2292). Any subset of windows can migrate; the
composited window-0 path keeps working for the rest. Natural rollout inside the agent:

1. Stage 1: per-window dumps for ordinary top-level windows only; fullscreen/exclusive
   surfaces stay on the DDA screen path (which also preserves `capture.c`'s
   `DesktopImageInSystemMemory` model where it still applies).
2. Stage 2: widen to popups/override-redirect windows (small, high-frequency — menus are
   the worst artifact source and the cheapest buffers).
3. A config flag can force the legacy path for A/B and for regression escape.

No flag day, no daemon coordination, reviewable in small PRs — matching upstream's stated
preference (qubes-issues #1861 context).

## 5. Q6 — placement ownership does NOT need to move

The feared protocol reversal (dom0 owning window position) is NOT required to kill the
artifact class. With per-window buffers, damage coords are window-relative: guest window
position affects only where dom0 places its (dom0-side) window, not which pixels belong to
it. Motion, occlusion and stacking disagreements stop corrupting content entirely.
`MSG_CONFIGURE` keeps flowing exactly as today, in both directions.

Host-owned placement remains a potential later optimization (it would eliminate
guest-roundtrip move latency), but it is severable, needs upstream design discussion, and
is deliberately OUT of this proposal.

## 6. Q7 — security review

- Same mechanism, same direction, same permissions: `XcGnttabPermitForeignAccess2`
  read-only grants from guest to gui-domain, exactly as the current single framebuffer
  grant (agent capture.c:528-537). No new IOCTLs, no new qrexec services, no policy change.
- dom0/gui-domain maps N smaller buffers instead of 1 large one. The daemon already
  sanitizes per-window dumps from Linux guests today (dims clamped xside.c:3893-3897, size
  check 3906-3914, grant-ref count bounded by MAX_GRANT_REFS_COUNT); the Windows agent
  becomes just another sender of already-parsed input. No parser paths are added.
- Guest influence on dom0 geometry is unchanged (MSG_CONFIGURE semantics untouched); the
  bordering/anti-spoofing model daemon-side is untouched (per CLAUDE.md 2A-chrome rule 4,
  nothing weakens daemon-side borders).
- Resource pressure: N grants instead of 1. Bounded by the daemon's existing per-window
  limits and by the guest's own grant table; Q2 numbers below size the realistic budget.
  A malicious guest could already grant maximal windows today; per-window capture does not
  extend what a guest may request, only what a benign agent does request.
- Net: no isolation-relevant change identified. Anything that would weaken isolation
  remains out of scope, period.

## 7. Costs and open items (honest list)

- **Dirty rects**: WGC gives none on Win10 19044, and — measured, counter to the naive
  assumption — WGC KEEPS redelivering ~40 fps for windows with no damage at all. So
  option (a) "full-window damage per delivered frame" is NOT viable as-is: it would both
  burn CPU on idle windows and flood the daemon with no-op damage. In-guest per-window
  diffing in the staging buffer (b) is the required starting point; a cheap frame-hash
  short-circuit makes the idle case nearly free.
- **Staging copy**: per-frame GPU→CPU copy+readback is ~1.8 ms at 800x600 and ~8 ms at
  1080p on this (WARP, GPU-less) guest. It replaces the DDA full-desktop copy path, not
  augments it. On a guest with a real GPU this is expected to shrink; on this reference
  guest it is already comparable to the existing path's per-frame work.
- **dom0-side mapping cost** of N segments: unmeasured from this qube (no dom0 access);
  flag for the upstream design issue.
- **Win10 floor**: WGC needs 1803+; `PrintWindow(PW_RENDERFULLCONTENT)` (Win 8.1+) is the
  verified fallback for older guests — both proven occlusion-correct on this guest.
- **Windows that resist capture**: DRM/protected content, some exclusive-fullscreen
  swapchains. Fallback: legacy screen path per Q5 stage 1.
- **QWT 4.2.2 agent protocol version**: agent must negotiate >= 0x00010007 for
  WINDOW_DUMP_ACK; verify during implementation.

## 8. Proposed next steps (all gated on user approval)

1. User reviews this document.
2. Upstream design issue (references #1861): summary of §1-§6 + the measurement tables,
   asking for concept-ACK on converging the Windows agent with the Linux per-window model.
3. Only after ACK: implementation phases per Q5, each with before/after artifact
   reproductions (ARTIFACT-ZORDER.md, ACCEPTANCE-PROTOCOL.md scenarios) as acceptance.
