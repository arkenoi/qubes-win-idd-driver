# capture — findings

## CURRENT STATE

AUTHORITATIVE. Supersedes everything under History below. A correction belongs HERE,
not only as a new dated section — the whole reason this file exists is that 654
correction lines were buried chronologically in a 25k-line log, so reading a topic
top-down returned the stale answer.

- Not yet distilled from the history below. UNVERIFIED

## History

Append-only. Never edit a dated section; correct it in CURRENT STATE above.

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

## Guest left at `PerWindowCapture=0`

Deliberate, and a trade-off worth stating: 0 avoids the new artifact AND makes the shadow
impossible (synthesis inert), so it is the best interactive experience right now — but it is
**not** the configuration a real user gets, since nothing in the install path writes the value
and the code default is 1. Flip it with:
`Set-ItemProperty 'HKLM:\Software\Invisible Things Lab\Qubes Tools' -Name PerWindowCapture -Value 1`
then reboot the qube (an in-place agent restart destroys gui-daemon on this build).

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

## 2026-08-16 — discriminator for "this app draws its own header" (no app list needed)

Requirement (owner): windows with their own tabs and client-drawn controls must be LEFT ALONE; Edge's
appearance is fine as it is. So the header-stripping predicate needs to detect custom-frame windows
rather than carry a class allowlist.

**Behavioural test.** An app that paints its own header removes the standard non-client area
(`WM_NCCALCSIZE`), so its client rect reaches the top of the window. Measure
`ClientToScreen(0,0).Y - GetWindowRect().top`:

| window | top inset | WS_CAPTION | own header |
|---|---|---|---|
| Edge `Chrome_WidgetWin_1` | **0** | set | yes |
| Notepad | **51** | set | no (OS draws it) |
| Explorer `CabinetWClass` | **0** | set | yes (ribbon extends into the caption) |
| Store `ApplicationFrameWindow` | 0 | set | yes |
| UWP `Windows.UI.Core.CoreWindow` | 0 | clear | yes |

**`WS_CAPTION` is NOT a discriminator** - every window above has it set, Edge included. Only the
inset separates them.

Rule: strip the header only when the inset is substantial (OS-drawn caption, e.g. >= 20 px); skip
anything at ~0. Under it, no Chromium window is ever touched, which also makes the unreproduced
"strip kills Edge" observation moot rather than load-bearing. Explorer measures 0 and would be
skipped too - it survived stripping in the test, so skipping is the conservative side of the same
rule at no cost.

NOT YET IMPLEMENTED in the agent: all header experiments so far were applied externally to one
window at a time. Building it in means mutating other processes' styles at map time, where apps that
re-apply their own styles will fight back, and it must be opt-in per the blast-radius gate.

## 2026-08-16 — VERIFIED: everything eligible for synthesis IS being synthesized

Owner: "but what could be properly synthesized should be." Checked, because winwatch measures
ELIGIBILITY (owner + containment), not whether the agent actually composited.

Took the 26 NetUI popups that were eligible for their whole life (`synth=yes` at every sample) and
looked for them in the agent's protocol trace. 14 sampled, all identical:

    0x803ca CREATE=0 DAMAGE=0     0x100326 CREATE=0 DAMAGE=0
    0x903ca CREATE=0 DAMAGE=0     0x110326 CREATE=0 DAMAGE=0
    ... (14/14)

**Zero announced.** They never became dom0 windows - they were composited into the owner, which is
the intended behaviour. Contrast the ineligible shadows in the same session:
`CREATE=1` plus ~15 full-window `DAMAGE` each.

So the synthesis path is NOT leaking: nothing that qualifies is being missed. The only surfaces that
reach dom0 as separate windows are the structurally ineligible ones (16 born ownerless, 9 orphaned
within 165 ms). That closes the question - the remaining work is solely the shadow DROP, not better
synthesis coverage.

## 2026-08-16 — NetUI drop shadows DROPPED: proven pair, red frames gone at source

Owner: "can we just get rid of it so it wont bother us?" Shipped as rule 4 in `ShouldAcceptWindow()`
(`main.c`, beside rule 3), an EXACT class match on `SCENIC_DROPSHADOW_WINDOW_CLASS`.

**PROVEN PAIR** - identical scripted input both sides (`scratchpad/ribbon-drive.ps1`: 30 fixed-point
ribbon hovers, 3 rounds x 10 points, 900 ms dwell):

| | control (no rule) | test (rule 4) |
|---|---|---|
| shadow `CREATE`s | **5** | **0** |
| `rejecting NetUI drop shadow` log lines | 0 | **18** |
| `SYNTH` events (content still composites) | 14 | 7 |

The reject count required raising `LogLevel` to 5, because the rule logs at `LogVerbose` following
rule 2/3's hot-path convention. Without that, `reject_lines=0` was ambiguous between "rule fired" and
"no shadow appeared" - the pair was not complete until the positive evidence existed. LogLevel
restored afterwards. Explorer re-captured after the change: full ribbon, Share tab expanded, all
content intact - nothing lost.

**Two corrections to my earlier analysis, from the adversarial review:**

1. I wrote that the 2A-chrome predicate's `Owner != NULL` clause was why rule 2 misses these. That is
   incomplete: measured `ex=0x08180028` has **no `WS_EX_TOOLWINDOW`** either, so rule 2 misses on
   TWO clauses and deleting the Owner clause alone would have fixed nothing. The ownership finding
   still stands on its own (16/25 born ownerless, 9 orphaned within 165 ms) - it just was not the
   whole cause.
2. I had proposed the pixel criterion as "the region hanging outside the owner". Wrong: the shadow
   rect is **byte-identical** to the content popup's (1766,395 1123x93 and 1997,452 1123x93 each
   appear as both SCENIC and Net UI Tool Window). There is no overhanging region. The real
   observable is the 1 px qube border flashing at the dropdown rect for ~317 ms.

