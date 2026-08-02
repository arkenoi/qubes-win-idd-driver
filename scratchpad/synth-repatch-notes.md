# Synthesized-popup re-patch timer (branch `synth-repatch-timer`)

Date: 2026-08-02. Branch based on `b299011`. Agent fork, `gui-agent/main.c` only.
Not built (no toolchain in this qube) — needs a CI build before deployment.

## Defect (as reported by the user)

A mouseover / dropdown menu in a Windows guest renders as a **blank rectangle** in dom0.
It only fills in when the mouse is moved slightly **down into** the menu — i.e. when the
menu itself repaints (hover highlight) and thereby produces real screen damage. Keyboard
navigation does not fix it either; only actual damage does.

## Root cause (verified in source on this branch)

- Menus/tooltips are *synthesized*: tracked locally, never announced to dom0, and their
  pixels are copied into the **owner's** granted per-window buffer by
  `PwPatchSynthChildren` (`gui-agent/main.c:2872` on the base commit).
- Three copy triggers existed, all of them frame-driven except the first:
  1. one-shot copy at `SynthActivate` (`main.c:1163`, `PwPatchSynthRect` at 1171);
  2. dirty-rect-driven patch inside `ProcessNewFrame` (`main.c:~3105`);
  3. "periodic" full re-copy every `SYNTH_FULL_PATCH_MS` (200 ms), also inside
     `ProcessNewFrame` (`main.c:~3112`), which exists *precisely* to heal a child that
     was captured mid-draw.
- `ProcessNewFrame` is only ever called when a DDA frame arrives
  (`WatchForEvents`, `main.c:3516` on the base commit, `case 1:` of the wait). On a
  static screen `AcquireNextFrame` yields nothing, the capture thread never signals
  `frame_event`, and trigger (3) **never fires**. It is a frame-arrival hook wearing a
  timer's clothes.
