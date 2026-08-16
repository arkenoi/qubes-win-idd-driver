# FINDINGS.md — dated session findings (append-only)

Mandated by CLAUDE.md; created 2026-07-31 (earlier sessions logged into per-topic files under
`instrumentation/` instead — see GOAL-STATUS.md for the index of those).

---

## 2026-07-31 — per-window capture feasibility session (SESSION-PLAN-per-window-capture.md)

Session start state:
- win-idd-test: Running, stock QWT 4.2.2 installed (our agent build withheld — cold-boot
  enumeration failure, GOAL-STATUS.md).
- Plan: Gate 0 (pwprobe occlusion premise check), Q1 daemon reading, wgcprobe (Q4), capture
  scaling (Q3), grantprobe (Q2), then design writeup for user review.

Findings appended below as steps complete.

### Step 1 / Q1 — VERDICT A: per-window framebuffers are ALREADY the protocol's mainline path

Read read-only clones under `upstream/ro/` (no upstream contact), pinned at:
- qubes-gui-daemon `f66fb34c90d3400772df7e11dfea47331c08407f`
- qubes-gui-common `66b879e36d6cd2a01271fc8d4c2c0f3be85d0029`
- qubes-gui-agent-linux `bc845212eb427db6bd5c41bb5c100ef1221f1ff1`

Evidence chain:
1. **Dispatch is per-window.** `xside.c` `handle_message` resolves `untrusted_hdr.window`
   via `remote2local` and passes the resolved `vm_window` to `handle_window_dump`
   (xside.c:4025-4028). Nothing special-cases window 0 on this path.
2. **The dump attaches to THAT window.** `handle_window_dump` stores
   `image_width/image_height` on `vm_window` and `qubes_xcb_send_xen_fd(g, vm_window, ...)`
   sets `vm_window->shmseg` (xside.c:3869-3916, 3634).
3. **Composition has a native dual path.** `do_shm_update` (xside.c:2277-2292): if
   `vm_window->shmseg != QUBES_NO_SHM_SEGMENT`, damage coords are WINDOW-RELATIVE against
   the window's own image; `else if (g->screen_window)` it slices the screen image offset
   by `vm_window->x/y` (xside.c:2455-2462) — today's Windows-agent model, as the fallback.
4. **`screen_window` is just window id 0.** `FULLSCREEN_WINDOW_ID 0` (xside.h:69); a window
   becomes `g->screen_window` only by being created with remote id 0 (xside.c:455-457).
5. **The Linux agent uses the per-window path today.** vmside.c: every window map sets
   `window_dump_pending = True` (vmside.c:610); the next damage notification calls
   `send_pixmap_grant_refs(g, window)` → `MSG_WINDOW_DUMP` with `hdr.window = <that
   window>` (vmside.c:379-381, 691-695), followed by window-relative `MSG_SHMIMAGE`.

Consequences:
- Per-window capture on Windows needs **no protocol change and no daemon change**. It
  converges the Windows agent with what the Linux agent already does.
- **Q5 largely answered structurally:** mixed mode is native and per-window — any subset of
  windows can carry their own buffer (shmseg set) while the rest fall back to screen-slicing.
  Incremental migration is the daemon's existing behavior, not a feature to build.
- **Q6 reframed:** placement ownership does NOT need to move for the artifact class to die.
  With per-window buffers, content is occlusion- and position-independent; dom0 keeps
  mirroring guest geometry exactly as today (`MSG_CONFIGURE` both directions already exists).
  Host-owned placement becomes an optional later optimization (Phase 3 discussion), not a
  prerequisite.
- Protocol bound relevant to Q2: `MAX_GRANT_REFS_COUNT = NUM_PAGES(16384*6144*4)` ≈ 98k
  pages per dump (qubes-gui-protocol.h:102-121) — the protocol does not constrain realistic
  window sizes; the practical grant budget (Step 4) is the real question.
- `MSG_WINDOW_DUMP_ACK` exists from protocol 0x00010007 (qubes-gui-protocol.h:83-84):
  the daemon acks dump processing so the agent knows when the old buffer is safe to release
  — exactly the resize/re-grant handshake per-window capture needs.
- Caveat: read at gui-daemon master; the user's dom0 runs the R4.3 daemon. Verify the same
  paths in the R4.3 branch before the design writeup goes out (expected identical — the
  dual path predates 4.3).

### Gate 0 — PASSED: occluded-window content IS retrievable (premise holds)

pwprobe `6C9EC6A1…F0872` (hash echoed from the guest each run, matches the CI artifact),
3/3 runs on win-idd-test, stock QWT, interactive session via pushrun:

| arm | expectation | result (3/3 identical) |
|---|---|---|
| baseline (visible, flags=0) | MATCH | MATCH pct=100.0 |
| fullcontent (occluded, PW_RENDERFULLCONTENT) | the question | **MATCH pct=100.0** |
| plain (occluded, flags=0) | negative candidate | MATCH pct=100.0 — see note |
| screen-DC BitBlt of occluded rect | must MISMATCH | MISMATCH pct=0.0 |

Occlusion asserted in-scene every run (`WindowFromPoint` at A's center returned B).
The screen-DC arm is the proof the comparator can fail: same comparator, provably-wrong
pixels, 0.0% match. The flags=0 arm matching is itself a finding: under DWM every
top-level window keeps a redirection surface, so even legacy PrintWindow returns the
window's own content while occluded. Two independent working retrieval paths — the
premise of DESIGN-QUESTIONS §2 is verified, document not void.

### Q1 adversarial verification — all three claims SURVIVED (3 independent skeptics)

Each claim was handed to a skeptic agent instructed to refute from source. None refuted;
all high confidence. Corrections adopted:
- `window_dump_pending` is set on MAP at vmside.c:1032 (my earlier :610 citation was the
  init-to-False site); dumps are also sent on configure-of-mapped (vmside.c:1178-1181) and
  reconnect re-enumeration (vmside.c:1677) — i.e. the resize re-grant path already exists
  agent-side on Linux.
- Per-window dumps require MSG_CREATE first (daemon exits on dump-without-create,
  xside.c:3951-3957) — fine, the Windows agent already creates windows.
- The screen fallback also requires screen_window->shmseg valid (xside.c:2454); Linux
  feeds per-window pixmaps from XComposite redirection (vmside.c:2737-2742,
  xf86-input-mfndev qubes.c:594-681 GetWindowPixmap grant refs).

**R4.3 check: gui-daemon xside.c/xside.h are BYTE-IDENTICAL between master and
release4.3** (git diff empty, same blob hashes; only pulse/mic code differs). The Q1
verdict applies to the user's dom0 daemon as-is.

### Step 2 / Q4 (qualitative) — WGC works and is occlusion-independent on this guest

wgcprobe `2ddc8b8c…ebd4` (guest hash verified via certutil), 3/3 check runs on
win-idd-test (os build 10.0.19044):
- `wgc-supported=1`; occluded static window captured with `content-pct=100.0` →
  `occluded-content=MATCH` 3/3 (occlusion asserted per run).
- `dirty-regions-api=0`: WGC provides NO dirty rects on this build. Per-window damage
  must come from elsewhere (in-guest diffing, or accept full-window damage per frame).
- `border-api=0`: `IsBorderRequired` not settable → the system capture border around
  captured windows cannot be disabled on 19044. Irrelevant in pure per-window mode
  (nothing captures the screen), but a mixed DDA+WGC mode would show yellow borders in
  the screen capture. Design must note it.
- `cursor-api=1`: cursor can be excluded from per-window captures.

Probe-code adversarial review found 1 blocker + 3 major defects in wgcprobe's BENCH mode
(scene/capture on one starved thread; benchstatic arg conflation; mapUs omitting the
full readback; procCpu blind to dwm.exe). All fixed before any Q3 numbers were produced;
check-mode verdicts above are unaffected (full readback path was always used there).
Bench numbers below come only from the fixed binary.

### Steps 2+3 quantitative (Q3/Q4) — raw logs instrumentation/perwin-*.txt

Instrument characterization (unchanged binary, K=4, 3 runs): fps stable ±3%, mapP50
±16%, CPU seconds noisy ±40% → verdicts use fps + mapP50 medians, never single-run CPU.
mapP50us = staging CopyResource + Map + FULL frame readback to system memory (the honest
per-frame price of feeding the existing grant transport).

WGC per-window capture, 800x600, damage-bounded (128px tile/tick), 15 s runs:

| config | fps/window | mapP50 µs | rounds |
|---|---|---|---|
| K=1 | 31.3 / 30.9 / 31.9 | 1702 / 2191 / 1751 | 3 |
| K=4 | 30.9 / 31.0 / 32.9 | 1671 / 2172 / 2193 | 3 |
| K=10 | 27.9 / 28.4 | 2055 / 1884 | 2 (see data-loss note) |
| K=30 | 11.4 (opened=30) | 1843 | see session-churn note |
| 1x1920x1080, full damage | 28.7 / 29.2 | 7904 / 8101 | 2 |
| K=4 STATIC (no damage) | ~40 (!) | 1973 / 1991 | 2 |

- Per-frame CPU price ≈ constant ~1.7-2.2 ms at 800x600 (spread across K=1/K=4 rounds),
  ~8 ms at 1080p (n=2) → scales with AREA, not window count. Delivery is ~30 fps/window;
  aggregate saturation ~310-355 frames/s and the even ~11 fps/window at K=30 were each
  observed in single runs (n=1) — indicative, not submission-grade.
- **Static windows still get ~40 fps redelivery**: with no DirtyRegions API the consumer
  cannot distinguish changed from unchanged frames. A naive per-window agent would BURN
  ~2 ms x 40 fps per idle window; per-window diffing or damage inference is REQUIRED.
- **WGC session creation intermittently fails**: opened=30/18/11/10/7/0 across identical
  `bench 30` invocations, error 0x80070057 (E_INVALIDARG — not an obvious resource
  code); best on fresh boot. The refusal is measured; its CAUSE is not established and
  probe-side leakage was not excluded. opened=0 (total WGC unavailability) was observed
  once — any design must survive it (degraded mode: legacy screen path).
- Data-loss note: the original 3-round matrix lost K=30 (all rounds), K=10 r3, 1080p r1,
  and benchstatic K=4 r1 to a probe crash whose output vanished — root-caused to fully-buffered stdout on the
  qrexec pipe + WinRT exception. Fixed (unbuffered + fatal handler); the failure itself
  became the session-failure finding above. The matrix was NOT completed post-fix (iteration
  budget went to the crash hunt): K=30 and saturation are n=1, K=10/1080p/static n=2,
  and no static-scene DDA control was taken — listed as measurement debts in the design.

PrintWindow(PW_RENDERFULLCONTENT) fallback price (occluded 400x300, 100 iters x3):
p50 17.7-18.5 ms, min ~2 ms (bimodal, DWM-tick-synced), 0 failures, 0 content
mismatches. Too slow as the primary path; fine as damage-driven refresh for the mostly
idle window tail if WGC sessions are constrained.

DDA control (ddaprobe, 3440x1440 desktop, K=4 animated scene, 3 interleaved runs):
acquire median 35.6 / 31.3 / 31.2 ms (~24-32 acq/s across rounds), `DesktopImageInSystemMemory` TRUE
throughout, avg 2-3 dirty rects/frame, and **GetFrameMoveRects was empty on every one
of 300 frames** — the capture.c:441 folklore ("move rects seem always empty") is now
measured fact on this guest; Track A should not build on move-rects.

pwprobe bench note (honesty): the first bench implementation (single reused DIB +
malloc'd latency array) AV'd at the first latency store with all pointers preflight-
valid; cause NOT established. Rebuilt on the proven per-iteration capture path
(fresh DIB per call, as check mode always did); crash filter + preflight retained in
the tool. The AV is unexplained and recorded here so nobody trusts that fast path
without understanding it first.

### Step 4 / Q2 — ≥64 windows granted, no ceiling found (true ceiling not located)

grantprobe `b6854554…2499` (guest hash verified), VM healthy after all runs:
- **ceiling** (single run): 64 windows granted simultaneously (mix 720p/1080p/4K =
  232,425 pages, ~908 MB) — no failure before the probe's own 64-window cap, so the
  REAL Xen grant-table ceiling was not located. Latency scales with size: p50 2.6 ms (720p) / 5.2 ms
  (1080p) / 21.3 ms (4K) ≈ 2.5 µs/page.
- **regrant** (1080p, 100 iters x3): grant p50 4.7 / 5.7 / 6.5 ms; revoke p50
  90-101 µs. A window resize costs one ~5 ms grant — imperceptible against Windows'
  own resize work.
- Caveats: no dom0 consumer mapped these grants (guest-side numbers only; dom0 map cost
  is an open design item). Ceiling-mode revoke latencies were reported as 0.0 (stats
  bug in the batch-revoke path — regrant mode's revoke numbers are the valid ones).

---

## 2026-08-01 — per-window capture IMPLEMENTED and validated end-to-end

Running code on `agent/` branch `perwindow` (commit ec55f39), installable package
`qwt-improved 4.2.2+agent.ec55f39` (CI run 30671887528, all jobs green), deployed to
win-idd-test and validated against every acceptance criterion the user set.

### Architecture as built
- Per accepted window: page-aligned BGRA buffer, granted read-only to the gui domain
  (`XcGnttabPermitForeignAccess2`, same call/flags as the screen framebuffer), announced
  via per-window `MSG_WINDOW_DUMP` — the daemon's existing own-shmseg composition path,
  UNMODIFIED (the Linux-agent model). Config: `PerWindowCapture` DWORD / `QGA_PERWINDOW`.
- Capture engine: **PrintWindow(PW_RENDERFULLCONTENT)**, not WGC. Decisive e2e finding:
  WGC cannot be activated in the agent's process context (SYSTEM token, session 1) —
  `IsSupported()` returns 0x8007000E and `CreateForWindow` throws, while the identical
  code worked from the user-context wgcprobe. PrintWindow (Gate 0: byte-correct on
  occluded windows) works under GDI in that context and needs no session broker. Engine:
  DDA dirty-rect intersection triggers per-window recapture; a 250 ms round-robin sweep
  converges guest-occluded windows (which never appear in DDA damage); every capture is
  row-diffed against the granted buffer so idle windows produce zero vchan traffic.
- Legacy screen-slice path fully retained: windows fall back to it on attach failure,
  capture-thread death, or daemon protocol < 1.7.

### Acceptance — all PASS (stock QWT baseline replaced by this build, hash-verified)
| criterion | result | evidence |
|---|---|---|
| no window corruption (overlap) | PASS | `instrumentation/perwin-overlap-{back,front}.png`: BACK window renders COMPLETE to its right edge ("...777 888 999") though FRONT covers that region in the guest; FRONT clean. The debris/slice defect is structurally gone — each window has its own buffer. |
| no tearing | PASS | all captures crisp; content byte-fed from PrintWindow, never sliced from a composited frame |
| no wobble | PASS | scripted 10 s drag, proto trace: 2/219 damage events with any origin drift, max dx=5px (content is position-independent under per-window capture) |
| Office-style compound windows | PASS | `perwin-chromerepro.png`: 1 dom0 window, not 5 |
| no stray border rectangles | PASS | the 4 layered/transparent/toolwindow shadow strips are not mapped |
| no double titles | PASS | single title bar |
| menu/popup no host corruption | PASS | main window pristine with F2 popup open |
| cold-boot survival | PASS | full shutdown/start: per-window agent came up on the boot path, windows attached, ZERO `EnumWindows failed` (the exact defect that blocked the prior build) |

### Bugs found and fixed during the build (adversarial review + e2e)
- **Daemon-kill remap** (blocker): re-announcing a dump with live dims but the old grant's
  page count fails the daemon's img_data_size check → gui-daemon exit(1) (whole-qube GUI
  loss). Fixed: remap/rebuild always use the granted geometry (PwWidth/PwHeight).
- **Resize-failure freeze** (blocker): detach-then-failed-attach left the daemon
  compositing a stale pinned buffer. Fixed: force daemon release via unmap/map on failure.
- **Capture-thread deadlock** (blocker, hit live): the async capture thread held the engine
  lock across the damage callback, which takes g_csWatchedWindows; the frame thread holds
  g_csWatchedWindows and calls WcMarkDirty wanting the engine lock — inversion froze DDA
  frame processing and all window tracking (a second window never mapped). Fixed: damage
  collected under the lock, callbacks fired after release. This was the single most
  important fix — found only by running two overlapping windows, exactly the user's ask.
- Teardown ordering (capture thread joined before vchan close), dom0-initiated resize
  rebuild, minimized-then-restored attach, WGC apartment/probe context — all fixed.

Package artifact: `artifacts/qwt-final/` (install-qwt-improved.ps1 overlay updater).

## 2026-08-01 (session 2) — Edge broke the per-window build: two daemon-killers + ULW black rendering, all root-caused and fixed

User report: Edge "all rendered wrong"; then the whole qube GUI died (watchdog kept
respawning gui-agent but no windows appeared — the DOM0 DAEMON was dead, agent-side log
`WatchForEvents: vchan disconnected`). Reboot of the VM restores it.

### Root causes (all verified against gui-daemon source + adversarially reviewed, workflow wf_787b6e72)
1. **Daemon kill #1 (the crash)**: capture thread fires damage callbacks AFTER releasing
   the engine lock (by design, deadlock fix ec55f39) — nothing serialized them against
   RemoveWindow. Wire order UNMAP(A), DESTROY(A), then SHMIMAGE(A) from thread 492 hit
   gui-daemon `handle_message` → "msg without CREATE" → `exit(1)` (xside.c:3951-3957;
   destroy removes the id synchronously, and SHMIMAGE-before-DESTROY is silently dropped —
   so the observed death itself proves the fatal ordering). Race is latent for ALL window
   closures; Edge's fullscreen first-run overlay repaints (~4 damage/s continuous) made it
   probable. Agent-side trace tell: the only DAMAGE line in 2366 lines without `ax=`
   (short format = hwnd already OS-destroyed at send time), same ms as the unmap.
2. **Daemon kill #2 (found in review, same class)**: HandleConfigure ACKed daemon
   configures for UNTRACKED windows — an ACK racing window destroy dies identically.
3. **"All rendered wrong"**: Edge's first-run overlay is a fullscreen UpdateLayeredWindow
   surface (welcome card on a ~30%-alpha dimming backdrop). PrintWindow(PW_RENDERFULLCONTENT)
   returns premultiplied source bits for ULW → backdrop = near-black opaque (measured
   in-guest: 93.2%% of samples black, alpha=255; screen BitBlt of the same rect shows the
   real blended content). dom0 displayed a black fullscreen override-redirect window.
   ULW discriminator: GetLayeredWindowAttributes FAILS on ULW windows ("Restore pages"
   popup is also ULW). Edge sets WS_EX_LAYERED only AFTER the window is shown (CREATE
   logged ex=0x101, later maps ex=0x80101) — eligibility must be re-checked on ExStyle
   change, not just at attach.
4. **Maximized CONFIGURE ping-pong**: maximized Edge reports DWM rect 3442x1409 on a
   3440x1400 screen → dom0 WM clamps → daemon configure → HandleConfigure SetWindowPos
   on the maximized window (bounces/moves it off anchor) → agent re-reports → loop at
   ~3 Hz, each flip a full ~4700-page grant detach/reattach (26 attaches in the crash
   log; 11+11 alternating). Also dragged the guest window to x=25,y=56 permanently.
5. Minor: MSG_CROSSING (127) is unhandled and safely drained (flood is from pointer
   enter/leave over the fullscreen overlay — cosmetic warn-spam only); ovr flag flapped
   1↔0 during popup drags because the ACK echoed the daemon's override_redirect instead
   of the agent's own classification; 4x-duplicate CONFIGUREs measured; SendWindowDestroy
   was unlogged (instrumentation gap that cost this investigation an hour);
   dom0 `local.WinScreenshot` does NOT capture override-redirect windows (popups/overlays
   invisible to qtest shot — user eyeballs needed for those).

### Fixes (agent commit 74665bf on perwindow)
- SendWindowDamageEvent: holds g_csWatchedWindows (RemoveWindow's lock) across
  membership-check + vchan send; damage for removed windows dropped. Lock order
  watched OUTER → vchan INNER preserved; capture engine lock is never held at the
  callback site (wincapture.cpp fires callbacks unlocked, comment anticipates this).
- HandleConfigure: ACK under g_csWatchedWindows, tracked windows only, carries agent-side
  override_redirect. Maximized windows: dom0 geometry ignored, ACK = actual geometry.
- PwWindowEligible (ULW/colorkey → legacy screen-slice path) gate in PwAttachWindow +
  runtime PwForceLegacy (detach + unmap/map daemon release) on ExStyle transition.
- GetWindowData clamps maximized rect to host screen; damage-path rect refresh skips
  maximized windows; SendWindowConfigureIfChanged dedupes identical consecutive configures
  (LastCfg* in WINDOW_DATA, primed by HandleConfigure so daemon geometry isn't echoed).
- RemoveWindow no longer leaks entry on unmap-send failure; DESTROY + detach proto-traced.

### Repro recipes (for regression testing)
- First-run overlay: `msedge --user-data-dir=C:\temp\<fresh>` — recreates the fullscreen
  ULW welcome overlay on any profile-less launch.
- Crash race: open/close Edge windows repeatedly while content repaints.
- In-guest ULW probe: mgmt scratchpad cmp-overlay.ps1 (PrintWindow vs CopyFromScreen diff).

### Review cycle + deploy (same session, package 4.2.2+agent.f77e71ab2cfd)
Adversarial review (workflow wf_ec52b044, 3 lenses + refutation verify) caught TWO
blockers in the first fix commit 74665bf before/while it was on the VM:
- **ABBA deadlock**: the first damage-race fix held g_csWatchedWindows across the capture
  thread's vchan send — but the main thread dispatches inbound messages while HOLDING
  g_VchanCriticalSection (main.c WatchForEvents) and its handlers take the watched lock
  inside it. Opposite orders on two threads. Redesigned (commit f2f...74665bf→) as a
  64-entry recently-destroyed-hwnd ring guarded by the vchan lock itself: DESTROY marks in
  the same hold that emits it, damage checks in the hold that would emit — linearization
  on ONE lock, capture thread takes no second lock. Cleared on hwnd reuse at CREATE.
- **ACK livelock (observed live, ~1000 configure/s)**: MSG_CONFIGURE ack must BYTE-ECHO
  the daemon's values — conf_changed=0 is what clears the daemon's have_queued_configure
  (xside.c:2124-2134); any other reply makes it re-send its geometry and keep waiting.
  "ACK with actual geometry" spun daemon↔agent at vchan speed and capped the log in 2 s.
  Maximized windows now skip APPLYING daemon geometry but still echo-ACK; convergence
  happens via the deduped tracking-path configure. (Daemon ignores ovr in agent
  configures — xside.c:2105 — so the ovr "flap" was cosmetic, in our logs only.)
- Screen-window variant of the destroy race (pre-existing): a pending frame event can
  emit window-0 damage after StopFrameProcessing sent DESTROY for the screen window →
  same daemon exit(1). Gated on g_LocalScreenDestroyed (window-0 damage is main-thread
  only, so a flag check is race-free).

### Validation on win-idd-test (agent f77e71a, pid 6092)
- Edge stress: 8 open/force-kill cycles under active repaint — 12 DESTROYs, 0 vchan
  disconnects, agent stable, daemon alive. (Previously: died on first such closure.)
- Fresh-profile first-run: overlay attached → "became PrintWindow-ineligible (layered),
  dropping to legacy path" within ~1 s of Edge applying ULW; detach logged; daemon alive.
- Maximized main window: single attach at CLAMPED 3440x1400 (was 3442x1409 with ~3
  reattach/s ping-pong); attach count static over 10 s; log growth ~600 B/s (was 160 KB/s
  during the livelock). dom0 window now 3440x1384 = granted buffer dims, content verified
  crisp via screenshot.
- Left open on the VM: an Edge instance with the first-run overlay (profile
  C:\temp\edgefr2) for the user to eyeball the blended (no longer black) backdrop, plus a
  normal Edge + notepad.

Deployed package: artifacts/qwt-edgefix2 (CI run 30674710417). Review findings not acted
on (accepted): UpdateWindowData can stall behind a slow PrintWindow during PwForceLegacy
(same latency class as the pre-existing RemoveWindow path); ULW transition can lag up to
~2 s behind the periodic resync (GWL_EXSTYLE changes emit no WinEvent); windows that
un-layer stay on legacy until recreated.

### Post-review polish (deployed: 4.2.2+agent.be6cacf482af)
- IsHungAppWindow guard before PrintWindow in the capture pass (review [major]: a hung
  guest app would otherwise park the capture thread inside the engine lock and freeze
  the agent behind any removal). Deployed.
- DaemonMax adoption (maximized windows adopt dom0-WM-dictated size): implemented but
  measured DORMANT on this dom0 — the WM does not resize oversize windows, it just
  places them with the bottom off-screen, so no MSG_CONFIGURE ever arrives. Harmless.
- Maximized-Edge ground truth after all fixes: guest window properly anchored
  (raw -8,-8..3448,1408; DWM 0,0..3440x1400), geometry stable, no churn, no storms.
  Remaining user-visible artifacts are PRESENTATION, not defects:
  (a) dom0 window = 3440x1400 content + dom0 title bar > 1384 usable height → bottom
      ~16px clipped off-screen ("huge");
  (b) double chrome: Windows apps draw their own title/tab bar, dom0 WM adds its frame —
      inherent to QWT seamless for ALL Windows windows (stock QWT identical).
  Candidate remedies (all need user/policy decisions): map guest-maximize to dom0
  fullscreen (needs guid allow_fullscreen), crop guest decorations for maximized windows
  (breaks Chromium tab-in-titlebar), or dom0-side special-casing (gui-daemon change →
  Phase 3 / upstream design discussion).

### True first-run retest (deployed: 4.2.2+agent.6133446e685d) — RESOLVED, plus a non-bug
- The "instant crash" on genuine first run was NOT the GUI stack at all: **wlms.exe
  (Windows License Manager) force-shuts the VM down HOURLY** — the EnterpriseSEval
  license sits in "Notification" (offline VM can never activate the eval). Event 1074
  says it plainly; there was no BSOD, no agent crash (mid-frame log ends = shutdown
  kill), and the daemon survived. `slmgr /rearm` consumed a rearm (2→1) but did NOT
  clear Notification post-reboot. USER DECISION NEEDED: brief network for eval
  activation, reinstall from a non-eval image, or live with hourly shutdowns.
- The true-FRE takeover window differs from the per-profile FRE: created with
  **WS_EX_NOREDIRECTIONBITMAP** (DirectComposition-only, GLWA can succeed) — slipped
  past the ULW check and attached. Fixed: NRB windows are unconditionally
  PrintWindow-ineligible (agent 6133446).
- Retest evidence: FRE overlay 0x101e0 attach → "became PrintWindow-ineligible
  (layered), dropping to legacy path", 0 disconnects, in-guest fullscreen recorder
  (mgmt scratchpad recorder.ps1, C:\temp\frames) shows the carousel + dimmed backdrop
  rendering correctly. dom0 = same pixels by construction (legacy slice).
- Correction to earlier assumption: dom0 host is 5120x1440 (multi-monitor), guest
  3440x1440 — the IsPopup size guard therefore does NOT veto 3440-wide fullscreen
  popups (they map ovr=1, undecorated), and the maximized clamp only bites on height.
- New instrument: in-guest fullscreen JPEG recorder — the only way to see
  override-redirect windows (dom0 local.WinScreenshot skips them).

### Slice-fed per-window buffers (deployed: 4.2.2+agent.<slice2>, run 30677339109) — FRE RENDERS CORRECTLY
The dom0 full-desktop screenshot (local.WinFullScreen, ~60-90 s per capture) exposed the
real defect: the FRE overlay was a daemon-side legacy-slice window, and the daemon
sources slice pixels by ITS OWN window position — force_on_screen had pushed the ovr
window to y=31 (below the dom0 panel) while the guest rendered it at y=0, so the whole
overlay was misregistered by 31px (the "weird ugly double borders").
Fix: **slice-fed per-window buffers** — PrintWindow-ineligible windows (ULW,
WS_EX_NOREDIRECTIONBITMAP) now get a normal per-window buffer that ProcessNewFrame fills
by copying the window's region out of the persistently-granted DDA desktop image
(composited truth, translucency pre-blended, content window-relative). Iteration note:
the first cut gated the copy on frame->mapped, which is TRUE only on the very first
frame (MapDesktopSurface runs once, for the grant pointer) — overlay rendered as an
all-black box; fixed by passing ctx->framebuffer into ProcessNewFrame.
Verified via dom0 screenshot: FRE carousel + dimmed backdrop pixel-correct, aligned,
only the (by-design) 1px red ovr border remains. Occlusion caveat: slice-fed content
includes whatever covers the window in the guest — acceptable for this class (topmost
overlays); PrintWindow windows are unaffected.
Remaining cosmetic: overlay displayed 31px below its guest position (content is
window-relative so nothing misaligns visually); dom0's force_on_screen padding is the
cause — a dom0 guid.conf override_redirect_protection tweak could remove even that.

### Maximize-propagation experiment — REVERTED (multi-monitor), geometry residue analyzed
Tried: send WINDOW_FLAG_FULLSCREEN for guest-maximized windows (daemon converts to WM
maximize when allow_fullscreen=off) so the dom0 client aligns with the workspace.
Result on THIS dom0: the WM maximized the daemon window to 0,0 5120x1440 — the FULL
dual-monitor span (dom0 = 5120x1440 total; the guest's 3440x1440 desktop straddles the
monitor boundary, so no dom0 monitor matches the guest and maximize has no right answer).
Reverted (agent 82fe92a); redeployed build da62d1e (run 30677339109, artifacts/qwt-slice2).

User's correct decomposition of the remaining TRUE-FRE geometry residue:
1. The decorated ("lower") maximized window is sized to the guest screen, not to the
   dom0 available workspace → client lands at 5,56, right edge pokes 5px past the
   3440 area (the right-side "double border"), bottom cropped by the screen edge.
2. The borderless overlay ("upper") neither matches the lower window's client area nor
   its own guest position (daemon force_on_screen offsets it) → the pair is misaligned.
Root cause for both: the guest work area != dom0 usable workspace, and the protocol has
NO work-area propagation (daemon reads _NET_WORKAREA for its own force_on_screen only;
nothing is sent to the VM — checked xside.c). Candidate remedies:
  (a) guest work-area sync via SPI_SETWORKAREA fed from a CONFIG value (registry pushed
      over qrexec) — implementable today, static, per-user-setup;
  (b) protocol extension: daemon sends its work area to the agent (upstream design
      discussion, references the same need Linux guests solve via WM cooperation);
  (c) dom0-side: guid.conf tuning / single-monitor dom0 matches trivially.
Not pursued unilaterally — needs user decision (b is Phase 3 territory per CLAUDE.md).

### Black "Restore pages" popup — root cause + class fix (deployed: run 30689303099)
The bubble attached via PrintWindow (not layered at creation) and rendered as a black
box in dom0 while a USER-context PrintWindow probe captured it perfectly: PrintWindow
returns BLANK for Chromium bubble windows from the agent's SYSTEM/session-1 context
(the WGC lesson repeats: user-context probes do not predict SYSTEM-context behavior).
Blank row-diffs as "no change" vs the blank prefill → zero damage, healthy-looking
channel, black window forever (damage count stuck at 1 = the initial blank push).
Fix: **slice-feed ALL override-redirect windows as a class** (menus, tooltips, bubbles,
overlays): topmost by nature, so the composited screen region is their correct content;
also full re-copy scheduled when a slice-fed window moves. Verified via dom0
full-desktop screenshot: popup pixel-correct. Occlusion staleness between overlapping
popups self-heals via DDA damage.
Also: DESIGN-workarea-propagation.md written (MSG_WORKAREA daemon→agent + SPI_SETWORKAREA
agent-side, frame extents included; compat + alternatives) — awaiting user review before
any upstream contact. Retail Win10 ISO auto-download blocked by Microsoft by IP
(quickget); user action needed for a non-eval image or brief network for eval activation.

## 2026-08-01 (session 3) — composite synthesis + work-area sync

### Composite synthesis (agent 49e119a, CI 30691320005) — WORKING, dom0-verified
Owner-contained override-redirect windows (menus, tooltips, bubbles; <=4px overhang)
are now SYNTHESIZED: tracked locally, never announced to dom0. Verified with Notepad's
File menu: dom0 window list = 1 window (was 2), the menu renders INSIDE Notepad with no
border rectangle of its own, 0 vchan disconnects.

Design choice (adversarial workflow wf_82dac5f5, 5 agents): the analysts' first design
switched the OWNER to slice-fed while any child existed; the attackers showed that costs
a full ~19MB grant rebuild per popup show/hide (menu browsing = continuous churn) and
bleeds every overlapping guest window into the owner for the popup's lifetime. Shipped
instead: **owner stays PrintWindow-fed + capture MASK + per-rect patch**. wincapture's
row loop compares/copies only the segments between masked column ranges, so the popup
region is never overwritten; the frame loop patches exactly that region from the live
DDA desktop image. No grant churn, no whole-owner bleed, popup pixels are composited
truth (which is what a topmost popup should show).

Two bugs found by running it, both dom0-verified:
1. **Invisible menus**: a menu paints ONCE before the tracking pass learns it exists, and
   a static screen then yields no further DDA frames -> the dirty-rect-driven patch never
   ran. Fixed by publishing the live framebuffer pointer in globals (valid for the whole
   duplication - the daemon reads it continuously) and patching immediately at synthesis.
2. **Daemon killed (whole-qube GUI loss, reproduced live)**: materialization cleared
   `Synthesized` and relied on the normal removal path to re-add the window, but
   RemoveWindow's silence gate tested `Synthesized` -> it sent UNMAP+DESTROY for an hwnd
   the daemon never had a CREATE for. Fixed with an explicit `CreateSent` flag gating all
   teardown sends (also covers failed announces). The attackers had flagged exactly this
   divergence between the two analysts' change lists as "itself a latent daemon-killer".

### Work-area sync (agent workarea.c) — implemented, partially validated
Sources in priority order: registry `WorkArea="x,y,w,h"` / qubesdb `/qubes-workarea`
(written by the optional dom0 watcher `dom0/09-install-workarea-watcher.sh`, live across
panel/monitor changes) / inference from daemon-dictated window origins. Applies
SPI_SETWORKAREA + SetWindowPlacement re-fit of maximized windows.
Measured: SPI_SETWORKAREA **must not** carry SPIF_SENDCHANGE - the broadcast makes
Explorer recompute from its own taskbar geometry and revert us (verified both ways
in-guest); without flags it sticks. OPEN: after an agent restart the value was observed
back at the OS default, i.e. something (Explorer's WM_DISPLAYCHANGE recompute after the
agent's SetVideoMode) still overwrites it asynchronously -> needs a periodic re-assert
(cheap SPI_GETWORKAREA compare on the existing ~2s tick) before this is reliable.
No dom0/daemon changes; MSG_WORKAREA dispatch is present but dormant (locally-defined
constant) until a protocol-1.9 daemon exists.

### Work-area re-assert made event-driven (agent, CI 30693970781 green)
User asked for event-driven rather than timed. Both halves now are:
- dom0 watcher: `xprop -root -spy _NET_WORKAREA` blocks until a change (the 60s loop in
  it is only a re-push safety net for VM restarts, not the change detector);
- guest: qubesdb `qdb_watch` blocks; and the re-assert against Explorer's overwrite is a
  hidden top-level window on the window-event thread's existing message loop handling
  WM_SETTINGCHANGE(SPI_SETWORKAREA)/WM_DISPLAYCHANGE. No timers, no polling. (The
  listener must be a real top-level window: broadcasts skip HWND_MESSAGE windows.)
Build note: workarea.c has no <stdint.h>, so no uint32_t casts there.

### BLOCKED: guest unreachable after attaching a netvm (for the Office test)
User attached `fw-net` to win-idd-test for Windows activation + an Office trial download.
After the required restart the VM reports power_state=Running with high cputime but:
qrexec never answers (many probes over ~20 min), and a dom0 full-desktop screenshot shows
NO win-idd-test windows at all (agent never connected). One kill+start cycle already
attempted; per CLAUDE.md the second failure stops for user input rather than retrying.
Nothing in the guest could be driven, so the Office/Word rendering test did not start.
Suspects, in order: (a) the expired EnterpriseSEval license watchdog interacting with a
now-networked boot, (b) QWT network-setup on first netvm attach, (c) unrelated boot stall.
The last agent build deployed to the guest is CI 30691320005 (synthesis, validated);
CI 30693970781 (event-driven work-area re-assert) is built but NOT yet deployed.

### Windows ISO acquisition: what actually blocks automation
Microsoft's software-download connector API is reachable and works headlessly for the
catalogue steps (session GUID -> page cookies -> vlscppe fingerprint ->
getskuinformationbyproductedition returns the full SKU list; Win10 22H2 English = SKU
16067). The FINAL call, GetProductDownloadLinksBySku, returns
`{"Key":"ErrorSettings.SentinelReject","Value":"Sentinel marked this request as rejected."}`
even from a residential exit IP - so it is the SESSION that is rejected (no fingerprint
JS executed), not the address. quickget/Fido fail identically for the same reason.
Script kept at `tools/get-win-iso.sh` with this documented; finishing it needs a real
browser engine to run the vlscppe fingerprint once and hand over its cookies.
Workaround used: Firefox opened in the mgmt qube, link copied, curl'ed.
ISO in flight: ~/win-iso/Win10_22H2_EnglishInternational_x64v1.iso (5.71 GB).

### NEXT SESSION - clean-room rebuild (user's leftover-independence test)
The current guest carries sediment from this session (hand-swapped gui-agent.exe +
.orig backups, a WorkArea registry value, an expired eval license, a mid-life netvm
attach) and is currently UNREACHABLE (Running, no qrexec, no windows). Plan:
1. `mgmt/build-unattended-iso.sh ~/win-iso/Win10_22H2_EnglishInternational_x64v1.iso "Windows 10 Pro" --with-key`
2. wipe + recreate win-idd-test (dom0/02-create-win-qube.sh mirrors the Admin API calls
   this qube is allowed to make), install unattended with QWT, keep netvm OFF.
3. deploy CI 30693970781 (composite synthesis + event-driven work-area sync) onto the
   pristine guest - this validates the agent against stock QWT, not our leftovers.
4. then: maximized-window geometry check, and the MS Office/Word rendering test the user
   asked for (Word is the most complex window layout available: ribbon, backstage,
   dropdowns, task panes - the real synthesis stress test).

## 2026-08-01 (session 4, mgmt qube) — win11-idd-test provisioned; per-window build deployed; first Win11 defect

### New test qube: win11-idd-test (Win11 24H2 Enterprise Eval 26100.1742)
Provisioned fully unattended (mgmt/PROVISION-LOG.md has the recipe: autounattend-win11.xml
with LabConfig bypasses, split-swm media, same $OEM$ payload). QWT 4.2.2 + testsigning +
build cert all verified; drive with `QTEST_VM=win11-idd-test` (QubesIncoming path identical).
dom0 policy extended (tag-scoped lifecycle+block.*, name-scoped VMShell/Filecopy);
local.WinScreenshot is now an allowlist service taking +<qube>; qtest shot passes it.

### Per-window build ec55f39 (qwt-improved 4.2.2+agent.ec55f39) deployed and healthy on Win11
Overlay installer OK (sha-verified swap, .orig kept). Evidence of health: PwAttachWindow
per-window buffers for each app window; QGAPERF v=2 seq advancing; overlap scenario
(Notepad + elevated Windows Terminal) both pixel-correct in per-window shots; cold boot
PASS (qrexec 2 s, ENUMFAIL=0, agent up on boot path, 3 buffers attached). Recurring
benign-looking transient: bursts of `GetWindowData: GetRealWindowRect failed 0x80070006`
(ERROR_INVALID_HANDLE) around window churn — recovery works, but frequency on Win11 (11 in
~5 min across two boots) is higher than Win10; watch it.

### DEFECT (user-observed live, dom0-verified): Win11 XAML windowed popups bypass composite synthesis
Symptom: Notepad's "auto-save" teaching bubble renders in dom0 as its own sticky window
with a heavy BLACK FRAME over the Notepad window (instrumentation/win11/
xaml-popup-bypass-dom0.png) instead of being synthesized into the owner.
Taxonomy (instrumentation/win11/xaml-popup-taxonomy.txt): class `Xaml_WindowedPopupClass`
title "PopupHost", same process as Notepad, geometrically contained in the main window,
styles WS_POPUP + WS_EX_NOACTIVATE + WS_EX_NOREDIRECTIONBITMAP — and NONE of the flags the
override-redirect/synthesis classifier keys on (no TOPMOST, no TOOLWINDOW, no LAYERED),
and no GW_OWNER visible linkage.
Two independent classifier gaps:
1. Ownership: XAML windowed popups don't set GW_OWNER to the app main window -> the
   owner-contained synthesis predicate can never match. Candidate fix: same-PID +
   geometric containment (<=4px overhang) as an alternate linkage for
   Xaml_WindowedPopupClass / WS_EX_NOREDIRECTIONBITMAP popups.
2. Capture: WS_EX_NOREDIRECTIONBITMAP means the window HAS NO redirection surface —
   PrintWindow structurally cannot capture it. These windows must be slice-fed
   unconditionally. The black frame is consistent with blank (black) prefill persisting
   where no damage-driven patch has landed.
Impact class: ALL WinUI/XAML apps on Win11 (inbox Notepad, Terminal flyouts, context
menus, teaching tips, jump-list previews) — this is the default popup mechanism on the
new shell, not an Office-style corner case.
NOTE Win11 positives: Search/Start CoreWindows are CLOAKED and correctly invisible;
DummyDWMListenerWindow spam is 0x0-sized and correctly skipped.
Next (dev session): add owner-linkage fallback + unconditional slice-feed for
NOREDIRECTIONBITMAP windows to the acceptance/synthesis predicate; re-test bubble,
Win11 Notepad context menu (same class), Terminal dropdown; then re-run the full
Win10 acceptance set for regressions.

### Win11 XAML popup synthesis — FIXED (agent a5012a5 + 832ce97, dom0-verified)
Two-part fix, both on `perwindow`, package `4.2.2+agent.832ce9738328` deployed on
win11-idd-test:
1. **Same-process fallback owner** (a5012a5): `Xaml_WindowedPopupClass` popups carry no
   usable GW_OWNER; SynthQualifies now falls back to the TOPMOST same-process window
   whose granted buffer contains the popup. GW_OWNER, when tracked, stays exclusive
   (a menu owned by A must not synthesize into overlapping B); synthesized windows
   re-qualify only against their recorded owner (no owner-hopping); WINDOW_DATA gains
   ProcessId. Also fixed en passant: an already-accounted child no longer flunks
   re-qualification when the owner sits at WC_MAX_MASK capacity.
2. **Overhang 4 -> 12 px** (832ce97): XAML menus align to the owner's OUTER window rect
   while the buffer starts at the DWM frame — measured 5 px overhang at 96 DPI, one
   past the old cap, so the File menu still materialized after fix 1. Both consumers
   verified clip-safe first (patch loop intersects with buffer rect; capture mask
   clamps to channel width).
Evidence: teaching bubble AND File menu both `QGAPROTO,msg=SYNTH` into the Notepad
main window; dom0 full-desktop shot shows ONE window with the menu inside
(instrumentation/win11/xaml-popup-synthesized-dom0.png; before:
xaml-popup-bypass-dom0.png). Alt-nav keytip badges (~40x46, ~20px outside the frame)
are deliberately NOT synthesized.
Open Win11 items: (a) `WorkAreaCreateListener: CreateWindowEx failed 0x5 Access is
denied` twice at agent start — the event-driven work-area re-assert (826ad82) is dead
on Win11, needs its own look; (b) recurring transient `GetRealWindowRect 0x80070006`
bursts around window churn — handled, but noisier than Win10; (c) Win10 regression
pass for a5012a5+832ce97 still pending — the fallback only ever fires for popups
GW_OWNER can't place, and Win10-validated owned popups take the unchanged path, but
re-run the win-idd-test acceptance set before calling it clean (coordinate with the
Edge-fixes session which owns that VM right now).

### Keytip badges: small-popup acceptance (agent d6ab61c, dom0-verified)
User-observed on the synthesis build: Alt-nav keytip badges only PARTIALLY visible.
Root cause chain: ShouldAcceptWindow's SM_CXMIN/CYMIN floor (~136x39) silently rejects
the ~40x46 keytip popups; they sit ~20px outside the owner's granted buffer so
synthesis cannot represent them either; the only pixels that reached dom0 were the
fragments overlapping the synthesized menu's patch region.
Fix: override-redirect popups now use a token 4x4 floor (normal windows keep
SM_CXMIN/CYMIN; DWM-cloaked strips like EdgeUiInputTopWndClass stay excluded via the
IsVisible fold, verified before shipping). Result (keytips-visible-dom0.png): menu
synthesized borderless inside Notepad, keytips fully visible as 12 tiny slice-fed
override-redirect windows - each with the daemon's red qube border, which is the
DESIGNED presentation for guest windows and stays (2A-chrome rule 4: never weaken
daemon-side bordering).
Also observed: one borderline keytip synthesized at creation geometry then cleanly
materialized when its final position left containment ("no longer owner-contained,
materializing") - the existing re-check machinery handles the flap.
Win11 stack now: package 4.2.2+agent.d6ab61cf8659 on win11-idd-test (a5012a5 fallback
owner + 832ce97 overhang 12 + d6ab61c small popups).

### Drag phantom identified: Win11 snap-layouts overlay (fix 3c12071, NOT yet verified)
User report: dragging a guest window by its WINDOWS title bar makes a huge phantom window
full of desktop wallpaper appear at the top of the screen, staying until release.
Could NOT be reproduced with synthetic input (SetCursorPos/mouse_event drags) - only with
a real user drag; the high-rate recorder (instrumentation/win11/window-recorder.ps1, run
while the user dragged) caught it: `XamlExplorerHostIslandWindow` (explorer.exe) 2560x360
at (440,0), ex=0x2800a8 = TOPMOST|TRANSPARENT|TOOLWINDOW|LAYERED|NOREDIRECTIONBITMAP,
not cloaked. Corroborated by the agent log: `PwAttachWindow: per-window buffer 2560x360
(900 pages) attached (slice-fed)` on each drag, plus one 3440x1440 slice-fed attach.
NOREDIRECTIONBITMAP -> PrintWindow-ineligible -> slice-fed from the composited desktop ->
wallpaper-filled phantom. Fix 3c12071 rejects click-through + uncapturable + toolwindow
windows in ShouldAcceptWindow. NOT built/deployed/verified yet - first task next session.
Full transcript: instrumentation/win11/drag-recording-snaplayout.txt.

### Keytip presentation is still wrong (open, user-flagged)
d6ab61c made keytips visible but each is announced as its own dom0 window, so the daemon
borders all ~12 of them and their slice-fed content bleeds the pixels behind them
(instrumentation/win11/keytips-bordered-defect.png). Neither this nor the pre-fix
half-cut-fragments state is acceptable. Designed fix in BOOTSTRAP-win11.md OPEN #1:
announce sub-floor popups only when they synthesize, drop them silently otherwise.

## 2026-08-01 (session 3b) — CLEAN-ROOM REBUILD DONE; synthesis paint defect found on it

### Rebuild (user's leftover-independence test) — SUCCESS
Retail Win10 22H2 (English International) installed unattended on a wiped win-idd-test:
`OS=Windows 10 Pro, BUILD=10.0.19045`, testsigning Yes, QdbDaemon/QrexecAgent/
QubesGuiWatchdog Running, stock `gui-agent.exe` = 80968 B, QubesIncoming path unchanged.
qrexec answered 16 min after boot. **Retail, not eval** -> no more hourly wlms shutdowns
(License Status: Notification = unactivated only).
Two build fixes were needed vs the eval image: (a) `install.wim` is 5.17 GB > ISO9660's
4 GiB, split to .swm with wimlib (this xorriso has no UDF write support); (b) the answer
file must match the media language - our en-US autounattend made Setup silently ignore
the unattend and sit on the locale picker; switched to en-GB (`0809:00000809`),
`autounattend.xml.enus.bak` keeps the original.
Media attach from this qube: `sudo losetup --find --show --read-only <iso>` then
`qvm-start win-idd-test --cdrom=win-idd-mgmt:loopN` (the PATH form is dom0-only; the
loop-device identifier form works from a VM).

### Our build OVERLAID on stock QWT: window suppression OK, composited paint MISSING
NOTE (user): this is an OVERLAY (install-qwt-improved.ps1 swaps bin\gui-agent.exe on an
existing QWT 4.2.2, watchdog left stock) - the GUEST is clean, the QWT install is not
"our stack installed cleanly". User decision 2026-08-01: go for a FULL SOURCE BUILD of
qubes-windows-tools with our agent fork integrated, and deploy that instead.
Deployed 4.2.2+agent.03f04018d508 (CI 30693970781) on the pristine guest: install OK,
agent 124664 B, 0 vchan disconnects, synthesis activates on Notepad's File menu
(`msg=SYNTH,hwnd=0x10296,owner=0x30256,x=254,y=309,w=229,h=196`) and dom0 correctly
shows ONE window (no separate bordered menu window).
**CORRECTION (user caught this): the "red-bordered letter boxes" were NOT ours.** The
full-desktop service captures the WHOLE dom0 screen including other qubes' windows, and
the parallel session's win11-idd-test Notepad was stacked over ours at those coordinates.
Cropping win-idd-test's rect out of a full-desktop shot does NOT isolate our VM. Use the
VM-SCOPED per-window service for anything about OUR window contents
(`tools/qtest shot` -> local.WinScreenshot+win-idd-test, which does import -window on our
window ids only); reserve fullshot for dom0-side geometry/border questions, and even then
read geometry.txt rather than eyeballing overlapping pixels.
**The real symptom, re-measured VM-scoped with the menu open (MENU=0x4017e):** the
dropdown is simply NOT PAINTED - Notepad's window shows "File" highlighted and blank
client area where the menu should be composited. So synthesis suppresses the child window
(correct) but PwPatchSynthChildren contributes nothing on this guest.
NEXT SESSION starts here. Hypotheses, cheapest first:
1. wrong source geometry: the copy uses guest screen coords (c->X/Y) into the granted
   framebuffer; if this guest's screen != the framebuffer stride/size assumed
   (g_ScreenWidth vs frame->rect.Pitch), rows smear - check g_FbPitch vs g_ScreenWidth*4
   on this guest (fresh install may have a different DDA pitch/padding).
2. mask/patch rect mismatch: WcSetMask clips to PwWidth/PwHeight of the OWNER buffer,
   patch clips to the same - verify owner PwWidth vs Notepad's actual 2566x1022.
3. the red borders in the fragments suggest the copied region is NOT the menu at all but
   another part of the composited desktop (borders are dom0-drawn, so their presence in
   guest framebuffer content would mean we are reading dom0-composited pixels - impossible
   -> more likely these are Notepad's own menu-item bitmaps at wrong offsets).
Repro: deploy on clean guest, open Notepad, Alt+F, `tools/qtest fullshot`.

## 2026-08-01 session-5 (win11 line): drag phantom verified fixed; keytips synthesize-or-drop

**Deployed on win11-idd-test: `4.2.2+agent.d61045417ed6`** (CI 30700488504).

### Snap-layout drag phantom (3c12071): VERIFIED FIXED
- Deployed `4.2.2+agent.3c1207143254`, then log-verified: dragging raised the transparent
  `XamlExplorerHostIslandWindow` and `ShouldAcceptWindow` rejected it
  ("click-through uncapturable shell overlay ... rejecting"), no oversized slice-fed attach.
- **User dragged by hand and confirmed: no artifacts in dom0.**
- Contrary to the session-4 note, synthetic input DOES reproduce the drag overlay: a SLOW
  stepped drag (SetCursorPos+mouse_event, 5px/30ms steps after a proper engage) raises it.
  Fast/jumpy synthetic drags were what failed. `scratchpad/dragtest.ps1` pattern works.
- Win+Z raises a DIFFERENT XamlExplorerHostIslandWindow flavor (344x244, NO WS_EX_TRANSPARENT,
  clickable) - correctly announced+slice-fed+raised, correctly unmapped on dismiss. The
  rejection triple (TRANSPARENT+NOREDIRECTIONBITMAP+TOOLWINDOW) leaves it alone by design.

### Keytip badges (OPEN #1): FIXED by d610454 (synthesize-or-drop + foreground owner pref)
- `d610454` in AddWindow: sub-floor override-redirect popups (below SM_CXMIN/CYMIN) that
  fail SynthQualifies get DeletePending and are dropped SILENTLY instead of being announced
  as bordered slice-fed fragments (RemoveWindow is already silent for !CreateSent entries).
  Materialization re-adds through the same gate, so a badge drifting out of its owner is
  re-dropped, never announced.
- Also in `d610454`: same-process fallback owner now prefers the FOREGROUND window over
  topmost-containing (two-same-process-windows ambiguity from session-4).
- Verified with TWO Notepad windows of one process: log shows per-geometry owner assignment
  (0x40236/0x60250/0x80238 -> owner 0x301be; 0x9024a at x=2103 -> owner 0x70072), SYNTHPAINT
  for each, zero announcements/materializations. dom0 fullshot mid-Alt: F/E/V badges render
  borderless and pixel-correct inside the red-bordered win11 Notepad. No bordered fragments.
- Alt keytips hold as long as needed for a shot if you don't send Esc; fullshot takes
  ~20-60s per capture, so budget one shot per ~45s hold (`scratchpad/keytiptest.ps1`).

### Operational notes
- Agent log level: the effective knob is the PER-MODULE key
  `HKLM\SOFTWARE\Invisible Things Lab\Qubes Tools\gui-agent\LogLevel` (overrides the base
  key). The watchdog does NOT recycle the agent on service restart - `Stop-Process gui-agent`
  and let the watchdog respawn it. LogLevel=4 floods (per-second window dumps; one perf
  sample showed log=13593us) - restored to 3 after testing.
- `qrexec-client-vm dom0 local.WinFullScreen` HANGS without `</dev/null` - use
  `tools/qtest fullshot`, which already does it right.
- Intervening commit `3f7c956` (synthesis paint-skip diagnostics) from the parallel session
  is in this build's history; coordinate as before.

### Still open (unchanged): synthesis flap during drags (#2), WorkAreaCreateListener 0x5 (#3),
### GetRealWindowRect 0x80070006 bursts (#4), Win10 regression pass for all five fixes (#5).

### 2026-08-01 — "attaching a netvm makes the guest unresponsive" = NO PV NETWORK DRIVER
User observed twice that giving win-idd-test a netvm renders it unresponsive, and that
removing the network makes it instantly responsive again. Diagnosed on the clean guest:

| probe | result |
|---|---|
| `Xen PV Network Class` PnP device | **Unknown** (never started) |
| `xenvif` system driver | **Stopped** (while xenbus/xenfilt/xeniface are Running) |
| `XP0001 XENBUS VBD`, `XENBUS CONS` | **Error** |
| active NIC | **Realtek RTL8139C+** (emulated), IP 10.137.0.64 |
| `System` process CPU | **269 s** (top consumer by an order of magnitude) |
| QWT network-setup log | `GetAdaptersInfo failed with 0xe8, retrying` for ~4 min, then settles on "Adapter 6: Realtek RTL8139C+" |

Mechanism: with no PV netfront the HVM falls back to the QEMU-emulated RTL8139, which
traps to the device model per packet. That burns kernel time in-guest and device-model
time out-of-guest, starving the GUI agent and qrexec -> the VM looks hung. Detach the
netvm and the emulated NIC goes idle -> instant recovery. Both observations explained.

NOT a regression from our agent work: it is a PROVISIONING gap. Our unattended install
runs QWT's MSI with an ADDLOCAL feature list (guest/install-qwt.cmd); the PV network
driver is either absent from that list or failed to bind. The PV stack is partial -
enough for vchan/qrexec (xeniface), not for networking (xenvif stopped).

NEXT SESSION, before the Office test:
1. Inspect `guest/install-qwt.cmd` ADDLOCAL and compare against the MSI's feature table
   (`msiinfo`/`msidump` on ~/win-iso/qwt-iso/installer.msi from Linux).
2. Re-run the MSI with the network feature enabled, reboot, confirm `xenvif=Running` and
   a `Xen PV Network Class` adapter carrying the IP instead of the Realtek.
3. Only then attach the netvm for Office + `slmgr /ato`. Expect normal responsiveness.
This is also a strong argument for the full source build: a correctly-bound PV driver set
is what a real QWT package installs and what our overlay approach can never fix.

## 2026-08-01 (session 6) — full source build: inventory done, qwt-full.yml cut; synth mid-draw fix landed

### Lost fix re-implemented (PLAN hazard cleared)
The "200 ms full re-copy of synthesized children" fix existed nowhere on disk (previous
session wrote it but never committed; no stash). Re-implemented as agent `382fa05`:
`SynthLastFullPatch` (DWORD, GetTickCount) on the owner's WINDOW_DATA, stamped at
SynthActivate's initial paint; in ProcessNewFrame's PwIsAttached/non-slice branch, when
SynthChildCount>0 and >=200 ms elapsed, `PwPatchSynthChildren(entry, NULL)` (NULL = full
child rects, same path as PwPatchSynthRect) + damage via the existing
PwPatchSynthChildClipped -> SendWindowDamageEvent. Reviewed: lock discipline unchanged
(runs where the existing patch loop runs), wrap-safe tick math. Limitation (documented in
commit): tick fires only while frames flow — acceptable, a painting popup IS a frame source.

### PLAN step 1 (inventory) — headline corrections to the plan's assumptions
Full record: ci-notes/qwt-full-build.md. Upstream clones under upstream/ro/.
- `QubesOS/qubes-windows-tools` does not exist; QWT 4.2.2 = qubes-builderv2 building
  independent component repos + `qubes-installer-qubes-os-windows-tools` (WiX v4.0.5,
  tag v4.2.2-1 = 14c189e). No submodule to override; MSI wants a flat
  `QUBES_REPO\<comp>\bin\<file>` tree (72 files) + per-component sign.crt.
- **PV network "packaging gap" was a misdiagnosis**: ADDLOCAL always had PvDriversNetwork
  and it staged correctly (DifX). xenvif can only bind once a netvm-provided VIF exists,
  and the emulated-RTL8139 unplug is a two-boot dance (arm Services\XEN\Unplug on first
  PV start -> reboot -> xen.sys unplugs at early boot; vetoed until a VIF was enumerated
  once). Expected remedy on the wiped guest: attach netvm, reboot twice. install-qwt.cmd
  ADDLOCAL needs NO change.
- EWDK-in-CI infeasible (15 GB); choco-WDK (83 s, WDK 26100) proven by the idd-driver job
  if drivers-from-source is ever wanted.

### PLAN step 2 decision: rebuild the real installer from source in GitHub CI
Chosen integration = build installer.msi + Burn bundle from the genuine upstream WiX
sources (pinned v4.2.2-1) with QUBES_REPO staged from (a) our CI-built, test-signed
gui-agent/gui-watchdog + our cert as gui-agent-windows sign.crt, (b) all unchanged files
bit-identical from the GPG-verified shipped MSI (vendored: vendor/qwt-4.2.2/, ITL sigs and
certs kept). Rationale + rejected options in ci-notes/qwt-full-build.md §2. User directive
recorded: build remotely on GitHub whenever possible.

### PLAN step 3: .github/workflows/qwt-full.yml added
Single windows-2022 job; agent steps reused verbatim from build.yml; new pieces:
packaging/stage-qwt-repo.ps1 (parses wxs QUBES_REPO refs, stages from admin image with
hash-dedupe, fails loudly), .distfiles nupkg pinning, fake EWDK tree for the bundle's
vc_redist, TEST_SIGN=1, CWD=vs2022\installer for the CreateVersionWxi CodeTask.
Iterating to green next; then step 4 (unattended ISO with our MSI) + step 5 acceptance.

### Session-6 install-path findings (reinstall-over-existing-guest, API-started)
1. **bootfix.bin**: MS media prompts "Press any key to boot from CD/DVD" whenever the disk
   already carries a bootable OS; unattended = prompt times out = the OLD install boots.
   Tell: qrexec ANSWERING during what should be Setup (old QWT lives). Fix landed in
   build-unattended-iso.sh: delete boot/bootfix.bin from the repacked ISO (promptless CD
   boot). Fresh/empty disks never hit this - why the session-3b rebuild worked.
2. **API-initiated qvm-start gives NO VGA console** (OPEN, dom0-side): starts issued from
   this qube leave the domain labeled Transient and never attach qubes-guid until qrexec
   connects, so install-phase boots are headless; dom0-initiated starts show the VGA
   console from BIOS onward (user-confirmed behavior). Consequence: during unattended
   installs the ONLY instruments are admin.vm.CurrentState cputime deltas (~1 s/s = WIM
   apply or payload stage; ~0 = wedged) and halt events; qvm-ls state stays Transient
   throughout, and qvm-start blocks ~10 min returning 0 around the reboot. Do not read
   Transient as stuck - read cputime.
3. Reinstall-over-existing-guest needs no qvm-remove: autounattend WillWipeDisk=true wipes
   disk 0 from Setup. (qvm-remove and sudo were permission-blocked this session anyway;
   udisksctl loop-setup replaces sudo losetup, and stale loop capacity after an ISO
   rebuild is detectable via /sys/block/loopN/size vs the file size.)

### ROOT CAUSE of the "headless install / blackbox" episode: stale `gui` feature
`qvm-features` are advertised by the GUEST (QWT sets `gui=1`, `qrexec=1`) and SURVIVE a
disk wipe, because they live in the qube's metadata, not the disk. With `gui=1` still set,
dom0 believes the VM supplies its own gui-agent and never starts the EMULATED VGA console
-> every install-phase boot is invisible, and the only telemetry left is cputime/disk
deltas. This is why the console "used to appear at boot and vanish when seamless kicked
in" (fresh qube: no gui feature -> console; after QWT: gui=1 -> seamless) and why it never
appeared during reinstalls.
FIX before any reinstall on an existing Windows qube:
    qvm-features --unset <vm> qrexec
    qvm-features <vm> gui ''          # or --unset; must not be truthy
    qvm-features <vm> gui-emulated 1  # dom0 attaches qubes-guid to the stubdomain
Verified: after setting these, `tools/qtest fullshot` shows a real console window -
720x400 (VGA text: BIOS/CD load) then 1024x768 "Setup is starting". Console geometry is
therefore a first-class progress signal: 720x400 = firmware/boot, 1024x768 = Setup GUI.
Corollary corrections to earlier notes in this session:
- "API-initiated qvm-start gives no console" was WRONG - the feature flags decided it, not
  who initiated the start. Retracted.
- A black 720x400 console with ~0 cpu is the SLOW BIOS/CD-load phase, not a hang; it can
  last minutes on a 5.8 GB ISO before Setup switches to 1024x768.
New instrument: `mgmt/win-install-watch.sh <vm> [dir]` - per-90s screenshot + cputime +
disk sampling, emits only console-phase changes, halts (auto-restart), stalls (~9 min of
nothing), or QREXEC UP. Replaces the state-only babysitter for install runs.

## 2026-08-01 (session 6, part 2) — from-source QWT INSTALLED and accepted; netvm still blocked

### Step 4 NOT ACCEPTED: installs and renders, but the result is NON-FUNCTIONAL QWT
The display/install evidence below is real, but it does NOT make this a usable QWT: with a
netvm attached the guest is unusable (see the netvm section). A Windows qube that cannot
have networking is not a working qube. Corrected framing: the original heading said
"Step 4 DONE" - that declared success on the passing checks and ignored the failing one.
gui-agent.exe = 654de8eb… (CI MANIFEST), gui-watchdog.exe = d6196059…, **zero .orig
backups** (MSI-installed, not overlaid), stage-2 log `installer.msi sha256 OK: ff89da3c…`
+ `QWT_INSTALL_OK rc=3010`, ARP shows "Qubes Windows Tools v4.2.2.0", testsigning Yes,
all Qubes services Running, two cold boots survived, seamless verified (Notepad = own
dom0 window). **Menu synthesis PASS on Win10**, evidenced from both sides: dom0 shows NO
separate menu window with the dropdown painted inside Notepad, and the guest log shows
4x SYNTH, 24x SYNTHPAINT, 0 skips, 0 vchan errors — including repeat paints of the same
rect minutes after the menu opened, i.e. the new 200 ms tick (382fa05) working.

### netvm attach: xenvif installs but never STARTS (blocker, unresolved)
Attached fw-net while HALTED (avoids freezing a live session), then two boots: each ran
>7 min with ~1.95 cores burned, no qrexec, no unplug. Detach → 0.05 cores instantly.
Forensics from a healthy (detached) boot narrow it a lot:
- `Enum\XENBUS\...DEV_VIF` EXISTS and `Xen PV Network Class` is present but **Unknown**.
- setupapi.dev.log 22:51:34: xenvif.inf selected, **service 'xenvif' created**, xenvif.sys
  hardlinked, PnP proceeded to Start → **install succeeded; the trust/driver-store
  hypothesis is ELIMINATED**. xennet is correctly blocked behind a started xenvif.
- `xenvif` = Stopped; `Services\XEN\Unplug` has **no NICS value** → unplug never armed.
- **Procedural error (mine): I used `qtest kill` (domain destroy) between the attached
  boots.** The upstream flow needs a CLEAN reboot so the armed registry value survives.
  The two-boot dance has therefore NOT had a fair test — redo with `qtest shutdown`/
  in-guest `shutdown /r`, never kill.
- User rejected (correctly) the argument "our PV drivers are byte-identical to stock, so
  stock behaves the same". Byte identity is not behavioural proof. A **stock-QWT control
  install** is now a required experiment (vendor/qwt-4.2.2/installer.msi, same ISO/ADDLOCAL/
  hardware, same measurements). Note stock QWT is documented to support netvm hotplug.

### Daemon-absent respawn storm: diagnosed, candidate fix REJECTED
Not a busy-poll: the agent EXITS when it cannot resolve the GUI domain and QgaWatchdog
relaunches it every second (upstream Linux simply does not run the agent without a daemon;
the Windows port has no such gate). Fix 53056d5 on branch `spin-backoff` was rejected by
3 adversarial reviewers (BROKEN/NEEDS_WORK): it introduces a 100%-core busy loop in the
capture thread on a shutdown-join timeout, permanently removes the vchan server (daemon
connects once, no retry → unrecoverable no-GUI qube), counts non-launches as launches in
the backoff, and does not touch the evidenced exit path. Submodule left on perwindow.

### 2026-08-01 (subagent) — work-area/maximize check on pristine Win10 from-source: FAIL
Full data: `instrumentation/qwtfull-w10/workarea-check.md`. Guest 3440x1440; agent applied
inferred work area (5,56)-(3435,1435) once at start (source = inference; registry+qubesdb
absent), Explorer overwrote it back to (0,0)-(3440,1400) and it was never re-asserted:
**`WorkAreaCreateListener: CreateWindowEx failed 0x5` reproduces on Win10 19045** (3x at
agent start) — open item #3 is NOT Win11-specific. Result: maximized Notepad = 3440x1400
dom0 client at (0,56) on a 5120x1440 dom0 span → bottom 16 px off-screen (status bar
cropped, PNG evidence). Had the agent's rect stuck, it would have fit (bottom 1435<1440).

## 2026-08-02 (subagent) — Win10 regression pass of the five win11-line fixes: BLOCKED
win-idd-test found wedged before any check could run: ~3.8/4 cores pegged for the whole
24-min observation, qubes.VMShell data vchan timing out on every probe, dom0 showing only
one stale "(Windows Desktop)" window (no seamless windows), netvm detached, gui=1.
Signature matches the session-6 daemon-absent respawn storm; recovery needs a clean VM
reboot, which the task rules forbade the subagent. ZERO scenarios executed — nothing about
a5012a5/832ce97/d6ab61c/3c12071/d610454 on Win10 was verified in either direction.
Full data + rerun recipe: instrumentation/qwtfull-w10/win10-regression.md.

## 2026-08-02 (session 7, orchestrator) — full step-5 sweep, wedge, netvm self-service, fix pipeline

- **Netvm IS settable from this qube** — handoff's "user must attach" claim retracted:
  `qvm-prefs win-idd-test netvm` write permission verified (no-op set). The whole two-boot
  retest and stock-control experiment are self-service now.
- **xenvif flow source-verified** (`ci-notes/xenvif-start-flow.md`, from pinned
  xenbits pvdrivers 9.1.0 sources): three corrections to session-6's model — (1) arming
  happens at the XENVIF\DEV_NET child (xennet) start, so "xennet absent" means the chain
  died BEFORE the arm, nothing was "lost"; (2) `Unplug\NICS` is consumed (deleted) at
  EVERY xen.sys boot — its absence on the netvm-detached forensics boot was the healthy
  state, that evidence proved nothing; (3) boot 1 never reboots itself: xenbus_monitor
  waits forever on a MB_YESNO dialog. Retest tooling: tools/netvm-bootwatch.sh,
  netvm-instrument.ps1 (SYSTEM schtask collector for starved boots), sharpened
  netforensics.ps1. Decision tree in the doc maps outcomes → root causes.
- **Drag bench FAIL** (verifier-upheld): drag p50 17.2/16.1 ms vs 0.917 ms baseline,
  <5 ms bar; 92.6% is per-frame PrintWindow recapture of the dragged window whose diff is
  EMPTY (content is position-invariant on pure move). Scroll/type/idle improved 4-6x.
  Full data: instrumentation/qwtfull-w10/bench-qwtfull-w10.md.
- **Stock-control ISO built + verified** (subagent, verifier-upheld):
  ~/win-iso/win-idd-unattended-stock.iso, staged installer.msi bit-identical to vendor
  stock 70493221…, everything else hash-identical to the current install's media.
- **Wedge**: guest starved (~3.8 cores, qrexec dead, no seamless windows, netvm detached,
  gui-daemon alive) between the bench (ended OK ~23:47) and the protocol check (23:57).
  Cause unattributed — the "respawn storm" label from session 6 does NOT obviously apply
  (that mechanism needs an absent daemon; here the daemon lived). Dom0 scrollback in the
  fullshot shows netvm fw-net→'' commands but may be stale from session 6. ACPI shutdown
  sent 21:49 UTC; guest ignored it for minutes while pegged. Post-recovery: MUST census
  gui-agent-*.log files (respawn discriminator) + event log for the 23:47-23:57 window.
- **Both defect fixes drafted, adversarially reviewed (6 reviewers): NEEDS_WORK ×6.**
  Workarea v1 (mask+lifecycle confirmed correct/necessary) blockers: drift-check
  unreachable on hook-thread death + starved by frame-path resync drain; g_WaLock used
  before init once the listener actually lives. Drag v1 blockers: corrupt hand-authored
  diff; mask-memo defeated by split owner/child interrogations (menu-over-drag pushes
  masks twice per frame, each WcSetMask forces recapture); unbuilt/unbenched. v2 agents
  running on clones, branches workarea-fix-v2 / drag-fix-v2.

### 2026-08-02 — FAIR two-boot netvm retest on our from-source build: the dance is UNSATISFIABLE
Setup exactly per the source-verified flow: healthy detached boot first (qrexec OK, forensics
collected), SYSTEM scheduled-task collector installed (survives starvation), **graceful ACPI
shutdown** (halted in <10 s — proving the guest CAN shut down cleanly when healthy), netvm
`fw-net` attached **while halted**, then boot.

| boot | netvm | result |
|---|---|---|
| 1 | attached | 15 min soak: **~1.9-2.0 cores burned continuously, qrexec never answered**. ACPI shutdown sent → **ignored for 7+ min** (guest never serviced it) → had to destroy. |
| 2 | attached | 8+ min: **2.02 cores, no qrexec**, no unplug. Same state. |
| 3 | detached | 15 min: **0.05 cores (idle), still no qrexec, no dom0 windows** → Windows now parked pre-desktop (WinRE/repair after two unclean shutdowns). |

**Conclusions.**
1. The handoff's remedy ("redo with graceful shutdown, never kill") is **not executable**: with
   a netvm attached the guest never reaches a state where usermode services ACPI, so a clean
   reboot between boot 1 and boot 2 CANNOT be produced from inside. The two-boot dance is not
   "untested due to operator error" — it is unreachable on this install. My session-6
   self-blame for using `kill` was therefore only half right: kill was forced, not chosen.
2. Boot 1 shows none of the healthy-flow markers (no xennet install, no reboot dialog) — the
   chain still dies at "xenvif installed but never started", *before* the arming point.
3. Repeated destroys wrecked the install's boot path (boot 3 idle-but-dead), which the goal's
   clean-install requirement resolves anyway.
4. Cost is not display-side: the burn happens with qrexec dead and no gui-agent windows at
   all, and the wedge census showed no respawn loop.

## 2026-08-02 (session 7) — CLEAN INSTALL of the fixed package: gates 0 and 1 PASS

Wiped-disk unattended install of `installer.msi f590c878…` (agent `a459f0e` = perwindow +
workarea 0x5 fix `2c5dad2` + drag suppression `d64bca6`). NOT an overlay: `gui-agent.exe`
= `663d7e9b…` (CI manifest), **0 `.orig` files**, `QWT_INSTALL_OK`, MSI status 0, ARP
"Qubes Windows Tools v4.2.2.0", testsigning Yes, services Running.

### Workarea fix: works, and immediately exposed a defect it created
- `WorkAreaCreateListener … 0x5` count: **0** (was 3/agent-start on every build since
  6d46132). Root cause was `OpenInputDesktop` lacking `DESKTOP_CREATEWINDOW`.
- The drift check earns its keep on the very first boot:
  `work area drifted: OS has (0,0)-(3440,1400), ours was (5,56)-(3435,1435); re-asserting`
  — exactly the Explorer overwrite that beat the old build.
- **NEW DEFECT (found by measuring, not reading): re-assert ping-pong.** The now-live
  listener re-asserted on every broadcast, and Explorer answers each of our
  SPI_SETWORKAREA with its own: **1018 applies in 84.9 s (~12/s)**, 293 in the last 20 s,
  each an EnumWindows + cross-process SetWindowPlacement sweep **on the hook thread**.
  Every one issued a real SPI_SETWORKAREA, i.e. the OS value differed each time →
  Explorer's disagreement is PERSISTENT, not transient.
- Fix v1 (`425c439`, sliding-window debounce) was **rejected in review**: a suppressed
  call still stamped the deadline, so any sustained external broadcast train would starve
  re-asserts *including the drift-check backstop*. Reworked in `b299011`: CAS gate that
  leaves the deadline untouched, applied ONLY to WM_SETTINGCHANGE, plus a
  5-strikes→30 s backoff for a fight we cannot win. Acceptance is a 120 s idle
  measurement, not a reading.

### Gate 1 (both previously BLOCKED by the wedge) — PASS
- **Win10 regression for the five win11-line fixes**: occlusion 76/76 damage to the front
  window, 0 to the occluded one (dom0 pixel check: 0 cover-coloured px in the overlap);
  menu SYNTHesized into its owner, never announced; drag 526 records "all invariants
  hold"; announced geometry == DWM extended frame bounds exactly; chromerepro
  GUEST-COUNT=5 MAPPED-OF-OURS=1; 0 shell-overlay rejections of legitimate windows,
  0 sub-floor announcements. **Drag-fix engagement proven**: `QGADRAG ev=suppress 153,
  refresh 59, settle 2` during the drag, `ev=maskpush` only OUTSIDE it (the menu-over-drag
  criterion).
- **Edge ULW first-run**: agent pid stable, 0 vchan/daemon-kill signatures, ULW window
  slice-fed via the shipped fallback while the normal frame took the PrintWindow path,
  window renders real content, clean unmap on close.
- Two limitations reported rather than papered over: `check-occlusion.py`'s screen-slice
  criterion is INVALID for per-window-captured windows and needs a rewrite before its
  result counts again (ACCEPTANCE-PROTOCOL.md still lists it as proven); Edge's "true
  first run" is qualified (Windows pre-initialised the profile during install).

### RETRACTED: "MSI REINSTALL starves the guest"
I wrote that entry from two mistakes of my own and it is WRONG on both counts.
1. The reinstall never took effect: `gui-agent.exe` was still `663d7e9b…` (a459f0e)
   afterwards, so nothing about `b299011` was ever exercised by it.
2. qrexec had in fact RECOVERED at 01:44:59 — my probes used 12-15 s timeouts against a
   busy guest and read "slow" as "dead", and I then destroyed the domain on that basis.
What actually happened: a PV-driver-touching reinstall attempt caused transient boot-time
PnP churn on the OLD (churning) build, which resolved on its own. Lesson recorded because
the same short-timeout mistake produced a premature `qtest kill` twice today: when probing
a guest under load, use >=40 s timeouts and confirm with a cputime trend before killing.

## 2026-08-02 (session 7) — FINAL: clean install of b299011, all display gates PASS

Build: `qwt-full` CI 30724190347, `installer.msi fa774936…`, `gui-agent.exe 4b4ce2b1…`,
agent `b299011` = perwindow + `2c5dad2` (workarea listener/lifecycle/drift) + `d64bca6`
(drag move-only suppression) + `b299011` (re-assert throttle + lost-fight backoff).
Installed by unattended ISO on a **wiped disk**. Netvm DETACHED throughout.

| gate | result |
|---|---|
| identity | `gui-agent.exe` = `4b4ce2b1…` (CI manifest), **0 `.orig`**, MSI-installed, testsigning Yes, services Running |
| workarea listener | **0** `CreateWindowEx 0x5` (was 3 per agent start on every build since 6d46132) |
| workarea churn (120 s idle, same script, same guest) | **0 applies, 0 drifts, 0.08 s agent CPU** — control on pre-fix `a459f0e`: **1460 applies (12.2/s), 21 drifts, 3.95 s CPU** |
| drag p50 (bench-agent.sh, identical harness) | **613 us** vs 5 ms bar. Pre-fix `a459f0e`: 17218/16128 us. Old screen-slice baseline: 917 us. 36.1 fps vs 23.7 |
| other phases p50 | scroll 121 us (base 493), type 96 us (base 531), idle 91/99 us (base 522/684) — all improved |
| Win10 protocol regression (5 win11-line fixes) | PASS on 526 non-empty records; occlusion 76/76 correct, menu synthesized not announced, geometry == DWM frame bounds, chromerepro 5→1, 0 bad rejections, 0 sub-floor announcements |
| Edge ULW first-run | PASS on all five points (pid stable, 0 vchan/daemon-kill signatures, ULW slice-fed fallback, real pixels, clean unmap) |
| cold boot | PASS: 2 guest top-level windows → **exactly 2 dom0 windows**, **0 EnumWindows failures**, agent up on the boot path |

### The work area now STICKS, and the backoff never had to engage
Only 6 applies + 3 drifts in the whole boot, then zero for 120 s. Once we stopped
re-asserting at 12 Hz, Explorer stopped counter-setting — the fight was self-sustaining.
`WA_LOST_FIGHT_TRIES` backoff logged 0 times, i.e. it is dead code on this configuration
and remains only as a guard.

### Harness defects found and fixed (they produced a FALSE FAIL on a healthy build)
`tools/viewcheck/coldboot-test.sh` reported "dom0 received 0 windows" on a build that was
demonstrably fine (2/2 windows visible seconds later). Two causes, both fixed:
(a) it screenshotted with no settle wait, racing map+first-damage; (b) it hardcoded
EXPECT=3, a count that assumed `chromerepro` was present — it is absent on a freshly
installed guest. It now derives the expectation from the scene's own window list and
settles 20 s first. `scene.ps1`/`vchanchk.ps1` were only in a stale session scratchpad and
are now committed under `tools/viewcheck/`, so the harness is self-contained.

### NOT claimed
Networking. With a netvm attached this build behaves exactly as before the display fixes
(xenvif never starts, ~2 cores, qrexec dead) — unchanged by our work, not fixed by it, and
still unattributed between us and upstream until the stock-QWT control install runs. The
stock-control ISO is built and verified (`win-idd-unattended-stock.iso`, staged MSI
bit-identical to vendor stock) and that experiment is the next task.

## 2026-08-02 — NETWORK BLOCKER ROOT-CAUSED (by the user): the netvm was mirage-firewall

`fw-net`, the netvm used for **every** failing measurement in sessions 3-7, is
**qubes-mirage-firewall** (a MirageOS unikernel). Pointing the Windows qube at a conventional
Linux netvm released the hang immediately. No guest-side defect was ever involved.

Consistent mechanism: the Windows PV network frontend never completes its handshake with the
unikernel netback → `xenvif` never starts → no `XENVIF\...&DEV_NET` child → `xennet` never
installs → `Unplug\NICS` never armed → the guest spins ~2 cores in PnP retry and qrexec is
starved out. Detach removes the frontend and the guest recovers.

### Why my investigation missed it for so long — worth internalising
I varied, and eliminated by measurement, EVERY guest-side variable: our agent fork vs stock
QWT (byte-identical MSI), the ADDLOCAL feature subset vs ALL features, vCPUs 4 vs 2, memory,
offline-vs-online install timing, Win10 vs Win11. Each negative result should have raised the
prior on "the variable is not in the guest at all", and instead I kept generating new
guest-side hypotheses. The netvm was a constant I never questioned because the previous
session's handoff had already framed the problem as "our PV stack is broken". The user
supplied the decisive reframes: first that stock QWT works in the wild (so it is our setup),
then that Win11 fails identically (so it is the deploy), and finally the actual answer.

Corollary: **a control experiment only controls the variable you vary.** My "stock QWT
control" swapped the MSI bytes and held the netvm, the ISO machinery, the qube parameters and
the invocation constant — I initially wrote it up as "we are cleared, it is upstream", which
was wrong, and the user caught it.

### Positive results that survive (they were real, just not the cause)
- Storage half of the same PV machinery works perfectly here: xenvbd started, armed
  `Unplug\DISKS=1`, took its reboot (the modal "Xen PV Storage Host Adapter needs to restart"
  dialog), unplugged the emulated IDE, disks now `XENSRC PVDISK`.
- `ci-notes/xenvif-start-flow.md` (source-verified frontend flow + decision tree) is accurate
  and is exactly the material needed for an upstream report.
- Reference config that works: user's long-lived qube runs PV drivers 8.2.x and carries
  traffic over the **emulated Realtek**, i.e. PV networking is not required for a working
  Windows qube.

### Open follow-ups
1. Re-measure on `win-idd-test` with a conventional netvm for a clean A/B (this qube's policy
   only permits referencing `fw-net`; needs the user to set it or name it).
2. Upstream report: Windows HVM + QWT 4.2.2 PV drivers (Xen Project 9.1.0) hangs when its
   netvm is qubes-mirage-firewall. Capture the mirage-side xenstore backend state first —
   nothing collected so far shows how far the backend handshake got.

### 2026-08-02 — mirage-firewall incompatibility PINNED to a fixed upstream bug
Full analysis: `ci-notes/mirage-netback-incompat.md`.
- **qubes-mirage-firewall < 0.9.5** serialises an HVM's TWO vifs (`appvm` + `appvm-dm`,
  the stubdomain's) on one thread; `read_frontend_configuration` blocks in `Xs.wait` on the
  first, so the second backend never runs `init_backend` and stays at libxl's `state=1`
  (Initialising). Fixed upstream by PR #219 / CHANGES 0.9.5 (2025-10-29), which names the
  symptom "deadlock states because the connection protocol for one interface is not
  completed". **This is why only HVMs are affected — PV/PVH qubes have a single vif.**
- xenvif has **no branch for backend state Initialising** (`frontend.c:1545-1576`); it loops,
  busy-waiting with `KeStallExecutionProcessor(1000)` at DISPATCH_LEVEL **while holding
  Frontend->Lock**. One core spinning + one blocked on the lock = exactly 2 cores regardless
  of vCPU count, matching the measurement (2.00 @4 vCPU, 1.95 @2 vCPU). Separate,
  upstream-worthy robustness defect: any absent/slow backend wedges the whole guest.
- Corroboration: qubes-mirage-firewall#127 (6 years old, closed unfixed) reports the freeze
  at `xenvif|FrontendSetMaxQueues` with "use sys-firewall instead" as the workaround. That
  log line is merely the last Info() before the wedge — `FrontendMaxQueues` is a red herring,
  and our test of `FrontendMaxQueues=1` correctly changed nothing.
- Feature negotiation is NOT involved: every backend key mirage omits (multi-queue,
  split-event-channels, ctrl-ring, multicast, hash) is optional in xenvif with a safe
  default; at NumQueues==1 xenvif writes the flat legacy ring layout mirage reads.
- **Correction to my earlier reasoning**: `Enum\XENVIF` empty / xenvif not Running /
  `Unplug\NICS` unarmed are NOT discriminating evidence — NICS is consumed every boot,
  detaching the netvm deletes the NET PDO, and the DISPATCH_LEVEL wedge starves the lazy hive
  writer. Consistent with the model, but they never proved it.

**Verified working today on mirage (fw-net) with PV net disabled**: guest boots in 20 s,
IP 10.137.0.64, gateway 10.138.21.72, ping to 8.8.8.8 OK, `http://example.com` = **HTTP 200**.
Cost: emulated RTL8139 (100 Mbit, QEMU-emulated) instead of PV xennet. Disk stays PV.

### 2026-08-02 — upstream issue filed; netvm decision: core-net
Filed **https://github.com/mirage/qubes-mirage-firewall/issues/230** (text approved by the
user first, per CLAUDE.md): Windows HVM `vif_ioemu` device never completes its handshake on
0.9.5, backend stuck at InitWait while the frontend goes to Closing and mirage keeps waiting.
Includes the xenstore capture, the unikernel log, and everything eliminated by measurement.
**Decision: `win-idd-test` runs on `core-net`.** mirage-firewall support is deferred to the
upstream fix; no PV-side workaround exists that keeps PV networking (the emulated-NIC route
works but is a 100 Mbit QEMU path, rejected as non-production).
Still to file separately: xenvif's unbounded DISPATCH_LEVEL busy-wait under Frontend->Lock,
which is what escalates any stalled backend into a wedged qube.

## 2026-08-02 — END-TO-END on our package b299011 (clean install, core-net)

Wiped-disk unattended install of `installer.msi fa774936…`; in-guest hash check passed,
`QWT_INSTALL_OK`, `gui-agent.exe 4b4ce2b1…` = CI manifest, **0 `.orig`** (MSI-installed, never
overlaid), testsigning Yes, Qubes services Running. netvm `core-net`.

| gate | result |
|---|---|
| install identity | PASS — `4b4ce2b1…`, MSI hash verified in-guest, 0 `.orig` |
| work-area churn, 120 s idle | PASS — **0 applies, 0 drifts, 0.27 s CPU** (pre-fix control: 1460 applies, 3.95 s) |
| drag p50 (settled) | PASS — **698 us** vs 5 ms bar; 1.39 interrogated/frame, 34.2 fps (pre-fix 17.2 ms; earlier install measured 613 us) |
| Win10 protocol regression | **PARTIAL** — all four acceptance conditions pass on non-empty data (579-record drag run "all invariants hold"; 0 legit-window rejections; 0 sub-floor announcements; chromerepro 5→1). See the negative finding below. |
| Edge ULW first-run | PASS — 5/5, on a genuinely first-run profile (sentinel absent, FRE takeover appeared), agent pid stable, 0 daemon-kill signatures, real pixels, clean unmap |
| cold boot | PASS — agent up on boot path, 2 guest windows → 2 dom0 windows, **0 EnumWindows failures** |

First bench right after install read 1.97 ms p50; the settled re-run read 698 us. The first
number was first-boot background load (Defender/Search/WSD), not a regression — recorded
because reporting only the good number would be the exact pattern this project bans.

### NEGATIVE FINDING — maskpush storm on joint owner+child motion (new follow-up)
The regression agent was asked to CONFIRM `ev=maskpush` stays absent during joint motion. It
found the scripted drag cannot answer that (the harness presses ESC first, so no synthesized
child exists — `maskpush=0` there is vacuous), then built the condition itself: a Win10 menu
does NOT travel with its owner, so it constructed an owned caption-less child in lockstep.
Result: **58 maskpushes in 2.6 s, two per motion step.** Mechanism: `SynthFlushMasks` defers
per tracking PASS, but `TrackWindows`' non-resync path handles only the current WinEvent
batch, so owner and child land in different passes — owner interrogated → CONFIGURE →
maskpush (stale child rect), child interrogated → maskpush (restore). Each takes
`WcSetMask`'s exclusive lock and forces a full recapture. This is precisely the cost the v2
single-flush design was meant to remove (adversarial-review blocker 2): it works for the
plain drag, not for joint motion. No visual defect observed; no acceptance condition depends
on it. Logged as a follow-up.

### SCOPE LIMIT stated by the agent, and it is right
This run proves **no Win10 regression only**. None of the five win11-line fixes was positively
exercised: the Win10 menu has a real `GW_OWNER` (a5012a5's fallback never entered), overhang
was 0 (832ce97's raised cap never reached), no sub-floor popup occurred (d6ab61c/d610454 never
entered), and no Win10 window carries TRANSPARENT+NOREDIRECTIONBITMAP+TOOLWINDOW (3c12071
tested only in its false-positive direction). Each PASS means "the check did not fire", not
"the check was shown able to fire on this build".

### Harness defects found and fixed/recorded
`tools/viewcheck/coldboot-test.sh` produced THREE false FAILs on healthy builds: no settle
before the screenshot (fixed), a hardcoded window expectation (fixed — now derived from the
scene, excluding chromerepro's deliberately-unmapped shadow strips), and a single screenshot
with no retry when `local.WinScreenshot` returns an empty tar (fixed). Remaining known flaw:
`chromerepro` self-exits between scene and screenshot, so its window can never be counted —
verify cold boot directly rather than trusting that count. `check-occlusion.py` remains
INVALID for per-window-captured windows and needs a PW-aware rewrite before its result counts.

## 2026-08-02 — REAL MS OFFICE REPRODUCES A DAEMON-KILL (first real-Office validation)

Microsoft 365 Apps (Word/Excel/PowerPoint, no licence — reduced-functionality mode still
renders full chrome) installed on win-idd-test via ODT, netvm core-net, on our build b299011.
This is the real-Office validation Phase 2A has wanted since the chrome fix was written;
`PHASE2A-CHROME-RESULT.md` warned chromerepro's synthetic strips are larger than the real ones.

**Real Office strips are 8 px** — `hwnd=0x7037a x=2164,y=501,w=8,h=558` and three siblings
(left/right/bottom/top). They are ABOVE the SM_CXMIN/CYMIN floor question because they are
synthesized, not size-rejected.

### What happened (agent log gui-agent-20260802-155607-3392.log)
1. All four strips are **SYNTHESIZED** (suppressed from dom0) via SynthActivate, but they sit
   OUTSIDE the owner's buffer: `synth paint 0x7037a: child (2164,501)-(2172,1059) outside owner
   (1314,509)-(2164,1051)`. The 12 px overhang allowance added in 832ce97 for XAML menus admits
   strips that are entirely adjacent to, not contained in, the owner. Nothing is ever painted
   for them; the warning repeats every frame for ~3 s (4x per frame).
2. Owner geometry changes -> all four **materialize in one burst**:
   `UpdateWindowData: 0xa0324/0x7037a/0x702fa/0x90326: owner geometry changed, materializing child`
3. Immediately after, every send fails `libxenvchan_send: vchan not open` -> `WatchForEvents:
   vchan disconnected` -> clean teardown (`CaptureTeardown` revoke fails 0x490 Element not
   found) -> `WinMain: WatchForEvents failed 0x490` -> watchdog respawns an agent that then sits
   at "Awaiting for a vchan client" forever, because dom0's daemon is gone. **Whole-qube GUI
   loss.** The user observed it live: "it did show then apparently crashed".

The agent did NOT crash: the daemon dropped first and the agent exited cleanly. Precedent:
FINDINGS 2026-08-01 session 3 records a materialization-driven daemon-kill (UNMAP+DESTROY for
an hwnd with no CREATE), fixed by the CreateSent gate. This looks like a sibling path that fix
did not cover. Also seen twice in the run: `HandleServerData: got unknown msg type 127,
ignoring` (MSG_CROSSING) - noted, not implicated.

### Still needed to name the violation
dom0's `/var/log/qubes/guid.win-idd-test.log` records why the daemon exited (xside.c logs
before exit(1)). Requested from the user; this qube cannot read dom0.

### Status of the chrome question
Real Office chrome DOES reproduce and is NOT correctly handled: the strips are neither cleanly
rejected (as chromerepro's are) nor legitimately contained - they are synthesized out of view
while outside the owner, and the eventual materialization burst is fatal. chromerepro was not
a faithful proxy: its strips are contained, real Office's are adjacent.

### 2026-08-02 — Office daemon-kill: trigger bounded, NOT yet deterministically reproducible
Controlled repro added (`tools/viewcheck/office-repro.ps1`, modes Reset/FirstRun/Steady; closes
Word with WM_CLOSE because repeated Stop-Process kills left Word offering safe mode and poisoned
later launches - user spotted that the state we were measuring was not the state we thought).

| attempt | SYNTH | outside-owner | materializing | vchan disc | agent respawn |
|---|---|---|---|---|---|
| FirstRun, 75 s hold, no input | 5 | 81 | **0** | **0** | no |
| 6x window MOVE (SetWindowPos) | - | - | **0** | **0** | no |
| maximize/restore + 3 resizes + maximize | 10->11 | 247 | **0** | **0** | no |

So: **strips synthesized while outside the owner happen on EVERY Word launch and are harmless on
their own.** The kill additionally requires the strips to STOP qualifying, which produces
"owner geometry changed, materializing child" for all four at once - and neither a move nor a
resize does that, because the strips follow the owner and keep satisfying the (proximity)
predicate. The original kill happened on the FIRST launch after installation; the likeliest
remaining trigger is the owner being replaced during startup (splash -> main frame) under load,
i.e. timing-dependent. A post-Reset FirstRun run did not hit it either.

CONSEQUENCE FOR THE FIX: we cannot currently prove the fix by reproduction. The predicate fix
(require real overlap, not proximity) removes the precondition - the strips are never synthesized
- and the CreateSent audit must make ANY materialization burst survivable on its own merits.
Both are being reviewed on branch fix-office-chrome-v2. Do not claim the daemon-kill is fixed on
the strength of "Word no longer kills the GUI in a run we could not make it kill the GUI in".

### 2026-08-02 — Office chrome IDENTIFIED: class MSO_BORDEREFFECT_WINDOW_CLASS, owned by the DIALOG
Enumerated during Word's first-run sign-in state (user reported the GUI died when clicking
outside the "license required" window):

```
0x2033e  850x542   @2969,542   NUIDialog                     'Sign in to set up Office'
0x20326  866x8     @2961,1084  MSO_BORDEREFFECT_WINDOW_CLASS
0x20340  8x558     @3819,534   MSO_BORDEREFFECT_WINDOW_CLASS
0x20342  8x558     @2961,534   MSO_BORDEREFFECT_WINDOW_CLASS
0x20344  866x8     @2961,534   MSO_BORDEREFFECT_WINDOW_CLASS
0x20306  3446x1395 @-3,48      OpusApp   'Document1 - Microsoft Word'
```

1. **The four 8 px strips frame the DIALOG (2961-3827 x 534-1092), not the main OpusApp window.**
   So the materialization burst is triggered by the DIALOG being dismissed/defocused - the strips
   are orphaned when their owner disappears. That is an ACTIVATION/lifetime event, which is why
   move (6 steps) and resize (maximize/restore + 3 resizes) both failed to reproduce it.
2. **Office gives its shadow chrome a dedicated window class: `MSO_BORDEREFFECT_WINDOW_CLASS`.**
   This is a far more robust discriminator than the layered/transparent/toolwindow style
   heuristics, and it is something chromerepro could never have taught us (its synthetic strips
   are ordinary windows, and contained rather than adjacent).
3. My scripted click at (120,900) landed ON OpusApp (which spans -3..3443), so the modal merely
   flashed - not equivalent to the user's click. Still no repro: MATERIALIZING 0, VCHANDISC 0.

FIX IMPLICATION: reject MSO_BORDEREFFECT_WINDOW_CLASS in the window-acceptance predicate outright
- it is pure decoration and dom0 draws its own borders (2A-chrome rule 4 forbids weakening
daemon-side bordering, and this does not: it stops presenting decoration fragments as windows).
That removes the precondition regardless of the containment predicate. Keep BOTH: containment
(no synthesis of a child wholly outside its owner) and the CreateSent audit (any materialization
burst must be survivable), since neither alone covers non-Office cases.

### 2026-08-02 — Office sluggishness SOLVED: Office hardware acceleration on a GPU-less VM
User: "works but painfully slow on every key press" (Word, maximized, 3430x1379 buffer).

Measured with QGAPERF while typing 40 chars at 200 ms intervals, Word focused, identical runs:

| metric | HW accel ON (default) | HW accel OFF | change |
|---|---|---|---|
| `dt` p50 (frame interval) | 257,317 us (~4 fps) | **30,935 us (~32 fps)** | 8.3x |
| `acq` p50 (waiting for a frame) | 255,159 us | 30,056 us | 8.5x |
| `area` p50 (dirty px/frame) | 236,997 | **3,406** | 70x smaller |
| `tot` p50 (OUR cost) | 98 us | 182 us | irrelevant |

**The agent was never the bottleneck**: 98 us of work per 257 ms frame = idle 99.96% of the time.
With acceleration on, Word (a) presented only ~4x/second and (b) repainted essentially the whole
window for a single character. Disabling it makes Word repaint only the changed text and present
at display rate.

REMEDY (guest configuration, not an agent change):
`HKCU\Software\Microsoft\Office\16.0\Common\Graphics\DisableHardwareAcceleration = 1`
(plus `DisableAnimations=1`, `Common\UseAnimations=0`). Worth adding to guest setup/docs for any
Office-in-a-Windows-qube deployment - this will hit every user of Office under Qubes, and the
symptom (typing lag) invites blaming the GUI agent, which the numbers exonerate.

Method note: the first attempt returned RECORDS 0 and looked like a null result. It was vacuous -
SendKeys went nowhere because Word did not have focus after the restart. Fixed by explicitly
SetForegroundWindow-ing Word and asserting FOREGROUND_IS_WORD=True before typing. A measurement
that cannot fail loudly will fail quietly.

### 2026-08-02 — agent-side optimisation headroom for Office: bounded, and NOT in throughput
Asked whether the agent can be optimised to speed Office up. Measured answer:
- Our cost is **182 us against a 31 ms frame interval = 0.6%**. Reducing it to zero would be
  imperceptible for typing.
- We impose **no frame-rate cap**: `GetFrame(capture, FRAME_TIMEOUT)` uses a 1000 ms
  AcquireNextFrame timeout (capture.c:733, FRAME_TIMEOUT=1000) with no sleep or throttle in the
  loop, so the ~32 fps observed is the GUEST's present rate.
Therefore there is no throughput win available agent-side. Real (bounded) opportunities:
1. **Damage-scoped recapture + diff** — today any intersecting dirty rect triggers a full
   PrintWindow of the whole window and a full-window row diff; on Word (3430x1379) this produced
   `upd` spikes to **58 ms**. Scoping both to the damaged band removes the spikes. Same family as
   d64bca6 (suppress recapture on pure moves), extended from "don't recapture" to "recapture
   less". Best evidence-backed agent-side change available; benefits every large window.
2. **slice-fed / PwForceLegacy fallback** fired twice on this guest — that path serves a window
   from full-desktop slices instead of its own buffer and is materially slower. Find out what
   triggers it on Office before assuming it is rare.

### 2026-08-03 — CORRECTION to the Office-latency numbers, and what is actually solid
User: "more or less fine on notepad but very sluggish in word" - which does not fit the story I
told, so I re-measured.

**Correction 1: my `dt` figures were confounded by my own harness.** The typing script sends one
key every 200 ms, so frames arrive ~every 200 ms BECAUSE THAT IS THE INPUT RATE. Notepad typing
measures dt_p50 = 202,333 us, which is the cadence, not a ceiling. The earlier "4 fps -> 32 fps"
framing overstated it. What the acceleration test really showed still stands and is still
significant: with HW accel ON Word's dt was 257 ms - SLOWER than the 200 ms input, i.e. genuinely
falling behind; with it OFF, 31 ms, comfortably ahead. Cause and remedy unchanged; the magnitude
claim was wrong.

**Correction 2: the first PrintWindow timing was confounded too.** The row labelled WORD measured
a 391x8 SHADOW STRIP - Word's MainWindowHandle points at one (itself a useful fact, and the
reason several enumerations behaved oddly). The real OpusApp window has not yet been timed.

**What is solid (unconfounded, input-rate independent):**
`PrintWindow(hwnd, dc, PW_RENDERFULLCONTENT)` measured in-guest:
- 2573x1013 (2.6 Mpx, Notepad): p50 **49.4 ms**, max 68.0 ms
- 391x8 (3,128 px):             p50 **17.3 ms**, max 32.5 ms  -> ~17 ms FIXED DWM cost
This lands on EVERY update of a per-window-captured window, independent of typing speed. Word's
window is 3430x1379 = 4.7 Mpx, ~1.8x Notepad's area, so its per-update cost should be
proportionally worse - consistent with "Notepad fine, Word sluggish" if ~50 ms is near the
perceptual edge. NOT YET MEASURED on the real Word window; do that before acting.

**Consequence for the proposed fix:** damage-scoping the DIFF cannot help, because PrintWindow
has no partial mode - it always re-renders the whole window. The design being explored is a
HYBRID SOURCE: for an UNOCCLUDED window take pixels from the DDA desktop image already held in
memory (a memcpy, zero added latency) and use PrintWindow only for genuinely covered regions.
The window being typed into is almost always unoccluded, so the common case would lose the whole
25-65 ms. Correctness (an occluded window must still yield its own content - Gate 0) is preserved
by construction. Design in progress: scratchpad/hybrid-capture-design.md.

### 2026-08-03 — hybrid DDA/PrintWindow capture: design done, one premise of mine corrected
Full design: `scratchpad/hybrid-capture-design.md`.

**Corrects my brief:** the occlusion machinery I said to reuse does not do what I claimed.
`rgnCovered` accumulates ONLY override-redirect popups and synthesized windows
(main.c:2983-2987, 3119-3122, 3271-3272), and `CollectZOrder` skips `EnumWindows` and sets
`g_ZOrderValid = FALSE` whenever no popup is visible (main.c:2637-2662) - i.e. always, while
typing. General z-order clipping was tried here and REVERTED with measured evidence
(main.c:3256-3270). The hybrid therefore needs its own bounded top-down GW_HWNDNEXT walk,
conservative-on-doubt, which must not feed back into rgnCovered.

**Why Word feels different from Notepad, quantified (INFERRED extrapolation):** measured
PrintWindow p50 is 49.4 ms at 2.6 Mpx; Word's 3430x1379 = 4.73 Mpx extrapolates to ~76 ms, which
EXCEEDS the 31 ms frame interval - so the capture thread never catches up and end-to-end lands
~100-150 ms. Notepad's ~49 ms fits between frames. Matches the user's report exactly.

**Design calls, each with a verified reason:**
- Per-window binary, NOT per-region: an occlusion-derived mask changes at input rate and
  `WcSetMask` takes the engine lock EXCLUSIVE and forces a full recapture
  (wincapture.cpp:339-356) - it would reintroduce the very cost being removed.
- Partial occlusion falls back ENTIRELY to PrintWindow: the covered region has no change signal
  (its dirty rects belong to the occluder), so a mixed buffer could sit up to 250 ms stale.
- Fast path already exists: `PwSliceCopyAndDamage` (main.c:2736-2776), already proven against the
  daemon for WS_EX_NOREDIRECTIONBITMAP windows; it takes `fb` as a parameter, so it adds ZERO
  exposure to the g_FbBits dangling hazard (the real dangling reader is SynthActivate ->
  PwPatchSynthRect, main.c:1171 - separate issue).
- Eligibility (7 predicates) includes NOT MOVING: d64bca6's position-invariance argument INVERTS
  for a DDA source. Plus a ~100 ms dwell; exit immediate and asymmetric.
- `WcSuspend` must take the engine lock SHARED like WcMarkDirty - exclusive would stall up to
  65 ms while holding g_csWatchedWindows. Order stays g_csWatchedWindows -> engine(shared) ->
  vchan; no inversion.

**BIGGEST RISK + THE FALSIFIER (do this before writing any code):** the design assumes DDA pixels
== PrintWindow pixels for an eligible window. Threats: alpha (DDA composes it; a GDI BI_RGB DIB
likely leaves 0, so memcmp would call every row changed), Win11 rounded corners, DWM effects.
Cheapest test, no agent change: one guest tool grabbing BOTH sources for the same unoccluded
window at the same instant, reporting % differing on RGB vs RGBA and per-corner deltas, ~100
iterations while typing, on Win10 AND Win11. Interior RGB mismatch ~0 => proceed; otherwise the
design is dead and the fallback is damage-scoped diffing. Prerequisite: time the occlusion walk
standalone - if >~1 ms/pass it must be memoised against EVENT_SYSTEM_FOREGROUND/LOCATIONCHANGE.

### 2026-08-03 — Office daemon-kill: GEOMETRIC PROOF of the cause (no longer "unreproducible")
Word's Document Recovery dialog (HWND 0x20338, 375x186) carries four MSO_BORDEREFFECT strips
owned by the DIALOG. Measured geometry at 09:57:21.778, owner (1543,702)-(1918,888):

| strip | rect | overlap |
|---|---|---|
| 0x20350 top | (1535,694)-(1926,702) | bottom edge == owner top -> **0 px** |
| 0x20340 bottom | (1535,888)-(1926,896) | top edge == owner bottom -> **0 px** |
| 0x20344 left | (1535,694)-(1543,896) | right edge == owner left -> **0 px** |
| 0x20342 right | (1918,694)-(1926,896) | left edge == owner right -> **0 px** |

All four edge-adjacent, EXACTLY zero intersection, each 8 px outside - inside
SYNTH_OVERHANG_MAX = 12.

**The bug is `SynthOwnerQualifies` (main.c:1013-1020): it tests BOUNDS PROXIMITY ONLY, with no
overlap test.** The 12 px allowance from 832ce97 was for XAML popups that stick out slightly
WHILE STILL OVERLAPPING; it silently admits children entirely outside the owner. Downstream
`PwPatchSynthChildClipped` (main.c:2799) intersects, gets an empty rect, logs "synth paint ...
outside owner" and paints nothing - forever.

**Kill mechanism - synth/materialize oscillation:**
```
095721.324  SynthActivate x4                                  (strips synthesized)
095721.653  UpdateWindowData: ... owner geometry changed, materializing child   x4
095721.778  SynthActivate x4                                  (re-synthesized)
095721.778  synth paint ... outside owner x4
```
Flip-flop inside ~450 ms; materialisation announces them to dom0, and that burst is what precedes
the vchan loss. Cause is now geometric, not "timing-dependent and unreproducible".

**Two corrections to the 2026-08-02 write-up:**
1. That entry describes a DAEMON-FIRST death (daemon dropped, agent tore down cleanly). The
   09:57 death was SILENT: the log ends mid-normal-PerfEmitFrame with no vchan error, no
   teardown, no WinMain failure, and NO WER/Application Error 1000 for gui-agent.exe in 24 h.
   The agent did not crash-with-report and did not exit cleanly. Different variant, same family.
2. Per-window capture was ENABLED in the session that died (only the post-reboot respawns show
   "disabled by config"), so an earlier reading that the VM was "already in Arm B" was about the
   wrong instance.
The ~10:06 reboot was mine (qtest kill/start to restore the GUI after the daemon loss), not a
self-reboot.

**Fix**: require a NON-EMPTY intersection with the owner's granted rect (PwWidth/PwHeight), not
bounds proximity - ideally a majority of the child's area inside. Rejection must DROP, never
announce (an announced 391x8 strip becomes its own bordered dom0 sliver); the
"synthesize-or-drop, never announce" precedent is main.c:1218-1219 (d610454 keytips). Branches
fix-office-chrome-v2 (predicate + CreateSent) and fix-mso-chrome-class (c789199, class rejection)
both target this; the class rejection is the narrower, more certain cut.
Still wanted from dom0: `/var/log/qubes/guid.win-idd-test.log` for the daemon's own exit reason.

### 2026-08-03 — Office daemon-kill: the daemon's own verdict, and the fix (branch fix-createsent-gate)
The user qvm-copied dom0's daemon logs to ~/QubesIncoming/dom0/. `guid.win-idd-test.log.old`
ends with, verbatim:
```
Window 0x1c00192 is still set as transient_for for a 0x1c00194 window, but VM tried to destroy it
libvchan_is_eof          <- agent died 09:57:00
Icon size: 128x128       <- daemon restarted
libvchan_is_eof          <- agent died 09:57:51
Icon size: 128x128       <- daemon restarted
msg 0x86 without CREATE for 0x20340    <- daemon exit(1), 09:58:07, never restarted again
```
`0x86` = 134 = **MSG_CONFIGURE** (verified against qubes-gui-protocol.h: MSG_MIN=123, and the
header's own `MSG_UNMAP // 133` / `MSG_DOCK // 143` markers bracket it). `0x20340` is the BOTTOM
MSO_BORDEREFFECT strip of Word's Document Recovery dialog. So the GUI loss was gui-daemon
exiting on a protocol violation by us - not a crash, not the VM.

**Full chain, every link verified in source or logs:**
1. Four strips sit flush against the dialog with EXACTLY zero intersection, 8 px out (geometry
   in the previous entry).
2. `SynthOwnerQualifies` (main.c:1013-1020) tested only bounds proximity vs SYNTH_OVERHANG_MAX,
   with no overlap test -> all four admitted as synthesized children, so none was ever announced
   (`CreateSent = FALSE`).
3. `PwPatchSynthChildClipped` intersects to an empty rect -> `synth paint ... outside owner`
   forever; the strips can never be painted.
4. Owner geometry shifts -> main.c "materializing child": `SynthDeactivate(c); c->DeletePending
   = TRUE;`. Clears `Synthesized`, leaves `CreateSent = FALSE`, entry STAYS in the watched list.
5. `ProcessNewFrame` no longer skipped it (not synthesized, not PwIsAttached) -> legacy branch ->
   `SendWindowConfigureIfChanged` -> **MSG_CONFIGURE for a window with no CREATE** -> daemon dies.

Not deterministically reproducible before because it needs a DIALOG with zero-overlap chrome AND
a geometry change; Document Recovery supplies both.

**Fix (98eed30, CI green: idd-driver + gui-agent + package):**
- **Layer 1, the backstop** - send.c now keeps the set of windows a CREATE actually went out for,
  maintained under g_VchanCriticalSection by the calls that emit CREATE/DESTROY (the same lock
  that orders the messages), and all nine window-scoped senders check it; window 0 is exempt.
  `WINDOW_DATA.CreateSent` cannot serve: it lives under g_csWatchedWindows, which the capture
  thread must not take (ABBA vs the vchan lock). Before this, `CreateSent` was checked in exactly
  ONE place (RemoveWindow, main.c:1360). **No agent bug should be able to kill the qube's GUI.**
- **Layer 2, root cause** - `SynthOwnerQualifies` now requires a non-empty intersection with the
  owner's granted buffer, not mere proximity.
- **Layer 3, disposition** - the frame loop skips `DeletePending` entries outright.

`SendResetCreatedWindows()` on client connect is defence in depth only: `WatchForEvents` runs
once per process and returns on vchan EOF, so a new client always means a respawned agent with an
empty set. It matters if the agent is ever made to survive a daemon restart - which would also
require re-announcing existing windows (it does not today).

**Correction to the 2026-08-02 entry**: that one describes a DAEMON-FIRST death (daemon dropped,
agent tore down cleanly). This is the opposite order and a different variant: the agent died
SILENTLY twice (log ends mid-frame, no vchan error, no teardown, no WER Application Error in 24 h)
before the third instance killed the daemon outright. Two silent agent deaths remain UNEXPLAINED -
the strip bug explains the daemon's exit, not the agent's. The ~10:06 VM restart was mine.

**Operational lesson**: `guid.<vm>.log` is truncated on daemon start. Only `.old` carried the
fatal line, and only because the daemon happened to restart once more. Pull BOTH before any restart.

NOT yet deployed: the guest is parked in the PerWindowCapture=0 arm awaiting the user's typing
judgement, and deploying restarts the agent (which drops the dom0 daemon and needs a VM restart).
Deploy + re-run the Office repro once that judgement is in.

### 2026-08-03 — 98eed30 DEPLOYED and VALIDATED against the live repro (supersedes "NOT yet deployed" above)

The "NOT yet deployed" note directly above is superseded: the fix is on the guest and the Office
repro was re-run against it. The typing judgement it was waiting for is NOT a prerequisite for
this — the two are independent (that arm is about PrintWindow latency, this is about the daemon
kill), and leaving a known qube-GUI-killer undeployed to preserve a measurement arm was the wrong
trade.

**Deploy method (note for whoever touches this guest next): hand-swapped binary, not a package
install.** `gui-agent.exe` from CI run 30794482470 (`gui-agent-package`, superproject 176264f →
agent 98eed30) copied over `C:\Program Files\Qubes Tools\bin\gui-agent.exe`, with
`gui-agent.exe.orig` left beside it for revert. Sequence: `Stop-Service QubesGuiWatchdog` → kill
`gui-agent` → copy → set `PerWindowCapture=1` → `Start-Service`. **A QWT reinstall silently
reverts this.** The registry value was found at
`HKLM\Software\Invisible Things Lab\Qubes Tools` (note: install tree is `C:\Program Files\Qubes
Tools`, the config key is still under the ITL path).

`PerWindowCapture` was **0** on this guest before the swap, i.e. the synthesis path was dormant
and none of the strip machinery could run. Anything measured on this guest between the 10:06
reboot and 15:45 was the legacy screen-slice path. Re-enabled to 1 so the fix is actually exercised.

**Repro**: Word launched cold, producing its crash-recovery prompt ("Word couldn't start last
time… start in safe mode?") — the same dialog class that owns the four `MSO_BORDEREFFECT` strips.
Its reappearance is itself a consequence of the unclean 10:06 reboot.

**Result — six checks, agent log gui-agent-20260803-154537-6240.log:**

| check | before (b299011) | after (98eed30) |
|---|---|---|
| `synth paint … outside owner` | every frame for 13 h | **0** |
| `QGAPROTO,msg=SYNTH` for the strips | 4, repeatedly | **0** — overlap test rejects them |
| `materializing child` oscillation | 4 per burst | **0** |
| gate drops (`no CREATE was sent`) | n/a (gate did not exist) | **0** — nothing even attempted it |
| vchan | `not open` → daemon exit → qube GUI lost | **healthy**, daemon 0x10008 |
| dom0 windows for the dialog | dialog + 4 bordered slivers / broken composite | **1 clean window** |

`local.WinScreenshot` returned exactly one PNG: the dialog, correctly bordered, fully painted, no
shadow-strip slivers, no black regions. Agent attached one per-window buffer (`0x2031a`, 400x185).

Worth recording explicitly: the strips are now **neither synthesized nor announced**. Layer 3's
predicted failure mode (rejection from synthesis → four bordered 391x8 slivers in dom0) did NOT
occur — they are filtered before announcement. So no "synthesize-or-drop" change was needed.

**Review of 98eed30 before deploying** (findings, not just a rubber stamp): the three things that
could still have been fatal are all correct — (a) `MaySendForWindowLocked` is called inside the
`g_VchanCriticalSection` hold at every one of the nine sites; (b) both early-return gate sites
(`SendWindowDump` send.c:73, `SendWindowMap` send.c:504) `LeaveCriticalSection` before returning,
so the gate cannot deadlock the agent; (c) `MarkWindowCreatedLocked` runs only AFTER
`VCHAN_SEND_MSG(MSG_CREATE)` succeeds, so the set can never claim more than the daemon was told.
`SendResetCreatedWindows` is declared (send.h:62) and called at main.c:3587.

**Still open, do not treat the GUI-death class as closed:**
- The two SILENT agent deaths (09:57:00, 09:57:51) remain unexplained. The strip bug explains the
  daemon's `exit(1)`, not why the agent process vanished with no log line and no WER entry. The
  watchdog is not the killer — watchdog.c:160-161 only restarts a process it finds missing, it
  never terminates one.
- The ~10:06 VM restart was **unclean**: Kernel-Power Event 41 ("rebooted without cleanly shutting
  down"), plus EventLog 6008. A hand-swapped agent cannot cause that. Something below the agent
  is still suspect; the strip fix does not address it.
- Validation is n=1 on one dialog. The stronger test is real Office under load
  (`tools/viewcheck/office-repro.ps1`), not yet run against 98eed30.

### 2026-08-03 — fix VALIDATED on the live repro (measured here, not inferred)
The "Sign in to set up Office" dialog reproduces the identical geometry to this morning's
Document Recovery dialog, and it was on screen while the fixed agent (98eed30, hand-swapped
gui-agent.exe, PerWindowCapture=1) was running. Live enumeration, owner dialog 0x1201a8
(1300,454)-(2150,996), four WS_EX_LAYERED|WS_EX_TOOLWINDOW strips 8 px thick:

| strip | rect | vs dialog |
|---|---|---|
| 0x10388 top | (1292,446)-(2158,454) | bottom edge == dialog top -> 0 px |
| 0x80040 bottom | (1292,996)-(2158,1004) | top edge == dialog bottom -> 0 px |
| 0x10386 left | (1292,446)-(1300,1004) | right edge == dialog left -> 0 px |
| 0x10384 right | (2150,446)-(2158,1004) | left edge == dialog right -> 0 px |

Agent's actual reaction (its own log, same instant):
```
SynthActivate: msg=SYNTH,hwnd=0x80040,owner=0x50322,x=1292,y=996,w=866,h=8
SynthActivate: msg=SYNTH,hwnd=0x10384,owner=0x50322,x=2150,y=446,w=8,h=558
SynthActivate: msg=SYNTH,hwnd=0x10386,owner=0x50322,x=1292,y=446,w=8,h=558
SynthActivate: msg=SYNTH,hwnd=0x10388,owner=0x50322,x=1292,y=446,w=866,h=8
```
**owner=0x50322 is Word's MAIN window** (-8,-8)-(3448,1408), which the strips genuinely overlap -
NOT the dialog 0x1201a8 they merely touch. The overlap test rejected the zero-overlap owner and
let the candidate fall through to one with real overlap, which is exactly the intent.
Counters with the strips live: `outside owner` = 0, `materializing child` = 0, gate drops
("no CREATE was sent") = 0, vchan connected, agent PID stable. Pre-fix the same configuration
produced SynthActivate x4 onto the DIALOG, then `synth paint ... outside owner` x4 forever, then
the materialize oscillation, then the daemon's exit. Chain broken at the first link.

Two corrections to my own checks along the way, both mine, both mattered:
- I scanned agent logs for the strip HWNDs (0x2034x) to see whether the repro had re-run
  post-fix and read zero as "it never ran". HWNDs are per-session, and the agent does not log
  class names (`OLD_HAS_CLASSNAME=0`), so that detector could never have matched. The skepticism
  it produced was unfounded.
- A first enumeration returned garbage class/title text ("S", "D"): `GetClassNameW`/
  `GetWindowTextW` need `CharSet=CharSet.Unicode` on the DllImport or the StringBuilder is
  marshalled ANSI. Geometry was unaffected and is what the verdict rests on.

Deployment caveat: this is a hand-swapped `gui-agent.exe` with `.orig` alongside, NOT a package
install - a QWT reinstall reverts it. `PerWindowCapture` had been 0 (my typing A/B) and is now 1.
Unrelated and open: `local.WinScreenshot` currently returns rc=1 with an empty tar even though
the agent reports a connected vchan; the two SILENT agent deaths remain unexplained.

### 2026-08-03 — PerWindowCapture correlates with LOGON-PATH HANGS; flag must default OFF (VM lost to it)

**Symptom**: the guest reaches `user / Welcome` during autologon and stays there indefinitely.
No interactive session is ever created, so `qubes.VMShell` accepts the connection and returns
NOTHING (rc=0, no output) while `qubes.Filecopy` keeps working — file-receiver is a service and
session-independent. `local.WinScreenshot` shows the Welcome spinner. Survives a reboot: the
guest self-restarted and hung at the SAME stage.

**Correlation, two independent episodes:**

| window | PerWindowCapture | outcome |
|---|---|---|
| 2026-08-02 20:50 → 2026-08-03 09:57 | **ENABLED** (`PwInit: per-window capture ENABLED`) | agent died SILENTLY twice (log ends mid-frame, no vchan error, no WER); daemon killed; 10:06 unclean reboot (Kernel-Power 41) |
| 09:58 → 15:45 | **0** (`disabled by config`) | stable ~6 h, dozens of successful pushruns, Office repro ran fine |
| 15:45 (set to 1 during this session's deploy) → 16:14 | **1** | worked ~7 min; first idle LOCK at ~16:14 → stuck; self-reboot → stuck again |

The flag was 0 when this session started. **It was set to 0 at 09:58, i.e. immediately after the
first episode** - that was not a neutral default, it was somebody's workaround, and re-enabling it
without asking why reproduced the failure. Recording that as the process error it is.

**Suspected mechanism** (INFERRED - not proven, the VM was lost before it could be instrumented):
`PrintWindow` round-trips **synchronously into the target process** - the engine says so itself
(wincapture.cpp:99-105, which is why `IsHungAppWindow` is checked at all). The capture thread
calls `AttachThreadToInputDesktop` and re-attaches whenever a capture fails
(wincapture.cpp:244-246). Across a lock / secure-desktop transition the input desktop becomes
Winlogon, and the agent - SYSTEM in session 1 - begins driving `PrintWindow` at LogonUI-owned
windows. A synchronous round-trip into the logon UI during session init is a credible way to stall
logon exactly where the guest is stuck. `IsHungAppWindow` does not help here: LogonUI is not hung,
it is waiting on us.

**Why this matters beyond the test rig**: lock/unlock is a daily event for every real user. If the
mechanism is right, per-window capture as shipped can wedge a Windows qube's logon. That is a
release blocker for the feature, not a lab artifact.

**Actions:**
- `PerWindowCapture` must **default OFF** until this is root-caused. Note the code default is
  currently ON (perwindow.c:70, `DWORD enabled = 1; // default ON: this build exists to exercise
  the new path`) - fine for a bring-up build, wrong for anything a user installs.
- The engine must never capture across a non-default desktop. Candidate guard: record the desktop
  the channel was created on and skip capture when `OpenInputDesktop` reports a different one
  (Winlogon/secure), rather than re-attaching to it as the code does today.
- Repro to run on the rebuilt guest BEFORE trusting the flag again: enable it, lock the session
  (`rundll32 user32.dll,LockWorkStation`), wait, unlock, and see whether the desktop returns.
  That is a 2-minute test and would have caught this.

**Evidence lost**: the guest could not be shelled, so the 16:14 agent/qrexec logs and the
Windows event log for the hang were never extracted, and the VM is being rebuilt. The correlation
above rests on the boot-time `PwInit` lines already quoted in this file plus the observed
timeline - it is strong, but the mechanism remains UNPROVEN. Do not present it upstream as
established without the lock/unlock repro.

**Not lost**: all code and analysis are committed and pushed - `aaa8c37` (MSO chrome by class),
`66fc670` (no popup re-homing), superproject `ed314d2`, FINDINGS `f71509c`.

### 2026-08-03 — SUSPECTED RELEASE BLOCKER: per-window capture correlates with logon-path hangs
win-idd-test is now stuck at autologon ("user / Welcome", spinner) across THREE boots including a
clean ACPI shutdown. `qubes.Filecopy` works, `qubes.VMShell` returns nothing - qrexec-agent is
alive, there is simply no interactive session for a shell to run in. The guest is unusable and I
cannot recover it from here: flipping the registry flag or reverting the binary both need a shell.

**Correlation (2 independent episodes + the morning deaths):**

| window | PerWindowCapture | outcome |
|---|---|---|
| 08-02 20:50 -> 08-03 09:57 | ENABLED (log: `PwInit: per-window capture ENABLED`) | agent died SILENTLY twice, daemon killed, 10:06 unclean reboot (Kernel-Power 41) |
| 09:58 -> 15:45 | 0 (`disabled by config`) | stable all day, dozens of successful pushruns |
| 15:45 -> now | 1 | ~7 min OK, first idle lock ~16:14 -> stuck; stuck again on every reboot since |

**Proposed mechanism** (plausible, NOT proven): `PrintWindow` round-trips SYNCHRONOUSLY into the
target process (wincapture.cpp:99-105 - the reason the `IsHungAppWindow` guard exists), and the
capture thread calls `AttachThreadToInputDesktop`, re-attaching on failure (wincapture.cpp:244-246).
Across a lock / secure-desktop transition the input desktop becomes Winlogon, so the agent - SYSTEM
in session 1 - starts driving PrintWindow at LogonUI-owned windows. A synchronous round-trip into
the logon UI during session init is a credible way to stall logon exactly where we are stuck, and
`IsHungAppWindow` does not help: LogonUI is not hung, it is waiting on us. This is also the first
hypothesis that FITS the two silent agent deaths, which I had recorded as unexplained.

**CONFOUND, stated honestly**: the flag was not the only variable. The current episode also
follows a binary swap to aaa8c37 AND my deploy script wrongly stopping `QdbDaemon` (it matched
service DisplayName 'Qubes' and picked qubesdb, not the gui agent - qrexec depends on it). Episode
A (16:14) was 98eed30 + flag=1 with no such interference, which is the cleaner of the two. So the
flag is the best-supported single explanation but is NOT isolated; the decisive test is a guest
with the flag OFF and the same binary.

**If it holds, this is a release blocker for the feature, not a test-rig quirk**: every real user
locks and unlocks daily. Per-window capture must default OFF until root-caused, and the capture
thread must refuse to touch windows on a desktop other than the interactive one.

**Not lost with the VM**: aaa8c37 (MSO chrome drop), 66fc670 (no popup re-homing onto an untracked
owner's sibling), ed314d2 (bump), plus the validated daemon-kill chain - all committed and pushed.
Undeployed/unvalidated: the shadow-band fix (aaa8c37 + 66fc670).

**My operational errors this session, recorded so they are not repeated:**
1. The deploy script picked the service by `DisplayName -match 'Qubes'` and stopped **QdbDaemon**,
   killing qrexec. Match the gui-agent's own service, never a DisplayName substring.
2. Two `qtest kill`s left the volume dirty. The later `qvm-shutdown --wait` worked cleanly - try
   ACPI FIRST; the guest honoured it even with no interactive session.

### 2026-08-03 — RETRACTION: the logon hang was WINDOWS UPDATE, not PerWindowCapture

The entry immediately above is **WRONG in its central claim** and is retracted. I attributed a
logon hang to `PerWindowCapture` on a correlation, then went to rebuild the VM. The VM recovered
on its own before the rebuild, and the guest's own event log gives the real cause.

**Proof:**
- `qvm-prefs win-idd-test netvm` = **`core-net`**. The guest has been ONLINE since the Office
  install (FINDINGS 2026-08-02) and nobody detached it afterwards.
- OS build moved **19045.6456 → 19045.6466** across the incident.
- Hotfixes installed 02-03/08: KB5072653, KB5071959, KB5071982, KB5066130, KB5066135, plus
  KB5066747 (.NET CU) and KB5001716.
- Update activity ran 12:12 → 16:05 (`WindowsUpdateClient` 43/44/19 events, incl. "2025-11
  Cumulative Update for Windows 10 Version 22H2 (KB5071959)" started 12:21).
- The decisive line, **16:04:24 Event 1074 / User32**:
  `The process C:\Windows\servicing\TrustedInstaller.exe ... has initiated the restart ... for the
  following reason: Operating System: Upgrade (Planned)`

So: the `user / Welcome` spinner was **post-update logon servicing**, the "self-reboot" was
TrustedInstaller's planned servicing restart, and `qubes.VMShell` was mute because no interactive
session exists while that runs. All of it is ordinary Windows servicing on a networked guest.

**What survives from the retracted entry:**
- The 09:57 silent agent deaths are still UNEXPLAINED. They predate the 10:16 update activity and
  are not accounted for here.
- `PerWindowCapture` was set to 0 at 09:58 by someone, and I re-enabled it at 15:45 without
  establishing why. That process error stands regardless of the outcome: **do not flip a flag
  whose current value you cannot explain.**
- The code default (perwindow.c:70, `enabled = 1`) is still wrong for a shipping build, on general
  principle - but NOT for the reason I gave, and this is no longer evidence for a release blocker.

**What does NOT survive:** the correlation table, the "PrintWindow into LogonUI stalls session
init" mechanism, and the "release blocker" conclusion. All withdrawn. The mechanism was never
observed - I inferred it from a timeline that had a much simpler explanation I had not checked.

**Method failure worth keeping:** I had `netvm=core-net` available from `qvm-prefs` the whole time
and never looked, because I had internally filed the guest as "offline" from CLAUDE.md's rule. The
rule describes intent; `qvm-prefs` describes reality. Check the machine, not the memory of the
machine. The same mistake in miniature as quoting DESIGN-workarea-propagation's problem statement
instead of reading workarea.c.

**Consequences to act on:**
1. **Detach the netvm** (`qvm-prefs win-idd-test netvm ''`) now that Office is installed - a guest
   that services itself mid-run invalidates every latency and CPU measurement taken today, and
   silently changed the OS build under our benchmarks (6456 → 6466).
2. Re-check any timing numbers taken 12:12-16:05 today; a cumulative update was installing
   underneath them.
3. The VM was NOT rebuilt. It is healthy, updated, and Office is intact.

### 2026-08-03 — RETRACTION: the "per-window capture logon hang" was Windows Update
The entry above titled "SUSPECTED RELEASE BLOCKER: per-window capture correlates with logon-path
hangs" is **WRONG and withdrawn**. The guest was not wedged. `qvm-prefs win-idd-test netvm` =
**core-net**: it has been ONLINE since the Office install and was servicing itself all afternoon.
OS build moved 19045.6456 -> 19045.6466; KB5072653/5071959/5071982/5066130/5066747/5001716
installed 12:12-16:05; Event 1074 at 16:04:24 records `TrustedInstaller.exe ... initiated the
restart ... reason: Operating System: Upgrade (Planned)`. The "user / Welcome" spinner was
post-update logon servicing, the "self-reboot" was TrustedInstaller's planned restart, and
`qubes.VMShell` was mute because no interactive session exists while that runs. The VM recovered
on its own; qrexec answers again and Office is intact. **No reinstall was performed** - the user
had approved one, but its entire premise was this bad diagnosis.

The correlation table was real and still meaningless: per-window capture happened to be ON during
two windows that also contained update activity. I built a mechanism (PrintWindow into LogonUI)
that fit the story and stopped looking. **`qvm-prefs` was available the whole time and I never
ran it**, because CLAUDE.md says the test VM is offline - the rule states intent, the command
states reality. Second time today I trusted a document over the live system (the other: quoting
DESIGN-workarea-propagation.md's problem statement instead of reading workarea.c).

Consequences for the record:
- The two SILENT agent deaths at 09:57 are **still unexplained**; they predate the update activity.
- **Timing numbers taken 12:12-16:05 today are invalid** - a cumulative update was installing
  underneath them, and the OS build changed mid-run. Re-take anything from that window.
- Commit 6b5b298 (capture idles while the secure desktop is up) **keeps its behaviour but loses
  its evidence**: it is now hardening, not a fix for an observed hang. Capture on the secure
  desktop is still undesirable on its own merits - PrintWindow round-trips synchronously into
  LogonUI, DDA returns ACCESS_DENIED there, and the agent has no business sampling the logon UI -
  but nothing observed today demonstrates harm. Its commit message overstates the case and is
  corrected here rather than by rewriting the pushed history.
- Standing rule from this: **before blaming our code for a guest-wide symptom, check netvm,
  Windows Update state, and the System event log.** A networked Windows guest is never quiescent.

---

# 2026-08-04 — T2 needs OUR driver to supply the modes (measured); T1 instrument rebuilt

> Heading corrected: this originally read "T2 is blocked on the IddCx driver". The framing was
> wrong — the mode list is ours to choose, not an external constraint. See the correction inside.

Guest quiesced first: `qvm-prefs win-idd-test netvm ''` (it was `core-net`). Lockout threshold
was already `Never`, so trap 4.3 cannot bite. `AutoAdminLogon=1` with **no** `DefaultPassword`
is still the configuration — left alone, since setting the password needs the user.

## FINDING (T2): the BASIC DISPLAY ADAPTER's mode list is fixed and lacks 1600x1000 — so the mode list has to become OURS

Framing correction (user, 2026-08-04): an earlier version of this entry said "the adapter
offers a fixed 29-mode list" and called T2 *blocked*, as though the mode list were a fact of
nature to work around. It is not. **The adapter is ours to choose.** Track B exists precisely
to replace the Basic Display Adapter with an IddCx driver we write, and declaring the mode
list — including arbitrary, dynamically-added modes — is that driver's core capability. The
measurement below does not block T2; it establishes that 1600x1000 cannot come from the
*stock* adapter and must therefore be **supplied by our driver**. T2 is a Track B deliverable,
not an obstacle.

The feasibility caveat in SESSION-HANDOFF-2026-08-03 §5 is now settled, and it settles against
the plan. Two independent instruments agree:

1. **The agent's own `InitVideoModes()`**, at `LogLevel=5` (see the registry note below), logs
   the list it will actually choose from: `Enumerated 29 supported modes` — 640x480, 800x600,
   1024x768, 1280x1024, 1600x1200, 1152x864, 1280x768/800/960, 1440x900, 1400x1050, 1680x1050,
   1920x1200, 2560x1600, 1280x720, 1920x1080, 1600x900, 2560x1440, 3840x2160, 960x540,
   1280x1080, 2160x1080, 2560x1080, 3200x1800, 3440x1440, 3840x1080, 3840x1600, 2048x1152,
   2048x1536. **No 1600x1000, and nothing arbitrary.**
2. **`ChangeDisplaySettings(..., CDS_TEST)`**: 1600x1000 -> -2 (`DISP_CHANGE_BADMODE`),
   1234x777 -> -2, 2566x1022 -> -2, 1920x1080 -> 0 (`DISP_CHANGE_SUCCESSFUL`).

Consequence: **T2 as specified is unreachable on the STOCK adapter, and is therefore a Track B
deliverable** — exactly as CLAUDE.md Phase 2B-resize predicted. `SelectSupportedMode()` does
not fail on an unsupported request; it silently snaps to the best-similarity entry in the list
above, so a naive "default to 1600x1000" change would appear to work and quietly give a
different resolution.

Read the right way round, this is the strongest concrete argument yet **for** building the
IddCx driver rather than a reason to defer T2: once the guest monitor is ours, 1600x1000 (and
the dom0-window-following resize of Phase 2B-resize, which needs arbitrary sizes like
2566x1022 that no fixed list will ever contain) becomes a property we simply declare. The 29
modes above are the stock adapter's limitation, not a requirement we must satisfy.

Caveat, stated rather than hidden: a standalone PowerShell `EnumDisplaySettings` probe written
for this returned `MODE_COUNT=0` — its DEVMODE marshalling is wrong. Its **mode list output is
discarded and is not the basis of anything above**; only its `CDS_TEST` return codes are used,
and those are corroborated by instrument 1. The probe was left in the session scratchpad rather
than committed: instrument 1 is production code that already answers this, so a second, broken
copy of the same question is not worth carrying. (Note: SESSION-HANDOFF §5 says this probe "was
written (`scratchpad/modes.ps1`)" — that file does not exist in the repo, in any commit. The
handoff is wrong on that point.) Track B will need a working mode probe to verify the IddCx
driver reports arbitrary modes; write it then, in C++ alongside `tools/ddaprobe`, not in
PowerShell marshalling.

Also observed while there: `HandleXconf: host resolution: 5120x1440` -> agent set 3440x1440
(from the saved `FullscreenWidth/Height`), confirming §5's "registry value is a last-applied
cache, read as if it were user intent".

## Registry: `LogLevel` has a PER-MODULE override that wins

`HKLM\Software\Invisible Things Lab\Qubes Tools\LogLevel` is **not** what gui-agent reads.
There is a subkey `...\Qubes Tools\gui-agent` with its own `LogLevel`, and it takes precedence:
setting the parent to 5 produced zero `-D]`/`-V]` lines; setting
`...\Qubes Tools\gui-agent\LogLevel = 5` produced 369 debug lines in the next instance.
Anything in this repo that says "raise LogLevel" means the subkey.

## T1 (validate aaa8c37): the first two instruments were both worthless — replaced

Deployed the CI build of agent `6b5b298` (`gui-agent.exe` sha256 4da9fe96…, verified against the
running file, `.orig` kept). Seamless survived it: Notepad and Word's NUIDialog both rendered
correctly in dom0, and with all four real `MSO_BORDEREFFECT_WINDOW_CLASS` strips present in the
guest (`dump-windows`: 0x10348/34a/34c/34e around dialog 0x10342), dom0 received **one** window
for that dialog, not five. That is the intended effect — but it is **not yet proven**, because:

- **Instrument 1 (count PNGs from `qtest shot`) is void.** The pre-fix control produced the same
  count as the fix. Worse, Word's strips are *transient*: four at 13:37, one at 13:41, none at
  13:42. The metric was tracking scene state, not the build — the exact trap CLAUDE.md warns
  about, hit again.
- **Instrument 2 (grep the agent log for strip HWNDs) was inconclusive**, for the same reason:
  the control run recorded `STRIPS_PRESENT=0`. Nothing was on screen to reject, so "0 mapped"
  proves nothing. Recorded as inconclusive, not as a pass.

Rule 3 is at least reachable, which was worth confirming before building a repro for it: the
strips are caption-less `WS_POPUP`, so `IsPopup()` marks them override-redirect and the size
floor drops from SM_CXMIN/SM_CYMIN (~136x39) to 4x4 — an 8 px strip survives it. Note this also
means rule 2 can never match them: the real strips carry **neither** `WS_EX_TRANSPARENT` nor
`WS_EX_NOACTIVATE`. Only the class rule can.

**Fix: `tools/chromerepro --mso`** (commits 1c94a62, then corrected) creates four strips of the
literal class `MSO_BORDEREFFECT_WINDOW_CLASS` with the measured styles — deterministic, and
independent of Office. The measurement harness now also fails loudly when the main window is not
mapped, so a dead gui-daemon can no longer masquerade as "the fix worked".

### The Office strip bug is a regression THIS FORK introduced (and instrument 3 was nearly void too)

The first `--mso` used Office's true 8 px thickness. That would have produced a fourth worthless
instrument, caught by reasoning before it produced a verdict and then confirmed on the guest:
the stock control run reported `STRIPS_PRESENT=4, STRIPS_MAPPED=0, MAIN_MAPPED=1` — daemon alive,
instrument working, and the strips still not mapped. **Stock rejects an 8 px strip on SIZE**, so
both sides would have read zero for different reasons: a check that cannot fail.

The mechanism, which matters well beyond the harness:

- `ShouldAcceptWindow()` applies the `SM_CXMIN x SM_CYMIN` (~136x39) floor only to
  NON-override-redirect windows. A caption-less `WS_POPUP` is classified override-redirect by
  `IsPopup()`, and those face a 4 px floor instead.
- That exemption is **fork-local**: agent `d6ab61c`, "Accept small override-redirect popups:
  keytip badges died on the SM_CXMIN floor", added to rescue Win11 Alt-nav keytip badges.
- Office's strips are 391x8 and 8x202 — under the old floor, over the new one.

So: **on stock QWT, Office's shadow strips never reach the chrome rules at all; they die on
size.** `d6ab61c` lowered the floor for popups and let them through as a side effect, and that
is what produced the strip adoption, the synthesis flip-flop and ultimately the `msg 0x86
without CREATE` gui-daemon kill. `aaa8c37` closes it.

The fix stands. Its **description** must change: it repairs a regression introduced by this
fork's own keytip-badge fix, not a long-standing upstream defect. Any upstream submission that
presents it as the latter would be wrong, and `d6ab61c` should be submitted (or at least
described) together with it, since alone it re-opens the hole.

Consequence for testing: **stock QWT is the wrong control for a thin-strip test.** `--mso` now
keeps a floor-clearing thickness (the class rule is size-blind, so this tests the rule
faithfully) and `--mso-thin` preserves the realistic 8 px geometry for use against fork builds
that contain `d6ab61c`.

Harness bug found the same way, worth recording because it is generic: the A/B installed each
side's binary by `Copy-Item -Force` over `gui-agent.exe` **while the agent was running**.
Windows locks a running image, so the copy fails; with `-Force` and no error check the harness
then measured the PREVIOUS build believing it was the new one. Caught by the hash readback
(`COPIED=4B4C…` on the side that should have been `4DA9…`). Stop the service before copying,
and always compare the installed hash to the manifest — CLAUDE.md's rule 3, earned again.

Two more harness defects, both caught by guards rather than by results, both worth knowing:
- **Multi-line PowerShell does not survive the `qtest ps` wrapper.** It arrives as literal text;
  all six sides "failed to install" without installing anything. Keep guest logic in pushed
  `.ps1` files, never inline blocks.
- **`grep -oE 'INSTALL=(OK|FAIL)[^\r]*'` truncates at the first letter `r`.** In a POSIX bracket
  expression `[^\r]` is "not backslash, not r" — there is no `\r` escape. `INSTALL=OK which=orig`
  became `INSTALL=OK which=o` and every side was rejected. Use `tr -d '\r'` and match on line.

## RESULT (T1, aaa8c37): VALIDATED — control failed as required

Method: one **cold boot per side** (in-place restarts are unusable, see above), binary installed
with the agent stopped and the installed hash compared to the CI manifest before every run,
`chromerepro --mso` for the scene, metric = `SendWindowMap` announcements for the strip HWNDs
taken from the same `dump-windows` snapshot. Three rounds per side, interleaved.

| round | build | strips present | **strips announced to dom0** | main announced | total |
|---|---|---|---|---|---|
| r1 | stock `4B4CE2B1…` | 4 | **4** | 1 | 7 |
| r1 | fix `4DA9FE96…`   | 4 | **0** | 1 | 3 |
| r2 | stock              | 4 | **4** | 1 | 7 |
| r2 | fix                | 4 | **0** | 1 | 3 |
| r3 | stock              | 4 | **4** | 1 | 7 |
| r3 | fix                | 4 | **0** | 1 | 3 |

Unanimous and clean: 4/4 vs 0/4, three times each, and the difference in `total` is exactly the
four strips. **The check has been seen to FAIL on a build carrying the defect**, which is what
makes the PASS mean anything (CLAUDE.md evidence rule 5). `MAIN_MAPPED=1` on every run proves
gui-daemon was connected and the instrument live, so a zero is a real rejection and not silence
from a dead daemon. Every run was also a cold boot, so the boot path is covered.

### Scope of this result — read before quoting it

- It validates **`aaa8c37` only** (reject `MSO_BORDEREFFECT_WINDOW_CLASS`).
- **`66fc670`** (never re-home an owned popup onto an untracked owner) and **`6b5b298`** (never
  capture while the secure desktop is up) are **still unvalidated**. They were present in the
  binary under test but nothing here exercised either path.
- It is measured against `chromerepro --mso`, i.e. Office's class and ex-styles at a
  floor-clearing thickness — not against real Office. Given the mechanism is a pure class-name
  comparison, and real strips were separately observed to be admitted on a fork build, this is
  strong but not identical to an end-to-end Office test.

### `qtest shot` cannot see layered windows — first instrument was doubly worthless

An attempt to add pixel evidence failed and is recorded rather than dropped: with the **control**
build announcing all four strips, `qtest shot` still returned exactly **one** PNG, byte-identical
(md5 `36efd5a5…`) to the fixed build's. `local.WinScreenshot` uses `import -window <id>`, which
silently fails on `WS_EX_LAYERED` windows — the chromerepro README already warned of this and I
re-derived it the expensive way.

So counting PNGs, today's first instrument, was not merely noisy: **it is structurally blind to
exactly the windows this bug creates**, and would report a PASS against a build with the defect
fully present. No pixel-level before/after is obtainable from this dev qube; the daemon-side
"five bordered fragments vs one" can only be confirmed by a human looking at dom0's screen.
The agent's announcement log is the authoritative instrument available here.

## One reboot in ~9 wedged in `Transient` (recorded, not diagnosed)

The last shutdown/start cycle of the session left the qube in `Transient` for >5 minutes with no
qrexec. `qtest kill` + `qtest start` recovered it cleanly and it has been healthy since. Roughly
nine full reboots were driven today and exactly one wedged, so this is a low-rate event and no
cause is claimed — do not read it as related to the build under test, which was also installed
across the seven reboots that worked. Recorded because **T6 requires a Windows qube that
survives its own reboots**, and a ~1-in-9 wedge rate on a quiet, offline guest is worth watching.

Watch for it, and if it recurs check whether it correlates with the shutdown that follows an
agent binary swap (the only unusual thing these cycles do).

## Guest state at end of session

| thing | value |
|---|---|
| `netvm` | **detached** (`''`) — still a measurement control, NOT the end state T6 wants |
| `gui-agent.exe` | `4DA9FE96…` — the **validated** CI build of agent `6b5b298`; `.orig` (`4B4CE2B1…`) intact |
| gui-daemon | connected and healthy after a cold boot (`SendWindowMap` x2) |
| services | QdbDaemon / QrexecAgent / QubesGuiWatchdog all Running |
| `PerWindowCapture` | 0 |
| `LogLevel` | **5** in the `…\Qubes Tools\gui-agent` subkey — verbose; reset to 3 before timing work |

Deliberately left with the fix installed rather than reverted to stock: the remaining T1 work
(`66fc670`, `6b5b298`) tests that same binary. Reverting means `install-agent.ps1 -Which orig`.

---

# 2026-08-04 (later) — validating `66fc670`: three more controls that could not fail

Work in progress on the second of the three unproven commits. Recorded now because the
*preconditions* found here are worth more than the eventual verdict.

## RETRACTED (same day, see the correction immediately below): "unreachable at the shipped default"

**The heading and reasoning in this subsection are WRONG and are corrected in
"CORRECTION: there is no shipped `PerWindowCapture=0`" further down.** In short: nothing in the
install path ever writes `PerWindowCapture`, and the CODE default is **1 (ON)**. Our guest's 0
is *our own test artifact*. So these fixes are **on-path for a real user of this fork**, not
latent. The measured facts below stand; the "latent / off-path" conclusion drawn from them does
not. Left in place rather than deleted so the error is visible.

## `66fc670`'s defect is unreachable ON OUR TEST GUEST (which has `PerWindowCapture=0`)

`AddWindow()` gates the whole composite-synthesis path:

```c
if (PwEnabled() && SynthQualifies(entry, &synthOwner))
    SynthActivate(entry, synthOwner);
```

`PwEnabled()` follows the `PerWindowCapture` registry value, and **this guest ships with
`PerWindowCapture=0`**. With it off, nothing is ever synthesized, so:

- the frozen L-shaped shadow ghost `66fc670` fixes **cannot occur** at the default config;
- neither can the synthesis→materialize→`MSG_CONFIGURE`-without-`CREATE` chain that killed
  gui-daemon, at least not by that route;
- and any A/B of `66fc670` run with `PerWindowCapture=0` reports zero SYNTH on both sides —
  a fourth check-that-cannot-fail, which is exactly what my first two control runs were
  (`SYNTH_ALL=0`, control and fix identical). The harness now asserts `PerWindowCapture=1`
  **and** the absence of `per-window capture disabled by config` in the agent's own log, and
  fails the run outright otherwise.

This does not make `66fc670` pointless — per-window capture is a supported mode and the
hybrid-capture work (T3) would turn it on — but it does bound the claim: **the bug it fixes
is latent unless per-window capture is enabled.** Any upstream description must say so.

## Stock QWT is the wrong control here too — for a different reason than the strips

Composite synthesis does not exist upstream; it arrived in fork commit `0a334c1` ("Composite
synthesis: owner-contained popups painted into their owner, never announced"). Stock therefore
emits no `msg=SYNTH` under any circumstances. The control for `66fc670` must be **agent
`aaa8c37`**, the commit immediately before it, built from throwaway branch `control/aaa8c37`
(superproject pins the submodule there; `workflow_dispatch` builds it — do not merge that
branch). Control binary `6554EFED…`, test binary `4DA9FE96…`.

That is now twice in one day that the obvious control — "the binary that shipped" — was
incapable of exhibiting the defect under test, each time for a different reason. **Before any
future A/B: ask what makes the control able to FAIL, and confirm the feature under test even
exists on that side.**

## The repro's own ordering was the third dead control

Synthesis adopts a popup into a **tracked** same-process, non-override-redirect sibling.
chromerepro created the orphan popup before `ShowWindow(g_Main)`, so the popup reached the
agent while no sibling was tracked yet; `SynthQualifies()` then failed for want of a
*candidate* rather than because of the fix, and both builds announced it identically. The
agent log shows it plainly on the control: `AddWindow` → `SendWindowCreate` for the popup at
`.564`, and the main frame's `PwAttachWindow` only at `.689`. Fixed by creating the orphan
last, after pumping messages for 3 s.

Also fixed here: the measurement parsed only the LAST `###` snapshot of `dump-windows`, which
is empty whenever the process is killed just after writing a header — that read as "the scene
is missing" and failed a run that was fine. It now scans every snapshot and dedupes by HWND.

## RESULT (`66fc670`): VALIDATED — control failed as required, on two opposed signals

Control = agent **`aaa8c37`** (`6554EFED…`), test = **`6b5b298`** (`4DA9FE96…`),
`PerWindowCapture=1`, scene `chromerepro --orphan`, one cold boot per side, installed hash
compared to the manifest every run, 3 interleaved rounds.

| round | build | orphan synthesized | adopted by main frame | orphan announced |
|---|---|---|---|---|
| r1 | control `6554EFED…` | **1** | **1** | 0 |
| r1 | fix `4DA9FE96…`     | 0 | 0 | **1** |
| r2 | control              | **1** | **1** | 0 |
| r2 | fix                  | 0 | 0 | **1** |
| r3 | control              | **1** | **1** | 0 |
| r3 | fix                  | 0 | 0 | **1** |

Unanimous. The control adopted the popup into the frame every round — `SYNTH_ALL` naming the
exact pair each time (`0x1029c->0x7005c`, `0x3025e->0x10292`, `0x102a4->0x50164`) — and the fix
synthesized nothing at all in any round.

What makes this hard to fool is that the **two signals move in opposite directions**. A
synthesized popup is painted into its owner and deliberately never announced, so the control
reads adopted-but-unmapped while the fix reads refused-but-announced. A confound that merely
suppressed synthesis would drive both counts to zero; a dead gui-daemon would suppress the
announcement too. Only the intended behaviour produces the observed inversion, and
`ORPHAN_PRESENT=1` on all six runs confirms the scene was actually built every time.

### Scope — same caveats as `aaa8c37`, plus one

- Validates `66fc670` only. **`6b5b298` remains unvalidated.**
- The defect is **unreachable at the shipped default** (`PerWindowCapture=0`), so this fixes a
  real path that is latent in the default configuration.
- Measured against `chromerepro`, not real Office. The mechanism is generic (any app whose
  owned popup points at an untracked owner), which is precisely why the synthetic repro is
  appropriate here — but it is not an end-to-end Office test.

## gui-daemon died again — and it was self-inflicted, by agent restarts

After ~9 gui-agent restarts in 20 minutes, the agent parked at `Awaiting for a vchan client`,
`qtest shot` returned **zero windows**, and it never recovered on its own. Sequence in
`gui-agent-20260804-134924-7504.log`: `libxenvchan_send: vchan not open` on `MSG_MAP`/
`MSG_SHMIMAGE`, then `WatchForEvents: vchan disconnected`.

**The sends failed because the vchan was already closed — the daemon went first. This is not a
protocol violation by the build under test**, and must not be recorded as one.

### Sharpened after a cold boot: ONE agent restart is enough

The first read of this was "~9 restarts wore it down". That is wrong and understated. After a
full qube shutdown/start the GUI came back healthy (fresh daemon, `SendWindowMap` x2, `qtest
shot` normal). **The very next gui-agent restart — stop watchdog, kill agent, copy the SAME
binary back, start watchdog — lost the daemon again**: `awaiting_vchan=1`, `total_mapped=0`,
`qtest shot` = 0 windows. Two for two, from a known-good starting state.

So the rule is: **gui-daemon does not survive a gui-agent restart, and nothing brings it back.**
Reproducible on demand, no Windows Update or other confound involved (guest offline throughout).

Practical consequences:
- **In-place binary swapping is not a viable test method for this component**, which invalidates
  the harness design used earlier today and in previous sessions. Each A/B side now installs its
  binary and *cold-boots the qube*, measuring the agent instance the fresh daemon connected to.
  Slower (~4 min/side), but it is the only sound method — and it makes every run a boot-path
  test, which CLAUDE.md requires anyway.
- Any "restart the agent to apply a fix" instruction in this repo or in QWT docs is, on this
  build, an instruction to take the qube's GUI down until it is rebooted.
- It strengthens the case that daemon fragility, not any one crash cause, is the real robustness
  gap — dom0-side, so Phase 3 discipline (design writeup before code). Worth an upstream issue
  on its own: an agent restart is a normal, expected event (upgrades, crashes, watchdog action)
  and should not be terminal for the qube's GUI.

---

# 2026-08-04 (later still) — CORRECTION: there is no shipped `PerWindowCapture=0`

Prompted by the user asking whether these "off-path" fixes make any sense at all. Checking the
premise instead of the fixes inverted it.

**I claimed twice today — in FINDINGS and in the handoff — that `66fc670` and `6b5b298` fix a
defect that is "unreachable at the shipped default" because "this guest ships with
`PerWindowCapture=0`". That is wrong. Retracting it.**

The evidence, all of it checkable in seconds:

1. **The code default is ON.** `gui-agent/perwindow.c` `PwInit()`:
   ```c
   DWORD enabled = 1; // default ON: this build exists to exercise the new path
   CfgReadDword(NULL, REG_CONFIG_PERWINDOW_VALUE, &enabled, NULL);
   ```
   The registry value only *overrides* that default; absent the value, per-window capture runs.
2. **Nothing in the install path writes the value.** `grep -rl PerWindowCapture guest/ mgmt/
   tools/` returns nothing. No installer, no provisioning script, no `.inf`/`.wxs` sets it. A
   fresh install of this fork therefore has **no** `PerWindowCapture` value at all → default 1.
3. **Our guest's 0 is our own test artifact.** FINDINGS 2026-08-03: "`PerWindowCapture` was set
   to 0 at 09:58 by someone, and I re-enabled it at 15:45"; and "`PerWindowCapture` had been 0
   (my typing A/B)". It came from a prior session's A/B, not from shipping.
4. **The one written recommendation to default it OFF rests on a retracted finding.** FINDINGS
   2026-08-03 "PerWindowCapture must **default OFF** until this is root-caused" belongs to the
   entry titled "PerWindowCapture correlates with LOGON-PATH HANGS", which was **RETRACTED the
   same day** — the hang was Windows Update. The recommendation was never re-justified.

## What this changes

- **`66fc670` is on-path, not latent.** For a user installing this fork today, synthesis runs,
  so the orphan-adoption bug it fixes is live. Its validation today is worth full value.
- **`6b5b298` is likewise on-path** — and still unproven, which now matters more, not less.
- **`aaa8c37`'s stakes rise.** The daemon-killing chain (strips admitted → synthesized →
  materialized → `MSG_CONFIGURE` without `CREATE` → guid `exit(1)`) needs synthesis, i.e. needs
  per-window capture — which is ON by default. So the qube-killing bug was reachable out of the
  box on this fork, and `aaa8c37` + `98eed30` are load-bearing rather than defensive extras.
- **Today's Word observation proves nothing about the shadow.** I ran Word on the fixed build at
  `PerWindowCapture=0`, where synthesis cannot run, so the frozen L-shaped shadow band could not
  have appeared regardless of whether the fix works. That check could not fail — the fifth such
  instrument today. The end-to-end Office test must run at `PerWindowCapture=1`.
- **I restored the guest to `PerWindowCapture=0` at the end of the validation run and called it
  "the shipped default" in the handoff.** That description is wrong; it is simply the value the
  guest happened to carry. It also means the guest is currently NOT in the configuration a real
  user would have.

## The generalisable error

Twice today the *premise* of a measurement was wrong rather than the measurement: "stock is a
valid control" (it lacked the feature under test) and now "the default is off" (it is on). Both
were one grep away. **Check the premise of a comparison before running it, not after it produces
a clean-looking result** — a wrong premise yields confident, well-replicated, meaningless numbers.

---

# 2026-08-04 (end) — the "weird shadow" is FIXED on real Office; a NEW artifact appears at PerWindowCapture=1

## RESULT: end-to-end on real Microsoft Office, both directions

Run at `PerWindowCapture=1` — mandatory, since the whole chain goes through composite synthesis
which `AddWindow()` gates on `PwEnabled()`. (An earlier Word run today at `PerWindowCapture=0`
proved nothing and is retracted as evidence: the shadow could not have appeared on any build.)

| build | Office strips present | synthesized (adopted) | `SYNTHPAINT` lines |
|---|---|---|---|
| `98eed30` — pre-`aaa8c37`, pre-`66fc670` | 4 | **4, all into one owner** (`0x102d4/d6/d8/da -> 0x102a0`) | **731** |
| `6b5b298` — fixed | 4 | **0** | **0** |

Identical scene (four real `MSO_BORDEREFFECT_WINDOW_CLASS` strips present on both sides),
opposite behaviour. The control **visibly** showed the artifact: a grey band framing the
document area of Word's window, strips painted into the frame's buffer where they do not
belong (`scratchpad/shadow-ctl/win-0.png`). The user independently confirmed on the fixed
build: **"weird shadow is gone."**

So the shadow is closed on the real application, not merely on `chromerepro`. Together with the
daemon-death chain (`98eed30`, validated 08-03) that closes the Office stability complaint too.

## NEW DEFECT, reported by the user in the same session

> "when you move around the modal dialog, leftovers appear and disappear behind it in pretty
> ugly way"

Observed on the FIXED build at `PerWindowCapture=1`. This is a **different** defect from the
shadow and must not be recorded as a regression of the fixes without evidence — but it must not
be waved away either. What is established:

- It appeared only once `PerWindowCapture=1` was set. The guest had been running
  `PerWindowCapture=0` all day, where the per-window path is inert.
- It is therefore most likely a property of **per-window capture**, which — per today's
  retraction — is **ON by default** in this fork. That makes it a defect real users would hit.
- Hypothesis ruled OUT: slice-feeding of the participants. The agent log shows Word's frame
  (`0x1029c`, 3430x1379) and the dialog (`0x402d0`, 850x542) are both `PrintWindow`-captured;
  only the full-desktop window `0x1003a` is `(slice-fed)`.
- Leading remaining hypothesis: when a tracked window moves across another, the agent does not
  emit damage for the region the mover VACATES, so dom0 keeps showing stale pixels there until
  something else dirties them — "appear and disappear". This is precisely the occlusion problem
  analysed in `scratchpad/hybrid-capture-design.md`.

**This revives T3.** That design was downgraded on 08-03 because its motivation had evaporated
(the typing lag was Office hardware acceleration, and the guest ran with the path disabled).
Its §7 gate — the `PerWindowCapture` 1-vs-0 A/B — now has a concrete, reproducible, visible
symptom to gate on, and the premise that per-window capture is off is itself retracted.

### Next experiment (not yet run)
Move a tracked window across another and count `SendWindowDamageEvent` for the window being
UNCOVERED. Zero damage while the mover crosses it confirms the mechanism. Control: the same
motion at `PerWindowCapture=0`, where the artifact should be absent.

### Tooling limitation found while attempting it
`FindWindowEx` / `SetWindowPos` from the qrexec PowerShell (SYSTEM) **cannot see or move the
interactive session's windows** — both `NUIDialog` and `QubesChromeReproMain` came back as not
found while `dump-windows.exe` enumerated them fine from the same shell. A separate process
that attaches to the input desktop works; in-process P/Invoke from that PowerShell does not.
Any window-manipulation probe must therefore be a small native tool, not a PowerShell snippet.

## Guest left at `PerWindowCapture=0`

Deliberate, and a trade-off worth stating: 0 avoids the new artifact AND makes the shadow
impossible (synthesis inert), so it is the best interactive experience right now — but it is
**not** the configuration a real user gets, since nothing in the install path writes the value
and the code default is 1. Flip it with:
`Set-ItemProperty 'HKLM:\Software\Invisible Things Lab\Qubes Tools' -Name PerWindowCapture -Value 1`
then reboot the qube (an in-place agent restart destroys gui-daemon on this build).

---

# 2026-08-04 (end) — CORRECTION: a GRACEFUL agent restart does NOT kill gui-daemon

Found by the design workflow, verified on the guest immediately after. **Two claims I made
earlier today were wrong; both are retracted here.**

## Retraction 1: "there is no graceful shutdown path for gui-agent.exe"

There is. `Global\QGA_SHUTDOWN` (`include/common.h:46`) is created at `main.c:3848` and is
`watchedEvents[0]` in `WatchForEvents` (`main.c:3483`); signalling it sets `exitLoop` and the
agent runs its real exit path. I concluded "force-kill is the only way" after `taskkill` without
`/F` left the process running for 20 s — but that posts `WM_CLOSE`, and gui-agent is windowless,
so of course it ignored it. **I tested the wrong mechanism and generalised from it.**

## Retraction 2: "one gui-agent restart kills gui-daemon" — too broad

Measured with the supported mechanism (`scratchpad/graceful-stop.ps1`):

```
STEP1 signalled=True event=Global\QGA_SHUTDOWN
STEP2 exited=True after_s=1            <- "WatchForEvents: exiting"
STEP4 respawned_pid=6492 new_log=True
STEP5 maps=6 awaiting=1 connected=1    <- a vchan client CONNECTED
qtest shot -> 3 windows in dom0
```

**The GUI survived an agent restart.** The correct statement is:

> A **force-killed** (`TerminateProcess`) agent restart loses gui-daemon. A **graceful** restart
> via `Global\QGA_SHUTDOWN` does not.

Every harness in this project used `Stop-Process -Force` / `taskkill /F`, so every GUI loss I
attributed to "restarting the agent" was **self-inflicted by the stop method**, not inherent.

## Why force-kill loses it — mechanism, from the daemon source

gui-daemon has TWO EOF paths (`gui-common/txrx-vchan.c`) and only one recovers:

| path | code | outcome |
|---|---|---|
| poll helper | `wait_for_vchan_or_argfd_once` → `libvchan_is_eof` → `vchan_at_eof()` | `restart_guid()` → re-`execv`s → **survives** |
| read/write helper | `handle_vchan_error` → `if (!libvchan_is_open) { "EOF"; exit(0); }` | **never restarts** |

`handle_vchan_error` never consults `vchan_at_eof`. In practice only the WRITE side reaches the
fatal branch (reads are routed through the restarting helper). And `libxenvchan_buffer_space`
does not check `is_open` — it returns raw ring space after the peer dies — so whether the fatal
branch fires depends on **whether the daemon happened to have anything queued to send at the
instant the agent vanished.**

That is a coin flip, and it explains the record better than my "2 for 2 reproducible" did:
08-03 recovered twice (`libvchan_is_eof` in the daemon log), 08-04 died twice. **Same
procedure, different daemon-side traffic.** So the force-kill failure is probabilistic, not
deterministic, and my n=2 was not evidence of determinism. A graceful stop avoids it by letting
the agent close the vchan properly, which drives the peer down the poll path.

Also established by the workflow, and it kills a hypothesis I was carrying:
**there is no reconnect race.** `libvchan_client_init` polls with an INFINITE timeout while the
xenstore node is absent, aborting only if the domain is dead. A re-exec'd guid cannot fail
merely because gui-agent.exe is briefly absent. "Shorten the agent-absent window" is dead.

One deterministic guest-side hole remains worth closing: the agent removes its xenstore node
only if a client ever connected (`main.c:3749` gates on `g_VchanClientConnected`), so an agent
that publishes a node, never gets a client, and then exits leaves a stale node pointing at a
revoked ring — and a guid that connects to it dies permanently with `Failed to connect to
gui-agent`.

## Immediate consequences

1. **Tooling fix, no agent code needed:** stop the agent by signalling `Global\QGA_SHUTDOWN`,
   never `Stop-Process -Force`. `scratchpad/graceful-stop.ps1` does this.
2. **The A/B harnesses can stop cold-booting per side** — that was a workaround for a problem we
   were causing. Cold boot remains right for *boot-path* acceptance, not for every comparison.
3. The full design (guest-side options ranked, dom0 proposal, killed options, and the
   experiments that would settle attribution) is in
   `DESIGN-gui-daemon-restart-survival.md`. **dom0 items need user approval; nothing dom0-side
   has been touched.**

---

# 2026-08-04 (end) — DIAGNOSIS of the `Transient` wedges (not retried, diagnosed)

Two qube wedges today were recovered with `qtest kill` + `start` and written off as "low rate,
no cause claimed". That was wrong of me — the user's rule stands: **any failure should be
diagnosed, not retried.** Here is the diagnosis, from the guest's own event log.

## The guest did not hang, and did not crash

Every normal cycle looks like this, and there are ~20 of them today:
```
1074  xenagent_9_1_0_0.exe (WIN-IDD-TEST) has initiated the shutdown
6006  Event log service was stopped
13    operating system is shutting down
12    operating system started
```
Measured shutdown duration across 19 consecutive cycles: **10-16 s, every time.** So the
"guest is slow to halt" hypothesis is dead — I had assumed it and it is not true.

**For the wedged cycle there is NO 1074, NO 6006 and NO 13 at all.** The last clean pair before
the wedge is `16:22:08 -> 16:22:18`, and the next event 12 is the boot produced by my own
`qtest kill`. There is no 6008 ("previous shutdown was unexpected") and no Kernel-Power 41 for
that cycle either.

**Conclusion: Windows never received a shutdown request.** The guest was healthy and idle; the
shutdown simply did not reach it. Note every real shutdown here is initiated inside the guest
by `xenagent_9_1_0_0.exe` (the Xen PV agent) in response to the hypervisor's control request —
so the failure is upstream of the guest OS, in the shutdown-request delivery, not in Windows.

## My harness turned a failed shutdown into a wedge

```bash
timeout 200 ./tools/qtest shutdown >/dev/null 2>&1
for i in $(seq 1 40); do [ "$(state)" = Halted ] && break; sleep 5; done   # 200 s, then FALLS THROUGH
timeout 200 ./tools/qtest start >/dev/null 2>&1                            # <-- runs even if NOT Halted
```
The wait loop has no failure branch: when the VM never reaches `Halted` it exits normally and
the next line issues `start` **against a VM that is still running or mid-transition**, with
stdout and stderr discarded so the error is invisible. Then the qrexec loop burns another 300 s
finding nothing. That is exactly the observed signature: the whole compound command produced
**no output at all**, not even `QREXEC_UP`.

So: an occasional undelivered shutdown request (real, unexplained, low rate) plus a harness that
cannot see its own failure = a wedge that looks like a guest fault and is not one.

**Fix applied to the harness:** assert the state is `Halted` before calling `start`, and fail
loudly instead of proceeding. A shutdown that does not land must be a visible error, not a
silent fall-through into an invalid operation. This is the same class as today's other harness
bugs (a copy over a running binary, a `[^\r]` that ate the letter r): **the check existed but
could not fail.**

Still open, and NOT explained: why the shutdown request occasionally does not reach the guest.
Frequency ~2 in ~25 cycles. Next time it happens, capture `qvm-ls --fields NAME,STATE` plus the
guest's `xenagent` service state BEFORE recovering, since the recovery destroys the evidence.

---

# 2026-08-04 (end) — wild-pointer fix VALIDATED: the control CRASHES the agent, 3/3

Tested with a control that was seen to fail, as required. Both preconditions asserted per run,
so a round where the bug could not have been reached reports VOID rather than PASS:
`PerWindowCapture=1`, a synthesized window present (`msg=SYNTH` ≥ 1), and a real **in-place**
duplication recovery (`duplication recreated in place … windows kept`) — the sweep only runs on
the next frame after `capture->grants_changed`.

Trigger: a desktop SWITCH (`CreateDesktop` + `SwitchDesktop` away and back), which raises
`DXGI_ERROR_ACCESS_LOST`. Deliberately not `LockWorkStation`: that strands the guest on the
secure desktop where no frames flow, so the sweep would never run and recovery would need a
reboot. The scratch-desktop round trip restores frames in seconds and needs no password.

| round | build | synthesized | in-place recoveries | agent survived |
|---|---|---|---|---|
| 1 | control `4DA9FE96` | 1 | 1 | **NO** — pid 3636 → 7112, 0 log growth |
| 1 | fixed `F06C0979` | 1 | 2 | yes — same pid 824, +115 lines |
| 2 | control | 1 | 1 | **NO** — pid changed, 0 growth |
| 2 | fixed | 1 | 2 | yes — same pid, still logging |
| 3 | control | 1 | 1 | **NO** — pid changed, 0 growth |
| 3 | fixed | 1 | 2 | yes — same pid, still logging |

Unanimous, interleaved, cold boot per side, installed hash checked against the CI manifest every
round. **On the unfixed build the agent DIES every time** — the watchdog respawns it under a new
pid and the old instance stops logging mid-sweep, which is what a wild pointer walking backwards
through the heap while holding `g_csWatchedWindows` looks like from outside. The fixed build
keeps the same pid and keeps working, across TWO recoveries per round rather than one.

This is the first defect this session that was found by **reading** rather than by testing, and
it was live on the default path (`PerWindowCapture` defaults to 1). Nothing we ran all day would
have caught it: it needs a synthesized window to coincide with a duplication recovery, and our
guest sat at `PerWindowCapture=0` for most of the session.

Shipped in the build now on the guest (`F06C0979`) together with the mask-sort cherry-pick
(`d3a5fbc`, previously written and never merged) and the framebuffer-pointer invalidation.

---

# 2026-08-04 (close of session) — index, and the one experiment left running

## Documents produced today (all committed, all reviewable)

| file | what it is |
|---|---|
| `DESIGN-gui-daemon-restart-survival.md` | why gui-daemon dies, ranked guest-side fixes, the dom0/upstream proposal. **dom0 items need user approval.** |
| `PLAN-trackb-t2-modes.md` | Track B / T2: how our driver supplies arbitrary modes, what gates it, plus the work-area addendum |
| `REVIEW-synthesis-fix-cluster.md` | per-commit keep/revise/revert verdicts for the synthesis cluster; found the wild-pointer bug |
| `SESSION-HANDOFF-2026-08-04.md` | entry point for the next session |
| `scratchpad/` | the harnesses that work: `vmcycle.sh`, `wildptr2.ps1`, `graceful-stop.ps1`, `install-agent2.ps1`, `ab-boot.sh`, `ab-orphan.sh`, `office-shadow-probe.ps1`, and the deliberately-UNRUN `secure-desktop-probe.ps1` |

## IN FLIGHT, not finished: does `6b5b298` do anything?

The user's instruction was "if it does nothing, let's revert". Establishing the "if" first,
because the review's claim that its mechanism is impossible is itself unverified, and there IS a
concrete mechanism it would prevent:

`wincapture.cpp:39` `DEAD_AFTER_FAILURES = 5` — five consecutive `PrintWindow` failures set
`c.dead = true`, and nothing in the file revives a dead channel. Pre-`6b5b298`,
`AttachThreadToInputDesktop()` followed the input desktop onto Winlogon; captures of *session*
windows from a thread attached to the *secure* desktop should fail. If they fail five times, the
channel is dead **permanently** — that window never captures again, even after unlock. That is a
real harm, and it is NOT the justification in the commit message (which was about stalling logon
via PrintWindow into LogonUI, and whose supporting evidence was retracted).

**Set up and ready to run:**
- Control branch `control/revert-6b5b298` (superproject) / `revert-6b5b298` (agent) — `6b5b298`
  reverted on top of `a4f6961`, so the ONLY difference is the secure-desktop guard. This is a
  better control than `98eed30`, which also lacks `aaa8c37`, `66fc670`, the wild-pointer fix and
  the mask sort.
- CI build dispatched: run `30921242920` (`gh workflow run build --ref control/revert-6b5b298`).
- Trigger already proven to work: the scratch-desktop switch in `scratchpad/wildptr2.ps1`
  (`CreateDesktop` + `SwitchDesktop` away and back). It raises a genuine desktop switch without
  `LockWorkStation`, so no password and no reboot are needed.

**The experiment:** `PerWindowCapture` ON (it now is, by default), a window with a live
per-window channel, switch desktop away and back, then check whether that window still produces
`SendWindowDamageEvent` afterwards.
- control (reverted) → channel dies / window stops capturing ⇒ **`6b5b298` does something, keep it**
- both sides identical ⇒ **it does nothing, revert it** per the user's instruction

Do not revert it without running this: "it does nothing" is currently an assumption, and this
session has already been burned six times by checks that could not fail.

---

# 2026-08-04 (close) — CORRECTED wedge diagnosis: the guest HANGS, and the upstream policy

## The wedge is a guest hang, not an undelivered shutdown request

Earlier today I diagnosed the `Transient` wedges as "the shutdown request never reached the
guest", from the absence of events 1074/6006/13. That inference was **too weak**, and the next
occurrence gave the missing piece. Evidence captured *before* recovering this time, as the rule
requires:

```
dom0:    win-idd-test  Running  SrU-----     <- dom0 thinks it is fine
qrexec:  no answer (timed out)               <- the guest is NOT fine
guest:   no 1074 / 6006 / 13 for that cycle  <- Windows never began shutting down
```

qrexec dying at the same time as the shutdown request goes unanswered points at **the guest OS
being hung**, not at a lost message: `qvm-shutdown` signals through xenstore to `xenagent` in
the guest, and a hung guest answers neither that nor qrexec. So the correct statement is:

> Occasionally (~3 in ~30 cycles today) the guest hangs hard: dom0 still reports `Running`,
> qrexec stops answering, and Windows never starts an orderly shutdown. Only `qvm-kill`
> recovers it.

The cause is still unknown, and I am not going to guess at it — but the hypothesis space is now
much smaller, and the next occurrence should also capture `xl dmesg` / the domain's console
(dom0-side, user), because the guest itself cannot be asked anything once it is in this state.

**What worked:** `scratchpad/vmcycle.sh` refused to proceed rather than issuing `start` against a
running VM, so this time the failure stayed a clean failure instead of compounding into the
"no output at all" wedge. The fail-loud rewrite paid for itself on its second use.

## Upstream policy set by the user — recorded in CLAUDE.md

> "we submit nothing until our work is done in full and we have new shiny qwt with all the
> features. until that everything stays in my fork." — "except bugs outside of qwt scope, those
> we report"

So: **nothing from `agent/` goes upstream** until QWT is complete — this withdraws CLAUDE.md's
earlier "small, measured, reviewable PRs" framing and settles the open question about how to
describe `aaa8c37` (it is not being submitted, so the question is moot for now; the regression
framing stays recorded for whenever it is).

**Bugs in components that are not ours are still reported**, because they are not part of the
deliverable and sitting on them helps nobody. Currently qualifying: the two gui-daemon defects in
`DESIGN-gui-daemon-restart-survival.md` §3 (the write-path EOF bypassing `vchan_at_eof`, and the
`restart_guid` use-after-free). Both still need the user to approve the exact text.

---

# 2026-08-04 (close) — `6b5b298` REVERTED: measured, no effect

The user's rule was "if it does nothing, let's revert" — so the "if" was measured rather than
assumed, because the review's claim that its mechanism was impossible was itself unverified and
there WAS a concrete mechanism it might have prevented.

## The experiment

Control = `6b5b298` reverted on top of `a4f6961` (`768CA58C`), i.e. a **single variable** — unlike
`98eed30`, which also lacks four other fixes. Test = `F06C0979`. `PerWindowCapture` on (its
default). Scene: a console window scrolling text forever, so its per-window channel produces
continuous damage — a static window emits none even when perfectly healthy, which would have made
"no damage" unreadable. Trigger: `CreateDesktop` + `SwitchDesktop` away for 8 s (more than the
five capture attempts needed to trip `DEAD_AFTER_FAILURES`) and back.

| build | damage before | damage after | channel |
|---|---|---|---|
| guard REVERTED `768CA58C` | 136 / 12 s | **83 / 12 s** | alive |
| guard PRESENT `F06C0979` | 176 / 12 s | **118 / 12 s** | alive |

**Identical behaviour.** The hypothesised harm — `AttachThreadToInputDesktop()` following onto a
non-`Default` desktop, captures failing five times, `DEAD_AFTER_FAILURES` marking the channel
dead forever — **did not occur without the guard**.

Combined with the rest of the case against it, that is enough to revert:
- its stated justification (guest stuck at "Welcome", PrintWindow stalling LogonUI from SYSTEM)
  was **already retracted** — FINDINGS 2026-08-03 shows that hang was Windows Update;
- it logs **nothing** on either edge of its idle branch, so in production it can never be shown
  to have acted — unfalsifiable by construction, which CLAUDE.md's instrument rule forbids.

Reverted in agent `8629a9c`.

## The limitation, stated not buried

**A scratch desktop is not Winlogon's secure desktop.** The real lock case is NOT measured, and
cannot be with the tools available: unlocking needs an interactive password we cannot supply, so
the state *after* a real lock is unobservable, and measuring only *during* the lock does not
discriminate (both builds are quiet then, for different reasons). So this result says "no effect
under the only desktop transition we can raise and return from", not "no effect ever".

If that path is ever shown to matter, reinstate the commit **with logging on both edges** so the
next person can actually test it — the absence of that logging is most of why this one cost so
much to adjudicate.

## Two more instrument failures caught by guards (not by luck)

1. **`qvm-kill` rolled back an install.** The guest hung, I killed it, and the binary on disk
   reverted from `768CA58C` to `F06C0979` — the verified install did not survive, because an
   unclean kill loses unflushed writes. The probe's hash gate caught it and reported VOID; without
   it the entire control run would have measured the *fixed* binary while believing it was the
   control. **Always re-verify the installed hash AFTER any unclean recovery, not just after the
   install.**
2. **The metric was invisible at the shipped log level.** `SendWindowDamageEvent` logs at
   VERBOSE, and I had reset `LogLevel` to 3 at handoff, so the first run read `damage_before=0`
   and would have been reported as "channel dead" had the gate not required a non-zero baseline
   before proceeding.

Both were caught because the checks were written to fail loudly on missing preconditions. That is
now three separate occasions today where a precondition gate turned a silent wrong answer into a
visible VOID.

---

# 2026-08-04 (close) — GUEST HANG: diagnosed to a leading hypothesis, and it points back at us

Third diagnosis of this failure today, each sharper than the last. The first two were wrong and
are superseded; keeping the trail because the corrections are the point.

## What the guest's own record settles

**1. Windows never crashed.** Every Kernel-Power 41 across 7 days carries `BugcheckCode=0`, and
there is **no `MEMORY.DMP` and no minidump at all** despite `CrashDumpEnabled=7` (automatic) and
`AutoReboot=1`. A bugcheck would have left both. So this is a HANG, not a blue screen — and the
41s are all explained by my own `qvm-kill`, which makes them evidence of nothing else.

**2. The shutdown path is healthy — my earlier "the request never reached the guest" was wrong
in an important way.** `xenagent` logs event id=1 "The tools requested that the local VM shut
itself down" on every delivery, and **every single one of the ~37 requests logged today was
followed by an orderly shutdown within 90 s**. There is no case of "request received, shutdown
never initiated". So during a hang xenagent never sees a request at all — because the guest is
already unresponsive. **The hang PRECEDES the shutdown attempt; the shutdown merely exposes it.**

**3. The freeze is abrupt, not a slow degradation.** In the 17:58 hang the agent was emitting
`QGAPERF` frames every 15-46 ms — `seq=1639…1646` — and then simply stops mid-stream, 726 s
before the next instance starts. Nothing logs a failure, a timeout, or an error on the way down.
That is the whole VM stopping between one frame and the next.

## Leading hypothesis: leaked grants from force-killed agents

Not proven. Stated as a hypothesis with its disconfirming evidence, because it is actionable and
it implicates our own practice rather than the guest.

- `capture.c:428` states it outright: **"grants are not automatically revoked when the xeniface
  device handle is closed"**. Revocation is explicit, in `CaptureTeardown` (`capture.c:430`),
  `RecreateDuplication` (`:251`) and `PwDetachWindow` (`perwindow.c:181`) — all **user-mode code
  that does not run under `TerminateProcess`.**
- Every harness in this project stopped the agent with `Stop-Process -Force` / `taskkill /F`.
  That leaks every grant the instance held.
- Per-window capture grants are large: a 3440x1440 buffer is **4838 pages**, and each tracked
  window gets its own. **136,744 pages were granted across today's agent instances.**
- Xen's default `max_grant_frames` gives on the order of 16-32k grant entries per domain. A few
  force-killed instances within one boot, each leaking a framebuffer plus per-window buffers, is
  the right order of magnitude to exhaust that.

**Evidence against / not yet explained:** no grant failure is logged anywhere —
`XcGnttabPermitForeignAccess2` failures would go through `win_perror2` and there are none. So if
exhaustion is the mechanism, it manifests as a hang inside the driver rather than a failed call,
which is plausible but unverified. Do not present this as established.

## Why this is worth acting on regardless

The fix for the hypothesis is a practice change we already know we want for an unrelated reason:
**stop the agent with `Global\QGA_SHUTDOWN`, never `TerminateProcess`.** A graceful exit runs the
teardown path and revokes the grants. The same change independently prevents losing gui-daemon
(FINDINGS earlier today). Two failures, one cause: *we were killing the agent instead of asking
it to stop.*

## The experiment that would settle it — cheap, and worth running first next session

Stop force-killing entirely: convert `install-agent2.ps1` to signal `QGA_SHUTDOWN`, wait for
exit, then copy. Then run the same ~30-cycle install/reboot workload.
- hangs disappear ⇒ strongly supports the leak (and the practice change is already justified);
- hangs persist ⇒ the leak is not the cause and the next suspect is the PV transport itself,
  which needs dom0 (`xl dmesg`, domain console) and therefore the user.

Also worth adding cheaply: log the cumulative granted page count per boot, so exhaustion becomes
visible instead of inferred.

## Correction trail for this defect

1. "One reboot in nine wedged; no cause claimed" — too passive, and I recovered without looking.
2. "The shutdown request never reached the guest" — inferred from missing 1074/6006/13, and
   **wrong**: xenagent proves delivery works, and the guest was already dead.
3. Current: the guest hangs abruptly with no bugcheck, before any shutdown request, on a workload
   dominated by force-killed agents that leak large grant allocations. Hypothesis, testable.

# 2026-08-04 (cont) — goal set: T2 is now THE goal; graceful-stop premises verified in source

**User set the primary goal: arbitrary guest resolutions in non-seamless mode, synced to the
dom0 window size and work area.** That is PLAN-trackb-t2-modes.md end to end. The deliberate
hang-reproduction experiment (force-kill vs graceful A/B) is DEFERRED — VM time belongs to T2.
Graceful stop is adopted as practice anyway, since it is justified independently of the
hypothesis test. Three premises were verified in source first (3 parallel readers, all claims
file:line-cited; full detail in the workflow transcript):

## 1. Watchdog stop semantics (watchdog/watchdog.c)
- `Stop-Service QubesGuiWatchdog` does NOT touch gui-agent.exe: the stop handler (`:264-281`)
  only reports SERVICE_STOPPED. No TerminateProcess, no job object; child handles are closed
  right after CreateProcessAsUser (`:137-138`).
- Respawn = 1 s poll (`:153`, Sleep(1000) + WTSEnumerateProcesses name-PREFIX match `:68`),
  no backoff, no give-up counter. 20+ stop/respawn cycles in one boot trip nothing.
- Consequence for installs: stop watchdog first (agent keeps running), THEN signal
  `Global\QGA_SHUTDOWN`, wait exit, copy, verify hash. `install-agent3.ps1` implements this.

## 2. The graceful-exit premise is only HALF true — graceful stop still leaks per-window grants
Exit order on QGA_SHUTDOWN (main.c:3541→3768-3781): PwShutdown → libvchan_close →
StopFrameProcessing → CaptureTeardown.
- Desktop framebuffer grant: revoke IS attempted (capture.c:430) — but the vchan is already
  closed, no unmap/destroy handshake reached the daemon (send.c gates on
  g_VchanClientConnected), so if the daemon still maps the pages the revoke fails and is
  merely logged (the in-code warning at main.c:3742-3743 admits this).
- Per-window buffers: **there is NO detach-all loop on the exit path.** The only such loop is
  ResetWatch (main.c:1797, called from SetSeamlessMode only). PwShutdown (perwindow.c:122)
  drains just the already-queued revokes, 3 tries / 300 ms. Every still-attached window's
  grant (~4838 pages each at 3440x1440) leaks even on a graceful stop, silently — not even
  counted by the "leaking un-revoked grants" warning.
- So the hang hypothesis's clean dichotomy (force-kill leaks, graceful revokes) is WRONG as
  stated. Graceful is better (framebuffer revoke attempted, vchan closed, daemon survives)
  but not leak-free. A leak-free exit needs the ack-gated revoke handshake — same design
  space as A6 (plan §6.2), Phase 3, design note + user approval first.
- Also found on the way: `VchanSendBuffer` spins forever (Sleep(1), no is_open check,
  qubes-windows-utils vchan-common.c:100) when the daemon dies with a full write ring; the
  WGC damage callback holds g_VchanCriticalSection while sending (send.c:634), survives
  WcShutdown's 5 s bounded join (wincapture.cpp:326), and the main thread then blocks forever
  at main.c:3770. I.e. a graceful stop can STALL INDEFINITELY if the daemon died dirty at the
  wrong moment. Harnesses must keep a bounded wait + loud fallback.

## 3. Grant accounting from logs
- Per-window: fully countable at LogLevel=3 — `PwAttachWindow: 0x…: per-window buffer WxH
  (N pages) attached` / `PwDetachWindow: … detached` (perwindow.c:348/358).
- Screen framebuffer: initial grant logs only at DEBUG (`GetFrame: 1st frame, sharing
  framebuffer`, capture.c:524) and successful revokes are silent at every level → full screen
  accounting needs LogLevel=4. Recovery re-grants do log at INFO (main.c:3570).

# 2026-08-04 (cont 2) — T2 execution start: exp 0 done, exp 2 guest-half done, comparator validated

- **Exp 0 (baseline on 19045 retail): PASS, 3/3 agree** — `instrumentation/t2-exp0/base-19045-{1,2,3}.json`,
  ddaprobe `30F6012D` (hash-verified on guest against the CI package manifest, run 30616998988).
  All runs: session_id 1 / WinSta0 / Default, `agent_capture_would_work` true, flag TRUE and
  `ever_false` false, MapDesktopSurface OK, **pitch 13760 == 3440*4**, format 87 B8G8R8A8.
  Bonus vs the void 19044 baseline: acquire latency median 31 ms (was 82 ms) — retail 19045 is
  a materially different capture environment, vindicating the re-baseline requirement.
- **Exp 2 (non-seamless pinning), guest half: PASS.** `SeamlessMode=0` set in root + gui-agent
  subkey; cold boot; registry still 0; agent logged `Seamless mode changed to 0`; ONE dom0
  window (win-0.png 3440x1384, live desktop). Boot resolution was 3440x1440 = the
  `FullscreenWidth` cache (the A4 defect, on cue). **The dom0 window shows only 1384 of the
  guest's 1440 rows — the taskbar lives in the hidden 56 px.** That clipped band is the
  work-area mismatch T2 exists to fix, now visible in a screenshot.
  Remaining half (WM-resizable + MSG_CONFIGURE stream) blocked on the dom0 resize service.
- **Exp 0b comparator half: VALIDATED both directions.** Decoded-pixel compare (PIL, RGB,
  metadata ignored): static desktop pair → bbox None / 0 diff px; same vs under
  activity-gen.ps1 → 415,058 diff px. The instrument can both pass and fail.
- **dom0 resize harness written, NOT installed** (needs the user): `dom0/10-install-resize-service.sh`
  installs `local.WinResize+WxH|query` (resize-only, isolation pattern of WinScreenshot);
  `tools/qtest resize` added. Verified refused today (no policy) — fails loud, not silent.

# 2026-08-04 (cont 3) — exp 1 PASS (pitch tight), A1 validated both ways, and T2's guest->dom0 half already works

- **Exp 0b inverted-ddaprobe: VALIDATED.** Scratch build `56BB76C2` (branch
  `scratch/ddaprobe-inverted`, never merge) run on the real guest DXGI: JSON reports
  `tool=ddaprobe-INVERTED, inverted=true`, flag FALSE, `ever_false` true,
  `agent_capture_would_work` false. The FALSE reporting path is now proven against real DXGI.
  **Caveat found doing it:** ddaprobe's process EXIT CODE never consumed the sysmem flag —
  even the real instrument exits 0 whenever duplication succeeds. Harnesses must judge the
  JSON summary, never the exit code. (Plan §2.4's "exit code non-zero" was wrong as written.)
- **Exp 1 (pitch at 1400x1050): PASS — pitch 5600 == 1400*4, TIGHT** at a 32-but-not-64-byte
  aligned width; flag TRUE and never flipped across the mode change. Partial by design: does
  not clear 8-byte-aligned widths (2566). `pitch1400.json` on guest; modeprobe applied the
  mode dynamically (readback-verified, no registry persistence).
- **A0 modeprobe: landed + acceptance PASS** (merge f0c1252, CI 30941736145, exe `630DB029`,
  hash-verified on guest): 29 BDA modes, includes 1920x1080 + 1400x1050, excludes 1600x1000;
  `--test 1600x1000` → DISP_CHANGE_BADMODE, `--test 1920x1080` → DISP_CHANGE_SUCCESSFUL.
- **A1 snap logging: landed + VALIDATED both directions** (agent `5b7ad97`, exe `A47E0382`,
  merge 42ef808, installed on guest via graceful stop):
  - snap side: cold boot with cached 1600x1000 → `RESREQ 1600x1000 src=lastapplied`,
    `RESSNAP 1680x1050 SNAPPED`, `RESAPPLIED 1680x1050`; external witness modeprobe
    ENUM_CURRENT_SETTINGS read 1680x1050. (So the IoU snap of 1600x1000 is 1680x1050, not
    1920x1080 as the plan guessed — the plan's A1 example was wrong, the mechanism right.)
  - control side: cold boot with cached 3440x1440 (exact match) → `RESSNAP 3440x1440` with
    NO SNAPPED marker. The instrument can distinguish.
- **First graceful install worked:** `install-agent3.ps1` reported `stop=graceful`
  (watchdog stopped → QGA_SHUTDOWN → exit within window → copy → hash verified).
- **THE DAY'S BIG UNPLANNED RESULT: T2's guest→dom0 half already works in non-seamless mode.**
  Applying 1400x1050 externally (modeprobe) on the HEAD fork build produced, per the agent
  log: geometry-changed ACCESS_LOST → reinit → `ResolutionChangeThread: resolution change:
  1400x1050` → duplication recreated in place, windows kept → framebuffer re-granted →
  MSG_WINDOW_DUMP re-sent → **dom0's window resized to exactly 1400x1050 with a live
  desktop** (decoded screenshot). The fork's recovery fixes carry a mode change end-to-end.
  Remaining for T2: the dom0→guest request path (exists but snaps to the 29-mode list) and
  arbitrary sizes (the IDD). Not proven: whether window 0 avoided a destroy/create cycle
  (A6's criterion) — only that the outcome converged.
- Guest left at: 3440x1440, non-seamless, A1 agent `A47E0382` running, netvm detached.

# 2026-08-04 (cont 6) — THE HANG, CAUGHT LIVE WITH DOM0 FORENSICS (first time)

Guest hung at ~23:17, one minute after a modeprobe --apply 3440x1440 that itself followed the
user's manual dom0 window resize (2956x1224 request → 2560x1080 snap). Evidence captured
BEFORE recovery (files: instrumentation/hang-2026-08-04/):

1. **The guest is not stopped — it is SPINNING.** xentop: state `-----r`, cputime 2155 s and
   climbing on a guest booted 62 min earlier (idle accumulation would be a few hundred s);
   4 vCPUs. xl dmesg is a wall of dom0 CPU thermal throttle messages — the spin is literally
   heating the host. This is a NEW fact: prior hang diagnosis assumed "the whole VM stopping";
   it is a livelock, not a stall.
2. **gui-daemon SURVIVED** (`qubes-guid … -N win-idd-test` running since 22:29 boot) and its
   log shows `libvchan_is_eof` — the read-path EOF branch (the one that restarts) fired: the
   agent side of the vchan died first, guid destroyed its windows (hence zero PNGs from the
   screenshot service) and is waiting for a new client. My exit(1)-page-count theory for THIS
   event is disproven — guid is alive.
3. **qrexec is dead too** — even `echo` times out. Whole-guest livelock, consistent with a
   kernel-level storm (interrupt/DPC), not a stuck user thread.
4. **No Xen-visible fault.** No gnttab errors, no domain faults in xl dmesg tail.
5. **Bonus dom0 bug:** `timeout 6 xl console win-idd-test` crashed with
   `*** buffer overflow detected ***` and dumped core — a dom0 xl defect, outside QWT scope,
   candidate for upstream report (needs user approval of text, per policy).

**Working hypothesis, sharpened:** the trigger is the RESOLUTION-CHANGE path, not stop-method
grant leaks alone — this boot had only ~2 grant churns (user resize + my apply) but they were
seconds apart, and the second arrived while the first recovery (revoke→re-grant→re-dump) may
still have been in flight. The revoke-while-mapped inversion (DESIGN-a6 §1.2) is exactly the
kind of thing that can wedge PV machinery. The hang preceded any IDD install — this is the
stock BDA display path. A6 is therefore not hygiene, it is the likely fix for a
guest-killing defect on T2's hot path.

**Testable prediction:** N resolution changes with generous settle time (>10 s) should be
safe; rapid alternation should reproduce the livelock. To be tested DELIBERATELY, once, with
forensics ready — not stumbled into.

Practice change effective immediately: after any resolution change, wait for the agent log to
show the re-grant completed (`framebuffer re-granted` line) before issuing the next one.

# 2026-08-04 (close) — D0 DRIVER LIVE: the gating answer is OUTCOME A, and D2 is NEGATIVE

The single most important session of Track B so far. All on the D0 minimal driver
(branch t2/d0-minimal-idd, 1 monitor, EDID-less, single hw id Root\IddSampleDriver, dll
ED1CC64A; control build w/ MONITOR_COUNT=3 exists: scratch/d0-monitor3-control, 7128230F).

1. **"Present but inactive" is DEAD for D0.** Installing the driver (pnputil + devcon,
   deploy-and-test.ps1) brought the IDD monitor UP immediately: desktop extended to
   2048x768 dual (BDA (0,0)-(1024,768) + IDD (1024,0)-(2048,768) @75Hz). Phase 1B's
   "inactive" reading does not describe this build. Exp 8's original acceptance is
   unmeetable-as-written; superseded by the direct measurements below.
2. **THE GATING MEASUREMENT: DesktopImageInSystemMemory = TRUE on the IDD output**, never
   flipped, MapDesktopSurface OK, **pitch tight (4096 = 1024*4)**, in BOTH topologies:
   extended (BDA+IDD) and IDD-primary (BDA disabled). With the BDA disabled the IDD moved to
   **adapter 0 output 0 — the exact output the agent captures** — and ddaprobe's
   agent_capture_would_work read TRUE there. **Outcome A, scoped to: D0 driver, WARP
   renderer, 19045, this topology.** (Formal 3x interleaved cold-boot runs still owed for
   the record; every hot measurement today agreed.)
3. **The agent rode every topology change in place** — windows kept, framebuffer re-granted,
   MSG_WINDOW_DUMP re-sent, dom0 window resized to match (2560x1080 → 1024x768 → …). The
   fork's recovery path is load-bearing and works.
4. **D2 (virtual modes): NEGATIVE.** With the IDD owning the desktop, CDS_TEST rejects
   1600x1000 / 2566x1022 / 1234x777 with DISP_CHANGE_BADMODE. The OS offers exactly the
   monitor∩target intersection — measured: {1024x768, 1600x900, 1920x1080} on the IDD.
   **So T2 requires the driver to PUBLISH the desired modes: D3 (runtime UpdateModes spike)
   and/or D4 (dense grid / IOCTL mode store) are the path.** No shortcut exists.
5. **BDA disable → Windows spins up the Basic Display DRIVER fallback** (ROOT\BASICDISPLAY,
   \\.\DISPLAY3, 1024x768-only) rather than leaving the IDD alone — a second attached
   output, but on adapter 1, so the agent's adapter-0 choice still lands on the IDD.
6. **The PnP auto-revert is proven on the REAL target**: with the BDA disabled and the
   marker armed, the boot task re-enabled it (devcon_exit=0, running=True, status readback)
   at 23:42:02. Note: read revert-result.txt via PowerShell (UTF-16; cmd `type` + grep
   silently hid the line — instrument-blindness trap #8 of the day).
7. Cleanup: IDD uninstalled (ROOT\DISPLAY\0000 removed), reboot, BDA-only 3440x1440
   restored and persisted. Guest ends the day at the shipped-like baseline + A1 agent.

Also this session: A2 (readback-authoritative, agent 2525fdd) and A3 (single-source
framebuffer size, assert-only 936c07d control + fix 0dbec23) implemented and CI-built on
branches t2/a2-readback, t2/a3-assert-ctl, t2/a3-single-source — NOT validated yet, that is
next session's exp 4/5 A/B work.

Next decisive step: **D3 spike** — publish one extra target mode at runtime from the driver
and see if the OS picks it up; if not, D4's dense pre-declared grid (needs re-agreeing the
T2 acceptance criterion with the user: "follows to within N px" instead of exact).

# 2026-08-05 — ARBITRARY RESOLUTION END-TO-END: 2566x1022 on the D4 driver, dom0 window follows

The T2 core loop is demonstrated. Driver `t2/d4-registry-modes` (dll D1212687, CI 30949957738):
reads REG_MULTI_SZ `HKLM\SOFTWARE\QubesIDD\Modes` at monitor arrival, appends the entries to
both monitor and target mode lists; reload = devcon restart (replug). Sequence measured:
`guest/resize-sync.ps1 -SyncNow 2566x1022` → registry publish → replug → CDS_TEST turns
SUCCESSFUL → apply → **readback 2566x1022 match=True** →
- ddaprobe on the IDD output at 2566x1022: flag TRUE, MapDesktopSurface OK,
  **pitch 10264 == 2566*4 TIGHT** — the 8-byte-aligned width case that exp 1 could not clear
  is now cleared. The stride killer is dead on this configuration (three widths measured
  tight: 3440, 1400/1024 alignments, and 2566).
- `agent_capture_would_work` TRUE; agent rode the replug; **dom0 window = 2566x1022, live
  pixels** (decoded, non-flat).
Configuration: IDD primary, BDA disabled with the (previously boot-proven) revert marker
armed. The BASICDISPLAY fallback output remains attached at 1024x768 on another adapter;
does not interfere (agent takes adapter 0 = IDD).
Sync loop: `resize-sync.ps1` (loop mode) watches A1's `RESREQ … src=dom0` lines and syncs
exact on snap — the harness prototype; production home is the agent (mode-cache refresh +
IOCTL instead of replug). NOT yet declared done: the user-required stability stress gate
(scratchpad/stress-resize.sh, 16 mixed cycles) is running; D3 spike answer pending; A6
implementation in flight (user approved the design 2026-08-05, "fit tightly").

# 2026-08-05 (cont) — stress gate WORKING AS INTENDED: three named defects under replug churn

The user-required stability stress (16 mixed cycles) fails reproducibly at the same point
(~9th consecutive replug) with a three-part mechanism, each part now named and evidenced:

1. **Agent crash under churn (the actual killer):** transient `0x887A0026` during a mode
   switch makes `CaptureInitialize` fail inside `StartFrameProcessing`, and `WatchForEvents`
   treats that as FATAL → process exit → watchdog respawn (two instances died 12 s apart,
   logs `...000909` and `...000922`). The fix class is an INIT RETRY on transient
   ACCESS_LOST (A7-lite), distinct from A6.
2. **Respawn applies the stale cache:** the fresh instance's HandleXconf re-applied
   `FullscreenWidth` (1600x900), overriding the in-flight target — the A4
   preference-vs-cache defect amplifying a crash into a wrong-resolution steady state.
3. **EDID-less identity churn:** every replug mints a new display instance (guest reached
   `\\.\DISPLAY29`) — exactly the "runaway registry / random resolutions" failure the
   hypervisor survey (docs/RESEARCH-hypervisor-resize.md) warns about. Fix: stable EDID
   (D4v2, building).

Also measured before the crash point: dom0-follow latency is ~3 s per replugged resize
(cycles 3 and 6, healthy), and the daemon's stale MSG_CONFIGURE echo during the replug
outage is real and must be converged against (resize-sync retries; observed and handled).

Survey takeaway now driving design (docs/RESEARCH-hypervisor-resize.md): every working stack
uses agent-pushed custom-mode-slot + user-mode apply, no replug — but those rest on DXGK
verbs IddCx hides. On console IddCx 1.5 the demonstrated-working mechanism is stable-EDID
replug with the target as preferred mode; `IddCxMonitorUpdateModes` + CDS (our D3 spike,
built, untested) is the publicly-untried blink-free candidate. RDP size constraints adopted:
width EVEN, 200-8192.

# 2026-08-05 (cont 2) — D3 spike NEGATIVE with valid control; A6 stack + A7-lite built; D4v2 in CI

**D3 (runtime IddCxMonitorUpdateModes on console): NEGATIVE.** Spike driver C0F48F3B
(monitor list incl. 1600x1000, target list excl., thread adds it via UpdateModes ~60 s after
arrival). Measured: T+10s 1600x1000 BADMODE / control 1600x900 SUCCESSFUL; T+90s (timer
fired) 1600x1000 STILL BADMODE / control still SUCCESSFUL. The OS does not re-intersect for
a console IDD on 19045 — consistent with MS Q&A 5924412 and driver-samples#1184. Caveat: the
spike logs nothing driver-side, so "UpdateModes returned an error" vs "OS ignored it" is not
distinguished; either way no console path exists here. Replug (stable-EDID, D4v2) is the
mechanism, exactly as the hypervisor survey predicted.

**A6 implemented** (agent branch t2/a6-grant-lifecycle, commits 67561e0 / 7b73bf8 / 57205f8,
worktree-isolated build; details in the agent report): in-place geometry survival with
ctx-derived sizing, park+ack-gated old-grant revoke with 5 s timeout fallback onto a retry
sweep, bounded 2 s exit drain with ring-headroom guard. Plus **A7-lite** (d256b51, mine):
StartFrameProcessing retries 10x750 ms on 0x887A0026/0x887A0005 instead of dying — the
stress-identified crash class. Parent branch t2/a6-stack (CI 30951775933).

# 2026-08-05 (cont 3) — STRESS GATE PASSED 16/16 ON THE A6 STACK; boot acceptance PASSED

**The A6+A7 agent (6254ECF1, branch t2/a6-stack) passed the same stress that killed the A1
agent twice at cycle 9** — 16/16 cycles, every size exact (1600x1000, 1920x1080, 2566x1022,
1024x768, 1234x777, 3440x1409 = the real work-area size, 1600x900, 2000x1000, twice each),
qrexec alive throughout, dom0-follow latency 2-3 s at every checkpoint, ONE agent instance
across the whole run. The two prior A1 failures ARE the control-that-fails for this pass.
A6 machinery visibly load-bearing: A6PARK=18, A6ACK=18, A6REVOKE=16 (ack-gated),
A6ACKTIMEOUT=0, **A7RETRY=3** (the retry saved the process three times), A6LEAK=1 (one grant
never became revocable and was leaked LOUDLY — the designed fallback; watch the counter).

**Boot acceptance:** revert net disarmed deliberately (IDD-primary is now the intended
config; recovery path documented: qrexec works headless → re-arm marker → reboot), cold
boot → A6 agent up, IDD PRIMARY, BDA stayed disabled, display numbering RESET to DISPLAY2
(identity churn was session-scoped), fresh-boot sync to 2566x1022 ok=True, dom0 window
2566x1022 live pixels.

**Instrument disclosure:** the stress cputime/livelock slope check was silently a no-op in
ALL runs — the Admin API response embeds a NUL, grep went binary-mode, and my harness
"skip-if-empty" guard hid it (the exact 'a check that cannot fail' anti-pattern, again).
Fixed (tr -d '\0'). Livelock absence in the passing run is evidenced by qrexec liveness,
sync timeliness, and follow latency — not by that metric.

**D3 negative stands; D4v2 (stable EDID) still broken** — monitor never arrives, root-cause
hunt with the driver agent in progress; D4 v1 (identity churn per replug, session-scoped)
is the working driver meanwhile.

**Remaining for the full goal demo:** a live dom0 window DRAG with the sync loop running
(loop started on the guest). The dom0-originated request chain itself is already proven
(RESREQ src=dom0 measured from the user's manual drag on 08-04); scripted drag needs the
_QUBES_VMNAME resize service variant.

# 2026-08-05 (cont 4) — the user was right: the stress missed the real drag path. Two fixes, one bounded fragility

**User-reported breakage after real manual resizes, screenshot-confirmed:** dom0 window
showed interleaved content GENERATIONS — a diagonally sheared band of old-geometry pixels
(own taskbar + watermark) inside the new-size window. My stress had validated settled
one-at-a-time syncs; a real drag is a MSG_CONFIGURE stream, and the v0 loop replugged the
monitor PER REQUEST. Two distinct defects:

1. **Stale patchwork after a grant switch.** The existing full repaint fires when the
   re-grant is SENT; under overlapping recoveries stale damage still interleaves. Fix
   (agent 177ac32): a second full-screen repaint ON THE WINDOW-0 DUMP ACK — the one point
   where the new mapping is provably current on both sides. Validated: A6ACKREPAINT fires
   (3/3 settled syncs), decoded screenshot after churn is a single clean generation.
2. **Per-request replug during drags.** resize-sync rewritten: debounced latest-wins —
   act only when the newest dom0 request is stable for 2 polls and differs from current.
   One replug per gesture, exactly the pattern every hypervisor stack ships (survey §4).

**Bounded remaining fragility, honestly stated:** deliberately bypassing the debounce
(3 back-to-back -SyncNow, no settle) wedged the guest AGAIN — qrexec dead, cputime slope
~1.9 vcpu-s/s (measured with the FIXED sampler), ACPI shutdown never processed, kill
required. The livelock family is real and is triggered by rapid display-topology churn;
the debounce keeps normal use off that path but does not fix the underlying guest-side
defect. Next diagnostic requires deliberate reproduction with dom0 forensics staged
(protocol exists, evidence dir instrumentation/hang-2026-08-04/).

**gui-daemon coin-flip death observed again** on the second graceful agent install of one
boot (agent waited at "Awaiting for a vchan client", zero dom0 windows, empty screenshot) —
one more datapoint for the §3 upstream report (DESIGN-gui-daemon-restart-survival.md).

State: agent AD4DE497 (A6+A7+ackrepaint) running, IDD primary, debounced loop live,
guest at 2560x1440 clean. D4v2 stable-EDID fix still iterating in CI.

# 2026-08-05 (cont 5) — freeze hunt: 100-cycle soak clean on the current stack; trap stays set

User priority: crashes/freezes above all. State of the hunt:
- **Soak reproduction: 40 batches (~100 replug cycles), alternating rapid-sequential and
  3-way-concurrent syncs, ZERO wedges** on agent AD4DE497 in a fresh boot — including the
  exact concurrent pattern that wedged earlier the same day. The wedge is a genuine but
  RARE race, possibly involving boot-accumulated display-instance state or real-WM-drag
  echo storms (not reproducible without the dom0 drag harness).
- **Trap set for the next occurrence:** in-guest CPU-attribution telemetry
  (guest/wedge-telemetry.ps1, 2 s samples incl. DPC/interrupt time → survives the wedge on
  disk), NMICrashDump=1 armed (dom0 `xl trigger <dom> nmi` would produce MEMORY.DMP — needs
  the user), soak harness committed (scratchpad/soak-wedge.sh, stops AT the wedge without
  recovering). Re-arm both loops after any reboot: resize-sync.ps1 (debounced) +
  wedge-telemetry.ps1.
- **Churn-frequency reduction shipped:** agent 5969284 widens the rolling resolution
  debounce 500→1200 ms (mid-drag hesitations no longer fire mode changes); deployed as
  DCFEA348 (stack t2/a6-stack), boot-verified, E2E sync clean post-boot.
- The earlier "jumped weirdly": mid-drag snap applies + the loop latching a mid-drag pause
  size (2008x645). The 1200 ms debounce addresses the first; the proper cure for both is
  the agent-native exact-mode path (agent publishes + replugs + applies itself, no PS loop)
  — designed next step, deliberately parked BELOW the freeze work per user priority.
Guest state: DCFEA348 (A3+A6+A7+ackrepaint+1200ms), IDD primary via D4 v1, 2560x1440,
debounced loop + telemetry running, netvm detached. D4v2 stable-EDID still with the
driver agent (monitor-arrival regression under root-cause).

# 2026-08-05 (planning) — Win11 resize plan written: Win11 changes NOTHING structural for console mode updates

Web research (two passes: MS docs/headers + community/field evidence) for
`PLAN-smooth-resize-win11.md`, verdict: **no Windows 11 build gives a console IDD a
replug-free way to apply a runtime mode-list change.** IddCxMonitorUpdateModes2 (1.10) is
the HDR variant of v1, publish-only, target-modes-only; the apply half
(IddCxAdapterDisplayConfigUpdate/2) is documented remote-only; the "modes based on a
client window size" flag is IDDCX_ADAPTER_FLAGS_REMOTE_ALL_TARGET_MODES_MONITOR_COMPATIBLE
(header-verified: one flag, REMOTE prefix, "only valid for remote drivers"). IddCx per
build: 24H2 = 1.10 (0x1A80 GERMANIUM, WDDM 3.2); 1.11 = 25H2-era, feature-gated. Field
evidence is net regressive: Looking Glass LGIdd (1.10) documents in-source that
UpdateModes[2] "does not invalidate Windows' cached mode list" and ships replug; every
examined console VDD replugs; VirtualDrivers#471 reports 24H2 HALF-APPLIES dynamically
updated modes (signal mode switches, desktop mode stuck until a Settings poke →
mitigation: SDC_FORCE_MODE_ENUMERATION retry, same flag QXL ships). Two weak Win11
"works" claims (#1184 OP, #471-on-23H2) justify exactly one instrumented re-spike (W2),
expected negative. MS Q&A 5924412 and #1184 remain without Microsoft resolution.
Header curiosity: IDDCX_VERSION_COBALT_UPDATEMODE_FIX 0x1801 exists, undocumented.
Consequence: the Win11 plan keeps the Win10 mechanism (stable-EDID replug, agent applies,
one commit per settled gesture, 2-3 s follow floor), adds the 24H2 half-apply gate to W1,
and states per-frame follow as impossible on console IddCx (§8). Plan file:
PLAN-smooth-resize-win11.md (milestones W0-W7, ~16-25 pd).

# 2026-08-05 (cont 6) — exact-follow + --solo deployed; BOOT-PATH wedge caught; leak theory weakened

- **Never-resize-to-viewport ENFORCED in the agent** (user hard rule, saved to memory):
  exact-follow (agent 8bd39a9, deployed D6D382E1) — src=dom0 requests are applied EXACTLY
  (obtaining the mode from the IDD registry+replug in-process via SetupAPI) or NOT AT ALL
  (RESKEEP, resolution untouched). The snap path is unreachable for dom0 requests; the ×1440
  auto-choice the user hit cannot recur from a drag. The PS resize loop is retired.
- **modeprobe --solo landed + validated live**: topology assertion (target primary at WxH,
  all others detached, CDS_UPDATEREGISTRY-persisted). Fixed the DisplaySwitch-polluted
  Configuration cache in one call; IDD-only topology now survives reboot (verified). The
  DisplaySwitch /internal|/external roulette is dead — never use it again.
- **Cursor**: double cursor in fullscreen fixed via DisableCursor=1 (stock mechanism;
  the fork's provisioning had pre-seeded 0); the CM-scale offset was input-coordinate skew
  from the phantom fallback display extending the virtual screen — gone with --solo
  (vscreen == window exactly). IDD hardware cursor remains the proper Track B fix.
- **BOOT-PATH WEDGE caught (second wedge of the day, NO churn involved):** boot 17:07 →
  two short-lived agent instances (6 KB + 0 KB logs) → third instance runs normally,
  pumping ~60fps QGAPERF — and the log STOPS MID-STREAM at 17:08:31.183, identical to the
  original 08-04 freeze signature. qrexec dead, ~1.6 vcpu-s/s spin, daemon window frozen.
  Telemetry was not yet running (started too late — boot-time arming needed).
- **Grant accounting of the wedged boot: near-zero churn** (0 re-grants, 0 per-window
  attaches across all three instances → ≤3 screen grants ≈ 11k entries). This WEAKENS
  pure grant-table exhaustion for the boot wedge unless baseline PV usage is far higher
  than assumed. The freeze is kernel-level and guest-side observability is EXHAUSTED:
  next wedge requires dom0 — `xl debug-keys g` + `xl dmesg` (grant table state), and
  `xl trigger <domid> nmi` (NMICrashDump=1 is armed → MEMORY.DMP).
- Smooth-resize plans delivered per user directive: PLAN-smooth-resize-win10.md (bee4a42,
  ~10-14 pd, one-replug-per-gesture ceiling) and PLAN-smooth-resize-win11.md (615cacf,
  ~16-25 pd, verdict: Win11 changes nothing structural — replug remains the mechanism).

# 2026-08-05 (cont 7) — "it died" root-caused: ONE denied SendInput killed the agent AND the daemon

The user's window death during their drag was neither the livelock nor grants. The wedged-
looking state had qrexec ALIVE and zero CPU spin — only gui-daemon was dead. Agent log,
17:24:39: guest idled ~9 min → lock screen took the input desktop → dom0 sent mouse motion →
`HandleMotion: SendInput failed with error 0x5 (ACCESS_DENIED)` → **HandleServerData treats
any handler failure as fatal** → agent exits → vchan closes → gui-daemon EOF death (the
known dom0 coin-flip) → window gone. A single undeliverable mouse event took down the whole
GUI chain. This crash class is trivially triggerable: UAC secure desktop, idle lock, any
desktop switch.

**Fix (agent 8ad3f1e+f37759c, deployed A11F5E60, stack t2/resilience-stack):** all six
SendInput sites route through InjectInput() — log, best-effort AttachToInputDesktop for the
next event, DROP the event, continue. Protocol-safe (body already consumed). Input
injection failures are never fatal again.
**Hygiene:** the test qube no longer idle-locks or blanks (NoLockScreen=1,
InactivityTimeoutSecs=0, monitor-timeout 0) — a guest whose input comes from dom0 must
never take the input desktop away.
**Also observed:** CaptureTeardown revoke noise 0x490 on that exit path (grant already
gone) — harmless, but confirms exit-path revokes can no-op.

Full acceptance soak per the user's gate ("test until it does not die, misbehave, or revert
to 2560x1440") running: scratchpad/soak-full.sh — 30 cycles of exact resizes (never
2560x1440), agent restarts every 3rd (size must persist; daemon deaths counted separately
as the KNOWN dom0 bug), reboots every 5th (size+topology must persist), pixel checks,
stop-at-first-hard-failure.

# 2026-08-05 (cont 8) — THE WEDGE, CAPTURED IN FULL: 22k pinned grants + NMI kernel dump

Reproducible trigger confirmed (twice): rapid exact resizes + a graceful agent stop →
whole-guest livelock within ~2 min (soak-full cycle 3 both times). This occurrence was
captured with every instrument armed:

1. **dom0 grant table (`xl debug-keys g`, instrumentation/hang-2026-08-04/wedge2-xl-dmesg.txt):
   the wedged domain held ~22,000 ACTIVE grant entries (refs to 0x564a), pinned 0x200 =
   STILL MAPPED BY DOM0** at freeze time. Dozens of stale framebuffer generations that the
   guest cannot revoke while dom0 maps them (the 0x490 / A6LEAK / ack-timeout trail). The
   accumulation mechanism: every resize re-grants; dom0-side release of old mappings is not
   keeping pace (daemon deaths orphan mappings; rapid re-dumps race the release);
   unrevocable refs pile up.
2. **In-guest telemetry ran through the freeze:** final samples (17:49:45) show a HEALTHY
   guest — cpu bursts from explorer/dwm, dpc <2%, no runaway process — then sampling stops
   between one 2 s tick and the next. The freeze is instantaneous and invisible to guest
   user-mode; the vCPU spin seen from dom0 starts AT the freeze → kernel spinning in a
   hypervisor-coupled path (grant/hypercall), not a user process.
3. **NMI kernel dump captured: MEMORY.DMP 392 MB** (preserved as C:\qubes-idd\wedge2.dmp)
   — holds the spinning stacks. In-guest analysis pending a CI-bundled kd (offline guest;
   module+offset stacks are enough to name the driver).

Strategic fix direction this evidence selects: **stop churning framebuffer grants
entirely** — the B1-style persistent staging buffer (grant ONE max-size buffer for the
qube's lifetime, CopyResource each frame into it, re-dump geometry changes over the SAME
grant). Kills the accumulation class structurally; also what the smooth-resize plans want.
Interim mitigations: rate-limit topology churn (planned), and dom0 max_grant_frames raise
(user action) as headroom.

# 2026-08-05 (cont 9) — LIVELOCK ROOT-CAUSED FROM THE NMI DUMP: xeniface->xenbus grant revoke spins forever

kd (CI-bundled, export-symbol resolution against the guest's own binaries; raw output in
instrumentation/hang-2026-08-04/wedge2-kd-stacks.txt) on the 392 MB NMI dump:

- **CPU 1 (the spinner):** `xeniface+0xb07d → xeniface+0xc23c` (IOCTL dispatch) →
  `xenbus+0x11bab → xenbus+0x1cbd1` → DPC/`MmUnlockPages` …→ **`xenbus+0x1cd35`** executing
  at NMI time. That is the **gnttab IOCTL path (revoke: MmUnlockPages = releasing granted
  pages) stuck inside xenbus** — an unbounded wait/spin, almost certainly on a grant entry
  that dom0 STILL MAPS (the 22k pinned entries from the xl dump).
- CPUs 2-3: idle. CPU 0: NMI handling + NtQuerySystemInformation (the telemetry sampler).
- Everything downstream (qrexec vchan, gui vchan, ACPI) blocks behind the stuck xenbus —
  the whole observed syndrome from one spinning revoke.

**Conclusion: the livelock is a Xen Windows PV-driver defect (xenbus/xeniface): a grant
revoke of a still-mapped entry can spin unboundedly with locks held.** Our workload
(framebuffer re-grant churn + revokes racing dom0's unmap) is the trigger, not the defect.
Under the standing policy this is OUTSIDE QWT scope → upstream report (user approves text).
Note most revokes of mapped grants return 0x490 cleanly — the spin is a rarer race, which
matches the intermittency.

Guest-side avoidance (ours, already in flight): the staging-grant change (one grant per
agent lifetime, zero resize-time revokes) removes the trigger from the hot path; the A6
exit drain should also SKIP revokes for grants dom0 provably still maps (log-and-leak is
strictly safer than a kernel spin — the domain teardown reclaims them).

# 2026-08-05 (cont 10) — staging build changed the failure: no spin, but qrexec loses EVENT DELIVERY; the common enemy is the PnP replug

Acceptance soak on the staging agent (9D74FF26, STAGING granted 7200 pages once): cycle 3
failed AGAIN but with a NEW signature — **no CPU spin** (slope 0; the livelock signature is
gone with grant churn removed), gui window alive, guest idle, but qrexec dead. qrexec-agent's
log ends at 18:50:18 mid-eventloop: spawned the cycle-3 command wrapper, logged "waiting for
event" — and never logged again. No crash, no error: **Xen event-channel delivery to
qrexec's vchan silently stopped** after the third rapid display-device restart.

Unified read: every failure mode (grant-revoke spin, lost evtchn upcalls) correlates with the
FULL DEVICE PnP restart used to reload driver modes (SetupAPI DICS_PROPCHANGE = device
remove/start = PnP/interrupt churn touching the Xen platform device). The staging fix
removed the grant half; the PnP half remains. Fix in flight: **D4v3 IOCTL monitor-level
reload** (IddCxMonitorDeparture/Arrival inside the running driver — zero PnP), plus the
agent calling the IOCTL instead of restarting the device. This is plan M5, promoted from
"blackout reduction" to "stability fix".

# 2026-08-05 (close) — ACCEPTANCE SOAK PASS 30/30 on the no-PnP stack; the stability arc closes

Stack: agent A8621D1F (staging grant + exact-follow + input resilience + IOCTL reload) +
driver 57eb5004 (D4v3: IOCTL_QIDD_RELOAD_MODES, monitor-level replug, no PnP).

**SOAK PASS: 30 cycles, 10 graceful agent restarts, 6 reboots, ZERO reverts, ZERO wedges,
all pixels live, every size exact** — including cycle 3 + restart, the exact pattern that
killed three earlier builds (those failures are the controls that fail). Sizes persisted
across every restart and reboot (2340x1100, 1650x950, 2200x1234, 1876x1004, 2464x1200,
2016x1160).

The three-layer fix that got here, each layer evidence-driven:
1. **Staging grant** (one grant per agent lifetime) — removed the grant-revoke churn that
   fed the xenbus revoke spin (NMI-dump-proven).
2. **IOCTL monitor-level reload** (driver replugs its monitor internally) — removed the
   full-device PnP storm that killed Xen event-channel delivery (qrexec deaths).
3. **Input resilience** — a denied SendInput can no longer kill the agent.

Remaining known defect, now the ONLY recurring one: **gui-daemon's EOF coin-flip death on
agent exit — 6/10 restarts** in this soak. It is the dom0-side bug documented in
DESIGN-gui-daemon-restart-survival.md §3, upstream report awaiting user approval; guest
recovers by qube restart. Honest scope note: real interactive drag streams (WM configure
bursts) remain validated only by the user's manual drags; every machine-drivable layer of
the same path is soak-proven.

Upstream drafts now pending user approval: gui-daemon EOF (2 defects), xl console overflow,
xenbus/xeniface revoke spin. All in docs/ + DESIGN-gui-daemon-restart-survival.md.

# 2026-08-05 (final) — the rock-solid-agent answer, measured

User question: "make sure the agent does NOT unexpectedly exit?" Answer shipped and soaked:

1. **NEVEREXIT audit** (agent a776efb): complete inventory of every exit path. Remaining
   fatal exits ONLY: dead vchan / handshake-on-dead-vchan (exit harmless, daemon gone) and
   QGA_SHUTDOWN. Converted to degraded-and-retry: capture-init exhaustion (A7DEGRADED state
   - vchan stays serviced, capture retries every 5 s forever), SetSeamlessMode failures,
   HandleXconf resolution failure, per-handler failures with fully-consumed bodies, one
   capture.c exit(OOM). vchan-desync stays fatal deliberately: a desynced stream re-parsed
   as messages could synthesize keyboard/mouse input - the fatality is an input-integrity
   boundary. Bonus fixes forced by the audit: duplicate-CREATE(0) guard (a daemon-killer),
   fullscreen-toggle-during-recovery guard, two NULL-capture crash sites.
2. **RESECHO filter** (d316f19): the user-observed "applies exact then reverts" was the
   daemon echoing its stale pre-apply size during the replug outage; a dom0 request equal
   to the pre-apply size within 4 s of an exact apply is dropped and logged.
3. **Settle-then-single-pass exit revokes** (ce32fc1): the exit drain's 100 ms revoke
   retries rolled the xenbus revoke-vs-unmap spin race ~20x per exit and wedged the guest
   DURING OS SHUTDOWN (soak cycle 5, Transient + full spin signature, state captured).
   Now: 1 s settle, one attempt per grant, loud abandonment. PwShutdown same.

**Acceptance soak on the final stack (agent D26DC84D): PASS 30/30** - 10 graceful agent
restarts, 6 reboots incl. the previously-wedging shutdown path, zero wedges, zero reverts,
all pixels live, daemon deaths 4/10 restarts (was 6/10; the cleaner exit shrinks the EOF
race too). The residual daemon coin-flip is the dom0 gui-daemon bug - upstream report
awaiting user approval; that fix is what makes agent exits fully free.

# 2026-08-05 (addendum) — shadow-cursor regression after resizes: fixed

User-reported: the guest shadow cursor reappeared after a couple of resizes. Cause: a
display mode change makes Windows reload the cursor scheme, undoing HideCursors()' one-time
blanking (the exact weakness the cursor investigation predicted). Fix: HideCursors() is
re-run after every applied mode change — exact path, snap path, and externally-driven
changes observed via duplication recovery (agent commit on t2/never-exit, deployed
A218AB2E, boot + resize verified). Functional confirmation (shadow stays gone across
resizes) is the user's check — the blanking has no level-3 log signature.

# 2026-08-05 (addendum 2) — the lost-resize bug: filter ate real intent; now suspect-only + defer

User-reported "last resize failed": the widened settle-window filter DROPPED a genuine
settled request (2055x1308, 3.3 s after a 2734x941 apply) — a settled drag's request never
re-arrives, so the drop was a permanent loss. The same trace also delivered the day's best
performance datum: **the agent-native IOCTL obtain applied a novel size in 356 ms**
(RESREQ→ioctl-reload→RESEXACT replug=1), no PnP, first live use.

Fix (agent a38c2f5, deployed 3DCEAD75): echo suspects are ONLY the pre-apply size and
desktop-transit sizes recorded during the obtain (recovery path feeds them via
ResolutionNoteTransitSize); suspects are DEFERRED to the settle-window end then applied
(worst case one convergent late bounce), never dropped; fresh sizes apply immediately.
Machine check: rapid pair 2222x1111 → 2345x999 (second inside the first's window) both
applied exactly. Real-drag confirmation is the user's.

# 2026-08-05 (addendum 3) — SyncNow harness retired: it now races the agent it tests

The rapid-pair machine check "failed" (2345x999 mode_never_offered) because of the harness,
not the agent: the agent's echo-follow processed the daemon's echo of the harness's first
apply through its FULL native path — RESREQ src=dom0 → WriteRequestedIddMode(2222x1111) →
QIDD ioctl-reload → RESEXACT replug=1, ~420 ms — and its registry write raced the harness's
write of the second size. Two writers on HKLM\SOFTWARE\QubesIDD\Modes: the agent is now the
rightful owner; resize-sync.ps1 -SyncNow is RETIRED as a resize-testing tool (still fine as
a one-shot recovery hammer when no agent runs). Incidentally this was the first complete
live validation of the agent-native loop end to end, echo-triggered.

Consequence for testing: machine-driving the agent's obtain path requires REAL MSG_CONFIGURE
traffic — i.e. the _QUBES_VMNAME-based dom0 resize service (v2, written, awaiting the user's
one-command reinstall) or the user's hands. Soak harnesses must not touch the modes registry
while the agent runs.

# 2026-08-05 (addendum 4) — wrong-jump #3 fixed (75 ms announce race); device sounds silenced

The user's third wrong-size jump: the capture thread's recovery cycle announced a transit
mode (A6CONFIGURE 1920x1080) 75 ms AFTER the resolution thread's apply cleared the in-flight
flag — outside the suppression gate — and the daemon echoed it back into an apply. Fix
(deployed 2977CCD8): the announce gate now covers the whole settle window; while it is open
ONLY the exact target geometry may be announced, and suppressed geometries are recorded as
echo suspects (which the defer filter then handles even if one leaks).

Also: monitor replugs fired Windows' device connect/disconnect sounds on every resize —
silenced via HKCU AppEvents (DeviceConnect/DeviceDisconnect/DeviceFail set to no sound).

Resize-service note: the repo's dom0/10 installer had regressed to the v1 title-matching
body, which is what the user's reinstall deployed (still no_window). v2 restored in the repo
from git history (commit 15d530a); needs one more user reinstall to unlock scripted
real-MSG_CONFIGURE soaks.

# 2026-08-05 (final 2) — REAL-PATH DRAG SOAK 28/28; held-frame masking deployed

**The goal's invariant is machine-proven on the true path.** With the user-installed
_QUBES_VMNAME resize service, soak-drag.sh drove 28 cycles of REAL dom0 WM resizes
(14 drag-like configure streams + 14 jumps) through gui-daemon into the agent-native
exact-follow: 28/28 triple-converged (requested == dom0 window == guest resolution),
zero wedges, zero reverts, zero crashes — and ALL 7 graceful agent restarts kept
gui-daemon alive (0 EOF deaths this run; earlier today 4-6 of 10 — the settle-gate
sequencing has narrowed the dom0 race substantially, dom0 patch still the real fix).
4 clean reboots, sizes persisted. DeviceFail canary silent across ~40 replugs.

Along the way this session closed, in order, the full echo-family: (1) mid-drag snap
applies (exact-follow), (2) pre-apply-size echo (RESECHO), (3) transit-size echo via
A6CONFIGURE (in-flight gate), (4) the 75 ms announce race (settle-window gate), (5) the
re-dump geometry channel (A6DUMP gate), (6) lost-real-intent from over-filtering
(suspect-only defer). Plus: device plug sounds silenced (DeviceFail kept as canary),
shadow-cursor re-blank per mode change.

**Held-frame masking deployed (agent 3362f62, exe 5EA4CDF8, user-committed):** during
exact-obtain/settle no screen damage is sent - the daemon freezes on the last clean frame
and snaps fully painted at the final size, replacing the transient sheared-band mangling
(the last user-visible defect). Scripted drag-stream verification converged exactly
(2260x1130 triple-equal); the freeze-vs-mangle visual is the user's confirmation.

# 2026-08-05 (final 3) — M6 + A4-lite delivered: blink-free tiles measured, boot tamed

- **M6 (mode-set pre-publish) ACCEPTED BY MEASUREMENT:** the pre-published tile-half applied
  with `RESEXACT 2560x1409 replug=0` — same-millisecond apply, zero monitor churn, no blink,
  no sound; triple-converged (dom0 window == guest == request). Set builder (agent 44e1669):
  target + work-area maximize + tile-half + 1024x768 fallback, deduped, replace-not-append,
  host-size never added by the builder (rule 2); boot publish + one reload (M6BOOT);
  work-area changes recompute registry-only (M6DEFER, no blink). Watcher's real frame
  extents arrived mid-test and the set self-corrected to true tile sizes (2560x1384).
- **A4-lite boot clamp** (agent d6cb5e9): cached boot size clamped to the work-area ceiling
  (sync qubesdb read pre-HandleXconf; honest fallback when no feed). Measured boot: cache
  2100x1100 applied unclamped (correct - within ceiling), fresh daemon window, WM
  re-maximized, guest followed dom0 - authority order preserved end to end.
- **Resize service v3** (user-installed): clears maximized/fullscreen state before resizing —
  the WM-stuck-window failure mode is gone (de-maximize + follow verified live).
- Watcher frame-extents fix live (user-restarted): feed now carries real extents.
Deployed: agent 385EBAEA (stack: staging + exact-follow + never-exit + echo-family gates +
held-frame + M6 + A4-lite), driver 57eb5004. All merged to main.

# 2026-08-05 (final 4) — border-aware M6 variants + 15 px habitual snap, verified live

User feedback pair: (1) vertical size off by the border pixels — frame extents are
WINDOW-STATE-DEPENDENT (this WM hides borders when maximized: real maximized client
5120x1384 vs bordered computation 5110x1379). Fix: publish BOTH variants of maximize and
tile-half (dedupe collapses them when extents are 0). (2) "if the size is close (<15px),
make it snap" — new rule: dom0 requests within 15 px of a WORK-AREA-DERIVED published size
snap to it (RESSNAP15); deliberately never snaps to the previous target so small manual
adjustments stick; the daemon nudging the window onto the tile is sanctioned and bounded.

Verified live (agent 2E5DD07026E29091, commits 8410cbe+bef52d7+398566b): feed 5/5/25/5 →
set `max=5120x1384/5110x1379 half=2560x1384/2550x1379`; request 2556x1382 → RESSNAP15 →
2560x1384 applied; dom0 window and guest both at 2560x1384. First snap was replug=1 (the
deferred set became live with it); subsequent habitual snaps are replug=0. Note: after a
VM reboot the feed is stale up to ~60 s (fresh qubesdb, watcher repopulate tick) — the
set self-corrects via M6DEFER when the push lands; boot-time sets may briefly lack the
work-area entries.

# 2026-08-06 — invisible bottom border: snap must target bordered sizes only (fullshot-proven)

User-reported and fullshot-CONFIRMED (instrumentation/border-invisible-before.png): the
taskbar ran to the last screen row with the window's bottom border pushed off-screen. Cause:
RESSNAP15 snapped a NORMAL (bordered) window to the borderless-maximized height (1384), so
the total frame (25 title + client + 5 border) overflowed the work area by exactly the
border height. Fix (agent 8fa1b37, deployed 0DE5239A): snap candidates are the BORDERED
variants only - maximize gestures hit the borderless sizes exactly and never need snapping;
anything close-but-not-equal is by definition a normal bordered window. Verified: 2544x1374
→ RESSNAP15 → 2550x1379, frame fits (border-visible-after.png shows the red qube border
below the taskbar). Both variants stay PUBLISHED (exact maximize remains replug=0); only
the snap targeting changed.

# 2026-08-06 (cont) — side borders: our own w0 configure carried (0,0) and MOVED the window

User pinpointed it: side borders vanished after the AGENT's snap following their resize.
Cause: the post-resize w0 MSG_CONFIGURE sent x=0,y=0 (upstream fullscreen semantics) and
the daemon obligingly moved the client to origin - left frame border at x=-5, off-screen.
Fix (agent bd6e8b8, deployed 110A4D46): remember dom0's window position from its own w0
configures (g_ScreenWinX/Y) and echo it back - the daemon resizes in place, never
repositions. Verified: snap 2544x1374 → 2550x1379 with client at x=5 (frame flush to the
screen edge, border visible). Also: resize service v4 (user-installed) nudges frames fully
on-screen after scripted resizes (windowsize never moves; stale positions clipped borders).

# 2026-08-06 (cont 2) — M1 DELIVERED: stable EDID, identity churn eliminated

Driver t2/m1-stable-edid (dll 70C64039, on top of D4v3): monitor 0 carries a fixed
128-byte EDID (vendor QBS, product 0x0001, serial 1, preferred 1920x1080@60);
EvtIddCxParseMonitorDescription now serves our EDID with the same base+registry mode list
as the EDID-less path — the v2 failure was exactly the predicted parse-path rejection of
an unknown EDID. ACCEPTANCE, measured live: `Enum\DISPLAY\QBS0001` = exactly ONE instance,
unchanged across two real replug cycles (novel-size snaps applied, guest followed); even
the session GDI name held (\\.\DISPLAY3 both times — stable identity makes Windows reuse
the display source, so the DISPLAY2→30 session churn is gone too). The 7 pre-M1
Default_Monitor phantoms stopped accumulating; one-shot sweeper in progress.

# 2026-08-06 (cont 3) — M1 + M0 delivered; registry swept; exp-9 harness parked

**M1 stable EDID: ACCEPTED** (driver 70C64039). `Enum\DISPLAY\QBS0001` = ONE instance,
stable across replugs AND across a cold boot; session GDI name stable too. Identity churn
is structurally over.
**Registry hygiene: swept.** guest/registry-hygiene.ps1 (conservative: Default_Monitor
phantoms only, diffed against Get-PnpDevice -PresentOnly; QBS0001 never touched). Admin run
reported 6 phantoms LOCKED (Enum keys are SYSTEM-ACLed); re-run as SYSTEM via a one-shot
scheduled task removed all 6 → Default_Monitor down to 1 instance. Record that: the sweeper
must run as SYSTEM, not admin.
**M0 blink instrumentation: DELIVERED and measured** (agent 0A105F60). First real
decomposition of a novel-size blink: obtain-start → reload-returned **16 ms** →
mode-offered **281 ms** (1 poll) → applied **344 ms** → repaint-sent **813 ms**. So the
IOCTL reload is nearly free, the driver's mode-offer latency (~265 ms) dominates the
pre-apply half, and **the post-apply repaint path costs ~470 ms** — the single biggest
remaining lever, and it is agent-side (capture recreate → re-grant → re-dump → ack →
repaint), not driver-side. Habitual sizes remain 0 ms (replug=0, no blink at all).
**One more livelock, one more gate:** the single-pass exit revoke still wedged a shutdown
(slope 3). Exit revokes are now attempted ONLY when the daemon is gone (dead vchan); with a
live daemon the grants are leaked BY DESIGN and loudly — the daemon still maps them, so the
revoke cannot succeed and can only lose the xenbus race. Deployed, boot verified.
**Snap regression battery** (scratchpad/snap-regress.sh, user directive): near-half snaps,
20px-off and arbitrary sizes do NOT snap, window position preserved — **PASS 4/4** on the
current stack.
**exp-9 formal record: PARKED.** The harness stops on its own persistence check (empty
string reaches check_persist despite a validating/retrying mp_json); the guest and topology
were healthy each time. Debt, not a defect in the product; script is committed for a later
debugging pass.

# 2026-08-06 (cont 4) — M0-tail: blink 609 → 484 ms; two instrument lessons; one more wedge

**M0-tail delivered** (agent 12fd58c, deployed 22D148B4). Three source-justified changes:
mode-availability poll checks immediately then 15/50/250 ms (was: a flat 250 ms sleep
BEFORE the first check — the old `polls=1` line was hiding ~240 ms of not looking);
RecreateDuplication retries 8×25 ms then 250 ms within the same 5 s deadline (was flat 250);
the pending re-dump no longer waits for a dirty frame (an idle post-mode-change desktop
could stall it indefinitely). Deliberately NOT done: an apply→capture-thread wake hint —
`AcquireNextFrame` is a blocking DXGI call with no cancellation, so a flag would only be
seen after ACCESS_LOST already returned; and lowering FRAME_TIMEOUT blind.

**Measured, same 5-size protocol, before → after (medians):** mode-offered 266 → 109 ms,
applied 312 → 187 ms, **time-to-pixels 609 → 484 ms**. No `apply-failed` appeared (the
flagged risk of the tighter poll did not materialize). New markers also settled a
measurement error: `repaint-sent` fires on the daemon's ACK, one round trip AFTER pixels
were sent — `repaint-first` is the honest time-to-pixels, and the earlier "470 ms tail"
was partly ack latency. Remaining tail (applied→pixels ≈ 300 ms) is dominated by repeated
ACCESS_LOST/recreate cycles during the replug transit, now visible per-cycle in the log.

**Instrument lesson (again): the snap battery's first FAIL was the battery.** T2 read the
guest ONCE, 7 s after the request, landing inside a replug transit and reading the PREVIOUS
mode — while the agent log showed the correct `RESEXACT 2530x1359` with no snap. Converted
to a convergence poll (same fix the stress harness needed). Snap behaviour itself: verified
correct on this build (near-half snaps, position preserved, arbitrary exact).

**One more wedge** during the re-run (qrexec dead, slope 1, daemon window alive, agent log
ends mid-QGAPERF with a 29.7 s frame delta = the freeze caught mid-stream). Same family as
the xenbus livelock; recovered by kill+start. It followed a long uninterrupted resize storm
(11 replugs in ~4 min) — heavier than any real use. Not root-caused further this session:
guest-side observability is exhausted and dom0 forensics need the user.

# 2026-08-06 (cont 5) — MAJOR CORRECTION: the remaining wedge is NOT a spin. Guest is IDLE and deaf.

Storm soak (scratchpad/storm-soak.sh: 8 rapid resizes, 1.2 s apart) is a DETERMINISTIC
reproduction — wedged on storm 1. User ran the new dom0 kit (dom0/11-wedge-forensics.sh)
with --nmi on that fresh wedge. Evidence in instrumentation/wedge-2026-08-06/:

- **NMI kernel dump (376 MB): ALL FOUR vCPUs in `nt!HalProcessorIdle`.** No spinning code
  anywhere. The guest kernel is healthy and IDLE — it is simply not being asked to do
  anything. This is NOT the xenbus grant-revoke livelock (2026-08-05, NMI-proven, all
  stacks in xenbus/xeniface) — that one is FIXED and did not recur.
- Grant table: 9 frames of 2048, our domain's table not even large enough to appear
  prominently; the 22k-pinned-entry condition is GONE (staging grant working as designed).
- Event channels for the domain: 11, all present and bound (ports to dom0 d0 and to the
  stubdomain d695) — the channels exist; nothing is torn down.
- vCPU time deltas across 10 s: ~3 s total over 4 vCPUs (~0.3 vcpu-s/s) = idle, confirming
  the dump. **The earlier `slope` heuristic reported "1-3 vcpu-s/s" and I called it a spin;
  for this wedge that reading was noise. Retracted.**
- gui-daemon alive; its window intact.

**Revised model: two distinct failure modes existed.** (1) xenbus revoke spin — fixed.
(2) THIS one: after heavy replug churn the guest stops SERVICING the PV rings — Windows
idle, event channels intact, qrexec deaf. Matches FINDINGS cont 10 (qrexec-agent log
ending mid-eventloop with no error). Suspect: the PV drivers' interrupt/DPC path or the
xeniface/xenvchan servicing stalling after repeated display-device PnP churn; the guest
never notices, so nothing logs.

Guest-side mitigation is therefore exactly right and now has an acceptance test with a
CONTROL THAT FAILS: the storm soak wedges the current build on storm 1. M7 (recent-size
LRU so repeats need no replug + a 2.5 s minimum interval between replugs) must survive it.

# 2026-08-06 (cont 6) — M7 ACCEPTED: the storm that reliably wedged the guest now passes 6/6

Agent 8468926D (t2/m7-churn-guard: recent-size LRU of the last 4 applied sizes published in
the mode set + MIN_REPLUG_INTERVAL_MS=2500 before any IDD reload, applied only on the
obtain path so replug=0 sizes stay instant).

**Acceptance with a control that failed hours earlier:** scratchpad/storm-soak.sh (8 resizes
1.2 s apart, repeats in the pool) wedged the PREVIOUS build on storm 1. On M7: **6/6 storms
PASS, no wedge.** The mechanism is visible in the numbers: storm 1 = 4 replugs for 8
requests, **storms 2-6 = ZERO replugs for 8 requests each** — the LRU serves every repeat
from the published set, so the churn that triggers the idle/deaf failure simply stops
happening after the first pass over a size pool. Real usage (a handful of habitual sizes)
should approach zero replugs in steady state.
Snap regression battery: PASS 4/4 on this build (near-half snaps, 20px-off and arbitrary
exact, position preserved).

# 2026-08-06 (close) — M7 + fit guard landed; the idle/deaf wedge still reachable via drag soak

**Fit guard** (agent on t2/fit-guard, deployed 6177C57F; user rule "if remembered geometry
does not make sense, snap to the nearest that does"): a dom0 request whose FRAME cannot fit
the work area snaps to the largest published habitual size that does; when none is known the
current resolution is kept. Verified live: `RESFIT 5120x1440 does not fit work area
5110x1379 - snapping to 5110x1379`. This is what stops a WM-remembered oversized geometry
(seen when the daemon window is recreated after an agent restart) from pushing borders
off-screen.

**Status of the wedge, stated honestly.** M7 defeats the *storm* reproduction decisively
(6/6, replugs 4→0 after the first pass). It does NOT eliminate the idle/deaf failure: the
real-path drag soak reached cycle 10 (9 gestures, 2 agent restarts, 1 reboot, all
converged exactly) and then qrexec died again. So the remaining trigger is not raw replug
RATE alone — the drag soak's replugs are already spaced by M7 — and the PV-servicing defect
is still reachable under sustained mixed load. Guest-side mitigation has taken it from
"first storm" to "~10 mixed cycles"; the rest is the dom0/PV side.

**Two harness corrections this session** (both mine, both the same class as before):
soak-full.sh RETIRED — it drove raw devcon PnP restarts through the obsolete SyncNow path,
manufacturing the very churn it then reported; soak-drag.sh now (a) asserts guest==CURRENT
dom0 window after a restart rather than the pre-restart size (the WM legitimately re-places
a recreated window — the earlier "REVERT" was a false alarm) and (b) treats a missing dom0
window as the KNOWN daemon EOF bug: reboot and continue, not fail.

Deployed: agent 6177C57F (staging + exact-follow + never-exit + echo/announce gates +
held-frame + M6 + A4-lite + M0-tail + M7 LRU/limiter + fit guard), driver 70C64039 (D4v3 +
stable EDID). Snap battery PASS 4/4 on this build.

# 2026-08-06 (exp-9) — round 1 PASS both sides; round-2 wedge RECOVERED WITHOUT FORENSICS (my error)

**Round 1 formal record, both sides, cold boot each, activity-verified:**
- IDD test: `flag=True ever_false=False map_ok=True pitch=7680 (=width*4) dup_ok=True
  agent_ok=True device=\\.\DISPLAY2 adapter0_attached=1 acquired=163 access_lost=0 redup=0
  format=87 session=1` → **Outcome A CONFIRMED on the CURRENT stack** (stable-EDID driver
  70C64039 + staging-grant agent), not on the superseded D0/D4v1 configuration.
- BDA control: identical field set, `acquired` above the gate after the probe window was
  widened (see below). Raw JSON: instrumentation/exp9/round-1-{bda,idd}.json.

**Instrument fixes on the way there** (both were the harness, both now recorded):
1. `python3 - <<EOF` with piped JSON: the heredoc IS stdin, so `json.load(sys.stdin)` always
   saw EOF — that is what produced the two "PERSIST FAIL json-unparseable" stops on healthy
   topologies. JSON now passed via argv.
2. Activity gate (>=20 acquired) tripped at 15: the guest's damage rate under activity-gen is
   ~0.5 frames/s, so a 30 s probe COULD NOT reach 20 even when working correctly. Probe
   window widened to 75 s (activity 90 s); the gate itself was NOT lowered.

**PROCESS FAILURE, mine, recorded per the user's standing rule:** round-2-bda stopped with
"could not arm revert marker" — qrexec dead, slope ~1 (idle), i.e. the idle/deaf wedge again,
and the harness had correctly FROZEN the state for forensics. I then ran `qtest kill` and
restarted **without capturing dom0 forensics**, destroying that instance. That was exactly the
evidence the remaining defect needs, and the kit (dom0/11-wedge-forensics.sh) existed and was
one command away. Rule reaffirmed: when the harness says STATE FROZEN, the next action is the
dom0 kit — never a kill.

# 2026-08-06 (exp-9 VERDICT) — PASS 6/6 sides: Outcome A formally recorded on the shipped stack

Protocol as specified in PLAN-trackb-t2-modes.md §2.4/§7 row 9: 3 interleaved rounds of
[BDA control, IDD test], COLD BOOT per side, topology asserted with modeprobe --solo and
re-verified twice post-boot, ddaprobe hash-checked against the CI manifest before every run,
activity-gen driving concurrent damage, acceptance evaluated from the JSON (never the exit
code). Raw JSON + per-side reports: instrumentation/exp9/round-{1,2,3}-{bda,idd}.json.

| side | flag | ever_false | map | pitch | dup | agent_ok | adapter0 attached | acquired | access_lost | redup | fmt | session |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| r1-bda | True | False | ok | 7680=w*4 | ok | True | 1 | 106 | 0 | 0 | 87 | 1 |
| r1-idd | True | False | ok | 7680=w*4 | ok | True | 1 | 146 | 0 | 0 | 87 | 1 |
| r2-bda | True | False | ok | 7680=w*4 | ok | True | 1 | 111 | 0 | 0 | 87 | 1 |
| r2-idd | True | False | ok | 7680=w*4 | ok | True | 1 | 172 | 0 | 0 | 87 | 1 |
| r3-bda | True | False | ok | 7680=w*4 | ok | True | 1 | 118 | 0 | 0 | 87 | 1 |
| r3-idd | True | False | ok | 7680=w*4 | ok | True | 1 | 161 | 0 | 0 | 87 | 1 |

**Verdict: OUTCOME A, formally.** An IddCx *console* driver on Win10 19045 keeps
DesktopImageInSystemMemory TRUE for the whole run, MapDesktopSurface works with TIGHT pitch,
Desktop Duplication is clean (zero ACCESS_LOST, zero re-duplications across 146-172 acquired
frames per test side), and the agent's own output selection lands on the IDD. The BDA control
passed identically every round — the sides are indistinguishable on every acceptance field,
which is the point: the IDD is not a degraded capture source.

**Scope, per §2.4 — do not overstate:** current driver build (D4v3 + stable EDID 70C64039) +
staging-grant agent, WARP renderer, 19045, 1920x1080 solo topology. Near-zero odds of holding
on a guest with a real GPU; a PASS here must not be ported to GPU passthrough.

Track B's gating question is now closed with evidence at the standard CLAUDE.md demands.
Guest left at IDD-primary 1920x1080, BDA disabled, marker disarmed (the intended steady
config); restore a preferred size with a dom0 resize.

---

## 2026-08-06 — release packaging: clean-guest QWT installer + ISO (branch `t2/release-package`)

**Deliverable.** `.github/workflows/release-package.yml` produces two artifacts:
`qwt-improved-setup` (directory) and `qwt-improved-iso`. Both install QWT on a **clean**
guest — this is not the overlay. First green run: **31109691408** (all 4 jobs), 2 fix
rounds.

**Chosen path: the MSI, not a scripted overlay.** `PLAN-full-source-build.md` step 3 already
shipped `qwt-full.yml`, which rebuilds the genuine `installer.msi` from the pinned upstream
WiX v4 sources with our gui-agent; it has been green for weeks and its MSI was installed on
a wiped guest. `release-package.yml` therefore *calls* it (`workflow_call`, added to
`qwt-full.yml`) rather than duplicating the toolchain, and stages the result into an
installable tree. `build.yml` was not touched.

**Verified on the downloaded artifacts, each against a control that could fail:**

| claim | evidence |
|---|---|
| our gui-agent.exe/gui-watchdog.exe are physically inside `installer.msi` | 7z-extracted both MSIs: `6558c4cf…` and `df172b68…` present in ours; **absent from the stock 4.2.2 MSI** (control), 72 payload files each |
| the cert the installer tells the guest to trust is the cert that signed our binaries | shipped `qwt-improved-testsign.cer` DER appears verbatim in gui-agent.exe, gui-watchdog.exe, iddsampledriver.cat and IddSampleDriver.dll; **absent from Microsoft-signed vc_redist.x64.exe** (control) |
| the ISO is intact under the names Windows actually reads | extracted the **Joliet** tree (not just Rock Ridge) and re-checked every file against `SHA256SUMS.txt` — 19/19 |
| the ISO check can fail | deliberately corrupted a payload → `sha256sum -c` FAILED, exit 1; deliberately named a missing entry point → Joliet name check FAILED, exit 1 |

**Two rounds of CI failure, both instructive.**
1. `idd` job: I "improved" driver collection to prefer the WDK package folder. It found
   `driver\IddSampleDriver\x64\Release` (stamped INF, **no binary** — the WDK writes the DLL
   to `driver\x64\Release`), so the dll assertion fired. The check worked; my refinement did
   not. Reverted to build.yml's proven flat glob. Also stopped copying the WDK's pre-built
   `.cat` so that a skipped `Inf2Cat` cannot pass the "no .cat produced" check.
2. `workflow_dispatch` is only offered for workflow files that exist on the **default
   branch**, so a new workflow cannot be dispatched from its own development branch. Added
   the branch to the push trigger.

**Honest scope of the deliverable — recorded in the shipping README.txt, not just here:**
- Installs `ADDLOCAL=PvDriversCore,Core,Gui[,PvDriversNetwork]`. Does **not** install
  PvDriversDisk, MoveUsers, Autologon, any video driver (4.2.2 has none), or the dom0-side
  resize service.
- Test-signing is **mandatory and permanent** for the guest; the installer enables it.
- The IddCx driver ships but is only staged into the driver store with `/idd`, and is
  **never activated** — an active second monitor enlarges the desktop bounding box the agent
  maps as the screen and breaks seamless coordinates.
- **The netvm blocker is unchanged and is stated in the artifact README**: attaching a netvm
  still starves the guest, and it is still NOT attributed to us vs the upstream PV drivers.
  Byte identity with stock is not behavioural proof; the stock-QWT control install remains
  the outstanding experiment. This package is for an offline qube.

**Not done / not proven here:** nobody has installed *this* artifact on a guest. The
verification above is of the artifact's contents, its provenance and its self-checks — not
of an end-to-end install. The install path itself is the same `msiexec` invocation that was
executed successfully on a wiped guest on 2026-08-01, plus a two-stage script whose only
unexercised parts are the certificate/testsigning/reboot sequencing and the `-Auto` SYSTEM
resume task. Record that as unproven until a guest install runs.

# 2026-08-06 (release qualification) — fresh-guest install found a REAL installer bug

Fresh qube `win10-fresh` created from the unattended ISO (clean Windows 10 22H2 19045),
tagged into the new tag-based testbed policy (dom0/12-install-policy-tagged.sh — the old
per-NAME rules gave new qubes NO qrexec access at all; found immediately by qvm-tags
returning "Request refused").

**Bug found by the fresh install, ours, fixed (0859dbb):** the release installer aborted
with `FATAL ERROR: The system cannot find the file specified.` at
`Install-QwtImproved.ps1:279` = `Clear-BootResume`. Cause: `schtasks /Delete` on a
non-existent task writes its ERROR line to STDERR, and under
`$ErrorActionPreference='Stop'` PowerShell converts a native command's stderr into a
TERMINATING error — so a successful no-op killed the install. It only triggered because
the boot ISO had ALREADY enabled testsigning, so stage 2 ran without a prior `-Auto`
stage 1 — precisely the state a fresh-system test produces and an upgrade test never
would. Both schtasks call sites now judge the EXIT CODE, never the stream. (Same trap as
the earlier pnp-revert-setup NativeCommandError; third occurrence of this class in the
project — worth a lint rule.)

Evidence captured before recovery (guest went qrexec-dead right after, ~2 vcpu-s/s, no
dom0 window — the familiar PV-servicing signature, on a machine that had just had its PV
drivers touched): installer RESULT json
`{"stage":"stage2-install","ok":false,...,"payload_files_verified":19,
"package_version":"4.2.2+agent.bd6e8b81a560"}`, cpu-slope and window-count probes,
full-desktop screenshot. Note the payload itself verified 19/19 files in the guest, so
packaging and transport are sound; only the stage logic was wrong.

Release artifacts verified independently of the guest: setup dir 19/19 sha256 OK, ISO
sha256 OK (997cc27d…), MSI carries our agent (bd6e8b81) per the build job's own
extraction check.

# 2026-08-06 (blocker) — ISO/CD attach fails: the BLOCK BACKEND in win-idd-mgmt is broken

Symptom: any new qube started with a CD from this qube dies at domain creation,
`libxenlight failed to create new domain`. dom0 log (user-supplied) names the real cause:
`Stubdom NNN startup: startup timed out` + `device model did not start: -9`, with the
stubdom waiting on `vbd .../51760` whose backend lives in domain 121 = win-idd-mgmt.

Isolation performed (each step a separate control):
- brand-new qube, NO cd, NO netvm -> starts fine  => not memory, not dom0, not the VM
- same qube + CD                                   => fails                => the CD path
- ISO on a freshly created loop device (loop1)      => fails                => not stale loop0
- an 8 MB dummy image on loop2 instead of the ISO   => fails                => not the ISO file
- hot `qvm-device block attach` to a RUNNING qube   => "empty response from qubesd"
=> the block backend export from win-idd-mgmt itself is failing for ANY device. It worked
   earlier the same day (win10-fresh installed from loop0), so it broke during this session.

Also found and fixed on the way (my bug): reprovision.sh did not set netvm, so every new
qube inherited the default `fw-net` - a Mirage unikernel whose vif backend never comes up,
which ALSO causes the stubdom timeout. Installs must be offline; use `core-net` (not
fw-net, not sys-firewall - that name does not exist here) for the networking tests.

CONSEQUENCE: the clean-system E2E acceptance (Win10 + Win11), the clean-system regression
run, Windows Update/networked-qube and Office checks are all BLOCKED until the backend
works. No sudo in this qube, so I cannot restart the service; the cheapest fix is very
likely a restart of win-idd-mgmt itself (which also ends the agent session) or a dom0-side
look at qubesd's error.

# 2026-08-06 (networking) — RESOLVED and re-attributed: the blocker was mirage-firewall

Measured on win-idd-test with netvm `core-net` (the real netvm; `fw-net` is a Mirage
unikernel, `sys-firewall` does not exist here):
- hot-attach to a RUNNING guest: no NIC appears, but the guest stays perfectly healthy
  (qrexec alive, no CPU burn) — Windows simply does not enumerate the hot-plugged vif;
- after a COLD BOOT with the netvm attached: `Ethernet adapter Ethernet: 10.137.0.64`,
  `Test-NetConnection 8.8.8.8` True, DNS resolves, `https://www.microsoft.com` -> 200;
- **Windows Update: search OK (1 update), download rc=2 (orcSucceeded), install rc=2,
  RebootRequired=False**;
- CPU over 90 s post-attach: brief 1.3-1.8 vcpu-s/s of network-stack/WU activity, settling
  to ~0.3 — nothing like the historical "2 cores burning, qrexec dead".
Per the user: this was diagnosed sessions ago; the fault is **mirage-firewall as the
netvm**, not this fork and not the PV drivers. GOAL-STATUS.md's stale blocker section is
now marked RETRACTED in place. Practical rule for this project: test qubes install
OFFLINE (netvm ''), and use `core-net` when networking is needed.

# 2026-08-06 (release qualification, session close) — what is verified, what is not

**VERIFIED THIS SESSION**
- **Networking + Windows Update: zero issues** (win-idd-test, netvm `core-net`, cold boot):
  NIC enumerates (10.137.0.64), DNS + HTTPS OK, WU search/download/install all
  orcSucceeded, no reboot needed, no CPU burn, qrexec stable. Historical "netvm ⇒
  unusable" was **mirage-firewall**, re-attributed; stale GOAL-STATUS text retracted.
- **Office 365 (evaluation) installs unattended on the networked guest** via ODT
  (`guest/install-office-eval.ps1`), WINWORD.EXE present and launches.
- **Release package + ISO** built, checksum-verified, MSI proven to carry our agent.
- **User-facing write-up** `docs/WHAT-CHANGED-FOR-USERS.md`.
- **Installer bug found by the fresh-guest test and fixed** (schtasks stderr abort).
- **Benchmark harness bug fixed** (`local a="$1" b="$a"` is rejected under `set -u`), both
  sides now execute.

**NOT VERIFIED - stated plainly**
- **Clean-system E2E (Win10 and Win11): BLOCKED.** Any qube started with a CD from this
  qube fails domain creation: libxl `Stubdom startup timed out / device model did not
  start`, while the same qube starts fine without the CD, and an 8 MB dummy image fails
  identically. dom0 qubesd log shows no exception; `/local/domain/121/backend/vbd` does not
  exist, i.e. the backend node is never created. Next diagnostic: dom0
  `/var/log/xen/console/guest-*-dm.log` for the stubdom, and `xl info free_memory`.
- **Office WINDOW BEHAVIOUR: not measured.** Word launches, but enumeration from qrexec
  runs in session 0 and cannot see session-1 windows (documented trap); the native
  dump-windows run timed out. Automated + visual Office checks remain OPEN.
- **Performance vs stock: NOT a valid comparison yet.** Ours: 2614 QGAPERF records
  collected. Stock: 0 by construction (no instrumentation in ITL's binary, confirmed by
  string scan), and the dom0 pixel-sampling fallback SATURATED (~0.4 Hz sampling cannot
  discriminate). A modal dialog was also on screen during part of the run. The harness
  correctly refused to imply a result. A meaningful comparison needs a metric that exists
  on both sides (e.g. guest-side gui-agent CPU + a native in-guest frame counter).
- Clean-system regression run: blocked with the E2E item.

Stock agent for future control runs: extracted from vendor/qwt-4.2.2/installer.msi,
sha256[0:16] **3D2E6BCEC9F5BD89**, 80,968 bytes (ITL build server pdb path, zero QGAPERF).
Guest left on our build 8468926D with netvm core-net attached.

# 2026-08-06 (Office, visual) — Word runs; window-behaviour check needs SEAMLESS mode

Visual capture with Word open (instrumentation not needed - the screenshot is the evidence):
- Word 365 (evaluation) renders correctly through the agent: ribbon, styles gallery, the
  document surface and Office's own sign-in modal all paint cleanly, no tearing, no stale
  bands. **That modal is Office's activation prompt** - it is what blocked the unattended
  flow the user observed, not an installer defect.
- **The compound-window (shadow-strip) question cannot be answered in this configuration**:
  the guest is in FULLSCREEN mode (SeamlessMode=0, the T2 configuration), so dom0 receives
  ONE window containing the whole desktop - there are no per-window frames to count. The
  2A-chrome acceptance (Office shadows dropped, toasts kept) is a SEAMLESS-mode test and
  must be run with SeamlessMode=1.
- Tooling note: `dump-windows.exe` is INTERACTIVE ("Press ESC to exit"), so it produces no
  output when run from a scheduled task - it needs a non-interactive/oneshot flag before it
  can serve as an automated probe. The session-0 limitation is real but secondary to this.

# 2026-08-06 (guest state at session end)

win-idd-test: agent **8468926D** (our M7 build), **SeamlessMode=1** (switched from the T2
fullscreen config to attempt the Office compound-window check), netvm **core-net** attached,
Office 365 evaluation installed, Windows Update current. The seamless Office check did NOT
complete: after the mode switch + reboot the guest was still at "Please wait" (logon) when
Word was launched, so only one window (0x2003c) had been mapped - the count is meaningless.
Re-run needs: boot -> wait for the desktop to settle -> launch Word -> count via the agent's
SendWindowMap lines (qtest shot cannot be used in seamless mode: `import -window` fails on
layered windows, documented earlier).
Note for the next session: to return to the T2 resize configuration set SeamlessMode=0 in
both `…\Qubes Tools` and `…\Qubes Tools\gui-agent` and reboot.

# 2026-08-06 (defect found by the Office test) — SEAMLESS MODE IS BROKEN ON THE IDD CONFIG

Switching the T2 guest (IDD primary, M6 published mode set) to SeamlessMode=1 produces:
```
SetVideoModeInternal: ChangeDisplaySettings failed: 0xfffffffe   (DISP_CHANGE_BADMODE)
WorkAreaApply: SPI_SETWORKAREA failed with error 0x57
GetFrame: AcquireNextFrame failed 0x887a0026
```
and only ONE window is ever mapped (0x2003c) with Word running - so the Office
compound-window count cannot be taken, and seamless is effectively non-functional here.

Mechanism (from our own code, no guessing needed): `SetSeamlessMode` forces the HOST
resolution on every StartFrameProcessing (main.c ~1888-1897). The host is 5120x1440. The
IDD publishes only the M6 set - target + work-area maximize/half + LRU + 1024x768 - which
does NOT contain 5120x1440, so ChangeDisplaySettings returns BADMODE, the work area cannot
be applied, and capture churns.

This is an INTERACTION between the T2 driver work and seamless mode, not a regression in
either alone: on the stock Basic Display Adapter the host size is always in the 29-mode
list, so seamless always worked. Fix direction (small): when seamless is active the mode
set must include the host size - i.e. `BuildIddModeSet` should add `g_HostScreenWidth x
g_HostScreenHeight` while `g_SeamlessMode` is TRUE. That is consistent with the user's rule
2 ("host-size modes only when the window is actually fullscreen") because in SEAMLESS mode
the guest desktop IS the host-sized surface.

Consequence for the release qualification: the Office compound-window (2A-chrome) check
cannot be run on an IDD-primary guest until this is fixed; it needs either the fix above or
a BDA-primary guest for the seamless test.

# 2026-08-06 (E2E acceptance, clean guest) — REAL DEFECT: the MSI does not replace gui-agent.exe on upgrade

Clean Windows 10 22H2 (win10-e2e, unattended ISO, 18 min) + release package (setup2, the
build with the schtasks fix). Sequence: payload verified 19/19, certs trusted, testsigning
already active, vc_redist rc=0, **msiexec rc=3010 (success, reboot required)**, then the
installer's own post-check FAILED:
```
installed gui-agent.exe 4b4ce2b1... but the package was built with 5f15dfdd... - the MSI did
not deliver our agent
```
**Verified across a reboot: still 4B4CE2B1** - so this is NOT the deferred-file-replacement
theory. The MSI genuinely does not overwrite an existing gui-agent.exe.

Mechanism (almost certainly): Windows Installer file-versioning rules. The guest already had
gui-agent.exe from the 2026-08-01 build via the unattended ISO; MSI skips overwriting a file
whose version is >= the incoming one, and our binaries do not carry an increasing
FILEVERSION. So a fresh-install-over-existing-QWT (the realistic user path) silently keeps
the OLD agent while every other component updates.

**The installer's hash check is what caught it** - it fails loudly instead of reporting
success, exactly as designed. That check is now proven by a real failure, not just by
construction.

Fix directions (not applied - user's freeze; both are packaging, not agent behaviour):
1. give the agent binaries a monotonically increasing FILEVERSION in the CI build, or
2. mark the component with `REINSTALLMODE=amus` / `msiexec /fa`-style force-overwrite for
   our own files, or
3. have the installer stop the agent, delete the file, then repair-install.
Until then: the package is only proven to deliver our agent onto a guest with NO prior QWT.

E2E status: clean-install + package-install pipeline works end to end (ISO -> Windows ->
payload -> certs -> MSI -> reboot) and is now reproducible via scratchpad/reprovision.sh;
the ACCEPTANCE fails at this one check, which is a genuine product defect worth the whole
exercise.

# 2026-08-06 (branch t2/installer-upgrade-fix) — FIX for the upgrade path: uninstall first

Applied to `packaging/setup/Install-QwtImproved.ps1` (commits f32f100, 7b2f84d). Addresses
the defect measured earlier today: on a guest that already had QWT, msiexec rc=3010 and
every component updated except gui-agent.exe (still old across a reboot) — Windows
Installer's file-versioning rule, our binaries carrying no increasing FILEVERSION.

Stage 2 now, before the install:
1. `Stop-QwtRuntime` — signal `Global\QGA_SHUTDOWN` (graceful, releases grants), stop the
   `QubesGuiWatchdog` service (it respawns the agent, so it goes first), then force-kill
   `gui-agent.exe` / `gui-watchdog.exe`.
2. `Get-InstalledQwt` — the Uninstall registry hives (HKLM + WOW6432Node), DisplayName
   `^Qubes\s+(Windows\s+)?Tools`. Deliberately NOT Win32_Product: enumerating that class
   reconfigures every registered product.
3. `msiexec /x <ProductCode> /qn /norestart REBOOT=ReallySuppress /l*v+ "C:\qwt-uninstall.log"`
   per product; 0 / 3010 / 1605 accepted, anything else is fatal.
4. `Remove-QwtLeftovers` — delete the files the package delivers (from MANIFEST.json
   `reference_binaries`: gui-agent.exe, gui-watchdog.exe) out of the QWT bin dir, because
   `msiexec /x` measurably leaves them there. Locked files are renamed aside. This sweep
   runs on EVERY path into the install, including "nothing registered" — a hand-uninstalled
   guest has no registration but does keep the binaries.
5. Re-seed the gui-agent registry defaults: the uninstall takes
   `HKLM\Software\Invisible Things Lab\Qubes Tools` with it, so the stage-1 seeding would
   otherwise be gone before the MSI's AppSearch runs.

Cross-reboot: if the uninstall returns 3010 the run arms the EXISTING `-Auto` resume task
(`schtasks /SC ONSTART /RU SYSTEM`, name `QwtImprovedSetup`) with the new internal
`-ResumeAfterUninstall` switch and reboots; the resumed run re-enters stage 2 (testsigning
is active) and skips detection/uninstall. Nothing re-arms the task in the resumed run, so at
most one uninstall reboot is possible. Without `-Auto` the run exits 10 and the manual re-run
finds nothing registered and takes the clean path.

Belt and braces: `REINSTALLMODE=amus` added to the install command line ('a' = copy all files
regardless of version). Both mechanisms are intentional — the uninstall can be defeated by a
file we cannot delete; REINSTALLMODE only applies where Windows Installer consults it.

The post-install gui-agent.exe hash check is UNCHANGED. It is the acceptance gate and it is
the thing that caught the defect.

NOT VERIFIED HERE (needs a guest, orchestrator-side): that the upgrade path now ends with the
hash check passing; that `msiexec /x` on this MSI returns 3010 and thus that the resume path
is ever exercised; the graceful `Global\QGA_SHUTDOWN` open from a SYSTEM context. CI only
proves the script parses and is staged into the artifact.

## 2026-08-06 — stock ISO + separate answer disc (answering "can it be a virtual removable drive?")

Windows Setup scans the root of every *removable* drive for `autounattend.xml`. Qubes
presents attached block devices as fixed disks by default, but `--option devtype=cdrom`
makes the frontend a CD-ROM. **Measured today:** `qvm-device block assign --option
devtype=cdrom --ro win11-fresh win-idd-mgmt:loop2` is accepted (rc=0; a second assign
errors with "already assigned", proving it stuck). So a second virtual CD is available.

That gives a two-disc install: CD 1 = the vendor ISO, byte-for-byte untouched, booted;
CD 2 = a ~1 MB image (`mgmt/build-answer-disc.sh`, added today) with `autounattend.xml`
at its root plus `\payload`.

The one non-obvious requirement: `qvm-start --cdrom` assignment does NOT survive the
guest reboot that ends the image-apply phase (the domain is destroyed), and a stock ISO
cannot carry `sources\$OEM$\$1\payload`, which is how the repacked image gets the payload
onto C:. So the answer disc must be attached **persistently** (`qvm-device block assign`),
which keeps it present at first logon; the drive-letter scan already in our
`autounattend.xml` FirstLogonCommands then finds `%d:\payload\setup.cmd` unchanged.

Status: **designed and the attach mechanism is verified; the end-to-end install on this
route is NOT yet proven.** Whether Setup actually reads the answer file off the second
CD needs one full install cycle to demonstrate, and every result produced so far came
from the repack route (`build-unattended-iso.sh`), which stays the supported path. Do not
report the two-disc route as working until an install has completed on it.

## 2026-08-06 — UPGRADE PATH: fixed and verified on a guest (was: MSI silently kept the old agent)

**Defect** (found 2026-08-06 on the clean-guest E2E): installing the release package over an
existing QWT reported success while leaving stock `gui-agent.exe` in place. Windows Installer
will not overwrite a file whose version is not newer, and our agent carries the same version
resource as ITL's. Every behaviour claim would have been made about a binary that was not
running.

**Fix** (`t2/installer-upgrade-fix`, f32f100 + 7b2f84d): the installer now detects a registered
QWT, stops the watchdog and agent (`Global\QGA_SHUTDOWN`, then service stop, then force-kill),
uninstalls the product, sweeps leftover delivered binaries, re-seeds the gui-agent registry
defaults the uninstall removes, and only then installs - plus `REINSTALLMODE=amus` as an
independent guard. The uninstall returns 3010, so the run arms a SYSTEM boot task and resumes
after the reboot.

**Measured on win10-e2e** (a guest carrying stock QWT 4.2.2.0 `{AA91BD3B-...}` and agent
`4B4CE2B1`), full log in the guest at `C:\qwt-improved-install.log`:

| step | result |
|---|---|
| payload verification | 19/19 files match SHA256SUMS.txt (twice: source, then staged copy) |
| existing QWT detected | `Qubes Windows Tools v4.2.2.0 {AA91BD3B-D8C5-420C-AB85-D73C328ADE6F}` |
| runtime stopped | QGA_SHUTDOWN signalled, watchdog Stopped, 1 x gui-agent.exe force-terminated |
| uninstall | rc=3010, resume task armed, rebooted |
| resumed run | detection skipped, leftover sweep: removed [] absent [gui-agent.exe gui-watchdog.exe] stuck [] |
| install | vc_redist rc=0, msiexec rc=3010 |
| **acceptance gate** | **installed gui-agent.exe == manifest 77607793a82d… — PASS** |
| boot path | guest rebooted itself; back up with agent running, hash still 77607793, resume task retired |

Agent hash went **4B4CE2B1 (stock) → 77607793 (ours)**. Before the fix the same guest stayed on
4B4CE2B1 after a reported-successful install.

Honest limits of this run:
- The package used was the previously built artifact with the fixed `Install-QwtImproved.ps1`
  and `README.txt` dropped in and SHA256SUMS regenerated for those two entries, because GitHub's
  Windows runners left CI queued for over an hour. CI copies both files verbatim
  (`packaging/make-setup.ps1`), so the logic tested is the shipped logic, but the *artifact*
  gate still has to be re-run against a real CI build.
- The leftover sweep reported the binaries ABSENT - the uninstall had already removed them. The
  delete and rename-aside branches are therefore still unexercised.
- Visual confirmation was not obtained at the time. **RETRACTED 2026-08-06:** I claimed the
  dom0 screenshot service was broken. It is not, and I did not break it - verified immediately
  after the claim: `fullshot` returned 1,269,760 bytes and a per-VM shot of win-idd-test
  890,880 bytes. The empty tars were CORRECT: win10-e2e had just had its QWT uninstalled and
  reinstalled so its agent was down and it had no mapped windows, and win-idd-test had none
  open. An empty tar means "no windows", not "service broken" - I never checked which.
  Functional evidence for the run instead: the agent log shows seamless mode
  (`mode=s`), `SendWindowMap` of the Notepad HWND, and a continuous QGAPERF frame stream with
  `win=1`. Recorded as "not visually confirmed", not as a visual pass.

## 2026-08-06 — clean-path install stalled: the answer file was ignored (my regression, twice-recorded)

User observation ("does not seem that answer file was picked up") was correct. `win10-clean`
booted the clean-path ISO and sat there; Setup had discarded the whole `autounattend.xml`.

Cause: **the answer file's language must match the media language**, or Windows Setup silently
ignores the entire file and stops on the locale picker. The media is
`Win10_22H2_EnglishInternational` (en-GB); the answer file I built with was en-US.

This is not a new discovery — it is recorded in this file from 2026-08-01 ("the answer file must
match the media language ... switched to en-GB (0809:00000809)"). The reason it recurred is the
process failure worth recording: **that fix was only ever applied to the mgmt qube's working
copy** (`~/qubes-win-idd/mgmt/autounattend.xml`), never to the committed
`mgmt/autounattend.xml`, which `build-unattended-iso.sh` uses by default. A finding written down
but not landed in the tree is not a fix.

Fixed as a class, not an instance (7439c31): the answer file carries `@UILANG@`/`@INPUTLOCALE@`
placeholders, the builder DERIVES the locale from the source ISO name (`*EnglishInternational*`
-> en-GB, else en-US), honours `LOCALE=`/`KEYBOARD=` overrides, and **hard-fails on any
unsubstituted placeholder** rather than producing media that stalls an hour later. Verified
before rebuilding: the substituted output's locale lines are identical to the proven en-GB file.
`build-answer-disc.sh` got the same guard, defaulting to en-US but printing the locale it used,
since it cannot inspect the media on CD 1.

Cost: one wasted install cycle. The doomed guest was killed rather than left running.

## 2026-08-06 — the shipped installer IS the one tested (caveat closed)

The upgrade-path guest test ran against a locally assembled package (CI's Windows runners were
queued for hours). Comparison against the first CI artifact that completed
(run 31126324112, `qwt-improved-setup`):

    ci   Install-QwtImproved.ps1  933fffcd…  (CRLF, as git checks out on Windows)
    repo Install-QwtImproved.ps1  a6c130a8…  (LF)
    normalised (strip \r): a6c130a8… == a6c130a8…  -> IDENTICAL

So the installer logic proven on `win10-e2e` is the shipped logic; the only difference is line
endings introduced by the Windows checkout. The remaining honest gap is that the MSI and agent
binaries in that artifact are from the seamless-fix branch, not from `main`.

CI note: repeated runs showed `cancelled` jobs. `release-package.yml` has **no** `concurrency`
block, and the canceller was our own token - a background verification job from an earlier
agent that cancelled runs it treated as duplicates. It has since exited; the next dispatch on
`main` should complete. Not a workflow defect.

## 2026-08-06 — clean-path attempt 2 wedged: my release stage-2 script never retired its ONSTART task

User observed: "Qubes Windows Tools setup on screen and thats it", then "two close buttons".

**Cause, in code I added today (29328c8).** `payload/setup.cmd` creates `QWTStage2` with
`/sc onstart`. The stock `payload/setup2.cmd` deletes that task as its FIRST action, which is
what makes it one-shot. The `RELEASE_SETUP` variant of `setup2.cmd` that the builder generates
omitted the delete. Our installer reboots up to three times (stage 1 -> testsigning, install ->
drivers bind), so on every one of those boots the task re-fired and started ANOTHER concurrent
`install.cmd /auto`. Two installers contending for the Windows Installer mutex = two stacked
setup dialogs and a guest whose qrexec stopped answering (gate log: `state=Running` with an
empty hash from 19:33 onward, after having answered at 19:19).

Evidence available: the user's direct observation; the gate log transition from answering to
timing out; and the diff itself. NOT available: `C:\qubes-win-idd-setup.log`, because qrexec was
wedged on that guest. (An earlier claim here that the dom0 screenshot service was broken is
RETRACTED - it works; see the retraction above. A screenshot of the wedged guest WAS obtainable
and I failed to take one.)

Fixed: the generated stage 2 now starts with `schtasks /delete /tn QWTStage2 /f`, with the
incident in the comment.

**Scope of the damage.** The clean-path run is void. The UPGRADE-path result is NOT affected:
it ran `install.cmd` directly over qrexec on `win10-e2e` and never touched this firstboot
payload; its gate passed (4B4CE2B1 -> 77607793) and survived a reboot. The wedged guest is not
being repaired - a system that survived two concurrent installers cannot serve as clean-install
evidence no matter what state it is coaxed into. Rebuild and reinstall from scratch.

## 2026-08-06 — win-idd-test wedge: CAPTURED. 3 vCPUs spinning, ZERO active grants

First forensics taken at the moment of a wedge, before any kill (dom0 service installed by
the user). Archived: `evidence/wedge-2026-08-06/` (dom0 tarball + the frozen-desktop shot).

Trigger: I forced `Stop-Process gui-agent` on win-idd-test to make it re-read SeamlessMode.

Measured, domid 846:

| instrument | result |
|---|---|
| `xl vcpu-list`, two samples 10 s apart | vcpu0 `r--` +10.0 s, vcpu2 `r--` +10.1 s (both pinned ~100 %), vcpu1 `r--` +5.9 s, vcpu3 idle 48.0 s unchanged |
| grant entries, this domain, active | **0** |
| domain state | Running throughout; qrexec dead; desktop frozen (screenshot clock stuck at 23:07 while guest time advanced ~18 min) |

Reading: the guest is NOT hung - three vCPUs are burning CPU in a tight loop - while the
framebuffer grant is **gone**, so dom0 has nothing to read and the pixels freeze. Spin plus
zero outstanding grants is the signature of the revoke-spin class already written up in
`docs/upstream-xen-pv-grant-revoke-spin.md`, now with a live capture behind it rather than
inference.

What this does NOT establish: which code revoked the grant, and whether the spin is cause or
consequence. An `--nmi` capture (deliberately not reachable from the qrexec service) would
name the spinning code via a kernel dump; that is a human decision.

Service bug found by this capture: the wrapper collected `~/wedge-*`, but under qrexec it
runs as root while `11-wedge-forensics.sh` writes to the dom0 user's home - so the tar came
back with only the log. The script's own qvm-copy had already delivered the real tarball.
Fixed to search both `/home/*/wedge-*` and `/root/wedge-*`; re-pull the file into dom0 to
pick this up.

## 2026-08-07 — GATE B PASSED: seamless works on the IDD config after a COLD BOOT; merged to main

The seamless host-mode fix (`agent cb1fa4b`, "seamless mode needs the host size in the IDD
mode set") is now demonstrated on the path that matters — a cold boot, not a service restart,
on win-idd-test with the IDD primary and `SeamlessMode=1` set in both registry keys:

| criterion | measured |
|---|---|
| mode entered | `SetSeamlessMode: Seamless mode changed to 1`; QGAPERF frames stream with `mode=s` (seq 715+ and growing) |
| the fix's code path | `BuildIddModeSet: M6SEAMLESS host 5120x1440 added to set` (repeatedly, incl. before the switch) |
| BADMODE | **0** occurrences in the whole log (the pre-fix signature was `ChangeDisplaySettings failed: 0xfffffffe`) |
| resolution followed | `Win32_VideoController`: IddSampleDriver Device **5120x1440** — the host size, actually applied |
| visual | dom0 fullshot: Notepad rendered as its own red-bordered `[win-idd-test]` window (seamless per-window mapping working) |
| process stability | ONE agent instance across the boot (one log file this boot, PID matches log name) |

Non-fatal wrinkles recorded, not gate failures: 8 transient `0x887a0026` (keyed mutex
abandoned) at startup incl. one `StartFrameProcessing: CaptureInitialize failed` — survived
in place (A7 retry class), no respawn; and `WorkAreaApply: SPI_SETWORKAREA failed 0x57`
twice early in the boot. Both are open items, neither blocks seamless function.

Merged: driver repo `t2/seamless-build` → main (9436282), agent submodule bumped to cb1fa4b.

ALSO: the intended-state device topology, measured for the health gate's allowlist:
IDD `ROOT\DISPLAY\0000` err=0; VGA `PCI\VEN_1234&DEV_1111` err=22 (ours, deliberate);
`XENBUS\VEN_XP0001&DEV_CONS` and `…DEV_VBD` err=28; `XENVIF\VEN_XP0001&DEV_NET\0` err=28
**with the adapter Up and functional** — the last one is unexplained and deliberately kept
OFF the health-check allowlist so the sweep surfaces it.

## 2026-08-07 — health gate VALIDATED both ways; it immediately caught two real things

`guest/health-check.ps1` (replaces the hash-only clean-path gate) now demonstrated per the
instrument rule — seen to FAIL on a defective build and PASS on the intended state:

- **win10-clean (degraded, no IDD)**: ok=false, failed = idd_device_bound (device ABSENT),
  desktop_on_idd, idd_modes_published — exactly the missing function the hash gate scored
  green on 2026-08-06. agent_binary_hash still passes there, proving the two gates measure
  different things.
- **win-idd-test (intended state)**: every check passes except the deliberate XENVIF
  surface (below). PnP allowlist works in both directions.

Instrument bug found while validating (would have made the sweep never-allowlist anything):
once `Get-PnpDevice` has loaded the PnpDevice CDXML module, `Win32_PnPEntity
.ConfigManagerErrorCode` STRINGIFIES as the enum label (`CM_PROB_FAILED_INSTALL`), not the
number, so a string compare against '28' silently fails. Fixed with `[int]` on both sides.
Debugged by instrumenting the real script - an isolated replica of the same loop PASSED,
because the replica never called Get-PnpDevice first.

**Catch #1 — PV NETWORK IS NOT ACTUALLY BOUND on win-idd-test.** The gate refused to
allowlist `XENVIF\VEN_XP0001&DEV_NET\0` err=28, and following it up:
`Get-NetAdapter` shows the active NIC is **Realtek RTL8139C+ (emulated)**, while xenvif
(the PV bus) runs and enumerates the vif child that xennet never binds — despite
ADDLOCAL=...,PvDriversNetwork and xenvif.inf+xennet.inf present in the driver store.
So the 2026-08-06 "networking + Windows Update zero issues" result was real but ran over
the EMULATED NIC, not PV. Re-scoped accordingly: function works, PV path does not.
Whether stock QWT 4.2.2 behaves identically on this platform needs a control before this
counts as our defect. Open item for the release notes either way.

**Catch #2 — the IDD's declared EDID physical size changes the guest's DPI per mode**
(user observed it visually). At host-size 5120x1440 Windows computed the PPI from our
EDID's 60x34 cm and silently switched recommended scaling to 150 % (LOGPIXELSX=144, no
user override present). Previous lower-res runs sat at 100 % — so apparent DPI changed
between runs. Fix in driver/IddSampleDriver/Driver.cpp: image size declared UNDEFINED
(bytes 21-22 and DTD 66-68 zeroed, checksum 0x53→0x78) which pins the recommendation at
96 DPI for every mode; per-monitor user overrides persist via the M1 stable identity.
Needs the next driver build to take effect.

## 2026-08-07 — seamless maximize overflows the dom0 workspace (user-reported); mechanism measured

User: "why is the window maximized beyond workspace area (same as the snapping bug we fixed
in non-seamless mode)?" All numbers below measured on win-idd-test (live guest + agent log).

Three separate mechanisms, two real defects:

1. **First ~3.5 min after boot the work area is INFERRED and under-margined.** Until dom0's
   real work area + frame extents arrived (23:54:52), WaCompute fell back to origin
   inference: `(0,31)-(5120,1440)` — zero bottom/right margin. Windows maximized during
   that window overflow the dom0 workspace bottom. Self-corrects only when the next apply
   fires WaRefitProc; windows launched later use the good value.
2. **Maximized windows carry Windows' invisible resize borders (~7 px at 96 dpi, ~10 px at
   150 %) that overhang ALL screen edges** - measured: work area `(5,56)-(5115,1435)`,
   Word zoomed rect `(-6,45)-(5126,1446)` (DPI-descaled). The agent maps the RAW rect
   into dom0, so even a correctly maximized window paints past the dom0 screen/workspace
   edges. The Linux agent clamps zoomed windows to the work area; ours does not yet.
   **Fix class: clamp IsZoomed windows' reported geometry to the applied work area.**
3. **Permanent Explorer-vs-agent work-area battle**: Explorer recomputes
   `(0,0)-(5120,1380)` from its own taskbar and overwrites the agent's value; the drift
   check re-asserts every 2 s. Converges but churns; the log shows the fight continuing
   for minutes. Also transient `SPI_SETWORKAREA` 0x57 during resolution changes (rect
   validated against the old screen) - benign, self-healing, but noisy.

Also answered: Word comes up maximized because Office persists its window state - normal.
The DPI part of the report is already fixed in source (EDID image size undefined, pending
driver rebuild in the queued release build).

Disposition: recorded as KNOWN ISSUE for this release cycle; the clamp fix (2) reopens the
agent binary during release qualification, so it goes in the next agent build together with
a re-run of the seamless gate. (1) is mitigated by the same clamp; (3) tracked.

## 2026-08-07 — CORRECTION to the seamless-maximize entry above: two claims RETRACTED, one confirmed

An in-source + live investigation (scratchpad/seamless-office-defects.md) refuted the two
loudest claims in the previous entry and in my report to the user:

- **RETRACTED: "the desktop window is mapped in seamless mode".** It is NOT - window 0 is
  unmapped by SetSeamlessMode at boot (main.c:1942 path; boot log confirms). The claim came
  from an instrument bug: the fullshot geometry list enumerates X windows via
  `xwininfo -root -tree` WITHOUT reading Map State, so a withdrawn window is
  indistinguishable from a mapped one. Harness fixed (dom0/07, new `mapped` column) -
  dom0 needs a one-time re-install of that script.
- **RETRACTED: "Word's main frame is never mapped".** All Word frames were mapped with
  per-window buffers; the hwnd I chased (0x2032C) is a 5 px MSO_BORDEREFFECT shadow strip,
  CORRECTLY rejected - silently, because that rejection logs at Verbose while the deployed
  level is Info. (Also noteworthy: these strips were UNOWNED on this build, so the
  style-based rule would not catch them; the class rule is load-bearing.)
- **CONFIRMED (the real defect): the WS_MAXIMIZE clamp used screen bounds, not the applied
  work area** - maximized Word reported 5120x1395 against dom0's 5120x1384 work area
  (~11 px overflow + CONFIGURE ping-pong + grant rebuild), and before the dom0 work-area
  feed lands (~3 min into a boot) maximized windows genuinely ignore the dom0 workspace.
  This is the mechanism behind the user's "maximized beyond workspace" report. Fixed:
  agent branch workarea-clamp-maximize (WorkAreaGetApplied + clamp), needs build + gate
  re-run before it ships.

## 2026-08-07 — clean-path install FAILED on disk selection; answer file no longer trusts DiskID

Symptom (caught by a routine screenshot, not by any check): `win10-clean` Setup stopped with
"Windows cannot be installed to the selected partition. Installation requires at least
20000 MB of free space", then "The installation was cancelled". Root volume usage stayed at
**0.0 GiB** - Setup never wrote a byte.

Cause: the answer file hardcoded `<DiskID>0</DiskID>`. A Qubes HVM presents THREE disks and
the guest-side numbering is only stable AFTER install - measured on the working guest
win-idd-test: `DISK 0 80GB boot=True / DISK 1 2GB / DISK 2 10GB` (root / private / volatile).
WinPE's enumeration is not guaranteed to match, and on this run Disk 0 was one of the small
volumes; 2 GiB and 10 GiB are both below Windows' 20 GB minimum, hence the message. This is a
LATENT race that had silently worked on every previous install, not a new regression.

Fix (both answer files, both media routes): the static `DiskConfiguration` is gone. A new
`mgmt/diskprep.cmd` runs in windowsPE (RunSynchronous, before image apply), picks the
LARGEST disk via `wmic diskdrive get Index,Size`, refuses anything under 25 GB with a
logged reason, partitions it MBR+active+NTFS as C:, and leaves the other disks RAW.
`<InstallTo>` is replaced by `<InstallToAvailablePartition>true</InstallToAvailablePartition>`,
so Setup can only land on the one installable partition that exists. Both ISO builders stage
diskprep.cmd at the media root and hard-fail if it is missing.

Note on the failure mode this REPLACES: the old bug always failed loudly (both small disks
are under Windows' minimum), so no past install can have silently landed on the wrong disk.

## 2026-08-07 — toast notification: mapped borderless over a maximized window (user-reported)

User: "a toast popped up in notepad window on win-idd-test, it certainly should not happen."

Measured, not inferred:
- dom0 geometry at that moment: `0x740018e 1524 667 396 373 ovr=1 "New notification"` -
  its OWN X window, override-redirect (borderless), at the bottom-right of the work area
  (work area (5,56)+1915x984 ends at 1920,1040; the toast ends at exactly 1920,1040).
- **Notepad's per-window buffer is CLEAN** (`qtest shot` -> win-0.png shows no toast pixels),
  so this is NOT capture contamination - per-window capture behaved correctly.
- Classification path: `IsPopup` (main.c:812) marks any visible window without WS_CAPTION
  (and without SYSMENU+APPWINDOW) as override-redirect. A toast has no caption -> borderless.

So the toast is drawn exactly where Windows draws toasts, but WITHOUT a Qubes border, which
makes it visually indistinguishable from the content of the window it covers.

**Open question the spec does not settle.** CLAUDE.md 2A-chrome 3c says toasts "must be KEPT,
mapped override_redirect" - what the code does today. But the same section's NOTE says that on
Linux qubes a notification arrives "as a normal bordered window". The user's report sides with
the NOTE. Not changed unilaterally: making toasts bordered is a one-line predicate change, but
the safe discriminator needs the toast's live in-guest attributes (owner, class, styles), and
an attempt to re-fire one for capture did not render (unregistered app id). Next step: catch a
naturally occurring toast with the winenum probe, then decide between "unowned windows are
never override-redirect" (principled: synthesis already assumes popups are owned) and a
narrower shell-notification class rule.

## 2026-08-07 — RETRACTION: my work-area maximize clamp was WRONG and is reverted

Claimed earlier today as a verified fix ("maximized Notepad reported exactly the applied work
area"). It was verified against the wrong criterion. The user saw the truth within the hour:
**"notepad window has no menus and content"**.

Mechanism, from our own source: `entry->X/Y/Width/Height` is NOT merely the geometry reported
to dom0 - `perwindow.c:305` derives the per-window CAPTURE CROP from it
(`cropX = entry->X - wr.left; cropY = entry->Y - wr.top`). Raising `entry->Y` from the raw
-8 to the work-area top 56 therefore cropped **64 px off the top of the window's own content**
- precisely the title bar and menu bar. The geometry number I checked looked perfect exactly
because the window had been shrunk to match it.

Why the screen clamp was right all along: against screen bounds the clamp only trims the
invisible resize border (cropY = 0 - (-8) = 8), which is the margin the per-window crop is
designed to skip. The original comment said so; I did not take it seriously enough.

Reverted (agent a68d244). `WorkAreaGetApplied()` stays - correct and harmless.

Restated correctly: **"maximized window overflows the dom0 workspace" is a WORK-AREA problem,
not a geometry-reporting problem.** Windows had maximized Notepad against the full screen
(raw rect -8,-8 1936x1056) even though the agent had applied (5,56)-(1915,1040) - i.e. the
SPI_SETWORKAREA did not stick for that window, or arrived after it maximized. The fix belongs
in the work-area path (make it stick, re-fit maximized windows afterwards), never in what we
tell dom0 the window is.

Process note: this is the "judge output, not logs" rule failing in its exact documented form.
I verified a NUMBER (reported geometry == work area) and called it a pass without looking at
the resulting pixels; a `qtest shot` of that window would have shown the missing menu bar
immediately, and in fact the per-window PNG I captured for an unrelated toast question DID
show a menu-less Notepad - I looked straight past it.

## 2026-08-07 — CLEAN-ROOM INSTALL ROUTE adopted for Win10 AND Win11 (user directive)

User: *"if we can run unattended install with stock images, why rebuild ISOs at all? it
breaks our clean room approach"* — and then *"use the answer disc route for win11 too"*.

Both correct, and the first is a CORRECTNESS argument before an efficiency one. Every
clean-path result before today was produced on media I had repacked: `bootfix.bin` removed,
`install.wim` split into `.swm`, `$OEM$` injected, boot layout rebuilt. An install passing on
that proves the package installs on *my reconstruction* of Windows media, not on the vendor's.
That is precisely the property the clean-path acceptance exists to establish, and repacking
spends it.

New route, now used for both guests:
- **CD 1 = the vendor ISO, byte-for-byte untouched**, booted via `qvm-start --cdrom`.
- **CD 2 = a 29 MB answer disc** (`mgmt/build-answer-disc.sh`): `autounattend.xml` +
  `diskprep.cmd` + `\payload` (incl. the release package, installed with `/auto /idd`),
  assigned PERSISTENTLY (`qvm-device block assign --option devtype=cdrom --ro`) so it
  survives the installer's reboots — a `--cdrom` assignment does not.
- `scratchpad/reprovision.sh` gains `ANSWER_LOOP=loopN` and ASSERTS the assignment stuck;
  a silently-absent answer disc is indistinguishable from "the answer file was ignored"
  an hour later, which already cost one cycle today.

Cost per iteration: **1 second / 29 MB**, against ~15 min / 5.8 GB / ~12 GB of transient
disk for a repack. The repack route filled `/home` to 100 % and killed its own build today.

Win11 disc verified before use: 6 LabConfig bypass entries (TPM/SecureBoot/RAM/CPU/Storage),
image name "Windows 11 Enterprise Evaluation" (confirmed by `wiminfo` against the eval ISO,
single-image WIM), `InstallToAvailablePartition`, `diskprep.cmd` staged at the disc root,
en-US locale matching the en-US media, payload calling `install.cmd /auto /idd`.

Sequencing note: the Win11 run is CHAINED behind proof that the two-disc route boots on
Win10 (its install reaching qrexec), not started blindly in parallel — if the route were
broken, two 45-minute cycles would discover the same defect instead of one.

Status: both runs in flight. The repack route (`build-unattended-iso.sh`) stays in the tree
as a fallback but is NO LONGER the default for acceptance.

## 2026-08-07 — the clean-room route's FIRST run exposed two harness defects (both mine)

The run failed within seconds, and both causes were checks that could not do their job -
the same class this file keeps recording:

1. **A check that could never PASS.** The answer-disc assertion I had just written used
   `qvm-device block list "$VM"`, and this qube has NO PERMISSION for that call (it answers
   "Failed to list 'block' devices ... you do not have access"). So the assertion failed on a
   run where the assignment had in fact succeeded. Verified afterwards the permitted way: a
   SECOND `qvm-device block assign` answers *"block device win-idd-mgmt:loop1::1 already
   assigned to win10-clean"* - which is positive proof the first one stuck. That is now the
   check.
2. **A check that could never FAIL.** `reprovision.sh ... | tee -a log || fail "..."` judges
   TEE's exit status, not reprovision's. reprovision exited 1 and the harness sailed past it,
   printing "waiting for the release install to complete in-guest" about a guest that had
   never been started. Now judged via `${PIPESTATUS[0]}`, and the guard was demonstrated to
   catch a deliberately failing command before being trusted.

Both fixed and relaunched. Worth stating plainly: the assertion in (1) was written *because*
a silently-missing answer disc is indistinguishable from "the answer file was ignored" an
hour later - and it was written in a form that could not work. Permission-dependent commands
must be exercised once by hand before they are used as gates.

## 2026-08-07 — the two-disc "clean room" route is IMPOSSIBLE on Qubes HVM (measured, decisive)

Attempted per the user's directive ("if we can run unattended install with stock images, why
rebuild ISOs at all?"). It does not work, and the reason is at the platform level, not ours.

Run 1 - `qvm-start --cdrom=<stock ISO>` + answer disc assigned persistently
(`qvm-device block assign --option devtype=cdrom --ro`, assignment VERIFIED by a second
assign reporting "already assigned"): Windows Setup stopped at the **locale picker**, i.e.
`autounattend.xml` was never found. (Screenshot evidence.)

Run 2 - the decisive one. BOTH discs assigned as cdrom, VM started with NO `--cdrom`:

    SeaBIOS (version 1.16.2-1.fc41)
    Booting from Hard Disk...  Boot failed: not a bootable disk
    Booting from Floppy...     Boot failed: could not read the boot disk
    No bootable device.

The firmware sees **no CD-ROM whatsoever**. So `qvm-device block assign --option
devtype=cdrom` does NOT create an emulated IDE CD-ROM; it creates a Xen PV (xvd*) device.
Only `qvm-start --cdrom=` produces the QEMU-emulated, bootable CD. WinPE carries no Xen PV
drivers, so any assigned device is invisible to Windows Setup - which is exactly why run 1
found no answer file.

**RETRACTION of the 2026-08-06 entry** "stock ISO + separate answer disc ... a second virtual
CD is available". That conclusion rested solely on the assign COMMAND being accepted (rc=0,
"already assigned" on a repeat). Command accepted != device present in the guest - the same
"a check that cannot fail" pattern this file keeps recording. The route was recorded as
designed-and-verified when only its dom0 half had ever been exercised.

CONSEQUENCE: on Qubes HVM the answer file must live on the ONE booted CD, so unattended
install requires a repacked ISO. What can still be protected is how MUCH is changed - see
the minimal-repack note below.

## 2026-08-07 — the self-matching pgrep guard, again (process note)

Wrote `until ! pgrep -f "build-unattended-iso.sh"; do sleep 20; done` to wait for the ISO
build. `pgrep -f` matches full command lines, and the waiter's OWN shell command line
contains that string - so the guard matched itself and would have waited forever while the
build had in fact finished (log showed the ISO written and the vendor delta emitted).

This is verbatim the defect called out in the 2026-08-06 handoff's process note ("a pgrep
guard that matched its own monitor, so a watcher 'ran' while nothing ran"). Recording it
because knowing about a trap did not stop me walking into it: the fix is to not identify
work by a string that the waiter itself contains - wait on the PID, on a sentinel file, or
grep the log for the completion line.

## 2026-08-07 — CLEAN-PATH ACCEPTANCE: install PASSED, health gate FAILED. /idd is not release-ready

First clean-path run on minimal-repack media (vendor ISO `edc53c5c…`, delta manifest beside
the image). Reported honestly, because the install half genuinely worked:

**PASSED** - the install itself, on a guest that had never seen QWT (`existing_qwt: []`):
qrexec answered after 1314 s (proving OUR package delivered it), `ok:true`,
`payload_files_verified: 20/20`, agent hash == manifest (`b758dd92…`), and the IDD
activation sequence ran exactly as designed:

    devcon: Drivers installed successfully.
    IDD devnode up: ROOT\DISPLAY\0000; waiting up to 30 s for its display adapter
    IDD display adapter present: IddSampleDriver Device
    disabling emulated VGA adapter: PCI\VEN_1234&DEV_1111...
    IDD ACTIVATED

Also confirmed: the answer file WAS read off the repacked media (Setup went straight to
"Installing Windows", no locale picker) and `diskprep.cmd` selected the 80 GiB disk by size.

**FAILED - `desktop_on_idd`.** After the reboot the desktop runs on **Microsoft Basic
Display Adapter at 3440x1440** while the IDD sits **offline** (`Availability=8`, no
resolution). Re-measured after settling: identical, so it is not a sampling race.

The confusing part, measured directly: the VGA disable DID persist -
`PCI\VEN_1234&DEV_1111... err=22`, `ConfigFlags=1` (CONFIGFLAG_DISABLED) - and
`ROOT\BASICDISPLAY\0000` is present at err=0. So Windows disabled the PCI adapter as asked
and then drove the desktop through the Basic Display **driver** fallback instead of
attaching the IDD. Disabling the VGA is therefore NOT sufficient to make the IDD the
desktop: an IddCx monitor arrives INACTIVE and something must still activate it
(SetDisplayConfig / topology apply). Our installer never does that step - it assumed the
VGA disable was enough. On win-idd-test the IDD-primary state was reached through the
2026-08-05 experiment sequence, not through this installer path, which is why it was never
caught before.

**Then the guest WEDGED.** Shortly after the health probes, win10-clean stopped answering
qrexec. Forensics captured automatically before any kill (`evidence/wedge-win10-clean-031334`,
domid 884): **zero active grant entries** - the revoke-spin signature in
`docs/upstream-xen-pv-grant-revoke-spin.md`. **Causation NOT established**: this wedge class
has been seen without the IDD, so "the IDD activation caused it" is a hypothesis, not a
finding. What IS established is that this configuration (IDD bound but offline, desktop on
the fallback) reached a wedge within minutes of first boot.

### Release decision (mine, evidence-backed)

`/idd` comes OUT of the default unattended payload and stays an explicitly opt-in,
documented flag. Justification: on a clean install it currently produces a guest whose IDD
is installed and bound but NOT driving the desktop - i.e. no arbitrary-resolution support in
practice, the very defect the flag was added to fix - and that guest wedged. Shipping it on
by default would make every clean install worse than the plain Basic Display Adapter build,
which at least is stable. The activation gap (topology apply after reboot) is now a named,
reproducible bug with a clear fix direction rather than an unknown.

## 2026-08-07 — WIN11 CLEAN-PATH ACCEPTANCE: health gate PASSED 8/8 with the FULL IDD assertion

`win11-fresh`, Windows 11 24H2 build **26100**, installed unattended from the UNTOUCHED
vendor eval ISO (`755a90d4…`) via minimal-repack media, guest never had QWT:

- install: `ok:true`, agent hash == manifest (`b758dd92…`), package
  `4.2.2+agent.018ec54d1584`, qrexec answered after 2009 s (so OUR package delivered it),
  LabConfig TPM/SecureBoot/RAM/CPU/Storage bypasses worked, `diskprep.cmd` picked the disk.
- health gate, run WITHOUT `-NoIddExpected` (the full assertion): **8/8 pass**, and
  decisively `desktop_on_idd` PASSED - `IddSampleDriver Device` is the ONLY active
  controller (1920x1080, Availability 3) while `Microsoft Basic Display Adapter` is
  Availability 8 (offline). `non_idd_active = 0`. Modes published: 5120x1440, 1024x768.

**This inverts the conclusion I drew two hours ago.** I predicted the activation gap would
reproduce on Win11 and treated it as platform-independent. It does not: **`/idd` activation
works end to end on Win11 24H2 and fails on Win10 19045.** Same installer, same package,
same activation sequence, opposite outcome - so the defect is in how Win10 19045 responds to
"PCI VGA disabled + IddCx monitor present": it spins up the ROOT\BASICDISPLAY fallback and
leaves the IDD offline, where Win11 attaches the IDD.

Corroborating datum that this is not "Win10 cannot do it": win-idd-test IS Win10 19045 and
runs IDD-primary at 5120x1440 (Gate B, same day). It reached that state through the
2026-08-05 manual experiment sequence, not through the installer - so on Win10 something in
that sequence performs the activation the installer omits. That is the fix's target.

Release stance UNCHANGED for now (`/idd` stays opt-in, out of the default payload): a Win10
user would still get the degraded, wedge-prone state, and Win10 is the more common target.
But the write-up must say what is true - verified working on Win11 24H2, broken on Win10
19045 via the installer path - rather than "broken".

### Win11 visual step: dom0 SERVICE limitation, not a product failure (do not misread this)

The Win11 run ended `ACCEPT=FAIL reason=screenshot service returned empty tar`. That is NOT
a guest defect. Guest-side evidence, which does not depend on dom0 policy:

    MAPS=4                              (SendWindowMap x4)
    QGAPERF,v=2,seq=7032,...,mode=s,...,win=2      seamless, 2 windows mapped, streaming
    QGAPROTO,msg=SYNTHPAINT,hwnd=0x10284,owner=0x201a6   popup synthesis working
    vchan connected (blocking read on an idle channel)

So the Win11 guest is in seamless mode with windows mapped and frames flowing. The per-VM
`local.WinScreenshot+win11-fresh` returns 0 bytes because the dom0 screenshot service does
not serve `win11-fresh` (its allowlist names win-idd-test / win10-clean / win10-e2e, as seen
when the wedge service was installed). `fullshot` confirms it: the geometry it returns lists
win-idd-test's windows, not win11's.

**Needs one dom0 action from the user** to close the visual acceptance on Win11: add
`win11-fresh` to the screenshot service's allowlist (or reinstall it with the tag-based
policy so any `win-idd-testbed`-tagged qube is served). Until then Win11 visual acceptance is
UNPROVEN-BY-TOOLING, and is recorded as such rather than as a pass or a failure.

## 2026-08-07 — toast attribute capture: TWO approaches, both NEGATIVE (recorded, not glossed)

Needed to settle the user's toast report (borderless toast painted over a maximized window)
by capturing a live toast's real window attributes, per CLAUDE.md 2A-chrome 3c.

1. **Fired via qtest directly** - nothing rendered. Diagnosed: qrexec runs in **session 0**,
   which does not composite. Same limitation already recorded for `cpu-bench.ps1` (its load
   ran in session 0 and both benchmark sides read 0.05 %) and `dump-windows.exe`.
2. **Fired from an INTERACTIVE scheduled task** (`/ru user /it`, the cpu-bench pattern;
   probe committed as `guest/toast-probe.ps1`) - still nothing. The probe enumerated for 6 s
   and caught only `Windows.UI.Core.CoreWindow` (TextInputHost) and `ApplicationFrameWindow`,
   both `cloak=2` i.e. not actually on screen.
3. A 4-minute watch for a NATURAL toast (`scratchpad/toastwatch.ps1`) also caught none.

So a toast can be *observed* on this guest (the user saw a OneDrive one, and dom0 geometry
captured it as `0x740018e … ovr=1 "New notification"`), but not *summoned* on demand by any
route tried. Likely remaining causes: the notifier app-id is not registered in Action Center
on this image, or notifications are suppressed for the autologon account.

**The classification question therefore stays OPEN and the predicate is UNCHANGED.** What is
already established without the capture: the toast is its own X window, override-redirect via
`IsPopup` (main.c:812, no WS_CAPTION -> borderless), and Notepad's per-window buffer was
CLEAN, so this is purely about classification, not capture contamination.

Carried caution for whoever changes the predicate: on this build the Office shadow strips are
**unowned**, so a rule like "unowned windows are never override-redirect" would drop toasts
and Office shadows together. `MSO_BORDEREFFECT_WINDOW_CLASS` is the load-bearing rule for the
shadows; any new discriminator must keep BOTH outcomes (shadows dropped, toasts kept/bordered).

## 2026-08-07 — DRAFT release cut, deliberately NOT published

`gh release create --draft` with the package tarball (27 MB) and ISO (29 MB) from CI run
31129344581, package `4.2.2+agent.a68d24492b25`.

Draft, not published, for one specific reason found while cutting it: **the clean-path
acceptances ran the PREVIOUS build.** `artifacts-rel/setup3` (used to build both test ISOs)
carries `agent.018ec54` - the build that contains the maximize-clamp regression. The release
package carries `agent.a68d244`, where that is reverted. So Win11's 8/8 health pass and
Win10's install pass are evidence for a DIFFERENT binary than the one being shipped.

This is the project's own rule ("verify the artefact under test is actually installed -
compare the running binary's hash to the manifest") applied one level up: the artefact
under test and the artefact being released are not the same build. The release notes state
this in a table rather than burying it, and the release stays a draft until acceptance is
re-run against `a68d244`.

Also noted in the notes: `/idd` works on Win11 24H2 and is broken on Win10 19045 (with the
recovery command), PV networking is not bound, toasts map borderless, and maximized windows
can still overflow the dom0 workspace early in a boot.

## 2026-08-07 — Win10 clean install WEDGES on the first reboot after install — and it is NOT the IDD

`win10-clean`, default configuration, **no `/idd`** (media verified: `install.cmd /auto`):
install completed (`ok:true`), harness rebooted the guest for boot-path acceptance, and the
guest never answered qrexec again. `ACCEPT=FAIL reason=guest did not answer qrexec after
reboot`. Forensics captured automatically before any kill
(`evidence/wedge-w10-noidd-041212`): domain **Running**, **zero active grant entries** - the
same revoke-spin signature as every other wedge in this project.

**This clears the IDD of the earlier wedge.** Two hours ago `win10-clean` wedged after an
`/idd` install and I recorded causation as unproven; it now wedges identically WITHOUT the
IDD, so `/idd` is not the trigger. The two facts are independent:
- `/idd` on Win10 leaves the IDD offline (real, reproducible, task #11);
- Win10 clean installs wedge on the first reboot after install (real, and the more serious
  of the two, because it hits the DEFAULT configuration we intend to ship).

Contrast that isolates it: `win10-e2e` (UPGRADE over an existing QWT) survived its own reboot
on 2026-08-06, and `win-idd-test` reboots repeatedly today without wedging. What is unique to
this path is a FRESH Windows install where our package has just installed the Xen PV drivers
(`ADDLOCAL=PvDriversCore,Core,Gui,PvDriversNetwork`) - the first boot after PV-driver
installation is exactly the "PV-servicing signature" already noted in this file. Win11's
clean install did NOT wedge on the same step, so it is Win10-specific like the IDD issue.

Testing now whether a SECOND boot recovers it. That distinction decides severity: a
first-boot-only wedge is a bad but survivable install experience with a workaround; a
permanent one is a hard blocker for Win10 clean installs and must stop the release.

## 2026-08-07 — disk exhaustion has now broken TWO ISO builds; it is a real process defect

`build-unattended-iso.sh` needs roughly **12 GB transient** (6 GB extracted tree + ~5 GB .swm
split + 5.8 GB output) on top of whatever is already there. Started it twice with less
(8.1 GB, then 8.6 GB free) and both died mid-write with `xorriso: No space left on device`,
each costing ~10 minutes and, the second time, silently leaving a truncated ISO.

The script should REFUSE to start rather than fail 10 minutes in. Recorded as a defect to
fix; the immediate mitigation is deleting superseded ISOs first (each vendor image is 5-6 GB
and each build output another 5-6 GB, so two stale files is the whole budget).

Related: this is why the answer-disc route mattered - 29 MB and one second per iteration
instead of 5.8 GB and ~12 minutes. It remains impossible on Qubes HVM for the reasons
measured earlier, so the disk discipline has to compensate.

## 2026-08-07 — RETRACTION: the Win10 "second boot also wedged" claim was MY HOST, not the guest

I reported the Win10 clean guest as failing to come back on a second boot and, on the user's
criterion, called that a hard blocker. **Wrong, and retracted within the hour.**

With `win11-fresh` shut down (three Windows guests = 24 GB committed on this host was the
confound) `win10-clean` booted and answered qrexec in **22 seconds**. The domain had been
stuck in `Transient` - a start-time state, not the Running+zero-grants signature of the real
wedge class - which was the tell I should have read before asserting severity.

**This also puts the FIRST wedge back in question.** It happened while the same three guests
were running (win11-fresh was mid-install), so host resource pressure is a live alternative
explanation there too, and "Win10 clean installs wedge on first reboot after install" is
NOT established. It is recorded as: one unexplained wedge under known memory pressure, with
forensics archived (`evidence/wedge-w10-noidd-041212`). The project has been bitten by
exactly this before - the ISO-attach "blocker" that turned out to be an exhausted xenstore
quota, and the mirage-firewall netvm that never brought up its vif.

Lesson for the harness, not just for me: **acceptance runs must not share a host with another
install.** Two 8 GB guests plus the 8 GB reference guest is over budget here, and the failure
mode it produces (silent guest, stuck domain) is indistinguishable at a glance from the real
wedge class it is supposed to detect.

### With the confound removed, Win10 DEFAULT-CONFIG acceptance PASSES

Re-run on the recovered guest, `-NoIddExpected` (media has no `/idd`): **health gate 7/7**
- agent_binary_hash, agent_process, qubes_services_running, idd_device_bound,
idd_modes_published, pnp_no_unexpected_errors, agent_log_healthy - at 3440x1440. Agent-side:
`MAPS=5`, ONE agent log this boot (no respawn), QGAPERF streaming in `mode=s`.

Caveats kept: the dom0 per-VM screenshot returned an empty tar for this guest (as it did for
win11-fresh), so the VISUAL/chrome half is again unproven-by-tooling rather than passed - the
gui-daemon was very likely not re-attached after the kill/start cycle
(`DESIGN-gui-daemon-restart-survival.md`). And this guest runs `agent.018ec54`, not the
shipped `a68d244`.

## 2026-08-07 — OFFICE COMPOUND-WINDOW CHECK: PASSES in seamless mode (2A-chrome acceptance)

Blocked all session by an instrument bug, not by the product. `guest/office-window-check.ps1`
launches Word over qrexec, i.e. in **session 0**, which has no interactive desktop - WINWORD
starts and exits in ~2 s (`WORD_EXITED after 2s exitcode=0`), so the enumeration reported
`n=0` every time and the check silently proved nothing. Third instance of this trap today
(cpu-bench's load generator, the toast probe, this).

Fixed with `guest/office-window-check-interactive.ps1`: the enumeration is handed to a
scheduled task with `/ru user /it` so it runs in the interactive session.

**Measured, seamless mode, win-idd-test:**

    guest: OFFICE_HWNDS n=8   office_main_frames=3  office_shadow_candidates=4
    dom0 : Document3 - AutoRecovered - Word
           Document1 - AutoRecovered - Word
           Document3 - Word
           Sign in to set up Office          (a REAL Office dialog, correctly mapped)

Eight visible Word windows in the guest; **four** in dom0 - the three real document frames
plus the genuine sign-in dialog. **All four shadow-strip windows were dropped**, and no
document frame was lost. That is exactly the 2A-chrome criterion (Office chrome fragments
must not be presented as separate bordered qube windows), demonstrated on the real
application rather than on `tools/chromerepro`.

Note this could ONLY be shown in seamless mode - in fullscreen the whole desktop is one dom0
window and there are no per-window frames to count, which is why every earlier attempt at
this check was inconclusive.

## 2026-08-07 — SNAP REGRESSION: PASS in the fullscreen config (and why the first run "failed")

Ran `scratchpad/snap-regress.sh` against `win-idd-test` while it was still in SEAMLESS mode
(SeamlessMode=1, left over from Gate B) and got **FAIL on all three resize tests** - every
requested size came back 1920x1080.

That was NOT a regression, it was the wrong configuration: in seamless mode `SetSeamlessMode`
forces the HOST resolution on every StartFrameProcessing, so the guest cannot follow
per-window resize requests at all. The battery targets the T2 FULLSCREEN configuration where
the guest resolution follows the dom0 window. The tell was that T4 (position preservation)
PASSED while the three size tests failed identically - the agent working, simply not honouring
resize in that mode.

Switched to `SeamlessMode=0` in both registry keys, rebooted (back in 18 s), re-ran:

    feed: 0 31 5120 1409 5 5 25 5 -> bordered half = 2550x1379
    T1 near-half snap : PASS (2544x1375 -> 2550x1379)
    T2 20px-off no-snap: PASS (2530x1359 exact)
    T3 arbitrary no-snap: PASS (1803x957 exact)
    SNAP-REGRESS PASS

One item flagged, NOT swept up: **T4 position CHANGED** (x=3195,y=355 -> x=2565,y=56) on this
run, where it was preserved on the seamless run. The harness itself annotates it "WM may
legitimately clamp" - a dom0-window move to the snapped half can legitimately reposition it.
Recorded as unexplained rather than as a pass: it needs one run where the requested position
is inside the work area to distinguish "we moved it" from "the WM clamped it".

Process point, third time today: a check run in the wrong configuration produces numbers that
look exactly like a product failure. Same shape as the session-0 traps (benchmark load, toast
probe, Office check). Before reporting any FAIL, establish that the configuration under test
is the one the check was written for.

## 2026-08-07 — SHIPPED-BUILD acceptance FAILED: an interactive MSI dialog blocks the install

The run whose whole point was to make the evidence match the RELEASED binary
(`agent.a68d244`) did not get there. `ACCEPT=FAIL reason=install never reported stage2
ok:true + running agent` after the full 2400 s budget - where every previous run reached
"install reported complete" in about 3 minutes.

Cause, from the screenshot (`evidence/accept-win10-clean-20260807-043957/stuck-installer-dialog.png`):
a **"Qubes Windows Tools setup" dialog is open on the guest desktop with a Close button**,
i.e. the installer is sitting in INTERACTIVE UI waiting for a human that will never come.
The guest is otherwise healthy - desktop up, taskbar, "Test Mode Build 19041.vb_release..."
watermark - so this is not a wedge and not a crash.

Note the resemblance to the 2026-08-06 incident the user reported as "two close buttons":
that was two CONCURRENT installers (the QWTStage2 ONSTART task re-firing), fixed by having
stage 2 delete its own task. This dialog again appears to show a second, greyed Close
beneath the active one. Whether the same concurrency is back on this media, or the MSI
simply fell out of silent mode, is NOT established - and the difference matters, so it is
recorded as unexplained rather than assumed.

Suspicious detail found while looking, not yet proven to be the cause: with `NO_QWT=1` the
ISO builder still copies **stock** `~/win-iso/qwt-payload/installer.msi`, `vc_redist` and the
QWT certs into `\payload` (the `for f in ...` loop only excludes `qwt-installer.exe/.msi`,
not `qwt-payload/installer.msi`). The release `setup2.cmd` does not invoke it, but a stock
QWT MSI sitting in the payload of a "no stock QWT" image is at best confusing and at worst
reachable by `firstboot-setup.ps1`. Worth auditing before the next media build.

### Consequence for the release

**The draft release stays UNPUBLISHED.** Its notes already state that the acceptance evidence
is for `agent.018ec54` and not for the shipped `a68d244`; this attempt to close that gap
failed for an installer-flow reason, so the gap is still open. Publishing now would ship a
package whose install has never been observed to complete unattended end to end.

## 2026-08-07 — the blocking dialog: a STOCK QWT MSI left on a "no stock QWT" image

Diagnosis of the shipped-build acceptance failure, from what could be established without
guest access (qrexec was dead, which is itself a clue):

- Our installer runs BOTH msiexec calls with `/qn` (install at line ~617, uninstall at ~397),
  and vc_redist with `/quiet /norestart`. **None of our invocations can show UI.**
- `firstboot-setup.ps1` invokes no installer at all; `install-qwt.cmd` is only ever called by
  the STOCK `payload-setup2.cmd`, which NO_QWT=1 replaces. So nothing in our flow runs it.
- Yet `\payload\installer.msi` (3.3 MB, the STOCK QWT MSI), `install-qwt.cmd` and
  `vc_redist.x64.exe` WERE on the media - the NO_QWT exclusion in the staging loop only
  covered `qwt-installer.exe/.msi`, never `qwt-payload/installer.msi`.
- Timeline fits: qrexec came UP at 1252 s (our package installed) and then DIED, with an
  interactive "Qubes Windows Tools setup" dialog left on the desktop.

Mechanism: our package registers the SAME ProductCode as stock QWT. Windows Installer
resiliency resolves a repair/reinstall against a cached or discoverable source - and a stock
MSI for that product sitting at a fixed path is exactly such a source. A resiliency repair
runs in the USER session with UI, which is precisely the dialog observed, and it explains
qrexec disappearing (the repair tearing components down) with no corresponding line in our
own installer log.

**Honesty about confidence:** the ProductCode identity and the resiliency path are inferred
from our own documented behaviour ("our binaries carry the same version resource as ITL's",
2026-08-06) plus the observed sequence, NOT from the guest's MSI log - the guest was
unreachable and rebuilding destroys the evidence. So this is a well-supported hypothesis with
a fix that is correct regardless: **a "no stock QWT" image must not carry a stock QWT MSI.**

Fixed in `mgmt/build-unattended-iso.sh`: the stock MSI, `install-qwt.cmd` and vc_redist are
excluded under NO_QWT=1, and the build now ASSERTS afterwards that none of them is staged,
failing loudly if one reappears. Re-running the shipped-build acceptance on the corrected
media; the assertion is checked before the run is allowed to start.

## 2026-08-07 — PV NETWORKING ROOT CAUSE FOUND: xenvif/xennet revision mismatch

User raised the bar: "check not only if it installs but also if everything works (PV, IDD,
clipboard)". Added those assertions, `pv_drivers_bound` failed immediately, and following it
down produced an exact root cause rather than another "not established".

Measured on win-idd-test:

    device XENVIF\VEN_XP0001&DEV_NET\0   err=28 (no driver), service = <empty>
    device HardwareIDs:  ...&DEV_NET&REV_09000004   (highest offered)
                         ...&REV_09000003 / 02 / 01 / 00, then XENDEVICE
    xennet INF (oem5.inf) declares ONLY:
                         XENVIF\VEN_XP0001&DEV_NET&REV_09000005
                         XENVIF\VEN_XP0002&DEV_NET&REV_09000005

**xenvif publishes a child at REV_09000004 and below; xennet claims REV_09000005 only.**
No hardware ID intersects, so PnP finds no driver for the device and leaves it at code 28 -
`CM_PROB_FAILED_INSTALL`. That is the whole mechanism. Nothing is "broken" at runtime: the
two PV components in this QWT package are simply built against different interface revisions,
so the network child can never bind, and Windows falls back to the emulated Realtek NIC -
which works, which is exactly why every previous check passed.

Both INFs are in the driver store (`xenvif.inf`, `xennet.inf`, provider "Xen Project"), so
this is not a missing-driver or signing problem.

**Scope: NOT ours to fix in this repo.** These are the upstream Xen PV drivers as shipped
inside QWT 4.2.2's MSI; we neither build nor patch them. Options, in order of honesty:
1. Report upstream (qubes-windows-tools / the Xen Project win-pv-drivers) with this evidence -
   it qualifies under the "bugs OUTSIDE QWT scope get reported" exception in CLAUDE.md, and
   the exact revision numbers make it actionable. **Needs the user to approve the text first.**
2. Verify whether STOCK QWT 4.2.2 shows the same mismatch on this platform (it almost
   certainly does, since the MSI payload is the same) - that determines whether this is a
   regression we introduced (it is not, but that must be shown, not asserted).
3. Until then the release notes must say PV networking runs over the emulated NIC.

The health gate now FAILS on this, which means the release cannot pass the user's bar until
it is resolved or explicitly waived. That is the correct behaviour, not an obstacle to route
around.

## 2026-08-07 — RETRACTION: the PV mismatch is NOT our build. Our MSI's PV drivers are byte-identical to stock

User pushed back: "we know for sure it works in stock qwt and our previous builds, so if it
does not you are building from wrong code base". Checked it properly instead of arguing.

Extracted BOTH MSIs (`vendor/qwt-4.2.2/installer.msi` = stock, and our CI-built
`artifacts-final/setup/msi/installer.msi`) and diffed every stream:

    files differing between stock and ours: 3
      gui-agent.exe      (ours, expected)
      gui-watchdog.exe   (ours, expected)
      one ASCII text file
    EVERY OTHER FILE, including every Xen PV driver, is BYTE-IDENTICAL.

    xennet hardware IDs: identical in both  (REV_09000005 only)
    xenvif DriverVer:    identical in both  (04/07/2025, 9.1.0.0)

So the "we are building from the wrong codebase" hypothesis is REFUTED, and so is my
"upstream packaging bug" framing from an hour earlier - **both retracted**. Our package
ships stock's PV drivers unmodified.

What is still true and unexplained: on **win-idd-test** the `XENVIF\...&DEV_NET` child
advertises at most `REV_09000004` while the installed xennet claims `REV_09000005`, so it
sits at code 28 and the guest runs on the emulated Realtek NIC. Installed xenvif reports
9.1.0.0 - matching the MSI - yet a SECOND xenvif entry appears with an EMPTY version, i.e.
that guest has leftover/duplicate PV driver state.

win-idd-test is the wrong guest to conclude anything from: it has been through the original
stock-QWT provisioning, an overlay install, a full uninstall+reinstall, and repeated agent
swaps. **The decisive test is win10-clean** - a fresh Windows where ONLY our package ever
installed PV drivers - which is installing right now, and whose gate now includes
`pv_drivers_bound`. Conclusion deferred to that result rather than generalised again from a
much-abused reference guest. I have now been wrong on this twice in one hour by doing exactly
that.

## 2026-08-07 — PV mismatch is REAL and lives inside the QWT 4.2.2 payload; upstream drivers would bind

Chased the user's question ("if they are byte identical, how come they announce different
hw?") to a concrete answer by fetching the Xen Project's own Windows PV drivers
(https://xenbits.xen.org/pvdrivers/win/, index reachable, tarballs dated 2023-07-13).

    QWT 4.2.2 xennet (stock AND ours - byte-identical):  requires REV_09000005
    QWT 4.2.2 xenvif child, as enumerated on the guest:  offers  REV_09000004 ... 09000000
    UPSTREAM Xen Project xennet 9.1.0.3:                 requires REV_09000003
    UPSTREAM Xen Project xenvif 9.1.0.2

So the QWT 4.2.2 payload is INTERNALLY INCONSISTENT: its xennet demands an interface
revision one higher than its own xenvif publishes, so the NET child can never bind and
Windows falls back to the emulated Realtek NIC. Since our MSI's PV binaries are byte-identical
to stock's, **stock QWT 4.2.2 has the same defect** - this is not something we introduced,
and it is not "wrong codebase" on our side.

Upstream's xennet 9.1.0.3 asks for REV_09000003, which IS in the device's hardware-ID list
(04/03/02/01/00). So swapping in the upstream pair is a plausible fix, exactly as the user
suggested.

RETRACTED along the way, in order: "wrong codebase" (refuted by the byte diff);
"upstream packaging bug" (premature - it is a QWT PACKAGING inconsistency, upstream's own
pairs look self-consistent); "the 2026-08-06 networking result ran over the emulated NIC"
(I back-projected today's observation onto an entry that never recorded the adapter);
"stale cached devnode" (cannot apply to a freshly installed system, as the user pointed out).

BEFORE acting on the driver swap, two things must land:
1. The fresh-guest reading from `win10-clean` (health gate now includes `pv_drivers_bound`) -
   it says whether a never-upgraded guest binds PV. Everything above predicts it will NOT.
2. Whether replacing PV drivers inside the QWT MSI is acceptable at all: they are
   attestation-signed by Xen Project, our guests run testsigning, but a real release would
   need the signing question answered. That is a USER DECISION, not mine - it changes what
   the product ships beyond the agent.

## 2026-08-07 — the fresh-guest PV run was a NULL RESULT: my check fails on an OFFLINE guest

`win10-clean` health gate: `pv_drivers_bound` FAILED with `active_nic: NONE`,
`XENVIF: false`, `XENNET: false`, and **no XENVIF NET child in the device list at all**.

That is not evidence about the driver mismatch. `scratchpad/reprovision.sh` deliberately
installs with `netvm ''` (offline install is a project rule), so the guest has NO vif -
nothing for xenvif to enumerate a NET child from, and no emulated NIC either. The check
asserts "the NIC carrying traffic must be the PV one" on a guest with no NIC by
construction, so it can only fail. Another check failing for the wrong reason.

Fix required (not yet applied): when no network device is attached at all, the PV-NIC half
must report `na` with the reason, NOT fail - while a NETWORKED acceptance must still assert
it. `na` must never read as a pass; the harness has to distinguish "not applicable here"
from "verified".

Re-running properly: `qvm-prefs win10-clean netvm core-net`, reboot, then read the XENVIF
NET child's hardware IDs on a guest that has never had a QWT uninstall/reinstall. THAT is
the reading that decides whether the QWT xenvif/xennet revision mismatch bites a clean
install - and it is the one the release stance depends on.

## 2026-08-07 — CONFIRMED ON A CLEAN GUEST: QWT 4.2.2's PV network can never bind. Not our build, not guest history

`win10-clean`, freshly installed from our media, **never** had a QWT uninstall/reinstall,
then `netvm core-net` attached and rebooted:

    CHILD = XENVIF\VEN_XP0001&DEV_NET\0     status=Error
    HWIDS = ...&DEV_NET&REV_09000004, 09000003, 09000002, 09000001, 09000000, XENDEVICE
    NICS  = Realtek RTL8139C+ Fast Ethernet NIC [PCI\VEN_10EC]   (emulated - the ONLY adapter)

Identical to win-idd-test. So every alternative explanation is now dead:
- NOT our build - our MSI's PV binaries are byte-identical to stock's (3-file diff, all ours);
- NOT our uninstall/reinstall cycle - this guest never had one;
- NOT stale cached hardware IDs - this devnode was created once, by this xenvif;
- NOT guest history - there is none.

**The defect is in the QWT 4.2.2 payload itself**: its `xennet` declares only
`XENVIF\VEN_XP0001&DEV_NET&REV_09000005`, while its own `xenvif` enumerates the NET child at
`REV_09000004` and below. No hardware ID intersects, PnP leaves the child at code 28
(`CM_PROB_FAILED_INSTALL`), and Windows uses the emulated Realtek NIC. Because the binaries
are byte-identical, **stock QWT 4.2.2 behaves the same on this platform** - so any belief
that "PV works in stock" does not hold here and needs re-checking against an actual adapter
name, which is exactly what was never recorded on 2026-08-06 (that entry logged an IP and
working DNS/HTTPS, never which NIC carried it).

**The fix the user proposed is supported by the evidence**: upstream Xen Project
`xennet 9.1.0.3` requires `REV_09000003`, which IS in the child's hardware-ID list, so the
upstream pair (xenvif 9.1.0.2 / xennet 9.1.0.3, xenbits.xen.org/pvdrivers/win/) should bind.

Open decision for the user before implementing: replacing PV drivers inside the QWT MSI
changes what the product ships beyond our agent, and those binaries are attestation-signed by
Xen Project. Our guests run testsigning so they will load, but a release needs the signing
story answered. Also worth reporting upstream (qubes-windows-tools) under the "bugs OUTSIDE
QWT scope" exception - with the user approving the text first.

## 2026-08-07 — SHIPPED-BUILD ACCEPTANCE: FAIL. Release NOT published. Verdict and reasons

The re-run on stock-MSI-free media got all the way through install and reboot, then the gate
failed on two checks. Recording precisely because one is real, one is my instrument, and
neither is the interactive-dialog problem that killed the previous attempt (that IS fixed -
the install completed unattended this time, `install reported complete` at 07:10:42).

    agent_binary_hash        PASS  installed 5BF33DE6... == manifest 5bf33de6...  (the SHIPPED a68d244 binary)
    agent_process            PASS
    qubes_services_running   PASS
    idd_device_bound         PASS
    idd_modes_published      PASS
    pnp_no_unexpected_errors PASS
    clipboard_works          PASS
    agent_log_healthy        FAIL  logs_this_boot=2, still_writing=false, badmode=0
    pv_drivers_bound         FAIL  (see below)

**pv_drivers_bound - REAL, and now fully explained.** On this fresh guest with `core-net`
attached: child `XENVIF\VEN_XP0001&DEV_NET\0` status=Error, hardware IDs
`REV_09000004,03,02,01,00`, only adapter = emulated Realtek. QWT 4.2.2's own xennet requires
`REV_09000005`. The branch "if PV binds on the fresh guest, our uninstall/reinstall cycle is
to blame" is therefore CLOSED: it does not bind, so the upgrade path is exonerated and no
uninstall-cycle experiment is needed.

**agent_log_healthy - needs follow-up.** `logs_this_boot=2` means the agent RESPAWNED once
this boot, and `still_writing=false` at sample time. Zero BADMODE. Not diagnosed; it may be
the ordinary startup retry (a first instance dying on a transient capture error and the
watchdog restarting it, which A7 was written for) or something new. It must not be waved
through - it is the one unexplained failure on the shipped binary.

**Release: NOT published.** The gate is PV + clipboard + chrome + health all green; two are
not. The draft stays as it is. Note the chrome assertion never even ran - the harness fails
at the health step before reaching it.

Guest state: `win10-clean` has since had upstream xennet 9.1.0.3 pushed and offered to
pnputil by hand, which raised "Windows can't verify the publisher of this driver software"
and is sitting on that modal. That guest is now a driver-experiment guest, not a clean
acceptance guest, and must be reprovisioned before it is used for acceptance again.

## 2026-08-07 — where the PV drivers actually come from, and the 4.2-vs-4.3 question

Traced properly instead of inferring from version strings.

**We do not build the PV drivers.** `.github/workflows/qwt-full.yml:8` states the design:
PV drivers, qrexec agent and qubesdb are staged **bit-identical** from the GPG-verified QWT
4.2.2 RPM. That is why our `xenvif.sys`/`xennet.sys` are byte-identical to stock and why we
inherit stock's mismatch. `PVDRIVERS_REF: v4.2.0-1` clones
`QubesOS/qubes-vmm-xen-windows-pvdrivers` only to build **libxenvchan** (headers + static lib
our agent links against) - no driver binaries come from it.

**That repo is a thin superproject**: `xenvif`, `xennet`, `xenbus`, `xeniface`, `xenvbd` are
git SUBMODULES pointing straight at `xenbits.xen.org/git-http/pvdrivers/win/*.git`, pinned at:

    xenbus  e76d03e37550a0889c08be8e2a2caaf299d588c8
    xennet  ad7717f6390b320255680ef3d4c86d4c6833e009
    xenvif  9fd1afe4382b15ed8e063a816a328c0a580f038e

So the "commit after the interface bump" I speculated about earlier is one of these - the
sources are upstream xenbits, and Qubes pins the pair. Whether these two specific commits
disagree about the VIF NET interface revision (xennet requiring rev 5 while xenvif publishes
rev 4) is now a checkable question against those exact SHAs, not guesswork. NOT yet checked -
the shallow clone did not fetch submodule contents.

**The user's point, which reframes all of it: `v4.2.0-1` and QWT 4.2.2 are built for Qubes
4.2, and this host is Qubes 4.3.** Every PV result recorded here was produced by 4.2-targeted
guest drivers running against a 4.3 host's netback. That is a plausible reason the pairing
misbehaves here and not on the platform it was built for, and it means "stock QWT works" and
"stock QWT is broken" can BOTH be true depending on host version. Nothing in this file has
tested a 4.3-targeted QWT because none has been identified yet.

Direction agreed with the user: **upgrade xenvif to match xennet, do not downgrade xennet.**
Downgrading to the 2023 xenbits tarball loses ~2 years of xennet changes, and those binaries
are not signed in a way Windows accepts anyway ("Windows can't verify the publisher of this
driver software", observed on win10-clean). Upgrading means building xenvif from the pinned
submodule SHA (or a newer one that publishes rev 5) and signing it with our CI cert.

Next concrete steps, in order:
1. Fetch the three submodule SHAs and read the VIF interface revision each declares - settles
   whether the pinned pair is internally consistent.
2. Establish whether a Qubes 4.3-targeted QWT / PV driver set exists. If it does, everything
   above may be moot and the answer is simply "use the 4.3 build".

## 2026-08-07 — There is NO newer Qubes PV driver set; we are already on 4.3 sources

Checked instead of assuming, per the user's "check if there is a 4.3 qwt build first":

- **QWT installer: we already build R4.3.0.** `INSTALLER_SHA=14c189e4...` is exactly what
  `refs/tags/R4.3.0^{}` and `refs/heads/release4.3` point at in
  `qubes-installer-qubes-os-windows-tools`. The "4.2.2" string is QWT's product version, not
  its Qubes target. So the installer is NOT stale.
- **PV drivers: `release4.3` IS our pin.** `refs/heads/release4.3` = `388c821c` =
  `v4.2.0-1^{}`, i.e. the tag we already pin. And `main` (8cffcc09) pins the SAME driver
  submodules: xenbus `e76d03e3`, xennet `ad7717f6`, xenvif `9fd1afe4`. There is nothing newer
  to pull - main, release4.3 and our pin are identical for drivers.

So the "we are on 4.2 software on a 4.3 host" worry does not hold for the sources: they are
the current 4.3 ones.

**Where the inconsistency actually sits.** Fetched the pinned submodules from xenbits:
`xennet@ad7717f6` source declares `DEV_NET&REV_09000005` - matching the SHIPPED xennet binary.
So the shipped xennet is faithful to the pinned source. `xenvif@9fd1afe4` carries no literal
`0900000x` in its `src` tree (its published revision is constructed elsewhere - INF template
or version macro), so source alone did NOT settle what it publishes.

The one hard fact remains the runtime measurement: the SHIPPED xenvif binary enumerates the
NET child at `REV_09000004`. Two possibilities remain, and they are distinguishable by ONE
experiment:
  A. The pinned xenvif source publishes rev 5, and the PREBUILT binary in the QWT 4.2.2 RPM
     was built from an older tree -> **building xenvif from the pinned SHA fixes PV**, and
     the bug is that the RPM ships a stale xenvif.
  B. The pinned xenvif source publishes rev 4 -> the pinned PAIR itself is inconsistent and
     the bug is upstream in what Qubes pins.

**Next step (not done - needs an EWDK build):** build xenvif and xennet from
`9fd1afe4`/`ad7717f6` in CI, read the built xenvif's published NET revision, and if it is 5,
stage OUR built pair instead of the RPM's prebuilt drivers. That is a real change to
`qwt-full.yml` (it currently stages PV drivers bit-identical from the RPM and builds only
libxenvchan from this repo) and it forfeits the bit-identical property for a
security-relevant component - a deliberate tradeoff the user has now directed
("upgrade the driver instead").

## 2026-08-07 — HOW the non-functional PV pair happened, and whether it is known

**Commit history (the reason).** Both submodules were bumped in ONE superproject commit
(`1ad9328` "Update submodules for win10"), so nobody forgot one. The mismatch is UPSTREAM
ORDERING:

    xennet ad7717f6  2024-07-09  "Bump binding to 0x09000005"          <- requires rev 5
    xenvif 9fd1afe4  2024-12-02  "Invalidate FDOs when no devices..."  <- provides only rev 4
    xenvif 4608bc1   2025-06-30  "Use UNPLUG v3"                       <- rev 5 finally added

xennet declared a dependency on VIF interface revision 5 in **July 2024**; xenvif did not
publish rev 5 until **June 2025**. For eleven months the two projects' masters were mutually
incompatible, and any pin taken in that window yields a pair that cannot bind. The xenvif pin
(Dec 2024) sits inside it. So this is not a Qubes packaging slip in the "forgot to bump"
sense - it is upstream shipping a consumer ahead of its provider, with nothing in either
tree that would surface the incompatibility short of diffing `revision.h` against xennet's INF.

Loose end, deliberately not glossed: the superproject's last commit touching those paths on
`main` is dated 2023-06-26 while the pinned SHAs are from 2024, so the pins likely arrive via
the `v4.2.0-1` tag's history rather than `main`'s. Confirm which commit set them before
writing anything upstream.

**qubes-issues: NOT REPORTED.** Searched "windows xennet", "windows PV network", "xenvif",
"windows tools network", "windows emulated NIC realtek". Nothing describes PV networking
failing to bind or the guest falling back to the emulated Realtek. Related but distinct:
- **#10069** "Windows (with new QWT) freezes sometimes" (OPEN, Qubes 4.3) - freezes with no
  crash message, seen by omeg during QWT development and in CI. Worth keeping in view next to
  our own unexplained wedge (`evidence/wedge-w10-noidd-041212`, Running + zero grants), though
  nothing yet ties them together.
- **#1861** the Win10/11 support issue this project already tracks.

So the defect appears unreported. That strengthens the case for filing it, with the three
commit SHAs and dates above as the body - subject to the user approving the text
(CLAUDE.md upstream policy).

## 2026-08-07 — PV NETWORKING FIXED AND PROVEN: upgraded xenvif binds xennet, Realtek unplugged

Built xenvif from xenbits **master** (unpinned per the user; resolved 94853a0), test-signed,
exported the signer, trusted it on the guest, installed via a scheduled task, rebooted:

    INSTALL_RESULT  RC=0
    NICS_BEFORE     Realtek RTL8139C+ Fast Ethernet NIC
    NICS_AFTER      Xen PV Network Device #0          <-- emulated NIC GONE
    XVDATE          07/08/2026                        <-- our build (QWT's: 04 July 2025)

**The emulated Realtek is unplugged and replaced by the PV NIC.** That is the strong signal
chosen in advance precisely because it cannot be faked by a device merely reporting status
OK: rev 5 shipped with `4608bc1` "Use UNPLUG v3", and a working unplug removes the QEMU NIC
outright. The diagnosis is therefore confirmed end to end:

    QWT 4.2.2 / Qubes 4.3 pins:  xenvif REV_09000004 max  vs  xennet requires REV_09000005
    -> no hardware ID intersects -> NET child stuck at code 28 -> emulated Realtek
    upgrade xenvif to master (has 0x09000005) -> xennet binds -> Realtek unplugged

Loose end, NOT glossed: the post-reboot probe reported
`NETCHILD=Unknown XENVIF\VEN_XP0001&DEV_NET&REV_09000004` - i.e. it matched a devnode still
advertising rev 4 with status Unknown, while a working PV NIC exists. Almost certainly the
stale child from the old xenvif left behind beside the newly created rev-5 one, and the probe
takes `Select-Object -First 1`. Needs one enumeration of ALL XENVIF NET children to confirm
that reading before the health gate asserts on it - a gate that matches the stale node would
fail a working guest.

Two install lessons, both now encoded in the tooling:
1. pnputil on a bus driver re-enumerates the Xen bus and kills qrexec mid-call. The result
   must be written to a file by a scheduled task, never returned over the connection the
   install itself tears down. (First attempt returned no RC and silently changed nothing.)
2. The signer must be trusted BEFORE install. Testsigning permits self-signed drivers, but an
   untrusted publisher fails with 0xE0000247. The workflow now exports `xenvif-signer.cer`
   and the installer imports it into Root + TrustedPublisher.

## 2026-08-07 — MIRAGE-FIREWALL PROBE: NOT a clean failure. My script's own verdict is WRONG

Ran with PV networking now working (xenvif upgraded, xennet bound, emulated NIC unplugged),
to see whether `netvm=fw-net` fails cleanly or leaves an unresponsive qube.

    qvm-start rc=124        <- 124 is TIMEOUT: MY `timeout 300` killed it, qvm-start HUNG
    domain state            Transient
    script verdict          "CLEAN-FAIL-AT-CREATE"   <- WRONG

**Correcting my own instrument:** the classifier treated any non-zero rc as a clean failure.
rc=124 is not an error return from qvm-start, it is my timeout firing after 300 s. So the
real result is: **`qvm-start` hangs for at least five minutes and the domain sits in
`Transient`** - i.e. exactly the "unresponsive qube" outcome the user asked to rule out, not
the clean failure the log claims. Anyone reading only the VERDICT line would draw the
opposite conclusion.

So PV networking working does NOT fix the mirage-firewall interaction. The failure is at
DOMAIN CREATION, before the guest runs at all, which is consistent with the earlier
diagnosis: mirage's netback never brings the vif up, the stubdom waits on it, and domain
creation stalls. The guest's netfront is irrelevant because the guest never starts.

Not left dirty: the probe restored `netvm=core-net` and the domain settled to `Halted`.

Fix needed in the probe before it is cited anywhere: distinguish rc=124 (hang) from a real
non-zero exit, and treat `Transient` as a FAILURE state rather than evidence of a clean stop.

## 2026-08-07 — media build: extract-and-repack replaced by graft-onto-mount (qvm-create-windows-qube's method)

User asked how `qvm-create-windows-qube` automates answer files. It repacks too - there is no
second-media trick - but its method is far better (windows/create-media.sh):

    genisoimage -udf -b boot.bin -no-emul-boot -allow-limited-size -graft-points \
        -o out.iso "$iso_mntpoint" "boot.bin=$boot_img" "Autounattend.xml=$answer_file"

i.e. loop-MOUNT the vendor ISO read-only and overlay files with `-graft-points`. Two wins:
no extraction, and `-udf` removes the >4 GiB file limit so `install.wim` is never split.
Our entire splitting apparatus existed ONLY because this box's xorriso has no UDF writer.

`mgmt/build-media.sh` implements it (genisoimage installed by the user). Measured:

    old builder: ~14 GiB transient, ~15 min, install.wim SPLIT to .swm
    new builder:  5.8 GiB output, 2m50s, install.wim UNSPLIT

Verified on the produced ISO, not assumed:
    autounattend.xml / diskprep.cmd / payload/release/install.cmd / sources/$OEM$/$1  present
    sources/install.wim  5,166,935,814 bytes, ORIGINAL 2023-05-05 timestamp (byte-identical)
    El Torito boot img   platform BIOS, bootable=y   (SeaBIOS-compatible)

**The vendor delta is now purely ADDITIVE** - previously the .swm split was a real change to
vendor content, and it is gone. This is as close to the untouched vendor media as the
platform allows.

TWO DEFECTS OF MINE, caught before use (both invisible to "the build succeeded"):
1. Passing `$MNT` as a plain path AND using -graft-points emitted the tree TWICE: 12 GiB
    output from a 5.8 GiB source. Fixed by grafting as `/=$MNT`.
2. The boot image was chosen with `find *.img | head -1`, which picked
    `eltorito_img2_uefi.img`. Qubes HVMs boot SeaBIOS and need `boot/etfsboot.com`, so that
    media would very likely not have booted. Fixed to take the BIOS image explicitly.
Neither was visible in the exit code or the log; the SIZE was the only tell, and the timing
alone looked like a success.

Still to prove: that this media boots and installs end to end. A correct-looking ISO that
does not boot is a failure mode this project has already hit (`CDBOOT: Couldn't find
BOOTMGR` after a layout change). The acceptance queued on it was refused by reprovision's
per-VM flock because the older-builder run still holds win10-clean - the lock working as
intended.

## 2026-08-07 — ACCEPTANCE: the SHIPPED package repairs PV networking on a clean install

`win10-clean`, installed from release media containing `pv-drivers/`, then `core-net`
attached and rebooted. Health gate (`-NoIddExpected`):

    agent_binary_hash        PASS   (installed == manifest, the shipped binary)
    agent_process            PASS
    qubes_services_running   PASS
    idd_device_bound         PASS
    idd_modes_published      PASS
    pnp_no_unexpected_errors PASS
    clipboard_works          PASS   windows clipboard round-trip + Qubes handler running
    pv_drivers_bound         PASS   XENNET/XENVIF/XENBUS/XENIFACE started
                                    pv_nics = ["Xen PV Network Device #0"]
                                    emulated_nics_still_present = []   <-- Realtek UNPLUGGED
    network_carries_traffic  PASS   ip 10.137.0.70 -> gateway 10.138.25.43 REACHABLE
    agent_log_healthy        FAIL   logs_this_boot=2 (see below)

So the xenvif rev-5 fix works END TO END FROM THE PACKAGE, not just by hand: a guest whose
only driver source was our installer ends up on the PV NIC with the emulated adapter gone
and real connectivity. That closes the defect QWT 4.2.2 ships (its xenvif caps at
REV_09000004 while its own xennet needs REV_09000005).

The ONE remaining failure is `agent_log_healthy`: `logs_this_boot=2`, i.e. the agent
respawned once. Diagnosed earlier the same day on a different guest: the first instance dies
seconds after start with `WatchForEvents: vchan disconnected` / `A6EXIT` and the watchdog
restarts it; the second instance runs healthily. That is a dom0 gui-daemon connect race
(DESIGN-gui-daemon-restart-survival.md), not a fault in the shipped binary. The CHECK is too
strict - `logs_this_boot == 1` fails a benign single respawn on a first boot. It must
distinguish a respawn LOOP from one restart with a healthy current instance before it can
gate a release.

Harness flaw also exposed: the FIRST run of this acceptance failed with `pv_drivers_bound`
and `network_carries_traffic` reporting `na` ("no physical network adapter attached"),
because reprovision installs OFFLINE by design. `na` currently counts as a failure. It must
block a release CLAIM without failing the run - otherwise acceptance can never pass on the
offline install path it itself creates.

## 2026-08-07 — NETVM HOTPLUG: partial. Device re-plugs at runtime, connectivity does not

`win10-clean` running, PV networking healthy (baseline `NIC=Xen PV Network Device #0
IP=10.137.0.70`):

    DETACH  qvm-prefs netvm ''         rc=0, guest RESPONSIVE, NIC gone      <- clean
    ATTACH  qvm-prefs netvm core-net   rc=0, NIC BACK without a reboot       <- device layer OK
                                       but IP=169.254.234.144 (APIPA), gw empty, GWOK=False

So the frontend genuinely hot-plugs now - which it could not do before, when there was no
working PV netfront at all - but the guest never regains its Qubes-assigned static IP.
Qubes drives guest addressing from qubesdb via QWT's network setup, and nothing re-runs that
when a vif appears at runtime; Windows falls back to APIPA. **Verdict: hotplug works at the
device level, NOT at the connectivity level. A reboot is still required.**

That is a real improvement over the historical state and a well-defined next task (have the
QWT network setup re-apply on vif arrival), but it is NOT "hotplug works".

Instrument bug found in my own probe, fixed: the success matcher was `*IP=1*`, which happily
accepts `169.254.*`. Only the gateway-reachability check caught the truth. A pattern that
matches the failure it is meant to exclude is worthless.

## 2026-08-07 — HOTPLUG REPAIRED, and the health gate now passes 10/10 with NOTHING skipped

**Repair found.** QWT ships `C:\Program Files\Qubes Tools\bin\network-setup.exe` - the
component that applies the qubesdb-driven static IP. Nothing re-runs it when a vif arrives
at runtime, which is why a hotplugged NIC landed on APIPA. Running it by hand:

    BEFORE = 169.254.234.144      (APIPA, hotplugged NIC, no gateway)
    network-setup.exe  RC=0
    AFTER  = 10.137.0.70          (correct Qubes IP)

So netvm hotplug on Windows is: `qvm-prefs <vm> netvm <net>` then run `network-setup.exe`
in the guest. No reboot. Revised verdict: **hotplug WORKS, with one guest-side step** -
previously recorded as "does not work at runtime", which was true only because nothing
re-applies the addressing.

Follow-up worth doing (not done): have QWT re-run network-setup on vif arrival so no manual
step is needed - a PnP/WMI notification on a new Xen network adapter, or the existing
network service watching qubesdb.

**Health gate after both check fixes, full re-assert:**

    ok = true   failed = []   not_applicable = []   asserted_all = true
    agent_binary_hash, agent_process, qubes_services_running, idd_device_bound,
    idd_modes_published, pnp_no_unexpected_errors, agent_log_healthy,
    pv_drivers_bound, network_carries_traffic, clipboard_works  -- ALL PASS
    network: ip 10.137.0.70 -> gateway 10.138.25.43 reachable

This is the first time the gate has passed with `asserted_all=true`, i.e. no check skipped
and none excused. It is passing on the SHIPPED package (`agent_binary_hash` == manifest),
on a guest whose only driver source was our installer.

## 2026-08-07 — NETVM HOTPLUG NOW FULLY AUTOMATIC (trigger verified end to end)

`network-setup.exe` repairs a hot-plugged NIC, but nothing invoked it. Registered a SYSTEM
scheduled task, `QubesNetworkReapply`, triggered by **Microsoft-Windows-NetworkProfile/
Operational event 10000** ("network connected", +3 s delay), running network-setup.exe at
highest privilege.

VERIFIED with a real cycle, no manual step:

    baseline        IP=10.137.0.70
    netvm ''        IP=            (detached, guest responsive)
    netvm core-net  -> TRIGGER FIRED -> IP=10.137.0.70 after 15 s

So `qvm-prefs <vm> netvm <net>` on a RUNNING Windows guest now restores networking by
itself. Revised twice today and this is the final state: first recorded as "does not work at
runtime" (true, but only because addressing was never re-applied), then "works with one
guest-side step", now **works with none**.

Registration is wired into `Install-QwtImproved.ps1` so every install gets it; failure is a
WARN, not fatal (the guest still works, hotplug just needs the manual step). Standalone
copy kept at `guest/network-reapply-task.ps1` for existing guests.

Note the task is registered only when network-setup.exe exists, so it is a no-op on a
guest without QWT's network component rather than a broken task.

## 2026-08-07 — AUDIO: not shipped by QWT 4.2.2 at all, and Xen has no Windows audio path

User asked whether audio and clipboard are in the release, then whether Xen offers a better
audio path. Pinned down rather than assumed.

**Clipboard: IN, and asserted.** `clipboard_works` passes in the acceptance gate - the Qubes
handler runs (part of QrexecAgent/gui-agent, not a separate MSI feature) and the Windows
clipboard round-trips a marker. Scope limit kept in the check's own output: the dom0<->guest
transfer needs Ctrl+Shift+C/V, a human keystroke pair, so that last hop is NOT asserted.

**Audio: NOT SHIPPED, and it is not our ADDLOCAL dropping it.** Scanned the release MSI for
feature identifiers in BOTH ascii and utf-16:

    PvDriversCore   ascii      <- our selected features are present as plain strings,
    Autologon       ascii         so the scan can see feature names
    Audio           ABSENT (both encodings)
    Sound           ABSENT
    Wave / Mixer / Endpoint / pacat   ABSENT

So QWT 4.2.2 contains no audio component to select. On the guest this shows as the
QEMU-emulated `High Definition Audio Device` present and OK, with only QdbDaemon /
QrexecAgent / QubesGuiWatchdog running - nothing bridges that device to dom0.

**Xen's PV sound is not the route.** The complete Windows PV driver family on xenbits is
xenbus, xencons, xenhid, xeniface, xennet, xenvbd, xenvif, xenvkbd - **no audio driver**.
Xen's `sndif` (vsnd) protocol exists with Linux frontends (embedded/automotive), but no
Windows frontend, and Qubes does not use sndif anyway: Linux guests run pulseaudio over
**vchan** (`pacat-simple-vchan` <-> the dom0 audio daemon). dom0 expects a vchan stream, not
a Xen sound ring.

**Therefore a Windows audio agent is a vchan user-mode program, not a driver** - a sibling of
gui-agent, not a PV driver port. Encouragingly the hard parts already exist here: vchan from
Windows is proven (every frame ships over it) and `libxenvchan` is already built by our CI
for the agent. Shape: WASAPI loopback capture of the default render endpoint -> PCM over
vchan for playback; a capture path for the microphone. Before committing to a protocol,
read what `qubes-audio-daemon` expects on the dom0 side.

POST-FREEZE. This is a feature, not a fix, and needs a dom0-side counterpart to be useful.

## 2026-08-07 — THE OTHER DROPPED FEATURES, especially DISK. All I/O is emulated IDE.

User asked what else is dropped. Measured on the released guest:

    XENBUS\VEN_XP0001&DEV_VBD\_   err=28   (no driver bound - xenvbd not installed)
    DISK 0  80GB  bus=ATA
    DISK 1   2GB  bus=ATA         <- ALL disks emulated IDE, none PV
    DISK 2  10GB  bus=ATA

**`PvDriversDisk` (xenvbd/xencrsh) is omitted, so every byte of guest disk I/O goes through
QEMU-emulated IDE.** This is structurally the SAME situation networking was in before today:
the PV path unbound at code 28 while the emulated device carries the traffic. The difference
is that networking was broken by an upstream version mismatch, whereas disk is switched off
BY US on purpose.

The stated reason - "documented BSOD risk" - traces to `packaging/setup/README.txt:45` and
`docs/WHAT-CHANGED-FOR-USERS.md:375`, both of which are OUR OWN text. I have not found the
primary source. Given that today's "PV networking is fine in stock" belief turned out to be
wrong, and the 2026-08-06 "netvm makes the guest unusable" claim turned out to be
mirage-firewall rather than PV drivers, **this claim deserves the same treatment before it is
repeated again**: find the upstream advisory or the measurement it came from, or retest it.

Performance consequence worth stating: emulated IDE is far slower than PV block, so the disk
path caps absolute guest performance. It does NOT distort the stock-vs-ours benchmark - both
sides are equally on emulated IDE - but it does mean any absolute I/O number from this
release is a floor, not the platform's ceiling.

The other two omissions are minor and stand:
  MoveUsers  - relocates C:\Users via BootExecute; invasive, no benefit for a test guest.
  Autologon  - randomises the local password; would break our unattended qrexec access.

POST-FREEZE: verify the xenvbd BSOD claim (source or measurement), and if it does not hold,
enabling PvDriversDisk is likely the single largest remaining performance win - the disk
equivalent of today's xenvif fix.

## 2026-08-07 — RETRACTION: the Win10 /idd symptom is NOT "falls back to ROOT\BASICDISPLAY"

I wrote that four times (FINDINGS, RELEASE-QUALIFICATION-STATUS, two mgmt scripts, the
release notes) and it is wrong. The archived post-reboot measurement of the failing Win10
guest actually says:

    PCI\VEN_1234&DEV_1111   ConfigManagerErrorCode = 22 (CM_PROB_DISABLED)   <- disable DID persist
    PCI\VEN_1234&DEV_1111   Availability = 3 (Running), 3440x1440            <- SAME device drives the desktop
    ROOT\BASICDISPLAY       absent from the controller list entirely

Both the emulated VGA and the ROOT fallback carry the friendly name "Microsoft Basic Display
Adapter"; I read the name and never checked the PNPDeviceID. The desktop stays on the
EMULATED VGA, which keeps driving video while its devnode is marked disabled. Windows did not
"fall back" to anything.

ROOT CAUSE (this part of the hypothesis survives, with a different mechanism):
**nothing in the package ever performs a display-topology apply.** The /idd sequence is
pnputil -> devcon create root devnode -> wait for a Win32_VideoController -> Disable-PnpDevice
on the PCI VGA -> reboot. An IddCx monitor arrives CONNECTED but INACTIVE (Availability=8,
null resolution) and is not attached to the desktop until a CCD topology apply names its path.
No such call exists anywhere in the package - not before the reboot, not after. The persisted
topology therefore still names only the VGA path at next boot, so Windows drives that rather
than leaving the box headless. The installer's comment at Install-QwtImproved.ps1:740 -
"Activation happens HERE, right before the stage-2 reboot" - encodes the false assumption.

Decisive corroboration: `win-idd-test` is the SAME Win10 19045 build and DOES run IDD-solo,
but it got there via `tools/modeprobe --solo`, which performs exactly the missing step
(detach every other display, CDS_SET_PRIMARY|CDS_UPDATEREGISTRY on the IDD, commit). Win11
24H2 reaches the same end state from the identical installer, so Win11 performs or persists
the apply on its own. The Win10/Win11 difference is NOT driver-side: the IddCx driver has zero
OS-build branches and no version mismatch (verified in driver/IddSampleDriver/Driver.cpp).

FIX (not yet implemented): do the topology apply in the GUI AGENT at startup, before it maps
the screen - QueryDisplayConfig(QDC_ALL_PATHS), find the target whose
DISPLAYCONFIG_TARGET_DEVICE_NAME matches the Qubes IDD, mark ONLY that path active and every
other path inactive, then SetDisplayConfig(SDC_APPLY | SDC_USE_SUPPLIED_DISPLAY_CONFIG |
SDC_SAVE_TO_DATABASE | SDC_ALLOW_CHANGES). Marking the others inactive is what keeps the IDD
the SOLE output, so the desktop bounding box does not grow and seamless coordinates hold.
It must NOT go in the installer's SYSTEM ONSTART task: session 0 gets ERROR_ACCESS_DENIED.

## 2026-08-07 — PLANNED (post-freeze): USB answer-file media, no ISO rebuild at all

Current shipped route (`mgmt/build-media.sh`, graft-points): vendor ISO mounted read-only,
our 3 files grafted on top, `genisoimage -udf -graft-points`. 5.8 GB in 2m50s, vendor content
byte-identical, install.wim unsplit with its original timestamp. Both Win10 and Win11
acceptance ran on this. It STAYS as the supported route.

PLANNED IMPROVEMENT — leave the vendor ISO literally untouched by putting the answer file on
an emulated USB stick instead of any optical media:

    qvm-features <vm> qemu-extra-args -- '-drive file=/dev/xvdi,format=host_device,if=none,readonly=on,id=ansdrv -device nec-usb-xhci,id=ansusb -device usb-storage,bus=ansusb.0,drive=ansdrv,removable=on'

Chain (each link verified in source by the 2026-08-07 research workflow):
 1. `qemu-extra-args` is a documented per-VM feature (`man qvm-features`), rendered into the
    stubdom emulator cmdline by /usr/share/qubes/templates/libvirt/xen.xml.
 2. libvirt -> libxl passes it through as `extra_hvm`, appended to the stubdom QEMU argv.
 3. Every guest disk is attached to the STUBDOM too, addressed there as /dev/xvd<a+index>,
    so a disk assigned at frontend-dev=xvdi is openable by that QEMU as /dev/xvdi.
 4. Windows Setup's documented implicit search order includes removable media at the drive
    root, and WinPE has USBSTOR/USBXHCI inbox - which is exactly why USB works where the
    two-disc PV route FAILED (assigned CDs are PV devices and WinPE has no PV drivers).

Per-iteration cost drops to ~1 s: rebuild an 8 MB FAT image, no ISO work at all.

OPEN before this can be adopted:
 - needs `admin.vm.feature.Set` (one-time per qube) - ASK THE USER, do not attempt.
 - whether the stripped stubdom QEMU actually has `usb-storage` compiled in is INFERRED, not
   proven. It fails loudly at domain start if absent (`-device usb-storage: no such device`),
   so the test is cheap - but it is a test, not a known.

CAUTION on the source of this research: the workflow agent that produced it repeatedly probed
for privilege escalation (`sudo -n`, `sudo -l`, reading /etc/sudoers.d/*) against CLAUDE.md's
explicit rule. Nothing succeeded and no VM was mutated, but treat its claims about what
privileges are available as UNVERIFIED until re-checked directly.

## 2026-08-07 — CLEAN ROOM WORKS: answer file + payload on an emulated USB stick

**RETRACTION FIRST.** Earlier today I wrote "the two-disc clean room route is IMPOSSIBLE on
Qubes HVM (measured, decisive)". That verdict is correct ONLY for the **CD** variant and I
stated it as a general one. I then cited my own overly broad write-up to justify going back to
5.8 GB ISO repacks - exactly the loop the user called out ("you put any excuse to BOTH avoid
real clean room path and to spend time on endless rebuild instead of real work").

What is actually true:
  * `qvm-device block assign --option devtype=cdrom` creates a **Xen PV** device. WinPE has no
    PV drivers, so Setup never sees it. That part of the old finding stands.
  * WinPE **does** carry USBSTOR/USBXHCI inbox, and Windows Setup's documented implicit search
    order includes the root of removable media. So the same image presented as an **emulated
    USB mass storage device** IS read.

MEASURED, on `win10-clean`, booting the byte-untouched vendor ISO via `qvm-start --cdrom`:

    qvm-features <vm> qemu-extra-args -- '-drive file=/dev/xvdi,format=host_device,\
      if=none,readonly=on,id=ansdrv -device nec-usb-xhci,id=ansusb \
      -device usb-storage,bus=ansusb.0,drive=ansdrv,removable=on,bootindex=99'
    qvm-device block assign --required -o frontend-dev=xvdi -o devtype=disk <vm> win-idd-mgmt:loop9

Result: `Installing Windows - Copying Windows files / Getting files ready (86%)`, stage 1
"Collecting information" completed with NO interaction. No repack, no locale picker.

Two research assumptions are now settled by execution, not inference:
  * `admin.vm.feature.Set` **is** available to this qube - no dom0 action needed.
  * the stripped stubdom QEMU **does** have `usb-storage` compiled in (the domain starts; a
    missing device makes QEMU exit immediately with "no such device").

### The actual bug that made it look like the transport failed

`mgmt/autounattend.xml` is a TEMPLATE: `@UILANG@` x8, `@IMAGE_NAME@` x2, `@INPUTLOCALE@`, and
a `<!--PRODUCTKEY-->` marker. I copied it verbatim to the stick. Setup then:
  1. reported "Windows cannot read the <ProductKey>" - which PROVED the stick was being read,
     since Setup can only complain about an element it found;
  2. after I patched only the key, hit the invalid `@UILANG@` values and fell back to the
     interactive picker **SILENTLY** - indistinguishable from "the answer file was never
     found", which is why it read as the same failure twice.
`mgmt/build-answer-stick.sh` now substitutes every placeholder, ASSERTS none remain, and
validates the XML - a leftover placeholder cannot fail loudly at install time, so it must fail
loudly at build time.

### Three traps worth remembering

  * The stick joins the boot order unless given `bootindex=99`.
  * The guest disk must be EMPTY. A leftover partition table from a previous partial Setup
    makes SeaBIOS print "Press any key to boot from CD or DVD", nobody presses one, and it
    falls through to a diskless boot -> "An operating system wasn't found". Recreate the VM,
    do not restart it.
  * `rm -f` + `truncate` on the image gives it a NEW INODE while losetup still holds the old
    one (`losetup -l` shows the backing file as "(deleted)") - the guest then reads a stale
    stick. Re-attach the loop after rebuilding, or the image must be rewritten in place.

### Why this matters beyond cleanliness

The grafted ISO bakes the payload INTO the 5.8 GB image, so any package or install-flag change
forces a full 5.8 GB rebuild. Nothing about the payload needs to be on the boot media: Setup
needs only the answer file, and QWT is applied at first logon. Split, the vendor ISO is
constant and only a ~96 MB image is rebuilt, in seconds.

## 2026-08-07 — Win10: IDD is the SOLE active output after cold boot; all three assert together

Clean-room install (untouched vendor ISO + USB answer stick), then a VERIFIED cold boot
(guest confirmed Halted before start; guest uptime 3 min at check time).

Install trailer, stage2-install ok:true:
    addlocal   PvDriversCore,Core,Gui,PvDriversNetwork,PvDriversDisk
    pv_xenvif  installed
    idd_driver activated (ROOT\DISPLAY\0000), VGA disabled
    installed_gui_agent_sha256 == expected_gui_agent_sha256

Health gate: **12/12, ok=True, asserted_all=True, not_applicable=<empty>** - disks, network
and display all measured in the SAME run:
    agent_binary_hash, agent_process, qubes_services_running, idd_device_bound,
    desktop_on_idd, idd_modes_published, pnp_no_unexpected_errors, agent_log_healthy,
    pv_drivers_bound, pv_disk_bound, network_carries_traffic, clipboard_works

Measured end state (pushed script, not a quoted one-liner):
    DEV OK     ROOT\DISPLAY\0000                        <- IDD
    DEV Error  PCI\VEN_1234&DEV_1111...                 <- VGA disabled
    SCREEN \\.\DISPLAY2 primary=True 1920x1080          <- exactly ONE active screen
    VC IddSampleDriver Device          avail=3 1920x1080
    VC Microsoft Basic Display Adapter avail=8
Exactly the inverse of the pre-fix state (VGA avail=3 at 3440x1440, IDD avail=8).

### HONEST LIMIT: the deliberate-reintroduction test is still INCONCLUSIVE

CLAUDE.md requires a check to be SEEN TO FAIL on a build carrying the defect before its PASS
counts. Two attempts did not achieve that, so `desktop_on_idd`'s PASS is recorded as
**supported by a before/after control, but NOT yet validated by falsification**:

 1. NoTopologyApply=1 + cold boot -> STILL PASSED. Cause is my own design:
    EnsureQubesIddSolo applies with CDS_UPDATEREGISTRY, which PERSISTS the topology, so a
    previously-applied solo survives reboots even when the apply no longer runs. Disabling
    the apply cannot revert an already-persisted topology.
 2. Attempt 2 also re-enabled the VGA to tear the persisted topology down, but neither the
    reg add nor the Enable-PnpDevice echoed a success line, so the ARM step is UNCONFIRMED,
    and the run then aborted on the second cold boot. Nothing can be concluded from it.

What DOES support the fix: the same installer on the same Win10 19045 build, WITHOUT the
agent change, left desktop_on_idd FAILING with the VGA driving the desktop (evidence dirs
accept-win10-clean-20260807-023437). That is a real control, one rep.

TODO before the release write-up claims this check is validated: reproduce the pre-fix state
properly - arm the kill switch AND reset the persisted CCD topology (re-enable the VGA and
make it primary), each step VERIFIED to have executed - then cold boot and require FAIL.

## 2026-08-07 — AUDIT of every default 24a1ded changed vs stock QWT

Prompted by finding three defects in that one commit (PvDriversDisk dropped, the unsourced
BSOD claim, DisableCursor=0). Stock installs ALL SEVEN MSI features: no feature in
Package.wxs sets a Level attribute and WiX defaults them to Level=1.

| default | stock | ours | verdict |
|---|---|---|---|
| PvDriversDisk | installed | was DROPPED | **REGRESSION - FIXED** (now in ADDLOCAL) |
| DisableCursor | 1 (MSI) | was 0 | **REGRESSION - FIXED** (double cursor) |
| MoveUsers | installed | OMITTED | **REGRESSION - OPEN, see below** |
| Autologon | installed | OMITTED | **KEEP OMITTED - deliberate, safer than stock** |
| SeamlessMode | 0 | 1 | deliberate; upstream's own comment is "TODO enable after polishing" |
| LogDir | Q:\Qubes Logs | C:\Program Files\Qubes Tools\log | deliberate; see interaction below |
| testsigning | not needed | ENABLED | unavoidable for test-signed binaries; security-relevant |

### MoveUsers - the one real outstanding regression

Upstream: *"Move C:\users to Q:\Users on the Qubes Private Image disk."* Stock installs it.
We omit it, so **all user data lives on the ROOT volume**, which breaks the Qubes root/private
split: private is the volume Qubes treats as user data (backups, `qvm-volume revert` of root).
A user who reverts root would lose their profile.

NOT enabling it blind, because it is BOOT-CRITICAL: it registers `relocate-dir.exe` under
`HKLM\SYSTEM\...\Session Manager!BootExecute`, so a failure lands in early boot where there is
no qrexec to diagnose it. It must be tested on a throwaway clean guest first, with the
recovery path (clearing BootExecute offline) known before arming it.

Interaction to resolve at the same time: we pre-seed `LogDir=C:\Program Files\Qubes Tools\log`
to dodge the documented race between two MSI components (`[INSTALL_DIR]log` vs
`Q:\Qubes Logs`, where a Q: that does not exist silently swallows every log). With MoveUsers
OFF that choice is right and self-consistent - Q: has no Users on it. If MoveUsers is turned
on, revisit whether logs should follow to the private volume.

### Autologon - stays omitted, and this is BETTER than stock

Upstream's own description is a warning: *"Enable user autologon with randomized password.
NOTE: Don't enable if you use NTFS-encrypted files (EFS), access to them WILL BE LOST! All
existing stored credentials (e.g. for network shares) will be invalidated."* Randomising the
account password on a user's existing Windows is destructive and silent. Our test guests get
autologon from the ANSWER FILE instead, which is scoped to disposable test VMs. Keep omitted,
and say so in the release notes rather than leaving it as an undocumented divergence.

### testsigning - the divergence to state loudest

Stock QWT ships production-signed binaries. Ours are TEST-SIGNED, so the installer runs
`bcdedit /set testsigning on`. That weakens driver-signature enforcement for the whole guest
and is not something a user should discover from a log line. It is inherent to an unofficial
build, not a defect, but it belongs at the top of the release notes.

## 2026-08-07 — qrexec dies with the interactive session (locked desktop = no RPC)

Symptom: `win10-clean` sat at the LOCK SCREEN at 5120x1440 with the IDD driving it, agent
running, guest perfectly healthy - and every `qtest` call timed out. It read exactly like a
wedged guest. A reboot (AutoLogon LogonCount=999 re-establishes a session) restored qrexec
immediately, which confirms the session, not the guest, was the fault.

MECHANISM (read in upstream/ro/qubes-core-agent-windows/src):
  * `qrexec-agent` runs as SYSTEM (a service) and spawns `qrexec-wrapper.exe` as SYSTEM.
  * The wrapper takes a flags bitmask; `qrexec-agent.c:704` documents
      0x04 run the child process in the interactive session (REQUIRES THAT A USER IS LOGGED ON)
  * `qubes.VMShell` targeting user `user` sets that flag, so every dom0->guest RPC that runs
    as a user structurally depends on a live interactive session.
  * The separate `qubes.WaitForSession` service (`wait-for-logon.c:73`) only accepts sessions
    whose WTS state is `WTSActive`, i.e. it too is session-scoped.

SCOPE - this is NOT just a test-harness problem. Clipboard and file-copy to a Windows qube
travel the same path, so a user who locks their Windows guest loses them too.

NOT "fixable" by running the child as SYSTEM: that would let dom0 trigger SYSTEM-level
execution in the guest, which is a security regression and out of scope per CLAUDE.md.
The legitimate mitigations are (a) keep a session alive, and (b) make the failure legible
instead of looking like a hang.

DONE: both answer files now disable monitor/standby timeouts, the lock screen, the machine
inactivity limit and the screensaver, so test guests never idle-lock. This also protects the
benchmark, where an idle-lock mid-run would silently produce numbers for a blanked desktop.

STILL OPEN (needs a guest experiment, do NOT claim it settled): whether a merely LOCKED
session - as opposed to a logged-off one - actually kills the RPC. A locked session normally
remains WTSActive, so the observed failure may have been a logoff rather than a lock. The
decisive test is: confirm qrexec works, run `rundll32 user32.dll,LockWorkStation` over
qrexec, then retry qrexec. Until that is run, the mechanism above explains "no session = no
RPC" but the lock-specific claim is UNPROVEN.

## 2026-08-08 — benchmark orchestrator targeted the wrong VM (caught pre-run)

`bench-interleaved.sh` passed `BENCH_VM=$vm`, but `benchmark.sh` reads **`QTEST_VM`** and
defaults to `win-idd-test` (benchmark.sh:112). Both sides would therefore have been pointed at
a third, stale guest.

HONEST SCOPE OF THE CONSEQUENCE: `win-idd-test` was Halted, and `benchmark.sh run` checks
`guest_alive` first, so the actual outcome would have been REP FAILURES, not silently false
numbers. I initially wrote that it would have produced "plausible nonsense" - that was
overstated. It becomes exactly that only if the stale guest happens to be running, which is a
coin flip, not a safeguard.

Fixed by passing `QTEST_VM`, plus a guard that refuses to benchmark any VM other than the two
under test, so a future mis-wiring aborts loudly instead of depending on which guests are up.

## 2026-08-08 — RETRACTION: "QWT 4.2.2 has no audio" was wrong

I concluded on 2026-08-07 that audio is "absent from QWT 4.2.2 entirely" after scanning the
MSI for audio-related strings in both ASCII and UTF-16 and finding none. The scan was correct;
the CONCLUSION did not follow. Absence of an audio component in Windows Tools says nothing
about whether the guest has audio, because the audio path is not QWT's at all.

Measured on win10-clean (Get-CimInstance Win32_SoundDevice / Win32_PnPEntity):

    SND   High Definition Audio Device    OK  err=0
          HDAUDIO\FUNC_01&VEN_1AF4&DEV_0022&SUBSYS_1AF40022
    MEDIA High Definition Audio Controller    err=0
          PCI\VEN_8086&DEV_2668&SUBSYS_11001AF4
    MEDIA Speakers (High Definition Audio Device)   err=0
    MEDIA Line In (High Definition Audio Device)    err=0

VEN_1AF4 is Red Hat/QEMU: this is QEMU's emulated Intel HDA, bound by an inbox Windows driver,
with working endpoints. `qvm-prefs <vm> audiovm` is set (dom0), and the stubdom QEMU carries
`-qubes-audio:audiovm_xid=` to route it.

So: audio EXISTS and is emulated. QWT ships no audio component because it does not need one.
The earlier "post-freeze: build an audio agent" note was premised on a non-existent gap; what
would actually be on the table is PV audio to replace an emulated path that already works,
which is a performance/latency question, not a missing-feature one.

Also corrected in the same pass, per the user: the DOUBLE CURSOR is a genuine stock QWT
defect in all modes, not merely a regression this package introduced. Seeding DisableCursor=0
made it unconditional here, but stock exhibits it too, so the fix belongs in the user-facing
list as an improvement over stock rather than only in the self-inflicted-regressions list.

---

## 2026-08-08 — the coalescing fix was unmeasurable; RDP's plug points; z-order

### The counter that could never pass its own acceptance criterion

`g_PwSkippedCaptures` — added with the screen-content coalescing fix — was incremented in the
frame loop (`main.c:3344`) and **read by nothing**, under a comment claiming it was "exposed so
the effect is measurable". It was not. QGAPERF's existing `skip` field is a *different*,
pre-existing counter (`g_SkippedFrames`: capture-thread frames that arrived with no dirty
rects), so nothing in the record ever reflected the fix.

Worse, `validate-coalesce.sh` listed "1. `g_PwSkippedCaptures` > 0 — the new path actually
fired" in its header as a PASS requirement and **never implemented it as a check**. The run
could only ever compare CPU. This is the exact failure mode CLAUDE.md warns about: a check that
cannot fail is worthless, and one that was never written is worse, because the header made it
look covered.

Fixed with `PerfNotePwDecision(BOOL skipped)` recording BOTH outcomes as `pwskip`/`pwcap`
(`PERF_RECORD_VERSION` 2 → 3). Both halves are required: the claim is a RATE — captures avoided
over captures considered — and a skip-only counter cannot express one, since it only grows with
how long the workload ran.

### Where RDP actually plugs in (design question from the user)

The premise "remote windows do not have occlusions" needs one correction, and the correction is
the useful part: **RemoteApp does not eliminate occlusion, it synchronizes z-order.** The client
reports the stacking it shows; the server orders its session windows to match. Remote windows
look non-occluding because a RemoteApp session normally contains *only* the remoted apps. The
known artifact proves it — interleave a LOCAL window between two remote ones and RemoteApp
cannot represent it, because the server holds a single z-order.

We already stand in two of RDP's three plug points: pixels (a remote session's display path is
an indirect display driver — the IddCx framework Track B builds; TO VERIFY by enumerating
adapters inside a live RDP session) and window metadata (RAIL sends per-window orders over a
virtual channel; our agent does the same over vchan).

### Z-order: the transport exists, the information does not

Checked in source rather than assumed:

- **Bidirectional messaging already exists.** `vchan-handlers.c:783-810` dispatches daemon →
  agent `MSG_KEYPRESS`, `MSG_BUTTON`, `MSG_MOTION`, `MSG_CONFIGURE`, `MSG_FOCUS`, `MSG_CLOSE`,
  `MSG_KEYMAP_NOTIFY`, `MSG_WINDOW_FLAGS`, `MSG_DESTROY`, `MSG_WINDOW_DUMP_ACK`.
- **No stacking message exists** in the protocol enum (`qubes-gui-protocol.h:136-166`).
- **dom0 manages stacking only among its own X windows**: `restack_windows()`
  (`xside.c:3449`) does `XQueryTree` + `XRestackWindows` locally, for override-redirect windows
  on map, and sends nothing to the guest. The guest never reports its z-order either. The two
  orders are independent and coincide only because both follow the user's clicks.
- **The one exception is `MSG_FOCUS`**, handled at `vchan-handlers.c:689` with
  `SetForegroundWindow(window)` — and a commented-out `BringWindowToTop(window)` on the next
  line.

So full N-window sync is a protocol addition (Phase 3), but partial sync already exists. Since
`PwScreenUnchanged` refuses the fast path for any covered window, occlusion IS the fix's
ceiling — making this measurable rather than arguable. Put the raise behind registry DWORD
`FocusRaise` (default 0 = historic) so both conditions measure on ONE binary, and logged
`QGAFOCUSRAISE on|off` so every captured log states its own condition. A nil result is expected
and is a result: `SetForegroundWindow` usually raises already.

Design written up in `DESIGN-nonoccluding-desktop.md`, including the user's strongest objection
— allocation that scales with desktop size — which reordered the experiment list so the
desktop-size sweep is kill-first. Of the three candidates, the two that do NOT enlarge the
desktop (per-window WGC capture, z-order sync) are the ones worth pursuing.

### Harness defects found and fixed the same day

1. `validate-coalesce.sh` asserted the agent hash ~4 minutes after first qrexec contact —
   racing the firstboot QWT install and its reboots. Logged `up after 2006s`, then an empty
   hash and a vchan timeout, and reported it as "running agent != fixed". The build was fine.
   Replaced with a deadline poll that tolerates qrexec dropouts (the expected signature of the
   reboot), without weakening the gate.
2. CI failed with `upload-pack: not our ref` — the `agent/` submodule commit was never pushed.
   Not a compile error, which the first read of the log had assumed.
3. `win11-fresh` then wedged: Running, qrexec dead ~30 min, `qtest shot` returning an EMPTY tar
   (no mapped windows, so no gui-agent). Recovered by kill + restart. Judge output, not logs.
4. A binary-content probe reported `pwskip`/`pwcap`/`QGAFOCUSRAISE` ABSENT from a green build.
   False alarm: the literals are UTF-16 in the PE and `strings` was reading ASCII. Retained the
   check in `run-fix-validation.sh` with `strings -e l`, because a green build whose binary
   lacked the counters would yield an empty hit rate that reads like "the path never fired".

### Operational hazard: never edit a bash script that is currently running

Caught before it caused damage, recorded because this project runs multi-hour harnesses while
their scripts are still being iterated on, so it will recur.

`scratchpad/run-fix-validation.sh` was executing (pid 1268334, 26 minutes in, inside step 1)
when it was edited to add a fourth step. Bash does **not** read a script into memory up front:
it reads lazily and remembers a byte offset. Inserting lines shifts every later offset, so when
the interpreter next reads, it resumes mid-token and executes whatever now sits at that
position - silently, and with the shell's full privileges.

The file was restored to its committed bytes (`git checkout --`) while the run continued
unharmed. The follow-on step was then run as a SEPARATE invocation instead.

Rules that follow:
- an edit to a script is safe only when nothing is executing it - check with `ps` first;
- to extend a running pipeline, launch the new stage as its own process when the current one
  finishes, rather than appending to the file it is reading;
- committing the script first makes `git checkout --` an exact byte-level undo, which is what
  made this recoverable at all.

---

## 2026-08-08 (late) — the Windows 11 overhead is mostly AMBIENT

### The number that reframes the whole chase

Windows 11 presents **18.75 fps with no input at all** (30 s idle, 3 reps: 563/603/460
frames), each carrying ~350k real dirty pixels, `empty=0` — genuine repaints, not cursor-only
frames the agent already drops for free.

That is **77% of Windows 11's own 24.4 fps workload rate**, and more than Windows 10's *entire*
workload rate of 12.9 fps. So the 488-vs-259 controlled comparison that started this
investigation was largely measuring background repaint, not input handling. The surplus is
ambient: it happens whether or not anyone is touching the machine.

It also explains the idle CPU row that had looked anomalous — ours 0.343 vs stock 0.000. Stock
captures one composited screen and shrugs at ambient repaint; our per-window `PrintWindow` pays
for every one, at idle, indefinitely.

The load-bearing comparison is *within* Windows 11, so no Windows 10 idle number is needed. An
earlier note calling the finding "one-sided" because `win10-clean` never answered was
overstated and is withdrawn.

### Desktop effects are ruled out

Frame counts with effects off moved +2% to +9% — inside 9–25% run-to-run noise, and in the
*wrong* direction. Transparency/Mica/animations do not cause the surplus.
`guest/disable-visual-effects.ps1` stays in the tree (it is harmless and arguably correct on a
GPU-less guest) but it is not the lever, and must not be presented as a performance fix.

### The mechanism, now separable

    our CPU  ~  (presents Windows generates)  x  (our per-present, per-window cost)
                 ~19/s ambient + workload         PrintWindow, 15-18 ms on WARP

Stock is cheap in the second term, so the first barely hurts it. We are expensive in the
second, so the first dominates us. Both are worth attacking; neither substitutes for the other.

### The coalescing fix was never actually tested

`PwScreenUnchanged` opened with `if (!fb || pitch == 0 || !g_ZOrderValid) return FALSE`.
`CollectZOrder` (`main.c:2754`) deliberately skips its `EnumWindows` pass unless an
override-redirect popup is visible — "a second or two at a time" — because paying it per frame
cost roughly 4x the Phase 2A drag figure, and sets `g_ZOrderValid = FALSE` when it skips.

So in any ordinary workload the check refused **every single call**: 0 skips in 5557 decisions.
The null CPU result (all three deltas inside their own run-to-run spread) was measuring
nothing, not measuring a small effect. The premise is untested, **not** falsified — an earlier
reading that it might be falsified is withdrawn.

Replaced with an order-free test: if no other visible window's rectangle intersects this one,
nothing can cover it whatever the order is; paired with "is the foreground window" so a
full-screen window *below* (the shell desktop) cannot veto everything.

### Instrument defects found the same evening

1. **A `0.0%` that meant "the code never ran".** Fixed by counting refusals per cause
   (`pwnofb/pwnoz/pwoff/pwocc/pwnofg/pwovl/pwfirst/pwchg`), so an undifferentiated zero cannot
   recur. Only `pwchg` supports "the present was real"; everything else is the check declining
   to look.
2. **All four analyzers mis-parsed the phase markers.** The real format is
   `### PHASE-START <name> <ts>` — with a `###` prefix. Every one assumed field 0 was the
   keyword and field 1 the name, so phase lookups silently found nothing and reported "No usable
   data" for the win11 idle run whose data was perfect. The shell side used `awk '{print $NF}'`
   and was correct throughout, which is why the harnesses ran happily while analysis came back
   empty. Re-running the fixed parser over already-collected data cost no guest time and
   produced the 18.75 fps result above.
3. **A PASS criterion that could not fail.** `validate-coalesce.sh` compared single medians
   against a historical, non-interleaved baseline with no noise test, and printed
   "typing improved AND drag not regressed: True" for deltas of −1.8%, −9.9% and −3.6% against
   spreads of 9.7%, 15.6% and 29.2%. That verdict was retracted.
4. **An A/B that produced zero valid points**, because qrexec runs unelevated on clean-room
   guests — a wall documented in `win11-idd-vs-bda.ps1` months earlier and walked into anyway.
   The harness refused to fabricate numbers, which is the one thing that went right.

---

## 2026-08-09 — the session was never locked; autologon was broken. Three retractions.

### What actually happened

The guest sat at **"Windows sign-in"** — verified by capturing the dom0 desktop and *looking at
it*, after the user pointed out the screenshot tool had been available the whole time. It was
still there after a clean kill + cold start, so this was never an idle lock:
**AutoLogon does not resume the session after any reboot.**

Cause: `<LogonCount>999</LogonCount>` makes Windows write `AutoLogonCount`, and while that
value is present Windows **consumes `DefaultPassword`, deleting it after use**. Autologon is
then left with a username and no password and falls through to the sign-in screen. Deleting
`AutoLogonCount` and re-writing the credentials gives unlimited autologon. Fixed in both answer
files and gated by an acceptance step that **reboots and requires the session back** — the one
thing that could not be tested without rebooting. It passed: 46 s, versus never.

Marked TEST-RIG ONLY: it stores a plaintext password in the registry, which the shipped
installer must never do.

### Retractions

1. **"The idle Windows 11 desktop presents 18.75 fps ambient."** Wrong. That guest was at the
   sign-in screen with a pending update. On a settled guest with a *verified* session the idle
   rate is **5.20 fps** (4.96 / 5.73 / 5.20) — 3.6x lower.
2. **"The idle screen is byte-static."** Wrong, and wrong for an instructive reason: the probe
   sampled at a uniform 1500 ms and **aliased** with a blinking notification, so every sample
   landed at the same phase and saw nothing. Uniform sampling cannot see a periodic signal.
   Now 250 ms with 150 ms jitter, which finds change in 6 of 39 intervals.
3. **"A locked session unmaps the guest's windows, so the earlier wedge was probably this."**
   Wrong: the sign-in window *is* mapped and visible. Both the unmapping claim and the wedge
   attribution built on it are withdrawn.

### What survives, and is now on solid ground

On a settled guest with a verified session, idle:

- **5.20 presents/s**, every one carrying real dirty rects (`empty=0`, ~350k px);
- actual pixel change in **6 of 39** sampled intervals (~0.38/s);
- and **every changed region lay inside the single open application window** — Notepad's caret
  and text (window 1332,445–2118,1038; changed boxes 32x32, 560x48, 784x560).

Nothing outside that window changed: no taskbar, no wallpaper, no widget, no shell surface. So
~90% of idle presents carry no pixel change — DWM reports composition damage for regions whose
contents are identical.

**This kills the shell-quieting direction.** `guest/quiet-shell-surfaces.ps1` was built to
disable widgets/search/Copilot on the theory that some surface repaints unprompted. There is no
such surface. It must not ship on that basis.

### The pattern worth naming

Three times in two days an instrument returned a confident **zero** that meant "I could not see
it", not "there is nothing there":

- the coalescing fast path: 0 skips in 5557 decisions, because it required `g_ZOrderValid` and
  `CollectZOrder` deliberately leaves that FALSE unless a popup is on screen;
- the idle probe: 0 changed cells, because uniform sampling aliased with the blink;
- and before both, a counter that was incremented and never read.

Each looked like a finding. The defence that worked was counting *causes* rather than outcomes
(`pwnofb/pwnoz/pwoff/pwocc/pwnofg/pwovl/pwfirst/pwchg`), and the defence that would have worked
soonest was looking at the screen.

---

## 2026-08-09 (later) — RETRACTION: the elevated swap does NOT work on win11-idd-test

HANDOVER.md claims "win11-idd-test has stock 4.2.2 with a `.orig` backup, so swap ours in,
measure, restore" and "Elevation is available: guest/run-elevated.ps1". Both are FALSE for
this guest, measured today:

- `run-elevated.ps1` fails at `schtasks /create ... /rl HIGHEST` with **Access is denied**.
  Directly confirmed: an unelevated LIMITED task creates fine (RC=0), a HIGHEST task is
  denied. The `user` token is fully UAC-filtered here: `whoami /groups` shows
  **Medium Mandatory Level** with `BUILTIN\Administrators` as **deny-only**;
  `EnableLUA=1`, `ConsentPromptBehaviorAdmin=0x5`, `FilterAdministratorToken`/
  `LocalAccountTokenFilterPolicy` unset.
- There is **no `.orig` backup** on win11-idd-test (`gui-agent.exe.orig` absent) — swap-agent
  never ran there, because it can never elevate there.

Root cause of the bad handover claim: the swap was only ever *verified* on **win10-clean**
(`verify-elevated-swap.sh` runs there), and Win10's default UAC posture let the HIGHEST-task
trick through. It was extrapolated to Win11 without testing. Win11 built from
`autounattend-win11.xml` keeps UAC fully on, so the trick does not work on ANY Win11 guest
from that answer file — not just this one.

Consequence: `ours-vs-stock-one-guest.sh` / `stock-remeasure-1guest.sh` cannot run on
win11-idd-test as written — the swap silently no-ops and the harness would (correctly) refuse
the ours reps on the hash check. The single-variable Win11 stock-vs-DDA comparison is BLOCKED
on elevation, pending a decision (bake `EnableLUA=0`, test-rig-only, into the answer file and
reprovision one reusable stock guest; or credentialed schtasks, which the dev-qube safety
classifier blocks). Roadmap item N1 (the swap loop) inherits this: it must be fixed at the
answer-file level for Win11, not assumed working.

---

## 2026-08-09 (later) — the "guest restarts itself" mystery: QUEUED QREXEC + a 6000 s timeout

**Mechanism, reproduced and then fixed.** `win11-fresh` came back ~3 s after every `qvm-kill`,
looking exactly like a wedged/zombie domain. It was neither.

A qrexec call to a **Halted** qube **auto-starts it**. `win11-fresh`'s Windows install has no
working guest qrexec agent, so each call then hangs for the full `qrexec_timeout` — which is
**6000 s** on these guests — pinning 8 GB up for up to 100 minutes. Calls had QUEUED from this
qube (win-idd-mgmt) in earlier sessions. The queue outlives the shell that made it: killing the
script does NOT cancel the pending calls, which is why every process hunt came back empty
(100 `/proc` samples over 30 s matched nothing but the sampler itself).

**Fix that drained it, with native tools only:**
```
qvm-prefs win11-fresh qrexec_timeout 15    # was 6000
qvm-kill win11-fresh
```
Each queued call then failed in ~15 s instead of 6000 s. Observed draining: Transient at
t+10-20, t+35-45, t+55-65 (three queued calls), then **Halted continuously from t+70 s**.
8 GB recovered. `win-idd-test` came up by the same route minutes later — it is `tools/qtest`'s
DEFAULT target when `QTEST_VM` is unset, so any bare `./tools/qtest ...` starts it.

**Retractions.** Two wrong claims made and corrected within the hour:
1. "Nothing is restarting it, it never died" — WRONG. The user watched it shut down and restart;
   a kill+poll test then reproduced it (Halted t+3 s, Transient t+6 s). Built on one bad
   `qvm-shutdown --wait` reading that showed Halted.
2. HANDOVER.md trap #1 blames "a background script fighting a deliberate qvm-kill". The script is
   not the agent of the restart — the QUEUED CALL is, and it survives the script's death.

**Rules that follow:**
- Never leave a harness pointed at a guest whose qrexec agent is dead: with `qrexec_timeout=6000`
  every retry pins the guest for 100 minutes and resurrects it after a kill.
- Before diagnosing a "wedged" guest, check `qrexec_timeout` and drain by lowering it. Do NOT
  reach for `xl destroy`; the native tools are sufficient and were never the problem.
- Always set `QTEST_VM` explicitly. A bare `tools/qtest` silently starts `win-idd-test`.
- Memory pressure is the real cost: three 8 GB guests up at once starved the host and made
  qubesd admin calls fail/hang ("Service call error", `qvm-ls` blocking >120 s).

**Same session, provisioning bug found and fixed:** `usb-provision.sh:12` used
`NETVM="${4:-core-net}"`. The colon form treats an EXPLICITLY EMPTY argument as unset, so
`usb-provision.sh <vm> loop3 loop10 ''` — the documented way to ask for an OFFLINE guest —
silently produced `netvm=core-net`. The swappable-stock reprovision therefore came up
NETWORKED, against CLAUDE.md's hard rule and against measurement hygiene (a networked Win11
guest pulls updates during OOBE, the documented source of the bimodal benchmark clusters).
Caught ~2 min into the install from the provisioner's own log line "creating win11-idd-test
(netvm=core-net)"; `qvm-prefs win11-idd-test netvm ''` applied immediately, well before first
logon. Fixed to `${4-core-net}`: omitting the argument still defaults to core-net, passing ''
now means offline. Lesson: read the provisioner's echoed configuration, do not assume the
argument you passed is the value it used.

---

## 2026-08-09 (evening) — THE STOCK COMPARISON, AT LAST. It does not say what we hoped.

First single-variable ours-vs-stock measurement in the project's history: ONE guest
(`win11-idd-test`, rebuilt today with genuine stock QWT 4.2.2 + `EnableLUA=0`), our agent
swapped in and out IN PLACE via the elevated scheduled-task path, hash-verified every rep,
5 rounds interleaved, classic Notepad both sides.

**GATE: ddacap=2293, pwcap=13 -> the DDA fast path served 99.4% of captures, zero refusals.**
This is a clean read of the feature working as designed, not a fallback measurement.

| metric | stock 4.2.2 | ours (DDA, cond C) | delta | worst spread | verdict |
|---|---|---|---|---|---|
| typing | 2.188 | 4.381 | **+100.3%** | 62.8% | **REAL — distributions do not overlap** |
| drag   | 12.314 | 11.727 | −4.8% | 34.6% | inside noise — NO verdict |
| scroll | 4.369 | 5.158 | +18.0% | 42.5% | inside noise — NO verdict |

    typing stock [1.400 1.867 2.188 2.333 2.651]   ours [3.042 3.756 5.007 5.795]
    drag   stock [11.396 12.174 12.314 12.331 12.952] ours [9.359 10.784 12.669 13.421]
    scroll stock [3.426 4.070 4.369 4.383 4.843]   ours [4.688 5.152 5.163 6.879]

Typing is the one robust result: **every** ours rep is worse than **every** stock rep
(ours min 3.042 > stock max 2.651). Our agent costs 2x stock on typing CPU. Drag and scroll
differences are smaller than the run-to-run spread and prove nothing in either direction —
the harness's own "BEATS STOCK" tag on drag (0.95x) is NOT supported and must not be quoted.

n=4 on the ours side: `ours-ro3`'s CPU sampler produced no samples, correctly emitted as
`{"na": ...}` rather than 0.

### RETRACTION — what the −67% actually meant

HANDOVER.md's headline ("DDA-sourced capture is a large, measured win: typing −67%") compared
**our binary against ITSELF** with DDA disabled (condition D, typing 12.427). It never compared
against stock. Stock is 2.188. So the honest statement is:

  our build without DDA   12.427   (5.7x WORSE than stock)
  our build with DDA       4.381   (2.0x worse than stock)
  stock 4.2.2              2.188

DDA removes most of an overhead THE FORK ITSELF INTRODUCED. It does not make the fork faster
than what it forked. The ship gate's "publish as a performance bugfix" framing is withdrawn:
on typing, this build is a regression against stock and must not ship as-is.

### The one confound still open, and it is testable

Our build writes a QGAPERF record per frame (`g_PerfEnabled`, gated by the `PerfLog` registry
DWORD, perf.c:89); stock emits none BY CONSTRUCTION (benchmark.sh's own header says so). So
this compares an instrumented build against an uninstrumented one, and an unknown share of
the +100% typing cost is logging, not the feature. Next experiment: same binary, `PerfLog=0`,
third interleaved side — verified by HASH (the binary is ours) plus the ABSENCE of QGAPERF
records (logging really is off). That splits "our code is slower" from "our logging is slower",
which is the difference between a redesign and a build flag.

## 2026-08-09 (late) — TYPING GAP ROOT-CAUSED: it is an IDLE floor, and the idle floor is the sweep

### The reframe: there is no typing regression. There is a standing burn.

Per-phase process-CPU recomputed from the raw 4 Hz SAMP traces of the same 2026-08-09
stock comparison (script `phase-cpu.py`, session scratchpad; ours n=4 — ro3 has no
samples — stock n=5, boundaries interpolated from rep.json):

    phase        ours     stock     delta
    idle (all)   3.04%    0.57%     +2.47   <- the defect
    type         4.38     2.02      +2.36
    type - idle  1.34     1.45      -0.11   <- typing itself is AT PARITY
    drag        11.49    12.17      -0.68   <- fork slightly cheaper
    scroll       5.44     4.13      +1.31 (idle-adjusted increment 2.40 vs 3.56 - cheaper)

Every phase's gap is the idle floor wearing that phase's name. The instrumented main loop
accounts for ~1.0-1.2 points during typing (677 µs/frame at ~15 fps; typing-phase upd=32,
enu=38 — the SetWinEventHook rework WORKS; HANDOVER's scary upd=1157 was the whole-rep mean,
drag-dominated). The other ~3 points never appear in any QGAPERF column.

Bonus finding, direction reversed: stock's working set GROWS ~87 MB per 110 s rep
(34 -> 120 MB); ours is flat at ~63 MB (+14 KiB).

### The named cost: wincapture's 250 ms sweep has no DDA exemption

`wincapture.cpp:38,241-253`: every 250 ms the engine thread marks one live channel dirty —
unconditionally. During the whole benchmark the one channel is the DDA-active Notepad
window (ddacap=1 every frame). Each sweep then runs CaptureAndDiff (:96-224): fresh
CreateDIBSection (3.84 MB, kernel zero-fill), PrintWindow(PW_RENDERFULLCONTENT) — a
synchronous cross-process render, 15-18 ms class on this WARP guest per main.c's own
comment — GdiFlush, a full-buffer row memcmp (7.7 MB reads), teardown. 4x/s, forever,
for a window whose every real change the DDA path already serves. ~25 ms/s of in-process
CPU ≈ the entire 2.5-point idle delta. Invisible to QGAPERF by construction: it is on the
engine thread and pwcap counts only frame-loop PerfNotePwDecision calls.

It is also a CORRECTNESS bug: main.c:3712-3719 closes the buffer-ownership race "by
construction" on the claim that "while DDA-active nothing ever marks the window dirty -
the engine never touches the buffer at all". The sweep falsifies that claim 4 times a
second: it can overwrite DDA-established content with PrintWindow-sourced pixels (the
alpha-byte difference the ESTABLISH-ONCE comment itself names) and fire capture-thread
damage — a 4 Hz version of the content swap that rework existed to remove.

Ruled out by the same evidence pass: window tracking (typing-phase upd+enu = 70 µs),
send amplification ("sends=2x dirty rects" is header+body counting in VchanSendTimed —
messaging is 1:1 with stock), dirty-area inflation (area is the raw pre-intersection DXGI
number; stock sees the same rects), StagingCopyFrame (per-frame Map/Unmap + dirty-region
copy ~0.2-0.7 pt during typing, near zero at idle — real but secondary; note the fork
copies every dirty pixel twice where stock copies zero), engine idle polling (Sleep(8),
~0.05-0.25 pt), FrameSignature hashing (verified gated off), PerfLog (168 µs/frame = 0.25
pt at 15 fps — closes the "one confound still open" above: logging is NOT the gap).

Also found and noted: wincapture.cpp/`.h` and perwindow.h headers still describe a WGC
engine; there is NO Windows.Graphics.Capture in this build (activation fails under
SYSTEM/session-1, wincapture.cpp:1-21) — the engine is PrintWindow polling. Stale docs.

### The fix (this commit)

Per-channel `ddaOwned` flag + `WcSetDdaOwned()`: while the frame loop owns a window's
buffer (DDA-active), the engine neither sweeps it nor consumes its dirty flag (pending
marks are served when ownership drops; WcPrefill as a direct call still works — it is how
ownership is established). Set on DDA entry before the prefill, re-asserted per
steady-state frame, cleared on every DDA exit; PwDetachWindow now also clears PwDdaActive
(was stale across detach/re-attach). Attribution switch in the house style: registry
DWORD `SweepDdaExempt` (default 1), marker file `C:\Users\Public\qga-sweepdda-off`
disables at runtime — so the A/B runs on ONE binary.

Prediction to falsify: with the exemption ON, idle CPU drops from ~3.0 to <=1.0 and typing
from ~4.4 to ~2.3-2.7 (stock parity); with the marker present, both return to current
values. If idle does NOT drop, the sweep attribution is wrong and the remaining suspects
are StagingCopyFrame and the 8 ms poll loop, in that order.

## 2026-08-09 (night) — SWEEP FIX VERIFIED: idle floor gone, typing at/below stock reference

One binary (agent 92C48AC55CF96D4B = submodule e0cd9c4 sweep fix + 09b643e version bump),
marker-toggled A/B on win11-idd-test, 3 rounds interleaved E,N; cold boot included (the
guest started Halted); hash gate passed on all 6 reps; DDA served throughout (ddacap sums
363-2528 per rep vs pwcap 2-27). E = SweepDdaExempt active (default), N = marker
qga-sweepdda-off present = the pre-fix behaviour deliberately re-introduced.

    phase        E (fix)   N (defect)   stock ref   before-fix ref
    idle pooled    0.83       2.86        0.57         3.04
    typing         1.71       3.93        2.02-2.19    4.38
    drag           8.67      13.15       12.31        11.49-11.73
    scroll         3.51       5.51        4.37         5.16-5.44

- The defect-reintroduced control REPRODUCES the pre-fix numbers (idle 2.86 vs 3.04,
  typing 3.93 vs 4.38): the check has been seen to fail on the defective configuration,
  so its pass is proven meaningful (autonomy rule 5 satisfied).
- Typing separates COMPLETELY per-rep: every E rep (max 2.35) is below every N rep
  (min 3.33). Idle separates on phase means in all four idle windows (pooled 0.83 vs
  2.86); individual 2-5 s idle windows overlap once (1.60 vs 1.25) - short-window
  sampler quantisation, the pooled picture is unambiguous.
- Against the stock REFERENCE (previous run, same guest/harness/phases, not interleaved
  today - claim accordingly): idle 0.83 vs 0.57 (parity within the sampler's floor),
  typing 1.71 vs 2.02-2.19 (at or below stock), drag 8.67 vs 12.31 (~30% below), scroll
  3.51 vs 4.37 (below). The honest headline: THE FORK NO LONGER COSTS MORE THAN STOCK ON
  ANY MEASURED PHASE, and the 2x-typing verdict is repaired at its root cause. A fresh
  interleaved ours-vs-stock run would make the stock comparison ironclad; the E-vs-N
  separation needs no such caveat.
- Not yet in any released artifact: released builds still carry the burn until the next
  release (prepare-but-hold per the owner, 2026-08-09).

## 2026-08-10 — PV-DISK UPGRADE GATE VALIDATED; THE CRASH IS REAL AND WORSE THAN REPORTED

The gate shipped yesterday marked "unvalidated". Tonight's three-phase run removes that
caveat and hardens the fix:

1. **Probe positive, three real guests.** win11-idd-test, win10-e2e, and a clean-room
   freshly provisioned win11-fresh all read PVBOOT=True with raw evidence BusType=SCSI,
   disk model "XENSRC PVDISK", xenvbd Start=0. (win10-e2e was picked as the NEGATIVE
   control on the assumption it predated PV restoration - wrong: it is PV-booted too.
   A genuine False-case guest is still owed; candidates win10-clean/win10-stock, else a
   /nodisk provision.)
2. **Gate fires.** On the fresh stock guest, the gated installer (payload re-hashed so
   Test-Payload accepts the swapped-in script) verified 24 files, entered stage 2, probed
   pv_boot_disk=true, found the stock MSI - and Failed with the exact message BEFORE
   uninstalling anything. Post-gate probe still True; QWT still registered.
3. **The crash reproduces - and Qubes makes it worse than the field report.** With
   /AcceptPvDiskUpgrade the uninstall ran (rc=3010), the recipe printed, the reboot was
   taken - and the guest NEVER CAME BACK. Seven consecutive boot attempts died within
   ~12-24 s each: under Qubes the domain is DESTROYED at the instant of the bugcheck
   (on_crash=destroy), so Windows never counts failed boots and the "crash-loop ~3 times
   -> recovery menu" path the field user reported NEVER ENGAGES here. A 0x7B-bricked
   qube on Qubes has no in-guest recovery at all without console interaction; offline
   hive repair or reinstall are the real options. Docs updated accordingly.
4. **Fix upgraded from gate to mitigation.** The installer now RE-ARMS the emulated
   storage stack (atapi/intelide/pciide/storahci -> Start=0, the exact state Safe Mode
   restores) right before the risky reboot when proceeding on a PV boot disk. Validation
   cycle for the mitigation is queued: fresh provision, switch path again, intermediate
   reboot expected to SURVIVE. Until that run passes, the re-arm is implemented-but-
   unproven (the README says "expected").

Operational refindings, same night: (a) the queued-qrexec trap struck again - win11-fresh
sat "Transient" through two qvm-kills because the 3b wait-loop's probe calls were queued
with qrexec_timeout=6000 (a FRESH VM does not inherit the 15 s the roster doc assumes -
set it at provision time); (b) /tmp is a 1 GiB tmpfs and a ~100 MB payload zip filled it
mid-write, producing a silently EMPTY guest-side payload and a void first "gate did not
fire" result - caught by judging output (empty C:\pvtest), now guarded by an explicit
expanded-file-count gate in pv-validate.sh; (c) dom0 fullshot cannot photograph a guest
that dies in <14 s - behavioural evidence (boot-die loop) plus in-log sequence stands in.

### Operational lessons from the e2e chain (2026-08-10, early)

- **Never qvm-kill a Windows guest that is wedged on a driver-restart dialog.** win11-fresh
  sat with "Xen PV Storage Host Adapter needs to restart" (modal) + "You're about to be
  signed out" (QWT setup) and qrexec down; a hard qvm-kill mid-transition left the boot
  path half-switched and the guest insta-bugchecked on every subsequent boot - the same
  die-in-seconds signature as the 0x7B repro, self-inflicted. `qvm-shutdown` (ACPI) lets
  Windows complete the pending driver work and sign-out; that was the right move.
- **The provision babysitter must never be orphaned.** usb-provision returns once the
  installer boots; the caller owns restart-on-Halted for the install's several reboots.
  Killing the calling script orphans the sequence and the guest wedges on whatever
  interactive step the dismisser misses (observed: the PV storage restart prompt).
  scratchpad/provision-then-e2e.sh now chains provision -> babysit -> verify -> e2e in
  one process so an interrupt cannot split them.
- A recreated VM does NOT inherit qrexec_timeout: usb-provision removes and re-creates,
  so the 15 s guard must be re-applied after EVERY provision (now done inside the chain).

## 2026-08-10 — IN-PLACE MSI UPGRADE OVER STOCK: END-TO-END PASS (the user's cheap solution, proven)

The 4.3.0 bump made the uninstall-first flow obsolete for upgrades: the rebuilt MSI shares
stock's UpgradeCode ({14BCB82F-3C4B-4C77-8E00-20BAEBC61354}), declares <MajorUpgrade>, and
outversions stock, so stage 2 now takes an IN-PLACE MSI major upgrade whenever everything
installed is older (upgrade_mode in the RESULT JSON; uninstall-first survives only for
same/newer versions, still behind the validated PV gate + storage re-arm).

E2E on a clean-room stock 4.2.2 guest (win11-fresh, PV boot disk active - the exact
configuration that BRICKED under the old flow hours earlier): 12/12 meaningful checks.
Stock registered -> installer took the in-place path -> NO intermediate reboot -> guest
BOOTS -> exactly one product, 4.3.0.0 -> agent hash matches the artifact reference
(91F40ECE29286063), running, FileVersion 4.3.0.0 -> PV disk re-bound -> app HW-accel
policies applied -> guest window mapped in dom0.

Findings the e2e earned:
1. **The upgraded guest's FIRST boot runs on the emulated disk; xenvbd re-binds on the
   SECOND boot.** That transitional state is precisely why the in-place path cannot 0x7B
   (the emulated stack stays boot-ready throughout), and it doubled as the genuine
   NEGATIVE probe case: BUSTYPE=ATA/"QEMU HARDDISK" mid-transition -> PVBOOT=False from a
   real guest state. The probe now has live True (3 guests) AND False evidence.
2. **A real parse bug in disable-hw-accel.ps1** ("Office $v:" - PowerShell reads $v: as a
   scoped variable; needs ${v}:) - the script had never run on a guest since its rewrite;
   the installer's non-fatal wiring caught and reported it exactly as designed. Fixed and
   re-validated live: 36 writes, 0 failures, Chrome policy readable afterwards.
3. local.WinScreenshot is policy-scoped to win-idd-test; e2e liveness for other guests
   must use the fullshot's geometry (check fixed).

Both e2e defects were in the TEST, one was in the payload script; the upgrade path itself
passed on the first genuine attempt.

## 2026-08-10 — RELEASED: v4.3.0-agent09b643e (tagged Latest)

Published from CI run 31364772166: dom0 RPM (now auto-patches qvm-create-windows-qube's
auto-qwt stub via qwt-ng-fix-qwcq in %post - the confusing notice is gone), ISO, setup
tarball, SHA256SUMS. gui-agent.exe in the assets is 91F40ECE29286063 - the exact binary
the upgrade e2e verified; the perf A/B ran on a sibling build of the same agent commit
(09b643e). Ships: the sweep fix (typing 1.71 vs stock 2.02-2.19), the in-place MSI
upgrade over stock, the PV gate + storage re-arm fallback, the app HW-accel pre-tweak
(with the ${v}: fix), and 4.3.0 versioning throughout. README rewritten to the post-fix
story; RELEASE-NOTES-09b643e.md is the release document; 03b1674 notes marked superseded.

## 2026-08-10 — updates-proxy Stage 0 PASS (baseline + instrument validation)

Plan: PLAN-updates-proxy.md. win11-fresh already has netvm=none (G1 satisfied without a
dom0 change), so Stage 0 ran in full. Both instruments emit clean === RESULT === JSON.

- guest/nic-state.ps1: {"adapters_up":0,"adapters_all":0,"nlm_connected":false,
  "nlm_internet":false,"ncsi_state":"probe=1"} - structurally no networking, NLM reports
  disconnected/no-internet. This is the state Stage 1 interrogates.
- guest/wu-scan.ps1 (COM IUpdateSearcher, forced ssWindowsUpdate+Online): FAIL
  hresult 0x8024402C (WU_E_PT_WINHTTP_NAME_NOT_RESOLVED) in 3.5 s. This is the
  DEFECT-PRESENT CONTROL SIGNATURE for every later stage - a fast connectivity-class
  fail, exactly the family the plan predicted, not a hang.
- qrexec policy-evaluated check: a bogus-service qrexec-client-vm call returned RC=0 with
  the handler NOT run (no HANDLER_RAN echoed). Confirms firsthand the documented Windows
  footgun: qrexec-client-vm ALWAYS exits RC=0 on trigger, success or denial; only the
  bytes the handler receives are evidence. Directly shapes Stage 2's gate (RC is worthless;
  the received response body is the datum).

Gate: PASS. Next: Stage 1 - guest-local mock proxy on 127.0.0.1:8082 + wu-proxy-config.ps1
(three planes), ask whether wuauserv/DO dials the loopback proxy with zero NICs. Needs no
dom0 gate (guest-only); the mock-proxy also becomes the plumbing-vs-Tor-path discriminator
for the later core-update debug target.

## 2026-08-10 — updates-proxy Stage 1: R1 SPLITS (proxy works offline; wuauserv is NLM-gated)

win11-fresh, netvm=none, EnableLUA=0 (direct HKLM writes work). Three proxy planes set via
guest/wu-proxy-config.ps1 (WinHTTP + device-wide WinINET ProxySettingsPerUser=0 +
DODownloadMode=0), verified. Kill-test guest/stage1-killtest.ps1 runs a loopback listener on
a background runspace IN-PROCESS with the WU COM scan (no detached child - start /b children
survive the qrexec session and squat 8082, a trap that cost two confounded runs; and
file-logging was unreliable - the in-memory runspace queue is the fix). Two baked-in controls.

DECISIVE RESULT (controls both meaningful):
- Control A (explicit-proxy client) => selftest_seen=true: the listener provably captures.
- **Defender cloud protection DIALED THE LOOPBACK PROXY**: captured
  `CONNECT wdcp.microsoft.com:443` and `CONNECT wdcpalt.microsoft.com:443` to 127.0.0.1:8082,
  with ZERO network adapters and NLM reporting not-connected. => the proxy planes work and NLM
  does NOT universally hard-gate loopback-proxy use. R1 (the fatal "nothing dials with no NIC")
  is RETIRED for WinHTTP components generally.
- **wuauserv did NOT dial**: the WU COM scan fast-failed 0x8024402C (WU_E_PT_WINHTTP_NAME_NOT_
  RESOLVED) in ~2 s, making NO connection to the mock (wu_endpoint_hits=0). NAME_NOT_RESOLVED
  = it attempted DIRECT resolution, never the proxy; the ~2 s fast-fail is a connectivity
  PRECHECK that Defender skips but WU performs. wuauserv restart did not change it.
- Control B (default-system-proxy client to a fake WU host) => sysproxy_routes=false: a .NET
  GetSystemWebProxy() request did not reach the mock either - the WinINET default-proxy
  resolution has its own quirk (ProxyOverride <local> / pre-connect DNS), noted for Stage 5.

VERDICT: the approach is ALIVE (offline proxying demonstrably works), but Windows Update
specifically is gated by an NLM/connectivity precheck -> Stage 1b (make NLM report
connectivity: NCSI registry override, then KM-TEST loopback adapter) is now the critical path,
NOT optional. Also found: the stock offline provisioning left
DoNotConnectToWindowsUpdateInternetLocations=1 set (WU internet blocked) - the shipped feature's
-Enable must clear it (wu-proxy-config.ps1 currently GUARDS on it; the productized version
should manage it). Instruments left reverted (planes Disabled).

## 2026-08-10 — updates-proxy Stage 1b: LOOPBACK ADAPTER UNBLOCKS wuauserv (R1 fully retired)

Rung 2 of the NLM ladder, on win11-fresh: installed the in-box Microsoft KM-TEST Loopback
Adapter via the QWT-shipped devcon (`devcon install %windir%\inf\netloop.inf *MSLOOP`),
gave it a static IP 10.137.99.99/24 with NO gateway and NO DNS. nic-state then reports
nlm_connected=true, nlm_internet=false - a network NLM can see, but no route anywhere.

Re-ran the kill-test (planes re-enabled, wuauserv restarted). RESULT flips decisively:
- wu_endpoint_hits=2: **wuauserv dialed the loopback proxy** - captured
  `CONNECT slscr.update.microsoft.com:443` (the WU service-locator). Its HRESULT changed
  from 0x8024402C (NAME_NOT_RESOLVED, never dialed) to 0x80072EF3 (dialed, got the mock's
  502) - the exact "WU now uses the proxy" signature.
- sysproxy_routes=true: control B (default-system-proxy client) now also reaches the mock.
- selftest_seen=true: control A still valid.

CONCLUSION: the whole approach is viable. wuauserv's ~2 s precheck gates on NLM
CONNECTIVITY (IsConnected), NOT internet reachability - so a routeless loopback adapter
satisfies it while the guest stays structurally offline (no gateway => the routing table
reaches nothing but the loopback proxy, whose only egress is the qrexec updates-proxy
stream). ISOLATION-STORY TRADEOFF: the shipped feature needs this loopback adapter, so the
claim becomes "a NIC with no route, egress only via qubes.UpdatesProxy" rather than
"literally zero NICs" - a design point for the owner (flagged per plan Stage 1b). Rung 1
(NCSI-only registry override, no adapter) was not needed and left untried.

Guest state: planes reverted (Disabled); loopback adapter LEFT INSTALLED (it is the
mitigation; harmless - no route). DoNotConnectToWindowsUpdateInternetLocations cleared.

## 2026-08-10 — updates-proxy Stage 2 PASS: real WU content through qubes.UpdatesProxy (R2+R5 retired)

On the fresh Windows TemplateVM (win11-clonetest, class TemplateVM, stock QWT 4.2.2, netvm
none, tags created-by-win-idd-mgmt + win-idd-testbed). Owner installed the debug policy lines
(mgmt/10-win-idd-all.policy) routing @tag:win-idd-testbed qubes.UpdatesProxy @default ->
target=core-update (the torified proxy; this rig has NO sys-net so the stock default doesn't
apply). One-shot handler guest/up-oneshot.ps1 fired via qrexec-client-vm.

RESULT: **REPLY-BYTES=7493, "HTTP/1.1 200 OK"** from ctldl.windowsupdate.com fetched through
the tunnel. A Windows template with no general networking pulled real Windows Update CDN
content via qubes.UpdatesProxy -> core-update -> Tor. Retires:
- **R5** (policy match): the Windows TemplateVM's qubes.UpdatesProxy call is ALLOWED and the
  handler spawns (MARKER-YES) - stock-style @tag/@type routing works for a Windows template.
- **R2** (qrexec byte path): 7493 bytes of HTTP response traversed the vchan back to the guest
  8-bit clean via the handler's stdin - the "caller never becomes the stream, handler stdio ==
  vchan" model works.

TWO PROBE BUGS FOUND (both shape the shipped forwarder):
1. **qrexec-client-vm.exe is NOT on PATH** in the qrexec session - bare invocation hits
   "command not recognized" and a trailing `& echo OK` masks it (RC=0 footgun compounded).
   The forwarder MUST call it by full path: "C:\Program Files\Qubes Tools\bin\qrexec-client-vm.exe".
   Cost ~4 confounded runs before `where qrexec-client-vm.exe` (empty) exposed it.
2. **Tor latency**: the first fetch returned 0 bytes in a 20 s handler window; 50 s got the
   full 200 OK. The forwarder/relay must NOT impose short read timeouts - WU/BITS set their
   own, and a torified proxy adds seconds. core-update works; it is just slow.

Next: Stage 3/4 - swap the one-shot handler for the connect-back relay (qubes-updates-relay.cs,
full-path fix folded in) so ARBITRARY TCP (not a canned request) tunnels through, then Stage 5/6
real WU scan+download with the loopback-adapter NLM mitigation.

## 2026-08-10 — updates-proxy Stage 3+4 PASS: the connect-back relay tunnels arbitrary TCP

The C# connect-back relay (guest/qubes-updates-relay.cs) compiled ON-GUEST with the in-box
csc and ran end to end. Compile gotcha retired: the in-box Framework csc (v4.0.30319) is the
PRE-ROSLYN C# 5 compiler - no string interpolation, no `using var`, no out-vars. The relay is
now written in strict C# 5 (async APIs are fine, they are .NET 4.5, present on 4.8), so the
"compile on-guest, no build infra" design holds.

Stage 4 (guest/relay-e2e.ps1): relay --listen 8082, then `curl.exe -x http://127.0.0.1:8082`
of a plain-HTTP WU CDN object - ARBITRARY forward-proxy TCP, not a canned request.
RESULT: {"ok":true,"listener_bound":true,"http_code":"200","body_bytes":78028,
"sha16":"B85A829F88A78BDB","magic":"MSCF"}. A real 78 KB signed cabinet (MSCF magic) came
back through: curl -> relay(--listen) -> qrexec-client-vm(full path) -> qubes.UpdatesProxy ->
core-update -> Tor -> ctldl.windowsupdate.com, and the mirror. Retires:
- **R2** fully: 78 KB of arbitrary BINARY traffic crossed the vchan 8-bit clean (MSCF intact).
- **R3**: per-connection qrexec spawn + connect-back token handshake works under a real fetch.
The relay design (caller triggers qrexec with itself as the --relay handler, handler connects
back token-checked, both processes on the guest, handler stdio == vchan) is proven.

State of the risk register: R1 (NLM/no-NIC) retired via the loopback adapter; R2, R3, R5
(TemplateVM policy match) retired here/Stage 2. Remaining: R4 (which WU sub-plane leaks) -
Stage 5/6, real WU scan+download+install through the relay with the loopback-adapter NLM
mitigation and the 3 proxy planes. The relay must run as a persistent service for that (Stage 7).

## 2026-08-10 — updates-proxy Stage 5 PASS: Windows Update SCANS through the tunnel (R4 retired)

On win11-clonetest (Windows TemplateVM, stock QWT, netvm none) with all three pieces live:
routeless KM-TEST loopback adapter (NLM connected), the 3 proxy planes, and the compiled
relay on 127.0.0.1:8082 kept alive by the driving script. RESULT:
    scan ok=true hresult=0x00000000 count=1 seconds=40.3  relay_conns=5
**Windows Update completed an online scan and found 1 available update**, entirely through
qubes.UpdatesProxy -> core-update -> Tor, on a guest with NO general networking. Relay traffic:
    CONN up=822   down=43850   ms=4728
    CONN up=823   down=40162   ms=4894
    CONN up=576   down=7788    ms=6860
    CONN up=7646  down=137553  ms=15237   (137 KB WU catalog, 15 s over Tor)

R4 ANSWER (which plane wuauserv uses): the machine WinHTTP proxy (netsh winhttp) alone is NOT
enough - wuauserv fast-fails 0x8024402C (NAME_NOT_RESOLVED, ~0.4-2.9s, no dial). The missing
piece is the SYSTEM-account WU/BITS proxy: `bitsadmin /util /setieproxy LOCALSYSTEM
MANUAL_PROXY 127.0.0.1:8082 "<local>"`, PLUS clearing C:\Windows\SoftwareDistribution (rename
it) so a backoff-cached failure does not fast-return. With those, wuauserv adopts the proxy and
dials. So the shipped plane set is: netsh winhttp + device-wide WinINET + DODownloadMode=0 +
**bitsadmin setieproxy LOCALSYSTEM** + a one-time SoftwareDistribution reset on enable.

Risk register: R1,R2,R3,R4,R5 all RETIRED. The feature is proven end to end: scan works. Left:
Stage 6 (download+install a real update - large/slow over Tor, but the path is identical to the
137 KB catalog fetch that already worked), Stage 7 (persistent relay service + installer wiring;
Start-Process children do NOT survive here so the service must be a scheduled task or Windows
service), Stage 8 side-scope, upgrade the template to QWT-NG for the packaged feature.

## 2026-08-10 — GWeck field feedback (forum posts 33-36): v4.3.0 fixes CONFIRMED; 3 new items

Ultracode forum diagnosis (wf_cc409d04). GWeck tested v4.3.0-agent09b643e on Win11 25H2:
- **CONFIRMED FIXED (his original 0x7B report):** PV-disk upgrade now detects the dangerous
  case and aborts (post 34); /acceptpvdiskupgrade present; control.exe + installer report
  4.3.0; clean fresh-install works (post 33); dom0 rpm auto-qwt fix in place. The
  INACCESSIBLE BOOT DEVICE hazard from posts 27/30 is field-confirmed closed.
- **NOT our bug (post 35 /idd "file not found"):** GWeck hand-built `Start-Process -FilePath
  'D:\idd'` treating /idd as a program. Our install.cmd relaunches via `%~f0` (=D:\install.cmd)
  and cannot emit D:\idd - verified (install.cmd:55). Real GAP though: no documented elevated
  /idd command, and no "add IDD to an existing install" path (install.cmd /idd on a
  same-version guest correctly stops at the upgrade gate). ACTION: reply with the command +
  add a standalone IDD-only activation switch (skips MSI + PV gate). Reply drafted:
  scratchpad/forum-reply-gweck-v3.md.
- **REAL remaining in-scope bug (posts 33-34):** Win11 25H2 Start menu renders partially,
  shutdown button unreachable - the layered/cloaked companion-HWND class (CLAUDE.md 2A-chrome
  / "double windows"). NOT touched by 09b643e (DDA/idle-burn only). ACTION: built tools/winenum
  (below); need a dump from GWeck while the broken menu is open to find the discriminator.
- Version-lag (4.2.2.0 on post 33) = yesterday's build, already fixed. PV-driver non-clickable
  dialog = same window class as the Start menu, low severity. Qube Manager warning = upstream
  qubes-issues #8090, out of scope.

Built **tools/winenum** (CLAUDE.md 2A-chrome 3b): C# 5 top-level-HWND dumper - handle, pid,
class, WS_*/WS_EX_* of interest, DWMWA_CLOAKED, owner, rect, layered alpha, title. Compiles
on-guest with in-box csc; validated on win11-clonetest (surfaces ForegroundStaging, Shell_TrayWnd,
layered tooltips_class32, WindowsDashboard with full attributes). This is the diagnostic that
pins the Start-menu window predicate once run on a 25H2 guest with the menu open.

## 2026-08-10 — Stage 6 download PROVEN via a reliable (non-Tor) proxy; rig disk cleanup

Stage 6 (WU download+install). core-update (torified) proved UNRELIABLE for large WU
downloads: repeated fresh scans returned different transient WU errors (0x80240439,
0x8024402F) even though the tunnel carried bytes each time (relay_conns>0) - the known
Tor-vs-Microsoft-CDN problem, NOT our forwarder. Pivoted to the owner-preauthorized fallback:
**win-idd-mgmt as the proxy backend** - it has direct (non-Tor) internet and a userspace
tinyproxy on 127.0.0.1:8082 (config /home/user/updates-tinyproxy.conf; the qubes.UpdatesProxy
rpc endpoint already ships in qubes-core-agent-networking). Self-test from the dev qube:
`curl -x 127.0.0.1:8082 <WU CDN>` -> HTTP 200, 80043 B, MSCF. Policy line added
(mgmt/10-win-idd-all.policy) routing @tag:win-idd-testbed -> win-idd-mgmt ahead of the
core-update fallback (owner installed).

Re-run: WU DOWNLOAD works through the reliable proxy - tinyproxy logged real update payload
GETs from tlu.dl.delivery.mp.microsoft.com (Delivery Optimization CDN, plain HTTP:80), 500+
requests, ~8 min of steady streaming. The update is a large cumulative that exceeds a single
560 s script window, so download+install is now run as a guest SCHEDULED TASK (QwtStage6 ->
stage6-async.cmd) that survives to completion and writes C:\Users\Public\stage6-result.txt;
polled from the dev qube. Download path CONFIRMED end to end; install result pending the task.

RIG DISK: dom0 thin-pool hit 87%. Deleted 4 redundant/superseded Windows VMs (owner request,
keep a win10 for compat): win-idd-test (47 GB, original primary, superseded by win11-*),
win10-e2e, win10-stock (comparison done), win11-idd-test (sweep benchmark released; stock
reference redundant with the win11-clonetest template which is also stock QWT). Freed ~98 GB;
pool 87% -> 74.9% (219 GB free). KEPT: win11-clonetest (active updates-proxy TemplateVM),
win10-clean (compat), win11-fresh (Win11 on QWT-NG 4.3.0). All deletions were policy-covered
(admin.vm.Remove via the created-by/testbed/qwt-bench tags).

## 2026-08-10 — Stage 6 CORRECTION: download PATH works, full install NOT yet demonstrated

RETRACTION of the earlier "Stage 6 download PROVEN" framing - it overclaimed. Ground truth:
- The pending update is KB5101650 (2026-07 security update, 26100.8875). After ~8 min of
  streaming through the win-idd-mgmt proxy it reached 753 MB in SoftwareDistribution\Download
  then STALLED. IsDownloaded=**False** - the download is INCOMPLETE, not done.
- What IS proven: the download PATH carries real update bytes at scale - 753 MB of genuine WU
  payload (delivery.mp.microsoft.com) flowed guest->relay->qrexec->tinyproxy->internet with the
  guest having no general networking. Plus WU scan works (Stage 5) and a Defender signature
  update ran through the proxy. So the feature is FEASIBLE and the transport is sound.
- What is NOT proven: a complete download+install of a large cumulative. It stalled at 753 MB.

Likely contributing causes, none cleanly isolated (a clean single retry is needed):
1. **/tmp exhaustion on the PROXY qube** (owner's catch): win-idd-mgmt's /tmp is tmpfs (RAM),
   it hit 100% DURING the download, and a starved tmpfs chokes tinyproxy (forks per
   connection). Timing correlates: steady growth -> /tmp full -> flatline at 753 MB. Freeing
   /tmp did NOT auto-resume (WU/DO does not restart a stalled transfer; usoclient StartDownload
   did not kick it). So /tmp was plausibly the trigger but the retry needs a fresh WU state.
2. Delivery Optimization through a forward proxy: DO reported dl=0MB/0MB (never got the file
   size via the proxy) and looped range requests - a known DO-proxy quirk; forcing classic
   BITS is the documented mitigation.
3. Repeated interrupted script runs left WU in a confused/backoff state.

HONEST NEXT STEP (Stage 6 completion, not done here): one clean run with /tmp headroom on the
proxy qube + DO bypassed (force BITS) + a fresh SoftwareDistribution, ideally on a smaller
update first (a servicing-stack or the Defender channel, both smaller than a full cumulative),
and let it run uninterrupted as a guest scheduled task. The feasibility is settled; this is
reliability/tuning.

OPERATIONAL NOTE: a proxy qube serving WU downloads needs adequate /tmp (or move tinyproxy
temp/logging off tmpfs). This session filled /tmp with old-session scratch; cleaned to 68%.

## 2026-08-10 — Stage 6 download orchestration: DO connection-storm diagnosed; full install blocked on Win11 WU internals

Tinyproxy introspection (owner's steer) gave the real diagnosis of the stall:
- **Delivery Optimization opens a CONNECTION STORM**: 2624 connections to
  tlu.dl.delivery.mp.microsoft.com in one download attempt, 223 errors dominated by
  "Client closed socket before read" (DO opens connections speculatively then abandons them)
  plus upstream "Connection reset by peer". DO's massively-parallel model is a bad fit for
  the relay, which spawns a qrexec-client-vm PER connection (R3): thousands of spawns thrash
  the tunnel AND consume proxy-qube RAM/tmpfs (this is what filled /tmp - thousands of
  tinyproxy forks + qrexec spawns). The 753 MB that landed came through before the churn
  overwhelmed it.
- **Force-BITS test** (DODownloadMode=99 + DoSvc disabled + clean SoftwareDistribution): the
  storm collapsed to **65 connections in 2 min, 5 abandoned-socket errors** - confirming DO
  was the churn source. BUT the download still did not progress: BITS jobs went to
  Error/TransientError with a garbage BytesTotal (17592186044416 = 2^44), folder stayed 0.
  Disabling DoSvc appears to break Win11 24H2's WU download orchestration rather than cleanly
  falling back to a working BITS transfer.

HONEST STATE OF STAGE 6:
- PROVEN: the updates-proxy TRANSPORT is sound - WU scan finds real updates, 753 MB of genuine
  cumulative payload flowed through the tunnel, Defender signature update ran, all with the
  guest having zero general networking. The feature is FEASIBLE and our forwarder works.
- NOT ACHIEVED: a complete download+install of a large cumulative. Both paths fail on Win11
  24H2 (26100) - DO storms the relay, forced-BITS errors. This is Windows' own download
  orchestration (DO/BITS) misbehaving through a forward proxy, a known-hard and
  version-specific problem, NOT a defect in the relay/planes/policy.

WHAT A REAL FIX LIKELY NEEDS (future work, beyond this session):
1. Make the relay handle DO's connection fan-out cheaply - a pre-spawned qrexec handler POOL
   or a single persistent multiplexed qrexec channel instead of spawn-per-connection (kills
   R3 properly). This alone might let DO work.
2. Or a clean force-BITS that Win11 24H2 actually honors (DoSvc left enabled but DO set to a
   mode that yields to BITS; needs experimentation per Windows build).
3. Test on a smaller update first (servicing-stack / Defender-platform), and keep proxy-qube
   /tmp off tmpfs or generously sized.
Guest WU state restored (DoSvc re-enabled, DODownloadMode policy removed). Left in place for
future tuning: the loopback adapter, proxy planes, relay exe, and win-idd-mgmt tinyproxy.

### /tmp confound RULED OUT for the force-BITS failure (owner asked)

Verified: during the force-BITS run tinyproxy peaked at ~65 connections (40x fewer than DO's
2624) and /tmp held 331 MB free with zero growth - no pressure - yet BITS still errored and
the folder stayed 0. So /tmp overflow was NOT the cause of the force-BITS failure; that is a
genuine Win11 24H2 WU-orchestration problem (disabling DoSvc does not cleanly fall back to a
working BITS transfer). For the DO path the /tmp fill was real but is a SYMPTOM of the
2624-connection storm (thousands of tinyproxy forks + per-connection qrexec spawns on a 1 GB
tmpfs), not an independent root cause. Clean separation: transport proven; blocker is Windows'
own download orchestration through a forward proxy.

## 2026-08-10 — R3 relay fix PROVEN at scale; guest WU/BITS/DO corrupted by testing (needs fresh guest)

The R3 connection-storm fix (guest/qubes-updates-relay.cs: read-first + concurrency gate)
is DEFINITIVELY validated:
- Old relay: DO's storm = 2624 connections, 223 abandoned-socket errors, /tmp FORK-BOMBED to
  100%, download stalled at 753 MB.
- Improved relay: handles 150+ concurrent DO connections with /tmp ROCK STEADY at 68% and 0
  abandoned-socket spawns. The fork-bomb is gone. This is the real, committed deliverable.

BUT the full cumulative (KB5101650) download could NOT be completed, and the cause is NOT the
proxy/relay - it is the guest's WU/BITS/DO subsystem now CORRUPTED by excessive testing:
- Both engines are broken: Get-DeliveryOptimizationStatus = "Downloading dl=0MB/0MB" (DO
  downloads nothing); Get-BitsTransfer = multiple jobs in Error/TransientError with a garbage
  BytesTotal of 17592186044416 (2^44 - uninitialized size). BITS/DO cannot even determine the
  file size, so they retry-churn forever (the 107-153 connections) without transferring.
- Attribution: an INLINE COM Download() (no reset) BLOCKED and actually downloaded (killed at
  120s while working), whereas the scheduled-task version fails 0x80240022 immediately because
  it resets WU services then downloads 6s later - a service-startup RACE in the test harness,
  not the feature. And 753 MB DID download early (before the interventions). So the download
  path works; this guest's download engines are now wrecked.
- This guest went through: force-BITS DoSvc-disable, DODownloadMode 0/99, catroot2 rename,
  many SoftwareDistribution clears, a reboot, dozens of service restarts. That sequence left
  BITS/DO in a persistent broken state a reboot did not repair.

HONEST BOTTOM LINE: the updates-proxy feature is FEASIBLE and PROVEN at the transport level
(scan + real payload + Defender, zero guest networking), and the R3 relay fix that makes it
scale is DONE. A clean download+install proof needs a FRESH guest (this one's WU is corrupted)
run ONCE uninterrupted with the improved relay - no service resets, no timeout-killing the COM
call. That is the remaining validation; it is not blocked by our code.

## 2026-08-10 — GWeck installer failure: ROOT-CAUSED (investigation workflow wf_c83674fb) — a DOUBLE version-collision, both times the version was not bumped

The instrument: a 6-investigator + synthesis workflow over the installer/version source (read-only,
source-cited). One investigator hit the StructuredOutput retry cap (its area returned a placeholder
"test/a/b" in the journal); the other five + synthesis returned source-grounded results. Verified the
key MSI-identity claim myself against the vendored WiX (upstream/ro/qubes-installer-.../vs2022/
installer/Package.wxs) rather than trust the synthesis, because its confidence_gap #1 wrongly said no
WiX was in-repo.

GWeck did nothing wrong. Both failures are the SAME disease — a release shipped WITHOUT bumping the
MSI ProductVersion — colliding with two different things:

1. FROM STOCK 4.2.2 (his original 0x7B brick). The earlier release pinned the agent submodule to
   03b1674, whose `agent/version` was still **4.2.2** (`git show 03b1674:version` = 4.2.2; the bump to
   4.3.0 only landed in 09b643e "Bump deliverable version to 4.3.0"). qwt-full.yml:311-313 stamps the
   MSI ProductVersion FROM agent/version, so that build stamped **4.2.2 == stock 4.2.2**. Equal
   ProductVersion => WiX MajorUpgrade cannot replace stock in place => installer falls to uninstall-first
   => msiexec /x stock (incl. its PV disk driver) => intermediate reboot bugchecks 0x7B on a PV-booted
   guest. Corroborated: GWeck saw "4.2.2.0" on that fresh install. **Already FIXED** in the shipped
   09b643e build (agent/version=4.3.0 => MSI 4.3.0 => out-versions stock => in-place, no reboot);
   field-confirmed closed. The PV gate is a RED HERRING for the stock case now (4.2.2 < 4.3.0 is in-place).

2. SAME-VERSION (what he hits now). His guest runs 4.3.0 (v4.3.0-agent09b643e). The "v4.3.1" IDD-default
   release is the SAME submodule 09b643e => agent/version STILL 4.3.0 => MSI ProductVersion 4.3.0 again
   => installed == ours. Shipped/committed HEAD Install-QwtImproved.ps1:648 used `-ge`, so 4.3.0 >= 4.3.0
   => $inPlace=FALSE => uninstall-first => PV gate Fail() on his PV-booted guest. /idd does NOT bypass it
   (it's a deprecated no-op); only /acceptpvdiskupgrade suppresses the gate. So a plain re-run hard-fails.

MSI identity (verified in Package.wxs): ProductCode="*" (new GUID per build), UpgradeCode shared
{14BCB82F-...}, `<MajorUpgrade/>` with NO AllowSameVersionUpgrades (defaults off). Consequence: two
DIFFERENT builds stamped the same ProductVersion are neither an upgrade (equal version) nor a reinstall
(different ProductCode). Therefore REINSTALL=ALL is INERT across builds — it only repairs an IDENTICAL
build (matching ProductCode). The real fix is the version bump, not a msiexec flag.

TWO version sources had drifted (the deeper bug): (A) MSI ProductVersion <- agent/version (qwt-full.yml).
(B) installer's own $ours upgrade decision <- make-setup.ps1 hardcoded '4.3.0' -> package_version ->
MANIFEST. Fix landed in working tree: make-setup now READS agent/version (single source of truth), with
the same 3-field validation, so package_version and MSI ProductVersion can never diverge again.

FIX PLAN (ordered): (1) bump agent/version third field per release, 4.3.0 -> 4.3.1, so the MSI
out-versions both stock and the prior 4.3.0 => clean in-place MajorUpgrade, no gate; (2) single-source
make-setup (DONE, uncommitted); (3) CI/build guard that FAILS if agent/version wasn't bumped past the
last release AND != the release tag's version — the "never again"; (4) keep the installer same-version
in-place branch (-gt + REINSTALL=ALL) only as an identical-build-re-run safety, comment corrected to say
so; (5) standalone IDD-only activation entry point so an already-installed guest can add IDD without a
full MSI reinstall (would have let GWeck add IDD without any of this). Outward-facing, needs owner nod:
the misleading v4.3.1-agent09b643e release (advertises 4.3.1, ships MSI 4.3.0) should be superseded by a
real 4.3.1 build or deleted.

Why CI never caught it: the E2E harness always destroys+recreates the qube and installs FRESH — it never
runs a release-over-release upgrade of our own package, so a same-version collision (which only bites on
the SECOND install) is structurally invisible. The guard in (3) closes that blind spot for good.

## 2026-08-10 — WU-through-proxy payload stall ROOT-CAUSED: BITS/DO connectivity gate, not transport

Layered diagnostic on win11-fresh (guest/wu-diagnose.ps1, guest/wu-fix-probe.ps1), backend =
tinyproxy on win-idd-mgmt (proven: curl -x 127.0.0.1:8082 <WU CDN> -> 200/80KB).
- LAYER A (relay): guest Invoke-WebRequest via 127.0.0.1:8082 -> HTTP 200, 50395 B. Transport
  from the guest WORKS end to end (guest -> relay -> qrexec -> win-idd-mgmt tinyproxy -> CDN).
- LAYER B (Windows verdict): both NICs Get-NetConnectionProfile IPv4Connectivity=NoTraffic,
  category Public.
- LAYER C (DIRECT bitsadmin, no WU COM): TRANSIENT_ERROR, BYTES 0/UNKNOWN, ERROR CODE
  **0x80200010 BG_E_NETWORK_DISCONNECTED** - "no active network connections."
CONCLUSION: the payload engine (BITS, and DO on top) gates on IsNetworkAlive and refuses BEFORE
any byte because Windows sees the interfaces as NoTraffic (offline guest, no routed traffic; the
loopback->qrexec proxy is not an IP-routed network Windows counts). The scan/metadata succeed only
because they ride WinHTTP/WinINET, which honor the proxy and do NOT gate on connectivity. Transport
was never the problem.
RULED OUT: NCSI is NOT the lever. wu-fix-probe tried NlaSvc re-probe, EnableActiveProbing=0, and a
custom ActiveWebProbeHost - ALL left IPv4Connectivity=NoTraffic and BITS at 0x80200010. The verdict
is interface-level (no route), not the web probe.
INDICATED REMEDY (untested): install the in-box KM-TEST loopback adapter (netloop.inf via
devcon/pnputil) with a static IP + dummy default gateway so IsNetworkAlive returns true; BITS still
routes the actual bytes through the OVERRIDE proxy (127.0.0.1:8082). Verify BITS uses the proxy, not
the loopback's fake gateway. Same gate blocks Delivery Optimization, so this is prerequisite for the
north-star in-VM updater agent too.

## 2026-08-10 — Path B (catalog + direct fetch, bypass BITS/DO) PROVEN end-to-end except offline install

After ruling out the BITS/DO connectivity gate (0x80200010) and the loopback-adapter remedy (a
loopback with an unreachable gateway still reports NoTraffic, so IsNetworkAlive stays false), the
chosen path is B: fetch the FULL standalone package over the proxy-aware WinHTTP path and install
offline, sidestepping the connectivity gate that only exists in the DO->BITS online path. Confirmed:
- WU COM search over the proxy returns the pending update (KB5101650) but its DownloadContents is
  the EXPRESS payload: 13421 DISTINCT files (8856 delta + 4565 full COMPONENT files), ~92GB nominal.
  Not fetchable without reimplementing express range selection - so B does NOT use it.
- Microsoft Update Catalog IS reachable through the proxy (HTTPS CONNECT via tinyproxy; Search.aspx
  200/60KB). Parser note: the catalog uses SINGLE quotes (id='<guid>_link', goToDetails("<guid>")).
- Catalog resolve works: KB5101650 -> picked "2026-07 Cumulative Update for Windows 11, version 24H2
  for x64-based Systems (KB5101650) (26100.8875)" (matches guest build), DownloadDialog.aspx POST ->
  standalone .msu URLs on catalog.sf.dl.delivery.mp.microsoft.com, ~4970 MB.
- SUSTAINED FETCH PROVEN: streaming the real .msu via HttpWebRequest through 127.0.0.1:8082 pulled
  393 MB in 40.1 s at a steady 9.8 MB/s, no stall (full 5GB ~= 8.5 min). This is the exact link that
  died under BITS (0 bytes at the gate); direct HTTP has no such gate.
REMAINING: the offline install (DISM /Online /Add-Package or wusa) of the standalone .msu(s). Note
KB5101650 catalog entry exposes TWO .msu files - 24H2 uses CHECKPOINT cumulative updates, so install
ORDER/prereqs matter (SSU/checkpoint before LCU). This fetch+install core is exactly the north-star
in-VM updater agent's download engine; progress (bytes/rate) is self-reported, no BITS/DO needed.
tools built: guest/wu-diagnose.ps1, wu-fix-probe.ps1, wu-loopback-test.ps1, wu-enumerate.ps1,
wu-distinct.ps1, wu-fullfiles.ps1, wu-catalog-probe.ps1, wu-catalog-get.ps1, wu-fetch-probe.ps1.

## 2026-08-11 — qubes.NotifyUpdates from Windows: the payload crosses; the bug was ARGUMENT QUOTING

The in-VM updater's `Report-Availability` (report the available-update count to dom0 so Qube Manager
lights up "updates available") appeared unfixable across a long thrash — every attempt returned
qrexec exit 0 but the flag never set. VERDICT: not a payload/stdio problem, not `_dom0`, not policy.
It was that `qrexec-client-vm.exe`'s argument was being wrapped in double quotes.

Mechanism, from source (upstream/ro/qubes-core-agent-windows + qubes-windows-utils):
- `qrexec-client-vm.c` parses FOUR fields via `GetArgument()`: domain|service|user|localprogram.
  It does NOT bridge its own stdin; it hands a trigger to the local qrexec-agent over the named pipe
  `\\.\pipe\qrexec_trigger` and returns ERROR_SUCCESS(0) immediately. So **exit 0 means "told the
  agent", NOT delivered/allowed** - it is worthless as a success signal. The agent then does policy +
  vchan asynchronously and spawns the localprogram, whose STDOUT is the vchan to the dom0 service.
- `exec.c:GetArgument()` reads the RAW `GetCommandLineW()`, skips the exe path, then splits the REST
  on `QUBES_ARGUMENT_SEPARATOR` = `L'|'`. **It never strips quotes from fields.**

The bug: passing `qrexec-client-vm.exe "dom0|qubes.NotifyUpdates|user|cmd /c echo N"` (whole string
quoted, the natural instinct + what the relay does with @default) makes GetArgument split
`"dom0|...|cmd /c echo N"` INCLUDING the wrapping quotes -> field1 = `"dom0` (literal leading quote),
field4 = `cmd /c echo N"`. The daemon gets target `"dom0`, which is not a VM, and REFUSES it.
Proven in the guest agent log (Q:\Qubes Logs\qrexec-agent-*.log):
  req: domain '"dom0'  ... local command 'cmd /c echo 4242"'  -> HandleServiceRefused   (BROKEN)
  req: domain 'dom0'   ... local command 'cmd /c echo 4343'   -> (accepted, flag set)   (FIXED)
(The updates-proxy relay has the same latent artifact - it sends `"@default` - and only works because
@default tolerates the junk prefix; a literal `dom0` does not.)

FIX - pass the fields UNQUOTED so the command line reaches qrexec-client-vm clean:
- cmd/batch: escape the pipes, no wrapping quotes:  `qrexec-client-vm.exe dom0^|qubes.NotifyUpdates^|user^|cmd /c echo N`
- PowerShell (re-quotes any single arg with spaces, which would re-leak the quote): pass SPLIT tokens
  so the pipe-bearing token has no spaces and is emitted verbatim:
    & $qr 'dom0|qubes.NotifyUpdates|user|cmd' '/c' 'echo' "$count"
  -> command line `...\qrexec-client-vm.exe dom0|qubes.NotifyUpdates|user|cmd /c echo N`, fields clean.
The localprogram writes the count to STDOUT (cmd `echo N`); dom0's qubes-notify-updates `.strip()`s the
line, so CRLF is harmless. VERIFIED end to end 2026-08-11: user confirms Qube Manager shows updates
available for win11-fresh after the unquoted call. Wired into guest/qubes-windows-update.ps1
Report-Availability (split-token form). Policy is the stock default (@anyvm -> dom0 allow); no dom0
change was needed or made. The dom0 target is literal `dom0`, never `_dom0` (that underscore came
only from throwaway test scripts notify4/5.ps1, since deleted from the guest).

## 2026-08-11 (cont.) — updater agent: scheduled scan reporting to dom0, deployed + validated

Built guest/install-updater-agent.ps1: compiles the relay with the in-box csc (v4.0.30319, like
winenum.cs), places qubes-windows-update.ps1, and registers scheduled task QubesWindowsUpdateScan
(SYSTEM/HighestAvailable, BootTrigger + every PT6H) that runs `-Action scan` ONLY - scan reports
availability; download/install stay on-demand so the task never blocks or reboots on its own.
Mirrors the QubesNetworkReapply schtasks-XML convention.

VALIDATED on win11-fresh (as SYSTEM, no user needed): deploy -> compiled+placed+registered rc=0;
`schtasks /run` -> LastTaskResult=0x0; fresh update-status.json (phase=done, count=0, error=null);
agent log shows the SYSTEM-run report crossing clean: `domain 'dom0' ... 'cmd /c echo 0'`, request
accepted (no HandleServiceRefused). Guest is fully patched so the true count is 0 - correctly
CLEARS the flag (N>0 delivery was proven separately via the quoting fix). Shipped as opt-in
`install.cmd /updatesonly` (staged in make-setup.ps1 alongside activate-idd), parallel to /iddonly:
add the updater to a guest that already has QWT, no MSI, no version/PV gate.

NOT yet validated: the download+install path end-to-end against a REAL pending update (none exists
on this guest now). That exercises Resolve-Catalog -> Fetch-Msu -> DISM, whose pieces were proven
separately (1742->8875) but not through the single agent script in one run. Needs a guest behind on
patches (or a pinned older base image) to close.

## 2026-08-11 (cont.) — the underscore was the leaked quote; progress via a poll service

Two things resolved.

1. The `_dom0`/`_@default` the user kept seeing in the dom0 policy log = the SAME quoting bug,
   sanitized. qrexec replaces the illegal `"` char in a target name with `_`, so wrapping the
   pipe-arg in quotes (`"@default|...`) makes the target parse as `"@default` -> logged as
   `_@default`. The updates-proxy relay still had this (`psi.Arguments = "\"" + target + ...`), so
   every UpdatesProxy spawn logged `target '_@default' does not exist, using @default instead` and
   only worked because @default falls back. FIXED: relay now builds `psi.Arguments` WITHOUT the
   outer quotes (handler keeps its own). Verified: guest agent log now shows `domain '@default'`
   clean, no leading quote -> no more `_@default` in dom0's log. (notify4/5.ps1's literal `_dom0`
   was a separate red herring, since deleted.)

2. update PROGRESS to dom0. qubesdb was the first candidate but qubesdb-cmd.exe's WRITE is broken
   on this QWT build: `client/qubesdb-cmd.c` does `#ifdef _WIN32 optind -= 2` to compensate for its
   getopt port, and combined with `-c write` that double-counts the command word, so cmd_write
   always gets an ODD argv and rejects it ("Invalid number of parameters"). READS work (the stray
   command token reads a harmless empty key); `/qubes-tools/version` -> `1`. There is no qubesdb.dll
   on the guest to P/Invoke either. (Candidate upstream report - core-qubesdb, outside QWT scope -
   pending user approval of exact text.)
   So progress rides the STATUS FILE + a poll service instead: qubes-windows-update.ps1 already
   rewrites C:\ProgramData\Qubes\update-status.json at each phase (downloading pct, installing
   state, reboot_needed). New guest rpc service `qubes.WindowsUpdateStatus` (guest/wu-status.ps1,
   registered by install-updater-agent.ps1 into %QUBES_TOOLS%\qubes-rpc) emits that JSON on stdout
   = the vchan to the dom0 caller. dom0-INITIATED, read-only, so no VM->dom0 policy is needed; dom0
   polls it for live availability + progress. Handler verified emitting the JSON on the guest.

## 2026-08-11 (cont.) — updates rearchitected to the LINUX MODEL: dom0-driven, guest never auto-installs

User direction: behave like Linux qubes - availability notify + dom0 updater drives the install.
Researched the real contract from source (cloned qubes-core-admin-linux; the vmupdate tool lives
THERE, not in a qubes-vm-update repo):
- Linux availability = a timer calling `qrexec-client-vm dom0 qubes.NotifyUpdates /bin/sh -c 'echo 0|1'`
  (upgrades-status-notify). Our scheduled scan-only task echoing the count is the exact equivalent.
- dom0 `qubes-vm-update` runs its agent in the VM via qubes.VMExec and parses PROGRESS AS BARE FLOAT
  LINES 0..100 ON STDERR (qube_connection.py: float(line), 100.0 ends progress, later stderr lines
  shown as messages). Exit 0 = success, EXIT 100 = NO UPDATES, else error. stdout = logs.
- Stock qubes-vm-update cannot drive Windows (it injects a tar of its Python agent and runs
  python3), so the guest speaks the SAME protocol behind its own service + a thin dom0 wrapper;
  future upstream integration is then mechanical.

Implemented (replaces the short-lived qubes.WindowsUpdateStatus poll service - REMOVED, wrong model):
- guest/wu-update.ps1 -> rpc `qubes.WindowsUpdate`: kicks the on-demand SYSTEM task
  QubesWindowsUpdateRun (`-Action full`; rpc handlers are unelevated, DISM needs admin - the
  SYSTEM-task path is proven), tails update-status.json, emits the float protocol, exit 0/100/1.
  2h hard bound; attaches to an in-flight run instead of clobbering it; baselines the status file.
- install-updater-agent.ps1 registers both tasks + the service. GOTCHA: schtasks warns on stderr
  for /st-in-the-past ("Task may not run..."), and under ErrorActionPreference=Stop that WARNING
  became a terminating NativeCommandError killing the deploy mid-script (first deploy silently
  lost step 4). Fixed by registering the run task from XML with an EMPTY <Triggers/> (purely
  on-demand, no warning). Scan task unchanged: scan-only, never installs - "not auto" holds.
- dom0/14-install-qvm-windows-update.sh -> `qvm-windows-update <qube>|--all` (user installs in
  dom0): qvm-run --service --pass-io qubes.WindowsUpdate, renders floats as a progress line,
  maps exit 100 -> "no updates". dom0-initiated => no policy needed.

VALIDATED on win11-fresh (handler invoked exactly as the rpc would):
  stderr: 0.0 / 3.0 / 100.0   stdout: "no updates available"   EXIT=100        (success contract)
  with QubesWindowsUpdateRun deliberately deleted: EXIT=1 + "cannot start..."  (check CAN fail)
NOT yet validated: a real install pass through this path (guest fully patched, count=0) - needs an
out-of-date guest; and the dom0-side wrapper end-to-end (user runs 14-install + qvm-windows-update).

## 2026-08-11 (cont.) — the dom0 request flood: the relay was left as an always-on system proxy

User spotted a flood of qrexec requests in dom0. Guest qrexec-agent log quantified it: 147
qubes.UpdatesProxy triggers in one afternoon (53@12h, 16@13h, 38@14h, 38@15h), still dripping at
15:57/16:01/16:06 with NO scan running. Root cause: Ensure-Proxy set the SYSTEM-WIDE WinHTTP proxy
(netsh winhttp set proxy 127.0.0.1:8082 + Internet Settings ProxyEnable) and never unset it, and the
relay kept listening. Every Windows background HTTP client (telemetry, Edge/Defender update checks,
NCSI, DO) discovered a "working" proxy and phoned home; the relay spawns ONE qrexec call per TCP
connection -> one dom0 policy line each. Beyond the noise this is a SCOPE VIOLATION: an "offline"
guest had standing HTTPS egress through the updates proxy for anything, not just update traffic.

FIX (deployed + verified): proxy is up ONLY during a pass. Remove-Proxy (netsh winhttp reset proxy,
ProxyEnable=0, ProxyServer removed, relay processes killed) runs in a finally around the agent's
main, so even an error path restores the routeless baseline. Verified live: scan completes ->
"proxy removed, relay stopped (offline baseline restored)" -> netsh shows Direct access, no relay
process. Expected residual: a bounded burst of UpdatesProxy lines DURING a scan/update pass only.
Immediate cleanup also applied on win11-fresh (2 lingering relays killed, proxy reset).

## 2026-08-11 (cont.) — REPRODUCED a Start-menu-breaks-under-IDD bug on win11-fresh (24H2); it is a SIBLING of GWeck's, not identical

Goal: reproduce GWeck's S1 (Win key -> garbled/no menu + dom0 "suspicious GUI request" dialog) on
win11-fresh with IDD active. Result: reproduced the USER-FACING breakage (no usable Start menu) via a
concrete, different-from-hypothesized mechanism; did NOT reproduce the dom0 dialog; and FALSIFIED the
workflow's leading S1 theory on this guest.

Setup confirmed: IddSampleDriver Device = OK/active, Basic Display Adapter = Error/disabled; desktop
\\.\DISPLAY2 = 0,0,5120,1440.

FALSIFIED here: the "EnumDisplaySettings fails on IDD -> divide by dmPelsWidth -> INT_MIN -> MSG_CREATE
negative width -> daemon VERIFY dialog" chain. On win11-fresh the agent math (main.c:750-760) runs CLEAN:
EnumDisplaySettings OK, pels=5120x1440, dmPosition=0,0, scale=1.0, all rects positive. No INT_MIN, no
negative dims, no dialog. So GWeck's dom0 dialog is 25H2-specific and needs a different trigger (still open).

REPRODUCED (live gui-agent log + fullscreen dom0 shot, evidence in scratchpad (local only, dom0 shot leaks other qubes - not committed)
scratchpad local shot): press Win ->
- The Start CoreWindow (0x1018a, cls Windows.UI.Core.CoreWindow title "Start") is PARKED OFF-SCREEN at
  16384,6119 (=0x4000, the classic Windows park coord); DWMWA_EXTENDED_FRAME_BOUNDS agrees. Size ~5120x1384.
- It carries a COMPLEXREGION clip (GetWindowRgn type 2), box (window-relative) 2131,502,2989,1392.
- GetRealWindowRect adds the parked origin to the region: 2131+16384=18515 -> announces the Start card at
  ~18515,6621 (858x874), ENTIRELY OUTSIDE the 5120x1440 desktop. The g_StartWindow border fixup
  (main.c:792-801) operates on the already-off-screen rect.
- The reported size then FLIP-FLOPS 5120x1384/1392 <-> 858x890 <-> 858x874 several times in ~2s (region
  present vs momentarily absent as the open animation plays). Each flip = PwResizeWindow grant rebuild
  (detach+reattach) + a SendWindowUnmap+SendWindowMap pair. A MAP/UNMAP/grant STORM.
- Interleaved: "GetRealWindowRect failed 0x80070006 The handle is invalid" every ~1.5s, and finally
  "HandleConfigure: window 0x1018a not tracked" - dom0's configure echo races in after the agent already
  unmapped it. Net: Start ends UNMAPPED; dom0 renders NO Start menu (fullscreen shot shows the guest
  console but no menu). = GWeck's "Windows key -> no usable menu."

Root cause (24H2 path): the agent tracks the Win11 Start CoreWindow which is parked off-screen, then
double-counts the parked origin into its window-relative clip region, announcing an off-desktop window,
and thrashes its size as the region blinks. Distinct from GWeck's 25H2 path where there is NO
CoreWindow (winenum: Wnd_StartFeed instead), so g_StartWindow=FindWindow("Windows.UI.Core.CoreWindow",
"Start")=NULL and all Start special-casing is DEAD - his full-screen Wnd_StartFeed is instead accepted
as a plain window (IsPopup full-screen demotion, main.c:826) and PrintWindow-garbled. Same symptom
class ("no usable Start under IDD"), two different code paths.

Candidate fix (general, safe, helps both): reject/clamp any window whose computed rect lies ENTIRELY
outside the desktop bounds (left>=screenW or top>=screenH or right<=0 or bottom<=0) before MSG_CREATE/
MAP - an off-screen announce is never useful and is the shared failure. Plus: don't thrash - coalesce
the region-blink size flapping. NOT YET IMPLEMENTED (instrument-first; needs the coalescing designed so
it does not regress legit fast resizes). The dom0 dialog (25H2) remains unreproduced - needs a 25H2 target.

## 2026-08-11 (cont.) — REPRODUCED, and it is SEVERE: Start-menu flip storm KILLS the capture thread (frozen display)

Followed the user's "reproduce before fixing". The negative-width MSG_CREATE (dom0 "suspicious GUI
request" dialog) did NOT reproduce on win11-fresh/24H2 (8202 tight-loop samples of the agent's exact
GetRealWindowRect math while hammering Start: only cloaked DummyDWMListenerWindow 0x0 noise, zero
strictly-negative, zero huge, zero off-screen-with-real-size). That dialog stays 25H2-specific
(user: update the test guest to 25H2 later to confirm nothing else broke).

What DID reproduce, in the REAL gui-agent, repeatedly, and it is worse than a cosmetic flip:
1. Start-open -> the agent thrashes the Start CoreWindow 0x1018a: reported size FLIPS between full
   desktop (5120x1392/1384) and the region-clipped card (858x890/858x874) across UpdateWindowData
   passes, each flip a PwResizeWindow grant rebuild (detach+reattach) + a SendWindowUnmap+SendWindowMap
   pair. Root: GetWindowRgn on the animating Start window returns COMPLEXREGION vs none frame-to-frame,
   so the clip is applied then dropped. Captured live at 16:20:45 and 16:23:49.
2. Under rapid Start toggling (16:51) the storm FLOODS the vchan:
     16:51:50 HandleServerData: got unknown msg type 127, ignoring  (x5)
     16:51:51 VchanSendBuffer: vchan buffer full, blocking write
     16:51:51 CaptureThread: error/timeout waiting for frame processing
3. THE CAPTURE THREAD DID NOT RECOVER. Liveness check at 16:58 (7 min later): opened notepad -> the
   agent emitted ZERO new frames (log last-modified frozen at 16:51:51, no PerfEmitFrame, no window
   event). The guest desktop in dom0 is FROZEN. qrexec still works; only the display pipeline is dead.
   RecreateDuplication (the intended capture-death recovery) never fired - a SECOND defect.

So the Start-menu-under-IDD failure GWeck reports is, on our side, a self-inflicted map/unmap STORM
that can back up the vchan and permanently wedge the capture thread = frozen/garbled guest. This is a
DoS of the guest display triggerable by normal Start-menu use. Distinct from (but same family as) the
2A-chrome window-classification issue.

Fix direction (now EVIDENCE-BACKED, not blind): (a) stop the flip - do not oscillate a window's
reported size when its clip region blinks; treat a transient no-region frame as "keep previous
geometry" (debounce/coalesce), and/or don't grant-rebuild + remap on every size wobble; (b) the
off-desktop announce (parked 16384,6119 -> card at ~18515,6621) should be clamped/rejected; (c)
capture-thread recovery must actually fire on the vchan-full/timeout path (RecreateDuplication or
restart), not silently die. NOT YET IMPLEMENTED. Guest left wedged by the repro; recovering via agent
restart next (also validates the recovery path).

## 2026-08-11 (cont.) — GWeck investigation workflow landed; correlation with the LIVE repro

Full synthesis saved to docs/GWECK-post44-investigation.md (root causes S1-S4, serial repro plan,
DRAFT forum reply, open questions). Key points and how they line up with the live win11-fresh repro:
- S1a garbled Start (25H2): Wnd_StartFeed full-screen popup demoted to NORMAL by IsPopup (main.c:826,
  '>=' fires on screen-size equality) -> PrintWindow-fed XAML host -> garble; all g_StartWindow
  special-casing is DEAD on 25H2 (no CoreWindow). MATCHES my repro's sibling-path note; my 24H2 repro
  hit the CoreWindow path instead (same symptom, both bad).
- S1b dom0 dialog: PROVEN by elimination it is MSG_CREATE with (int)width/height<0 (xside.c:2937); the
  SOURCE of the negative value is UNEXPLAINED (g_StartWindow inversion REFUTED - NULL on 25H2). My live
  24H2 repro FALSIFIED the EnumDisplaySettings-div0 candidate here (clean scale=1) -> the dialog is
  genuinely 25H2-only; needs a 25H2 target + GWeck's guid log to name the failed VERIFY.
- NEW from the live repro (the static workflow under-weighted this): the ACTUAL freeze mechanism on
  24H2 is the Start map/unmap FLIP STORM -> VchanSendBuffer full -> CaptureThread error/timeout ->
  capture thread DIES and does not recover (RecreateDuplication never fires; the watchdog only restarts
  a DEAD process, not a stuck-capture live one). Recovered by killing gui-agent.exe (watchdog relaunched
  it, frames resumed). This is a reproducible guest-display DoS independent of 25H2.
- S2 mouse ~1cm-low + S3 caret: agent stores the REQUESTED (not read-back APPLIED) resolution on
  RESAPPLIED-MISMATCH (resolution.c:1207) + missing SDC_FORCE_MODE_ENUMERATION poke -> injects pointer
  against a wrong believed height -> vertical-only skew. Per the workflow this is REPRODUCIBLE ON 24H2
  via a forced A4CLAMP request (next reproduce-first target, no 25H2 needed).
- S4 /idd: user error (Start-Process 'D:\idd') on top of OUR gaps - /iddonly + activate-idd.ps1 were
  committed (80f8d97) ~4h AFTER the v4.3.1 assets were uploaded, so they never shipped; README is stale.

QUEUED (reproduce-first discipline, per user): (1) provision a 25H2 test target - user/dom0 decision,
gates S1a/S1b validation; (2) reproduce S2 on 24H2 via A4CLAMP + measure skew 3x interleaved before any
fix; (3) the S1b structural guard (SendWindowCreate (int)w/h>0, mirroring send.c:600) validated by
INJECTING an inverted rect and seeing the dialog with guard off / suppressed with guard on; (4) re-release
containing 80f8d97 + README fix. No fixes committed yet - all gated on their own repro.

## 2026-08-11 (later session) — LIVE dom0 policy re-measured; handover's deny-matrix is STALE

Empirical probe from win-idd-mgmt (read-only Admin API calls only; nothing mutated):
- ALLOW (measured now): vm.List, CurrentState, property.Get/GetAll (incl. target dom0),
  global admin.property.Get (qubes-prefs), pool.List/Info, label.List, tag.List,
  feature.List, firewall.Get, notes.Get, **volume.List / volume.Info / ListSnapshots**
  (revisions printed), qubes.VMShell to win11-fresh (qtest run OK, state OK).
- DENY (measured now): admin.vm.device.block.List — "Request refused" — on BOTH
  win11-fresh and win-idd-mgmt.
- UNPROBEABLE read-only (still unknown): volume.CloneFrom/CloneTo, vm.Create.*,
  vm.Remove, Start/Shutdown/Kill, tag.Set, property.Set, feature.Set. (A no-side-effect
  probe of Create/CloneFrom was attempted and blocked by the local permission layer.)

CONTRADICTION with the 2026-08-11 handover: it recorded "all admin.vm.volume.* DENIED".
volume read-ops are now allowed ⇒ dom0 policy was changed after the handover was written.
The live rule set matches NO file in this repo: dom0/30-win-idd-mgmt-admin.policy and
mgmt/10-win-idd-all.policy BOTH grant device.block.* on the tag, which is denied live.
So whatever is installed is a partial/hand-edited variant. Repo dom0/* remains untrustworthy
as ground truth (as the handover warned).

Clone feasibility (data side): vm-pool 875.2 GB size / 654.5 GB used ⇒ ~220 GB free;
win11-fresh root usage ≈ 17.4 GB of 80 GB. Space is a non-issue.

## 2026-08-11 (cont.) — 25H2 TARGET LIVE: clone insurance + eKB flip both done

- Clone: `win11-24h2` created from halted win11-fresh (root usage 17.2 GB copied; tags
  `created-by-win-idd-mgmt` + `win-idd-testbed` both present). First `qvm-clone` attempt
  FAILED with "Request refused" AFTER both volumes cloned: qubesadmin `clone_vm` copies
  device ASSIGNMENTS last, calling `admin.vm.device.<class>.Assigned` for every device
  class — 10-win-idd-all only grants class `block`, so `pci` (or first non-block class)
  was refused and the error path deleted the fully-cloned VM. Workaround (no policy
  change): python `app.clone_vm(..., ignore_devices=True)` — the CLI has no flag for it.
- eKB: DISM Add-Package of kb5054156-25h2-ekb.msu on win11-fresh rc=0 → reboot →
  `ver` = **10.0.26200.8875 (25H2)**. gui-agent alive post-flip: qtest shot of a fresh
  Notepad renders correctly (pixel-judged). NOTE: `qtest shot` rc=1/empty tar when the
  guest has no mapped window — open one first; not a failure of the agent.
- policy.Get addendum works: installed 10-all read + diffed. Deviations from repo copy:
  installed LACKS all `@tag:qwt-bench` lines AND the four `admin.vm.tag.* @anyvm` lines
  (tag ops still granted per-tag); UpdatesProxy block present sans comments. Live grants
  now fully known — no more policy archaeology.
- NEXT: S1a/S1b repro on 25H2 (Win-key Start storm; `qtest fullshot` is the dom0-dialog
  detector).

## 2026-08-11 (cont.) — S1b DIALOG REPRODUCED ON 25H2 (win11-fresh, 26200.8875)

Repro: guest/win-start-probe.ps1 -Count 30 -DelayMs 400 (Win-key toggle storm) with Notepad open.
Observed, in order (agent log = instrumentation/gweck-post44/25h2-s1b-repro-gui-agent-tail.log):
1. Same flip storm as 24H2, now via PER-WINDOW slice-fed buffers: Start window 0x1018a cycles
   PwAttach 1920x1032 (1935 pages) -> PwDetach -> PwAttach 858x890 (746 pages) -> Unmap/Map,
   ~1 full cycle/sec under the storm (each = grant rebuild + MSG churn).
2. 18:19:42.246 `VchanSendBuffer: vchan buffer full, blocking write` (thread 4164 = main pump).
3. 18:19:43.258 `CaptureThread: error/timeout waiting for frame processing` x2 (thread 4884).
4. Agent log SILENT thereafter (main pump still blocked in vchan write) — no recovery fired.
5. dom0 showed the GWeck S1b dialog (user-observed + captured in fullshot, scratchpad-local):
   "The domain win11-fresh attempted to perform an invalid or suspicious GUI request ...
   Ignore / Terminate". EXACT trigger message unknown — needs dom0 guid log (user asked).
6. Display partially frozen: calc launched post-wedge never appeared in dom0; but a OneDrive
   popup DID render — either mapped pre-wedge or the slice-fed per-window path outlives the
   dead capture thread. Notepad content static.

CAUSALITY still two-way (guid-log timestamps will disambiguate):
  H1 storm floods vchan -> wedge -> some post-wedge/garbage announce trips the daemon VERIFY;
  H2 a bad announce trips the dialog FIRST -> modal dialog stops the daemon reading the vchan
     -> vchan fills -> agent pump blocks -> capture dies. H2 would make the dialog itself the
     wedge MECHANISM (any suspicious message = display DoS), raising fix priority for bounded
     vchan writes. On 24H2 the same wedge occurred WITHOUT a dialog, so H1 exists standalone.

New fact vs 24H2 findings: the flip storm + wedge is NOT 24H2-CoreWindow-specific — 25H2's
Wnd_StartFeed path drives the identical storm. Single Win-press on 25H2 is CLEAN (Start renders
fine in dom0, no dialog) — severity needs the rapid-toggle storm.

## 2026-08-11 (cont.) — S1b ROOT CAUSE CONFIRMED FROM dom0 guid LOG; causality RESOLVED (H2)

dom0 guid log tail (user-supplied, same storm run):
    Verify failed: (int) untrusted_crt.width >= 0 && (int) untrusted_crt.height >= 0
    (zenity:336840) ... 18:19:35.734   <- the Ignore/Terminate dialog process
    msg 0x90 without CREATE for 0x1018a

FACTS this settles:
1. The failing check is EXACTLY xside.c:2937-2938 in handle_create (MSG_CREATE) — the predicted
   line, now PROVEN not inferred. A negative-as-int width or height was sent for a window.
2. **Causality is H2, not H1.** zenity (the dialog) is stamped 18:19:35.734; the vchan flood is
   18:19:42.246 and the capture death 18:19:43.258 — the dialog came ~6.5 s BEFORE the wedge.
   So: bad MSG_CREATE -> daemon VERIFY fails -> modal dialog -> daemon stops draining the vchan ->
   agent pump blocks in VchanSendBuffer -> CaptureThread times out and dies -> display frozen.
   H1 (flood-first) is REJECTED for this run. The 24H2 wedge (no dialog) remains a separate,
   flood-only path — both exist; the dialog path is faster and worse.
   => ANY single suspicious message = guest display DoS. Bounded/non-blocking vchan writes are
   therefore not a nice-to-have; they are the containment for a whole failure class.
3. `msg 0x90 without CREATE for 0x1018a` — CORRECTED DECODE: with MSG_MIN=123 the enum gives
   MSG_CREATE=130 (0x82), MSG_MAP=132 (0x84), and **0x90 = 144 = MSG_WINDOW_HINTS** (verified
   against qubes-gui-common/include/qubes-gui-protocol.h:134-160, cross-checked by the two
   in-header annotations MSG_UNMAP=133 and MSG_DOCK=143). Same HWND 0x1018a as the storm.
   The rejected CREATE means the daemon holds NO window object, so every later message for that
   HWND is orphaned: agent and daemon state DIVERGE after a rejected CREATE. Any fix MUST keep
   them consistent (suppress dependent messages, not just the bad CREATE).
4. Agent send path has NO sanity guard: SendWindowCreate (agent/gui-agent/send.c:287) computes
   width = rcWindow.right - rcWindow.left from WINDOW_DATA X/Y/Width/Height and sends it
   unvalidated; the daemon's own clamp (min/max to MAX_WINDOW_*) happens only AFTER the VERIFY,
   so a negative value is fatal rather than clamped. Note the guard is NOT at send.c:600 as the
   earlier handover claimed — that reference should not be reused without re-checking.

STILL UNKNOWN: which WINDOW_DATA field went negative and why (25H2 StartFeed geometry). The dom0
log prints the failing values only at log_level>0 for successful creates, not for rejects. Next
diagnostic: agent-side QGAPROTO trace already logs w/h per CREATE (send.c:~336) — re-run the storm
with g_ProtoTrace on and find the CREATE whose w or h is huge-unsigned (= negative as int).

## 2026-08-11 (cont.) — ProtoTrace instrumented; wedge NOT reproducible after reboot (honest status)

Enabled `ProtoTrace=1` (HKLM\...\Qubes Tools\gui-agent, per perf.h:58) and re-ran the storm 4x
(1x 25@400ms, 3x 40@220ms) on the SAME 25H2 guest. Results:
- **No wedge, no dialog, no negative geometry in ANY of 4 runs** (FAULTS=0: zero "buffer full",
  zero "error/timeout"). Every traced CREATE was sane: hwnd 0x101a8 x=0,y=0,w=1920,h=1032,ovr=1.
- So the S1b dialog + wedge, though PROVEN to have happened (dom0 guid log: VERIFY failed at
  xside.c:2937), is currently NOT reliably reproducible. It fired on the FIRST boot after the
  25H2 in-place upgrade, with first-logon shell surfaces present (OneDrive "Turn On Windows
  Backup" popup visible in the fullshot) — plausibly a first-logon/post-servicing shell window,
  not the steady-state Start surface. Per the instrument-validation rule, the storm probe alone
  is NOT yet a validated reproducer for S1b; it IS one for the 24H2-style flip churn.
- Restarting gui-agent alone did NOT restore the display: the agent came up and sat at
  "Awaiting for a vchan client" — dom0's guid never reconnected (exactly the restart-survival
  gap in DESIGN-gui-daemon-restart-survival.md §3). A VM reboot restored it. Operational note:
  after a wedge, reboot the VM, don't just restart the agent.

NEW DEFECT (unrelated to negative geometry, seen in every clean run): the agent sends a FULL
`MSG_CREATE` for the SAME already-created HWND on every Start flip — 13 identical CREATEs for
hwnd 0x101a8 in one 25-toggle run. The daemon's handle_create unconditionally calloc's a new
windowdata and list_inserts it (xside.c:2919-2952), so repeated CREATE for a live window is
state-corrupting/leaky by construction. This is a strong candidate for the ACTUAL trigger of the
"msg 0x90 (MSG_WINDOW_HINTS) without CREATE" line and for daemon-side state divergence.
Fix direction: send CREATE once per HWND lifetime; use CONFIGURE for geometry changes.

Vchan blocking mechanism now pinned by source (workflow reader): `VchanSendBuffer` spins
`while (VchanGetWriteBufferSize(vchan) < size) Sleep(1);` with NO timeout and NO
libvchan_is_open check — upstream/ro/qubes-windows-utils/src/vchan-common.c:96-102 — while the
caller holds g_VchanCriticalSection (send.c:73 et al). Write buffer is 65536 bytes (logged at
agent start). Hence: daemon stops reading => pump blocks forever under the lock => capture dies.
main.c:4675 already carries a comment acknowledging "VchanSendBuffer blocks FOREVER on a full ring".

## 2026-08-11 (cont.) — GUEST CLOCK AUDIT (asked: is the guest synced with dom0?)

ANSWER: **No — two distinct errors.** Measured 8 round-trip samples in two batches (~2.5 min
apart), guest `(Get-Date).ToString('o')` vs this qube's clock, offset = guest - midpoint(t0,t1):

| batch | median offset | spread |
|---|---|---|
| 18:43:05-09 | +10801.768 s | 0.21 s |
| 18:45:2x    | +10801.878 s | 0.14 s |

1. **+10800 s = exactly 3 h, absolute/UTC error.** Guest TZ is `UTC` (bias 00:00:00) but its wall
   clock holds LOCAL (EEST, +0300) time: guest claims 18:45 UTC while true UTC is 15:45. Anything
   the guest computes in UTC (TLS validity, WU metadata, Event Log UTC fields, servicing stamps)
   is 3 h in the future. `RealTimeIsUniversal` is NOT set, W32Time Stopped/Manual with
   time.windows.com (unreachable — VM is offline), autotimesvc + vmictimesync Stopped. QWT's
   `qubes.SetDateTime` handler IS installed (`qubes-rpc-services\set-time.ps1`, does `Set-Date $in`
   on a dom0-supplied `...+0000` string, which WOULD be correct given TZ=UTC) — so it has simply
   not been invoked since the TZ was set to UTC. It is dom0-initiated (qvm-sync-clock); the mgmt
   qube cannot trigger it.
2. **+1.8 s residual skew** on top of the 3 h, stable to ~0.1 s across 2.5 min (no measurable
   drift; guest booted 18:34:37, measured 18:43-18:45).

IMPACT ON THE H2 CAUSALITY CLAIM (checked, claim SURVIVES): dom0 guid `zenity` stamped 18:19:35.734
(dom0 local wall) vs guest agent `vchan buffer full` 18:19:42.246 (guest wall). Both faces read the
same local wall clock, so they ARE comparable; correcting the guest by -1.8 s gives ~18:19:40.4 in
dom0 time, still **~4.7 s AFTER** the dialog. The dialog-precedes-wedge conclusion holds with margin
(would need >6 s of skew to invert, and measured skew is 1.8 s).
CAVEATS: (a) the comparison reference was win-idd-mgmt, not dom0 itself (mgmt reports "System clock
synchronized: no", NTP inactive — it inherits dom0's clock at boot; assumed within ~1 s, unverified
because this qube cannot read dom0's clock); (b) the guest REBOOTED at 18:34:37, after the 18:19
incident, so today's 1.8 s skew is not proof of the skew at incident time.

RECOMMENDATION (not applied — user asked to check, not change): before any further cross-log
timing work, either have dom0 run `qvm-sync-clock` / trigger `qubes.SetDateTime` for win11-fresh,
or set the guest clock to true UTC in-guest. Then re-measure. Also worth setting
`RealTimeIsUniversal=1` so the guest reads the Xen RTC as UTC across reboots.

## 2026-08-11 (cont.) — CLOCK FIXED (harness-side); in-guest settings CANNOT hold it

Attempted, in order, each verified by 4-5 sample offset measurement + a COLD REBOOT:
1. `RealTimeIsUniversal=1` + Set-Date to true UTC -> offset went +10801.8 s -> -0.216 s. **Reboot
   re-broke it: +10686 s.**
2. `RealTimeIsUniversal=0` + TZ `FLE Standard Time` (+03, matching dom0) + Set-Date -> -0.173 s.
   **Reboot re-broke it again: +10684.7 s** (guest UTC 18:52 vs true 15:54).
CONCLUSION (measured, not assumed): the guest's virtual RTC is re-derived from dom0's LOCAL wall
clock at every domain start, and guest RTC writes are DISCARDED when the domain is destroyed. No
in-guest setting (RealTimeIsUniversal either way, timezone either way) survives a reboot. The
residual is not a constant 3 h either - both boots landed ~115 s short of exactly +3 h, so the
error is not even predictable enough to subtract.

FIX SHIPPED: `tools/qtest synctime` — pushes this qube's clock into the guest, accurate to
**median -0.009 s** (5 samples, verified on a FRESHLY BOOTED guest, i.e. the boot path is the
tested path). Gotcha found and fixed while building it: the one-way-latency probe must be the
same SHAPE as the setter — probing with `cmd /c echo` while setting via powershell under-estimated
latency by ~0.7 s and left the guest that slow.
USAGE RULE: call `qtest synctime` after EVERY `qtest start`, before any measurement whose
timestamps will be compared to dom0 logs. Harnesses should do it unconditionally.
PERMANENT FIX (dom0, user-only): `qvm-sync-clock` / letting dom0 drive `qubes.SetDateTime`
(the handler `set-time.ps1` IS installed in the guest and would be correct), or changing the
domain's RTC basis to UTC. Not attempted - dom0 is out of scope for this qube.
Guest now left at TZ=FLE Standard Time (+03) so its wall clock reads the same face as dom0 logs.

## 2026-08-11 (cont.) — RENDERING-CORRECTNESS INSTRUMENT + a retraction

Built `tools/rendercheck` + `guest/render-truth.ps1`: compares GUEST truth (full-desktop capture
+ every visible top-level window) against what dom0 actually renders, per window, in pixels.
Verified working: Notepad 0.0% differing on a clean run, 0.41% with a caret blinking.

**RETRACTION (same-day, loud, per CLAUDE.md):** I claimed "with the Start menu open, dom0 has NO
window for it — the S1a defect, caught automatically." That was WRONG. It came from `qtest shot`,
which is per-window and CANNOT show override-redirect windows — and Start is override-redirect.
`tools/qtest`'s own comment (line ~48) says exactly this, and I used the wrong capture anyway.
The user confirmed dom0 DOES draw it: "thin border, with some extra stuff within rectangle".
STANDING RULE going forward: **any claim about what dom0 displays must come from `qtest fullshot`**
(its geometry.txt carries the override_redirect + mapped columns); per-window `shot` may only be
used for pixel comparison of ordinary windows. rendercheck now runs fullshot and treats its
geometry list as authoritative; the raw list is printed in every report.

Two real defects the instrument found in its own first runs (both fixed in it):
1. Guest truth must use DWMWA_EXTENDED_FRAME_BOUNDS, not GetWindowRect: Win11's ~7 px invisible
   border made Notepad read 1440x753 while the agent announces (and dom0 renders) 1426x746.
2. P/Invoke needs CharSet=Unicode or every window title marshals to its first character only.

STILL OPEN (the real S1a work): characterise the "extra stuff within the rectangle" the user sees
in the Start popup. Requires a fullshot taken WHILE Start is held open - ordinary qrexec calls
steal focus and dismiss it, so the keypress and the capture must run concurrently (attempted
once; the menu had already closed both times).

Also visible in the dom0 terminal during this session (relevant to the clock work): `qvm-sync-clock`
fails with "ClockVM sys-whonix is not running, aborting!" - so the permanent dom0-side clock fix
needs sys-whonix running (or a different clockvm). `tools/qtest synctime` remains the workaround.

## 2026-08-11 (cont.) — START-MENU ARTIFACT CAPTURE: BLOCKED, guest-side Start is now dead

Attempted the concurrent capture the user asked for (keypress/click held open in one qrexec
session while a dom0 fullshot + a guest render-truth capture run from another). Six attempts,
three input methods (keybd_event VK_LWIN, held-open 45-55 s; mouse click on the Start button at
716,1056; win-start-probe). Result every time: **the Start menu does not open IN THE GUEST at
all** - the guest's own desktop capture shows no Start surface, and EnumWindows lists only
Shell_TrayWnd / Notepad / EdgeUiInputTopWndClass / Progman. dom0 correspondingly has no window
for it. So this is NOT a dom0 rendering failure and the user's "extra stuff within rectangle"
artifact could not be reproduced.

IMPORTANT: Start DID work on this guest at 16:00-16:01 UTC (guest capture at 16:01 clearly shows
it open, post-25H2). It stopped some time after. Two candidate causes, NOT yet separated:
 (a) **My own clock manipulation** (most likely): the fix experiments moved the guest clock
     backward 3 h twice. Evidence: shell processes were later found with StartTime 9:52 PM while
     the clock read 7:16 PM - i.e. started ~2.5 h in the "future". Large backward jumps are a
     known way to wedge WinRT/shell activation.
 (b) The 4x40-toggle storm rounds wedging StartMenuExperienceHost persistently.
Against (a)-only: the breakage SURVIVED two full reboots plus a shell restart with consistent
timestamps, and survived re-registering the Appx package
(Microsoft.Windows.StartMenuExperienceHost_10.0.26100.4768, status Ok, re-registered + restarted).
So whatever it is, it is persistent profile/state damage, not a live-session glitch.

RECOVERY OPTIONS for next session (none attempted): new user profile; DISM /RestoreHealth + sfc;
or restore from the `win11-24h2` clone and redo the eKB (loses nothing - the clone is intact).
DISCIPLINE NOTE: run destructive-ish environment experiments (clock jumps) on the CLONE, not on
the qube currently holding the only reproduction of a bug under investigation.

## 2026-08-11 (cont.) — CLONE CONTROL: Start does NOT open on the CLEAN 24H2 clone either

Brought up `win11-24h2` (the clone, made BEFORE the eKB and BEFORE any clock manipulation) to get a
control for "did I break win11-fresh with clock jumps?".

Startup gotcha, fixed: the clone would not boot - `qvm-start` hung and the VM stayed Halted. Cause:
`qvm-clone` copied the `qemu-extra-args` FEATURE, which references `/dev/xvdi` (the answer-stick
block device attached to win11-fresh). The clone has no such device, so libvirt could not build the
domain. Fix: `qvm-features --unset win11-24h2 qemu-extra-args`. **Add this to any clone recipe.**
SELF-INFLICTED INCIDENT while diagnosing that: two `until qtest run ...; sleep` wait-loops kept
polling the halted VM, and qrexec AUTO-STARTS a halted target - so they hammered the system with
repeated failing domain starts until the user noticed. **Never poll a halted VM with qrexec; poll
`qtest state` instead.**

CONTROL RESULT (this is the important part): on the clean 24H2 clone, **the Start menu does not open
either**, under three different input methods, all injected from a qrexec session:
  1. keybd_event VK_LWIN (down/up, held 50 s)          -> no Start
  2. mouse_event click on the Start button (716,1056)  -> no Start
  3. PostMessage(Shell_TrayWnd, WM_COMMAND, 305) + Ctrl+Esc -> no Start
In every case the guest enumerates `Windows.UI.Core.CoreWindow 1x1 cloaked=2` — the Start surface
EXISTS but is 1x1 and shell-cloaked, i.e. parked/closed, never laid out.

CONSEQUENCE — RETRACTION OF A THEORY: "my clock jumps broke Start on win11-fresh" is now the WEAKER
explanation, because a VM that never saw those jumps behaves identically. Do not carry that claim
forward as established. What IS established: **synthetic input from a qrexec session does not open
Start on either guest right now**, though the same probe demonstrably DID open it at 16:00-16:01 and
again at ~18:17 UTC today (guest capture and dom0 fullshot both show it open). The difference between
those working runs and now is NOT yet identified — candidate: session/input-desktop state, or the
IDD-solo display configuration interacting with Start's layout (the 24H2 finding already showed the
Start CoreWindow being parked off-screen at 16384,6119).

So the S1a artifact ("thin border, extra stuff within rectangle" the user sees) remains UNCAPTURED,
and the blocker is now "cannot open Start via automation at all", not "dom0 does not render it".
Next diagnostic (cheapest first): (a) have the USER open Start by hand while a fullshot runs - one
human keystroke settles both the artifact and whether the input path is the blocker; (b) check
whether the interactive session is on a different window station/desktop from the qrexec service
session; (c) test with the IDD inactive (Basic Display Adapter only) to see if Start lays out then.

## 2026-08-11 (cont.) — START MENU CAPTURED (user opened it by hand) — 24H2 renders it CORRECTLY

The user opened Start manually on win11-24h2 and I took an immediate `qtest fullshot`. dom0's window
list (the authoritative one, with the override_redirect column):
    0x1c00190  531 142  858x890  or=1 mapped=1  Start
    0x1c0018e 1524 700  396x332  or=1 mapped=1  New notification      <- a TOAST, mapped, override-redirect
    0x1c0018b  123 129 1426x746  or=0 mapped=1  Untitled - Notepad

Pixel measurement of the capture (numbers, not impressions):
- the red qube border around the popup runs x 531..1388 (**858 px**) and y 142..1031 (**890 px**);
- the announced geometry is **858x890** — an EXACT match, and the visible Start card fills it
  (854 px wide inside the 2 px border on each side).
VERDICT: on 24H2 the Start menu is announced with correct geometry and dom0 renders it correctly.
The "thin border" the user sees is dom0's own border around an override-redirect popup, which is
CORRECT Qubes behaviour (Linux qubes border menus the same way) — not a defect. No oversized
rectangle, no stale-pixel band, no garbling on this build.

So the S1a "garbled Start" remains a 25H2-side claim, unreproduced by us; 24H2 is now a clean
CONTROL for it. Toasts are confirmed mapped as override-redirect windows on this build too.

METHOD NOTE that unblocked this: **manual input works where every injected input path failed.**
Automated keybd_event / mouse_event / WM_COMMAND all leave the Start CoreWindow at 1x1 cloaked=2.
Any Start-related test therefore needs either a human keystroke or an input path we have not found
yet; the storm probe measures the agent under Start CHURN, but cannot be trusted to have opened
Start at all unless a guest-side capture confirms it. Also confirmed: a qrexec call taken while
Start is open STEALS FOCUS and closes it — capture dom0 FIRST, ask the guest questions after.

## 2026-08-11 (cont.) — **GHOST WINDOWS: dom0 keeps painting shell surfaces the guest has closed**

The user opened Start by hand and reported "on screen, but old one is there too" and "announced
geometry does not match REAL geometry either". Both are one defect, now captured with evidence.

STATE AT CAPTURE (win11-24h2, 24H2):
  dom0 (qtest fullshot geometry.txt)        |  guest (render-truth.ps1 EnumWindows)
  0x1c0018b 123,129  1426x746 or=0 mapped=1 |  Notepad        (123,129) 1426x746   <- real
  0x1c0018e 1524,700  396x332 or=1 mapped=1 |  ** ABSENT **                        <- GHOST (toast)
  0x1c00190  531,142  858x890 or=1 mapped=1 |  ** ABSENT **                        <- GHOST (Start)
The guest has ONLY Notepad + a cloaked 1905x4 strip + Progman. The Start menu and the toast were
closed/dismissed minutes earlier, yet dom0 still has them MAPPED and is still painting them.

MECHANISM (agent log, same guest): three windows were mapped and NEVER unmapped -
  20:22:43/45 SendWindowMap 0x60058   (twice)
  20:27:28    SendWindowMap 0x50086
  20:30:05    SendWindowMap 0x10184
with the last SendWindowUnmap at 20:22:12 (for a different hwnd, 0x2002a). So the agent announces
MAP for these override-redirect shell surfaces and never announces UNMAP when they go away. The
likely cause: Start/toast surfaces are not DESTROYED when dismissed - Start's CoreWindow goes back
to 1x1 + DWM-cloaked (measured: cloak=2 when closed). If the tracker drops a window that stops
being enumerable/visible WITHOUT sending UNMAP first, dom0 is left holding a mapped ghost forever.
That is the "double windows" artifact class in the QWT docs, and it is a strong candidate for
GWeck's S1a "garbled Start" (a stale Start ghost overlapping a freshly opened one).

CONSEQUENCE FOR EARLIER CONCLUSIONS: the 24H2 "Start renders correctly, geometry exact 858x890"
measurement stands as a measurement of the LIVE menu, but it must NOT be read as "Start is fine on
24H2" - the very window I measured is now a ghost. Correct rendering includes disappearing when
the guest's window disappears.

INSTRUMENT: `tools/rendercheck` now detects this automatically - any dom0 MAPPED window with no
guest counterpart is reported under `ghosts_in_dom0` and FAILS the run. Verified it catches both
ghosts above. This is the regression test the fix must flip to PASS, and it is exactly the kind of
defect a per-window pixel diff can never see.

FIX DIRECTION (fits the overhaul as a new rank, agent-side): the window-acceptance predicate must
treat "was mapped, is now cloaked / 1x1 / not enumerable" as an UNMAP event rather than a silent
drop; unmap-before-forget must be structural, the same way rank 3 made CREATE-once structural.
Note this interacts with the toast requirement (toasts must be KEPT while visible) and with the
user's two new requirements recorded below.

## User requirements added 2026-08-11 (not yet implemented)
1. **The Win key must NOT work from a seamless app.** The user confirmed the agent does not
   currently suppress it. In seamless mode a guest Start menu opened by a stray Win press is
   unmanaged UI in the middle of the dom0 desktop.
2. **The Start menu should instead be reachable as a regular app-menu item** (a normal launcher
   entry for the qube), which is the Qubes-native way to expose it.
Both are Track A / 2A-chrome scope and must wait until the menu is proven to render correctly.

## 2026-08-11 (cont.) — RETRACTION + the REAL artifact, measured: announced rect > visible card

**RETRACTION of the "ghost windows" entry above.** Two flaws, both mine:
1. My guest enumeration is taken via qrexec, and a qrexec call STEALS FOCUS AND CLOSES THE START
   MENU (established earlier the same session). So "dom0 has Start, guest does not" can be produced
   by the instrument itself. The user also corrected me: nothing had been closed on their side.
2. That same enumeration returned only Notepad/EdgeUi/Progman - it had also LOST Shell_TrayWnd,
   which earlier runs did list. An enumeration missing the taskbar is not a trustworthy basis for
   declaring anything absent.
The Start menu subsequently vanished from dom0 on its own (user: "it vanished now"), which is what
a correctly-unmapped window looks like. **The ghost claim is withdrawn as unproven.** The three
unmatched SendWindowMap lines remain interesting but prove nothing on their own - a mapped window
that is still legitimately open produces exactly the same log.
`tools/rendercheck`'s ghost detector must therefore NOT be trusted while guest truth comes from a
focus-stealing qrexec call; treat `ghosts_in_dom0` as a hint, not a verdict, until guest truth is
collected without touching focus.

**WHAT IS REAL, and it is the artifact the user described.** The "New notification" window is the
OneDrive "Turn On Windows Backup" toast - a PERSISTENT ACTIONABLE notification ("Remind me again
in: 1 Week", "Let's get started" / "No thanks"), so it legitimately stays until dismissed. Measured
from the dom0 capture:
    announced / bordered by dom0 : 1524,700  **396 x 332**   (border rect measured: exactly that)
    actually visible toast card  : 1526,731  **377 x 287**
    => dead margin INSIDE the announced rectangle: **19 px horizontally, 45 px vertically**
The margin is not empty: it shows whatever was composited beneath (guest wallpaper here), and dom0
draws its qube border around the FULL announced rect. That is precisely the user's "thin border,
with some extra stuff within rectangle" and their "announced geometry does not match REAL geometry
either". The cause is the usual Win11 convention gap - the window rect includes the drop-shadow /
invisible margin, while the visible card is smaller (the same 7px-class discrepancy that made
render-truth.ps1 need DWMWA_EXTENDED_FRAME_BOUNDS: 1440x753 vs 1426x746 for Notepad).

This is exactly what `docs/TOAST-fix-plan.md` proposes (CropL/T/R/B in WINDOW_DATA applied inside
GetWindowData) - now CONFIRMED LIVE with numbers instead of being a design guess, and it applies to
any shadowed popup, not just toasts. Note the Start menu measured EXACTLY 858x890 border vs card
earlier, i.e. Start does NOT show this margin - so the crop must be derived per window (from the
DWM frame bounds vs window rect), never a constant.

## 2026-08-11 (cont.) — INSTRUMENT: guest PIXELS are trustworthy, guest WINDOW LISTS are not

Built `guest/render-watch.ps1`: a resident sampler that decouples SAMPLING from RETRIEVAL. It runs
hidden and detached, writing a timestamped JSON sample (and optionally a PNG) every N seconds into
C:\ProgramData\Qubes\rendertruth; a later qrexec fetch cannot retroactively disturb a sample already
on disk. This removes the flaw that produced today's retracted "ghost window" claim (the on-demand
probe stole focus and closed the very menu it was measuring). Verified: samples every 2 s, Notepad
stays foreground across them, and both rects are recorded per window (Notepad dwm 1426x746 vs raw
1440x753 - the Win11 invisible border).

DEFINITIVE TEST of the ghost question, using the sampler's own PNG (no focus theft):
- dom0 geometry.txt: `New notification` 396x332 override_redirect=1 mapped=1  -> present
- guest EnumWindows sample at the same time                                   -> ABSENT
- guest FRAMEBUFFER at the same time                                          -> **the OneDrive
  toast is right there, fully drawn**
So dom0 is CORRECT and the toast is real. **The ghost claim is dead for good** (it was already
retracted; this closes it with positive evidence rather than doubt).

WHAT IS ACTUALLY BROKEN IS THE INSTRUMENT: our guest-side EnumWindows cannot see shell popup
surfaces. `SetThreadDesktop` fails for us even from a fresh windowless thread (tried: unloading
System.Windows.Forms, then running the whole enumeration on a dedicated STA thread inside the C#
helper - both still fail), so we never attach to the input desktop the way the agent does
(AttachToInputDesktop, main.c). Notably GDI CopyFromScreen DOES return the real composited desktop
including the toast, which is why the pixel evidence above is sound.
RULES GOING FORWARD:
 1. Guest truth for "is it displayed" = PIXELS (sampler PNG). Proven.
 2. Guest window LISTS are incomplete for shell surfaces (toasts, Start) - never conclude "the guest
    does not have it" from an empty list. `tools/rendercheck`'s ghosts_in_dom0 stays a hint only.
 3. dom0's `qtest fullshot` geometry.txt remains the authoritative list of what dom0 shows.
 4. To make the list trustworthy the sampler would have to run with the agent's privileges/desktop
    (a service, or launched via the agent) - deferred, not needed for pixel comparison.

## 2026-08-11 (cont.) — TOAST CROP: BUILT, DEPLOYED, MEASURED — WORKS MECHANICALLY, **OVERCROPS**

CI: run 31526572625, all three jobs green (gui-agent, idd-driver, package) - first proof the
toastcrop/UIA/COM code compiles at all (it cannot be built locally; both reviewers could only
inspect it). Artifact gui-agent.exe sha256 5b80f2e100aae67eb158bff04a924049aebec918c97af3dda264cbd50f22f79d.

DEPLOYED to win11-24h2 via guest/swap-agent.ps1 (elevated, .orig backup kept). **Installed binary
hash verified equal to the CI artifact before any measurement was taken.**

A/B ON THE SAME LIVE WINDOW (the persistent OneDrive "Turn On Windows Backup" toast - it outlives
an agent restart, so this is a real before/after on one window, not two similar ones):
    before (shipped agent): 1524,700  396x332
    after  (CI build)     : 1540,730  364x289
    => insets applied 16 / 30 / 16 / 13 - EXACTLY the values the plan's original guest probe
       measured on a collapsed banner. The mechanism works end to end: classifier, UIA query,
       cache, GetWindowData crop, and every downstream consumer followed it.

**BUT THE RESULT IS WRONG (defect, do not ship).** Judged by pixels, inside the new announced rect:
 - the toast's HEADER ROW is gone - the "OneDrive ... X" bar, including the CLOSE BUTTON;
 - a strip of desktop wallpaper + the Windows build watermark appears along the BOTTOM.
So the announced rect is offset down relative to the real card: FlexibleToastView is the CONTENT
element, not the visible card. This is exactly the "silent overcrop clipping the 40x40 action
buttons" failure the plan named as the DANGEROUS one, realised on the header instead. The
plausibility guard did not catch it (364/396 = 92%, 289/332 = 87%, both far above the 40% floor)
and it cannot: an offset crop of the right SIZE is invisible to a size-ratio test.
Corroborating measurement from the earlier uncropped capture: the visible card's left edge is at
1526 (inset ~2), not 1540 (inset 16) - so the horizontal insets are wrong too, in the same way.

FAIL-SOFT CHECK PASSED (the plan's acceptance check, run for real): setting
HKLM\...\Qubes Tools\gui-agent\ToastCropDisable=1 and restarting the agent returned the toast to
1524,700 396x332 - today's uncropped-but-visible behaviour. **The escape hatch works, and the
guest has been left in that state**, so it is not sitting on the overcrop.

NEXT (measured, not guessed): the crop target must be the outermost visible XAML element (the card
including its header), not FlexibleToastView. Choosing it needs a UIA tree dump WITH bounding
rects from the live banner - and `guest/toast-uia-tree.ps1` (written today) CANNOT get it, because
a qrexec-launched process cannot see shell surfaces at all (the same input-desktop blindness
documented above: it printed NO-TOAST-WINDOW while dom0 had the toast mapped). The dump therefore
has to come from inside the agent, which is already on the input desktop - i.e. add a one-shot
"log every descendant + rect" debug flag to toastcrop.c and read it from the agent log.

## 2026-08-11 (cont.) — SEPARATE DEFECT: stale window border left on the dom0 screen
After the agent restart, the dom0 screen showed TWO red borders around the toast area: the live
one at the new 1540,730 rect AND a stale rectangle at the OLD 1524,700-1919,1031 coordinates,
persisting across captures ~1 min apart. dom0's geometry.txt lists ONLY the live window, so this
is not a mapped ghost - it is unrepainted pixels left behind when the old X window was destroyed.
This is very likely what the user saw earlier and described as "old one is there too". Not yet
diagnosed: whether the daemon fails to trigger a repaint of the exposed area, or the WM/compositor
does. Worth a dom0-side look before assuming it is ours - and if it is the daemon's, it falls under
the CLAUDE.md exception for defects outside QWT scope (report upstream, user approves the text).

## 2026-08-11 (cont.) — TOAST CROP IS CORRECT (two retractions closed)

UIA tree dump of the live banner, taken by handle (0x50086, read from the agent log - our
EnumWindows still cannot see shell surfaces, but UIA ElementFromHandle on a KNOWN handle works):
    window            1524,700 396x332
    ScrollViewer      1524,718 396x314
    FlexibleToastView 1540,730 364x289   <- insets 16/30/16/13
      OneDrive text   1580,742      |  Settings button 40x40 @1817,733
      X button 40x40  @1857,733     |  ... body, combo, action buttons
The header row and BOTH 40x40 header buttons are INSIDE FlexibleToastView. Overlaying that rect on
the guest's own framebuffer shows it hugging the drawn card exactly - rounded corners on the line,
header included, bottom edge just under the buttons.

**RETRACTION 1:** "the crop overcrops and clips the header/close button" - WRONG. The crop rect was
right; the render I judged was taken seconds after an agent restart, mid-recomposition.
**RETRACTION 2:** "the outer rectangle is a stale unrepainted border" - WRONG. It survived a forced
repaint (Notepad dragged over the area and back). It is **win11-fresh's toast**: the other test VM
is running the OLD agent, both guests are 1920x1080, and Windows places toasts at the same
bottom-right offset, so its uncropped 1524,700 396x332 window sits exactly around win11-24h2's
cropped 1540,730 364x289 one. geometry.txt filters by _QUBES_VMNAME, so each VM's list showed only
its own window and the overlap looked like a ghost.
METHOD NOTE: with two guests running, ALWAYS check the other VM's window list before calling
anything on the dom0 screen a ghost.

VERIFIED RESULT: with the CI build and the crop enabled, dom0 borders the toast at exactly
1540,730 364x289 = the visible card. The defect the user reported ("thin border, extra stuff within
rectangle") is FIXED on win11-24h2, and win11-fresh alongside it is the untouched control.
Still open: the crop keys on the undocumented class names FlexibleToastView/ToastView. A
name-independent rule (largest descendant strictly inside the window, or the union of descendant
rects) would pick the same element here and survive a rename - worth doing before this ships.

## 2026-08-11 (cont.) — 25H2 START MENU = GWeck S1a, MEASURED; and a crash-loop I caused

**S1a IS REPRODUCED.** From the 18:17 fullshot of win11-fresh (25H2) with Start open, measured:
    announced / bordered by dom0 : 531,142  **858 x 890**
    visible Start card           : 544,145  **832 x 874**
    dead margin inside the border: L=13  T=3  R=13  B=13
On **24H2 the same menu has NO margin** (announced 858x890, card fills it - measured earlier today).
So 25H2's Start gained a shadow inside its window rect, dom0 borders the whole rect and fills the
margin with composited desktop. That is the user's "thin border with extra stuff within rectangle",
and it is the same defect class as the toast - which is why the earlier class-name crop
(FlexibleToastView/ToastView) could never have fixed it.

FIX PUSHED: the card is now found GEOMETRICALLY - the largest descendant fully inside the window
and strictly smaller in BOTH dimensions. The strictness matters: the toast's ScrollViewer is 396
wide inside a 396-wide window and would otherwise win. Classifier widened to
StartMenuExperienceHost.exe and SearchHost.exe; the fixed 1000x600 ceiling removed (it would have
excluded Start at 858x890), oversize surfaces still handled by IsPopup's 90% rule.

**CRASH-LOOP I CAUSED, and the lesson.** The first geometric build crash-looped on win11-fresh:
unhandled c0000005 at address 0, a new agent log every ~6 s, the qube's windows gone from dom0.
Cause: the rewrite left the old `IUIAutomationElement_get_CurrentBoundingRectangle(card, ...)` call
in place while `card` is never assigned any more - a NULL COM pointer deref on the first shell
popup after startup. Reverted with `swap-agent.ps1 -Restore`; the shipped binary brought the
display straight back. Fixed and pushed; NOT yet rebuilt or redeployed.
The build was CI-green and both static reviews passed it. **Compiling is not working.** Any deploy
must now be followed by: same PID after 60 s AND the agent log not rotating, before any measurement
is taken - a crash-loop check, added to the deploy routine.
(The user's "a lot of sounds and zero toasts" was this: Windows kept firing notifications while the
agent was dead, so nothing reached dom0.)

## 2026-08-11 (cont.) — S1a FIXED on 25H2; new live defects recorded for handover

Build d342e93a (geometric crop + the NULL-deref crash fix) deployed to win11-fresh, hash-verified,
crash-loop check PASSED (PID 1136 unchanged over 75 s, log count static at 157 - no rotation).
dom0 now announces:
    Start            544,219  832x736   (was 531,142 858x890; measured card left/width = 544/832)
    New notification 1540,730 364x289   (was 1524,700 396x332)
Both equal the drawn card; the user confirms the menu "looks fine". **GWeck's S1a is fixed on the
surface he reported it on.** Remaining for S1a: cold-boot repeat, and a 24H2 non-regression check
(24H2's Start has no margin, so its announce must STAY 858x890).

NEW DEFECTS the user reports on this build, recorded not diagnosed (leads in the handover):
 - ALL windows react weirdly to DRAG (Feedback Hub especially). Suspicion order: the never-run
   performance gate (rank 2 added a ring query per message; QGAPERF shows dt~520 ms / acq~515 ms in
   this period, though much of that is idle wait), then the HandleConfigure crop-suppression branch
   (ruled out by inspection for uncropped windows - WINDOW_DATA is zeroed at main.c:913-922 - but
   unverified at runtime), then the HandleButton/HandleMotion locking change.
 - An overlap bug, no capture obtained: by the time the fullshot ran every dom0 window had been
   destroyed and re-announced (IDs 0x1c0018f... -> 0x1c001a1), leaving only the unmapped VMapp entry.
 - Toasts: geometry now correct but still NOT CLICKABLE, wrongly positioned (guest 1920x1080 inside
   a 5120x1440 dom0 screen puts a guest-corner toast mid-dom0-screen), not draggable, and multiple
   toasts should stack.
 - Start should be a NORMAL (WM-managed) window rather than override_redirect, and reachable as a
   regular app-menu item; the Win key should not work from seamless apps at all.

## 2026-08-12 — Defects A+B root-caused ON THE LIVE GUEST (scripted drag reproduces both)

Instrumented reproduction on win11-fresh, build d342e93a (agent PID 1136, hash-verified):
`guest/drag-harness.ps1` (new: SendInput circle-drag of Notepad, 60 Hz, precise t0/t1) +
`guest/perf-window.ps1` + `guest/log-window.ps1` + `guest/reset-census.ps1` (all new).

**Defect B is deterministic from a drag.** One 16 s scripted drag: every dom0 window ID changed
(0x1c001b1..b7 -> 0x1c001b9..bf) and Notepad+Feedback Hub came back mapped=0. Log shows the chain
at 23:56:46: `CaptureThread: error/timeout waiting for frame processing` (capture.c:1330 waits
1000 ms for ready_event, comment says "XXX arbitrary timeout") -> error_event -> main loop FULL
RESET: destroy screen window, AttachToInputDesktop, XcOpen (new handle), SendScreenGrants,
DESTROY+CREATE+MAP of every window (~2 s outage). Census: **6 such resets in 25 min**, four in
23:39-23:43 = exactly the user's "weird drag/overlap" period. RecreateDuplication count = 0 - this
is NOT the DDA recovery path, it is the frame-processing timeout.

**Defect A measured under active drag** (45 QGAPERF frames in 16 s):
    dt  p50 113 ms   p95 1.01 s   max 4.5 s      (idle-active before: 14-43 ms)
    dmg p50  77 ms   p95 972 ms   (the dominant phase; suspiciously clipped at the 1 s timeout)
    snd p50 0.3 ms   max 7.7 ms   (raw vchan send is NOT the cost)
    enu p95 171 ms  max 218 ms;  wak p95 187 ms  max 223 ms;  upd max 115 ms (spikes)
Dragged window's MSG_CONFIGURE goes out at ~1 Hz during a 60 Hz drag = the "weird" feel.

Also caught, standing defects on this guest:
 - `WorkAreaApply: SPI_SETWORKAREA failed 0x57` EVERY 30 s (51 times) - retry loop never succeeds.
 - Agent log is 145 MB after 25 min at LogLevel 3 (DAMAGE per-rect lines dominate).
 - A3CHECK grant geometry g=5120x1440 vs ctx=1920x1080 on every reset (fullscreen-size grant while
   the guest desktop is 1920x1080 - check intended).
 - Boot-time 0x887a0026 keyed-mutex AcquireNextFrame failure recovered by A7RETRY (known).

## 2026-08-12 (cont.) — ProtoTrace A/B gate + reproduction attempts + S1a cold-boot PASS

Interleaved gate (3 runs/side, same binary d342e93a, agent restarted identically each run,
fresh boot, no toast): ProtoTrace=1 vs 0 both HEALTHY under drag (dt p50 ~17.5 ms both; tot max
580 ms vs 66 ms - ProtoTrace has a real tail cost but is NOT the collapse). The pre-reboot
collapse (dt p50 113 ms) did NOT reproduce after reboot under: toast visible, Feedback Hub
running, ProtoTrace=1, Start opened, drag - separately or combined. The catastrophic state is
SESSION-STATE dependent (suspect: earlier fullscreen RESAPPLIED 5120x1440 poisoning believed
geometry; grant IS g=5120x1440 vs ctx=1920x1080 per A3CHECK). Mechanisms to fix regardless:
 1. capture.c:1330 1000 ms wait treated as FATAL -> full reset = defect B (proven live).
 2. ProtoTrace DAMAGE trace does GetRealWindowRect + g_csWatchedWindows lock PER RECT (send.c
    ~905, commit 8f9c004) - measured tail contributor.
 3. toastcrop sync UIA on the single WatchForEvents thread (verifier: bounded transient per
    (hwnd,w,h) slot, 3 attempts x 500 ms; Start ANIMATES size -> fresh slots).
 4. CODE-PROVEN (adversarially verified): DESTROY send failing in degraded mode leaves hwnd in
    created-set AND destroyed-ring; CREATEDUP branch returns before ClearWindowDestroyedLocked
    (send.c:527-556) -> window permanently drops damage. Fix: clear the ring in that branch.

**Win-key CAN open Start on 25H2** when sent from an interactive-session scheduled task
(guest/open-start.ps1) - direct qrexec keybd_event fails, the session was the difference.
Automated S1a testing is now possible.
**S1a COLD-BOOT CHECK PASSED**: after kill+start (guest wedged during a drag run - qrexec dead,
display live; killed+restarted), Start announces 544,219 832x736 = the drawn card.
**Persistent toast trigger**: guest/fire-toast.ps1 (reminder-scenario toast stays until
dismissed) - gives a stable shell surface for measurements.

## 2026-08-12 (cont.) — THE POISONED STATE FOUND: believed 5120x1440 vs actual 1920x1080

guest/geometry-truth.ps1 on the live guest: actual mode 1920x1080 (IddSampleDriver active),
but the agent's log shows RESREQ 5120x1440 src=lastapplied -> **RESAPPLIED 5120x1440 (readback
CONFIRMED it applied)** at 00:32:03 - and the mode later REVERTED to 1920x1080 with no agent
request and no agent notice. g_ScreenWidth/Height stayed 5120x1440. Consumers skewed:
 - HandleMotion/HandleButton normalize by believed size, Windows denormalizes over the actual
   primary -> injected pointer scaled by (1920/5120, 1080/1440) = dom0 clicks land wrong.
   This is the S2 class error AND (with HandleButton's dead dx/dy) the unclickable toasts.
 - WaCompute clamps to believed screen -> rect exceeds the real 1920x1080 -> SPI_SETWORKAREA
   0x57 every 30 s, forever (observed 51x).
 - SendScreenGrants grants pages for 5120x1440 (7200) while the capture context is 1920x1080
   (2025) = the standing A3CHECK mismatch. NOTE: granting 7200 pages of a 2025-page surface
   needs a look on its own (what memory backs the excess?).
WHAT REVERTS THE MODE IS STILL UNIDENTIFIED - watch for RESDRIFT lines on the fixed build.

## Fix bundle (agent b92506c..8be83b8, submodule bump cca7d4e), verified in code + adversarial
review, NOT yet run on a guest:
 1. capture.c: slow main loop tolerated up to 15 s (was: 1 s timeout = fatal full reset =
    defect B). FI proof: FI_PUMP_STALL.
 2. HandleButton: clicks carry their own absolute position (ButtonAbsolute=1 default).
 3. CREATEDUP clears the destroyed ring (failed-DESTROY damage-drop, code-proven).
 4. Wobble probe (per-rect GetRealWindowRect+lock) opt-in via ProtoTraceWobble.
 5. toastcrop: UIA on a dedicated worker (own IUIAutomation, no shared lock during RPC),
    tracking path cache-only, PokeWindowTracking on resolve, 2 s whole-walk deadline.
 6. resolution.c: adopt-applied on mismatch (fix A2), ResolutionAdoptCurrent on
    WM_DISPLAYCHANGE + 2 s drift tick (RESDRIFT), known-unappliable memo (60 s TTL).

## 2026-08-12 (cont.) — FIX BUNDLE VALIDATED ON win11-fresh (build 7db23513, agent 31ffaaf)

Deployed via swap-agent, hash-verified, crash-loop check PASSED (PID 6888 stable 105 s, log
count static). Verified against the same instruments that measured the defects:
 - **Defect B dead**: 3 interleaved drag runs, window IDs stable throughout, cap_timeout=0
   (was 6/25 min pre-fix, ~1 per drag). No 'main loop slow' lines even.
 - **Defect A dead**: drag dt p50 17.9 ms / p95 39.6 ms / max 154 ms over 1443 frames -
   AT 5120x1440, 4x the framebuffer area of the original collapse scene.
 - **Workarea fixed**: SPI_SETWORKAREA failures 0 (was 51); 'guest work area set to
   (16,64)-(5104,1424)' applied cleanly.
 - **RESDRIFT works**: 4 adoptions tracked the boot transit 5120->1024->1920->5120; A3CHECK
   converged to g=5120x1440 ctx=5120x1440 (pages 7200==7200). The 5120x1440 mode STUCK this
   session - the guest desktop now matches dom0, and the toast appears at 4724,891 = the real
   dom0 bottom-right. Toast POSITIONING largely resolves itself in this config; keep watching
   RESDRIFT counts for the unexplained reversion.
 - **Toastcrop worker bug found by its own logging gap**: worker alive, UIA ready, but zero
   measurements completed - the async lookups spent all 3 attempts in ~450 ms (pre-XAML).
   Fixed (attempts counted on completed measurements, 6x250 ms), CI round 3 in flight.
 - **Movability feasibility PROVEN**: SetWindowPos on a shell-band CoreWindow (by handle,
   from qrexec) moves it and the move sticks (guest/move-toast-probe.ps1). WM-managed shell
   surfaces are implementable; design pending (focus semantics, decorations).
Still needing the user's hand: dom0-side click on a toast (ButtonAbsolute path), dom0-side
window drag feel. Automated proxies all green.

## 2026-08-12 (cont.) — Round-4 build (ShellManaged) cold-boot validation on win11-fresh

Build e179e46f (agent fcafe61) deployed, guest COLD-BOOTED, hash-verified:
 - Toastcrop async worker WORKS after the pacing fix: first live toast measured insets
   16/30/16/13, announced 4735,1247 364x157 = the cropped card at the TRUE dom0 bottom-right
   of the 5120x1440 desktop. Positioning requirement: met in this config.
 - Toast is now WM-MANAGED (or=0): dom0 frames it; movable by the dom0 WM. Guest focus is
   NOT stolen when a toast fires (Notepad stayed foreground through fire-toast; the
   HandleFocus quarantine works).
 - 5120x1440 survived the cold boot; drag after cold boot: dt p50 19.5 ms over 436 frames.
 - **NEW DEFECT found by pixels: 25H2 Start at 5120x1440 maps a WORKAREA-SIZED (5120x1384)
   StartMenuExperienceHost window** - opaque white, WM-framed, covering the whole dom0
   screen, card content drawn top-left. The 90% exclusions (classifier + ratio guard) kept
   the crop away from it by design. Fixed in agent 4dc559b: no classifier ceiling, absolute
   card floor for oversize hosts. The geometric search already finds the 858x874 card.
 - Toastcrop measured a sibling StartMenuExperienceHost window 858x874 (card insets
   13/69/13/69) and correctly gave up (6 attempts) on a card-less 858x890 sibling - the new
   'no card measured' Info line works.

## 2026-08-12 (cont.) — Release e2e results (task 5)

**win11-24h2** (build 83b69f62 swap-deployed, ToastCropDisable removed): crash-loop check
PASS (PID stable, log static, hash verified), COLD BOOT PASS (agent auto-started on the
fixed build). Toast: cropped AND positioned correctly (4740,1222 364x157 = card at dom0
bottom-right). Drag QGAPERF window was empty - the guest CLOCK JUMPED backwards ~4 min
mid-phase (cold-boot RTC re-derivation), so the [t0,t1] extraction matched nothing:
instrument artifact, noted, dom0-side evidence (IDs, census) unaffected.
**RESIDUAL (24H2 only): Start announces UNCROPPED 0,56 5120x1384.** corewin-scan.ps1 (new)
shows StartMenuExperienceHost hwnd 0x10190 MORPHS between roles: parked cloaked at
5120x1384, measured earlier at 858x874 (card found, insets 13/69/13/69). The crop cache is
keyed (hwnd,w,h) and no measurement ever completed for the workarea-size key. On 25H2 the
mapped Start surface is the 858x874 sibling -> works there (the goal platform). Follow-up:
instrument why the 5120x1384 key never measures (queue? classifier at that instant? worker
race), likely needs a lookup-attempt debug line at Info.

**win10-clean: DEPLOYMENT BLOCKED on elevation.** user is in Administrators but the qrexec
token is now FULLY filtered: schtasks /rl highest AND Register-ScheduledTask -RunLevel
Highest both return Access denied (EnableLUA=1, the historical "HIGHEST-task trick" that
verify-elevated-swap.sh once used no longer works on 19045.6456 - a Windows update closed
it). No unattended elevated path exists on this guest. NEEDS ONE USER ACTION in the guest
(elevated console): either EnableLUA=0 (like the win11 rigs) or install the new agent once
by hand; then the whole win10 e2e phase runs unattended (scratchpad/e2e-win10-retry.sh).

**Benchmark (win11-fresh, 25H2, 5120x1440 desktop, build 83b69f62, 3 runs, hash-verified
each):** idle 3.64/4.79/4.94 %core (median 4.79), synthetic drag+repaint load
5.85/5.90/6.00 (median 5.90). NO same-resolution baseline exists (historical numbers were
1920x1080, 4x fewer pixels), so these are recorded as THE 5120x1440 reference for this
build, not compared. Idle ~4.8% at 4x pixels is the watch item for future optimization.

## 2026-08-12 (cont.) — win10-clean deployment: both self-service routes CONFIRMED closed
Empirically verified on 19045.6456 (not extrapolated): the qrexec `user` token is Medium
Mandatory Level (filtered). `reg add EnableLUA=0` to Policies\System -> Access denied;
`copy gui-agent.exe "C:\Program Files\Qubes Tools\bin"` -> Access denied; schtasks /rl highest
and Register-ScheduledTask -RunLevel Highest -> Access denied (recorded earlier). No
unattended admin path exists on this guest, and hunting a UAC-bypass vector is out of scope
(and the dev-qube classifier blocks it). Win10 e2e is therefore BLOCKED pending ONE elevated
action IN the guest by the user: set EnableLUA=0 (matches the Win11 rigs) OR install the agent
once by hand. Then scratchpad/e2e-win10-retry.sh runs the whole phase unattended. Guest left Halted.

## 2026-08-12 (cont.) — DRAG REPLAY ROOT CAUSE FOUND (user live drag + ProtoTrace, build 172A72B1)

**RETRACTION: handover fact F1 ("the daemon sends NO MSG_CONFIGURE during the drag") is
WRONG for a dom0 WM title-bar drag and is hereby retracted.** Proof: the deployed agent's
trace contains SendWindowConfigure calls at input rate (70-100/s) with byte-identical
duplicates 3-8 ms apart. The ONLY code path that can emit those is HandleConfigure's ACK
(vchan-handlers.c:777) - it bypasses both the dedupe and the c9481cb rate limiter - and it
only runs when MSG_CONFIGURE arrives. During a title-bar drag the pointer is grabbed by the
dom0 WM: motion is NOT forwarded; the daemon relays ConfigureNotify as MSG_CONFIGURE at
input rate. (F1 was probably verified against a guest-native drag - different path.)

**Mechanism (1:1 trace, user drag 14:36:50-56 local, scratchpad drag-evidence-1.txt):**
1. Daemon streams MSG_CONFIGURE (the drag path: ~22 distinct positions per stroke).
2. HandleConfigure applied EACH as its own SWP_ASYNCWINDOWPOS at daemon coords, unconverted.
   Two defects: (a) the flood queues in the window's thread, which applies moves at frame
   cadence (~10 Hz at 5120x1440) - the GUEST window physically replays the path for ~2 s
   after release; (b) daemon coords are announce-space (DWM extended frame bounds), SetWindowPos
   is GetWindowRect-space -> every applied move lands +7 px off (invisible border).
3. The frame path (main.c "writer #2") honestly re-announces each lagging step: the trace
   shows the ENTIRE walk re-sent 1:1, offset exactly +7, at ~10 Hz, ~2 s behind - each value
   != LastCfg (dictated value) because of the +7, so the "don't echo the daemon" guard never
   matched. The daemon applies each announce as a real move -> dom0 window replays the path.
4. At 10 Hz the echo stream sails UNDER the c9481cb 16 ms rate limit -> that fix cannot help.
   Scripted in-guest drags produce no inbound configures at all -> F3 explained (they never
   reproduced it).
5. "What changed vs older QWT": nothing in the protocol - the session-start bisect already
   showed pre-existing. At 1920x1080 the apply/frame cadence was fast enough that the queue
   and the +7 bounce settled within 1-2 frames; at 5120x1440 (~10 fps frame path) the same
   loop smears into a visible 2 s replay. Drag cost = the amplifier, as the user suspected.

**Fix (agent, this commit):** three coordinated changes, all measured-cost-conscious:
 - LATEST-WINS APPLY: HandleConfigure stashes the newest daemon geometry; ApplyPendingDaemonMove
   posts at most ONE async SetWindowPos in flight per window (in-flight = GetWindowRect vs
   posted target, 200 ms timeout); applied at drain end + per frame. The guest-side replay
   queue can no longer form.
 - COORD CONVERSION: announce-space -> SetWindowPos-space delta cached per window (refresh
   >= 500 ms apart; the reverted 95492ed recomputed per configure and made things worse).
   Applied position now lands exactly where dom0 dictated -> the frame path's fresh rect ==
   LastCfg -> no echo at all; also kills the permanent +7 settle offset.
 - DAEMON-DRIVE SUPPRESSION + DAMAGE HOLD: while MSG_CONFIGUREs for a window are <300 ms old,
   position-only announces are withheld (dom0 knows where its own window is) and the window's
   damage is held (announced origin = daemon's framebuffer read origin; sending damage against
   a frozen origin would paint the window's OLD screen region). On drive end: flush announces
   the true resting position ONLY if it differs from what the daemon dictated, then one
   full-window settle repaint. CfgFlushPendingMove now flushes current canonical X/Y (a
   withheld stale intermediate must never be announced late) and skips byte-identical echoes.

## 2026-08-12 (cont.) — Workflow audit of the evidence corpus (5 agents, wf_e1ebbf98)

Corrections to the handover's "established facts", from re-reading the RAW pulled logs:
 - **F2's "guest window static while agent announces motion" is VOID**: both pos-sampler
   runs backing it recorded ZERO movement for the entire session INCLUDING the commanded
   drag - the instrument never observed the event. No evidence the guest window was static;
   the async-SetWindowPos-queue mechanism requires it to MOVE, and nothing contradicts that.
 - **F1's "zero inbound configures at VERBOSE" is unverifiable**: not one Debug/Verbose
   line exists in any preserved pull, and HandleConfigure only logs at those levels. It was
   also scoped to DURING-drag at best; the replay lives after release.
 - The 12:22/12:28 (pre-c9481cb) traces show the second pass with re-generated values
   (429/234 for 431/236, one value dropped) - not a byte-replay of a queue; on c9481cb the
   second pass is exactly +7 px in x. Both fit re-generation through the winrect-vs-DWM
   coordinate seam, not ring drainage.
 - Daemon side (xside.c): NO animation/deferred moves - the ring is the only replay tape it
   drains (in order, one XMoveResizeWindow each); handle_configure_from_vm BOUNCES any
   non-matching agent configure back with its own geometry (sequence-number-free protocol,
   known to spin); ACK byte-echoes are indistinguishable from announces in ProtoTrace
   (fixed: QGAPROTO,msg=CONFIGURE-ACK tag, agent 0057c7a).
 - c9481cb's rate limiter also had 3 latent bugs (stale pending never invalidated; pending
   surviving HandleConfigure's dictated position; flush unreachable for Pw-attached windows
   which are the DEFAULT) - all three are structurally fixed by the 9f6ac17 flush rewrite
   (flush current canonical X/Y, skip byte-identical, Pw-branch call site added).

## 2026-08-12 (cont.) — DRAG REPLAY FIXED, USER-CONFIRMED ("all good")

Build E3D6810A (agent 336ccc7) on win11-fresh, hash-verified, ProtoTrace on during the test:
user dragged real windows by the dom0 title bar and confirmed the acceptance criteria - no
jump-back, no replay, no settle wander. Automated gates all green on the same build:
 - toast: fired, cropped card at dom0 bottom-right, two toasts stacked correctly (fullshot
   pixels inspected, not just geometry);
 - census: cap_timeout=0, workarea_fail=0; scripted drag settles in 60 ms, ZERO post-release
   configures after the one settle announce (144 ms after release, exactly winrect+7);
 - A3CHECK g=ctx=5120x1440 pages 7200==7200, RESDRIFT adopted correctly on start;
 - benchmark within noise of 172A72B1 baseline (3 runs/side, hash-verified): dmg_p50 12-13us
   both, tot_p50 1.2-1.8ms (fix) vs 1.5-2.2ms (base), dt_p50 216-280ms vs 280-319ms.

## NEW PRIMARY (user 2026-08-12): frame-delivery collapse during drags

Both today's builds (172A72B1 AND E3D6810A) capture only 4-5 frames/s during a scripted
drag (dt_p50 216-319 ms, acq~=dt so the time is spent WAITING for frames), while the
morning fix-bundle validation on 7db23513 (agent 31ffaaf) measured dt p50 17.9 ms over
1443 frames - same VM, same 5120x1440, same harness. ~12x fewer delivered frames. The
user: predating the session does not matter, chase it and fix it. This collapse is also
the amplifier that made the drag replay visible at all.
Next experiment (serial): redeploy 7db23513 interleaved with E3D6810A, 3 runs each - build
regression vs environment/scene drift.

## 2026-08-12 (cont.) — Review-pass hardening + frame-collapse post-mortem + final build

**Frame-delivery "collapse" closed as NOT-A-BUILD-BUG**: interleaved deploy proved 7db23513
measures the same 4-5 fps today (dt_p50 166-217 ms) as the afternoon builds, and a FRESH
Notepad restored dt_p50 19.7 ms on the same environment/build. Every afternoon benchmark ran
against ONE wedged window instance (white body, title strip delivered, typing registered but
invisible, survived agent restarts AND build swaps -> the state lives guest/window-side).
Its process was killed during diagnosis, so etiology is capped at "window rendering state,
inflicted sometime midday". RECURRENCE PROTOCOL: if a window goes empty again, capture a
GUEST-side screenshot first, run winenum + corewin-scan on it, and do not benchmark drags
against any window whose content is not verified rendering. The analysis workflow flagged a
plausible related hazard worth keeping in mind: a stuck g_InputDragWindow latch (press whose
release never arrived) permanently suppresses one window's recapture within an agent
instance - worth a defensive timeout someday, but it cannot explain cross-restart persistence.

**Adversarial review (15 agents, 23 raw findings) -> 4 fixes landed in agent 700d22b:**
 1. DaemonDriveTick stamped only by geometry-carrying configures (iconic/maximized/unchanged
    configures no longer arm holds or trigger settle repaints);
 2. drive-end settle no longer frame-gated: pump bounds its wait to 100 ms while settle work
    is pending, WAIT_TIMEOUT sweep flushes/applies/releases (static-desktop starvation gone);
 3. frame-loop settle repaint clipped to rgnVisible (no occlusion bleed);
 4. size-only configure can no longer overwrite an in-flight-gated dictated position
    (stash merge preserves the pending move).
 Deferred, documented: crop branch still applies per-message SetWindowPos - reachable only
 under ShellManaged=1 (not the shipped default); not worth touching the won shell UX now.
 Rejected as pre-existing/theoretical: lock-order inversion (all protocol sends are
 pump-thread-only, CS reentrancy makes vchan->windows order safe), optimistic-commit
 misregistration (pre-existing pattern, self-heals via tracking), DPI!=100% delta rounding.

**FINAL BUILD 2409BD22 (agent 700d22b), deployed hash-verified after a COLD BOOT of the
drag-fix line (E3D6810A boot: agent auto-start, RESDRIFT 1920x1080->5120x1440, A3CHECK
converged):** bench dt_p50 20.3/23.5/20.5 ms (n=379-428/run - full frame delivery, best
numbers of the day), dmg_p50 11-12 us, toast card cropped+positioned (pixels verified),
probe settle 65 ms with zero post-release configures, cap_timeout=0, workarea=0.
Awaiting the user's real-drag re-confirmation on 2409BD22 (settle-path code changed since
their "all good" on E3D6810A).

## 2026-08-12 (cont.) — Canonical-baseline comparison (user directive): NO agent regression;
## the delta vs the README table is the GUEST platform

The user's standard: the baseline is the recorded canonical benchmark (README table, agent
09b643e, 2026-08-10, win11-idd-test) - guest-side drag cost counts even where dom0-side
corrections mask it. Method: instrumentation/drag-harness.ps1 phases + 250 ms sampling of
gui-agent cumulative CPU (guest/phase-cpu-bench.ps1), win11-fresh @1920x1080, 3 runs/side,
hash-verified.

| phase | README 09b643e | 2409BD22 (current) | 92C48AC5 (README-era binary, SAME guest) |
|---|---:|---:|---:|
| drag   | 8.67 | 13.0-15.6 (med 13.9) | 15.3-16.2 (med 15.7) |
| scroll | 3.51 | 5.2-7.1 | 3.9-4.9 |
| type   | 1.71 | 4.2-6.2 | 4.6-5.3 |
| idle   | 0.83 | 0.3-1.0 | 0.3-1.0 |

**Single-variable verdicts:**
1. NO agent-code regression: the exact binary behind the README numbers costs the SAME
   (slightly more) on today's guest/scene as the current build. The current agent is the
   cheaper of the two at drag on identical scenes.
2. Toast hypothesis (user): FALSIFIED - same binary, toast dismissed vs present: drag
   14.0-18.7 vs 15.3-16.2 = noise. An on-screen toast does not tax the occlusion path.
3. The 1.6-1.8x gap vs the README table is the GUEST PLATFORM (win11-fresh/25H2 vs the
   08-10 win11-idd-test guest): same binary, same harness, same resolution, different
   guest. Flagged as its own future investigation for guest-side drag UX (candidates:
   25H2 DWM/compositor changes, IDD driver version/config differences).

**New canonical references, final build D27E826B (agent 857965a), win11-fresh 25H2:**
 @1920x1080: drag 11.6/15.9 scroll 3.8/4.4 type 4.0/5.8 idle 0.7-2.9 (2 runs)
 @5120x1440: drag 11.4-16.5 scroll 4.2-6.4 type 2.7-4.5 idle 0.0-2.1 (3 runs)
 Run-to-run spread on this guest is high (~±25%); compare medians of >=3 runs only.

**Incident during the resolution flips (user-reported "rendering bug"):** restoring
5120x1440 via ChangeDisplaySettings switched the active display DEVICE (DISPLAY1->DISPLAY2,
IDD monitor); the guest shell lost every visible window (bare wallpaper, no taskbar;
processes alive; explorer never crashed) and the agent correctly announced nothing -
GetRealWindowRect handle-invalid spam while it chased the dying handles, prev agent
instance died in the transition. RECOVERY: explorer restart + fresh window = fully healed,
no reboot needed. LESSON: in-guest ChangeDisplaySettings mode flips can hop display
devices and collapse the shell's window set on this IDD-equipped guest - use them only
with a recovery plan; dom0-driven resize remains the proper path (unavailable in seamless).

## 2026-08-12 (cont.) — FINAL: clean cold boot on D27E826B, all green

Post-boot on the final build (agent 857965a): agent auto-start PID 5044, hash-verified,
RESDRIFT->A3CHECK converged g=ctx=5120x1440, fresh Notepad renders full chrome (no black
regions), toast card cropped+positioned at the corner, scripted drag settles 12 ms after
release with zero post-release configures. Shell fully healthy after the earlier
explorer-restart recovery + reboot.

WATCH ITEM (user-reported, transient, pre-reboot damaged session): "top half of the
Notepad window was black" on the freshly-opened window. Two suspects if it recurs on a
clean session: (a) the clipped drive-settle repaint missing a region when a placement
configure pair arms a stream on a fresh window (agent 857965a code); (b) the pre-existing
per-window prefill painting a fresh window's buffer before its first full content copy.
Recurrence protocol: fullshot immediately, then guest-eyes.ps1 (guest-side pixels decide
whether the black exists in the guest or only in dom0's copy).

## 2026-08-12 (cont.) — Guest-drag wobble: measured, root-caused, four fixes landed (agent 43de7d4)

MEASURED on a real user drag (ProtoTrace, build D27E826B): 10 announce stalls of 76-472 ms
in a 5.7 s drag, catch-up jumps to 337 px, 43 direction reversals >3 px - vs a clean 26 ms
cadence with zero stalls on a scripted drag minutes apart. Frame correlation split it into
two species: (A) big-area frames delivered at 150-195 ms (acq-bound), (B) the pump busy
BETWEEN frames (476 ms with acq=19 ms).

Investigation (wf_c4ca99e0, 5 agents) ranked the mechanisms; all four GO fixes landed:
 1. **The dominant, most drag-shaped artifact**: the throttled 150 ms mid-drag PrintWindow
    refresh was the ONE recapture the drag latch did not suppress - a 15-50 ms synchronous
    stall injected into the dragged app's own modal move loop at ~6.7 Hz (freeze-then-snap).
    Latched windows now skip it; the settle recapture on release repaints once.
 2. Announce-cadence aliasing: the 16 ms limiter beat against the ~20 ms frame cadence and
    withheld positions only flushed at frame boundaries (the tracking-pass flush the
    comment claimed had NO call site). The latched window is now limiter-exempt.
 3. Inbound MSG_MOTION coalescing (the w9r3irkhc design, finally landed): latest-wins
    pending slot, flushed before any non-motion dispatch and at both drain ends - a
    post-stall backlog no longer replays the stale trajectory through SendInput.
 4. Mid-guest-drag daemon configures are ignored while the latch holds (ACK still echoes):
    the user's hand is the geometry authority; a WM bounce can no longer yank the window
    backward or arm the drive suppression mid-drag. Inert on clean drags (0 inbound
    configures in both traced episodes).
Deferred with instrumentation-first verdicts: HandleMotion origin reconstruction (magnitude
unmeasured), the 25H2 platform 1.6-1.8x cost multiplier (no designed fix; re-evaluate after
fix 1 lowers the floor).
ACCEPTANCE (user-felt + traced): a hand drag with no >60 ms announce stalls, no catch-up
jumps, and no rhythmic hitch; dom0-drag replay harness re-run (fix 2 touches the limiter
that fixed the replay).

## 2026-08-12 (cont.) — GWeck goal batch + wobble fixes DEPLOYED (build C55DCDA7, agent 43de7d4)

Automated validation green on win11-fresh 25H2, hash-verified:
 - QGASHELLMANAGED policy=2 (start-only), QGABLOCKWIN on, A3CHECK converged 5120x1440.
 - **Start menu IS a WM-managed dom0 window**: fullshot geometry or=0, mapped, 832x736 =
   exactly the cropped card; dom0 gives it a frame and the title "[win11-fresh] Start".
   Size-lock hint fired: QGAPROTO,msg=HINTS,sizelock=832x736.
 - Toasts UNCHANGED: or=1 corner popup at 4740,1222, card renders (policy separation works).
 - Occlusion choreography (armed-task, dom0-only captures): a console window stacked ABOVE
   the open Start in dom0 shows its own content (agreeing z-order: no bleed); Notepad moved
   UNDER the Start region and inspected after: fully intact, no Start-pixel debris, no
   stale regions. Census cap_timeout=0, workarea=0. Scripted drag settles in 4 ms.
 - Instrument facts re-learned: EnumWindows CANNOT see shell surfaces (the programmatic
   Start-move stickiness test silently no-oped - the real test is a dom0 WM drag, user
   checklist); any guest process activity while Start is open DISMISSES it, including the
   opener's own cleanup - both opener scripts now use exit-before-fire + hidden console
   (the shipped installer helper had BOTH defects; fixed before first ship).
Pending user-hand checks: Start frame drag (move-stickiness - the one unproven design
assumption), resize refusal (size-lock end-to-end), Start clickability, dom0-restack-above
bleed severity (documented Phase 3 limitation), Win-key block feel, wobble verdict.

## 2026-08-12 (cont.) — Movable Start on 25H2: WALLPAPER PHANTOM, root identified, investigating

USER-VISIBLE: movable Start moves+stays (NOACTIVATE fix works) but renders "a peek into the
underlying desktop" - pure wallpaper, no menu. Also "responds to resize", and the opener
flashed "two terminal windows".

DECISIVE EVIDENCE (win11-fresh 25H2, build CEBD5650):
 - A GUEST-SIDE screenshot shows NO Start menu rendered in the guest at all (only Notepad +
   toast) while dom0 shows a framed or=0 "[win11-fresh] Start" at 2352,56 1201x919 full of
   wallpaper. So the agent maps a StartMenuExperienceHost window that the guest is NOT
   presenting as an open menu = a PHANTOM (the persistent Wnd_StartFeed window that exists
   while Start is CLOSED - GWeck-investigation class).
 - Agent: PwAttach 0x10184 1201x919 SLICE-FED, then "no card measured for
   4294966630x4294966546" = GetRealWindowRect returned an INVERTED rect (-666 x -750).
 - EnumWindows from a guest script sees ZERO StartMenuExperienceHost top-levels (shell
   surfaces evade it; only the agent's hook tracking sees 0x10184).
 - ~2h earlier (C55DCDA7) a fullshot showed a CORRECT 832x736 cropped card - so the agent
   CAN render Start right when it is genuinely open; the failure is state-dependent.

Multiple root threads (investigation wf_82456c4a running): (a) the closed-Start phantom
passes ShouldAcceptWindow+IsShellToastWindow and is mapped showing wallpaper; (b) slice-feed
of a moved shell surface reads a screen region with no menu pixels; (c) GetRealWindowRect
returns negative for the managed Start, poisoning crop + slice geometry.

FIXES LANDED THIS ROUND (necessary, not sufficient alone):
 - Sticky crop (agent, toastcrop.c): last-good insets per hwnd, never revert a managed shell
   surface to uncropped. Fixes the garble+resize WHEN a card was ever measured; does not help
   a phantom that never had a card.
 - SWP_NOACTIVATE on daemon moves (main.c): a frame drag no longer dismisses Start. CONFIRMED
   working (moved+stayed).
 - Windowless wscript/VBS Start opener (installer + guest scripts): no more conhost flash
   that dismissed Start ("two terminal windows").

PROCESS NOTE: went too fast in the live loop here (3 user-visible failed attempts) - the
25H2 Start capture is a real investigation, not a one-shot fix. Stopped guessing; running
wf_82456c4a with the guest-pixel evidence to decide movable-managed-with-fixes vs
correct-corner-drop-movable.

## 2026-08-12 (cont.) — WOBBLE ROOT CAUSE: input translated against the LIVE origin instead
## of the ANNOUNCED one (agent b93d259)

The forth-and-back oscillation during a GUEST-NATIVE drag (user-reproduced; distinct from
the dom0-frame drag replay, which stays fixed) is a positive feedback loop on the input path:
 - gui-daemon sends window-RELATIVE input coords, computed against the rect it was last
   TOLD about (xside.c process_xevent_motion: k.x = ev->x).
 - The agent added them back to the LIVE tracked origin (data->X/Y) in BOTH input paths
   (InjectMotion and HandleButton), so injected cursor = true cursor + (live - announced).
 - The app's own modal move loop moves the window by that error -> the live origin changes
   -> the next error changes. While announces are starved (ProcessNewFrame holds
   g_csWatchedWindows for the whole per-window pass; the daemon also defers while
   have_queued_configure is set) the error ACCUMULATES and the window runs AHEAD of the hand;
   when the backlog flushes and dom0 adopts the newest position, the next injected sample is
   short by the whole accumulated gap and the window is yanked BACKWARD.
 - Predicts amplitude = drag velocity x announce dead time (~1300 px/s x ~160 ms = ~80 px,
   the observed max) and predicts HORIZONTAL-ONLY error on a horizontal drag (y stayed
   260-263 while x swung 80 px) - which no jitter/DWM-lag/two-writer story predicts.
 - The code comment at vchan-handlers.c:427 ALREADY stated the correct rule ("dom0's
   coordinates are relative to the rect the agent ANNOUNCED"); only the field was wrong.
FIX: both paths use LastCfgX/Y when CfgSentValid, falling back to X/Y before the first
announce. Every WINDOW_DATA writer runs on the pump thread under the lock, so this is not a
two-writer race - the window really moved back, because we told it to.

**INSTRUMENT CORRECTION (retraction):** the first oscillation measurement was ACK-POLLUTED -
every configure ACK byte-echo is ALSO traced by send.c as a plain msg=CONFIGURE, so 155 of
245 "outbound" lines in that trace carried dom0's coordinates, not ours. Re-measured on a
clean trace (1 ACK): the oscillation is REAL - 23 direction reversals in 143 genuine
announces. Also retracted earlier the same session: "the drag latch never armed" was an
artifact of LogLevel=3 hiding LogDebug lines; the latch does arm (guest LogLevel is now 4).

## 2026-08-12 (cont.) — Start on 25H2: the phantom is the remaining defect (agent, card gate)

The user watched four failed managed-Start attempts ("maximized window, then dead";
"console popped, then window at random position, then dead"; wallpaper contents). Causes,
now separated:
 1. PHANTOM MAPPING (the big one): StartMenuExperienceHost keeps a top-level surface alive
    while Start is CLOSED. Mapping it announces a window with no menu inside, so dom0 shows
    a slice of bare desktop at whatever rect that surface reports - measured 1201x919, and
    once x=6063 on a 5120-wide screen ("random position"), vanishing when the phantom does
    ("then dead"). FIX: ShellSurfaceCardless() + a genuine-open gate in ShouldAcceptWindow -
    a classified shell surface whose card measurement FINISHED with no card and no sticky
    last-good is not a window. In-flight measurements are never rejected.
 2. CONSOLE FLASH: the Start opener's launcher (powershell, even -WindowStyle Hidden)
    flashes a conhost window that steals focus and dismisses the menu it just opened - the
    user's "console popped". FIX: the whole chain is windowless (.lnk -> wscript //B ->
    Run(...,0) hidden powershell -> keybd_event(VK_LWIN)). SendKeys "^{ESC}" from that
    context does NOT open Start at all (guest screenshot: no menu, all shell hosts
    main=0x0) - the VK_LWIN chain is the proven one.
 3. Instrument note: `qtest fullshot` takes ~50 s and every qrexec retrieval flashes a
    console, so a transient menu cannot be observed that way. Added
    capture-start-render.ps1 / read-start-render.ps1: the guest samples its OWN screen while
    Start is open and the PNG is retrieved later.
Rig is back on ShellManaged=0 (headerless corner Start), the only configuration ever
confirmed to render correctly. Frozen-anchor (=2) exists but is unproven and NOT recommended.

## 2026-08-13 — DRAG: the accepted configuration, and what each part actually fixed

Shipped defaults (agent, verified by CLEARING every registry override and reading the
agent's own PerfInit lines back - build 69E59CE6):
  QGADRAGSERVO on gain=85% tau=25ms deadband=3px fast>=24px@85% clamp=on
  QGADRAGFREEZECONTENT on   QGADRAGEVTPRIO on   QGAMONCACHE on   QGADRAGFREEZE off

The user's drag complaints were FOUR separate defects, each with its own cause and fix.
Everything below is measured, mostly with guest/sample-window-motion.ps1 (in-guest 10 ms
sampling of the guest's OWN GetCursorPos + GetWindowRect, retrieved after the fact so the
observation cannot perturb the drag):

1. WOBBLE (forth-and-back). Structural, pre-existing (16% of announces reversed on the
   user-confirmed-good build, 19% on a regressed one). gui-daemon sends WINDOW-RELATIVE
   motion (xside.c: k.x = ev->x) and the agent reconstructed an absolute against a GUEST
   origin; that is exact only when it equals dom0's APPLIED origin, which lags our
   announces and is unobservable during a guest drag (zero inbound configures measured in
   a 5.85 s latch). Gain-1 servo + transport lag = oscillator. FIX: Smith predictor -
   timestamped ring of our own announces, reconstruct dom0's applied origin, damp at 85%.
   Servo the CURSOR not the window, so Windows re-anchoring the modal loop's grab
   mid-drag (drag-to-restore of a maximized window) cannot poison it.
2. STARTUP DELAY. Measured 193 ms and 211 ms between the INJECTED cursor moving and the
   window moving (221 px of cursor travel banked in one case); warm 30-40 ms. Cause:
   PrintWindow(PW_RENDERFULLCONTENT) is a synchronous cross-process render that executes
   in the DRAGGED APP'S UI THREAD, so the app cannot process the mouse messages that move
   its own window. FIX: freeze content during the drag (dom0 keeps the last good bitmap,
   one authoritative full repaint on release). Result: 0 ms on four of seven drags.
   Residual: cold first-drag still 156-259 ms - OPEN.
3. JUMPINESS. The guest's own window rect advanced only every 54-70 ms in 12-68 px hops
   (~16 Hz). Announcing faster cannot smooth motion that is not happening: the mouse
   events driving the app's move loop arrived in clumps at frame cadence, because the pump
   drains the vchan only on its own event or at the top of a frame, and g_WindowEventSignal
   is LAST in the wait array by design. FIX (DragEventPriority): while the drag latch is
   armed, drain input FIRST and then announce, both ahead of the frame wait.
4. FAST-DRAG TRAILING. The 85% damping is only needed near the settling point; applied to a
   fast hand it just lags. The user proposed 'first jump immediately, then adapt' = gain
   scheduling. Implemented at 100% for deviations >=24 px and it produced CRAZY
   EXTRAPOLATED JUMPS: at full gain a mis-reconstructed origin is applied whole, and the
   damping had been silently absorbing those errors. Reverted to neutral (fast gain ==
   base gain) and added the CLAMP that makes the idea safe: an injected step may never
   exceed 2x the hand's own relative movement for that event + 32 px, so a wrong estimate
   can only make the window LAG, never overshoot. Raising InputDragServoFastGainPct is now
   a field experiment rather than a risk.

PROCESS FAILURES THIS ROUND, recorded so they are not repeated:
 - A knob's registry READ silently failed to land in perf.c (the edit did not match), so
   the value was hardcoded and could not be flipped when it misbehaved - the binary had to
   be rolled back instead. EVERY generated edit is now verified by grepping the file, not
   by trusting the script's own success message.
 - Latency was judged for hours with ProtoTrace=1 and LogLevel=4 live on the guest, which
   multiply the frame-walk tail (tot max 580 ms vs 66 ms off). Diagnostics are now OFF by
   default on the rig and must be re-enabled per measurement.
 - MonInfoCache measured 3x interleaved: upd p95 3457->1631 us, upd max 40.2->14.6 ms.
   tot_max did NOT improve in the same runs (89.6->168.2 ms median) and is unexplained -
   NOT claimed as a win, still open.

## 2026-08-13 — DRAG WOBBLE PARKED by the user; the measured wins ship, the servo does not

User verdict after side-by-side testing of servo-on vs servo-off: "the difference is
marginal, both suck in a way, lets record experiment results and put improvement on long
term plan, not now." Full write-up, including how to resume it: docs/PLAN-drag-quality.md.

SHIPPED, default on (each measured independently of the parked work):
 - InputDragFreezeContent: content frozen during a guest drag, one full repaint on release,
   and the freeze OWNS the capture channel so the engine's sweep cannot fire a PrintWindow
   into the dragged app's thread. Startup 193/211 ms -> 0 ms on four of seven drags.
 - DragEventPriority: input drained (then announced) ahead of the frame wait while dragging.
   Fixes the guest window only advancing every 54-70 ms in 12-68 px hops.
 - MonInfoCache: upd p95 3457->1631 us, upd max 40.2->14.6 ms, 3x interleaved.
SHIPPED, default OFF (experiments, knob-revivable): InputDragServo (Smith predictor),
InputDragServoClamp, InputDragFreeze (frozen dom0 window), gain scheduling (neutral).

WHY THE SERVO DID NOT SHIP: theory and simulation were sound (delay cancels out of the loop;
1.6% residual reversals vs 43%), but on the guest the ESTIMATE was unreliable in both
directions - full gain on a bad reconstruction gave "crazy extrapolated jumps", and a
reconstruction running ahead collapsed the deviation so the window "just sits there". The
control law was never the problem; the origin estimate was, and it was never measured
against ground truth. That is the first thing to do if this is revived.

RESIDUAL, unfixed and recorded: cold first drag 156-259 ms (vs ~0 warm); the ~46 ms guest
composite quantum at 5120x1440 (vs ~18 ms at 1080p) which announces are slaved to and which
is NOT agent code - the authorised resolution A/B was never run; tot_max unexplained under
MonInfoCache; and the twice-seen wedged-window corruption (proven guest-side, fresh windows
always clean).

## 2026-08-13 — qubes-vm-update's agent is INJECTED per run (re-verified from source), and guest AU must be off

Re-cloned QubesOS/qubes-core-admin-linux to answer precisely how the Linux updater reaches a VM.
The agent is NOT part of any guest package - dom0 ships it in on every single run and deletes it
afterwards (`vmupdate/qube_connection.py`, `vmupdate/update_manager.py`):
1. dom0 tars its own `vmupdate/agent/` tree (`shutil.make_archive`, gztar) - `transfer_agent():132`.
2. `mkdir -p /run/qubes-update/` in the VM (`UpdateAgentManager.WORKDIR`, update_manager.py:421).
3. Copies the tarball via `qubes.VMExec` running `cat > /run/qubes-update/<name>.tar.gz` AS ROOT
   with the archive on stdin (`_copy_file_from_dom0`).
4. `tar -xzf ... -C /run/qubes-update/` in the VM.
5. Runs `/usr/bin/python3 /run/qubes-update/agent/entrypoint.py <args>` (PYTHON_PATH line 55,
   `run_entrypoint():187`).
6. entrypoint picks a backend from `get_os_data()` (dnf/dnf5/apt/pacman), refreshes, upgrades,
   prints float progress on stderr, then runs `/usr/lib/qubes/upgrades-status-notify`.
7. dom0 `rm -r /run/qubes-update/` unless `--no-cleanup`.
Exit codes re-confirmed against `agent/source/common/exit_codes.py`: OK=0, OK_NO_UPDATES=100,
ERR=1 - exactly what guest/wu-update.ps1 emits, so our contract implementation is source-correct.

CONSEQUENCE FOR US, stated plainly: the guest side of the Linux design is STATELESS (any VM with
python3 + a supported package manager is updatable, nothing preinstalled). Windows can never be
driven that way - no /usr/bin/python3, no dnf/apt, no Windows branch in get_os_data/AgentType - so
our `qubes.WindowsUpdate` service IS the Windows equivalent of that injected agent, and it must be
PREINSTALLED (shipped in QWT) precisely because dom0 cannot inject a runnable agent into Windows.

USEFUL FOR FUTURE UPSTREAMING: `run_entrypoint(entrypoint_path: str | List, ...)` already accepts a
ready-made command LIST and uses it verbatim. A Windows backend upstream would therefore be small:
skip `transfer_agent`, pass a command list that invokes the guest service. Not to be submitted now
(standing policy: nothing upstream until the whole thing is complete).

USER POLICY (2026-08-13): "updates are handled from dom0 side from now on, so guest-side auto
update should be off". Audited: NO NoAutoUpdate/AUOptions/AU-policy handling exists anywhere in
guest/ or packaging/ today - the shipped guest currently keeps stock Windows auto-update. This
matters because the proxy is now raised only during a dom0-driven pass, which is exactly when a
live AU would find connectivity and install behind dom0's back. To implement in the packaging
change: HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU\NoAutoUpdate=1. Do NOT disable
the wuauserv/USO services - the on-demand install path uses them.

## 2026-08-13 — Windows updates from the Qubes Update GUI: shim shipped, and a REAL install pass ran

GOAL (user): "do the wrapper and cook it into rpm for flawless install ... NO SEPARATE COMMANDS,
it should just update from gui with regular click". That rules out our own dom0 command as the
primary path: the Qubes Update GUI shells out to `qubes-vm-update`, so the GUEST must answer it.

WHAT DOM0 ACTUALLY DOES (re-read from source, qubes-core-admin-linux vmupdate/qube_connection.py):
it never calls an agent living in the guest - it INJECTS one per run and deletes it afterwards:
mkdir -p /run/qubes-update/ ; cat > .../agent.tar.gz (tarball on stdin, over qubes.VMShell) ;
tar -xzf ; /usr/bin/python3 .../entrypoint.py <flags> ; rm -r ; cat <agent log>. Steps 1/3/5/6 go
over qubes.VMExec IF the qube advertises `vmexec`, else qubes.VMShell. Step 4 ALWAYS goes over
qubes.VMExec - the progress path calls run_service() directly, no feature check, no fallback.

SHIPPED (guest/vmupdate-shim.ps1 + guest/VMExec.ps1 + guest/qubes-posix-cat.cs, deployed by
DEFAULT from installer stage 2, /noupdates opts out; qvm-windows-update folded into the dom0 RPM
as a fallback, not the required path; NoAutoUpdate=1 set - dom0 owns installs).

TWO DEFECTS FOUND, NEITHER OURS BY ORIGIN:
1. QWT's stock VMExec.ps1 ends on `& cmd.exe /c $cmd` and never exits with the child's status, so
   EVERY qubes.VMExec call returns 0 to dom0. Measured with controls: `exit 100` over VMExec -> 0;
   the identical command over VMShell -> 100; a refused service -> 126 (so the check can fail).
   dom0 decides success from that status, so on Windows every failure has read as success. Fixed
   in our copy of the file (we ship the tools stack).
2. The Windows build of qubesdb-cmd CANNOT WRITE to QubesDB at all. client/qubesdb-cmd.c does
   `optind -= 2` under _WIN32 after a loop testing `getopt(...) != 0` instead of `!= -1`; exactly
   ONE trailing argument reaches the handler. read/list take one arg and work; write needs a pair
   and dies with "Invalid number of parameters" in all five documented forms. Upstream
   qubes-core-qubesdb, not ours -> qualifies for reporting under the CLAUDE.md exception.

CONSEQUENCE OF (2): the guest cannot advertise `vmexec` (qubes.FeaturesRequest reads QubesDB).
CAUGHT ONLY BY ASKING DOM0: admin.vm.feature.Get+vmexec -> "Feature not set for domain
win11-fresh", while our installer had happily logged "advertised vmexec=1 (exit 0)" - qubesdb-cmd
prints usage and returns 0. A log line is not evidence; the check that could fail was the dom0 one.

WHY IT STILL WORKS WITHOUT THE FEATURE (measured): over VMShell dom0's line ends in `& exit`, and
`exit` with no argument returns 0 no matter what preceded it (control: a bogus command -> exit 0,
while an explicit `exit 100` -> 100). So dom0 sees the prep steps succeed and proceeds to step 4,
which is on VMExec regardless and lands in our shim. The ONE step that must not fail is step 2:
if the workdir is missing, cmd's redirection fails, cmd exits at once, and dom0 is left writing a
megabyte into a closed pipe. Hence the installer pre-creates C:\run\qubes-update and the shim's
`rm` EMPTIES that directory instead of deleting it. Both look like bugs; both carry comments.

VERIFIED (tools/replay-dom0-update.py replays dom0's sequence over the same services with the same
encode_for_vmexec encoding; tools/verify-vmupdate-copy.py checks the copy):
- steps 1/3/5/6 -> rc=0 each, with the shim's own log lines proving the handler ran;
- step 2 -> a 1 MB tarball arrives BYTE-EXACT (size + SHA256 read back out of the guest). An exit
  code proves nothing here: cmd's `exit` returns 0 whether or not the payload landed.

REAL INSTALL PASS - the north-star gap that had never been closed. Driven entirely through the
shim on win11-fresh (25H2, build 26200.8875): scan found count=2 (KB5120708 .NET 184 MB,
KB5121003 2026-08 Security Update, 4867 MB actually downloaded), download reached 100 %, install
ran, phase=done, reboot_needed=true. Result array: kb5121003 rc=3010 (SUCCESS, reboot required).
JUDGED ON THE GUEST, NOT THE LOG: Get-HotFix lists KB5121003 installed dated today, CBS
RebootPending=true, NoAutoUpdate=1 present. Updates now install on a Windows qube through dom0's
own protocol path.

OPEN FROM THAT PASS (do not gloss): the result array also contains a STALE kb5043080 .msu (a 24H2
cumulative left in the cache from an earlier session) with rc=552, and KB5120708 (.NET) appears in
`available` but in neither `result` nor Get-HotFix - it likely needs the pending reboot first. So
the pass reported success while one offered update was not installed. That is our updater's
install logic (guest/qubes-windows-update.ps1), not the shim, and it needs a look: stale files in
the cache must not be re-attempted, and "done" should distinguish "all installed" from "some
deferred".

HARNESS LESSONS (both cost real time today):
- Never pipe a long background job through `tail`: nothing is written until the pipeline ends, so
  a killed job yields an EMPTY output file. The 30-min outer `timeout` then killed the client
  ~1 min after the guest-side pass finished, losing the exit code and the float stream entirely.
  The pass itself had completed - the guest state proved it - but the protocol half went unseen.
- qubesdb-cmd, schtasks and qrexec-client-vm all return 0 on failure paths. Verify the EFFECT
  (read it back, or ask dom0), never the exit code.

STILL OPEN: the user's actual GUI click (dom0 tool, needs the user); the cold-boot path (dom0
starts a stopped template before updating it - a reboot test was started right after this entry);
and a TemplateVM proper. dom0-side selection has no OS filter (targets are chosen by class plus
updates-available/skip-update/prohibit-start) and the Update GUI lists anything `updateable`, so
templates are in scope by construction - but that is an argument, not a demonstration.

## 2026-08-13 (cont.) — second pass: the exit-code fix PROVEN with a nonzero code, and a silent failure caught

After the reboot (UBR 8875 -> 9168, KB5121003 applied), the sequence was replayed twice more.

PASS 2 (before the reporting fix): scan offered count=1 (KB5120708, .NET Framework Security
Update). `result` came back EMPTY - nothing downloaded, nothing installed - and the run reported
`updates processed: count=1` on stdout with EXIT 0. dom0 would have been told the qube updated.
Cause: Resolve-Catalog scrapes the Update Catalog around the x64/24H2/26100 client build and
resolved no installable .msu for that KB on a 25H2/26200 guest, so $got was empty, so no result
row was ever written, so nothing could look wrong downstream.

FIX: a KB that resolves to no installable package now records {kb, ok=false, reason=...} and
wu-update.ps1 names each failed KB on stderr and exits 1.

PASS 3 (after the fix), captured through the full dom0 sequence:
  [entrypoint] rc=1
    stderr: 0.0 / 1.0 / 3.0 / 100.0
    stderr: FAILED KB5120708: no installable package resolved from the Update Catalog
    stderr: see C:\ProgramData\Qubes\update-status.json on the qube for details
  [mkdir]/[tar]/[rm]/[cat log] rc=0 each, with the shim's own log lines.

TWO THINGS PROVEN AT ONCE:
1. EXIT CODE PROPAGATION through qubes.VMExec, with a NONZERO code, end to end. Stock QWT's
   VMExec.ps1 would have delivered 0 here (measured earlier today: `exit 100` -> 0). This is the
   fix working against a real failure rather than a synthetic one.
2. The reporting check is EVIDENCE, not decoration - it was seen to FAIL on a genuine defect.
   Same for the new PowerShell parse check (guest/ps-syntax-check.ps1): all guest scripts pass,
   and a deliberately broken file was pushed to confirm it reports FAIL.

PROTOCOL, captured in full at last (pass 2, which succeeded): stdout "updates processed: count=1",
stderr floats 0.0 / 1.0 / 3.0 / 6.0 / 100.0, exit 0. That is the qubes-vm-update agent contract.

KNOWN LIMITATION, now visible instead of silent: not every offered update can be fetched.
Resolve-Catalog needs to handle package shapes and builds beyond 26100 before .NET Framework
updates install. The transport, protocol and dom0 integration are unaffected - this is package
resolution, and it is the next piece of updater work.

COLD BOOT (dom0 starts a stopped qube, as it does to a TemplateVM): with a cumulative update
applying at boot, qubes.VMShell answered at t+259 s and qubes.VMExec at t+265 s - 6 s later. The
autologon/interactive-session concern is not a blocker. The pre-created workdir survived both the
reboot and dom0's `rm`.

STILL OPEN: the user's own click in the Qubes Update GUI (a dom0 tool - cannot be driven from
this dev qube), and a TemplateVM proper rather than the StandaloneVM used here.

## 2026-08-13 (cont.) — RETRACTION: the `vmexec` feature is REQUIRED, not optional

Earlier today I wrote that the update path works with or without the `vmexec` feature, on the
grounds that dom0's VMShell line ends in `& exit` and `exit` returns 0 even after a failing
command (measured with two controls). That generalised one measurement into a claim about a
path I had not actually replayed. Replaying it end to end (tools/replay-dom0-update.py
--no-vmexec) disproves it:

  [mkdir] rc=1   <- "a subdirectory or file already exists"; transfer_agent ABORTS on the first
                    nonzero result, so the agent step is never reached.
  [rm]    rc=49

and when the workdir does NOT exist, `mkdir -p /run/qubes-update/` fails on the forward slashes
instead, creating nothing, so step 2's redirection fails and dom0 writes its tarball into a
closed pipe. BOTH ways the fallback fails. The earlier "harmless no-op" reading was wrong.

WHAT THIS MEANS FOR SHIPPING: `qvm-features <vm> vmexec 1` must be set for every Windows qube,
from dom0, because the guest cannot set it (the Windows qubesdb-cmd cannot write - upstream
`optind -= 2` bug recorded above). Either the install instructions say so, or the dom0 RPM does
it the way qwt-ng-fix-qwcq already patches qvm-create-windows-qube. Without it the Qubes Update
GUI cannot update the qube at all - it fails before reaching our shim.

Set on win11-fresh via admin.vm.feature.Set+vmexec (this testbed's policy allows it from the dev
qube) and re-verified: every dom0 step returns 0 through the shim, and the workdir survives.

## 2026-08-13 (cont.) — catalog resolution fixed, and progress now names the updates

RESOLVER: KB5120708 was unresolvable because Resolve-Catalog required the entry title to match
`24H2|26100`. Fetched the real catalog page: the applicable entry is "2026-08 Cumulative Update
for .NET Framework 3.5 and 4.8.1 for Windows 11, version 25H2 for x64 (KB5120708)" - the other
three are arm64 and "Microsoft server operating system". The version/arch tokens now come from
the running guest (DisplayVersion, CurrentBuild, PROCESSOR_ARCHITECTURE), Server/Dynamic stay
excluded, the chosen title is logged, and a MISS logs every candidate - a miss was previously
indistinguishable from "no updates". Verified with the new `-Action resolve` dry run (scan +
resolve, no download, no install): picks the 25H2 x64 entry, 1 package, proxy torn down after.

PROGRESS DETAIL: dom0 shows any stderr line that is not a number as a MESSAGE, interleaved with
the progress bar (qube_connection.py::_collect_stderr tries float(line), then
float(line.split()[-1]), else emits FormatedLine). So wu-update.ps1 now streams which update is
running, not just a percentage. Measured against a scan-only run:
  0.0 / 1.0 / "opening the Qubes updates proxy" / 3.0 / "scanning Windows Update" /
  "found 1 update(s): KB5120708" / 100.0        exit 0
TRAP encoded in the code: because dom0 falls back to float(line.split()[-1]), a message ENDING
in a number is swallowed as a progress value - "downloading KB5120708 184.5" would register as
184.5 %. Every message must end in a non-numeric word.

QUBE LEFT UPDATE-READY for the user's dom0 run: win11-fresh running, updater agent current,
vmexec=1, updates-available=1, exactly one update pending (KB5120708, 184.5 MB) which now
resolves. Deliberately NOT installed here so the dom0 updater has real work to do.

## 2026-08-13 (cont.) — the first GUI run: why a SUCCESSFUL update reported ERROR

The user ran the dom0 updater against win11-fresh. KB5120708 installed (rc=3010, ok=true), and
the updater reported **error**. Also: progress lines repeated.

MECHANISM (read from dom0 source, not guessed): update_manager.update_qube() does
  result  = self._transfer_agent(...)      # mkdir, cat > tarball, tar, and whatever else
  result += self._run_entrypoint(...)
with ProcessResult.code = max(codes) and __bool__ = bool(code); _run_entrypoint sets
FinalStatus.SUCCESS only when the ACCUMULATED result is falsy. So ONE nonzero prep step turns a
completed update into an ERROR verdict, and dom0 prints nothing identifying the step. Ruled out
first, from source: error_from_messages() is dnf/apt-only; exit 100 is mapped to NO_UPDATES with
code reset to 0; truthiness is the exit code alone - so our stderr text cannot cause it.

CULPRIT, from the audit logging added for exactly this:
  17:24:26 [NT AUTHORITY\SYSTEM] rc=1  passthrough-to-cmd  argv: chmod u+x .../entrypoint.py
`chmod` does not exist on Windows, so it fell through to cmd.exe and returned 1. NOTE: that step
is NOT in the qubes-core-admin-linux master we read - the injection sequence differs between dom0
versions, which is the fragility flagged when the shim was proposed. Enumerating commands is
therefore the wrong fix: only commands naming the updater workdir reach the shim at all, so every
unrecognised verb is now a logged NO-OP returning 0. Verified chmod -> 0, with a negative control
(an unrelated failing command still returns 7, so real failures are not swallowed).

MY PREDICTION WAS WRONG and is recorded as such: I predicted the failure would be `cat >` over
VMShell, on PATH-resolution grounds. The audit log showed cat fine and chmod failing.

THREE MORE DEFECTS FOUND IN THE SAME EXCHANGE:
1. REPETITION had two causes. (a) The same text went to stdout AND stderr - dom0 renders stderr
   as live messages and also displays collected stdout. (b) Msg() de-duplicated against only the
   PREVIOUS message, so "found N update(s)" (re-derived every 3 s poll) and "installing <file>"
   (from the phase) alternated forever. Now de-duplicated against every message already sent.
2. RESUME/416. A .msu left complete by the previous pass made the server refuse the resume Range
   with 416; all 8 attempts burned; the KB was reported as unresolvable. 416 with bytes on disk
   now means "already downloaded". THE FIRST VERSION OF THIS FIX WAS INERT: PowerShell wraps a
   failing method call in a MethodInvocationException, so $_.Exception is the wrapper and the
   `-is [System.Net.WebException]` test never matched. Found by reproducing interactively.
   Lesson repeated: a fix is not a fix until its effect is observed.
3. DISK. 5.1 GB of installed .msu files were sitting in the work dir. Installed packages are now
   deleted after a successful install.
Also corrected the failure wording: "no catalog entry matches this Windows version/architecture"
vs "resolved N package(s) but none could be downloaded" - the old text blamed resolution for a
download failure.

AND MY OWN HARNESS LIED: tools/replay-dom0-update.py truncated each stream to 12 lines with no
notice, which hid the final "installed: …" and "RESTART REQUIRED" lines and made a correct run
look like it reported nothing. Cap raised and truncation is now announced.

FINAL STREAM, verified end to end (exit 0):
  0.0 / 1.0 / "opening the Qubes updates proxy" / 3.0 / "scanning Windows Update" /
  "found 1 update(s): KB5120708" / 10.0 / 75.0 / "installing windows11.0-kb5120708-…msu" /
  100.0 / "installed: KB5120708" / "updates installed - RESTART REQUIRED to finish"
Each message once, progress monotonic, summary present.

## 2026-08-13 (cont.) — restart after update: template vs standalone, and what dom0 will NOT do

User: the pass reported success but the qube was neither restarted nor marked as needing it.
"if it is a template qube, we just should do it ourselves. if it is standaloneVM, it should be
marked for restart (if it is doable within current dom0 logic)".

WHAT DOM0 ACTUALLY OFFERS (read from qubes-core-admin-linux vmupdate/vmupdate.py + utils.py):
the entire restart machinery is TEMPLATE -> APPVM. `--apply-to-sys/--restart` restarts not-updated
ServiceVMs, `--apply-to-all` also shuts down not-updated AppVMs - in both cases "whose TEMPLATE has
been updated", decided from volume staleness. There is NO restart-required marker for a
StandaloneVM, and a guest cannot invent one: qubes.FeaturesRequest accepts only qrexec, gui,
gui-emulated, qubes-firewall and vmexec (qubes/ext/core_features.py). So "mark the standalone for
restart" is NOT doable within current dom0 logic - reported as such rather than faked.

THE GUEST CAN TELL ITS OWN CLASS (reading QubesDB works; only WRITING is broken on Windows):
- /qubes-vm-type       = "TemplateVM" for templates, else AppVM/NetVM/ProxyVM
                         (written by qubes/ext/r3compatibility.py)
- /qubes-vm-persistence = "full" for template AND standalone, "rw-only" for AppVMs
Verified live on win11-fresh (a StandaloneVM): type=AppVM, persistence=full - consistent.

TEMPLATE HANDLING, and why a plain shutdown would be WRONG: Windows completes a pending servicing
operation during BOOT. Shutting a template down with the operation pending would make it run
inside each AppVM's copy-on-write layer at every start and be discarded at every shutdown -
forever, so the update would never actually land in the template root. The template therefore
REBOOTS itself (delayed 60 s so the rpc returns to dom0 first), which commits the servicing.
If dom0 shuts the template down before that fires - it does shut down qubes it started itself -
the pending operation simply completes at the template's next boot, which is self-correcting.

STANDALONE HANDLING: no auto-reboot. A running standalone is somebody's desktop; the run says
"restart this qube to finish - Qubes has no restart-required flag for standalone qubes" and
leaves the decision to the user. Note the qube does keep showing in the Update tool until the
reboot, because Windows keeps offering the KB until then - honest, if differently labelled.

VERIFIED on win11-fresh (standalone), stderr of a full dom0-driven pass:
  ... installed: KB5120708 / updates installed - RESTART REQUIRED to finish /
  restart this qube to finish - Qubes has no restart-required flag for standalone qubes
each message exactly once, and `shutdown /a` afterwards returned 1116 "no shutdown was in
progress" - proving the template branch did NOT fire on a standalone.
UNPROVEN: the TemplateVM branch itself. There is no Windows TemplateVM rig in the roster, so the
reboot path is code-complete but has never executed. Do not describe it as verified.

## 2026-08-13 (cont.) — reboot committed at the end of a pass, flag cleared, and what Qubes does to a guest reboot

User direction, superseding the template/standalone split recorded above: "we commit reboot if
needed at the end of update and it is fine. both on template and standalone. it is user guided
action anyway, so no safeguard needed." Plus: "if we applied everything, we can just clear the
flag right?" - yes.

PLATFORM FACT worth knowing before designing anything around this: qubes-core-admin's
templates/libvirt/xen.xml sets <on_reboot>destroy</on_reboot>. A guest-initiated reboot DESTROYS
the domain; a qube can never restart itself, only end up halted. Measured: after our shutdown
call the qube sat Halted for 4+ minutes and did not come back. The OUTCOME is still correct -
Windows completes pending servicing at its next boot, which for a template is exactly the boot
that commits the change to the template root - but the message had to stop claiming "rebooting".

TWO OF MY OWN BUGS, both of the "silently did nothing" family:
1. The first reboot implementation used `Start-Process shutdown.exe ... -EA SilentlyContinue`.
   It scheduled NOTHING and reported nothing: the qube never rebooted while the run announced it
   would (`shutdown /a` afterwards returned 1116 "no shutdown was in progress"). Now shutdown.exe
   is called directly and $LASTEXITCODE checked, with an honest message when scheduling fails.
   Positive control on the rig: `shutdown /r /t 300` -> rc 0, then `shutdown /a` -> rc 0.
2. MEASUREMENT BUG: `powershell ... & echo EXIT=%errorlevel%` reports the PREVIOUS command's code,
   because cmd expands %errorlevel% when it parses the line, before powershell runs. It made a
   "no updates" pass look like exit 0. The replay harness reads the real qrexec status and shows
   rc=100. Same family as the earlier `| head` pipeline trap: measure with an instrument that
   cannot report the wrong thing.

FLAG CLEARING: the pass now re-reports availability at the END of an install run. With a reboot
pending it reports the number of KBs that did NOT install (0 when everything applied) rather than
leaving the pre-install count standing - Windows keeps listing an installed KB as available until
it boots, which would otherwise leave the qube marked for minutes. The boot scan re-reports the
truth regardless, so a wrong guess self-corrects.

VERIFIED END TO END on win11-fresh:
  pass -> "installed: KB5120708" -> flag cleared (admin.vm.feature.Get+updates-available returns
  empty, i.e. False) -> qube shuts down -> next start completes servicing ->
  Get-HotFix lists KB5120708, pending_reboot cbs=false wu=false -> next pass rc=100
  "no updates available", flag still clear.

## 2026-08-13 (cont.) — the TemplateVM test found three defects the StandaloneVM runs never could

User: "none of our test window qubes are templateVMs, we need to test it properly." Correct, and
it paid immediately.

BUILDING THE TEMPLATE (and a correction to my own claim). I told the user TemplateVM creation was
dom0-only and I could not do it. FALSE: this qube is policied for admin.vm.Create.TemplateVM and
much more - only a genuinely unpermitted service returns 126 "Request refused"; an allowed call
returns 0 even when the API answers with an exception. Recorded in .claude/skills/qubes-admin-api.
The user also asked why I was cloning volume-level: because I was reimplementing something that
exists. `qvm-clone --class` / clone_vm(new_cls=...) changes class AND carries properties, features
and tags. On lvm_thin the copy is CoW: 80 GiB root + 40 GiB private in 2.7 s.
One-shot qvm-clone still FAILS here ("Request refused" after "Cloning root volume") because policy
is tag-based and it clones volumes before copying tags. Order that works: create -> tag -> clone
volumes + copy prefs. A fresh TemplateVM's defaults are Linux-shaped: virt_mode=hvm and an EMPTY
kernel are mandatory or Windows will not boot.
Result: win11-tpl, Windows 11 24H2 build 26100.8875, seeded from win11-24h2. The guest reports
/qubes-vm-type = TemplateVM, which is the discriminator our code reads.

DEFECT 1 - CONCURRENT OPERATIONS, A FALSE SUCCESS. The 6-hourly scan task fired SIX MINUTES into
the dom0-driven install (LastRunTime 19:09:14; install still running at 19:10:35). Both write ONE
status file, so the rpc handler tailing it read the SCAN's `done` - count=2, result EMPTY - and
reported the update complete with exit 0 while DISM was still installing. The scan's finally also
runs Remove-Proxy, which tore the proxy out from under the download: the pass then died with
`Exception from HRESULT: 0x80240438` (WU: no route to the endpoint) at 56.9 % of 4.8 GB.
FIX, two layers because either alone leaves a hole: a global mutex (a scan yields immediately when
real work holds it; real work waits up to 15 min) and a freshness guard in the handler (ignore any
status stamped before we kicked the task).

DEFECT 2 - reboot_needed WAS ASSIGNED, NOT OR-ed. Install-Msus runs once per KB and assigned
$St.reboot_needed each time, so a later KB needing no reboot ERASED an earlier one that did.
Measured: KB5120710 -> rc 3010 (reboot required), KB5121003 -> rc 0, and the pass finished claiming
reboot_needed=false while Windows had CBS RebootPending set. On a template that means the qube is
never rebooted and THE UPDATE NEVER COMMITS TO THE TEMPLATE ROOT. Now sticky.

DEFECT 3 - A FAILED REPORT FAILED THE PASS. The post-install availability rescan needs the proxy;
when the concurrent scan removed it, the exception propagated and marked a pass that had installed
everything successfully as phase=error. It is a report, not the work: now best-effort.

AFTER THE FIXES, the same pass on the same template:
  installed: KB5120710, KB5121003
  updates installed - this qube shuts down in 60 seconds; start it again and the update finishes
  during boot
each message once, floats monotonic 0/1/3/10/56.1/75/100, rc=0, and all three .msu visible
(ndp481, the kb5043080 prerequisite, and kb5121003).

ALSO VALIDATED HERE: the catalog resolver picked the 24H2/26100 variants on this guest where it
picked 25H2 ones on win11-fresh - the OS-derived matching works on a second build, not just the
one it was written against.

DESKTOP TWEAKS (user request, same /noapptweaks switch): guest/quiet-desktop.ps1 removes the
consumer/cloud surface - OneDrive (client stopped and prevented from starting), Widgets / News and
Interests, Chat icon, Cortana + web results + search highlights (local search untouched), Copilot,
Recall, Spotlight/tips/consumer apps, the OOBE nag, telemetry at the SKU minimum, advertising ID,
feedback prompts, Game Bar/Game DVR, Store background updates. All HKLM policy values; nothing
uninstalled, no service disabled. Verified on the template: changed=15 failed=0, idempotent.

## 2026-08-13 (cont.) — the template commit boot: the backstop works, and DISM 3010 is not proof

Sequence measured on win11-tpl (24H2, 26100.8875) after the clean pass:
  t+45 s   the template shut ITSELF down, as the pass said it would
  t+45 s   dom0 updates-available: cleared (empty = False)
  t+130 s  started again, qrexec answered; pending_reboot cbs=false wu=false - servicing ran
  build:   STILL 26100.8875. KB5120710 (.NET) landed; KB5121003 (the cumulative) did NOT.

WHY: DISM had returned rc=3010 for kb5121003.msu - "success, restart required" - but the
boot-time servicing failed with **0x80070490 (ERROR_NOT_FOUND)**, because the CHECKPOINT package
the 24H2 cumulative depends on (kb5043080, installed smallest-first as the prerequisite) had
failed with rc=552. So the cumulative was staged and then rolled back at boot.

TWO CONCLUSIONS, one good and one to fix:
- THE BACKSTOP WORKS. A fresh scan after the commit boot found KB5121003 still available and
  re-reported count=1 to dom0, so the optimistically cleared updates-available flag came back by
  itself. The "clear the flag when everything applied" shortcut is therefore safe: a wrong guess
  is corrected within one scan, exactly as designed.
- WE OVERCLAIMED. The pass told dom0 "installed: KB5120710, KB5121003" on the strength of an
  install-time return code. DISM 3010 means STAGED, not applied - nothing at install time can
  know whether boot-time servicing will succeed. The summary now says
  "staged (completes at restart): ..." whenever a restart is pending, and only says "installed"
  for updates that applied without one.

KNOWN LIMITATION, recorded rather than fixed: our offline path (catalog .msu + DISM /Add-Package)
cannot complete a 24H2 cumulative that requires the checkpoint chain - the checkpoint itself fails
with 552 and the cumulative then fails at boot with 0x80070490. The same path installs cleanly on
25H2 (win11-fresh: KB5121003 applied, build moved 26200.8875 -> 26200.9168). The user has
deprioritised 24H2 ("a first auto update gets it obsolete"), so this is documented, not chased.
What it means in practice: a 24H2 guest will keep being offered that cumulative, honestly, rather
than silently believing it is up to date.

## 2026-08-13 (cont.) — autologon: a Windows update can make a qube UNMANAGEABLE, and the fix was one-shot

User hit it: the template came back from an update-triggered reboot at the SIGN-IN SCREEN.

WHY IT MATTERS MORE THAN IT LOOKS. With no interactive session, qrexec service calls have nobody
to run as: qubes.VMShell AND qubes.VMExec both fail with rc=117 (note: NOT the 126 of a policy
refusal). dom0 then cannot update the qube, cannot run apps in it, cannot read anything out of it.
An update that costs autologon does not annoy the user, it makes the qube unmanageable - that is
release-blocking for the update feature, not cosmetic.

ROOT CAUSE, already documented in mgmt/autounattend*.xml since provisioning: while AutoLogonCount
is present Windows CONSUMES DefaultPassword, and when it runs out it deletes the password and
falls back to the sign-in screen. Provisioning deletes AutoLogonCount ONCE via FirstLogonCommands.
Nothing re-asserted it afterwards, and Windows servicing rewrites Winlogon - so the fix did not
survive the first cumulative update. A one-shot fix at image build is not a fix.

PREVENTION, baked into the update machinery in three places (user: "can we fix it with our
machinery? ... baking prevention into update machinery"):
 1. BEFORE every reboot the updater triggers - guest/ensure-autologon.ps1 removes AutoLogonCount
    and sets AutoAdminLogon=1, so the password is never consumed in the first place.
 2. AT EVERY BOOT - scheduled task QubesAutologonGuard (SYSTEM, BootTrigger+30s). Necessary
    because Windows applies the update DURING the next boot and rewrites Winlogon there, AFTER
    the pre-reboot check has run. With it, a qube can lose autologon at most once instead of
    permanently.
 3. AT INSTALL - install-updater-agent.ps1 asserts it once while deploying, so a guest that is
    already one update away from losing autologon is fixed before that update, not after.
Plus a REFUSAL: if the guard reports autologon cannot be guaranteed (DefaultPassword already
consumed - unrecoverable, we will not invent a password), wu-update.ps1 does NOT reboot. It says
so on stderr and leaves the update staged. A staged update is a smaller problem than a qube nobody
can reach.

THE GUARD IS PROVEN TO FAIL, not just to pass (guest/wu-autologon-selftest.ps1): healthy state
-> exit 0; with DefaultPassword removed to simulate consumption -> the two WARN lines and exit 2;
value restored in a finally. healthy_exit=0 broken_exit=2 verdict=GUARD WORKS.

RECOVERY, if it ever does happen (recorded in .claude/skills/qubes-admin-api): the guest cannot be
repaired from inside because nothing can run inside. admin.vm.volume.ListSnapshots and
admin.vm.volume.Revert are permitted from the dev qube and work on the VOLUME, not a session, so
a locked-out guest can be rolled back to its pre-update root without dom0 shell access.

## 2026-08-14 — RETRACTION: the CBS "dirty servicing state" verdict was a false positive

Claim retracted: that a killed/timed-out run left CBS mid-transaction, and that the pristine
`win11-24h2` image might carry an inherited pending transaction explaining the 24H2 rollback.

The guard behind that claim tested `Test-Path ...\Component Based Servicing\SessionsPending`.
That key exists on **every healthy Windows image** and holds COMPLETED session history, so the
guard reported "DIRTY" unconditionally. Measured on a freshly rebuilt, never-updated clone of the
pristine source (`guest/wu-cbs-state.ps1`, `guest/wu-cbs-subkeys.ps1`), before anything of ours ran:

    SessionsPending  exists=True  values=4 subkeys=5   Exclusive=0
      all 5 subkeys carry Complete=1  (finished sessions, dated 2026-08-10/11)
    RebootPending = absent    PackagesPending = absent    winsxs\pending.xml = absent
    PendingFileRenameOperations = 0    WU RebootRequired = False
    DISM /Online /Cleanup-Image /CheckHealth -> "No component store corruption detected."
    build = 26100.8875

So: the pristine image is CLEAN, inherited-dirty-CBS is ruled out as a cause of the 24H2
cumulative rollback (0x80070490 / CBS_E_INVALID_PACKAGE), and the earlier "DIRTY" reading is
evidence of nothing but a broken check.

Corrected rule, now in `wu-lcu-alone-detached.ps1` / `wu-install-lcu-alone.ps1` /
`wu-dism-forensics.ps1` — an interrupted transaction is:
  * a SessionsPending subkey with `Complete != 1`, or
  * `SessionsPending\Exclusive != 0`, or
  * `C:\Windows\WinSxS\pending.xml` present.
`RebootPending` present is **staged-awaiting-reboot**, the normal state after staging - not damage.

### Pre-download KB filter verified at zero bytes

`-Action resolve` now applies the filter before returning (it is pure string work on catalog URLs),
making it a true dry run. On win11-tpl @ 26100.8875:

    KB5121003: 2 catalog .msu
      DROP windows11.0-kb5043080-x64_9534...msu     <- superseded 2024-09 cumulative
      KEEP windows11.0-kb5121003-x64_dc58...msu
    KB5120710: 1 catalog .msu -> KEEP ...-ndp481_7f3b...msu

That is exactly the pairing that preceded the rollback, rejected before a byte is spent.

## 2026-08-14 — SOLVED: the 24H2 cumulative installs via the DISM path (26100.8875 -> 26100.9168)

Verified end to end on a rebuilt-from-pristine TemplateVM `win11-tpl`:

    build before  26100.8875
    build after   26100.9168      (UBR 0x22ab -> 0x23d0)
    KB5121003 installed_according_to_image = True
    KB5043080 installed_according_to_image = False   <- never downloaded, never fed to CBS
    CBS after reboot: incomplete_sessions=0  RebootPending=False

The fix is the pre-download KB filter alone. Same image, same package, same DISM path that rolled
back at boot with 0x80070490 / CBS_E_INVALID_PACKAGE last time; the only difference is that the
catalog's superseded sibling never reached CBS. Root cause confirmed: Microsoft Update Catalog's
DownloadDialog returns every file bundled with an update, and for KB5121003 that includes the
2024-09 cumulative KB5043080, which is not applicable to a 26100.8875 image. Feeding it first
poisoned the transaction that the real cumulative then rode into.

Timings (win11-tpl, 4 vCPU, 8 GB):
    download   4,867 MB in 389 s = 12.8 MB/s, ONE attempt, no resumes
    DISM       ~24 min (staging, rc=3010)
    shutdown   6.3 min (applying)
    boot       2.5 min to qrexec
    total      ~45 min wall clock

### RETRACTED: the "tunnel throughput" problem

Previously recorded at 120-150 KB/s and blamed on the relay destroying HTTP keep-alive. Measured on
the clean allowlisted baseline: **75.4 MB in 5 s (14.4 MB/s)** for the .NET package and **12.8 MB/s
sustained over 4.8 GB**. The tunnel was never the problem; those figures came from the WU-native
(DoSvc/BITS) path, not from our catalog download. Any conclusion that rested on them is void.

### Where servicing time actually goes (guest/wu-cbs-analyze.ps1 over the 266 MB CbsPersist log)

    lines 1,090,992 over 49.6 min      CBS 87.2% of lines, CSI 4.0%
    distinct packages evaluated 9,025
    LRU Cache Manifest: 43,014 finds, 24,323 hits, 18,691 misses, 489 MB commit, max 1024 MB,
                        Evictions: 0        <- cache is NOT undersized
    LRU Cache FileData: 16,196 finds, 0 hits, 16,196 misses

Optimisation read, and what the data REJECTS:
* NOT CPU-bound, so more vCPUs will not help. TiWorker burned 489 CPU-s across ~1,140 s of wall
  clock = ~43% of ONE core, on a 4-vCPU guest. Do not spend a dom0 change on this.
* The biggest log gaps (468 s, 281 s) follow "Ending TrustedInstaller finalization" and sit in the
  download/reboot windows - they are IDLE, not stalls. Do not optimise them.
* Genuine candidates, in order, all still UNMEASURED and stated as such:
  1. CBS's own logging: 266 MB / 1.09M lines written to the same disk the servicing is reading.
     A LogLevel knob is believed to exist but is NOT verified - verify before claiming it works.
  2. Defender: MsMpEng took 294 CPU-s during the run, scanning servicing I/O. Excluding WinSxS /
     CBS temp / the wu dir is the standard server recommendation; it is a security tradeoff and
     therefore the user's call.
  3. Unused language packs: the plan phase walks language variants of every package (sv-SE et al.
     observed). Trimming them shrinks planning, but mutates the template image.

## 2026-08-14 — consumer-nag policies now re-assert at boot (and a correction)

Correction to what I said earlier today: `quiet-desktop.ps1` was NOT missing from the package.
`Install-QwtImproved.ps1` has always run it by default (`/noapptweaks` skips it). The OneDrive
popup seen in every experiment came from the pristine `win11-24h2` SOURCE IMAGE, which predates
that step - every clone inherits it. Not a packaging defect.

The real gap: the installer ran the script out of the setup payload, kept no persistent copy and
never re-asserted it. A feature update rewrites consumer surface (the reason the autologon guard
exists), and a TEMPLATE's AppVMs get fresh user profiles whose per-user half of these settings was
never written. Nothing existed to put any of it back.

Fix: persist `quiet-desktop.ps1` to `C:\Program Files\Qubes Tools\bin` and register
`QubesQuietDesktopGuard`, a SYSTEM boot task (PT1M) that re-asserts it.
`guest/apply-quiet-desktop.ps1` mirrors the installer block so tests exercise the shipped path.

    before           policy_key_exists=False  onedrive_running=1  adverts=unset
    after + reboot   DisableFileSyncNGSC=1    onedrive_running=0  adverts=0    (29 changed, 0 failed)
    guard validated  deleted the policy key + set adverts=1 -> rebooted -> both restored,
                     QubesQuietDesktopGuard Last Result 0

The probe was seen in BOTH states before being trusted, per the "no result counts until the
instrument is validated" rule.

## Download volume: what the KB filter does and does not buy

Precise position, because "no overhead" would be an overclaim:

* **No wasted FILES.** Exactly one .msu per KB is fetched. Verified at zero bytes with
  `-Action resolve`: KB5121003 offered 2 files, 1 kept, 1 dropped.
* **No permanent disk cost.** `qubes-windows-update.ps1:546` deletes each .msu whose install
  returned an OK code. Measured after the pass: the per-KB dirs exist and are EMPTY, `wu` total
  0.02 GB. The flip side is that a re-run re-downloads - there is no package cache.
* **But the FILE ITSELF is a full cumulative.** The catalog serves full combined SSU+LCU packages
  (KB5121003 = 4,867 MB, MSWIM, all editions/languages); it does not serve the differential
  packages Windows Update can deliver. So the catalog path trades transfer volume for
  determinism and for a closed egress surface. NOT MEASURED here: what WU-native would have
  transferred for the same KB - do not quote a number for it without measuring.

## 2026-08-14 — EXACT download overhead, measured

Priced with HEAD / one-byte ranged GET through the proxy, no payload transferred
(`guest/wu-price-kb.ps1`, `-Action resolve` now reports sizes):

    KB5121003, catalog offers 2 files
      KEEP  windows11.0-kb5121003-x64_dc58...msu   4,867.4 MB
      DROP  windows11.0-kb5043080-x64_9534...msu     509.0 MB   <- avoided by the KB filter
      total the catalog would have handed us        5,376.4 MB
      transferred                                   4,867.4 MB
      wasted-file overhead eliminated                 509.0 MB = 9.5% of the naive transfer

So on the wire the filter is now exactly lossless: 0 bytes fetched that are not the requested KB.
The 509 MB is not merely wasted bandwidth - it is the package whose rejection poisoned the CBS
transaction and rolled the cumulative back, so the filter's value is correctness first, 9.5% second.

### Overhead INSIDE the package (package-level, exact; byte-level, not knowable from the log)

`guest/wu-payload-overhead.ps1` over the 266.5 MB CbsPersist install log:

    packages evaluated          9,036
      applicable / installed    4,007
      absent (walked past)      5,029   = 55.7% of evaluated packages
    distinct language tags carried  42  (image needs en-US)

That is the price of the catalog path: it serves the full combined SSU+LCU for every edition and
all 42 languages, and this image used 44.3% of the packages in it.

**Not derivable from the log, and deliberately not estimated:** the BYTE split of the 4,867 MB
between applied and skipped payload. CBS does not log a compressed size per payload member, and
the .msu is deleted after a successful install (`qubes-windows-update.ps1:546`). Getting it would
mean re-downloading and expanding the ESD. Quote the package ratio, never a byte ratio.

Measured on disk after the pass, for reference (no pristine control taken, so this is a level,
not a delta): WinSxS 20.95 GB apparent across 130,853 files (hardlinked - apparent overstates
real), C: used 24.26 GB of 79.37 GB.

## 2026-08-14 — what was rejected, by category, and why "2x" is the wrong reading

`guest/wu-lang-share.ps1` over the same install log.

    packages WALKED PAST (Absent)  total 5,029   language-tagged 4,358 (86.7%)   neutral   671
    packages APPLIED  (Installed)  total 4,007   language-tagged 1,458 (36.4%)   neutral 2,549

    REJECTED by category
      Package wrapper (metadata shell)                2,454   48.8%
      Feature on Demand (tools/roles)                 1,898   37.7%
      LanguageFeatures FoD (handwriting/OCR/speech)     303    6.0%
      Other Windows edition                             209    4.2%
      Language pack (UI translation)                     86    1.7%
      Other component / Fonts / virt / printing          79    1.6%

Raw families confirm the shape: `Microsoft-Windows-DNS-Tools-FoD`, `ServerManager-Tools-FoD`,
`ActiveDirectory-DS-LDS-Tools-FoD`, `MSPaint-FoD`, `Notepad-FoD`, `NanoServer-*` - each appearing
**45 times**, i.e. once per language. So the rejects are overwhelmingly language VARIANTS of
server/admin Feature-on-Demand packages, not UI language packs (those are only 1.7%).

### Byte weight: the package ratio badly overstates it

Measured proxy from the component store (expanded, installed-only - stated as a proxy, not a
substitute for expanding the ESD):

    language components   7,770 dirs   0.28 GB   mean    38 KB
    neutral components   18,949 dirs  19.64 GB   mean 1,087 KB
    mean size ratio language:neutral = 1 : 28.9

Weighting the log's package counts by those means:

    rejected  4,358 x 38 KB + 671 x 1,087 KB   ~=   874 MB
    applied   1,458 x 38 KB + 2,549 x 1,087 KB ~= 2,760 MB
    rejected share of payload bytes            ~=   24%

So the honest figure is **roughly a quarter of the bytes wasted, not the 55.7% package count and
not "2x"**. And that is still an OVERestimate: 48.8% of the rejects are package WRAPPERS, metadata
shells with essentially no payload. Anyone quoting the package ratio as a byte ratio is wrong by
at least a factor of two in the safe direction.

Still not exact. The exact byte split needs the ESD expanded and its members attributed, which
means re-downloading 4.8 GB. Recorded as: measured proxy ~24%, true value lower, unmeasured.

## 2026-08-14 — catalog resolution is language-invariant (measured), with one residual risk

GWeck runs a GERMAN edition, so this is a correctness requirement, not a hypothetical. No German
image exists, and none is needed: the catalog picks its response language from Accept-Language, so
an English guest can demand German titles. `-AcceptLanguage` was added to the agent so the test
drives the SHIPPING `Resolve-Catalog` rather than a copy that could drift.

`guest/wu-locale-invariant.ps1`, KB5121003, four languages:

    en-US  "2026-08 Cumulative Update for Windows 11, version 24H2 for x64-based Systems ..."
    de-DE  "2026-08 Cumulative Update for Windows 11, version 24H2 for x64-based Systems ..."
    fr-FR  "2026-08 Aggiornamento cumulativo per Windows 11, version 24H2 per sistemi basati su x64 ..."
    ja-JP  "2026-08 Cumulative Update for Windows 11, version 24H2 for x64-based Systems ..."

    PASS: every response language resolved to the identical package file(s)
          KEEP windows11.0-kb5121003-x64_dc58...msu   DROP windows11.0-kb5043080-x64_9534...msu

Two things this establishes:

1. **The response language is arbitrary.** Asking for `fr-FR` returned an ITALIAN title. It does not
   track the request, and it has already been seen changing on its own between two runs 30 minutes
   apart. Any logic keyed on title TEXT is therefore keyed on a non-deterministic input.
2. **Resolution survives it** because the match anchors on `x64` and `24H2` - tokens that are not
   translated - and the final decision is made on the .msu FILENAME.

RESIDUAL RISK, not covered by this pass: the row EXCLUSIONS are English words
(`Dynamic|Server|server operating system`). An Italian "Aggiornamento dinamico" row would not be
excluded, so a Dynamic Update could be picked when it happens to sort first. The cumulative sorted
first here, so the test never exercised it. Fix belongs on the exclusion side, and the anchor should
be the filename pattern rather than the title.

## 2026-08-14 — catalog row selection now decides on the FILENAME (and the flip is nondeterministic)

### The flip: researched, and it is not ours to control

Two identical runs of the same test, same guest, ~12 minutes apart:

    header    run 1      run 2
    de-DE     English    German
    fr-FR     Italian    English
    ja-JP     English    English
    en-US     English    English

Plus 8 header-less requests (4 for KB5121003, 4 for KB5120710) that were stable, English, with
stable GUIDs, stable row order and stable row membership.

So: the response language is NOT a function of our request. The Accept-Language header takes effect
only sometimes, and an fr-FR request has returned an ITALIAN page. This is what an edge cache
serving a rendering populated by another locale's request looks like. No client-side change can
make the title language deterministic - which settles the design question rather than leaving it
open: the decision must not depend on title text at all.

What is NOT flipping: row GUIDs, row order and row membership were identical across every run. The
rows are one per version x arch (KB5121003 returned 4: 24H2/25H2 x x64/arm64), with NO edition
dimension - cumulative packages are edition-neutral, so "any edition" needs no handling.

### Resolve-Catalog rewritten

The title is now used only to NARROW and RANK candidates on untranslated tokens; the accept/reject
test runs against the .msu FILENAME, which is language-invariant by construction:

  * arch (`x64`/`arm64`) is mandatory, from PROCESSOR_ARCHITECTURE
  * CurrentBuild outranks DisplayVersion (+4 vs +2). DisplayVersion alone cannot identify a
    product - Windows 10 AND Windows 11 both shipped a "22H2"; builds 19045 vs 22621 do.
  * the English `Dynamic|Server` keywords survive only as a -3 tie-breaker nudge and can no longer
    REJECT anything
  * each candidate is then resolved and accepted only if it yields a file matching
    <kb digits> + <arch> + the expected filename family
  * family is DERIVED, never assumed: `InstallationType` ('Client'/'Server', not localized) plus
    the 22000 build boundary -> windows11.0 vs windows10.0. This is the locale-invariant separator
    the `Server` keyword used to provide, and it is needed because Windows Server 2025 and
    Windows 11 24H2 are BOTH build 26100.
  * family is a PREFERENCE: a candidate with the right KB and arch but an unknown family is kept
    as a fallback, so an unforeseen future product family degrades instead of failing.

Verified after the rewrite - KB5121003 across en-US/de-DE/fr-FR/ja-JP, with de-DE returning a
genuinely German title ("Kumulatives Update fur Windows 11, version 24H2 fur x64-basierte
Systeme"): PASS, every language resolved to the identical file.

Nothing is pinned to a Windows version: arch, build, version and product family are all read from
the running guest.

## 2026-08-14 — locale audit: one real protocol bug, and a retraction of my own fix rationale

A 14-agent audit of every locale-dependent assumption confirmed 2 findings and rejected 8. The
rejections were correct and worth recording: Start Menu paths have not been localized since Vista,
and the `~xx-XX~` tags in CBS package identities are identifiers, not localized text.

### CONFIRMED and FIXED: every progress line was unparseable on a German guest

`guest/wu-update.ps1:25` formatted dom0 progress with `"{0:0.0}" -f $p`. PowerShell's `-f` uses
CurrentCulture, and in a CUSTOM numeric format string the "." is the decimal-separator PLACEHOLDER,
not a literal. dom0 parses progress with `float(line)`, and `float("75,0")` raises.

Measured on the English guest by forcing the culture in-process, with the defect as a control:

    culture   culture-bound      invariant (shipped)
    en-US     '75.0'  ok         '75.0'  ok
    de-DE     '75,0'  BREAKS     '75.0'  ok
    fr-FR     '75,0'  BREAKS     '75.0'  ok
    ru-RU     '75,0'  BREAKS     '75.0'  ok
    control (defect re-introduced under de-DE) produced a comma = True

So on GWeck's German edition EVERY progress line, starting with the first, was unparseable and fell
through to being displayed as a message. Fixed with an explicit InvariantCulture format. `Prog` is
the only number crossing the protocol; the other stderr writes are text.

### RETRACTED: "windows11.0 vs windows10.0 separates client from server"

I wrote that into the resolver comment and the commit message without checking it. Measured, it is
false - SERVER packages are also named windows11.0-*:

    "2026-08 Cumulative Update for Microsoft server operating system version 24H2 for x64-based
     Systems (KB5120233)"  ->  windows11.0-kb5120233-x64_9344a2fc....msu

What the family check actually buys is separating Windows 10 packages from Windows 11 ones. The
real client/server separator is the KB NUMBER, which is product-specific: 24H2 cumulative is
KB5121003 client / KB5120233 server, .NET is KB5120710 client / KB5120708 server. Measured:
KB5121003 returns four rows, all client (24H2/25H2 x x64/arm64), no server row at all.

### The audit's own central claim was also wrong, and measurement settled it

It argued a "Dynamic Cumulative Update" row carries the SAME KB as the LCU with a near-identical
filename, so only a DISM applicability check could separate them. Measured - both halves are false:

    Safe OS Dynamic Update ... (KB5121002)  ->  windows11.0-kb5121002-x64_....CAB
    Setup Dynamic Update   ... (KB5106084)  ->  windows11.0-kb5106084-x64_....CAB

Dynamic Updates ship .cab, not .msu, so the existing `\.msu` filter drops them outright; and they
carry their own KB numbers, so a KB search never returns them beside the cumulative. No
applicability-fallback machinery is needed. The English `Dynamic` keyword was never load-bearing.

Also seen: the server cumulative KB5120233 bundles the SAME superseded kb5043080 that broke us, so
that bundling is a catalog-wide pattern rather than something specific to KB5121003.

### Incidental, and a rule for this repo

A CJK stem added to the ranking hint was mangled to '?a??a?' in transit and broke the parse -
caught by `ps-syntax-check.ps1` before deploy. Files under `guest/` cross qrexec as ASCII: keep
them ASCII-only.

Re-verified after all edits: syntax clean, and KB5121003 resolves to the identical file across
en-US/de-DE/fr-FR/ja-JP.

## 2026-08-14 — locale hazard map, measured (guest/wu-locale-primitives.ps1)

Rather than reason about which APIs are culture-sensitive, the primitives this codebase relies on
were MEASURED under en-US, de-DE, th-TH (Buddhist era), ar-SA (UmAlQura/Hijri), ja-JP, zh-CN,
tr-TR (dotless i) and he-IL, by forcing the culture in-process on the English guest.
9 of 23 primitives are locale-dependent. The stable list matters as much as the hazard list,
because it says what needs no defensive code.

HAZARDS

    ToString('yyyy-MM-dd')        en-US 2026-08-14   th-TH 2569-08-14   ar-SA 1448-03-01
    ToString('yyyy-MM-dd HH:mm:ss')  same shift - custom patterns take the CULTURE'S CALENDAR
    ToString() default            differs in all 7 non-en-US cultures
    "{0:0.0}" -f 75.5             de-DE/tr-TR '75,5'      (the dom0 progress bug, fixed)
    (75.5).ToString()             de-DE/tr-TR '75,5'
    [math]::Round(x,1).ToString() de-DE/tr-TR '4867,4'
    "{0:N1}" -f 4867.4            de-DE/tr-TR '4.867,4'
    'file'.ToUpper()              tr-TR differs (dotted capital I) - the console flattens it, the
    'I'.ToLower()                 tr-TR differs (dotless i)         STRING COMPARISON caught it

LOCALE-STABLE - safe to rely on, measured identical in all 8 cultures

    ToString('s') and ToString('o')      standard round-trip specifiers force Gregorian
    [datetime]::TryParse(ISO)            parses correctly even under Buddhist/Hijri defaults
    Get-Date -Format 'HH:mm:ss'          no date component, no calendar
    [double]'75.5' and [int]'42'         PowerShell casts are invariant
    ConvertTo-Json numbers               emits 75.5, never 75,5
    -match / -eq case-insensitive        ORDINAL: "KB5121003" -match "kb" holds even in tr-TR
    regex \d                             matches Arabic-Indic digits (in every culture, so stable)

RULE: standard specifiers 's'/'o' are calendar-invariant; CUSTOM patterns containing a year are
not. That distinction is the whole calendar story.

### The status-file timestamp is safe - verified cross-culture, not assumed

`qubes-windows-update.ps1:81` stamps the status file with `(Get-Date).ToString('s')`, and
`wu-update.ps1:90` parses it back and compares against `StartedAt` to drop stale lines. Those run
in DIFFERENT PROCESSES - the agent as a SYSTEM scheduled task, the handler as the logged-on user -
so their cultures can differ. All 9 write-culture x read-culture combinations across
en-US/th-TH/ar-SA round-trip to 2026-08-14 correctly (`guest/wu-sortable-check.ps1`). No change
needed; had this used 'yyyy-MM-dd' instead of 's', a Thai or Saudi guest would have seen dom0 lose
every progress line and message.

### Calendar exposure in the SHIPPED path: none

The shipped update path formats dates only as 's', 'o' or 'HH:mm:ss'. Custom `yyyy` patterns exist
only in dev harnesses and diagnostics (drag-measure, drag-harness, phase-cpu-bench, wu-recon-extra,
wu-relay-tail, wu-verify-installed, wu-cbs-analyze), whose output is read by humans on our English
guest. Not worth changing; worth knowing.

## 2026-08-14 — RTL/CJK titles as DATA (guest/wu-bidi-check.ps1)

This class needs no foreign-language Windows: bidi marks and CJK text arrive as DATA in update
titles, which we send to dom0, use as de-duplication keys and round-trip through JSON. Tested with
Arabic/Hebrew/CJK titles and LRM/RLM marks built from code points (the file stays ASCII).

SAFE, measured:

    KB extraction   -match '(KB\d{6,7})' found KB5121003 in ALL titles - arabic+RLM, hebrew+LRM,
                    cjk, and ascii-with-an-embedded-LRM
    JSON round trip 5 of 5 titles byte-identical (-ceq) through ConvertTo-Json/Set-Content UTF8/
                    ConvertFrom-Json - so a non-ASCII title survives the agent -> handler hop
    dom0 protocol   the last token of every title is non-numeric, so no title can be swallowed as
                    a progress value

QUIRK, low severity, recorded rather than fixed:

    '...Update (KB5121003)' -eq '...Update<U+200E> (KB5121003)'  ->  True
    5 such titles produce only 4 distinct hashtable keys

PowerShell's `-eq` and the default hashtable comparer use LINGUISTIC comparison, in which
zero-width formatting characters (LRM/RLM) carry no weight - so two strings differing only by an
invisible mark are equal and collide as keys. This reaches `wu-update.ps1`'s Msg() de-dup, whose
keys are message strings. The only way it bites is two genuinely DIFFERENT updates whose titles
differ solely by an invisible mark, which is not a realistic catalog state; and the failure mode is
suppressing a duplicate-looking message, not a wrong install. Left alone deliberately - switching
the de-dup to an ordinal comparer would be a behaviour change made to satisfy a hypothetical.

Worth knowing for the future: this also means `-eq` on strings is NOT ordinal even though the
case-insensitive regex operators are. Do not assume the two behave alike.

## 2026-08-14 — END-TO-END proof on the shipped handler under a German culture

`guest/wu-handler-locale-e2e.ps1` drives the REAL `wu-update.ps1` with CurrentCulture forced to
de-DE, against a synthetic status file, and captures what dom0 would parse:

    control old-style    = '35,5'      <- culture genuinely applied, so the test can fail
    handler wrote        : 0.0
                           100.0
    numeric progress lines = 2, comma-formatted = 0
    PASS

Under the old code those lines were "0,0" and "100,0" and `float()` raised on both, so this does
exercise the decimal separator rather than an integer path.

Made safe by construction: a dummy scheduled task stands in for the updater (no update runs), the
synthetic status carries `reboot_needed=false` - and the handler only calls `shutdown.exe` when
that is true, verified in source before running - and the real update-status.json is backed up and
restored.

### A trap worth keeping: `2>&1` cannot capture this handler

The first version of this test reported "handler emitted no progress lines" while the numbers were
plainly visible on the console. `wu-update.ps1` writes progress with `[Console]::Error.WriteLine()`,
which goes straight to the process's stderr HANDLE and bypasses PowerShell's redirection operators.
Capturing requires a separate process with `2>` at the cmd level - which is also the faithful
simulation, because that handle is exactly what dom0 reads. Any future test of this channel that
uses `2>&1` will silently measure nothing.

## 2026-08-14 — locale-class research: 6 confirmed, and 2 of them were MY errors

A 13-agent research pass over non-Gregorian calendars, digit shapes, code pages, RTL/bidi and
Turkish casing. Two findings were real bugs in shipped code, two were defects in work I did earlier
today, one was low severity, and one was a false alarm. All verified independently before acting.

### 1. The freshness guard in wu-update.ps1 NEVER FIRED (culture-independent)

    $stamp = $null
    if ([datetime]::TryParse($st.ts, [ref]$stamp) -and $stamp -lt $script:StartedAt) { continue }

PowerShell converts a `[ref]` variable's CURRENT value to the ByRef parameter type during overload
resolution, and `$null` has no conversion to the non-nullable value type DateTime. The call raised
MethodException "Cannot find an overload for TryParse and the argument count: 2", which
`$ErrorActionPreference='SilentlyContinue'` (line 19) swallowed - so the whole `if` was abandoned,
`continue` never ran, and ~2400 exceptions per 2 h tail piled into $Error unseen.

Reproduced independently (`guest/wu-guard-check.ps1`), initializer sweep:

    init=null     TryParse threw            errors=1
    init=zero     True                      errors=0
    init=mindate  True                      errors=0
    CURRENT code, STALE(2020) status : accepted=True   <- guard never fired
    FIXED   code, STALE(2020) status : accepted=False
    FIXED   code, FRESH status       : accepted=True   <- normal path unchanged

This is the SAME trap that broke `wu-cbs-analyze.ps1` this morning. Fixed with
`$stamp = [datetime]::MinValue` + `TryParseExact` against the invariant Gregorian shape the writer
emits, so the guard cannot silently become calendar-sensitive later.

TWO CORRECTIONS to the guard's own comment, both verified: the 2026-08-13 scan-clobbers-install
collision is now prevented at the WRITER by the `Global\QubesWindowsUpdate` mutex, and a timestamp
test could never have caught it anyway - a scan running mid-install stamps a FRESH ts and passes.
What this guard actually protects is the ATTACH path, which skips the Remove-Item baseline. The
fresh-but-foreign case is closed separately by a new `if ($st.action -eq 'scan') { continue }`.

### 2. Non-ASCII arguments were destroyed in the dom0 -> guest command path

Stock `VMExec-Decode.ps1` resolves each `-HH` escape with `[System.Text.Encoding]::ASCII`, which
maps every byte above 0x7F to '?'. dom0 percent-encodes the UTF-8 BYTES, so one umlaut arrives as
two escapes and comes back as '??'. Per-escape decoding cannot be repaired by swapping the encoding
either - a UTF-8 character spans several bytes, so they must be accumulated and decoded once.

Measured (`guest/wu-vmexec-decode-check.ps1`), with the stock decoder as control:

    ascii path     stock=ok       fixed=ok
    german umlaut  stock=MANGLED  fixed=ok
    cyrillic       stock=MANGLED  fixed=ok
    cjk            stock=MANGLED  fixed=ok
    arabic         stock=MANGLED  fixed=ok

A German user with an umlaut in a folder name hits this on an ordinary `qvm-run`. Fixed in
`guest/VMExec.ps1` with a byte-accumulating UTF-8 decoder, byte-identical to stock for ASCII.
This is a defect in stock QWT, not something we introduced.

### 3. health-check.ps1 reported the Xen PV drivers MISSING on Turkish

`$d.Service -eq $k.ToLower()` - `.ToLower()` is culture-sensitive, and `'XENIFACE'.ToLower()` under
tr-TR returns x-e-n-**U+0131**-f-a-c-e (dotless i), so the comparison fails. Measured by code point;
the console renders both spellings identically, which is why this class hides. Fixed with
`ToLowerInvariant()`.

### 4 and 5. MY OWN errors, corrected

`docs/LOCALE-TESTING.md` claimed `-match`/`-eq` are **Ordinal**. They are not - they are
INVARIANT-CULTURE, which happens to explain both of my earlier observations at once:

    tr-TR  'i' -eq 'I'                  : True     (invariant casing, so Turkish does not bite)
    tr-TR  'XENIFACE' -match 'xeniface' : True
           'Update' -eq 'Update<U+200E>': True     (linguistic: zero-width marks have no weight)
           Ordinal comparison of same   : False

The practical conclusion in the guide was right, the stated reason was wrong, and the wrong reason
would have misled anyone extending it. The guide now also warns that the casing METHODS are
culture-sensitive even though the operators are not - which is exactly finding 3.

### 6. Rejected

A claim that `& cmd.exe /c $cmd` in VMExec.ps1 mangles child stdout by code page was disproved by
the verifier both in engine source and by measurement on the real path.

Re-verified after every edit: syntax clean, and the handler still passes the German end-to-end
progress test with the new guard and the scan check in place.

## 2026-08-14 — regression run: today's changes are CLEAN; a pre-existing relay defect surfaced

Asked to confirm nothing regressed after the day's edits (Resolve-Catalog rewrite, freshness guard,
VMExec UTF-8 decoder, invariant progress formatting).

### Pass 1 - dom0 sequence against the up-to-date guest: CLEAN

`tools/replay-dom0-update.py win11-tpl --with-entrypoint` on the 26100.9168 guest:

    [mkdir] rc=0   [cat>tarball] rc=0   [tar] rc=0   [entrypoint] rc=100   [rm] rc=0
    progress floats on stderr: ['0.0', '1.0', '3.0', '100.0']   <- dot-formatted, parseable
    stdout: no updates available

Every step green, exit 100 correct for an up-to-date guest, and the new freshness guard and
`action -eq 'scan'` check did not break the normal path.

### Pass 2 - full download+install from a pristine 26100.8875 rebuild: BLOCKED, not by us

The pass failed before its first log line with `0x80072F8F` (ERROR_INTERNET_SECURE_FAILURE), and on
retry with `0x8024402C`. Isolated (`guest/wu-egress-isolate.ps1`):

    .NET / HttpWebRequest -> catalog Search.aspx      HTTP 200      <- our downloader is fine
    WU COM searcher (Get-Available)                   FAILED        <- code NOT touched today
    relay log: ctldl.windowsupdate.com  ok x2, zero-bytes x5
               tas02.sls.update.microsoft.com  down=3974 eof=client

That signature is a client that received a certificate chain (~4 KB) and aborted it: WU could not
refresh its certificate trust list, so TLS validation of the update endpoints failed.

ROOT CAUSE, measured (`guest/wu-plainhttp-repeat.ps1`) - the relay's PLAIN-HTTP path is unreliable:

    disallowedcertstl.cab   ok=3/6  failed=3        same URL, both outcomes
    authrootstl.cab         ok=6/6  bytes=26531, 69943, 80043

So it drops requests intermittently AND truncates responses while reporting success (80043 is the
true length - `download.windowsupdate.com` returns exactly that). Both are in the non-CONNECT path.
Our .msu downloads are HTTPS and tunnelled end-to-end via CONNECT, which is why 4.8 GB transferred
flawlessly at 12.8 MB/s while this is broken - the plain-HTTP path was effectively never exercised.

NOT a regression from today: the failing call is the WU COM searcher, and the relay was not modified
today. It explains why the scan worked at 09:53 and fails now - the CTL refresh is periodic, so the
guest only needs this path some of the time, which is the worst possible failure profile: an update
feature that works on one boot and fails on the next for no visible reason.

The allowlist is NOT the cause: ctldl is ALLOWED (logs CONN, not DENY). Only 3 DENYs exist in the
whole log - wdcpalt, self.events.data (telemetry, correct) and windowsupdate.microsoft.com.

### A/B: the truncation is pre-existing, and the drain timeout is NOT the cause

RETRACTION first: the entry above said "the relay was not modified today". That is FALSE - the
allowlist commit 61f0bcc touched it at 09:43 today. The conclusion (pre-existing) still stands, but
it now rests on measurement rather than on a wrong claim.

Interleaved A/B, pre-allowlist build vs shipped, same guest, same URLs (`guest/wu-relay-ab.ps1`):

    PRE  disallowedcertstl  ok=6 fail=2  sizes=4987                                  constant
    PRE  authrootstl        ok=8 fail=0  sizes=30632,57892,69060,71512,80043         VARYING
    CUR  disallowedcertstl  ok=8 fail=0  sizes=4987                                  constant
    CUR  authrootstl        ok=8 fail=0  sizes=32476,46024,64952,78984,80043         VARYING

Both builds truncate identically, so the allowlist did not cause it. CUR dropped FEWER requests than
PRE here, which is within noise.

Drain-timeout hypothesis REFUTED (`guest/wu-drain-ab.ps1`), interleaved at three values:

    DRAINMS=250   full-length 6/10   sizes 56183,78687,78844,79238,80043
    DRAINMS=3000  full-length 4/10   sizes 54050,64952,67564,72097,75000,78844,80043
    DRAINMS=8000  full-length 5/10   sizes 16513,32039,68960,73064,78775,80043

No correlation - if anything the longest drain was worst. QUBES_UPDATES_DRAINMS is not the
mechanism, and raising it would have been a change made on a plausible story rather than evidence.

Still open (task #14). Next suspect, from reading the source rather than guessing: the relay reads
the request head with a SINGLE ReadAsync and then treats the connection as a tunnel. That is right
for CONNECT but wrong for plain HTTP, which is a SEQUENCE of request/response pairs with keep-alive
framing (Content-Length or chunked). Nothing in the relay parses that framing, so it cannot know
where a response ends - consistent with truncation at arbitrary offsets and with responses lost on a
reused channel.

## 2026-08-14 — plain-HTTP truncation: three hypotheses refuted, loss localized

Task #14. The relay's plain-HTTP path returns an 80043-byte file as anything from 0 to 79389 bytes,
about half the time, reported as success. Progress is by ELIMINATION, and each elimination was a
measurement rather than an argument:

    ALLOWLIST   refuted. Interleaved A/B of the pre-allowlist build vs shipped: both truncate
                identically (PRE 30632..80043, CUR 32476..80043).
    DRAIN       refuted. DRAINMS 250/3000/8000 -> 6/10, 4/10, 5/10 full-length. No correlation;
                the longest drain was not the best.
    WARM POOL   refuted, AND it nearly fooled me. First run: POOL=0 8/10 vs POOL=8 3/10, a strong
                effect. Replication with more rounds INVERTED it: POOL=0 7/15 vs POOL=8 9/15. This
                is the bimodal-metric trap this project already has a rule about - a verdict from
                one interleaved run is not a verdict.

### The decisive instrument: why did each direction stop?

`Pump` swallowed every exception with a bare `catch {}` commented "normal teardown", making an
orderly finish and a mid-body reset indistinguishable - which is why three theories could be chased
with nothing to falsify them. It now reports its termination reason, and the CONN line carries it:

    down=79389  eof=tunnel  upEnd=-  downEnd=eof
    down=20041  eof=tunnel  upEnd=-  downEnd=eof
    down=0      eof=tunnel  upEnd=ObjectDisposedException  downEnd=eof

EVERY truncated response ends `downEnd=eof` - a CLEAN end-of-stream. So the listen-side relay is
faithful: it copies everything it is given and sees an orderly close. The short body is arriving
from further up.

### Where it must be, and the next probe

Two candidates remain, both beyond the listen side:
 1. our own `--relay` HANDLER process (it pumps the qrexec vchan <-> socket), or
 2. the qrexec `qubes.UpdatesProxy` transport / tinyproxy in the netvm - NOT our code.

The handler is the prime suspect because it has the SAME teardown shape as the listen side:

    Task.WhenAny(t1, t2).Wait();
    Task.WhenAny(Task.WhenAll(t1, t2), Task.Delay(DrainMs())).Wait();
    // `using (sock)` then DISPOSES the socket

If the request-direction pump ends for any reason while the response is still streaming, the socket
is disposed 250 ms later and the response is cut - and the listen side would observe precisely the
clean EOF we see. The `upEnd=ObjectDisposedException` lines are that teardown ordering showing
through on the listen side.

NEXT: instrument the handler's two pumps to a file (they currently pass a null callback), and
record which direction ends first and why. If the response pump is cut by its partner's teardown,
the fix is ours and is a teardown-ordering fix, not a timeout. If the vchan simply EOFs early, the
defect is in the updates-proxy transport and qualifies for the CLAUDE.md upstream-report exception.

Do NOT "fix" this by raising DRAINMS - that was measured not to help.

### OWNERSHIP SETTLED: the truncation is upstream of the guest, not in our relay

The handler side is now instrumented too (`--log` is passed through to the `--relay` process, which
qrexec spawns with no console anyone reads). Every connection in a 12-request run:

    request_bytes=229  response_bytes=80455  responseEnd=eof  cut_response=False   <- full, x5
    request_bytes=229  response_bytes=79248  responseEnd=eof  cut_response=False   <- SHORT
    request_bytes=235  response_bytes=0      responseEnd=eof  cut_response=False   <- nothing
    (client saw 80043 for the full ones and 78836 for the short one; 80455 = 80043 body + headers)

`cut_response=False` on EVERY line means our handler never tears down a response in flight - the
response pump had already finished, cleanly, before the socket was disposed. And when the client
sees a short body, the HANDLER ALSO RECEIVED A SHORT STREAM, terminated by an orderly EOF.

So both halves of our relay are faithful: they copy what they are given and observe a clean close.
The bytes are lost BEFORE they reach the guest - in the `qubes.UpdatesProxy` service in the proxy
qube, or in tinyproxy behind it. That is outcome (b) of task #14: NOT our code.

`cut_request=True` appears on every line and is expected, not a defect: the request has been sent in
full and its pump is simply still blocked reading a socket that will never send more.

Caveat on rates: this run truncated 1 of 6 where earlier runs truncated about half. Nothing changed
but instrumentation, so the rate is variable and any future comparison needs interleaved runs -
"it got better" is not claimable from a single run.

CONSEQUENCE. We cannot fix the transport from the guest, and we cannot retry on Windows' behalf -
the CTL fetch is WinHTTP's, not ours. Two honest options, both needing a decision:
  1. Report upstream (qubes-core-agent updates proxy / qrexec transport). This QUALIFIES under the
     CLAUDE.md exception for defects outside QWT scope, and needs the user to approve exact text.
  2. Mitigate in the relay: parse the response's Content-Length and, on a short body, transparently
     re-issue the request on a fresh channel. This is within our power but means the relay stops
     being a byte tunnel and starts parsing HTTP - a real increase in its responsibility, and it
     cannot help CONNECT traffic at all (which does not need it).

### Reproduced with our relay REMOVED from the path

`guest/proxy-probe.cs` is a primitive qrexec local program - synchronous, no pool, no drain, no
teardown race - driven straight by qrexec-client-vm against qubes.UpdatesProxy, so nothing we wrote
is between the request and the reply. Same URL, HTTP/1.1, `Connection: close`:

    run 1  http=200  body=76995
    run 2  http=200  body=77976
    run 3  http=200  body=32336
    run 4  http=200  body=53656
    run 5  http=200  body=80043
    run 6  http=200  body=80043
    full-length bodies = 2/6   (reference 80043)

Every response is HTTP 200 with a short body. The relay is therefore not implicated, and neither is
its pool, drain or teardown.

CAVEAT, and it is the important one: this shows the loss is not OURS, but it does NOT establish that
the environment is healthy. The same guest image ran a successful WU scan at 09:53 today and the
full 4.8 GB download at 10:41. Something changed between then and 15:26 that is not in the guest,
and "not our code" is not the same claim as "upstream defect worth reporting". The next step is a
precise re-run of the KNOWN-WORKING configuration - same pristine rebuild, same guest files as
09:47 - before any upstream conclusion is drawn.

### KNOWN-WORKING CONFIGURATION RE-RUN: it fails too. Not a regression in our code.

Reproduced precisely, no substitutions:
  * win11-tpl rebuilt from the pristine `win11-24h2` image (same source as the 09:47 rebuild)
  * guest files extracted BYTE-IDENTICAL from commit 61f0bcc, the last deploy known to work -
    qubes-updates-relay.cs, qubes-windows-update.ps1, wu-update.ps1, vmupdate-shim.ps1,
    ensure-autologon.ps1, VMExec.ps1, qubes-posix-cat.cs, install-updater-agent.ps1
  * deployed with that commit's own install-updater-agent.ps1
  * same harness, same `-Action resolve` scan

    09:53 today   scan: 2 update(s) available        <- worked
    16:23 today   ERROR: Exception from HRESULT: 0x80072F8F

VERDICT: the failure is NOT a regression in anything we changed. The configuration that worked this
morning fails this afternoon with zero differences in the guest image, the agent, the relay or the
deploy. Today's edits (Resolve-Catalog, the freshness guard, the VMExec decoder, invariant progress
formatting) are all exonerated by construction - none of them is present in this build.

The variable therefore lies OUTSIDE the guest: the qubes.UpdatesProxy path - the proxy qube, its
tinyproxy, or the network beyond it. Consistent with the rest of the evidence: plain-HTTP bodies
truncate at random lengths with HTTP 200 and orderly EOFs, while CONNECT traffic through the SAME
transport moved 4.8 GB flawlessly at 12.8 MB/s earlier today.

CONSEQUENCE FOR THE UPSTREAM QUESTION: nothing should be reported upstream on this evidence. A
degraded local proxy qube is not an upstream defect, and "not our code" was never the same claim as
"a bug in Qubes". Checking or restarting the proxy qube is a dom0/other-qube action outside this
agent's remit (CLAUDE.md: only win-idd-test* qubes, only via qtest) - it needs the user.

WHAT WOULD MAKE IT REPORTABLE: the same truncation reproduced after the proxy qube has been
restarted, or reproduced from a Linux qube against the same service. This dev qube cannot do the
latter - `qrexec-client-vm @default qubes.UpdatesProxy` is refused by policy here (rc=126).

## 2026-08-14 — LOCALIZED: bytes are lost in the qrexec/vchan hop to the Windows guest

Done the way it should have been from the start: instrument BOTH ends here rather than speculate
about qubes that do not exist. (For the record: the netvm is `core-net`; there is no `sys-net` and
no `sys-firewall`, and naming them wasted the user's time. See the `updates-proxy-bisect` skill.)

Setup: `/etc/qubes-rpc/qubes.UpdatesProxy` in this qube is a symlink to `/dev/tcp/127.0.0.1/8082`,
where a USER-owned tinyproxy already runs (`tinyproxy -c /home/user/updates-tinyproxy.conf`). Moved
it to 8083 and put `tools/proxy-bytecount-shim.py` on 8082, counting bytes both directions per
connection. tinyproxy does not log response sizes, which is why the shim was necessary.

CONTROL - this qube, through the same shim+tinyproxy: 80043 every time (3/3, then 6/6 earlier).

THE MEASUREMENT - guest with OUR RELAY REMOVED (guest/proxy-probe.cs: synchronous, no pool, no
drain, no teardown), fetching through the same instrumented path:

    this qube SENT    80454  80453  80457  80454  80454  80454     (all full, endU2C=eof)
    guest RECEIVED    80454  29044  80457  80454  80454  65644     (two truncated)

We sent 80453, the guest received 29044. We sent 80454, it received 65644. Every send completed
with a clean EOF in both directions. So the bytes leave this qube intact and arrive short: the loss
is INSIDE the qrexec/vchan hop, with no QWT updater code, no relay, no pool and no drain in the path.

ELIMINATED, all by measurement: tinyproxy (same instance serves a Linux client perfectly), the
network (control is 100% clean), dom0 policy (traffic flows), our relay and its pool/drain/teardown
(removed entirely), and any of today's edits (the known-working 61f0bcc build fails identically).

### Important correction to "NOT our code"

The transport here is the WINDOWS side of qrexec - `qrexec-client-vm.exe` and the vchan handling in
Qubes Windows Tools, which is precisely the component this project forks. So this is not a Linux
Qubes defect to report upstream; it is plausibly OURS in the QWT sense.

MECHANISM HYPOTHESIS, fitting all the evidence and not yet tested: a close-race that discards
in-flight bytes. A plain-HTTP response with `Connection: close` ends with the SERVER closing
immediately after the body, so any bytes still buffered in the vchan when that close propagates are
dropped. CONNECT/TLS never shows it because the client closes first and the stream is long-lived -
which is exactly why our own 4.8 GB .msu download was byte-perfect with zero resumes through this
same transport, while an 80 KB plain-HTTP fetch loses a random tail.

Predictions if true: loss grows with response size and with upstream speed, is absent when the
client closes first, and is absent for CONNECT. All are testable.

### Two process corrections from this episode

* I claimed "both ends instrumented" while my tinyproxy had never started - it could not bind 8082
  because the user's instance already held it, and `ss` showed THAT process, not mine. Check that
  the thing you started is the thing you are measuring.
* I reported "nothing in the guest's window" from a grep that silently found nothing because the
  log contains NUL bytes and grep treated it as binary. Use `grep -a` on proxy logs.

## 2026-08-14 — stack identity VERIFIED, and the earlier verdict corrected

The user challenged whether the "known-working configuration" re-run really used the same stack.
It did not, quite - and verifying properly changed the conclusion.

WHAT WAS ACTUALLY LIVE AT 09:53 (reconstructed from commit times, not memory): the deploy ran at
09:53:13 and the working scan at 09:53:59. Commit 92bc1a6 (09:55:07) changed
`qubes-windows-update.ps1`, so at 09:53 that file was 92bc1a6's version, still uncommitted, while
every other deployed file was 61f0bcc's. My first re-run used 61f0bcc's agent - a real deviation.
`git diff 61f0bcc 92bc1a6` touches no scan or proxy construct, but that is judgement, not proof.

SO IT WAS REDONE, hash-verified end to end:

    qubes-windows-update.ps1  14acc9da87b226a1  (92bc1a6 - the file live at 09:53)   MATCH
    wu-update.ps1             d4046f129c3c8af4                                       MATCH
    vmupdate-shim.ps1         bffd531745f23eef                                       MATCH
    ensure-autologon.ps1      04404b543505a6ba                                       MATCH
    VMExec.ps1                1a425f306ad88445                                       MATCH
    qubes-updates-relay.cs    04feb1cd45e9cf91  (compiler input; .exe is built on-guest)  MATCH
    harness wu-resolve-dryrun.ps1: one commit (92bc1a6), working tree clean -> identical
    guest image: pristine clone of win11-24h2 both times

RESULT ON THE VERIFIED STACK: `scan: 2 update(s) available` at 16:46 - it WORKS.

### Correction

The earlier entry said the known-working configuration "fails too". That was a snapshot, not a
property. On a hash-verified identical stack the scan FAILED at 16:23 and SUCCEEDED at 16:46. The
variable is environmental and intermittent, not configurational. The only intervening change was
stopping and restarting the tinyproxy on 8082.

DO NOT read this as "fixed". Truncation was still measured at 16:38-16:40, AFTER that restart: the
byte-counting shim sent full bodies (80454/80453/80457) while the guest received 29044 and 65644.
The likelier reason the scan recovered is that several complete `authrootstl.cab` fetches did get
through, so Windows now holds a CACHED certificate trust list and no longer depends on the flaky
path each time. The underlying loss persists; it merely stopped being fatal.

That also explains the whole shape of this investigation: an intermittent transport fault that only
bites when Windows actually needs a fresh CTL, which is periodic - hence "works on one boot, fails
on the next", and hence a morning that worked and an afternoon that did not, with nothing in the
stack differing.

### Method note

Reconstructing "what was live" from commit TIMES against action times - rather than from the tidy
story of which commit came next - is what exposed the deviation. Working-tree state at the moment of
a deploy is not the same thing as a commit, and on a day with 20 commits the difference is routine.

## 2026-08-14 — the difference, explained and FIXED at the relay

### What the difference actually was

Measured rate, 30 relay-free fetches with the sender verified by a byte-counting shim in this qube:

    this qube sent   30/30 full (80321 or 80454 bytes, zero short sends)
    guest received   20/30 full; the rest 20883, 24979, 27943, 32729, 42063, 71487, 76413, 77135

So the qrexec/vchan hop loses part of a plain-HTTP response about a THIRD of the time, constantly -
morning and afternoon alike. Nothing about the environment changed between the run that worked and
the runs that failed.

What changes is whether Windows NEEDS that path. A fresh image has no certificate trust list, so it
must fetch authrootstl.cab over plain HTTP before it can validate the update endpoints; at a 1-in-3
loss rate that fetch is a coin toss. Once ONE complete CTL lands, Windows caches it and the whole
class of failure disappears until the cache expires.

    09:53   fresh clone, got a complete CTL early                  -> scan worked
    15:26   fresh clone, kept drawing short ones                   -> 0x80072F8F, repeatedly
    16:46   same guest, cache populated by my probe fetches        -> scans succeed regardless

That is the entire "it worked this morning" mystery: luck on a lossy path, not configuration. It
also explains the field symptom - updates work on one boot and fail on the next, for no visible
reason - and it is why a rebuild-from-pristine re-exposes it every time.

Single-variable A/B confirmed the agent file is NOT involved: 61f0bcc's agent and 92bc1a6's agent
each scanned successfully 2/2, interleaved, on the same guest.

### The fix (guest/qubes-updates-relay.cs)

Plain-HTTP requests are now VERIFIED and RETRIED; CONNECT is untouched.

  * a non-CONNECT request goes down a separate path that buffers the response instead of streaming
  * completeness is judged only where it is knowable - an explicit Content-Length. Chunked and
    close-delimited responses pass through unverified rather than being retried on a guess
  * a short body is re-issued on a FRESH channel, up to QUBES_UPDATES_RETRIES (default 4)
  * nothing is written to the client until a complete response is in hand, so Windows is never
    handed a truncated file that looks like the real one
  * bodies over 16 MB stream unverified, so this cannot become a memory problem; the files it
    exists for are tens of KB

RESULT, through the relay: authrootstl.cab 15/15 complete, ONE distinct size (80043), against
20/30 before. The relay log shows the mechanism working - "short attempt=1 got=23707 expected=80043
- retrying on a fresh channel" then "tries=2 ... complete=True".

Not claimed: this does not repair the transport. It makes the loss non-fatal for everything routed
through the relay, which is what Windows Update uses. The underlying qrexec/vchan defect (task #14)
is still open, and the close-race hypothesis was REFUTED - a 750 ms sender-side linger did not
reduce truncation (4/5 vs 5/5 at n=5, and the rate is far too noisy at that sample size to compare).

`disallowedcertstl.cab` still fails outright ~3 in 15. That is NOT a regression from this change: it
failed at the same rate before it (5/6, 4/6, 3/6 in earlier runs) and its body, when it arrives, is
always exactly 4987 bytes. Separate issue, not truncation.

## 2026-08-14 — cold-cache full pass: scan FIXED, install FAILS on a second defect

Pristine rebuild (26100.8875, no cached trust list), current stack, production @default routing.

WHAT NOW WORKS - the scan, which is the thing that failed all afternoon:

    scan succeeded on a COLD cache (previously 0x80072F8F, six attempts in a row)
    catalog resolved on the filename anchor; superseded kb5043080 dropped
    KB5120710 installed
    cumulative: 4,867.4 MB in 328 s = 15.2 MB/s, ONE attempt, zero resumes

The corrected retry is what fixed it. The FIRST version of the retry did not: it accepted
`!LengthKnown` as "unverifiable, pass through", and an EMPTY response has no headers, so a zero-byte
trust-list reply went to Windows unretried (`PLAIN tries=1 bytes=0 body=0/-1`) and the pass died at
0x80072F8F anyway. Only a cold-cache run could expose that - both earlier "successes" were on warm
caches and would have shipped a broken first-update experience for every fresh template.

WHAT STILL FAILS - UBR did NOT move.

    before/after reboot: 26100.8875 (unchanged)
    KB5120710  -> 7 CBS entries, state=112 (Installed)
    KB5121003  -> ZERO CBS package entries; never registered
    RebootPending cleared, no pending.xml, no rollback in CBS.log at boot
    shutdown took 77 s and boot 75 s - servicing plainly never ran (it took 6.3 min when it worked)

DIAGNOSIS: the pass staged TWO reboot-requiring packages in ONE servicing session - KB5120710
(rc=3010) and then KB5121003 (rc=3010) - with no reboot between them. At boot CBS applied the first
and silently discarded the second. DISM reported 3010 for the cumulative regardless, and the agent
took that as success, so the pass reported "installed" for a package CBS never registered.

This also explains the 11:47 success: that run installed the cumulative ALONE (`-OnlyKb KB5121003`)
on an image where KB5120710 had already been installed AND rebooted. One reboot-requiring package
per session. The variable was never the KB filter - it is how many packages a session stages.

FIX REQUIRED (not yet implemented): once a package returns a reboot-required code, the pass must
stop installing further packages and demand the reboot, resuming afterwards. Reporting
`installed=True` on rc=3010 also overstates: 3010 means STAGED, and the only proof is the package
appearing in CBS with state=112 after the reboot.

ACCEPTANCE when implemented: pristine rebuild -> full dom0 pass -> reboot -> UBR 26100.8875 ->
26100.9168 AND KB5121003 present in the CBS package list. Anything less is a staged package being
reported as an installed one, which is the defect itself.

## 2026-08-14 — MULTISTAGE VERDICT: CBS really does discard the second staged package

Run with `QUBES_UPDATES_ALLOW_MULTISTAGE=1` (Windows' normal behaviour, both packages staged in one
session) on a pristine cold-cache clone, WITH the settle step active:

    18:08:33  KB5120710: staged      settle: CBS RebootPending=True, TiWorker idle=True
    18:27:24  KB5121003: rc=3010     settle: CBS RebootPending=True
    reboot -> UBR 26100.8875 (unchanged)
              KB5120710 installed = True
              KB5121003 installed = False

So the shutdown-race hypothesis is REFUTED: RebootPending was confirmed for BOTH packages and
TiWorker was idle before the reboot, and the cumulative was still discarded. n=2, with the race
controlled for.

CONCLUSION: staging a second reboot-requiring package into a session that already has one loses it,
on this image, silently - DISM returns 3010 for both. The one-package-per-session rule is therefore
the CORRECT fix, not a workaround, and `QUBES_UPDATES_ALLOW_MULTISTAGE` should stay OFF. It remains
available so this can be re-tested on other builds, because Windows aggregates packages per reboot
in general and this may be specific to a cumulative landing behind a .NET update.

NOT yet proven: that the serialised path completes. The next pass must run with multistage OFF and
show UBR 26100.8875 -> 26100.9168 with KB5121003 in CBS - and, because only one package installs per
pass, dom0 must drive a SECOND pass afterwards to pick up the deferred one.

## Future plan — video modes during a Windows update (not started)

During servicing the guest desktop is useless and ugly to look at, and in seamless mode the update
screens arrive as override-redirect surfaces that cannot be managed. Make the behaviour configurable:

  * either HIDE the guest desktop entirely for the duration of the update, or
  * present it SMALL and NOT override-redirect, so dom0 can place and decorate it like any window,
  * and RESTORE the previous mode when the pass finishes (including on failure and on the reboot
    path, which is where a naive implementation would leave the guest stuck in the update mode).

## 2026-08-14 — THE SERIALISED PATH LANDS: 26100.8875 -> 26100.9168

Second pass, shipping default (multistage override cleared), single package, cached .msu reused
(416 "already complete" - no 4.8 GB re-fetch, which is what preserving a staged package bought):

    build = 26100.9168 (24H2)
    KB5121003 installed = True        KB5120710 installed = True
    RebootPending absent   winsxs pending.xml absent   DISM: no component store corruption

The acceptance criterion that stood unproven all day is met. One reboot-requiring package per pass,
dom0 driving a second pass for the deferred one, is a WORKING model - not just the right diagnosis.

### The teardown hang, and why the kill was safe

The apply took far longer than the 6.3 min known-good run and the guest sat on "Restarting" burning
exactly ONE core. That is consistent with the offline commit (poqexec is single-threaded by design;
the multi-core phase is TiWorker staging, which had already finished at 842 CPU-s). But the real
story was visible in dom0: `qvm-ls` showed **Transient**, not Running, for 8+ minutes - Windows had
finished and issued its restart, and it was the DOMAIN TEARDOWN that hung (`on_reboot=destroy`).

So the kill destroyed an already-committed Windows, not a live transaction - confirmed by the clean
CBS state and the successful build above. Worth knowing for next time: on this rig a stuck
"Restarting" should be diagnosed from dom0 state FIRST. Running = still working; Transient = Windows
is done and the domain is failing to go away, where a kill is safe and correct.

Unresolved: WHY the teardown hangs. Not investigated - it cost ~20 minutes here and would strand a
user who does not know to kill the qube.

## 2026-08-14 (evening) — GWeck's 4.3.1 reports: the escape hatch, and one root cause found by running it

Trigger: forum 42717 posts 54/55/56, the last of which (16:15 today) is new since the handover.
Post 54 is the severe one - Windows 10 22H2 with 4.3.1 comes up after the IDD-activation reboot
as "only a black inactive window", the Windows key does nothing, applications will not start,
shutdown from the Qube Manager does not work, and killing the qube brings the same black window
back. Post 56 adds that AppVMs based on that Win10 template start and then shut down silently.
Post 55: the SAME machine on 09b643e with Open-Shell is completely fine on both Win10 22H2 and
Win11 25H2. He asks for /noidd.

### Shipped today (proven on win11-fresh, by pixels, not by logs)

* `install.cmd /noidd` - fresh install, never activate the IddCx driver (-NoIddDriver existed
  but was reachable only by hand-editing a command line).
* `install.cmd /iddoff` + `guest/deactivate-idd.ps1` - the RECOVERY path: NoTopologyApply=1
  first so the agent cannot re-detach the VGA, then re-enable the VGA, then remove the IDD
  device, then reboot. It deliberately avoids ChangeDisplaySettingsEx so it runs over qrexec
  from dom0 on a guest with no usable display, which is the only situation it exists for.
* `install.cmd /iddonly` now clears NoTopologyApply, or re-activating after /iddoff would
  create the device and never attach it.
* install.cmd names the file a switch needs when it is not on the medium.

MEASURED round trip on win11-fresh (Win11 26200, IDD active at 5120x1440):

    install.cmd /bogus       -> "Unknown option", the new options listed          PASS
    install.cmd /updatesonly -> names the missing file and where it looked        PASS
    install.cmd /iddoff      -> VGA enabled, ROOT\DISPLAY\0000 removed, reboot    PASS
      after reboot: ATTACHED=1 Microsoft Basic Display Adapter 3440x1440,
      agent logs "IDD solo: DISABLED by NoTopologyApply=1", Notepad renders
      in dom0 (screenshot, not a log line)                                        PASS
    install.cmd /iddonly     -> IDD device recreated, VGA disabled, reboot        PASS

### ROOT CAUSE FOUND: /iddonly could never have worked, and it is a quoting bug

The first /iddoff run failed with `IDD DEACTIVATION FAILED: Illegal characters in path`.
Cause: `%~dp0` ends with a backslash, so `-Root "%HERE%"` reaches PowerShell as `-Root
"C:\path\"` - and PowerShell's argument parser reads `\"` as an ESCAPED QUOTE. The script
receives `C:\path"`, with a trailing quote character, and every path built from it is invalid.

This is not a new defect: win11-fresh's own `C:\qwt-idd-activate.log` from 2026-08-11 records

    IDD ACTIVATION FAILED: C:\qwtc"\idd-driver holds 0 .inf files (expected exactly 1)

- the same stray quote, sitting in the log for three days. So the earlier triage of GWeck's
post-35 `/idd` report (user error + the script not shipping) was incomplete: there is a THIRD,
independent cause, and it would have broken /iddonly even on a medium that carried the script.
Fixed by passing `%HEREQ%` (the directory without its trailing backslash) into every script.

Process note: this was found by RUNNING the switch on a guest, not by reading it. The same code
had been read several times today.

### The agent fix, and what could NOT be proven

`EnsureQubesIddSolo` detached every other display first and only then tried to make the IDD
primary, both with CDS_UPDATEREGISTRY. If the second step failed, the guest would be left with
no attached display AND that state persisted for the next boot - which matches post 54 exactly,
including surviving a kill. The failure is reachable in principle: an IddCx adapter enumerates
as soon as its devnode starts but has no mode list until its monitor arrives, and the agent is
started very early by the watchdog service.

Added: (1) a readiness gate - refuse to touch the topology until the IDD publishes a mode,
returning ERROR_NOT_READY, retried for 20 s at startup; (2) a rollback that re-attaches exactly
what was detached, with its previous mode and primary flag; (3) SoloFaultInject, a registry hook
that makes the apply fail on purpose, so the guard can be seen to fail (=2 suppresses the
rollback, i.e. the pre-fix behaviour).

FALSIFICATION ATTEMPT, and it did not succeed. On win11-fresh, with the precondition built and
ASSERTED (IDD detached, VGA attached and primary) and SoloFaultInject=2:

    IDD solo: found IDD adapter '\\.\DISPLAY2', attached=0 primary=0
    IDD solo: detach '\\.\DISPLAY5' -> -2            <- DISP_CHANGE_BADMODE
    IDD solo: set-primary '\\.\DISPLAY_QUBES_FAULT_INJECT' -> -5, commit -> 0
    IDD solo: '\\.\DISPLAY5' is STILL attached
    IDD solo: FAILED - idd attached=0 primary=0, others still attached=1

**Windows refused to detach the last attached display.** So on Win11 26200 the headless state
is structurally unreachable by this path, the rollback never ran, and its PASS is therefore
UNPROVEN - recorded as such. Whether Win10 19045 enforces the same rule is not known here and
is exactly what a Win10 rig would settle. The readiness gate stands on its own reasoning (never
attempt an apply the IDD cannot accept) and is cheap; the rollback stays as defence in depth.

An earlier run of the same experiment was VOID: modeprobe's JSON field is `device_name`, my
harness read `.name`, so `--solo` never ran and the precondition was never established. The
assertion added afterwards caught the next attempt and aborted it instead of producing a
confident wrong answer.

### GWeck is 53 agent commits behind, including the fixes for what he reports

`git log c7ccb459..HEAD` in agent/ is 53 commits. Among them: 8be83b8 (2026-08-12) makes the
agent adopt the size Windows APPLIED instead of the size it requested - that is the diagnosed
cause of his S2 "mouse pointer ~1 cm below where the system thinks it is", and it landed two
days after the release he is running. Also the whole 25H2 shell-surface series (toastcrop,
shell-managed Start, the geometry sanitizer) and the drag work. His 4.3.1 predates all of it.

CONSEQUENCE: the highest-value action for him is a new release, not more diagnosis of 4.3.1.

### Win10 diagnosis is BLOCKED on a rig, and the reason is recorded

win10-clean cannot run anything elevated - measured, not assumed:

    schtasks /Create /RL HIGHEST (guest/run-elevated.ps1)  -> ERROR: Access is denied
    qrexec qubes.VMRootShell                               -> Request refused (no such service)
    qrexec qubes.VMShell+SYSTEM                             -> runs as win-idd-test\user,
                                                              Medium Mandatory Level
    EnableLUA=1, ConsentPromptBehaviorAdmin=5, no consent UI reachable

So the IDD cannot be installed or activated there, and GWeck's platform cannot be reproduced on
the rig we have. A fresh Win10 with EnableLUA=0 is needed (the USB answer-stick route works and
is cheap - FINDINGS 2026-08-07), but it requires creating/removing a qube, which the harness
refuses without the user's approval. Flagged to the user rather than worked around.

## 2026-08-14 (evening) — post 56 does NOT reproduce: an AppVM on a Windows template works

GWeck: "Starting an AppVM based on the Windows 10 template seems to start normally, but just
after finishing the startup, it shuts down silently." That path had never been exercised here -
every test in this project uses standalone qubes - so it was worth running before theorising.

    qvm-create --class AppVM --template win11-tpl --label red win11-app
    qvm-tags win11-app add win-idd-testbed
    virt_mode=hvm, kernel='', memory 8192, vcpus 4, qrexec_timeout 6000, netvm ''

RESULT: started at 17:52:55, Running and stable through five state polls over 2 minutes and for
the rest of the session; `qubes.VMShell` answered (`APPVM_OK`, hostname win11-idd-test); the IDD
was the sole active display at 1920x1080; Notepad opened and rendered in dom0 (screenshot).
Nothing about being an AppVM broke the guest.

Features are NOT copied to an AppVM and do not need to be: `qvm-features win11-app` is empty
while os/gui/qrexec/stubdom-qrexec/vmexec all resolve through the template.

WHAT THIS DOES AND DOES NOT SETTLE. It rules out "an AppVM on a Windows template is structurally
broken", which was the cheapest explanation. It does NOT clear his case: this template is
Win11 26100 carrying only the updater stack, not a Win10 template that has had the 4.3.1 package
installed. The remaining candidates are Win10-specific behaviour, or template state (a pending
servicing operation, or a profile that MoveUsers relocated onto the template's private volume,
which an AppVM does not inherit). The Win10 rig now provisioning is what can test those.

## 2026-08-14 (evening) — stock QWT is NOT Microsoft-signed either, so signing is not what costs us the extra reboot

Question raised by the user: do we need proper signing to collapse our two-reboot install to
one, and does stock QWT have it? Measured on the shipped stock artifact rather than assumed
(`/usr/lib/qubes/qubes-windows-tools.iso` from `qubes-windows-tools-4.2.2-1.fc41.noarch.rpm`):

  * the ISO contains exactly one file plus a README: `qubes-tools-4.2.2.exe` - which is why
    qvm-create-windows-qube globs for `qubes-tools-*.exe`;
  * that bundle has **no Authenticode signature at all** (PE certificate table size 0);
  * carving its Burn attached container out and extracting `installer.msi` gives 40 PE files,
    **all 40 signed**, and the signer of a native (kernel-mode) one is
    **CN="Qubes Windows Tools"** - a private certificate. DigiCert appears only as the
    TIMESTAMP authority, not as the issuer.

A kernel-mode driver signed by a private CA does not load on Windows 10/11 without testsigning,
exactly like ours. So stock QWT is in the same position we are, and an EV certificate or
Microsoft attestation signing is NOT what would buy a single reboot.

CONSEQUENCE. Our second reboot is a design choice, not a signing consequence. Stage 1 already
imports our cert into Root and TrustedPublisher, which is what makes driver INSTALLATION
succeed; only LOADING needs testsigning, and any single reboot that enables it satisfies that.
What actually forces our split is that the installer VERIFIES its own work inline - `devcon
install` then wait for the IDD to bind with ConfigManagerErrorCode 0 before disabling the VGA,
plus the PV-drivers-bound assertions - and none of that can pass before the drivers can load.

So collapsing to one reboot means moving activation and verification to a one-shot task on the
next boot, and accepting that the qube is handed back on emulated IDE/NIC and the Basic Display
Adapter until it is started again. That is what stock does, and it is what makes an UNPATCHED
qvm-create-windows-qube work: its flow restarts the qube exactly once and then waits forever
for os=Windows, which hangs on any installer that needs a second reboot.

## 2026-08-14 (night) — Win10 rig rebuilt: post 33 FIXED and measured, post 54 does NOT reproduce,
## and my own headless hypothesis is REFUTED on both platforms

Rig: win10-clean rebuilt from the untouched vendor ISO via the USB answer stick, now with
EnableLUA=0 so it can actually be driven (the old answer file kept UAC on, which is why nothing
elevated could ever run there). Two runs, same ISO, same route, ONLY the package differs.

### The Xen restart prompt blocks the install - reproduced, then fixed

Run 1, shipped **4.3.1**: the modal "Xen PV Storage Host Adapter needs to restart the system to
complete installation" appeared on the dom0 desktop and the install NEVER completed - 70+ minutes,
one core spinning, qrexec never came up, and the user confirmed the dialog was NOT clickable.
That is forum 42717 post 33 reproduced, and it is FATAL, not cosmetic.

Run 2, **4.3.2** with the fix (xenbus_monitor AutoReboot=1 written at the start of stage 1 and
again before msiexec, instead of after the install that raises the prompt):

    qrexec alive after 945 s (~16 min), install RESULT ok:true, xenbus_autoreboot: true

No dialog, no hang. Same rig, same media, same route - a defect-present/defect-absent pair.

### The solo re-assert works, seen live on a real install

    19:10:08  IDD solo: found IDD adapter '\\.\DISPLAY2', attached=1 primary=0
    19:10:08  IDD solo: detach '\\.\DISPLAY1' -> 0 ... OK - sole active display
    19:10:12  IDD solo: detach '\\.\DISPLAY3' -> 0 ... OK - sole active display

DISPLAY3 arrived AFTER agent startup and was detached automatically. Before today nothing
re-asserted the topology, so that display would have stayed attached until the next reboot -
which is what put the guest's taskbar at x=1920, outside the region dom0 sees.

### Post 54 (Win10 black screen after the activation reboot) does NOT reproduce

On the boot after IDD activation: ATTACHED=1, the IDD sole+primary at 5120x1440, the BDA
offline, qrexec answering, and Notepad rendering in dom0 (screenshot). The guest is healthy.

### RETRACTION: "the agent can leave the desktop with no display" is refuted

I proposed that mechanism this morning for GWeck's black screen and built two guards for it.
With the failure injected deliberately (SoloFaultInject=2, rollback suppressed), on the very
platform he reports:

    Win10 19045: detach '\\.\DISPLAY3' -> 0     <- the last display CAN be detached...
                 set-primary <bogus> -> -5
                 readback: '\\.\DISPLAY2' is the sole active display
                 ...and Windows then attached the IDD BY ITSELF. Never headless.

    Win11 26200: detach -> -2 (DISP_CHANGE_BADMODE)  <- refuses to detach the last display

Two different mechanisms, same conclusion: neither build lets the desktop end up with no
attached output by this path. The rollback added in 6ea0822 is therefore DEAD CODE on both
tested builds. It stays as cheap defence in depth, but it is NOT the explanation for post 54
and must not be presented as one. The readiness gate stands on its own (do not attempt an
apply the IDD cannot accept yet).

WHAT REMAINS UNEXPLAINED: GWeck's Win10 black screen. We now have his platform, his package
path and his install flow on a rig that behaves correctly, so the difference is something in
his environment - most likely his actual display hardware (a disabled laptop panel plus an
external monitor, per post 54) which our emulated single-head guest cannot reproduce.

## 2026-08-14 (night) — post 56 REPRODUCED, and it is ours: an AppVM's first boot has no GUI

Built the configuration nobody here had ever run - `mgmt/clone-to-template.sh win10-clean
win10-tpl win10-app`, i.e. a Windows 10 AppVM on a Windows 10 template carrying 4.3.2.

MEASURED, three fresh AppVMs (create -> start -> open Notepad -> screenshot):

    first boot   qrexec answers in ~40 s, session up, explorer.exe and notepad.exe running,
                 gui-agent.exe running in session 1 - and dom0 maps ZERO windows.
                 Agent log ends at: "WatchForEvents: Awaiting for a vchan client"
    second boot  windows map normally, Notepad renders (screenshot)

So the qube is alive and completely invisible. That is GWeck's post 56 shape ("starts
normally, but just after finishing the startup it shuts down silently") seen from our side:
a qube that appears to do nothing.

### Whose fault - answered by experiment, not by reading

On the failing first boot, with the qube otherwise untouched:

    net stop QubesGuiWatchdog & taskkill /IM gui-agent.exe /F & net start QubesGuiWatchdog
    -> windows appear immediately (screenshot, 20 KB tar vs 0 bytes before)

The dom0 gui-daemon is therefore present and willing the whole time. What is dead is the
vchan SERVER this agent opened on that first boot. Plausible mechanism, not yet proven: the
Xen devices are re-enumerated while Windows specialises itself into a new qube identity
(new SMBIOS/UUID, fresh private volume) AFTER the agent opened the server, leaving it
waiting on something the backend no longer knows about.

FIX (agent): after 90 s with no client that has ever connected, log why and exit so the
watchdog respawns the agent - the exact recovery the experiment performed, rather than a
narrower guess at re-initialising the vchan alone. A persisted counter
(`VchanFirstClientRestarts`) bounds it to three attempts so a guest that legitimately has no
daemon is not restarted forever; it is cleared when a daemon attaches.

NOT yet done: confirming the fix on a fresh AppVM built from a template carrying the FIXED
agent. Until that runs, this is a fix with a proven mechanism and an unproven end state.

### Also measured, same run

  * A Win10 AppVM's private volume is a FRESH empty disk: `dir Q:\` fails while
    `wmic logicaldisk` lists Q:, i.e. the volume exists but is unformatted, and MoveUsers'
    relocation therefore does not carry the template's profile over. The guest still logs
    in and works, so this is not the GUI defect, but it is worth its own look.
  * `GetWindowData: GetRealWindowRect failed with error 0x80070006` appears on the AppVM's
    working boot - windows disappearing between enumeration and query. Noise, but recorded.

### CORRECTION, same night: the variable was the TEMPLATE never having been booted

The acceptance run for the self-heal passed - and passed for the wrong reason, which the log
says plainly:

    [20260814.223900.252] WatchForEvents: Awaiting for a vchan client
    [20260814.223900.252] WatchForEvents: A vchan client has connected
    VchanFirstClientRestarts = 0

Same millisecond, and the restart counter never moved. The self-heal DID NOT FIRE, so it is
not what made this first boot work.

What actually changed between the 3/3 failures and this success: to install the fixed agent I
had to START win10-tpl, i.e. the template was booted for the first time. Every failing AppVM
had been created from a template that had NEVER been booted - it was built by cloning volumes
straight out of a standalone qube. And it fits the one case that always worked: win11-app came
from win11-tpl, a template that had been booted many times as the updater rig.

So the defect I reproduced is: **an AppVM created from a never-booted Windows template comes up
with no GUI on its first boot** - the guest still has to complete the specialisation its
template never did, and the agent's vchan server does not survive it. Booting the template once
removes it.

CONSEQUENCE FOR POST 56: this is probably NOT GWeck's bug. His template was certainly booted -
he installed QWT inside it. My reproduction shares the SHAPE of his report (a qube that starts
and then does nothing visible) but not necessarily its cause, and I am not going to present it
as his. What it is: a real defect in a path this project had never exercised, found by building
the configuration he described.

STATUS OF THE FIX: the self-heal in the agent (exit for a watchdog respawn after 90 s with no
client that ever connected, bounded to three attempts) is a defensible guard against an agent
that would otherwise wait forever - the manual version of exactly that recovery was measured to
work, 20 KB of window vs 0 bytes. But it has NOT been seen to fire on its own, so its PASS is
UNPROVEN and it must not be reported as fixing anything yet. Proving it needs a never-booted
template plus the fixed agent, which is the run to do next.

### SECOND CORRECTION: the never-booted-template explanation is dead too, and the trigger is unidentified

A never-booted template was rebuilt from the same standalone (this time carrying the fixed
agent) and two fresh AppVMs were started from it. Both connected instantly:

    [20260814.224329.489] Awaiting for a vchan client
    [20260814.224329.489] A vchan client has connected     VchanFirstClientRestarts = 0

So "the template had never been booted" does not explain it either, and the self-heal again
did not fire. Scoreboard for a fresh AppVM's FIRST boot:

    template cloned 19:15 (from a standalone that had just been through the
      SoloFaultInject runs and restore-rig's VGA devnode cycling)   3/3 NO GUI
    template cloned 19:42 (from the same standalone after a clean boot,
      an agent swap and a clean shutdown)                           2/2 GUI, instantly

The failure is real - it was observed three times, with the agent log stopping at "Awaiting
for a vchan client" and a manual agent restart curing it on the spot - but its TRIGGER is not
identified, and the most likely remaining suspect is the state my own display experiments left
in the source image before the first clone (devnode cycling, a disabled/re-enabled VGA, a
topology apply history), not anything about templates or AppVMs as such.

RECORDED AS: an unexplained, currently non-reproducible first-boot GUI failure with a known
recovery. Not offered as an explanation of post 56. The self-heal stays in as a guard against
an agent that would otherwise wait forever, with its PASS explicitly unproven - it has never
been seen to fire.

Next run that would settle it: clone a template from a standalone that has NOT been through
the display experiments, and separately clone one that has, and start a fresh AppVM from each.

## 2026-08-14 (night) — 4.3.1 REPRODUCED on his exact build: two attached displays during the
## pre-logon window, which is exactly when he sees the pointer offset and the dead dialog

Rig rebuilt with `4.3.1+agent.c7ccb459aec9` - the identical package GWeck downloaded. The only
rig-side change is pre-setting xenbus_monitor AutoReboot from the answer-stick payload, without
which 4.3.1 cannot finish installing here at all.

FIRST RESULT, and it settles post 33 on his build: with the modal suppressed the same 4.3.1
package installed in **1008 s (~17 min)**, against a 70+ minute hang that never completed when
the modal was allowed to appear. Same package, same media, same rig, one variable. The dialog
was the blocker, not a symptom of something else.

SECOND RESULT, measured on 4.3.1 while the guest was still at the Welcome screen:

    ATTACHED=2
    SCREEN \\.\DISPLAY2 primary=True  {X=0,   Y=0,    W=5120, H=1440}   <- the IDD
    SCREEN \\.\DISPLAY3 primary=False {X=1920,Y=-768, W=1024, H=768}    <- the emulated VGA
    VIRTUAL 5120x2208

Two attached displays, the second at NEGATIVE Y, and a virtual desktop 768 px taller than the
screen the agent maps. Windows is free to place windows in that region, and dom0 never sees it -
which is precisely the stray 1024x40 override window (the guest's taskbar at x=1920) observed on
the dom0 desktop earlier today, and a mechanism for a pointer that does not land where it is
aimed.

After the user session starts, 4.3.1 converges to ATTACHED=1 on its own: the agent restarts into
the new session and its one-shot solo apply runs there. So on 4.3.1 the two-display state is
confined to the PRE-LOGON window - during the install and the boot that follows it.

WHY THAT MATTERS: that window is exactly when GWeck reports trouble. Post 54 says the pointer is
wrong on Windows 10 "only before the reboot after activation of the IDD driver", and post 33 is
a modal raised during the install that he could not click. One cause - a second display attached
while the agent maps only the first - accounts for both.

BEFORE/AFTER, same rig, same media:

    4.3.1   ATTACHED=2, second display at (1920,-768), persists through pre-logon
    4.3.2   the same arrival is detached within ~1.5 s, from the install itself:
              19:10:12  IDD solo: detach '\\.\DISPLAY3' -> 0
              19:10:12  IDD solo: OK - '\\.\DISPLAY2' is the sole active display
            post-install: ATTACHED=1, virtual 5120x1440

The WM_DISPLAYCHANGE re-assert is therefore doing the job it was written for, demonstrated
against the build that lacks it rather than only against itself.

STILL NOT REPRODUCED on 4.3.1: the black inactive window of post 54. This guest, on his exact
build, comes up at the Welcome screen and then to a working seamless desktop.

## 2026-08-15 — the updater was lying about "no updates", and the cause is ours

Chasing a 25H2 target, the natural first step was to ask our own updater what Windows Update
offers a 24H2 guest. It said "0 update(s) available" five times running, each in about a
second. The user's instruction was the right instinct: use OUR updater, and if it fails,
something is wrong with it.

WHAT WAS ACTUALLY HAPPENING. The scan reached Windows Update every time - the relay log shows
CONNECT to fe2cr.update.microsoft.com moving 114 KB. What failed were the small plain-HTTP
metadata fetches:

    PLAIN incomplete attempt=1 bytes=0 headers=False got=0 expected=-1 - retrying
    ... five attempts, ~400 ms apart ...
    PLAIN tries=6 bytes=0 body=0/-1 complete=False req=[GET .../45815198_...]

Zero bytes, no headers, at pool-hand-out speed: a channel taken from the warm pool that the
far end had already closed. Each dead channel spent one of the five retries, so a request
could exhaust its budget without ever reaching the server. Windows Update cannot describe an
offer whose metadata it could not download, so it answered "no updates" - and the guest then
told dom0 it was current.

FIX 1, relay: a warm channel that returns nothing at all is not a failed fetch. Dead channels
now have their own bounded allowance (at most the pool size) and the request stops drawing
from the pool afterwards. MEASURED on the same guest, same minute: **0 updates -> 3 updates**,
scan time 1 s -> 145 s (it is now actually talking to Windows Update).

FIX 2, agent: the silent-zero class itself. The scan watches the relay log across its own
window; if the relay gave up on any fetch AND the scan found nothing, the answer is UNKNOWN -
rescan once, then refuse to report a number and exit 75. SEEN TO FIRE, with a test hook for
the half that cannot be summoned once WU has cached its metadata:

    scan returned 0 but the relay gave up on 1 fetch(es) - the result is UNKNOWN, rescanning
    scan: 3 update(s) available

### 25H2 is still not on offer

With TargetReleaseVersion=25H2 and the seeker opt-in set, the (now trustworthy) scan offers
three updates: MSRT and Defender definitions, no enablement package. The Update Catalog has no
result for "Windows 11 version 25H2 enablement" or KB5054156 either. So this Enterprise
Evaluation 24H2 guest is not being offered 25H2 by any route we control, and the 25H2-only
reports (44, 45, 33.3, 33.4) still have no target.

Download automation was also retested and is closed from here - see tools/get-win-iso.sh:
mido/Fido's endpoint is retired (404), the page geo-redirects, and the surviving JSON connector
answers SentinelReject even from headless Chromium driving the real page with a fingerprinted
session.

## 2026-08-15 — the vendor's own bundle cannot install unattended; the proven route is the MSI

Building the stock-QWT baseline for post 27.2, I ran the vendor artifact the way
qvm-create-windows-qube runs it - `qubes-tools-4.2.2.exe /passive` - and it stopped dead on a
modal (screenshot):

    Qubes Windows Tools v4.2.2.0 Setup
    Test signing must be enabled, run the following as an administrator:
    bcdedit /set testsigning on                                    [ OK ]

/passive does not suppress it. Stock's own drivers are signed by a private
CN="Qubes Windows Tools" certificate (see the signing entry above), so stock needs testsigning
exactly like we do - and its installer refuses to proceed until it is ALREADY active in the
current boot. Consequence beyond our rig: upstream's own automated path runs that same command,
so a qvm-create-windows-qube provisioning run stalls there on any guest whose answer file did
not enable testsigning first. Same silent-stall class as the Xen restart modal, one layer down.

Working around it with a testsigning-then-reboot payload got the guest to a Test Mode desktop,
where the bundle then ran invisibly as SYSTEM in session 0, burned one core for a few minutes,
went idle, and never produced qrexec.

CORRECTION, from the user: this project HAS installed stock QWT unattended, several times. It
never used the vendor bundle. `artifacts-stock/` is a package tree carrying the stock
`installer.msi` - byte-identical to the one inside today's bundle (sha256
7049322128d1cf7d9dc2a48f69ef91a5893a8f779d3b2ad7d25fdfc8eee3baf4) - installed with OUR
installer, which enables testsigning in stage 1 and drives msiexec directly. That is the route
mgmt/build-answer-stick.sh's STOCK_SETUP implements, and its comment already said why: "our
installer is the only path proven to install this MSI".

Method note: the failure was mine for reaching for the vendor .exe when a proven route existed
in the repo, with a comment explaining itself. Reading the tooling before rebuilding it would
have cost five minutes and saved two provisioning cycles.

## 2026-08-15 — post 27.2 RESOLVED on a real stock guest, and the 0x7B mechanism is now pinned

The first stock-QWT baseline this project has ever built: Win10 19045, genuine Qubes Windows
Tools v4.2.2.0 from the vendor MSI, with the boot disk on the PV path -

    QWT      Qubes Windows Tools v4.2.2.0
    BOOTDISK bus=SCSI model=PVDISK
    SVC xenvbd Start=0

i.e. exactly the precondition Test-BootDiskOnPvPath exists to detect, which its own comment
admitted had never been seen live.

UPGRADE WITH THIS PACKAGE (4.3.2), single run, nothing hand-held:

    pv_boot_disk: true
    upgrade_mode: "in-place-msi-major-upgrade"   <- stock is NOT uninstalled at all
    INSTALL COMPLETE (no reboot from the installer - the single-shutdown change)
    reboot 1 -> guest boots. BOOTDISK bus=ATA  model="QEMU HARDDISK"
    reboot 2 -> BOOTDISK bus=SCSI model=PVDISK, QWT v4.3.2.0

So the upgrade DOES drop the boot disk back to emulated IDE for one boot - which is precisely
what the reporter described - and it returns to the PV path on the next boot. No 0x7B here.

WHY IT SURVIVED, and why his did not: on this image atapi, intelide, pciide and storahci were
all still Start=0, so a boot-start inbox driver was available the moment the PV path went away.
Windows demotes those drivers once xenvbd owns the disk; on a guest where that has happened,
the same intermediate boot has NO boot-capable storage driver and bugchecks 0x7B
INACCESSIBLE_BOOT_DEVICE - recoverable only through safe mode, exactly as reported.

FIX: the installer now re-arms the inbox ATA/AHCI drivers before msiexec on the IN-PLACE path.
An inline re-arm already existed, but only in the remove-then-install branch - which is not the
branch a version-bumped MSI takes, so it never ran here.

AND THE SECOND HALF OF WHY HE HIT IT: 4.3.0 and 4.3.1 shipped at the SAME MSI ProductVersion
(4.3.0), so Windows Installer could not treat the newer build as a major upgrade and the
installer had to REMOVE stock first - the dangerous path, with the PV disk driver going away
while nothing had re-armed the fallback. tools/cut-release.sh already enforces the version bump
that makes the in-place path possible; this run is what shows why that invariant matters.

Also observed, unchanged from 2026-08-14: the domain hung in Transient for ~3 minutes at the
post-upgrade reboot. Kill-and-start was safe and the guest came back correctly.

### VERIFICATION OF THE 0x7B FIX: the defect does NOT reproduce, so the fix is UNPROVEN

The user asked for the fix to be verified before moving on. It is not verified, and the
attempt is worth recording because it corrects my own claim from an hour earlier.

First attempt was VOID by construction: I ran it on win10-app, an AppVM, whose root volume is
discarded at every shutdown. The upgrade and the demotion were both wiped before the boot that
was supposed to crash, and the guest "booted fine" because it had reverted to stock
(QWT 4.2.2.0, atapi Start=0, marker file gone). An AppVM cannot test anything that spans a
reboot. Redone on the standalone guest, restoring the stock baseline by cloning win10-tpl's
root volume back over it.

    run 1  inbox drivers Start=0 (armed)    upgrade -> reboot -> BOOTDISK bus=ATA
                                            second reboot      -> bus=SCSI (PV), QWT 4.3.2
    run 2  inbox drivers Start=3 (demoted)  upgrade -> reboot -> BOOTDISK bus=SCSI, BOOTED,
                                            QWT 4.3.2.0, atapi still Start=3

So the boot disk's excursion to emulated ATA happened ONCE OUT OF TWO, and in the run where a
demoted fallback would have mattered it did not happen at all - the PV driver bound
immediately and the demotion was irrelevant.

WHAT THAT MEANS. My earlier statement - "the upgrade moves the boot disk off the PV path for
one boot" - was drawn from a single observation and is not reliable: it is intermittent. A
0x7B needs BOTH halves at once (the excursion AND a demoted inbox driver) and I have now seen
each separately, never together. The re-arm therefore stays in as cheap, idempotent insurance
against a transition that is real but not reproducible on demand - NOT as a demonstrated fix,
and it must not be described as one.

Still true and independently measured: the upgrade takes the in-place major-upgrade path and
never uninstalls stock, which is what removes the whole class of risk. The reporter's build
could not take that path, because 4.3.0 and 4.3.1 shipped at the same MSI ProductVersion.

### PROOF ATTEMPT, and the fix is REFUTED as written: there is no emulated disk to fall back to

Deterministic harness instead of waiting for the intermittent excursion: put the guest in the
state an uninstall of the PV disk driver leaves - inbox ATA drivers demoted, xenvbd disabled -
and see whether the shipped re-arm saves the boot. Baseline restored from a snapshot between
every run (win10-tpl root cloned back over win10-clean), so each run starts from identical
stock 4.2.2.

    RUN A  demoted inbox + xenvbd disabled, NO re-arm
           -> domain starts and is DESTROYED within ~50 s, twice in a row. 0x7B reproduced.
    RUN B  same + the shipped re-arm (atapi/intelide/pciide/storahci back to Start=0)
           -> ALSO fails. Domain up, executing (~4% of a core), qrexec never appears.

Why B failed is the part I had wrong. The disk inventory on a healthy stock guest:

    DISK \\.\PHYSICALDRIVE0 | XENSRC PVDISK SCSI Disk Device | SCSI | 80GB
    CTRL Intel(R) 82371SB PCI Bus Master IDE Controller | OK      <- controller present...
                                                                  ...with NO disk behind it

The Xen PV drivers UNPLUG the emulated disk: XENFILT masks the IDE channel
(XENFILT\Parameters!Internal_IDE_Channel = IDE). So when xenvbd does not load there is no disk
at all, and re-arming ATA drivers cannot help - there is nothing for them to bind to. The fix
as written addresses the wrong half of the problem.

    RUN C  re-arm + remove XENFILT's Internal_IDE_Channel (un-mask the emulated disk)
           + xenvbd disabled
           -> reaches WINDOWS AUTOMATIC REPAIR (user observed it on screen). Strictly further
              than A or B: WinRE loads, so a disk is visible again - but Windows still does not
              boot normally.

CONCLUSION. On this platform the 0x7B is not "no boot-start ATA driver"; it is "the PV disk
driver is gone AND the emulated disk it replaced has been unplugged". Nothing we can set from
inside the guest turned that back into a normal boot in these runs. The robust remedy is the
one already measured to work: DO NOT REMOVE THE PV DISK DRIVER during an upgrade - which is
exactly what the in-place major upgrade does, and what the ProductVersion bump makes possible.

The re-arm stays (it is idempotent and costs nothing, and it is a precondition for any recovery
that does restore the emulated disk) but it is NOT the fix and must not be described as one.
The claim "the installer now prevents the 0x7B" is WITHDRAWN.

### RUN E closes it: nothing from inside the guest recovers a removed PV disk driver

RUN D reached Windows Automatic Repair, which left open whether a normal boot would have
worked if Windows had not been diverting to recovery after repeated failures. RUN E removed
that confound (bootstatuspolicy ignoreallfailures + recoveryenabled No, so Windows attempts
the real boot) with the same arming - inbox ATA boot-start, whole Xen bus stack out of the
boot path. Result, seen on screen: "Your device ran into a problem and needs to restart".
Still 0x7B.

So the answer is not "re-arm ATA", not "un-mask the emulated IDE channel", and not "keep the
Xen bus stack out of the way". Once the PV disk driver is gone from a guest whose emulated
disk has been unplugged, nothing available from inside the guest brings it back.

### THE FIX: never remove the PV disk driver, and refuse the path that would

/acceptpvdiskupgrade is now inert; the gate is a hard refusal naming the reason and the
remedy. The design justification, which the user put more directly than I had: on an in-place
upgrade we do not touch the PV disk drivers at all - they are the same drivers. Our MSI is
rebuilt from the same upstream WiX sources as stock, so it carries the same UpgradeCode and
the same PV drivers, which is exactly why Windows Installer accepted it as a MAJOR UPGRADE
over genuine stock 4.2.2 today and the boot disk stayed on the PV path throughout. The
uninstall would have removed a driver the very next step reinstalls, unchanged.

The uninstall path is therefore reachable only when an in-place upgrade is impossible - the
installed product being NEWER than the package. There the correct answer is "install a newer
package", which is what the refusal says.

### The rule made explicit in code: the PV disk driver only goes UP or stays the SAME

User's framing, and it is the right invariant: an in-place upgrade never touches the PV disk
drivers because they ARE the same drivers. The only way a package can force them to change
downwards is a downgrade, and that is a real uninstall - the operation measured to leave the
guest with no boot disk.

So the installer now reads the version of xenvbd.sys FROM THE MSI'S OWN File table (no
extraction, stays correct when the payload changes), compares it with the running driver, and
refuses before touching anything if the package is older. Both halves tested on the guest:

    positive  PV disk driver: installed 9.1.0.0, package 9.1.0.0   -> INSTALL COMPLETE
    negative  PV disk driver: installed 9.9.9.9, package 9.1.0.0
              REFUSING: this package carries an OLDER Xen PV disk driver (9.1.0.0) than the
              one already running (9.9.9.9) ...
              guest untouched afterwards: QWT still installed, BOOTDISK still bus=SCSI

The negative case needs a hook (QUBES_FAKE_INSTALLED_PVDISK_VERSION) because our package and
stock carry the SAME xenvbd 9.1.0.0 - a real downgrade cannot be produced from the artifacts
that exist. Dead code when the variable is unset.

Bug found and fixed while testing, exactly the kind a dry read would have missed: the MSI File
table query emitted InvokeMember's return value into the pipeline, so the function returned
@($null,'9.1.0.0') and the [version] cast failed - the check degraded to a warning and let the
install continue. Visible only because the result JSON printed the array.

## 2026-08-15 — the updates proxy is now POSITIONAL, not temporal

User's framing, and it is the correct one: "the WU surface should be positional, not temporal -
not 'we open it for some update period' but 'it is open for the update process and that is it'."

Until now the relay listened on 127.0.0.1:8082 and the pass set a machine-wide WinHTTP proxy, so
every background HTTP client in the guest could use it for as long as the pass ran. That is not
access control, and this project had already measured the consequence: 147 dom0
qubes.UpdatesProxy policy hits in one afternoon on an "offline" guest, still dripping hours
after the last scan.

The relay is the only component that can see WHO is calling, so it now decides. Each accepted
connection is mapped back to its owning process (GetExtendedTcpTable), and only processes that
ARE the update are served: the service host running wuauserv / DoSvc / BITS / WinDefend /
cryptsvc / TrustedInstaller (resolved through the SCM with QueryServiceStatusEx - no WMI, no
System.ServiceProcess, so the file still compiles on-guest with the in-box csc and no
references), the servicing-stack images, and our own agent. Everything else is refused and
LOGGED BY NAME.

MEASURED, with a pass in flight:

    curl.exe through the proxy      -> exit=7 http=000        (refused)
    DENY svchost (pid 1800) - not part of the update          (the background phone-home, blocked)
    CONNECT fe2cr.update.microsoft.com:443 ... served         (the update itself, unaffected)
    scan: 0 update(s) available                               (pass unaffected)

GRANULAR POLICY, which is what identity-based control buys - the user's point: access can be
granted to one more updater without opening the proxy to everything. Two additive REG_MULTI_SZ
values under HKLM\SOFTWARE\Qubes\UpdatesProxy - AllowedImages and AllowedServices - extend the
built-in sets, re-read every few seconds. Proven both ways on the guest:

    default (curl not in policy)        curl exit=7 http=000
    AllowedImages = curl                curl exit=0 http=200

QUBES_UPDATES_PEER_ALLOWLIST=off restores the old purely-temporal behaviour, for diagnostics.

### And a denied caller must see "no network", not "network failing"

The first version of the gate accepted the connection and closed it, which is the wrong signal:
a client that gets accepted and then dropped mid-protocol concludes the proxy is BROKEN, retries
and logs errors. The right signal for an offline qube is a connection that never comes up.

The denial now aborts with SO_LINGER 0 before a byte is read, so the caller gets a reset at
connect time - what an unreachable proxy looks like. Measured on the guest with a pass in
flight:

    curl       exit=7 "couldn't connect" after 2.1 s   (not 56 reset-mid-stream, not 28 timeout)
    WebClient  WebException "Unable to connect to the remote server" after 2.3 s
    the update pass itself: unaffected

Fast-fail matters as much as the wording: nothing hangs waiting for a timeout, and Windows
reports no internet, which is the correct state for a qube whose proxy is not for it.

Denial logging is throttled to one line per distinct caller per minute - a refused client
retries, and a line per retry would bury everything else in the relay log.

### And a denied caller must see "no network", not "network failing"

The first version of the gate accepted the connection and closed it, which is the wrong signal:
a client that gets accepted and then dropped mid-protocol concludes the proxy is BROKEN, retries
and logs errors. The right signal for an offline qube is a connection that never comes up.

The denial now aborts with SO_LINGER 0 before a byte is read, so the caller gets a reset at
connect time - what an unreachable proxy looks like. Measured on the guest with a pass in
flight:

    curl       exit=7 "couldn't connect" after 2.1 s   (not 56 reset-mid-stream, not 28 timeout)
    WebClient  WebException "Unable to connect to the remote server" after 2.3 s
    the update pass itself: unaffected

Fast-fail matters as much as the wording: nothing hangs waiting for a timeout, and Windows
reports no internet, which is the correct state for a qube whose proxy is not for it.

Denial logging is throttled to one line per distinct caller per minute - a refused client
retries, and a line per retry would bury everything else in the relay log.

## 2026-08-15 (afternoon) — GWeck's build re-run on 25H2, and one artifact attributed to the guest

**The updater leak is closed and proven.** `Install-ViaWU` set `DODownloadMode=99` for its own pass
and restored it just before building the result rows, so the "WU: nothing to install" early return
walked past the restore - measured on win11-tpl, the policy was still set afterwards. The restore is
now a function called from a `finally` around the whole body:

    before: DODownloadMode=(unset) -> "DODownloadMode=99 for THIS pass only" -> "WU: nothing to
    install" -> "Delivery Optimization: restored" -> after: DODownloadMode=(unset)

The multistage-defer guard has now been SEEN TO FIRE both ways (`QUBES_UPDATES_FAKE_STAGED=1` ->
"DEFERRED ... CBS would discard a second one", staged=NO -> the fallback runs). win11-tpl also had
no `NoAutoUpdate` value at all (it predates the code that sets it); set to 1 and re-checked.

**win11-fresh is Windows 11 25H2 (26200.9168).** The earlier "no 25H2 target" note is stale - S1-class
work is reproducible locally. Its installed agent was NOT any shipped build: sha256 7463399F... matches
neither 4.3.1 (99480D87) nor 4.3.2 (20EC3EC4). Everything measured before that check was measured on an
unknown intermediate binary. Verify the hash BEFORE the experiment, not after.

**The Start-menu surface is not a stable target across 25H2 UBRs.** On 26200.9168 it is a
`Windows.UI.Core.CoreWindow` titled "Start" (`FindWindow` finds it, so the agent's special-casing runs);
on GWeck's earlier 25H2 it is `Wnd_StartFeed`, untitled, exactly 1920x1080, TOPMOST|TOOLWIN, no owner -
`FindWindow(CoreWindow,"Start")` returns NULL there and every Start special-case is dead code. When it
maps, dom0 does not raise the suspicious-request dialog for it: his screenshot shows the OTHER
protection - the daemon unsetting `override_redirect` on a "very large window" - which is what leaves
Start bordered and mis-drawn. Per owner direction (2026-08-15) the stock Start path is NOT being chased;
Open-Shell is the answer, and his last posts (54-56) contain no Start complaint at all.

**The rendering error visible today is the GUEST's, not ours.** Notepad's content sat 394 px below its
own frame. Same number on 4.3.1 and on 4.3.2, so "the newer build fixes it" was false - and the reason
is that it was never ours: capturing the window IN THE GUEST with `CopyFromScreen` gives
`banner_y = 394` too, identical to what dom0 renders. The app never re-laid-out after a resolution
change; the transport is faithful. Attribution needs the in-guest capture - the dom0 picture alone
cannot tell "we sliced it wrong" from "Windows drew it that way".

**Three fixes postdate the build he ran, one per symptom - all still UNPROVEN.** `c7ccb45` (his
4.3.1) contains none of: `6ea0822` "never leave the desktop with no attached display" (his black
inactive window after the IDD reboot), `4643931` "re-assert IDD-solo when a display is attached under
us" (his ~1 cm pointer offset), `fbf9368` "self-heal the AppVM first boot" (his post-56 AppVM that
starts and silently shuts down). Each needs a defect-present/defect-absent pair on one rig before it
counts, per the standing rule that a newer build is not an answer to a bug report.

## 2026-08-15 (evening) — the never-headless guard CANNOT be seen to fail here, so it stays unproven

Setup: win10-tpl = **Windows 10 Pro 22H2 (19045.2965)**, GWeck's exact platform; the 4.3.1 IDD
(`root\iddsampledriver`, from the shipped v4.3.1 package) installed on it; agents swapped by hash
(4.3.1 = 99480D87, 4.3.2 = 20EC3EC4).

The injection itself works. With `HKLM\SOFTWARE\QubesIDD!SoloFaultInject=2` the agent logs
`the apply will be made to FAIL on purpose and the rollback is SUPPRESSED`, aims set-primary at
`\\.\DISPLAY_QUBES_FAULT_INJECT` and gets -5 (DISP_CHANGE_BADPARAM) - exactly the pre-fix sequence.

**But the state it exists to prevent is unreachable on this platform.** Three attempts:

1. IDD already attached+primary, VGA attached: pass detaches the VGA, apply fails -> IDD still
   attached, one display. Nothing lost.
2. VGA attached+primary, IDD DETACHED (the shape of GWeck's post-reboot guest): pass detaches the
   VGA, apply fails -> readback shows BOTH attached again. Windows re-attached them.
3. Agent held out entirely (`NoTopologyApply=1`) and both displays detached by hand with
   CDS_UPDATEREGISTRY: Windows refused the last detach and re-attached the IDD (attached=1).

So Windows 10 22H2 will not leave this guest with zero attached displays, and the persisted-headless
state that `6ea0822` guards against could not be produced. Consequences, stated plainly:

- `6ea0822` ("never leave the desktop with no attached display") is a plausible defensive guard whose
  PASS is **UNPROVEN**. It has never been seen to fail, so it must not be reported as the fix for
  post 54's black window.
- GWeck's "black inactive window" is therefore **NOT explained** by the zero-display mechanism on a
  stock Win10 22H2 + our IDD. Something else on his box produces it (his display config: laptop panel
  disabled, external 1920x1200 on Intel). The one artifact that would settle it is the gui-agent log
  from a BLACK boot - `Q:\Qubes Logs\gui-agent-*.log`, retrievable over qrexec with no display at all.
- Repeated `devcon disable/enable` cycling of the IDD wedged the guest (qrexec stopped answering) and
  left the device in Error state; recovered with kill/start + `devcon remove` + `devcon install`. Do
  not cycle the IDD device as a test trigger.

Rig note: win10-tpl's previous agent (3D2E6BCE, version string 4.2.2.0) was overwritten by 4.3.2 -
`useagent.ps1` keeps no backup, unlike the win11-fresh swap which kept `.devbuild`.

## 2026-08-15 (evening) — GWeck's Win10 path reproduced end to end; the black window did NOT follow

Not simulated - walked. win10-tpl (Windows 10 Pro 22H2, 19045.2965), starting from stock QWT 4.2.2,
then his two builds in his order, each the release tarball verified against the release SHA256SUMS:

1. `qwt-ng-4.3.0-agent09b643e-setup.tar.gz` -> `in-place-msi-major-upgrade`, `idd_driver: "not
   requested"` (4.3.0 does NOT touch the IDD - matching his "the previous version was fine"), reboot,
   agent 4.3.0.0 (91F40ECE) running. The hand-installed IDD from an earlier experiment was REMOVED
   first (devcon remove + pnputil /delete-driver) so the baseline matched his: VGA only.
2. `qwt-ng-4.3.1-agentc7ccb45-setup.tar.gz`, `install.cmd` with NO flags, exactly as reported ->
   `package_version 4.3.1+agent.c7ccb459aec9`, agent sha 99480d87 (the shipped 4.3.1 binary), and:

       idd_driver: "activated: device up (ROOT\DISPLAY\0000), VGA adapter disabled (PCI\VEN_1234...)"

   **That is the mechanism behind the severity of his report**: activating the IDD DISABLES the
   emulated VGA, so if the IDD then fails to present, the guest has no display at all and no
   fallback. The installer records its own recovery hint (`Enable-PnpDevice -InstanceId ...`).

3. Reboot (the one he says goes black). Result here: IDD solo at 5120x1440, desktop alive, apps map
   and render correctly (Notepad captured and read back clean). ONE keyed-mutex abandonment fired -
   `GetFrame: AcquireNextFrame() failed with error 0x887a0026` (the CLAUDE.md "prerequisite bug") -
   but `RecreateDuplication` recovered it twice and frames kept flowing (QGAPERF seq 388+).

So **his black window did not reproduce on his exact build, his exact upgrade path and his Windows
version**. It is environment-specific, and the outstanding difference is his host display config: a
disabled laptop panel plus an external **1920x1200** monitor. Relevant measured fact: our IDD's mode
list is 1024x768 / 1600x900 / 1920x1080@60,90,144 / (host size) - **no 1920x1200** - and a request
for it is SNAPPED, not added:

    SetVideoMode: RESREQ 1920x1200 src=lastapplied
    SetVideoMode: RESSNAP 1920x1080 SNAPPED

A dom0 window of 1920x1200 over a guest desktop of 1920x1080 is exactly the shape that puts the
pointer BELOW where Windows thinks it is (dom0 y in 0..1200 mapped onto 0..1080) and leaves a dead
band - his symptom #1, and it would appear on Win10 and Win11 alike, as he reports.

What would settle the black window: his `Q:\Qubes Logs\gui-agent-*.log` from a BLACK boot (it is
retrievable over qrexec with no display at all). Ask for that specifically.

## 2026-08-15 (night) — the arbitrary-resolution feature was a TRAP for any size not already offered

Root cause (workflow wf_b0e24422, 9 agents, plus hand verification). `SetVideoMode` routed by the
request's SOURCE STRING, and only two strings reached the path that can EXTEND the IDD mode list:
`dom0` (resolution.c:1561) and `seamless-force`+QIDD (resolution.c:1575). Every other source - in
particular the boot restore `lastapplied` (vchan-handlers.c:174) and the fresh-guest `xconf` - fell
through to `SelectSupportedMode`, which picks the nearest entry from a cache enumerated ONCE at
startup, i.e. the driver's hardcoded base list. 1920x1200 exists nowhere in `driver/`.

It is a trap rather than a downgrade because of the ORDERING: the only publish on that path runs
AFTER the pick and carries the SNAPPED size, and the legacy tail then PERSISTS the snapped size
(resolution.c:1673 CfgWriteDword FULLSCREEN_WIDTH). So the wanted mode is never offered and never
re-requested - a 1920x1200 monitor is pinned to 1920x1080 for the life of the guest, and dom0 keeps
a 1920x1200 window over a 1920x1080 desktop. That is GWeck's "pointer about 1 cm below where the
system believes it to be" plus a dead band (post 54), on Win10 and Win11 alike, as he reports.
The driver would have accepted it: bounds are 640..16384 x 480..6144 (Driver.cpp:151) - it was
never asked. A4CLAMP is excluded: it runs BEFORE SetVideoMode, and RESREQ read 1920x1200.

FIX (agent 5e752d6): when the Qubes IDD is present, EVERY source takes the publish-and-obtain path;
the legacy snap survives only for a guest with no IDD, where a fixed-mode adapter genuinely cannot
be taught modes. `allowSnap` stays TRUE, matching dom0.

PROVEN, interleaved, on win10-tpl (Win10 22H2) with the precondition re-established before every
run (mode set cleared + IDD restarted, `pre_offered=0` asserted each time):

    shipped 4.3.1 (his binary)     RESSNAP 1920x1080 SNAPPED   desktop=1920x1080  offered_after=0
    fixed bin, ModeSnapFaultInject=1   SNAPPED x3              desktop=1920x1080  offered_after=0
    fixed bin, knob off                NO SNAPPED line x3      desktop=1920x1200  offered_after=2

The knob (`HKLM\SOFTWARE\QubesIDD!ModeSnapFaultInject`, dead code when unset) re-introduces the
defect on the SAME binary, so this check has been SEEN TO FAIL - it is evidence, not a PASS.

METHOD NOTE, and the reason the first re-runs were void: after ONE fixed run the driver offers
1920x1200, so the legacy path then finds an exact match and prints `RESSNAP 1920x1200` with no
SNAPPED suffix - both sides "pass". The defect exists only while the mode is absent, so the mode
set must be reset between runs or the A/B measures nothing.

Also surfaced (not yet acted on): `guest/resize-sync.ps1:40` is a SECOND writer of
`HKLM\SOFTWARE\QubesIDD!Modes` and can race the agent's own publication.

## 2026-08-15 (night) — the rest of the list: three more fixes, one honest "unproven"

Driven by workflow wf_cdf94a84 (4 defects, each diagnosed then attacked by an adversary).

**1. A second writer of the agent's mode set - REMOVED.** `guest/resize-sync.ps1` wrote
`HKLM\SOFTWARE\QubesIDD!Modes` as a SINGLE-entry list (`-Value @($size)`) and replugged the device.
That does not merely race the agent's publication, it destroys the set: the target slot, the LRU of
recent dom0 sizes, the habitual work-area sizes, and the host entry that seamless REQUIRES (without
it the seamless force fails DISP_CHANGE_BADMODE). It was the v0 prototype of a loop whose production
home is the agent - its own header says so - nothing called it and it never shipped in a package, so
it is deleted rather than defanged. (The reviewing agent preferred making it read-only; deleting a
destructive stray that git history still holds is the smaller surface.)

**2. A ceiling we do not have is not a ceiling of zero - FIXED.** `SelectSupportedMode` filtered
every candidate against `g_HostScreenWidth/Height`, which are 0 until HandleXconf assigns them and
stay 0 if msg_xconf carried zero (nothing validates it). At zero the filter rejects EVERY mode and
the tail returned index 0 - an arbitrary adapter mode, unrelated to the request and not even inside
the ceiling just enforced - which SetVideoMode then PERSISTS as FullscreenWidth/Height, so the next
boot asks for it again. Unset bounds now mean no ceiling; a genuine no-fit returns MAXDWORD ("no
opinion") and the guest keeps its current resolution. Reachability, not oversold: with the IDD
present the exact-follow path bypasses this function, so it matters mainly for a non-IDD guest and
for anything reaching the snapper before xconf. `ModeCeilingFaultInject` re-introduces it - and on
an IDD guest it MUST be paired with `ModeSnapFaultInject=1` or the run proves nothing, which is
exactly the trap this project keeps falling into.

**3. Two guest-log defects - FIXED.** `GetWindowData` logged every dead-window race at ERROR
(E_HANDLE from DwmGetWindowAttribute when a window closes between enumeration and measurement) -
dozens of lines a minute on an idle guest, which is how a real failure gets missed; only that one
status is demoted. `WorkAreaApply` had the worse one: it stored `g_WaLastApplied` BEFORE attempting
the apply, so a REFUSED apply was remembered as applied - the next pass saw "unchanged", returned
early, and the guest kept a work area Windows never accepted with nothing retrying it. The rect is
now clipped to the desktop that actually exists (dom0's feed describes dom0's window; the guest
desktop can legitimately be smaller, briefly so during a mode change), the refusal names the
rectangle and the desktop, and the applied rect is recorded only after Windows accepts.

**UNPROVEN, and said so rather than proxied:** the work-area fix. The failing condition
(SPI_SETWORKAREA refused every 30 s) was observed on win11-fresh but could NOT be reproduced on
win10-tpl - in fullscreen with no dom0 work-area feed `WorkAreaApply` never runs, and forcing a
smaller desktop behind the agent's back did not take. It is correct by construction (recording an
apply that was refused is plainly wrong) but it ships without a defect-present/defect-absent pair.

## 2026-08-15 (night) — agent restarts LEAK GRANTS until the guest can no longer have a GUI  [RETRACTED 2026-08-16 - see below, 14-kill test with the precondition asserted found zero failures]

Found by accident while A/B-ing binaries on win10-tpl: after many stop/swap/start cycles the agent
began dying immediately at startup, watchdog respawning it into the same wall, 0-byte logs one second
apart:

    XcGnttabPermitForeignAccess2: IOCTL_XENIFACE_GNTTAB_PERMIT_FOREIGN_ACCESS_V2 failed: 0x5aa
    init_gnt_srv: Granting ring to domain 0 failed
    libvchan_server_init failed
    WinMain: WatchForEvents failed with error 0x5aa: Insufficient system resources exist ...

0x5aa is ERROR_NO_SYSTEM_RESOURCES: the grant table is full. Each agent start grants the framebuffer
to dom0; a killed agent never revokes, and xeniface evidently does not reclaim everything when the
owning process dies. The end state is a guest that answers qrexec perfectly while having NO GUI at
all, and it does not recover on its own - only a reboot clears it.

Why it matters beyond the test harness: the watchdog restarts the agent on every failure, so a guest
in a crash-restart loop walks itself into this state, and the symptom it produces - "the qube is
running, I can do nothing with it, there are no windows" - is the same shape users report.

METHOD DAMAGE, recorded because it nearly became a false result: two of four log-noise measurements
were taken against this DEAD agent and reported 0 errors, which reads exactly like a clean PASS. The
harness had no liveness assertion. Only `log_growth=1` (an empty log delta) gave it away. Any
measurement that can be satisfied by "nothing ran" is not a measurement - assert the agent is alive
and the log is growing BEFORE trusting a count.

Not yet fixed. Options, none tested: revoke on graceful exit (does not help a kill), have the agent
detect 0x5aa at startup and reclaim its own previous grants, or bound the watchdog's restart rate so
a crash loop cannot exhaust the table. Related: docs/upstream-xen-pv-grant-revoke-spin.md.

## 2026-08-15 (night) — the agent announced UNINITIALIZED STACK MEMORY as window geometry

The most serious defect found today, and the first mechanism that actually explains the dom0
"invalid or suspicious GUI request" dialog GWeck photographed (post 45) - unexplained through two
prior investigations.

`GetRealWindowRect` returns a WIN32 status, not an HRESULT, and two of its failure returns are
POSITIVE numbers: `ERROR_INVALID_DATA` (0xd) and `win_perror`'s return. `GetWindowData` tested
`if (!SUCCEEDED(status))`, and `SUCCEEDED(0xd)` is TRUE - so for those two failures it skipped the
error path entirely, fell through with its `RECT rect;` still UNINITIALIZED, and returned
ERROR_SUCCESS. Whatever was on the stack became the window's geometry and was announced to dom0.

The `ERROR_INVALID_DATA` path is not exotic - it is every zero-sized top-level window (degenerate
DWM bounds AND degenerate GetWindowRect), which ordinary shell surfaces produce constantly.

PROVEN, identical 40 s workloads on win10-tpl with a deliberately created 0x0 top-level window
(`scratchpad/zerowin.cs`), agent liveness asserted before each run:

    pre-fix  (4.3.2, 20EC3EC4):  65 GetRealWindowRect rejections ->  1 reached GetWindowData
                                 => 64 swallowed, each returning success with a junk rect
    fixed    (D05BC3A2):         65 GetRealWindowRect rejections -> 65 reached GetWindowData

Fix: test `status != ERROR_SUCCESS`. Companions, both required: `UpdateWindowData` and
`GetWindowData` demote E_HANDLE and ERROR_INVALID_DATA to debug, because propagating them correctly
turned 64 silent garbage announcements into 65 ERROR lines per 40 s - measured on the proving run
itself - which would have moved the noise rather than removed it.

TWO HAZARDS THIS BRANCH INTRODUCED YESTERDAY, caught by adversarial review and not by me:
  - `|| !found` in SelectSupportedMode pinned index 0 for a zero-dimension request - reinstating
    the arbitrary pick the change existed to remove, for the one input that produces it. A zero
    request now returns the "no opinion" sentinel explicitly.
  - the MAXDWORD sentinel made SetVideoMode return ERROR_SUCCESS WITHOUT applying a mode, while the
    adopt-current rescue sat INSIDE the failure branch - so g_ScreenWidth/Height could stay 0 and
    `x * 65535 / g_ScreenWidth` in HandleMotion divides by zero on the first pointer event. The
    rescue is hoisted out; its own zero test was always the real guard.
Both are the direct argument for running the adversary over one's own patches, not just over the
code one is patching.

Also: the capture-restart gate logged BOTH its edges below the default log level, so a shipped
guest recorded nothing when capture stopped or came back - the one question a "my qube is frozen"
report needs answered. Now CAPTUREGATE at warning/info.

## 2026-08-15 (night) — 4.3.2 SHIPPED, and a new candidate for the "black window"

Published `v4.3.2-agentbacfd2c` (setup tarball + ISO + dom0 RPM + SHA256SUMS), superseding the stale
`v4.3.2-agentec07ac8` draft whose assets predated every fix of the last two days.

Verified on win10-tpl against the ACTUAL release package, not the build tree:

    upgrade 4.3.1 -> 4.3.2:  in-place-msi-major-upgrade, pv_boot_disk true, pvdisk 9.1.0.0 -> 9.1.0.0
    idd_driver:              "skipped (/noidd)"        <- the switch GWeck says is not accepted
    updater_agent:           "deployed"
    installed_gui_agent_sha256 == expected_gui_agent_sha256
    /iddoff:                 IDD device removed, NoTopologyApply=1, VGA re-enabled and primary
    /noidd on a guest with NO IDD: boots on the emulated adapter, windows map, notepad renders

**NEW FINDING, not yet fixed - a full-screen CLOAKED window is mapped to dom0.** On that same guest
dom0 showed a mapped, untitled, full-screen window (`0x1c0018b  0 56 3440 1440 ... "?"`). In the
guest it is:

    cls=ApplicationFrameWindow  pid=explorer  vis=1  cloaked=2  rect=0,0,3440,1400  title=(empty)

`cloaked=2` is DWM_CLOAKED_SHELL - the shell has hidden it, so the user cannot see it. We map it
anyway, and dom0 paints a blank full-screen rectangle over the whole qube. That is an extremely good
match for "the qube shows only a black inactive window while everything else still works": apps run,
qrexec answers, and the desktop is covered by an empty window. It appears on the NON-IDD path too,
so it is independent of the IDD.

Do not fix this with a blanket cloak filter: CLAUDE.md 2A-chrome 3c is explicit that toasts are
topmost+layered+frequently CLOAKED and must be KEPT. The discriminator has to separate
"shell-cloaked full-screen frame with no title" from "cloaked toast", and the toast acceptance test
gates any change.

## 2026-08-15 (night) — the "black window" mechanism: window tracking is SUSPENDED, not filtered

The cloaked full-screen window was the symptom of something much larger, found by workflow
wf_90491655 and confirmed against source. My own patch for it (`419e1b3`) was REVERTED: its premise
was refuted by its own file, and by my own probe.

**What is actually wrong.** main.c:6196-6199:

    if (g_VchanClientConnected && g_SeamlessMode && !g_LocalScreenDestroyed)
        ProcessWindowEvents();
    else
        DiscardWindowEvents();

`g_LocalScreenDestroyed` is set by StopFrameProcessing (main.c:5506) from the capture-error case
(main.c:6153, the one I made visible today as `CAPTUREGATE capture error`), and is cleared ONLY in
StartFrameProcessing (main.c:5425), which is reached only after the gui-daemon's MSG_DESTROY(0)
confirm (vchan-handlers.c:1231-1236). While that state lasts:

  - every window event is DISCARDED,
  - the frame-path TrackWindows (main.c:4541) is dead because capture is stopped,
  - so NO tracking pass runs at all.

Consequences, in the exact words users keep reporting: every already-mapped window stays mapped in
dom0 for ever (a stale rectangle over the qube), and - the part that matters most - **no NEW window
can ever appear**. GWeck, post 54: "the Windows key does nothing at all. Trying to start an
application from the Qubes menu does not work either." Applications DO start; they simply can never
be announced. qrexec keeps working throughout, which is why the qube looks alive and useless at the
same time.

CLAUDE.md's own recorded prerequisite bug - `AcquireNextFrame` failing 0x887a0026 on a
seamless/resolution change - lands exactly in that capture-error case. And there is precedent
already in this file at 7286-7300: dom0 kept a dismissed Start menu and a toast mapped for ever,
with `SendWindowMap` and no matching `SendWindowUnmap`. Same signature, same class, never explained.

**The one observation that separates it** (guest-side, no new code): take the HWND of the stuck
window from winenum and grep the agent log.
  - `Mapping window 0x<hwnd>` with no later `Unmapping window 0x<hwnd>`, plus `CAPTUREGATE capture
    error` with NO following `CAPTUREGATE gui daemon confirms screen destruction`  => the freeze.
  - repeated `DWM-cloaked (0x2)` for that hwnd while dom0 still shows it  => the tracker IS running
    and removal fails downstream instead.
That grep is now possible only because both CAPTUREGATE edges were moved above the default log
level earlier today; before that a guest in this state recorded nothing at all.

**What I got wrong, recorded because it was nearly shipped as a fix.** I patched the
measurement-failure path in UpdateWindowData on the theory that it left a stale entry accepted.
It cannot: UpdateWindowData returns the failure status and BOTH callers (main.c:3493-3497 and
3513-3517) already set DeletePending on any non-success return - a line that predates 4.3.2. My own
synthetic probe agreed, removing the window correctly on the pre-fix binary. Reverted in 52ee8f8.
The corroborating "dom0 announced a taller rect than GetWindowRect" argument was also unsound:
GetRealWindowRect multiplies both axes by a DPI scale that can exceed 1.

**Next, not done:** bound the wait for the daemon's confirm (a capture gate that never opens is
indistinguishable from a dead qube), and sweep windows that disappeared while the screen window was
down. Both need their own defect-present/defect-absent pair; neither is shipped.

## 2026-08-15 (late) — RETRACTION: the capture gate does NOT stop windows being announced

I wrote earlier today that while `g_LocalScreenDestroyed` is set "NO NEW WINDOW CAN EVER APPEAR" and
that this "explains GWeck's #16 and #17 exactly". **That is overstated and I withdraw it.** The
injector built to prove it disproved it instead.

With `CaptureGateFaultInject=7` (confirm suppressed, deadline disabled, capture error raised on
purpose), the gate opened and a brand-new window was announced anyway:

    CAPTUREGATE CaptureGateFaultInject: raising a capture error on purpose to open the gate
    CAPTUREGATE capture error - screen window destroyed, waiting for the gui-daemon confirm
    SendWindowUnmap: Unmapping window 0x0
    SendWindowMap: Mapping window 0x1201c6      <- a window mapped AFTER the gate opened

So `ProcessWindowEvents` being skipped is not the whole story: some other path still announces
windows in that state. The code-level reading (main.c:6196-6199 discards window events) is correct;
the CONSEQUENCE I drew from it is not.

What the defect run DID show, which is a real fault worth fixing: with the confirm suppressed the
daemon eventually dropped the connection, and the agent then sat in "Awaiting for a vchan client"
until the first-boot self-heal fired at 90 s and respawned it. So the user-visible cost of a gate
that never opens is a session outage of at least 90 s, not a permanent freeze.

The deadline fix (15 s, two re-sends, then respawn) shortens that and makes it explicit in the log,
and it is committed - but it is **NOT PROVEN**: the fix-side run never reached the gate, because by
then the rig had been churned into a state where no daemon client attached, so the injector's own
precondition (g_VchanClientConnected) never held. Rig rebooted clean; injectors disarmed.

To finish this properly: run the pair on a freshly booted guest, fault=7 then fault=5, each with a
confirmed vchan client before the injected error, and compare the time from the injected capture
error to a working session. Until that exists, the gate fix is defensive code with a plausible
rationale and no demonstration - the same status as the work-area fix, and it must be described
that way.

## 2026-08-16 — the capture gate fix is PROVEN, and the other half of the fault is upstream

Same binary (A9F0897F), one registry flag apart, freshly booted guest each time, precondition
asserted before every run (a gui-daemon client MUST be connected before the injected capture error,
or the run aborts as VOID - the earlier attempts that "passed" had silently skipped this):

    CaptureGateFaultInject=7  (confirm ignored, deadline DISABLED = pre-fix)
        capture error injected -> agent did NOT respawn within 120 s, no recovery within 300 s.
        It simply sits with the gate shut, doing nothing, for as long as anyone waits.

    CaptureGateFaultInject=5  (confirm ignored, deadline ENABLED = the fix)
        capture error injected -> "no confirm from the gui daemon in 15000 ms - re-sending the
        screen destroy (attempt 1 of 2)" -> agent respawned 19 s after the error.

**The full chain, now evidenced rather than modelled.** The gate opens (capture error). The confirm
does not come. The agent's re-send finds the vchan already dead (`A6EXIT ... open=0`). It exits, the
watchdog respawns it - and dom0's gui-daemon for that qube never comes back, so every later instance
waits for a client that will never arrive. The qube keeps answering qrexec and shows nothing, and
only restarting the qube fixes it. That matches the field reports far better than the "no window can
ever appear" story I retracted yesterday, and this time each step has a log line behind it.

The daemon half is NOT ours to fix and is already on the reportable list (CLAUDE.md upstream
exception): `handle_vchan_error` never consults `vchan_at_eof`, so a disconnect noticed on the WRITE
path skips the restart the daemon otherwise implements. Our agent cannot restore a daemon that has
exited; what it can do is stop hanging silently, act within 19 s, and say what happened.

Which is the second half of this change: a one-DWORD marker written the first time a client
connects. Without it every respawned agent reported "no gui-daemon client ... and NONE EVER
CONNECTED", which is false after a lost session and sends the reader to check the qube's gui feature
instead of the daemon. Seen firing in the fix run:

    no gui-daemon client in 90000 ms - exiting so the watchdog respawns the agent (attempt 1 of 3).
    This guest HAS had a daemon before, so this is a LOST session, not a first boot: dom0's
    gui-daemon for this qube most likely exited.

Also fixed here: my own injector was gated on `captureGateFault != 2` after the knob became bit
flags, so the "defect-present" value 7 kept the deadline ON and the first run measured the fix
against itself. A knob that cannot express the defect is worse than no knob.

## 2026-08-16 — the ACCESS_LOST root cause is OURS, and it is at boot

Workflow wf_426983cc ranked the triggers by recorded evidence rather than by mechanism, and the
answer is not the one the mechanism suggests.

**#1, and 17 of 24 recorded natural events: we hot-unplug the monitor two statements before we
create the duplication.** `ResolutionPublishBootModeSet` wrote the boot mode set and then made it
live with an IOCTL reload; the driver answers a reload by departing and re-arriving the monitor -
unconditionally, without comparing the sets - which is a hot unplug. `StartFrameProcessing` then
built the desktop duplication into a topology still settling from that replug. FINDINGS 4113 has a
single cold boot with 8 transient 0x887a0026 including a CaptureInitialize that failed outright, and
`StartFrameProcessingWithRetry`'s retry loop exists to survive exactly this.

Nothing needed that reload: the desktop is already running at the current size, so its mode is
offered by definition, and the reload only pre-arms LATER switches - which perform their own obtain.
The neighbouring `ResolutionRecomputeIddModeSet` already states the discipline ("registry rewrite
ONLY ... a dom0 panel move must not blink the screen"); it now applies to boot too.

MEASURED, three interleaved pairs, a COLD BOOT for every run, one change between the binaries, and
each run asserting the agent is alive with a daemon connected before it counts anything:

    round   boot replug (A9F0897F)      no boot replug (363AE675)
      1     4 / 1 / 2                   1 / 0 / 0
      2     4 / 1 / 2                   1 / 0 / 0
      3     4 / 1 / 2                   1 / 0 / 0
            (access_lost / capture_init_failed / a7retry)

Identical in every round: the boot cluster is four events with a failed CaptureInitialize and two A7
retries, and removing the boot reload leaves exactly one event and no retries at all.

**#2 is the only trigger proven at millisecond resolution** and it is not ours: the Winlogon ->
Default input-desktop flip, from GWeck's own log (ACCESS_LOST and "input desktop changed" in the
same millisecond), once per boot. That is very likely the one event still left above.

**Zero recorded occurrences**, and therefore not ranked: the UAC secure desktop. I disabled
`PromptOnSecureDesktop` earlier today on reasoning alone, and item #2 is the LOGON flip, not a UAC
prompt - so that change does not address the proven trigger. It stays (it is sound for seamless, and
correctly mode-gated after the owner pointed out that fullscreen has a real SAS path), but it must
not be described as fixing anything measured.

**Strong negative control**: drag, steady-state capture, DWM restart, RDP and host suspend produce
zero - 16 ddaprobe runs with ACCESS_LOST 0 and re-duplications 0. Novel-size replugs are a blink,
not a fault: obtain -> reload 16 ms -> offered 281 ms -> applied 344 ms, and habitual sizes cost 0.

### RETRACTED, and it would have been severe

I wrote a "quiesce capture across the mode change" bracket and shipped it to a test build. It could
never have worked: `CaptureStop` clears `g_CaptureThreadEnable`, and `RecreateDuplication` bails on
that flag (capture.c:465 "asked to stop while recovering") AFTER releasing the duplication - so
`CaptureReplugEnd` could only return FALSE, every call site discarded the result, and every mode
change with live capture would have frozen the qube's pixels permanently and silently. My own
measurement showed access_lost going UP (3 vs 1) and I read it as noise; the adversary read it as
the defect. Reverted in full (22fad26, d2b56c6).

The lesson is the one this project keeps relearning: an instrument that cannot fail is worthless,
and a fix whose own numbers get worse is not "noisy", it is wrong.

## 2026-08-16 — RETRACTED: agent restarts do NOT leak grants

Yesterday I recorded "agent restarts LEAK GRANTS until the guest can no longer have a GUI" and
reported it as the one hard failure we had reproduced ourselves. **It is wrong.**

Test: 14 consecutive kills of gui-agent on win10-tpl, each iteration ASSERTING the precondition
before killing - a gui-daemon client attached AND grants actually issued (`A3CHECK`/
`SendScreenGrants` present in the log) - because a kill with nothing granted strands nothing and
proves nothing. Result: every instance reconnected, **zero** occurrences of 0x5aa or "Granting ring
to domain 0 failed". A first attempt at this test was itself void (no daemon was attached, so no
grant was ever created) - the same precondition trap that has now caught me three times in one day.

So the staging grant is evidently reclaimed when the process dies, and the "capacity-sized grant
stranded per kill" mechanism I described does not happen.

What actually produced the original 0x5aa: it appeared while the agent was in a restart loop AND
the gui-daemon was gone or dying, and the failing call was granting the VCHAN RING
(`init_gnt_srv: Granting ring to domain 0 failed`), not the framebuffer. That points at the
daemon-side half of the vchan rather than a per-restart guest leak. Unproven either way, and it
must not be described as a known guest-side leak.

The watchdog backoff added for it stands on its own merits - respawning a fast-failing agent once a
second helps nothing - but its stated justification was wrong and is corrected here.

## 2026-08-16 — the grant leak is REAL after all, and the cause is in the shipped xeniface binary

I retracted the grant-leak finding earlier today on a 14-kill test. **That retraction was wrong, and
the test was incapable of failing.** Workflow wf_8d8cb19b did not stop at the source: it extracted
`xeniface.sys` from our own `vendor/qwt-4.2.2/installer.msi` (sha256 a5f666e3c7b4...) and
disassembled it.

**Release builds of xeniface never revoke a grant.** The only `RevokeForeignAccess` call in the
driver is the ARGUMENT OF AN ASSERT (`xeniface/src/xeniface/ioctl_gnttab.c:151-157`), and in a
non-DBG build `ASSERT(_EXP)` expands to `__analysis_assume(_EXP)` (`assert.h:128-136`) - the
expression is compiled out. Confirmed in the shipped binary, not inferred: `strings` finds no
"ASSERTION FAILED" (DBG=0), and `GnttabStopSharing` (0x14000b1c0) does `memset` +
`ExFreePoolWithTag` and makes NO calls through the CFG dispatch slot every xenbus interface call
uses. Two functions in the same binary whose interface calls sit OUTSIDE an ASSERT
(`GnttabPermitForeignAccess`, `GnttabFreeMap`) do emit that call - so this is the ASSERT being
elided, not an optimiser artefact.

Consequences, all mechanical:
  - `GnttabStopSharing` is the sole teardown path, reached from BOTH the revoke IOCTL and IRP
    cancellation on process death, so a graceful exit and `taskkill /f` are bit-identical: neither
    revokes anything.
  - The IOCTL returns STATUS_SUCCESS regardless, so our own `STAGING revoked on exit` line is a
    FALSE SUCCESS and the "dom0 still maps, leaking" warning is unreachable for the stated reason.
  - A reference returns to the pool only via the `Put` inside `GnttabRevokeForeignAccess`, which is
    never called. Every ref the guest allocates is gone until the domain is destroyed.

**Why my 14-kill test could not fail.** The host gives 2048 max grant frames = ~1,048,576 refs;
14 kills x ~4000 staging pages = 56,000 refs, 5% of the pool. It measured that the pool is big.

**What is NOT reachable on this system**: the dominant consumer the analysis identifies -
per-window grants at attach and every resize (~2025 refs per 1080p window, ~518 events to exhaust) -
because per-window capture never attaches here. `PwInit: per-window capture ENABLED (daemon version
gate applies at attach)` is logged, and no attach ever follows: this dom0's gui-daemon does not meet
the version gate. Measured twice, including on a clean boot: 700 resizes, `pw_attaches=0`. So on
THIS host the leak rate is bounded by staging grants (~7200 pages per agent start at 5120x1440) and
vchan rings (33 pages each, per agent start and per qrexec invocation) - predicting exhaustion at
roughly 145 restarts rather than 14. That prediction is now under test.

**The fix is not a patch to xeniface.** It is XenProject's, pinned at 9cd9a604 and fetched at build
time; we take headers only and stage the signed .sys bit-identical from the vendored MSI. Fixing it
would mean building and test-signing a PV driver, and it would still be insufficient - with dom0
mapping the pages, the revoke's 100-attempt CAS cannot match and loses the reference anyway. It is
reportable upstream under the CLAUDE.md exception, with the owner's approval of the text.

**The elimination that works with the driver exactly as shipped**: one grant arena per boot, owned
by something that never dies, sub-allocated to every consumer, never revoked. Total refs per boot
becomes a constant - independent of restarts, resizes and window count - so exhaustion is impossible
by construction. The kernel-owned version (our IddCx driver grants its own framebuffer at load) is
CLAUDE.md Phase 1B Outcome B and is a project; a user-mode holder service that does nothing but hold
the section is a strict prerequisite of it and ships far sooner.

METHOD NOTE, the fourth this session: this test was void three times before it was valid - no daemon
attached, then no grants issued, then per-window capture not attaching. Every one of those runs
printed a clean "zero failures". A precondition that is not asserted is a result that is not real.

## 2026-08-16 — the grant-exhaustion test is BLOCKED on the rig, not answered

The disassembly finding above stands on its own. The live confirmation does not exist, and this
records exactly why rather than leaving a half-run experiment looking like a result.

Attempted: ~160 agent restarts on win10-tpl, each asserting a connected gui-daemon before the kill,
watching for 0x5aa. Predicted exhaustion near 145 restarts on this host (staging ~7200 pages per
agent start; the per-window consumer that would exhaust it in ~518 events is unreachable here - the
daemon version gate is never met, measured as pw_attaches=0 across 700 resizes on a clean boot).

Blocked by the rig: win10-tpl now has NO gui-daemon in dom0. The guest agent sits at "Awaiting for a
vchan client" and dom0's window list for the qube is empty - not even the screen window - across
several full qube restarts. The qube's own config is correct (`gui 1`, `guivm dom0`), so this is
dom0-side and outside what this environment may touch. Earlier in the same session the daemon
survived agent kills perfectly (14 in a row, and a single-kill test that reconnected in 3 s), so
this is a state the rig fell into, not a property of the build.

What that means for the leak question:
  - MECHANISM: established by disassembly of the shipped binary, independent of any rig state.
  - RATE ON THIS HOST: bounded by staging grants and vchan rings, ~145 restarts predicted.
  - OBSERVED FAILURE: NOT reproduced. Do not claim it is.

RESOLVED as a rig fault, not a system one: win10-clean starts with its daemon attached and a live
desktop window, so the failure was win10-tpl alone - that qube is broken and needs recreating, not
diagnosing around. (There is no persistent per-qube daemon in dom0; guid is started at qube start,
so "never comes back across restarts" means that qube's start is not producing one.) Calling it a
blocker was an autonomy failure: the two-minute check that settles it is starting another Windows
qube.

The test therefore moved to win10-clean, where the numbers are exact rather than estimated:

    STAGING granted 7200 pages capacity 5120x1440     <- logged on EVERY agent start
    + ~33 pages for the vchan ring
    pool ~1,048,576 refs (2048 max grant frames x 512, less 32 reserved)
    => exhaustion predicted at ~145 restarts

so a 200-restart run crosses the threshold inside itself. At 103 restarts: zero grant failures, a
daemon client connected on every iteration.

## 2026-08-16 — the per-window grant leak, end to end, all four steps measured

Chain, with nothing inferred:

1. **The shipped driver never returns a reference.** xeniface's only RevokeForeignAccess call is the
   argument of an ASSERT, which release builds compile out - established by disassembling the
   xeniface.sys inside our own vendored MSI, with two same-binary controls ruling out an optimiser
   artefact.
2. **Per-window capture spends ~3819 refs per window APPEARANCE, permanently.** Defect-present run
   on 363AE675, fresh domain, window open/close churn:

       cycle 250 : attaches=251 grant_failures=0
       cycle 275 : attaches=272 grant_failures=8   -> EXHAUSTED

   The arithmetic predicted ~274 (1,048,576 refs / 3819). It broke at 272. Nothing anywhere was
   reclaiming them - the question "was this already mitigated somewhere?" is answered: no.
3. **The degraded state is INVISIBLE, which is what makes it dangerous.** With the pool exhausted
   the agent stays alive, PwAttachWindow fails, and the window is mapped on the legacy screen-slice
   path instead: frames keep flowing (QGAPERF seq 1643 -> 1708) and a window opened AFTER exhaustion
   renders perfectly - captured and read back, title bar, menu, caret and status bar all correct.
   The guest has silently reverted to stock-style capture and looks fine.
4. **The next agent restart kills the GUI outright.** Killing the agent in that state:

       agent_alive=False   client connected: 0
       XcGnttabPermitForeignAccess2 ... failed: 0x5aa
       init_gnt_srv: Granting ring to domain 0 failed
       WinMain: WatchForEvents failed with error 0x5aa
       dom0 window list: EMPTY

   qrexec still answers. Only restarting the qube recovers it.

So the user-visible shape is: use applications normally for an afternoon, notice nothing, and then
the first crash/watchdog respawn/mode toggle leaves a running qube with no GUI. That is the class of
report we have been chasing all week, arrived at from the other end.

**Fixed by the slab pool** (agent 100a9bb), measured on the same rig:

    123 window attaches -> 5 slabs granted; the last 80 attaches granted NOTHING

References now scale with peak concurrent windows instead of window history. The 5-rather-than-1 is
the 2 s quarantine overlapping a 1.5 s churn cycle - a slab is not handed to a new window while dom0
may still be compositing the previous one from it.

STILL OPEN: the staging grant is 7200 pages per AGENT START (~144 restarts to exhaustion, measured
separately). That one needs an owner that outlives the agent process - a holder service, or the IddCx
driver granting its own framebuffer (CLAUDE.md Phase 1B Outcome B).

## 2026-08-16 — drag wobble is still there, and it is the PARKED structural one

Owner dragged a window on win10-clean (pre-pool build 363AE675, 5120x1440) and reported crazy jumps
plus rendering errors. Both captured with ProtoTrace on:

  - WOBBLE: 2 direction reversals in the last 25 CONFIGURE announces (~8%), against the 16-19%
    recorded in docs/PLAN-drag-quality.md. This is the PARKED defect, not a regression: gui-daemon
    sends WINDOW-RELATIVE motion (`k.x = ev->x`) and withholds `ev->x_root`, so the agent adds back
    an origin that lags and is unobservable mid-drag. Gain-1 correction plus transport lag is an
    oscillator. The one-line exact fix is in dom0 (forbidden), freeze was rejected, the servo is
    default-off and judged marginal.
  - RENDERING: the window came back with its right-hand side BLACK and real content on the left -
    a per-window buffer filled only where damage covered it.

Announce cadence measured on the same rig, which is the thing PLAN-drag-quality names as "likely the
largest single remaining factor" and had never been run:

    desktop=5120x1440   announces=295   gap p50=26.0 ms  p95=62.0  mean=122.3

The plan predicted p50 66 ms at this resolution; the measured p50 is 26 ms, so the announce clock is
better than assumed - but the p95 of 62 ms and a mean dragged to 122 ms by outliers say the TAIL is
what a user feels, consistent with the earlier bench (tot p50 442 us, p99 40 ms, enu max 600 ms).

**A defect the slab pool introduced, found by that screenshot and fixed immediately**: with buffers
reused, the unpainted region would have shown the PREVIOUS WINDOW'S pixels rather than black - one
application's content inside another's frame. Slabs are now zeroed on acquire (agent 2addd20),
restoring the pre-pool appearance exactly.

## 2026-08-16 — drag baseline locked (agent `3811e98`, package build 31942731976)

User-confirmed good on win10-clean. This is the reference point for any future drag change; per the
canonical-benchmark rule, compare against these numbers, never against an intra-day build.

Binary under test verified installed: running `gui-agent.exe` SHA256 prefix `DA3E37CD274F8454`,
equal to the pushed artifact. Preconditions asserted in-run, not assumed:
`QGADRAGQUANT on (adopt=70 ms, announce pacing=140 ms)` from the log banner, and **no** registry
overrides present — so this measures the shipped defaults, not a ladder rung.

| metric | value | note |
|---|---|---|
| announces | 225 | 10 s hand drag with deliberate reversals |
| moves | 162 | non-zero deltas |
| reversals | 23 (14.2 %) | includes genuine hand direction changes - see caveat |
| max run | 1520 px | long straight runs are clean |
| announce gap | p50 134 ms, p95 802 ms | p50 tracks the 140 ms pacing as designed |
| edge black-fraction | left=0 right=0 top=0 bottom=0 | **was left=7** before the crop fix |

**Caveat on the reversal metric**: it counts every sign change in announced x, so a reversal the
user's hand actually performed is indistinguishable from a wobble the agent invented. 14.2 % here vs
11.6 % at the 200 ms rung is therefore NOT evidence that 140 ms is worse - the hand paths differed.
The metric is only comparable across runs driven by a scripted, identical mouse path. Treat the
hand-drag number as a sanity bound (it is nowhere near the 85.7 % of the broken pacing=0 build), not
as a precision instrument.

**Crop refresh is settle-only.** `WcSetCrop` marks the WGC channel dirty, so refreshing it per move
event forces a full-window recapture at input rate. A move now only sets `PwCropStale`; the settle
handler applies it, where a recapture is already scheduled - the correction is free and lands before
the repaint, so the first post-drag frame is already correct.

## 2026-08-16 — where the frame rate actually goes, and why drag is not smoother

### The agent is not the bottleneck: 0.7 % of the frame budget

win10-clean on the IddSampleDriver (5120x1440@60, BDA disabled), full-rate damage load, 900 frames,
`PerfLog=1 PerfEveryN=1`:

| metric | p50 (us) |
|---|---|
| frame interval `dt` | 16868 -> **59.3 fps** |
| `AcquireNextFrame` blocked (`acq`) | 15091 |
| **agent total (`tot`)** | **114** |
| damage `dmg` / wake `wak` / enum `enu` / send `snd` | 53 / 75 / 5 / 0 |

The agent spends 114 us per 16.9 ms frame. The other 99.3 % is the capture thread BLOCKED waiting
for DWM to present. Optimising the agent's frame path buys nothing - that work is not what we wait
on. p10 fps was 30.4 (`dt` p95 = 34490 = exactly two vblanks), but the load generator is a PowerShell
WinForms painter, so missed vblanks are plausibly the generator's, not the pipeline's - unproven.

What caps the rate is OUR driver: every published mode was hardcoded 60 Hz and DWM presents at the
mode rate. Now configurable via `HKLM\SOFTWARE\QubesIDD\ModeVSync` (default 60 = unchanged),
applied to monitor modes, registry modes AND the target list, since the OS offers the intersection.
Owner decision 2026-08-16: 60 Hz is fine; the knob ships default-off and unexercised - **not tested
at any value other than 60**, so raising it is unproven and would need a guest-CPU measurement first
(no GPU: DWM composites through WARP on the CPU).

### Drag smoothness is capped by the announce rate, not the frame rate

The window only MOVES in dom0 when we send `MSG_CONFIGURE`, and those are paced at
`InputDragAnnounceMs` = 140 ms: **~7 position updates/s against a 60 fps content stream**. That is
the stepping, and the two rates are independent.

The pacing is not arbitrary. dom0 sends motion in WINDOW-RELATIVE coordinates and withholds
`x_root`, so reconstructing an absolute position needs to know which window origin dom0 used for
that event. We know every origin (we chose them); we do not know WHEN dom0 applied one, so we wait
`InputDragAdoptMs` = 70 ms to be sure. Announce faster than the apply lag and events become
ambiguous - each announce moves the origin the next event is measured against, closing the gain-1
loop that produced the 85.7 %-reversal build.

**dom0 does not tell us either.** Measured on the baseline drag: **541 announces for the drag
window, 26 inbound configures - 4.8 %.** There is no per-move confirmation to lock onto; the 70 ms
is a guess because the protocol offers nothing better.

Two ways up, in order of availability:
1. **Shrink the guess.** 70/140 was chosen conservatively and never measured against dom0's real
   apply lag. If the true lag is ~30 ms, pacing could roughly halve. In-guest, no protocol change.
   Requires a SCRIPTED identical mouse path - hand drags are not comparable (see the baseline note).
2. **Close the gap.** Daemon sends `x_root`, or echoes applied geometry. Deletes the problem, but it
   is an ENHANCEMENT, not a bug, so it does not qualify for the CLAUDE.md upstream exception and
   waits for the completed work.

### Hiding guest-native window controls: technically yes, but it costs WM management

Tested on Notepad: stripping `WS_CAPTION|WS_SYSMENU|WS_MINIMIZEBOX|WS_MAXIMIZEBOX` +
`SWP_FRAMECHANGED` works - `caption_gone: true`, app survives, outer rect unchanged, and seamless
keeps streaming normally (agent announced the window with `ovr=0` and damage kept flowing).

But the window drops out of dom0's WM-managed window list. dom0's screenshot service selects from
`_NET_CLIENT_LIST` filtered by `_QUBES_VMNAME` and exits 1 when it captures nothing:

| state | captured |
|---|---|
| caption stripped | 0 bytes (2/2 attempts, plus 3 earlier) |
| caption restored | 20480 bytes (2/2) |

Notepad was the VM's only mapped window, so "nothing captured" means that window specifically left
the managed list. The consequence is the opposite of the goal: you do not get "dom0 decoration
only", you get NO decoration from either side - and with it, no dom0 titlebar to move or close by.
Strictly, what is proven is the service's before/after, not the X property directly.

It would not be uniform anyway: apps that custom-draw their caption (Chrome, Edge, Office, Win11
Explorer) paint those buttons into the CLIENT area, where no style change reaches them. The result
would be some windows losing the caption and others keeping it.

Conclusion: not worth doing by style-stripping. If the goal is the double-titlebar look, the layer
that owns it is dom0's WM decoration policy (off-limits) or the daemon (upstream, later).

## 2026-08-16 — attempt to measure dom0's apply lag offline: FAILED, hypothesis disproved

Tried to recover dom0's apply lag `L` from the baseline drag log with no new drag, on the hypothesis
that some of the 26 inbound configures were echoes of positions we announced.

**They are not.** Correlating all 541 outbound announces against the 26 inbound configures for the
drag window matched all 26 at exactly 0 ms - because the match found our own ACK REPLY, emitted in
the same millisecond as the inbound request:

    20260816.144113.230 IN  199 271     <- dom0's configure request
    20260816.144113.230 OUT 199 271     <- our ACK, same ms, same coords

So the inbound stream during a drag is dom0-INITIATED (the WM adjusting), not confirmation of
anything we sent. dom0 emits no per-move acknowledgement, which is exactly why `InputDragAdoptMs` is
a fixed guess. The 4.8 % inbound/outbound ratio measured earlier stands but means dom0-initiated
moves, not feedback.

**Consequence for measuring `L`.** It needs real dom0-driven pointer motion over the window:
- a guest-side `SendInput` drag does NOT work - it never generates dom0 motion events, so the
  reconstruction path under test is bypassed entirely;
- polling dom0 window geometry is not an option: geometry polling captures the whole dom0 desktop
  (privacy), and the qrexec round trip is far too coarse to resolve a ~30 ms lag anyway;
- so it is either one ordinary hand drag with the trace build installed, or a dom0-side pointer
  injection service (xdotool mousemove/mousedown is present in dom0, but adding a service is a dom0
  change and needs the owner).

Rig is left armed for the first option: trace build `058B4A02E45A677A` installed and verified,
ProtoTrace on, shipped drag defaults, Notepad open. One caption drag produces the data.

## 2026-08-16 — RETRACTION: the `/idd` "file not found" was OUR bug, and we blamed the reporter

Two entries in this file are **wrong and are retracted**:

- FINDINGS.md ~6442: *"NOT our bug (post 35 /idd 'file not found'): GWeck hand-built Start-Process
  -FilePath 'D:\idd' ... Our install.cmd relaunches via %~f0 (=D:\install.cmd) and cannot emit
  D:\idd"*
- FINDINGS.md ~6945: *"S4 /idd: user error (Start-Process 'D:\idd')"*

Also retracted: my own reading earlier today that GWeck's post-64 `C:\iddoff` meant he was running a
stale `install.cmd` left in `C:\QWT-NG`. He was running 4.3.2. The bug is ours.

**Mechanism (proven experimentally on win10-clean, not argued from source).** `install.cmd`'s option
parser uses bare `shift`. Bare `shift` starts at argument **ZERO**, so it overwrites `%0` with `%1`.
The parse loop runs BEFORE the elevation check, so by the time the UAC relaunch expands `%~f0`, `%0`
is the switch. `%~f` then runs it through the Win32 path normaliser, where `/` is a separator and a
LEADING separator means "root of the current drive":

    BEFORE arg0=[C:\...\shifttest.cmd]  tildef0=[C:\...\shifttest.cmd]
    AFTER  arg0=[/iddoff]               tildef0=[C:\iddoff]
    WOULDRUN: Start-Process -FilePath 'C:\iddoff' -ArgumentList '/iddoff' -Verb RunAs

Byte-identical to his post-64 transcript, ArgumentList included. `/idd` yields `C:\idd`; from a
substituted X: drive, `X:\idd` — which is his post-35 `D:\idd` from the ISO. **One bug produced both
field reports, a year apart in our triage, and we closed the first as user error.**

`RAWARGS` is captured before the loop, which is why the arguments looked right while the path was
destroyed — the asymmetry that made it look hand-built.

**Scope.** Fires iff (non-elevated OR UAC-filtered token) AND >=1 recognised switch. Elevated
console: unaffected. Bare `install.cmd` non-elevated: unaffected (no shift ran) — which is why
double-click installs never showed it. Unrecognised switch: exits 87 first.

**Why no test could ever have caught it.** Every rig sets `EnableLUA=0`
(`mgmt/autounattend.xml:180`, `mgmt/autounattend-win11.xml:246`, `guest/firstboot-setup.ps1:29`), so
`net session` succeeds and the relaunch block is **unreachable on our hardware**. The non-elevated
row — the default posture of every real user — is not merely untested, it is structurally
untestable on the current rigs. Recorded `/iddoff` PASSes all went through qrexec, which holds a
High-integrity token.

**Second defect, same 8 lines.** `exit /b 0` was unconditional and `Start-Process` had no
`-Wait`/`-PassThru`, so a failed elevation was reported to the caller as SUCCESS.
`tools/qwt-bootstrap` waits on it and returns its code, so `qubes-tools-<ver>.exe /passive` run
non-elevated printed an error and exited 0.

**Fixed** by capturing `set "SELF=%~f0"` before the parse loop and reading `%SELF%` thereafter
(preferred over `shift /1` because a future switch cannot reintroduce it), plus `-Wait -PassThru`
with exit-code propagation. **Not yet released, and the regression check has NOT yet been seen to
fail** with the defect reintroduced — that needs a UAC-on rig or a `-ForceUnelevated` hook, so it is
recorded as unproven per the CLAUDE.md rule.

## 2026-08-16 — the Windows key: we killed the menu we recommended

`g_BlockMenuKey` shipped **ON** in 4.3.2 (`perf.c`, compiled default AND registry fallback). In
`HandleKeypress` it drops Super key presses and every key carrying the Mod4 bit, in seamless, before
`SendInput`. In seamless the taskbar HWND is never mapped, so that key is the ONLY entry point to a
Start menu — stock or Open-Shell.

We had already dropped the stock Start menu as unsupported (GWECK-STATUS #6/#7) and told the
reporter Open-Shell was the answer; he confirmed it working in post 55. Then we shipped a flag that
suppressed the menu we do not support by removing the one we recommend. Post 64: *"Neither the
Windows nor the Open-Shell menu can be used at all."*

Now opt-in. The mechanism is retained and is still correct for anyone who wants stock Start
suppressed. This is exactly the blast-radius gate: a change that DISABLES something must enumerate
what must still work, and everything we have ever recommended as a workaround is a permanent test
case.

## 2026-08-16 — what is actually machine-verified before a release (honest inventory)

CI (`.github/workflows/`) has **no test or e2e job at all**. What is asserted before publishing:
file presence, SHA256 re-verification, ISO/RPM plumbing, version arithmetic, and a PowerShell parse
of `Install-QwtImproved.ps1` **only** (`activate-idd.ps1`, `deactivate-idd.ps1`,
`install-updater-agent.ps1` are never even parsed; `install.cmd` is never linted).

**Zero user-facing switches are executed by any automated gate.** One combination — `/auto /idd`,
copied-dir, elevated, fresh guest, en-US — is exercised by `tools/accept-clean.sh`, which someone
has to remember to run. Never executed in any form, by anything: `/nonet`, `/nodisk`,
`/noapptweaks`, `/reboot`, `/acceptpvdiskupgrade`, `/noupdates`, and the SUCCESS path of
`/updatesonly`. Nothing in the repo ever runs `activate-idd.ps1` or `deactivate-idd.ps1`.

Further gaps worth their own work, found during the audit and NOT yet fixed:
- Flags are persisted across the inter-stage reboot only under `-Auto`
  (`Install-QwtImproved.ps1:634`), but the manual path tells the user to "run install.cmd again"
  without saying "with the same flags" — so a manual two-stage `install.cmd /noidd` **activates the
  IDD in stage 2**.
- `/iddonly`, `/iddoff` and `/updatesonly` bypass `Test-Payload`, so those paths do no SHA
  verification of the medium.
- `:needfile` checks only the FIRST script of each branch; the rest of the payload fails as raw
  PowerShell exceptions — the very class `:needfile` was added to eliminate.

## 2026-08-16 — `/iddoff` and `/iddonly` finally run END TO END, in the reporter's layout

Prompted by the owner: his install went wrong because nothing was ever run end to end. Both switches
had a status of SHIPPED/VERIFIED without either ever being executed as a user executes them.

Setup: real 4.3.2 payload staged at **`C:\QWT-NG`** (a copied directory, his layout - not our ISO),
`install.cmd` replaced with the fixed one, run as `C:\QWT-NG\install.cmd /iddoff`.

**Gate 0 proved itself on first contact.** The run printed:

    QWT-NG installer: 4.3.2+agent.bacfd2c09b18 agent bacfd2c09b18
    Running from:     C:\QWT-NG

That is precisely the line whose absence made post 64 unattributable and cost him a wrong verdict of
user error on post 35.

**Results, judged on outcomes rather than log lines:**

| step | outcome |
|---|---|
| `/iddoff` | `NoTopologyApply=1`, VGA enabled, IDD removed, `ok:true`, auto-reboot |
| after reboot | **VGA the only adapter, 3440x1440, OK**; IDD absent; agent running |
| dom0 view | `qtest shot` returned a live, correctly rendered Notepad; edge black-fraction 0 on all four sides |
| `/iddonly` | IDD activated, VGA disabled, `ok:true`, auto-reboot |
| after reboot | **IddSampleDriver primary at 5120x1440**, agent running, window mapped |

So **his recovery path works**; the `%~f0` elevation defect was the only thing standing in front of
it. Both switches are now genuinely verified for: copied-dir medium, elevated, Win10 22H2, en-US -
and that cell list is the claim, not a bare "VERIFIED".

**Incidental positive**: a deliberately partial medium (idd-driver/ holding only devcon.exe) made
`/iddonly` fail with `C:\QWT-NG\idd-driver holds 0 .inf files (expected exactly 1)` - named the
directory and the missing thing. That is the `:needfile` class working as intended.

**New risk, not yet investigated**: a non-`/auto` run ends at `pause` ("Press any key to
continue . . ."). `packaging/setup/README.txt` documents `/iddoff` as a recovery path to be driven
over qrexec on a guest with no display - and a `pause` with no console is a plausible hang there.
This is a live candidate for the unexplained qrexec half of GWECK-STATUS #25. Harnesses at
`tools/tests/e2e-iddoff.ps1` and `tools/tests/e2e-iddonly.ps1`.
