# Drag-frame cost 17 ms under per-window capture: mechanism, fix design, risks

Date: 2026-08-02. Source analysis only, against agent submodule `perwindow` @ 382fa05
(`agent/gui-agent/*`), vendored daemon `upstream/ro/qubes-gui-daemon`, and the raw
QGAPERF evidence in `instrumentation/qwtfull-w10/bench-qwtfull-w10.txt`. Every claim is
tagged **VERIFIED** (read in source / raw data) or **INFERRED** (consistent with all
evidence, not directly measured).

## 1. The verified mechanism

### 1.1 What triggers the recapture during a drag — DDA dirty rects, not LOCATIONCHANGE

**VERIFIED.** The trigger chain for a PrintWindow-fed window is exclusively the screen
dirty rects of the DDA frame:

- `main.c:2944-2951` (`ProcessNewFrame`, `PwIsAttached(entry)` non-slice-fed branch):
  any screen dirty rect intersecting the window's rect → `WcMarkDirty(entry->Handle)`.
  The comment says it outright: *"Screen dirty rects are the change TRIGGER for the
  per-window engine ... content itself comes from PrintWindow, never the screen."*
- A dragged window dirties its whole extent (old+new position) every frame: raw drag
  records show `area` ≈ 573-675 k px with `dr=1` per frame (`bench-qwtfull-w10.txt`,
  seq 324-383) — ~800x600+chrome, matching the bench's ~552 k figure.
- `EVENT_OBJECT_LOCATIONCHANGE` does **not** trigger capture. It drives tracking only:
  hook thread `WindowEventProc` (`main.c:332-367`) → `QueueWindowEvent` →
  `TrackWindows`→`UpdateWindowData`, which sends `MSG_CONFIGURE`
  (`SendWindowConfigureIfChanged`, `main.c:1256`) but never touches the capture engine
  for a pure move (the only engine calls in `UpdateWindowData` are the resize path
  `PwResizeWindow` at `main.c:2262-2278`, gated on `PwWidth/PwHeight != Width/Height`,
  and the ex-style/layering rebuild at `main.c:2124-2130` — neither fires on a move).

### 1.2 Where the row-diff happens and what is diffed against what

**VERIFIED.** `wincapture.cpp:96-193` (`CaptureAndDiff`, dedicated capture thread):
`PrintWindow(PW_RENDERFULLCONTENT)` into a fresh DIB of the OS window rect, then a
row-by-row `memcmp` of the cropped visible region **against the window's own granted
buffer** (`c.buffer`, the page-aligned BGRA buffer granted to dom0), skipping masked
(synth-child) column segments. Changed rows are `memcpy`'d into the granted buffer and
reported as one window-relative row band → `PwOnDamage` → `MSG_SHMIMAGE`
(`perwindow.c:57-64`). Unchanged content = one compare, **zero vchan traffic**.

Consequence, central to the fix: the PrintWindow content of a window is
**position-invariant**. On a move-only frame the diff is empty and nothing is sent —
the entire ~15-18 ms PrintWindow render is thrown away. Supporting raw evidence
(**VERIFIED**): during drag frames the frame thread's `sends` is 0 on most records
(configure goes out between frames via `ProcessWindowEvents`), and the acceptance run
recorded content position-independence directly (FINDINGS.md line 219: 2/219 damage
events with any origin drift during a 10 s drag).

### 1.3 Where the 17 ms actually lands — and why it lands in `upd`

**VERIFIED (accounting):** `upd` = ticks inside `UpdateWindowData` calls
(`TrackWindows` refresh phase, `main.c:2373-2414`), both in-frame and folded from
between-frame `ProcessWindowEvents` passes (`main.c:2864-2876`). `g_PerfSendTicks` is
`__declspec(thread)` (`perf.c:32`), so vchan sends are correctly subtracted and no
other thread can inflate `upd`. The capture thread's PrintWindow is therefore **not**
directly measured in `upd` — the engine runs on its own thread (`wincapture.cpp:195`).

