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
