# Hybrid pixel source for per-window capture (design only — nothing implemented)

Date: 2026-08-03. Base: `agent/` at `b299011` (current shipping build). READ-ONLY session:
no VM contact, no build, no commit. Every claim below is tagged **VERIFIED** (I read it in
this tree, with file:line) or **INFERRED** (reasoning, API contract, or extrapolation from
someone else's measurement).

Measurements quoted from the task brief (agent CPU 182 us p50 / 31 ms frame; PrintWindow
16.3–32.5 ms at 3128 px, 24.8–65.7 ms at 2.6 Mpx; `upd` spikes to 58 ms on Word 3430x1379)
are taken as given and are **NOT** re-derived here — I re-verified only the *code* claims.

---

## 0. What the code actually does today (verified)

**The frame path.** `CaptureThread` (capture.c:718) calls `GetFrame(capture, FRAME_TIMEOUT)`
with `FRAME_TIMEOUT = 1000` (capture.c:34, 733) — **VERIFIED**: no cap, no sleep, no throttle
in the loop. It signals `frame_event` and blocks on `ready_event` until the main loop has run
`ProcessNewFrame` (capture.c:781-795, main.c:3516, 3528). So **the DDA frame is held for the
entire duration of `ProcessNewFrame`** — `AcquireNextFrame` … `ReleaseFrame` brackets it.
**VERIFIED.** This is load-bearing for §4.

**The desktop image the agent holds.** `MapDesktopSurface` + `XcGnttabPermitForeignAccess2`
run exactly once, on the first frame, gated on `!ctx->grant_refs` (capture.c:511-552).
`ReleaseFrame` then *unmaps* it (capture.c:684-693) while the grant and the pointer stay in
use forever after. **VERIFIED.** main.c:2739-2742 states the rule the tree relies on: the
address is constant for the life of the duplication, the daemon reads it live, and callers
must **not** gate on `frame->mapped` (TRUE only on the very first frame). Reading a surface
after `UnMapDesktopSurface` is outside the DXGI contract; it works because
`DesktopImageInSystemMemory` is TRUE and the agent hard-fails otherwise (capture.c:317-323).
**INFERRED** (why it works) / **VERIFIED** (that the tree depends on it).

**Publication.** `ProcessNewFrame` publishes `g_FbBits` / `g_FbPitch` (main.c:78-79, 2854-2858).
These are the *only* writes to those globals — **VERIFIED** by grep.

**Two consumers of the composited image already exist, and both are precedents for this design:**

1. **Slice-fed windows** — `PwSliceCopyAndDamage` (main.c:2736-2776). A window that
   `PwWindowEligible` rejects (override-redirect, `WS_EX_NOREDIRECTIONBITMAP`, ULW/colorkey
   layered — perwindow.c:205-238) still gets its own granted buffer, but the frame loop copies
   its pixels **out of the composited DDA image** and sends window-relative damage
   (perwindow.c:259, 289-318 skips `WcAddWindow` entirely for these; main.c:3000-3018 drives
   them). Sourcing: `fb + r.top*frame->rect.Pitch + r.left*4`, clipped to screen ∩ window ∩
   granted geometry; destination `relX = r.left - entry->X`, `relY = r.top - entry->Y`.
   **VERIFIED.** *This is exactly the mechanism this proposal wants, already shipping.*
2. **Synthesized children** — `PwPatchSynthChildClipped` (main.c:2784-2834) copies a menu's
   region from `g_FbBits` into the **owner's** PrintWindow-fed buffer, and `WcSetMask`
   (wincapture.cpp:339-356) stops the owner's capture from overwriting it (masked column
   segments, wincapture.cpp:136-179). **VERIFIED.** *So a buffer mixing DDA-sourced and
   PrintWindow-sourced pixels, from different moments, already ships and is accepted.*

**The per-window engine.** `CaptureAndDiff` (wincapture.cpp:96-193): fresh DIB,
`PrintWindow(hwnd, memdc, PW_RENDERFULLCONTENT)` over the **whole** window (line 130), then a
full-height row diff writing changed rows into the granted buffer, reporting one full-width
row band `(0, y0, width, y1-y0+1)` (line 256). No partial mode — **VERIFIED**, matching the
brief. The thread holds the engine SRW lock **shared** during the capture (204-249), sleeps
2 ms after work / 8 ms when idle (258), and round-robin-marks **one** channel dirty per 250 ms
(`SWEEP_INTERVAL_MS`, 38, 210-223).

**Occlusion: there is no general occlusion region today.** This corrects a premise in the task
brief. `rgnCovered` accumulates *only*:
- synthesized windows (main.c:2983-2987),
- attached windows **iff** `IsOverrideRedirect` (main.c:3119-3122),
- legacy windows **iff** `IsOverrideRedirect` (main.c:3271-3272).