- So the sequence is: menu appears -> `SynthActivate` copies it, frequently *before* the
  popup has painted (the window is tracked from its CREATE/SHOW event, which can beat the
  popup's first paint) -> screen goes quiet -> no frame -> no heal pass -> blank rectangle
  until the user generates damage by hovering an entry. Exactly the reported symptom.
- The fix is viable because `ProcessNewFrame` already publishes the live desktop image in
  `g_FbBits` / `g_FbPitch` explicitly "for paths outside this loop (synthesis)", and
  `PwPatchSynthChildren` depends only on those globals plus `g_WatchedWindowsList`.

## What changed

All in `gui-agent/main.c`.

1. **`g_SynthActiveChildren`** (new static UINT, next to `g_FbBits`): count of windows
   currently synthesized into an owner. Updated at *all three* sites that write
   `WINDOW_DATA.Synthesized` — verified by
   `grep -rn "Synthesized *=" --include=*.c --include=*.h`, which returns exactly three
   hits and nothing else in the tree:
   - `SynthActivate` (+1),
   - `SynthDeactivate` (-1) — this is what materialization, the "no longer
     owner-contained" path (`UpdateWindowData`), and the `!CreateSent` branch of
     `RemoveWindow` all funnel through,
   - the owner-death loop in `RemoveWindow` that orphans children directly (-1 each).
   Every window removal goes through `RemoveWindow` (verified: the only `free(entry)` /
   `RemoveEntryList` on the watched list is there), so there is no fourth path that can
   leak a count. Decrements are `if (n > 0) n--` so a hypothetical desync cannot wrap.
   Single-threaded by construction: all mutation sites run on the main thread with
   `g_csWatchedWindows` held (the hook thread only queues events).

2. **`SynthNextPatchTimeout()`** (new): returns the wait the main loop should use.
   `INFINITE` when `g_SynthActiveChildren == 0`; otherwise the smallest remaining time
   until an owner's next full re-copy is due. All arithmetic is unsigned/modular, so it
   is correct across the `GetTickCount()` 49-day wrap and for the back-dated stamp below.

3. **`SynthPeriodicPatch(capture)`** (new): the timeout handler. For each watched window
   with `SynthChildCount > 0` whose `SynthLastFullPatch` is at least
   `SYNTH_FULL_PATCH_MS` old, stamp it and call `PwPatchSynthChildren(entry, NULL)` —
   the identical full re-copy the in-frame path does.

4. **`WatchForEvents`**: `WaitForMultipleObjects(..., INFINITE)` becomes
   `WaitForMultipleObjects(..., SynthNextPatchTimeout())`, and a `WAIT_TIMEOUT` branch is
   added **before** the existing `if (signaledEvent >= MAXIMUM_WAIT_OBJECTS)` error check
   — `WAIT_TIMEOUT` is 0x102, so without that ordering the timeout would have been
   misread as a wait failure and broken the main loop.

5. **`SynthActivate`** back-dates `SynthLastFullPatch` by
   `SYNTH_FULL_PATCH_MS - SYNTH_FIRST_PATCH_MS` (new `#define SYNTH_FIRST_PATCH_MS 50`),
   so the first re-copy after a popup is synthesized is due 50 ms later instead of 200 ms.

6. **`StopFrameProcessing`** clears `g_FbBits`/`g_FbPitch`. The desktop surface belongs to
   the duplication being torn down; this stops any out-of-frame consumer from sampling a
   dead mapping. (This also closes the same latent hazard for the pre-existing
   `SynthActivate` immediate paint.)

The existing in-frame paths are **unchanged** — this is an additional trigger only.

## Early-retry decision (the question that was asked)

**Chosen: yes, retry early — via a back-dated stamp, not a separate mechanism.**

Rationale:
- The failure mode is real and is half of the reported defect: `SynthActivate` copies the
  popup the moment we learn about it, which can be before it painted. Waiting a full
  200 ms to correct that is a visible flash of garbage/blank.
- Back-dating the *existing* stamp is the cheapest possible implementation: no new field
  in `WINDOW_DATA`, no second timer, no new state machine, and **both** consumers (the
  in-frame periodic path and the new timeout path) honour it automatically because both
  compare the same stamp against the same threshold.
- Cost is bounded at one extra wakeup per popup shown. After that first retry the stamp
  is a normal `GetTickCount()` and the cadence settles at 200 ms.
- 50 ms is ~3 refreshes at 60 Hz — past a menu's first paint with margin, still fast
  enough to read as instant.

Rejected alternatives: a dedicated `SynthFirstPatchDue` field (more state for no extra
capability); doing the retry unconditionally on the next loop iteration (would be a
busy-ish poll and would still be frame-gated when frames flow); shortening
`SYNTH_FULL_PATCH_MS` globally (raises steady-state cost for every open popup).

## Idle cost

**Zero extra wakeups when nothing is synthesized.** `SynthNextPatchTimeout()` returns
`INFINITE` after a single integer test on `g_SynthActiveChildren`, so the main loop's wait
is byte-for-byte the previous behaviour on an idle guest with no menu open. This is
deliberate — the project has just finished fixing an idle-CPU churn bug and a gratuitous
periodic timer would regress it.

While a popup *is* open the loop wakes at most once per `SYNTH_FULL_PATCH_MS` per owner
(<= 5/s), each wakeup being a short walk of the watched-window list plus one full re-copy
of that owner's children (menu-sized memcpy, tens of microseconds). The wakeups stop the
moment the popup closes, because closing it runs `SynthDeactivate` and the count returns
to 0.

## Locking

- The new path takes **only** `g_csWatchedWindows`, the same lock the in-frame path enters
  at `ProcessNewFrame` — no new lock relationship is introduced, therefore no inversion is
  possible.
- Checked what the copy actually touches: `PwPatchSynthChildren` ->
  `PwPatchSynthChildClipped` does `memcpy` from `g_FbBits` into `owner->PwBuffer` and
  calls `SendWindowDamageEvent` (vchan CS). It does **not** call `WcSetMask` or
  `WcMarkDirty` — the WGC capture-engine-lock takers — so the capture engine lock is not
  on this path at all. Lock order is the established watched-windows -> vchan one.
- The handler runs only on `WAIT_TIMEOUT`, i.e. with no frame in flight and no other lock
  held.
- **No busy-wait anywhere.** The critical detail: every due owner's stamp is refreshed
  *unconditionally*, including when the source framebuffer is unavailable and the copy is
  skipped. Otherwise the deadline would stay permanently expired, `WaitForMultipleObjects`
  would return `WAIT_TIMEOUT` immediately, and the loop would spin at 100% CPU for the
  duration of a duplication recovery (up to ~5 s of retries in `RecreateDuplication`).

## Verification from outside (no code access needed)

1. Open a window whose menus get synthesized (e.g. Notepad) in the Windows guest and let
   the screen go completely static — no cursor motion, no blinking caret over the region,
   nothing.
2. Open a dropdown/mouseover menu **with the keyboard** (Alt+F), or click it and then do
   not move the mouse at all.
3. Expected after the fix: the menu is fully rendered in dom0 within ~50 ms (first retry),
   at worst `SYNTH_FULL_PATCH_MS` = 200 ms, **with no further input of any kind**.
   Before the fix it stays a blank/partial rectangle indefinitely until the pointer is
   moved into it.
4. `qtest shot` a second or two after opening the menu, without touching the VM in
   between, is the objective form of the check: the menu contents must be in the PNG.
5. Idle regression check: with no menu open, the agent's CPU time must be unchanged from
   the previous build (compare over a few minutes of an untouched desktop). Any measurable
   idle increase means `g_SynthActiveChildren` is not returning to 0 — i.e. a missed
   decrement.
6. Log evidence: `QGAPROTO,msg=SYNTHPAINT,...` lines for the popup's owner must appear
   while nothing on screen is changing (previously these only ever appeared alongside
   frame activity).

## Risks / open items

- **Not compiled.** No Windows toolchain here. C syntax was re-read hunk by hunk and brace
  and paren balance verified against the base file, but the first CI build is the real
  check. Watch for `/W4 /WX` (this project sets `TreatWarningAsError` for gui-agent):
  signed/unsigned comparisons were cast explicitly for that reason, and no second
  `C_ASSERT` was added to `main.c` (a benign typedef redefinition could trip `/WX`).
- **Residual framebuffer race** (pre-existing, narrowed not eliminated): the capture
  thread can call `RecreateDuplication` — which releases the duplication and with it the
  mapped desktop surface — while the main thread is inside the copy. `SynthPeriodicPatch`
  guards by requiring `g_FbBits == capture->framebuffer`, and `RecreateDuplication` NULLs
  `ctx->framebuffer` under `frame.lock` *before* dropping the duplication, so the whole
  multi-second recovery window is covered. What remains is the instant between passing
  that check and the memcpy. The same exposure already exists for `SynthActivate`'s
  out-of-frame paint. Closing it fully would mean holding `capture->frame.lock` across the
  copy — deliberately not done here: `frame.lock` is currently a leaf lock private to
  `capture.c`, and nesting it under `g_csWatchedWindows` (and over the vchan CS, via
  `SendWindowDamageEvent`) is a new lock relationship that deserves its own change and its
  own review.
- **Timer starvation while frames flow**: if events/frames arrive faster than the deadline,
  `WaitForMultipleObjects` never returns `WAIT_TIMEOUT` and the timeout path never runs.
  That is fine and intentional — in that regime the in-frame periodic path is running and
  doing exactly the same work.
- **Back-dating affects the in-frame path too** (by design, called out above): the first
  in-frame full re-copy after a popup appears now happens at ~50 ms instead of ~200 ms.
  One extra full child copy per popup; no other behaviour change.
- **Extra list walk per loop iteration while a popup is open**: `SynthNextPatchTimeout`
  walks the watched-window list (a few dozen entries) and takes/releases
  `g_csWatchedWindows` on every iteration of the main loop while `g_SynthActiveChildren >
  0`. During a menu-over-drag that is once per frame/input event. Measured cost was not
  taken; if it shows up in QGAPERF, cache the deadline instead of recomputing it.
- **Counter discipline is the fragile part**: any future code that clears
  `WINDOW_DATA.Synthesized` directly, without going through `SynthDeactivate`, must
  decrement `g_SynthActiveChildren`. A missed decrement = permanent 5 Hz wakeups (idle
  regression); a missed increment = the blank-menu bug returns for that case.