**Deliberately NOT shipped: the style-shape backstop**
(`LAYERED|TRANSPARENT|NOACTIVATE` + `WS_DISABLED` + `WS_POPUP`), which fits all 59 measured samples
equally well. It buys zero measured coverage over the class rule and carries all the false-positive
risk: a click-through, non-activating, per-pixel-alpha window that EXISTS TO BE SEEN - an OLE drag
image, a splash screen, a HUD overlay - is byte-identical in style to a shadow, and `main.c` already
states a false positive (real UI vanishing) is much worse than a spurious border. It also could not
be validated: with the class rule present, removing the style clause changes nothing observable, so
that check could never be seen to fail.

Ship the style form only if a second shadow class is observed that the class rule misses, AND these
are measured first and none matches: Open-Shell menu, an OLE drag image during a file drag, a CJK IME
candidate window, an app splash screen. The drag-image case is the most likely real collision and is
completely unmeasured.

## 2026-08-24 — GWeck's open bug (forum post 85): the black window is Progman, identified from his winenum log

Thread state as of post 85 (2026-08-23). 4.3.3 is largely good in the field: upgrade 4.3.2 -> 4.3.3
on Win10 22H2, fresh installs on Win10 22H2 and Win11 25H2, native menu working, AppVMs working,
network working. ONE open defect: a "black window" in an AppVM, minimizable but NOT closable,
present immediately after AppVM start before any interaction, and - the useful detail - normal
windows lose their Windows-key response while the black window keeps it.

**It is `Progman`.** From the winenum.txt.gz he attached to post 85 (75 windows, 12 visible), exactly
one visible window matches every symptom:

    0x00010102|cls=Progman|vis=1|cloaked=0|owner=0x00000000|
      flags=POPUP TOOLWIN|style=0x96000000|ex=0x00200080|rect=0,0,1920,1200|title=Program Manager

Progman IS the desktop window, which explains the whole symptom set at once: it exists from shell
start (so it appears before any interaction), it ignores WM_CLOSE (minimizable but not closable), and
it holds the shell's Windows-key handling (so the black window responds to it and normal windows do
not). `Shell_TrayWnd` in the same log sits at 0,1152,1920,1200, so the guest screen is 1920x1200 and
Progman covers it exactly.

**Why it renders black:** `ex=0x00200080` = `WS_EX_NOREDIRECTIONBITMAP | WS_EX_TOOLWINDOW`. With no
redirection surface `PrintWindow` cannot capture it, so whatever the agent sends dom0 is empty.

**Why our filter lets it through:** the shell-overlay reject in `ShouldAcceptWindow`
(gui-agent/main.c ~3243) requires ALL THREE of `WS_EX_TRANSPARENT + WS_EX_NOREDIRECTIONBITMAP +
WS_EX_TOOLWINDOW`. Progman has the last two but NOT `WS_EX_TRANSPARENT`, so it fails the test and is
accepted. The comment there says the narrowness is deliberate - it was written for the Win11
drag/snap overlay, which is click-through - so this is a gap in coverage, not a regression.

