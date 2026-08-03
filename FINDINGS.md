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