and only when `g_ZOrderValid`. `CollectZOrder` (main.c:2623-2715) **skips `EnumWindows`
entirely and sets `g_ZOrderValid = FALSE` whenever no override-redirect popup is visible**
(2637-2662) — i.e. essentially always, including while you type. General z-order clipping was
tried and deliberately reverted: main.c:3256-3270 records the measured stale-band failure.
**VERIFIED.** Consequence: **the existing machinery cannot answer "is window W unoccluded?"
— it does not know, and on purpose. A new, separate computation is required (§1.2), and it
must never be fed back into `rgnCovered`.**

**Move-only suppression (d64bca6).** main.c:3047-3096 + main.h:127-142: while a PrintWindow-fed
window is moving (`PwSettleDue` armed, quiet < `PW_MOVE_SETTLE_MS` = 150 ms, main.c:2730), the
dirty-rect trigger is skipped and content refreshes at most every `PW_MOVE_RECAPTURE_MS` =
150 ms (2724), with one unconditional settle recapture when motion ends. Rationale in code: the
PrintWindow buffer is **position-invariant**, so a pure move changes nothing in it; slice-fed
windows are explicitly excluded because their content **is** position-dependent (3044-3046).
**VERIFIED.** This is the single most important constraint on the hybrid (§3.3).

**Where the typing latency comes from (INFERRED, but tightly).** Keypress → app paints → DWM
composes → DDA frame (0–31 ms) → `ProcessNewFrame` (182 us) → `WcMarkDirty` → capture thread
wakes (0–8 ms) → **full-window `PrintWindow` + full-buffer row diff** → damage. Fitting the two
measured points linearly (3128 px @ 17.3 ms p50, 2.606 Mpx @ 50.2 ms p50) gives ≈ 17 ms fixed +
12.6 ms/Mpx, so Word at 3430x1379 = 4.73 Mpx lands at **≈ 76 ms p50** per capture, plus a
~19 MB `memcmp`/`memcpy` pass (≈ 5–10 ms on a WARP guest). Since 76 ms > the 31 ms frame
interval, the capture thread is *continuously* behind during typing and the observed
keystroke→pixel delay is roughly *one in-flight capture + one queued* ≈ **100–150 ms**. That is
the user-visible symptom. The two-point fit is crude (**INFERRED**); the ordering conclusion —
PrintWindow dominates by two orders of magnitude over the agent's 182 us — is not.

---

## 1. The rule for choosing the source

### 1.1 Verdict: per-WINDOW, per-frame, binary. Not per-region.

Add a per-window mode `PwDdaMode` (BOOL, in `WINDOW_DATA`, accessed only under
`g_csWatchedWindows`). A window is eligible for DDA mode in a given frame iff **all** of:

| # | predicate | why | source |
|---|---|---|---|
| E1 | `PwIsAttached(entry) && !entry->PwSliceFed && !entry->Synthesized` | slice-fed is already DDA; synthesized has no buffer | main.c:3000, perwindow.c:244 |
| E2 | buffer geometry current: `entry->PwWidth == entry->Width && entry->PwHeight == entry->Height` | a dump claiming more pixels than granted pages makes gui-daemon `exit(1)` | perwindow.c:425-429 |
| E3 | not moving: `!(entry->PwSettleDue && now - entry->PwLastMoveTick < PW_MOVE_SETTLE_MS)` | DDA content is position-dependent; see §3.3 | main.c:3044-3046 |
| E4 | fully on screen: window rect ⊆ `{0,0,g_ScreenWidth,g_ScreenHeight}` | DDA has no pixels off-screen; an off-screen band would freeze | main.c:2746-2752 |
| E5 | `!(entry->ExStyle & WS_EX_LAYERED)` | composited image shows the *blended* result; PrintWindow shows unblended content — different pixels | perwindow.c:227-237 |
| E6 | **fully unoccluded** by any visible top-level window above it in the guest z-order (§1.2) | the composited desktop does not contain a covered window's pixels | DESIGN-per-window-capture.md §3 Gate 0 |
| E7 | E1–E6 have held for `PW_DDA_DWELL_MS` (proposal: 100 ms) continuously | entry hysteresis; see §2.3 | new |

Leaving DDA mode is **immediate** on the first frame any of E1–E6 fails — asymmetric on
purpose: entering late costs latency, leaving late costs wrong pixels.

In DDA mode, the window's per-frame work in `ProcessNewFrame` becomes exactly the slice-fed
branch (main.c:3007-3017): for each `frame->dirty_rects[i]` intersecting the window rect,
`PwSliceCopyAndDamage(entry, frame, framebuffer, &hit)`. Not a new code path — **the same
function**, already shipping, already proven against the daemon. The PrintWindow branch is
skipped, and the channel is suspended (§4.2) so the engine does not fight the frame thread for
the buffer.