**Open question, one datum away.** The borderless-fullscreen gate (~3165) should also have caught it:
Progman has no `WS_CAPTION` and is exactly screen-sized. It fires only when
`data->Width/Height >= 99% of g_ScreenWidth/Height`, so either (a) `service.gui-fullscreen` is on for
that qube, or (b) `g_ScreenWidth/Height` is LARGER than 1920x1200 - which is exactly what an ACTIVE
second IDD monitor does to the desktop bounding box (the hazard CLAUDE.md's Phase 1B already names).
GWeck runs the IDD build, so (b) is the live suspicion. His agent debug log would say outright, since
both branches log their rejection; winenum alone cannot distinguish them.

**Proposed predicate, and the trap it must avoid.** "Reject NOREDIRECTIONBITMAP" is WRONG: toasts are
`Windows.UI.Core.CoreWindow` with `TOPMOST|NOREDIRECTIONBITMAP` (gui-agent/toastcrop.h:43,
toastcrop.c:859 gates on exactly that pair), and CLAUDE.md 2A-chrome 3c requires toasts be KEPT. The
discriminator that separates them is TOPMOST: Progman is `POPUP TOOLWIN` with no TOPMOST, a toast is
TOPMOST. So `NOREDIRECTIONBITMAP && TOOLWINDOW && !TOPMOST` catches Progman and cannot touch a toast.
Checked against all 12 visible windows in his log: it matches Progman and the (already cloaked)
DummyDWMListenerWindow/EdgeUiInputTopWndClass stubs, and does NOT match
`XamlExplorerHostIslandWindow_WASDK` (TOPMOST) or any normal app window.

NOT YET IMPLEMENTED - the (a)/(b) question above should be settled first, because if it is (b) then
the same screen-size arithmetic is mis-gating every fullscreen decision on an IDD guest, which is a
bigger fish than Progman.

## 2026-08-24 — GWeck's black window REPRODUCED locally, and it is NOT the Progman filter. RETRACTION + real mechanism

Reproduced on our own `win11-app` (AppVM on win11-tpl). Progman is present with byte-identical
attributes to GWeck's log - same class, `style=0x96000000`, `ex=0x00200080`, not cloaked, no owner,
exactly screen-sized (5120x1440 here against his 1920x1200):

    0x000100F8|cls=Progman|vis=1|cloaked=0|owner=0x00000000|flags=POPUP TOOLWIN|rect=0,0,5120,1440

**RETRACTION of the entry above.** I attributed the black window to the shell-overlay filter letting
Progman through because it lacks `WS_EX_TRANSPARENT`. That is wrong. The agent log settles it:
`ShouldAcceptWindow` logged **zero** decisions this boot, and Progman's handle appears nowhere -
neither accepted nor rejected. The predicate never ran on it. The filter gap I described is real as
a reading of the code, but it is not what produces this bug.

**The real mechanism, from the agent's own log, in order:**

    line 184  AttachToInputDesktop: tid=4328, from=Default, to=Winlogon
    line 188  AddAllWindows: EnumWindows failed with error 0x12a (ERROR_TOO_MANY_POSTS)
    line 189  AddAllWindows: event=enumfail, threadDesktop=Winlogon, inputDesktop=Winlogon
    line 484  AttachToInputDesktop: tid=4328, from=Winlogon, to=Default
    (no AddAllWindows after line 484 - AddAllWindows ran exactly twice, both before the switch back)

`EnumWindows` enumerates the CALLING THREAD'S desktop. The agent's only full sweep ran while it was
parked on the **Winlogon** desktop, where no user window exists, so it failed - and after returning
to Default it never re-enumerated. Every subsequent frame reports `win=0`: no application window is
mapped for the rest of the session.

That accounts for every symptom GWeck lists, which the Progman theory only half covered:
  - black, and appears immediately after AppVM start (the race is during startup, before any
    interaction) - there are simply no windows mapped, so nothing is painted;
  - minimizable but NOT closable - it is not an application window at all;
  - normal windows lose Windows-key response while the black one keeps it - input is going to the
    real desktop while the mapped surface is stale;
  - AppVM-only in his testing - a template and an AppVM reach the login/desktop transition on
    different timings, and this is a race against that transition.

**Trigger chain.** Immediately before the desktop switch: `GetFrame: initial GetFrameDirtyRects
failed with error 0x887a0026: The keyed mutex was abandoned` followed by `RecreateDuplication`.
That is the PREREQUISITE BUG already named in CLAUDE.md Phase 2B-resize - the same keyed-mutex
abandon on a seamless/resolution transition. It occurred twice this boot, with 4 duplication
recreates.

**Fix direction (not yet implemented):** re-run `AddAllWindows` after any successful
`AttachToInputDesktop` transition rather than only at startup, and treat `EnumWindows` returning
0x12A as retryable rather than terminal - 0x12A after EnumWindows is a well-known spurious
GetLastError. Either alone would have recovered this session; the desktop-change re-enumeration is
the one that fixes the class, since any future desktop bounce has the same effect.

Ask GWeck for `C:\ProgramData\QubesLogs\gui-agent-*.log` rather than another winenum - winenum cannot
show this, and the log names it outright.

### Same day, immediately after — RETRACT the Winlogon theory too. We have NOT reproduced GWeck's bug

Opening Notepad in the same session:

    win=0 -> win=2
    AddAllWindows: foreground -> 0x301a6, re-mapping to raise it in dom0
    SendWindowMap: Mapping window 0x301a6

The agent enumerates and maps correctly. `win=0` before that meant only that NO USER WINDOW WAS
OPEN - Progman and the taskbar are correctly not mapped. So "it never re-enumerates, win=0 forever"
is wrong, and so was the Progman-filter theory before it. Two wrong mechanisms in a row on this bug,
both from reading log fragments instead of checking the end state: is a window mapped, and is
anything actually black.

What was actually established on win11-app, and no more than this:
  - Progman exists with attributes byte-identical to GWeck's log, and is NOT mapped here;
  - the Winlogon/`EnumWindows` 0x12A race at startup is real and logged - but the agent RECOVERED
    from it (`from=Winlogon,to=Default` at line 484) and window mapping works afterwards;
  - `0x887a0026` keyed-mutex abandon fired twice this boot with 4 duplication recreates - the
    prerequisite bug CLAUDE.md already names, worth fixing on its own merits;
  - no evidence of a black window on our rig.

So: the INGREDIENTS reproduce, the SYMPTOM does not. The Winlogon enumeration race is still worth
hardening (re-enumerate on desktop transition, treat 0x12A as retryable) because on a slower or
differently-timed boot it plausibly does not recover - but that is a hypothesis, not this bug's
proven cause, and it must not be presented to GWeck as the answer.

Blocked on one thing I cannot do from this qube: SEE the qube's windows. `tools/qtest shot` is bound
to the retired win-idd-test and returns an empty tar for win11-app, so I cannot confirm visually
whether a black window is present. The owner has the display; one look at win11-app's windows settles
whether we are chasing a reproduction we do not have.

### Confirmed visually with `qtest fullshot` - no black window on our rig

I claimed I could not see the qube's windows. Wrong: `tools/qtest fullshot` captures the whole dom0
desktop AND a geometry table, and it is documented on line 12 of the tool itself. It is also the
right instrument for this entire bug class, because the geometry table has a `mapped` column - the
ground truth for what dom0 actually shows, which is what both retracted theories were guessing at.

win11-app, Notepad open:

    id         x    y    w    h    override mapped name
    0x4e00188  0    0    5120 1440 0        0      VMapp command        <- screen window, NOT mapped
    0x4e00189  4740 1090 364  289  1        1      New notification     <- toast, correctly kept
    0x4e0018d  350  363  3826 1016 0        1      Untitled - Notepad

The screenshot agrees: Notepad renders normally, the toast renders bottom-right, nothing black. The
full-screen window IS present but `mapped=0`, i.e. the agent is correctly not showing it - which is
precisely the surface a black window would have to be.

So GWeck's symptom is definitively NOT reproduced here, and the two mechanisms I proposed are both
dead. Also worth noting for 2A-chrome 3c: the toast is mapped `override_redirect=1` and renders -
the behaviour that filter work is required to preserve.

**Instrument note, since this is the third time today:** check the END STATE first - what is mapped,
what is on screen - before reasoning from log fragments. `qtest fullshot` answers both in one call.

## 2026-08-26 — PR 121: answered palainp's data_validated questions (owner-approved text)

palainp misread commit 4 as fragmentation-related and proposed csum_blank+data_validated on ALL
frames. Reply posted (owner edited + approved): commit 4 is the RX direction and load-bearing for
Windows (xenvif receiver.c:584-592 gates segment checksum handling on the flag; absent ->
TcpChecksumFailed -> 0.05 MB/s); repro for the 86% = rx_gso_checksum_fixup delta around a 10 MB
transfer; csum_blank on a COMPLETE checksum corrupts it in any finalizing consumer; un-gating
from GSO drops end-to-end verification on all forwarded traffic. Offered to split commit 4 into
its own PR. Draft file: mirage-gso/upstream/06-pr121-data-validated-reply.md.

## 2026-08-27 — GWeck's black window: defect state SIMULATED and the fix proven against it (agent 8ee3390)
## every candidate leg, but "fixes GWeck's bug" stays UNCLAIMED until he confirms in the field.

The field defect (forum 42717 post 85: Progman mapped as a black fullscreen window) needs TWO
filter legs down at once: the GetShellWindow() identity check not matching (his rig runs
OpenShell; on ours the check alone held the line even with service.gui-fullscreen forced on)
AND the borderless-fullscreen gate not firing (his (a)/(b) cause still unknown - feature on,
or an inflated desktop bounding box, or pre-xconf g_ScreenWidth=0). Rather than reproduce his
exact rig, agent 8ee3390 adds a diagnostic registry bitmask DiagWindowFilterOff (default 0)
that disables each leg individually, so ONE binary shows the defect and the fix:

    win11-app (25H2, Progman attrs byte-identical to GWeck's dump), feature on:
    Diag=3 (identity check off, new predicate off): dom0 geometry
        0x7600189 0 0 5120 1440 0 1 Program Manager     <- THE BLACK WINDOW, on demand
    Diag=1 (identity check off, predicate ON):
        Program Manager gone
    Diag=1 + fire-toast:
        0x760018b 4740 1222 364 157 1 1 New notification <- toast maps, positioned

The fix is the attribute predicate from the 08-24 analysis: NOREDIRECTIONBITMAP && TOOLWINDOW
&& !TOPMOST -> reject (shell furniture; a toast is TOPMOST|NOREDIRECTIONBITMAP and cannot
match). Identity- and timing-independent, so it covers his rig whatever the second leg is.

Process note: the first repro attempt ran on win10-app because it happened to be the running
qube - wrong rig (the defect and the predicate are Win11-attribute-shaped; win10 wasted an
hour incl. an explorer-kill that muddied the session). GWeck's environment is Win11 25H2;
start there next time. Also: FindWindow from the qrexec context is desktop-blind (service
window station) - in-guest window probes must run via an interactive task or be replaced by
dom0 geometry, which is authoritative anyway.

Ship next as 4.3.8 with the relay retry (e5aa944). e2e gate: upgrade install on the 4.3.7
template (exercises the relay-lock path - assert updater_agent deployed), 2 boots with the
standard asserts + toast-maps + no Program Manager/Xen window in geometry.

## 2026-08-27 — GWeck black-window field log (forum post 96): the log CANNOT show the defect,
## because the per-window capture engine has zero telemetry. Suspect identified as his File
## 2026-08-27 — WCBLACK telemetry VALIDATED (fired on a deliberately-black window); the
## user-context probe caveat; slice-fed vs engine path clarified

Telemetry shipped in agent e58274d (wincapture.cpp): WCDEAD on channel death (5 consecutive
capture failures, with last error), WCBLACK latched after 3 consecutive >=99%-near-black
successful captures (1/64 sampling, <0x0C per RGB channel), recovery line, WcPrefill failure
now LogWarning. Threshold rationale: a partial render (frame paints, DComp client empty)
never reaches 100%; the validation window measured 98.4% black; real windows measure <=4%
near-black — 25x separation from the 99% latch.

VALIDATION (win11-app, agent build 7aa4df791f2a from CI): blackwin.ps1 — a captioned
FixedSingle form, all-black including caption via DWMWA_CAPTION/BORDER/TEXT_COLOR,
ControlBox off (glyphs would break blackness), Text NON-empty (empty text+no controlbox
drops WS_CAPTION and the agent slice-feeds it as override-redirect), which spawns its own
white occluder after 2 s (a foreground/unoccluded window is DDA-owned and the engine
deliberately never captures it — first two validation attempts failed for exactly that
reason). Result: `WCBLACK 0x8035c: PrintWindow succeeds but returns >=99% near-black 602x432
content (3 consecutive)` — fired; no WCBLACK on any normal window in the same session
(Explorer attached engine-path alongside). WCDEAD: NOT observed to fire — window destruction
is detected by tracking (WcRemoveWindow) faster than 5 engine failures accumulate; it shares
the validated logging plumbing and counter path with WCBLACK, but per the instrument rule its
PASS is recorded as unproven.

CAVEAT ON TODAY'S EARLIER PROBES: pwdiag/exp-probe run in the USER context (schtasks /ru
user); the agent captures as SYSTEM in session 1, and wincapture.cpp's own ULW comment
records that user-context probes do not predict SYSTEM-context PrintWindow behavior (Edge
bubble: fine as user, blank in the agent). The negative reproduction verdicts REMAIN valid
because they rest on dom0-side pixels (qtest shot = what the agent actually delivered), not
on the probe. pwdiag now carries this caveat in its header; for the field it identifies the
window and gives a first pass, while WCBLACK/WCDEAD in the agent log are authoritative.

Path taxonomy (was muddled today until read from source): PwWindowEligible=FALSE (override-
redirect, WS_EX_NOREDIRECTIONBITMAP, ULW-layered, colorkey) -> slice-fed from the DDA desktop
framebuffer, engine never involved (win11-app: terminal/CoreWindow/borderless popups all
slice-fed). Eligible -> PrintWindow engine channel; DDA-OWNED while foreground+unoccluded
(engine skips; DDA slices feed the buffer); engine sweep covers guest-occluded windows.
GWeck's 0xa0042 attached ENGINE-path (no slice-fed suffix), so WCBLACK/WCDEAD will speak for
his window as soon as he runs a build with e58274d.

## 2026-08-27 — 4.3.10 SHIPPED (v4.3.10-agentab36aef): black-window telemetry, quiet
## default logs with one dom0 debug switch, priming gate fails closed. E2E ALL PASS.

Why a release now: the owner's call on the GWeck case — "better just give him new release
and ask for the log again" — plus the measurement that his 2.3 MB log was 91% per-frame
QGAPERF + 7% SYNTHPAINT traces (diagnostic content ≈ 50 KB). Contents:
- agent e58274d: WCDEAD/WCBLACK/prefill-warn engine telemetry (WCBLACK validated earlier
  today against a deliberately black window);
- agent ffae88a: QGAPERF default OFF (perf.h QGA_PERF_DEFAULT 0), SYNTHPAINT gated on the
  ProtoTrace switch its tag names; off-state logs one self-describing line;
- agent ab36aef: `qvm-features <vm> service.gui-agent-debug 1` — ONE dom0 switch enabling
  per-frame perf + proto traces + Debug level, read once at Init from
  /qubes-service/gui-agent-debug, dom0 wins both directions (owner: "make it configurable
  in our regular way" → "qvm-features please" → "to enable all debug");
- installer (repo 0e02fdb): priming gate retries the qubesdb /type read 3x and PRIMES ANYWAY
  when indeterminate (fail closed) — task #16 closed; result field seeded-indeterminate-class.

E2E (run9, tmp/e2e4310/, agent build 9e2f5b1fa902 manifest-matched): pristine win10 chain →
4.3.9 fresh (LOUD-log control: QGAPERF on — proves the quiet assert can fail) → 4.3.10
upgrade → boot1+boot2 (bound=4.3.5.15838, 5120x1440, agentver 4.3.10, perfframes=0,
off-banner present) → debug-feature A/B (feature=1: QGADEBUG ON + frames flowing;
feature='': QGADEBUG OFF + quiet — dom0 override proven in both directions) → priming
seeded (assert: never skipped-non-template) → xenvif + selfprime armed → AppVM gate PASS
(survived t+300s, svc/start/xenwin/e1074/tcp all green) → Phase B on win11-app with the
RELEASE binary: 15 KB session log, perfframes=0, WCBLACK fired (wcblack:1). ALL PASS 16:48.

Field ask (forum draft in tmp/expblack/forum-draft.md, awaiting owner approval): GWeck
upgrades to 4.3.10, reproduces, posts the (now ~40x smaller) log; WCBLACK-vs-WCDEAD in it
distinguishes renders-black from capture-dead for his window.

## 2026-08-27 (evening) — WCDEAD proven by fire via FI_PRINTWINDOW_FAIL; three testbed traps
## the shipped architecture; measured, not assumed

**Swapchain frame path** (Driver.cpp RunCore): still the pure Microsoft sample — acquire,
release, FinishedProcessingFrame, zero processing. That is CORRECT for our pixel flow: frames
reach dom0 via the agent (DDA + PrintWindow into granted buffers), never via the driver. So
"dirty-rect-limited processing in the swapchain loop" (CLAUDE.md Phase 2B) has nothing to
limit — there is no per-frame work to begin with.

**Idle driver cost, measured** (win10-tpl, 4.3.10, 60 s desktop idle): the IDD UMDF host
(WUDFHost hosting IddSampleDriver.dll) used **0 ms CPU** (0.000%), 7 threads, 9.3 MB working
set. The loop's 16 ms wait-timeout poll is not a real cost. Nothing to optimize.

**Hardware cursor: moot by architecture.** DisableCursor=1 ships by default (installer seeds
it; the agent hides guest cursors) and dom0 draws its own cursor in both seamless and
fullscreen — a guest-side hardware cursor plane would render something nobody ever sees.
Decision: no cursor work; documented here so the sample's TODO stops looking like our TODO.

**Benchmark (4 runs, one build, tools/bench-agent.sh + new instrumentation/bench-phases.sh):**
win10-tpl @ 4.3.10, QGAPERF enabled via the new dom0 feature (its first production use):
drag p50 938/1346/1497/1580 us, scroll 342-400, type 447-569, idle ~300-500. Runs agree with
each other; they are 2-5x the canonical b299011 baseline (drag 613, scroll 121, type 96,
idle ~95) but the comparison is CONFOUNDED and is NOT claimed as a regression: different rig
(baseline was win-idd-test), ~15 agent versions in between, and the host was NOT quiet (the
owner was actively using win11-fresh during all 4 runs, and the owner also flagged a possible
mid-run virtual-desktop switch; these are wall-clock microseconds). These numbers stand as
the under-load reference for THIS rig. **PENDING: canonical quiet-host re-baseline** when the
testbed is free, before any regression verdicts against b299011.

Harness repairs (plumbing only, workload untouched): bench-agent.sh now reads LogDir from the
registry (logs moved to Q:\Qubes Logs on 2026-08-07; the hardcoded path found nothing);
bench-phases.sh derives per-phase p50s from the ### PHASE markers (the guest-side marker JSON
was never pulled by the bench script).

**Track B bottom line:** driver-side performance work has nothing left to deliver — the
driver is a mode-setting and lifecycle component; performance lives in the agent. Remaining
Track B surface is functional, not performance: mode-list/resize behavior (shipped), and any
future stage-3 architecture change (IDD feeding frames directly), which per CLAUDE.md is a
present-the-plan-first item, not something to start.

## b299011 is real on this rig, and the profile says it lives in the damage path

Conditions: owner confirmed testbed free; win11-fresh halted; ONLY win10-tpl running
(4.3.10, QGAPERF via service.gui-agent-debug). Four runs, identical harness:
| phase | q1 | q2 | q3 | q4 | under-load r1-r4 | canonical b299011 |
|---|---|---|---|---|---|---|
| drag p50 us | 826 | 781 | 1551 | 1050 | 938-1580 | 613 |
| scroll      | 384 | 377 | 374  | 436  | 342-400  | 121 |
| type        | 554 | 458 | 596  | 546  | 447-569  | 96  |
| idle (pre)  | 392 | 381 | 302  | 307  | 331-1291 | ~95 |

Quiet == under-load within noise → the 2-5x elevation vs canonical is NOT host load.
Drag is bimodal across runs (781..1551 — the known scene-state trap; no drag verdicts from
this data). Scroll is the clean metric: 374-436 stable, vs canonical 121.

ATTRIBUTION (scroll phase, q2, field breakdown): dmg p50=216us mean=371 (45% of wall),
snd mean=70 (8.6%), tracking 33% (enu spiky: p50 6us, p99 7.7ms — the periodic sweep),
windows=1, dirty_px=164k/frame, sends=2.1/frame. The p50 total (377) is essentially
dmg+snd+drq. LEAD, unproven: the per-window screen-content hash (PwScreenUnchanged reads
the window's whole framebuffer region every frame; a 1054x752 window is ~3 MB/frame) plus
the per-window damage/patch machinery post-dates b299011 and lands exactly in dmg.
CONFOUNDS still standing for any regression claim: different rig (canonical was
win-idd-test; vCPU/host unknown-identical), ~15 agent versions between, QGAPERF schema
drift. What would settle it: A/B with the screen-hash short-circuited behind a flag on ONE
build, same rig, interleaved — a proper Track A investigation, not started tonight.
Raw canonical b299011 bench file was never committed (repo raws end Jul-31) — from now on
bench raws for recorded baselines belong in instrumentation/ (q1-q4 committed).

## 2026-08-27 (late) — #22 CLOSED: the dmg-cost lead is resolved by ABAB — the DDA-slice
## 2026-08-27 (night) — GWECK'S BLACK WINDOW: ROOT CAUSE FOUND AND REPRODUCED. It is the
## PromptOnSecureDesktop=0 validated as the shipped default

Three iterations, each defect found by measurement, all on win11-app (25H2 AppVM,
EnableLUA=1 - the GWeck-faithful rig):

v1 (ShouldAcceptWindow deny) - WRONG: the tracking re-eval treats "no longer acceptable"
as "unmap", so the instant UAC appeared every ALREADY-OPEN window was unmapped (measured:
PwDetachWindow of the live Explorer, dom0 census -> 0). Reverted.

v2 (ProcessNewFrame gate) - INSUFFICIENT: ProcessWindowEvents (the input-rate event leg)
still ran TrackWindows and mapped the consent dialog, which then showed BLACK because the
frame pipeline was frozen (shot14/win-4; the owner saw it live). Extended to v3.

v3 (all three legs gated: frame, events, AddAllWindows) - DEADLOCKED, and this is the
important one: g_OnSecureDesktop is written ONLY by AttachToInputDesktop, and every path
that reaches it was gated by that same flag. Once latched (or on a respawn onto Winlogon -
GWeck's exact case) the agent NEVER re-observed the desktop: stuck on Winlogon forever,
zero windows in dom0, 0-byte screenshots, long after the prompt cleared. Strictly worse
than the original bug. Caught only because the harness kept measuring after the dismiss.

v4 (agent fb4c1cd) - CORRECT: EnsureOnInputDesktop() runs at the TOP of ProcessNewFrame,
BEFORE the freeze early-return, so the flag can always clear itself (it no-ops cheaply
while the desktop is unchanged and re-attaches + rearms hooks on each transition).
Deadlock recovery demonstrated by deployment itself: the v3-stuck agent's dom0 census went
0 -> 7 windows the moment v4 was swapped in.

VALIDATION (v4, agent 7331cc056ebd, CI b0f0250):
- PHASE A (secure desktop, policy default): TWO live consent.exe processes on the guest's
  Winlogon desktop; dom0 census = 8 windows, consent=0 backdrop=0 - i.e. only the
  pre-existing Explorer/Terminal windows, frozen at last-good content. Log: "secure-desktop
  ENTERED ... window mapping suppressed", "AddAllWindows suppressed". Dismiss -> "secure
  desktop left - resuming with a full resync and the frame signature invalidated"; census
  back to 7. PASS.
- PHASE B (PromptOnSecureDesktop=0, the newly shipped installer default): elevation does
  NOT switch desktops (INPUTDESKTOP=Default) and the consent dialog arrives in dom0 as a
  normal 456x376 window, fully rendered, readable ("Do you want to allow this app..."),
  Yes/No visible. PASS. OWNER CLICK-TEST PASSED (2026-08-27, owner clicked Yes in dom0 and
  the elevation proceeded): dom0 input DOES reach the high-IL consent dialog - UIPI blocks
  synthesized guest-side input, not the real user's clicks arriving through the daemon's
  input path. The prompt is fully usable from dom0, which is the whole point of the
  policy default.

HARNESS CORRECTIONS (both were my bugs, not the product's): a window-COUNT assertion
flagged the Terminal the trigger itself spawns - replaced with surface-identity checks
(consent-sized 400-560x330-440, backdrop >=3000px wide); and a transient trigger miss
(INPUTDESKTOP=Default when consent had been killed moments before) needs a retry loop, not
an immediate FAIL.

## the resize chime/slowness is explained (mode-list reload), not fixed

NON-SEAMLESS SHRINK-ON-ENTRY, validated end to end on win11-app (agent c4caac381987, package
4.3.12+agent.2adbd5745f5f, hash-verified):
  QGAFSFLASH non-seamless requested while the desktop is host-sized (5120x1440): shrinking...
  ProcessNewFrame: QGAFSFLASH desktop is now 1280x800 (host 5120x1440) - completing the
    deferred non-seamless switch
dom0 census: exactly ONE window, 1280x800, screencover=0 - the guest desktop as a genuinely
small bounded window on a 5120x1440 display. With a UAC prompt raised: still ONE window,
consent=0 - the prompt is drawn INSIDE the desktop window, which is what non-seamless means
(owner's taxonomy: standalone window in seamless, window inside the desktop window otherwise).
Back to seamless: per-window mapping restored.

Two implementation facts learned the hard way:
1. The completion hook must live on the FRAME path, not in StartFrameProcessing: a resolution
   change frequently kills capture with 0x887a0026 and recovery runs RecreateDuplication,
   which never passes through StartFrameProcessing - so the first attempt shrank correctly and
   then sat there, mode unswitched (measured, then fixed).
2. The seamless force-to-host must be suppressed while the switch is pending, or the shrink
   and the force fight forever.
The guard is scoped to GUEST-originated sizes via g_ResolutionFromDom0: a dom0 configure (the
user sizing/maximizing the qube window) is never second-guessed. Confirmed in the same run -
the post-test 1406x871 desktop came from `RESREQ src=dom0`, i.e. the owner dragging the window,
not from a restore bug.

RESIZE CHIME + SLOWNESS EXPLAINED (owner: "why is window resize still slow and emits sound?
we should had fixed it many releases ago" - it never was). Mechanism, from resolution.c and
guest logs: every NEW size is written to HKLM\SOFTWARE\QubesIDD\Modes, the driver's mode list
is reloaded (QIDD ioctl; PnP replug as fallback), the agent POLLS until Windows offers the mode
(up to EXACT_MODE_WAIT_TIMEOUT_MS), then calls ChangeDisplaySettings. Windows treats the
mode-list change as a monitor arrival/change -> the device-connect chime; reload + wait -> the
latency; and the mode change often triggers the 0x887a0026 capture death + rebuild on top.
Already mitigating: debounced latest-wins resolution thread (one drag produced 2 settled
requests, not one per pixel) and an LRU so a previously published size takes the silent
replug=0 path. NOT fixed: a genuinely new size still reloads. Task #26 holds the two options -
agent-side pre-published mode grid (stopgap) vs driver-side broad/continuous mode set so no
monitor-change event ever fires (proper, Track B).

Also in 4.3.12: the secure-desktop freeze is UNCONDITIONAL (owner re-affirmed after a demo put
a screen-sized window on their display: "it could be a 'secure' desktop INSIDE the desktop
window, it is ok... if it is not fullscreen and does not take over any dom0 controls" - the
takeover criterion, but the guest desktop is host-sized, so in practice any secure-desktop
mapping in seamless IS a takeover); service.uac-disable warns when set on a volatile-root guest
where it cannot work; IDD bind-version assertions; WCBLACK/WCDEAD proven by fault injection.

## 2026-08-28 cont 2 — the sign-in lockout is MEASURED, not inferred

> **UNPROVEN — the headline word "MEASURED" is exactly what fails here (audited 2026-08-29).**
> The result rests on `qtest shot` returning a 0-byte tar, read as "windows mapped = 0". This same
> file records, ~143 lines earlier, that *an empty shot is NOT proof of "no windows", only of a
> failed capture — re-take before concluding*. No re-take, no positive control (same rig, autologon
> ON → non-empty tar) in the same run, n=1. Bars 5 (judge pixels, not a null result) and 6 (missing
> data fails). The lockout may well be real — the later entries treat it as settled and the
> installer's autologon work is built on it — but this entry does not measure it.

win11-tpl autologon disabled (AutoAdminLogon=0, DefaultPassword and AutoLogonCount removed),
win11-app booted from it, 4.3.13 agent (020d1567408f):

    control: windows mapped in dom0 = 0   (qtest shot tar is 0 bytes)
    control: qrexec identity = nt authority\system
    control: newest agent log = gui-agent-20260828-103548-4416.log

So the qube is RUNNING and REACHABLE - qrexec answers as SYSTEM through the pre-session policy -
and dom0 is shown nothing whatsoever. That is exactly the field report ("absolutely nothing is
visible"), reproduced here for the first time, and it needed no exotic setup: only a Windows
account that does not log itself in, which is the default for anyone who installs this package on
a Windows VM they built themselves.

HARNESS NOTES (both cost a run):
- `qtest push` needs the USER-SESSION file receiver, so it cannot deploy into a guest that is
  sitting at the sign-in screen. Deploy first, disable autologon second. qready/SYSTEM qrexec is
  not a substitute for bootwait when the next step needs a session.
- Parsing `reg query` output: the qrun transcript ECHOES the command, and that echo contains the
  value NAME. `grep DefaultPassword | sed 's/.*REG_SZ//'` therefore returned the 116-character
  command line as the "password". It was written back with `reg add /d "<116 chars>"`, which cmd
  rejected, so the real value (`qubes`, per mgmt/autounattend.xml) survived by luck. Anchor the
  grep to the value line (`^[[:space:]]+NAME[[:space:]]+REG_SZ`) and sanity-check the length
  before writing anything back into a guest.

Documented in README under Known limitations, since it is current shipped behaviour whatever the
owner decides on task #30.

## 2026-08-30 — the "black window": guest parked at the sign-in screen, and TWO defects behind it

Owner: the console log looks healthy, *"not like black window of win10-clean"*. Measured on that
guest: `EXPLORER=0`, `LOGONUI=1`, `quser` -> "No User exists", **`SendWindowMap` count = 0**.

So the black window is not a capture failure. It is the LOCKOUT SHAPE this project already documented:
a guest that maps ZERO windows while qrexec still answers - running, reachable, invisible. The
capture path was fine: the boot-time `0x887a0026` keyed-mutex error self-recovered
("A7RETRY capture initialized after 1 retries").

### Defect A: stage 2 declares autologon "verified" using a check that cannot fail on a bad password

From the install log of this guest, contradicting itself across stages:

    STAGE 1  autologon NOT armed (bad-credentials)      "autologon":"not-armed:bad-credentials"
    STAGE 2  ok password present as the LSA secret
             autologon verified - this qube can come back on its own   "autologon":"armed"

Stage 1 validates with `LogonUser` and refused. Stage 2's `guest/ensure-autologon.ps1` only asked
`LsaRetrievePrivateData` whether a secret EXISTS - never whether it WORKS - so it overrode a correct
negative with a weaker positive. A stored-but-rejected credential is the worst state: every
presence check reports "armed" while the guard silently defeats itself.

**Fixed:** `ensure-autologon.ps1` now retrieves the secret and calls `LogonUser` with
LOGON32_LOGON_INTERACTIVE - the same type Winlogon uses - against DefaultUserName/DefaultDomainName,
and reports a distinct loud failure for present-but-rejected. `$lsaValid` defaults to FALSE so a
thrown query cannot pass permissively. Run against this guest it now reports "present as the LSA
secret AND accepted by LogonUser".

### Defect B (NEW, separate): qrexec-wrapper fails interactive logons as `user`

The three 4625 failures (0xC000006D, "Unknown user name or bad password") at 01:15:27/37/43 are NOT
autologon attempts. Event detail:

    Account Name: user   Account Domain: WIN-IDD-TEST   Logon Type: 2 (interactive)
    Caller Process Name: C:\Program Files\Qubes Tools\bin\qrexec-wrapper.exe

They also post-date the boot-time re-arm (`QubesAutologonGuard` last run 01:15:15, result 0), so the
credential was already armed when they failed - and the LSA secret for that same account validates
now. **qrexec-wrapper is therefore using a different credential source than the one autologon
stores, and failing with it.** Not root-caused; recorded with the evidence rather than guessed at.

**Caveat on this guest:** it has had many manual interventions tonight (debug toggle, hard restarts,
agent swaps, a side-loaded xencons). It is not a clean specimen. Whether the sign-in-screen state
reproduces belongs to the matrix, on freshly provisioned guests.

## 2026-08-30 — P5: SG1 and SG6 PASS; SG2/SG4 blocked because SG0.2 containment does not survive a boot

**SG1 (Mode 1 — the boot/shutdown/logon screen is never shown) PASSES**, with a genuine vacuity
guard rather than an absence:

    SG1_FULLSCREEN_SEEN=0
    QGADESK secure-desktop ENTERED (input desktop 'Winlogon') - window mapping suppressed
    AddAllWindows: suppressed: secure desktop is active
    ApplyGuestShadows: no shell window; cannot disable guest shadows
    ProcessNewFrame: secure desktop left after 5 s - resuming with a full resync
    ApplyUacPromptPolicy: PromptOnSecureDesktop=0

The secure desktop was genuinely entered and mapping genuinely suppressed, so "nothing fullscreen
appeared" is a filter result and not a run that saw nothing.

**SG6 (autologon) PASSES** on every product criterion: `AutoAdminLogon=1`, `DefaultUserName=user`,
**`AutoLogonCount` ABSENT** (its presence would mean the password is being consumed toward lockout),
registry `DefaultPassword` ABSENT by design (the credential is the LSA secret), `QubesAutologonGuard`
registered and Ready, and one window mapped after autologon — the invisible-guest regression absent.

### SG2/SG4 are INVALID-PRECONDITION, and the reason is a protocol gap

I sized the probes to 1600x900 after setting that resolution pre-reboot. The trace then showed
captionless and override-redirect 1600x900 windows being MAPped with `service.gui-fullscreen` off,
which reads as a serious Mode-2/Mode-4 gate failure. **It is not one**, and the owner named the
reason immediately: *"because it knows it does not match dom0 geometry?"* Exactly —

    HandleXconf: host resolution: 5120x1440
    SetVideoMode: RESREQ 5120x1440 src=lastapplied
    ResolutionAdoptCurrent: RESDRIFT believed=0x0 actual=5120x1440 - adopting the actual mode

**The agent re-applies dom0's geometry at startup.** A resolution set before the reboot does not
survive it. By probe time the screen was 5120x1440 and a 1600x900 window is 31% of it — correctly
not fullscreen-sized, correctly mapped as an ordinary window. The gate was never exercised, so this
is neither a pass nor a fail: the cell did not run.

**The protocol gap:** SG0.2 prescribes running the fullscreen-gate cells at a sub-host guest
resolution as containment, but does not say the containment must be established AFTER the agent has
settled and verified against **the agent's believed screen size**, not merely against
`Win32_VideoController`. Set before a reboot, it is silently undone.

**Why SG2/SG4 were not simply re-run at 5120x1440:** if the gate did fail, that puts a genuine
full-screen window on the owner's display — the harm already caused once today. Containment first is
not optional. `set-resolution.ps1` is broken (recorded separately) and `qtest resize` returns
`GEOM ok=0 err=no_window` with no window mapped, so containment is currently unreachable; both are
the owed fix, and SG2/SG4 are blocked behind them rather than being run unsafely or scored
optimistically.