**VERIFIED (correlation, raw records):** during drag, `upd` scales with `iwn`
(interrogations): frames with `iwn=0` show `upd` ≈ 10-30 µs; `iwn=2` → 8-21 ms;
`iwn=4-6` → up to 60 ms. Each interrogation of the dragged window costs ~4-10 ms,
versus ~340 µs for the identical `GetWindowData` path in the accepted baseline (same
guest, no capture engine) and versus the same build's own scroll phase (`tot` p50
117 µs **while the engine is actively capturing every frame** — scroll damages the
window, `WcMarkDirty` fires, PrintWindow runs — but no LOCATIONCHANGE events mean
`iwn≈0`, and no stall appears).

**INFERRED (the one link not directly measured):** the ~8 ms per interrogation is the
frame thread **serializing against the in-flight `PrintWindow(PW_RENDERFULLCONTENT)`
of the same window** — prime suspect `DwmGetWindowAttribute`
(`GetRealWindowRect`/`GetWindowData` make two DWM queries per interrogation,
`main.c:690, 874`) contending with DWM's synchronous render of that window's surface;
expected wait for a uniformly-overlapping 16-18 ms render is ~8 ms, matching. The
scroll-phase control above rules out plain CPU starvation as sufficient (engine active,
frame thread unaffected) and rules out the vchan lock (capture thread sends heavily
during scroll, still no stall). What it cannot do from source alone is name the exact
kernel/DWM lock. **The fix does not depend on which:** eliminating the per-frame
PrintWindow during moves removes both the wasted render and whatever it serializes.

So the full verified picture per drag frame:
1. Window moves → DDA dirty covers its extent (~552 k px).
2. Frame loop marks the window dirty → capture thread runs a ~15-18 ms PrintWindow
   (PrintWindow p50 ~18 ms on this WARP guest was measured earlier,
   DESIGN-per-window-capture.md §3 hazard 2) → row-diff empty → nothing sent. Waste.
3. Frame thread meanwhile interrogates the window ~2x (two tracking passes per frame:
   the event-signal `ProcessWindowEvents` pass plus the in-frame `TrackWindows` pass —
   see §1.4), each stalling ~8 ms concurrent with that render → `upd` p50 17 ms.
4. `wak` 5.5 ms: frames wait while the main thread is stuck in tracking.

### 1.4 INTERROGATED/frame ≈ 2 (vs 1.03 baseline) — what the second interrogation is

**VERIFIED.** It is the **same** window interrogated in two tracking passes per frame,
not a second window (`win=1` throughout the drag records). `QueueWindowEvent` dedups
per-hwnd within a batch (`main.c:241-254`), but a batch is drained by each pass: the
main loop runs `ProcessWindowEvents` on the event signal (case 6, `main.c:3497-3504`)
*and* `TrackWindows` at the top of every `ProcessNewFrame` (`main.c:2860`). At 60 Hz
input and ~24-31 fps, ~2 events/frame arrive and get applied across ~2 passes →
`wev≈2`, `iwn≈2` (both folded into the frame record). Records with `iwn=4-6` are
frames preceded by more event-signal wakeups. Harmless once the per-interrogation
stall is gone (2 × ~0.34 ms).

### 1.5 The 200 ms SynthLastFullPatch tick — did it contribute?

**VERIFIED: no, not in this bench.** The tick (`main.c:2963-2971`) runs only for
owners with `SynthChildCount > 0`; the harness drags a bare Notepad (`win=1`, no synth
children — a drag closes menus), and the tick lives in the damage phase anyway
(`dmg` p50 107 µs, so nothing hid there). But the synthesis path holds a real adjacent
trap for drags (§3.3).

## 2. Protocol/daemon verification for a move-only fast path