### 1.2 The occlusion test

Nothing existing can answer this (see §0). New helper, computed **once per frame**, lazily
(only if ≥1 window passes E1–E5, i.e. skipped entirely when nothing is a candidate):

```
walk h = GetTopWindow(NULL); h; h = GetWindow(h, GW_HWNDNEXT)   // topmost-first
    stop when all candidates have been decided (h is below the lowest candidate's ZOrder-free
    position — in practice: stop after MAX_Z_WALK entries, or when every candidate has been
    resolved)
    skip h if !IsWindowVisible(h) or IsIconic(h) or h is the desktop/shell backstop
    r = GetWindowRect(h)
    for each still-undecided candidate C above which h sits: if IntersectRect(r, Crect) -> C is
        occluded, decided
```

Properties this must have, and why:

- **Conservative direction.** Any doubt ⇒ "occluded" ⇒ PrintWindow ⇒ today's behaviour. Walk
  overflow (`MAX_Z_WALK`, proposal 256), `GetWindowRect` failure, `GetTopWindow` failure ⇒ all
  candidates declared occluded. This mirrors the existing "failure must degrade to *do not
  clip*, never to *clip wrongly*" rule at main.c:2665-2680. **VERIFIED precedent.**
- **All top-level windows, not just watched ones.** `ShouldAcceptWindow` rejects plenty of
  windows that still paint on screen; an unwatched occluder is still an occluder. The existing
  `rgnCovered` walks only `g_WatchedWindowsList` — insufficient here.
- **No DWM-cloaked query.** `DwmGetWindowAttribute` is a cross-process call and the tree already
  treats it as expensive (main.c:3148-3150 pays it only for damaged windows). A cloaked window
  that is not `IsWindowVisible`-false will just be counted as an occluder — conservative, cheap,
  wrong only in the safe direction.
- **Cost.** `IsWindowVisible` + `GetWindowRect` are cheap kernel transitions; the walk is bounded
  at 256. **INFERRED** ≈ 0.2–0.5 ms/frame worst case, ≈ 1% of a 31 ms frame — an order of
  magnitude cheaper than the `EnumWindows`-per-frame that `CollectZOrder` removed (main.c:2634-
  2636 says that cost ≈ 4× the Phase 2A drag figure), because no per-window property
  interrogation happens. **This number is the second thing to measure (§6).**
- **It is a separate region/verdict from `rgnCovered` and must never be merged into it.** Feeding
  a general occlusion region into damage clipping is the exact thing main.c:3256-3270 records as
  measured-wrong. The occlusion verdict here selects a *pixel source*; it changes no damage
  clipping.

### 1.3 Why not per-region (mixing DDA and PrintWindow inside one buffer, by mask)

Tempting — the mask machinery exists — but it loses on three independent counts:

1. **`WcSetMask` takes the engine lock EXCLUSIVELY and forces `ch->dirty = true`**
   (wincapture.cpp:339-356). Exclusive acquisition stalls behind an in-flight PrintWindow (up
   to 65 ms), *while the caller holds `g_csWatchedWindows`*. An occlusion-derived mask changes
   every time the occluder moves — i.e. at input rate during a drag — so this would be a forced
   full recapture **per frame**. That is precisely the failure mode `SynthUpdateMask`'s memo and
   `SynthFlushMasks` were built to avoid (main.c:1104-1108, 1141-1147; scratchpad/
   drag-fix-v2-notes.md "Blocker 2", where option (a) was analysed and REJECTED with evidence).
   **VERIFIED.**
2. **`WC_MAX_MASK` is 8** (wincapture.h:60) and synthesized children already compete for those
   slots (`SynthOwnerQualifies`, main.c:1010). A visible-region-minus-occluders decomposition is
   not bounded by 8 rects.
3. **It makes the covered part staler, not fresher.** See §2.2 — the covered region has *no*
   change signal at all, so per-region mixing trades a self-consistent window for a window whose
   two halves diverge by up to a full sweep period.

Per-region mixing is therefore **explicitly out of scope**. The existing per-region mix (synth
children) stays exactly as it is; the hybrid never touches the mask, in either mode. That
keeps the mask/patch coordinate-space invariant true **by construction** (§3.2).

---

## 2. Correctness

### 2.1 The occluded case still gets PrintWindow — by construction

The rule is a gate on the *entry* to a new fast path. E6 is a necessary condition. If a window
is occluded at all — fully or partially — E6 fails, `PwDdaMode` is FALSE, and the code executes
the **unmodified** branch at main.c:3019-3118. The Gate 0 property
(`PrintWindow(PW_RENDERFULLCONTENT)` returns byte-exact content for a fully occluded window,
3/3, negative control held — DESIGN-per-window-capture.md §3) is untouched, because that path is
untouched. **This is the whole argument, and it is structural rather than empirical: no covered
pixel is ever sourced from the composited image.**

