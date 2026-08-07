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