**Does the daemon need damage after MSG_CONFIGURE? — No. VERIFIED** in the vendored
daemon (`upstream/ro/qubes-gui-daemon/gui-daemon/xside.c`, byte-identical R4.3 per
DESIGN doc §2):
- `MSG_CONFIGURE` → `handle_configure_from_vm` (xside.c:2072-2155) →
  `moveresize_vm_window` → `XMoveResizeWindow` (xside.c:1832). The X server moves the
  dom0 window; content moves with it.
- Any region X needs repainted (window newly exposed, compositor redraw) arrives as an
  `XExposeEvent` → `process_xevent_expose` (xside.c:2477-2484) → `do_shm_update` from
  the daemon's **stored per-window image** — no agent involvement.
- With a per-window buffer set, `do_shm_update` composites window-relative from the
  window's own image (DESIGN doc §2, xside.c:2277-2290) — the buffer's meaning is
  independent of guest window position.

**What needs repainting on a move? Nothing, from the guest. VERIFIED:**
- The moved window's own buffer: position-invariant, already correct.
- Revealed regions: belong to other windows' buffers, which are **always complete**
  regardless of occlusion — `PrintWindow(PW_RENDERFULLCONTENT)` captures occluded
  content byte-exact (Gate 0, DESIGN doc §3), and the daemon repaints exposures itself
  (above). In the guest, the reveal's dirty rects do hit the underlying window's rect
  and trigger a (wasteful, empty-diff) recapture of it — harmless for correctness,
  see §4 residuals.
- Occlusion invariants unchanged: the frame loop's `rgnCovered` claims only
  override-redirect areas (`main.c:2976-2977, 3126-3127`); attached windows never
  receive screen-slice damage at all (their branch `continue`s at `main.c:2978`).

**What did the old screen-slice path send during drags? VERIFIED:** MSG_CONFIGURE at
event rate plus per-frame `MSG_SHMIMAGE` damage covering the window's extent — required
there because the window's pixels sat at a new position inside the shared *screen*
buffer each frame (the still-present legacy branch, `main.c:2987-3107`, incl. the
wobble-fix origin re-read at 3002-3037). Per-window buffers remove that requirement
entirely; the 0.917 ms baseline was the cost of sending rects, not pixels.

**DWM during drags. INFERRED (architecture + measured corroboration):** DWM moves a
dragged window by retransforming its composition visual; the app's redirection surface
— what PrintWindow renders — is not re-rendered by the move itself. Corroborated by the
acceptance run's position-independence figure (FINDINGS:219). Shadows are DWM-drawn
(no HWND); snap previews / Office shadow strips are separate HWNDs already handled by
the acceptance rules (`main.c:1966-2004`) and unaffected here.

## 3. Chosen design: move-only capture suppression (+ settle recapture + throttle)

### 3.1 Core change (main.c, PwIsAttached non-slice-fed branch)

On a frame where an attached PrintWindow-fed window's position changed since the last
processed frame ("move-only" — a same-frame resize has already rebuilt the channel via
`PwResizeWindow`, and a fresh channel starts `dirty=true` with a synchronous prefill,
so skipping the trigger is harmless there):

- **skip `WcMarkDirty`** — no PrintWindow, no diff, no stall; dom0 keeps compositing
  the unchanged buffer at the new position from `MSG_CONFIGURE` (already flowing at
  input rate via `ProcessWindowEvents`, unchanged);
- **arm a settle recapture** (`PwSettleDue`): the first subsequent frame where the
  position did NOT change marks the window dirty unconditionally (not gated on dirty
  rects — the final repaint may not produce another intersecting frame);
- **throttled mid-motion refresh**: at most one `WcMarkDirty` per
  `PW_MOVE_RECAPTURE_MS` (150 ms) while moving, so content that genuinely changes
  during a drag (video, progress bars) stays ≤150 ms stale;
- the engine's 250 ms round-robin sweep (`wincapture.cpp:38, 209-223`) is untouched
  and independently bounds staleness even if no settle frame ever arrives
  (≤250 ms x live-channel count).