### 2.2 Partial occlusion: fall back entirely to PrintWindow. Not a mixed buffer.

The decisive asymmetry is **change detection, not pixel provenance**:

- For the **visible** part of a window, screen dirty rects are a *superset* of the window's own
  damage: for an opaque, fully on-screen, unoccluded window, any change to its pixels is a
  change to the composited desktop at that location, which DWM reports as dirty. **INFERRED**
  from composition semantics + DDA's documented conservative dirty rects.
- For the **covered** part there is **no signal whatsoever**. Dirty rects over that area describe
  the *occluder's* repaints. This is exactly why the 250 ms round-robin sweep exists
  (wincapture.cpp:13-15, 210-223) — **VERIFIED** by the comment and the code.

So a mixed buffer would have: visible half refreshed at up to 32 Hz, covered half refreshed only
by the sweep, whose period is 250 ms × (number of live channels) because the sweep marks **one**
channel per interval. With 6 attached windows that is **1.5 s of skew inside one window**. Today
a partially occluded window is captured whole by one PrintWindow whenever any dirty rect
intersects it — self-consistent, ≤ ~100 ms old. Mixing would make a *dragged-over* window worse,
which is the artifact class this whole per-window design exists to kill.

**Therefore: partial occlusion ⇒ full PrintWindow, unchanged.** No mixed buffer is introduced by
this design.

### 2.3 Different moments: tearing/ghosting risk, and what bounds it

Three distinct hazards; all are bounded, and two already exist in the shipping build.

**(a) Live-image tearing (pre-existing).** The agent reads the desktop image *live*, not a
snapshot (main.c:2739-2742). A copy can therefore straddle a DWM composition and produce a torn
row band. **Bound:** DWM reports the newer content as dirty in the frame that contains it, so the
next frame's dirty-rect copy repairs it — ≤ 1 frame period ≈ 31 ms. Already the exposure of
`PwSliceCopyAndDamage` and `PwPatchSynthChildClipped`. **INFERRED** (bound) / **VERIFIED** (the
exposure already exists).

**(b) Stale occluder pixels at the DDA→PrintWindow transition.** Window B is raised over A. If A
had been in DDA mode and we copied one more time before noticing, A's buffer would hold B's
pixels in the overlap, and dom0 (which may stack A on top) would show them. **Bound:** the
occlusion walk (§1.2) reads **live** window state, which is never *older* than the held DDA
frame, so an occluder present in the frame image is always also present in the walk. The
detection can only be *early*, never late. On the frame E6 first fails we perform **no copy** and
`WcMarkDirty` instead. Worst case is therefore not "occluder pixels get in" but "the newly
covered region is stale for one PrintWindow" (25–76 ms) — identical to today's behaviour after a
`WcSetMask`. **VERIFIED** ordering (the walk is live; the frame is held throughout
`ProcessNewFrame`, capture.c:781-795).

**(c) The reverse skew: occluder vanishes.** The walk being *newer* than the frame is dangerous
in one narrow case: occluder closed, walk says "unoccluded", but this frame's image still shows
it. E7's dwell (100 ms ≈ 3 frames) makes the window ineligible for DDA mode across exactly that
window of time, and the reveal repaint is itself reported dirty. **Bound:** ≤ dwell.

**(d) In-flight PrintWindow overwrite at the PrintWindow→DDA transition.** A capture already
running when we suspend the channel will finish and write *older* PrintWindow content over rows
we just filled from DDA. This is the same mechanism review-synth-v2.md:156-158 identified for
`WcSetMask` (an in-flight capture commits under the *old* mask and blanks a freshly patched
popup) — **an already-latent bug in the shipping build**. Fix, needed for this design and
curing that one as a side effect: a per-channel **generation counter**. `WcSuspend`/`WcSetMask`
bump `ch->gen`; `CaptureAndDiff` snapshots `gen` before `PrintWindow` and, before its
compare/copy phase, re-reads it — if it changed, it discards the DIB and writes nothing.
(review-synth-v2.md:262-264 proposes exactly this, as option (a), for the mask case.) Cost: one
atomic load per capture. Without it, the fallback is a backstop full-window DDA re-copy on the
2nd and 5th frame after entering DDA mode — cheaper to implement, weaker guarantee.