The slice-fed branch (`PwSliceFed`) is deliberately untouched: those buffers are fed
from the composited screen, which IS position-dependent — `PwSliceNeedsFull` on move
(`main.c:2198-2201`) is required for correctness there.

The synth-child patching inside the same branch (`main.c:2954-2972`) is also left
running during moves: it is a small screen-to-buffer memcpy against coordinates
`TrackWindows` just refreshed, and skipping it would let a moving owner carry a stale
composited popup.

### 3.2 Why this beats the alternatives considered

- *Capture only after move settles, configure-only in between* — that is exactly this
  design; the throttle is added because "settle-only" freezes animating content for
  the whole drag duration.
- *Pure recapture throttling without move detection* (e.g. adaptive backoff on empty
  diffs in the engine) — self-tuning and also covers the revealed-window waste, but it
  throttles by observed emptiness, so it delays *legitimate* first damage after quiet
  periods and is much harder to reason about against the ACK/mask machinery. Viable
  follow-up, not the first fix.
- *Detect drags via EVENT_SYSTEM_MOVESIZESTART/END* — cheaper detection but misses
  programmatic moves (which have the same cost signature) and adds hook surface;
  position-compare in the frame loop catches every mover uniformly.

### 3.3 Companion fix: SynthUpdateMask no-op guard

`SynthUpdateMask` (`main.c:1087-1107`) is called on **every** interrogation of an
owner with synth children (`main.c:2298-2299`) and on every child geometry change
(`main.c:2078-2081`) — i.e. at input rate while such an owner is dragged. Each call
hits `WcSetMask` (`wincapture.cpp:339-356`), which (a) takes the engine lock
**exclusively**, stalling the tracking thread behind any in-flight 15-18 ms
`CaptureAndDiff` (the capture thread holds the lock shared across the whole channel
loop, `wincapture.cpp:204-249`), and (b) sets `dirty=true`, forcing yet another full
PrintWindow. Mask rects are owner-relative (`main.c:1097-1098`), so a joint
owner+child move computes an **identical** mask — the push is a pure loss. Fix:
memoize the last pushed mask per owner and skip identical pushes; invalidate on
channel rebuild (attach/detach). This is the concrete edge of the documented
"synthesis flap during drags" open item and prevents the §1 mechanism from recurring
via the synthesis path once a menu is open over a dragged window.

## 4. Expected residual cost

- Drag frame cost: tracking ~2 x ~0.34 ms (unstalled interrogations) + damage loop
  ~0.1 ms + sends ~µs → **`tot` p50 ≈ 0.6-1.2 ms** (bar < 5 ms; old baseline
  0.917 ms). Prediction for verification: if p50 only halves instead, the §1.3
  inference was wrong — then instrument `GetWindowData` sub-phases before iterating.
- Capture thread during drag: idle except sweep (≤4 captures/s) + throttle
  (≤6.7 captures/s worst case) → occasional frames may still show an 8-17 ms `upd`
  stall when an interrogation coincides with one of those captures (~10-25% of frames
  at worst) → p95 improves less than p50. Acceptable against the p50 bar; if p95
  matters, gate the sweep off for a channel whose window moved within the last
  ~300 ms (needs one small engine API addition — noted, not included).
- Revealed-window waste (drag over another attached window): the underlying window
  still gets per-frame empty-diff recaptures (its own position is unchanged, so the
  move-skip does not apply). Off-main-thread, no protocol traffic, but it keeps the
  engine busy → same coincidence stalls as above when a third window's interrogation
  overlaps. Follow-up candidates: empty-diff backoff in the engine, or attributing
  mover-extent dirty rects. Not in this patch (attribution errors would trade a perf
  wart for a correctness bug).
- Resize-drag (edge drag) is NOT fixed and was not the measured defect: every size
  change still costs detach + grant + `WcPrefill` (a synchronous `CaptureAndDiff` on
  the frame thread, `perwindow.c:316`, inside `upd`) + full re-dump. Separate item.