**(e) Sweep convergence in DDA mode.** DDA mode must not lose the sweep's "guest-occluded windows
converge anyway" property, and must survive the one real hole in the dirty-rect superset
argument: DDA *move rects*, which the agent retrieves for instrumentation only and never applies
(capture.c:554-588, 642-644; the in-code note says they seem always empty). If a scroll were ever
reported as a move rect rather than dirty rects, a DDA-mode window would miss it. **Mitigation:**
keep the sweep for DDA-mode windows but make the sweep action a **full-window DDA copy + row
diff** on the frame thread instead of a PrintWindow — same convergence guarantee, ~5–10 ms per
250 ms instead of ~76 ms. Only changed rows are sent, so a static window costs zero vchan
traffic, exactly as today.

### 2.4 Pixel-equality assumptions that MUST be tested (this is the design's main risk)

The design assumes the composited desktop and `PrintWindow(PW_RENDERFULLCONTENT)` produce the
*same* pixels for an eligible window. Known ways that can be false:

- **Alpha channel.** DDA delivers B8G8R8A8 with composed alpha; a GDI PrintWindow into a
  `BI_RGB` 32-bit DIB (wincapture.cpp:113-122) commonly leaves alpha at 0. If the two differ
  systematically in the A byte, `CaptureAndDiff`'s `memcmp` (line 163) declares **every row
  changed** at each mode switch → a full-window damage burst per transition. Not a correctness
  bug (the daemon composites RGB), but a cost bug. Mitigation if confirmed: force alpha to a
  constant on both write paths, or diff RGB-only.
- **Win11 rounded corners.** DWM rounds top-level windows; the composited corner pixels are a
  blend with what is behind. DDA-mode corners would show background instead of window content.
  Small (~8×8 px × 4), but it is a visible fringe and `win11-idd-test` is a live target.
  Mitigation: exclude a corner margin from DDA copies (leave the last PrintWindow content there),
  or accept.
- **The mouse pointer.** DXGI delivers the pointer separately and the desktop image normally
  excludes it — but on a GPU-less guest a driver-composited pointer is conceivable. Mitigating
  factor already in the tree: `HideCursors()` (util.c:190-233, called at main.c:3807) replaces
  all standard cursors with a blank one when `g_DisableCursor`, which defaults TRUE
  (main.c:3786-3790). **VERIFIED.** So even a baked-in pointer is invisible. Still worth
  confirming — a cursor trail burned into a typing window would be the ugliest possible failure.
- **DWM per-window effects** (Mica/acrylic title bars): DDA arguably shows the *more* correct
  result. Cosmetic difference at a mode switch, not an error.

All four are answered by the one experiment in §6.

---

## 3. Invariants this touches

### 3.1 Row-diff / damage generation
Two shapes of damage would now exist for the same window at different times:
- PrintWindow mode: full-width row bands, `(0, y0, width, h)` (wincapture.cpp:256).
- DDA mode: precise `dirty_rect ∩ window` rectangles in window-relative coords
  (main.c:2775).

Strictly less traffic and strictly tighter damage — but **anything that parses
`QGAPROTO,msg=DAMAGE` sees narrower rects**. `tools/check-occlusion.py` asserts, in its
`hidden` phase, that BASE *does* receive damage reaching past x=300; with precise rects that
depends on where the repaint actually landed. That checker is **already** documented invalid for
per-window-captured windows (instrumentation/qwtfixed-w10/win10-regression.md:153-175 —
"Adjudication 2 — NEW finding: check-occlusion.py is stale for per-window capture"). This design
does not make it more invalid, but it also must not be cited as passing.

The row-diff itself is untouched in PrintWindow mode. In DDA mode the dirty-rect-driven copy
performs **no** diff (like the shipping slice-fed path, main.c:2768-2775) — it copies and
reports. Only the sweep-driven full copy (§2.3e) diffs, so an idle window still costs no vchan
traffic.

### 3.2 Synthesis mask and patch — same coordinate space, guaranteed
Both sources already write in one coordinate space: buffer origin = `entry->X, entry->Y` = the
origin last announced in `MSG_CONFIGURE`. `PwSliceCopyAndDamage` uses `relX = r.left - entry->X`
(main.c:2755-2756); `PwPatchSynthChildClipped` uses the identical form (main.c:2809); the
PrintWindow channel's `cropX/cropY` is computed as `entry->X - wr.left` precisely to land the OS
window rect on that same origin (perwindow.c:291-304); `SynthUpdateMask` builds mask rects as
`c->X - owner->X`, clamped to `PwWidth/PwHeight` (main.c:1120-1127). **VERIFIED — all four agree.**

**The hybrid changes none of them, and never writes the mask.** In DDA mode the mask is simply
inert (the channel is suspended); on return to PrintWindow mode the mask is exactly what
`SynthUpdateMask` last pushed. This is deliberate: the prior rejected approach (drag-fix-v2-notes
"Blocker 2", option (a)) failed because it computed masks from mixed-state geometry; anything
that recomputes a mask from occlusion state repeats that mistake at higher frequency.

*One consequence to note in review:* in DDA mode a synthesized child's pixels arrive twice — via
`PwPatchSynthChildren` and via the plain dirty-rect copy, which now also covers the child's area.
Identical source, identical destination, so the result is the same pixels and one redundant
`SendWindowDamageEvent`. Cheap fix: in DDA mode skip `PwPatchSynthChildren` entirely (the
whole-window DDA copy subsumes it). Recommended.

### 3.3 d64bca6's move-only suppression — preserved, and it is what forces E3
d64bca6's justification is that the **PrintWindow buffer is position-invariant**
(main.h:127-131, main.c:3024-3046). A DDA-sourced buffer is **not**: its content is read at
`entry->X/Y`, so a stale position yields the wobble/misregistration the tree measured at
p95 = 22 px (main.c:3136-3143). The shipping code already encodes this asymmetry —
`PwSliceNeedsFull` is set on move for slice-fed windows (main.c:2256-2257) and the comment at
3044-3046 says slice-fed windows never reach the move-suppression branch. **VERIFIED.**

Hence E3: **a moving window is never in DDA mode.** During a drag the window falls back to the
current, measured, shipped behaviour (suppress + 150 ms throttled refresh + settle). No
interaction, no regression — and no loss, because nobody types while dragging. Concretely,
`PwFrameXYValid / PwLastMoveTick / PwSettleDue` keep their exact current semantics; `PwDdaMode`
reads them and never writes them.

### 3.4 The occlusion invariant / `tools/check-occlusion.py`
As above: already invalid for per-window-captured windows, and unchanged by this design — the
damage-clipping code (`rgnCovered`/`rgnVisible`/`rgnDamage`, main.c:3189-3252) is not modified,
and the new occlusion verdict is a *separate* value that never enters `rgnCovered`.

### 3.5 Grant / dump lifecycle
Unchanged. Same buffer, same grant, same `MSG_WINDOW_DUMP`. E2 keeps the copy inside the granted
geometry, which is the condition whose violation makes gui-daemon `exit(1)` (perwindow.c:425-429).
`PwSliceCopyAndDamage` already re-checks it at runtime (main.c:2761-2762). **VERIFIED.**

---

## 4. Locking and threading

### 4.1 State of play (verified)
| lock | protects | held by |
|---|---|---|
| `g_csWatchedWindows` (main.h:38) | `g_WatchedWindowsList`, every `WINDOW_DATA` field incl. all `Pw*`/`Synth*` | main/frame thread throughout `ProcessNewFrame` (main.c:2927, 3277); tracking paths |
| `ctx->frame.lock` (capture.c) | DDA frame/duplication/grant state | capture thread inside `GetFrame`/`ReleaseFrame`/`RecreateDuplication` |
| engine `SRWLOCK e.lock` (wincapture.cpp:63) | the channel vector and channel fields | **shared** by the capture thread for the whole capture (204-249), `WcMarkDirty` (378-386), `WcIsDead`, `WcPrefill`; **exclusive** by `WcAddWindow`/`WcRemoveWindow`/`WcSetMask` |
| vchan lock (inside `SendWindowDamageEvent`) | the vchan | everyone |

Existing order: `g_csWatchedWindows` → engine(shared) → (release) → vchan, on the frame thread;
engine(shared) → (release) → vchan on the capture thread. `PwOnDamage` deliberately touches **no**
window list (perwindow.c:54-56, 61) and the engine fires callbacks only after releasing its lock,
with the inversion spelled out in the code (wincapture.cpp:82-90, 251-253). **VERIFIED.**

### 4.2 What the design adds
- **`PwDdaMode`, the dwell timer, and the per-frame occlusion verdict**: plain `WINDOW_DATA`
  fields / frame-local state, read and written **only** under `g_csWatchedWindows`, only on the
  frame thread inside `ProcessNewFrame`. No new lock.
- **`void WcSuspend(HWND, BOOL)`**: sets `Channel::suspended` (`std::atomic<bool>`) and bumps
  `Channel::gen`. **It must take the engine lock SHARED, exactly like `WcMarkDirty`** — never
  exclusive. Verified reason: the capture thread holds the lock *shared* for the whole
  `PrintWindow` (wincapture.cpp:204-249), so a shared acquirer never blocks, while an exclusive
  one stalls for up to 65 ms *while the caller holds `g_csWatchedWindows`* — which is the
  documented `WcSetMask` hazard (main.h:169-171). This is a hard design constraint, not a
  preference.
- **Engine honours `suspended`**: skip in the dirty loop (wincapture.cpp:225-248) and in the
  round-robin sweep slot (210-223), so a suspended channel neither captures nor consumes a sweep
  turn.