## 5. Wobble / synthesis interaction analysis

- **Wobble cannot come back via this patch.** Wobble was screen-slice damage
  registered against a stale origin while the window's pixels moved inside the shared
  *screen* buffer (WOBBLE-STATUS.md; the invariant comments at `main.c:2981-3037`).
  On the PrintWindow path this patch sends **no damage at all** during motion, and the
  damage it does send (settle/throttle/sweep) is window-relative against a
  position-invariant buffer — there is no origin to go stale. The two paths that ARE
  position-dependent (slice-fed full-recopy on move; legacy screen-slice with its
  origin re-read) are untouched. Acceptance already measured per-window content as
  position-independent (FINDINGS:219).
- **Synthesis:** children are patched from the live screen against
  freshly-tracked coordinates during moves (unchanged behavior); the 200 ms full tick
  still bounds mid-draw smears; the mask memo (§3.3) removes the drag-time
  exclusive-lock stalls and forced recaptures without ever changing WHAT is masked —
  a genuinely different mask (child appeared/moved-relative/resized, materialization,
  channel rebuild) still pushes immediately. Synthesized children produce no protocol
  traffic and no dom0 windows, so no daemon-side interaction changes
  (`main.c:2043-2084`).
- **check-occlusion invariants hold:** no damage is ever sent for occluded content
  (nothing new is sent at all on moves); revealed windows need no damage (complete
  buffers + daemon expose repaint, §2); `rgnCovered` claiming rules untouched.

## 6. Risks (explicit)

1. **Stall-mechanism inference** (§1.3): if wrong, the fix under-delivers — detection
   is built into the verification prediction (§4). The wasted-render elimination is
   correct regardless.
2. **Content staleness during motion**: bounded by 150 ms throttle / 250 ms sweep;
   title-bar drags (the defect scenario) have static content and see none. The old
   screen-slice path had zero staleness during drags; this is the trade.
3. **Settle frame may never arrive** if the desktop goes fully static the instant the
   drag ends mid-motion-frame: covered by the sweep (≤250 ms x channels); the settle
   flag also persists and fires on the next processed frame whenever one comes.
4. **GetTickCount granularity** (~15.6 ms) is fine for 150/250 ms thresholds.
5. **Field lifetime**: new fields live in `WINDOW_DATA` under `g_csWatchedWindows`
   (frame loop and perwindow.c call sites all hold it — attach/detach are called from
   `UpdateWindowData`/`AddWindow`/`RemoveWindow`); no new locking.
6. **Mask memo correctness**: memo must be invalidated when the engine channel is
   rebuilt (fresh channel has an empty mask) — done in attach/detach; `C_ASSERT`
   pins the memo capacity to `WC_MAX_MASK`.
7. Patch is drafted against 382fa05 and **not built or tested** — it needs the usual
   CI build + the same bench harness (`tools/bench-agent.sh`) A/B before any deploy,
   plus the ACCEPTANCE-PROTOCOL drag/overlap/menu scenarios (especially
   OVERLAP-IN-MOTION and the menu-over-drag case for §3.3).

## 7. Verification plan (when a build is allowed)

1. Same harness, same analyzer: expect drag `tot` p50 ≤ ~1.5 ms, `upd` p50 ≤ ~1 ms,
   `iwn` unchanged (~2), move-rects still 0, scroll/type/idle within noise of current
   (they must not regress — they bypass the new branch except for the two extra
   integer compares).
2. `qtest shot` + dom0 fullshot during drag: window content intact at final position;
   drag over a second window leaves no debris (revealed content correct).
3. Menu-open-then-drag (synthesis): child stays composited, no flicker
   (mask memo), owner content correct after settle.
4. Negative control for staleness: drag a window with a running timer/animation;
   content updates visibly ≥4 Hz during the drag and snaps correct on release.