- **Generation guard** in `CaptureAndDiff` (§2.3d): read `gen` at entry, re-check before the
  compare/copy phase, abandon on mismatch. Reads only channel-local atomics under the shared
  lock.

Resulting order is unchanged — `g_csWatchedWindows` → engine(shared) → vchan — so **no new
inversion**. Nothing new ever takes `g_csWatchedWindows` from the capture thread; nothing new
takes the engine lock exclusively from the frame thread.

### 4.3 Buffer ownership — the one genuinely new race, and how it is closed
Today, `PwBuffer` has exactly one writer per window: the capture thread for PrintWindow-fed
windows, the frame thread for slice-fed ones (which have no channel at all, perwindow.c:289-318).
The only overlap is the synth-mask carve-out, where the two write **disjoint** regions.

Under the hybrid a DDA-mode window has a channel *and* a frame-thread writer. The rule that keeps
it single-writer: **`PwDdaMode == TRUE` ⇒ channel suspended ⇒ the capture thread never touches
that buffer.** Both flags flip on the frame thread under `g_csWatchedWindows`, in this order:
- entering: `WcSuspend(TRUE)` (bumps gen, kills any in-flight commit) **then** `PwDdaMode = TRUE`
  **then** the first full-window DDA copy;
- leaving: `PwDdaMode = FALSE` **then** `WcSuspend(FALSE)` + `WcMarkDirty`.

### 4.4 `g_FbBits` and the RecreateDuplication dangling-pointer hazard
`RecreateDuplication` revokes the grant, frees `grant_refs` and sets `ctx->framebuffer = NULL`
(capture.c:244-252). `g_FbBits` is **not** cleared — it is written only at main.c:2856 — so
between a recreate and the next successful frame it dangles. **VERIFIED.**

- The hybrid's DDA reads happen **only inside `ProcessNewFrame`**, which runs only while the
  capture thread holds a live frame (capture.c:781-795) and which receives the framebuffer
  pointer as a **parameter**, not via `g_FbBits`. Note that `PwSliceCopyAndDamage` already takes
  `fb` as a parameter (main.c:2737) while `PwPatchSynthChildClipped` uses the global
  (main.c:2787). **The hybrid must use the parameter**, i.e. reuse `PwSliceCopyAndDamage`
  verbatim. Then it adds **zero** new exposure.
- The pre-existing exposure is `PwPatchSynthRect` called from `SynthActivate` (main.c:1171),
  which runs from `AddWindow` on the tracking path — reachable from `ProcessWindowEvents`,
  i.e. **outside** any held frame, reading `g_FbBits`. That is the real dangling read. It is
  **out of scope** for this design, but should be recorded as a separate bug: clear
  `g_FbBits`/`g_FbPitch` under `g_csWatchedWindows` when `capture->grants_changed` is observed
  (main.c:3478-3480), before any tracking can run again.
- After a recreate the frame loop already re-sends grants and forces a full repaint of every
  window (main.c:3478-3514) — **VERIFIED**; DDA mode needs nothing extra, but every window should
  additionally be kicked out of DDA mode there so the dwell re-qualifies it against fresh state.

---

## 5. Expected latency and CPU, per case

Against the measured baseline (31 ms frame interval; agent `tot` p50 182 us; PrintWindow p50
17.3 ms @ 3128 px, 50.2 ms @ 2.6 Mpx; ≈76 ms extrapolated @ Word's 4.73 Mpx).

| case | today | after | note |
|---|---|---|---|
| **Unoccluded foreground typing** (the reported bug) | DDA wait 0–31 ms + 182 us + 0–8 ms thread wake + **50–76 ms PrintWindow** + 5–10 ms full-buffer diff; capture thread saturated ⇒ effective ≈100–150 ms keystroke→pixel | DDA wait 0–31 ms + 182 us + **memcpy of the dirty area only** (3406 px p50 on Word with HW-accel off ⇒ ~14 KB ⇒ tens of us) + send | **~50–90 ms removed from the critical path**; the residual is the DDA frame interval itself, which the agent does not control (capture.c:733, no cap) |
| CPU, same case | ≈76 ms PrintWindow + ~19 MB diff **per 31 ms frame** ⇒ capture thread >100% of one core; plus the ~8 ms/interrogation tracking stalls behind PrintWindow that produced the 58 ms `upd` spikes | ~14 KB copy/frame + a 19 MB full copy+diff per 250 ms sweep (≈2–4% of one core) + the occlusion walk (~0.2–0.5 ms/frame, ~1%) | **the `upd` spikes disappear**: they are cross-process calls queueing behind `PrintWindow` in the target app |
| **Occluded window** | full PrintWindow on dirty-rect trigger + 250 ms sweep | **identical — byte-for-byte the same code path** | correctness preserved by construction (§2.1) |
| **Partially occluded** | full PrintWindow on trigger | **identical** | mixed buffers rejected (§2.2) |
| **Dragging** | d64bca6 suppression + 150 ms throttle | **identical** (E3 excludes moving windows) | |
| **Mode transition** | n/a | one full-window DDA copy + diff (~5–10 ms), ≥100 ms apart by E7 | plus a possible full-window damage burst if the alpha assumption fails (§2.4) |

Honest caveats: the 76 ms Word figure is a two-point linear extrapolation (**INFERRED**); the
100–150 ms end-to-end figure is a queueing argument, not a measurement (**INFERRED**); the
occlusion-walk cost is an estimate (**INFERRED**). The direction and the order of magnitude are
robust — PrintWindow is 2–3 orders of magnitude above everything else the agent does.

---

## 6. Risks, and the cheapest falsifying experiment

**Ranked risks**
1. **DDA pixels ≠ PrintWindow pixels** for an eligible window (alpha, Win11 rounded corners, a
   baked-in pointer, DWM effects). Would show as either a per-transition full-window damage
   burst (cost) or a visible fringe (cosmetic). *Kills or reshapes the design.* §2.4.
2. **Occlusion walk too expensive or wrong.** Too expensive ⇒ eats the win; wrong in the unsafe
   direction ⇒ covered pixels leak into a buffer. Mitigated by the conservative-on-doubt rule,
   but a `GetWindowRect`-only test ignores non-rectangular / cloaked / zero-alpha windows — all
   of which make it declare occlusion that is not there (safe) rather than miss one (unsafe).
   The one genuinely unsafe input would be a top-level window that is `IsWindowVisible` and
   rectangle-overlapping but *paints nothing* — then we needlessly use PrintWindow. Safe.
3. **Transition thrash.** A cursor-tracking tooltip crossing a window flips modes; each flip
   costs a full-window copy + possibly a full damage burst. E7's dwell plus an exit cooldown
   bound it; this is the same failure family as the 12 Hz work-area re-assert and the v1 synth
   timer, both of which this tree has already been burned by (FINDINGS.md:1009, review-synth-v2
   §"BLOCKER 1").
4. **In-flight capture overwrite** at PrintWindow→DDA (§2.3d) — needs the generation counter, or
   a re-copy backstop.
5. **Move rects** (capture.c:642) — the one hole in "dirty rects are a superset"; covered by
   keeping the sweep in DDA mode (§2.3e).
6. **Scope creep into per-region mixing.** §1.3 says no; reviewers should hold that line.

**The cheapest experiment that falsifies the design before anyone writes it** — no agent change,
no agent build, no daemon involvement:

> Extend `tools/pwprobe` (which already does the PrintWindow half — DESIGN-per-window-capture.md
> §3 Gate 0) with the DDA half already present in `tools/ddaprobe`, into a single guest-side
> console tool that, for a given HWND:
> 1. asserts the window is fully unoccluded and fully on screen;
> 2. grabs `PrintWindow(PW_RENDERFULLCONTENT)` into a DIB and, from the same instant, the
>    corresponding rect out of the DDA desktop image (`DesktopImageInSystemMemory`, cropped by
>    `entry->X/Y` exactly as `PwSliceCopyAndDamage` does);
> 3. reports: % pixels differing on RGB, % differing on RGBA, the bounding boxes of the
>    differing regions, and the per-corner difference;
> 4. repeats ~100 times while text is typed into the window (reuse the existing
>    `SendKeys`-with-asserted-focus harness — FINDINGS.md 2026-08-02 records that a run without
>    asserted focus is vacuous).
>
> Run it on **both** `win-idd-test` (Win10) and `win11-idd-test` (rounded corners), on a large
> window (Word/Notepad maximized) and a small one.

Decision rule:
- **RGB mismatch ≈ 0 outside corners** ⇒ the design's core premise holds; proceed, and treat
  alpha and corners as the two implementation details §2.4 lists.
- **RGB mismatch non-trivial in the window interior** ⇒ the design is dead as written; the
  composited image is not a substitute for PrintWindow even unoccluded, and the remaining
  latency options are damage-scoped diffing (FINDINGS.md 2026-08-02, opportunity 1) or moving
  PrintWindow off the critical path some other way.

Second, much cheaper sanity check to run first (5 minutes, no new code): time the occlusion walk
of §1.2 as a standalone PowerShell/console loop on the live guest desktop. If it costs > ~1 ms
per pass with a realistic window population, the per-frame verdict must be memoised against
`EVENT_SYSTEM_FOREGROUND` / `EVENT_OBJECT_LOCATIONCHANGE` instead of recomputed, which is a
design change worth knowing about before implementation rather than after.
