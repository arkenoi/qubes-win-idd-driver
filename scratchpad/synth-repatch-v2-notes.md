# Synthesized-popup heal, v2 (branch `synth-repatch-timer-v2`, commit `519e0cb`)

Date: 2026-08-02. Based on `b299011`. Files: `gui-agent/main.c`, `gui-agent/main.h`,
`gui-agent/capture.c`. Not built (no Windows toolchain in this qube) — CI is the real check.

Supersedes v1 (`18409bd`, branch `synth-repatch-timer`), which two independent adversarial
reviews returned as NEEDS_WORK. Same defect, same shape of fix (give the main loop's wait a
deadline), different cost model and a corrected safety argument.

## Defect (unchanged from v1)

A dropdown/mouseover menu renders as a **blank rectangle** in dom0 and only fills in when the
cursor moves into it. Two causes, both needed:

1. Menus are *synthesized* — never announced to dom0; their pixels are copied into the
   **owner's** granted buffer. The copy that exists to cure a child captured **mid-draw** is
   the "periodic" full re-copy inside `ProcessNewFrame`, and `ProcessNewFrame` runs only on
   DDA frame arrival (`WatchForEvents`, `case 1`). On a static screen `AcquireNextFrame`
   yields nothing, `frame_event` is never signalled, and that pass **never runs**.
2. `SynthActivate`'s one-shot copy can beat the popup's own first paint (the window is tracked
   from its CREATE/SHOW event), so the copy is of an unpainted window — and then nothing
   corrects it.

## Blocker-by-blocker disposition

### BLOCKER 1 — unbounded idle churn. FIXED by making the heal a bounded burst.

v1 armed the timer on "any child is currently synthesized" (`g_SynthActiveChildren`), which
counts every synthesized window, not just menus. Long-lived synthesized children exist — this
repo's own evidence, `instrumentation/e2e-b299011/win10-regression.md:292-297`, records an
owned caption-less WinForms child synthesized for the whole life of the app. With one on
screen, `SynthNextPatchTimeout()` never returned `INFINITE`, so a completely static desktop
woke **5×/s forever**, each pass doing a full memcpy per child, a `SendWindowDamageEvent` →
`MSG_SHMIMAGE` (waking dom0's gui-daemon for a no-op repaint) and a `LogInfo` SYNTHPAINT line
per child. Same class as the 12 Hz work-area re-assert removed earlier this session.

v2 replaces the standing cadence with a **bounded per-owner burst**:

- New `WINDOW_DATA` fields `SynthHealLeft` (passes still to run; 0 = disarmed) and
  `SynthHealDue` (absolute `GetTickCount()` deadline). Zeroed by the existing `ZeroMemory`
  at entry creation.
- `SynthArmHeal(owner)` sets `SynthHealLeft = SYNTH_HEAL_PASSES (3)` and
  `SynthHealDue = now + SYNTH_HEAL_FIRST_MS (50)`.
- `SynthHealPass()` runs a due pass, decrements, and schedules the next at
  `now + (50 << (3 - SynthHealLeft))`. When `SynthHealLeft` hits 0 the owner is disarmed and
  `SynthNextHealTimeout()` returns `INFINITE` again.

**Exact schedule: passes at +50 ms, +150 ms, +350 ms after arming. Then nothing.**
(gap sequence 50 / 100 / 200 — each gap twice the previous.)

**Arming sites — exactly two, both one-shot events:**

1. `SynthActivate` (a child is newly synthesized);
2. the `geomChanged` branch for a synthesized child in `UpdateWindowData` (a menu grew, a
   submenu opened, the popup moved) — the newly exposed region has never been copied and the
   new content may itself be mid-draw.

**Re-arming RESETS the burst** (`SynthHealLeft = 3` again) rather than accumulating, so the
last arming event at time *T* is followed by **at most 3 wakeups, all within 350 ms of T**.

**Worst case per popup:** 3 wakeups for it appearing, plus at most 3 more in the 350 ms after
it last changed shape. A menu that opens, sits still, and closes costs **3 wakeups total** —
not 5/s for as long as it is open.

**Why a burst is sufficient (and a cadence is not just expensive but pointless):** the burst
only has to cure a copy taken mid-draw or pre-paint. Any *later* pixel change inside a
synthesized child is by construction damage to the desktop framebuffer, so it produces a DDA
frame, and the existing in-frame dirty-rect patch and periodic pass already handle it.

**A long-lived synthesized child cannot re-arm it indefinitely:** `geomChanged` is a strict
comparison of X/Y/Width/Height against the freshly interrogated values, so a window that sits
still never re-arms. A window that *is* moving is producing screen damage anyway (frames flow,
the in-frame path is doing the work), and its burst still terminates 350 ms after motion stops.

### BLOCKER 2 — crash risk, and v1's rationale was FALSE. FIXED in `capture.c`, claim corrected.

v1's commit message and notes claimed `RecreateDuplication` "NULLs `ctx->framebuffer` under
`frame.lock` **before** dropping the duplication, so the whole multi-second recovery window is
covered". **The code did the opposite.** `capture.c:235` called
`IDXGIOutputDuplication_Release` first; only then did `:244-252` do
`XcGnttabRevokeForeignAccess` + `ctx->framebuffer = NULL`. Releasing the duplication
invalidates the `MapDesktopSurface` mapping `g_FbBits` points at, and the gap between the two
spans a full xeniface gnttab IOCTL. A copy in that gap passes the
`g_FbBits == capture->framebuffer` guard and memcpys from unmapped memory → access violation →
agent dies → guest GUI dies. v1 also raised the sampling rate of that pre-existing hazard from
once per popup to 5×/s per owner.

**v2 fixes the ordering.** At the very top of `RecreateDuplication`'s locked region — before
the held-frame `ReleaseFrame` and before the duplication `Release`, i.e. before *anything* that
can invalidate the mapping — the framebuffer pointer and grant refs are stashed into locals and
`ctx->framebuffer` / `ctx->grant_refs` are cleared. The revoke then runs afterwards with the
stashed address (it needs the address, so it cannot simply be moved up). Ordering only; the
observable end state is byte-identical. One incidental tidy-up: `free(grantRefs)` moved outside
the `ctx->xc &&` test (`free(NULL)` is a no-op, and a non-NULL `grant_refs` implies a successful
grant implies a live `ctx->xc`, so no reachable behaviour changes).

**Why the ordering fix and not "hold the lock across the copy" — the lower-risk choice:**

- `frame.lock` is today a **leaf** lock, private to `capture.c`. Taking it in the copy path
  creates a new nesting `g_csWatchedWindows → frame.lock → vchan CS` (the copy path already
  holds the first and `SendWindowDamageEvent` takes the last). That is a new lock
  relationship — precisely what this change was told not to create — and it would need its own
  review to establish it can never invert.
- The capture thread holds `frame.lock` across `AcquireNextFrame(FRAME_TIMEOUT)` and across the
  first-frame `MapDesktopSurface` + `XcGnttabPermitForeignAccess2` IOCTL. Blocking the main
  loop behind that is a latency regression in the exact loop this project is optimising.
- The ordering fix is ~10 lines, introduces no lock, and **also narrows the same hazard for the
  pre-existing `SynthActivate` paint**, which the lock option would not touch.

**Residual, stated honestly (v1 hid this behind a false claim):** the instant between the guard
(`capture->framebuffer != NULL && == g_FbBits`) and the memcpy is still open — the capture
thread can enter `RecreateDuplication` there. That is identical in kind to the exposure
`SynthActivate`'s immediate paint has always had, and it is now sampled **at most 3 times per
burst** instead of continuously. Closing it fully requires the lock nesting above and is
deliberately deferred. The unlocked read of `capture->framebuffer` is also a data race by C
rules (the capture thread writes it under `frame.lock`); it is a plain aligned pointer on
x86/MSVC and the guard rests on that. Both facts are in the code comment.

### ALSO FIXED (non-blocking review items)

- **Per-iteration list walk removed.** v1's `SynthNextPatchTimeout` entered
  `g_csWatchedWindows` and walked the whole watched list on *every* main-loop iteration while
  anything was synthesized — i.e. at input rate during a drag. v2 caches
  `(g_SynthHealArmed, g_SynthHealDeadline)` in globals updated at the arming sites;
  `SynthNextHealTimeout()` is two integer reads, no lock, no walk. The cache is deliberately
  **conservative**: arming only ever moves the deadline *earlier*, and `SynthHealPass`
  re-derives both values exactly from the window list. So a stale-armed cache (owner freed
  mid-burst, e.g. `RemoveWindow`'s owner-death loop) costs **one no-op wakeup** and can never
  cause a *missed* pass.
- **Detached-owner log storm.** A burst on an owner with no children left, with
  `PwBuffer == NULL` (detached via `WcIsDead`/`PwDetachWindow`, or forced legacy via
  `PwForceLegacy`), or with no live desktop image to copy from is **dropped**, not run — so
  `PwPatchSynthChildClipped`'s `LogWarning("synth paint …: no source")` is never emitted from
  this path. Dropping on an invalid source also removes v1's pure-no-op wakeups for the
  duration of a duplication recovery (v1 re-stamped and re-armed to avoid a spin; v2 disarms,
  which is both cheaper and simpler).
- **Corrected claims.** v1's "one extra wakeup per popup" was wrong — the back-dated stamp is
  per *owner*, so it was one per synthesized child. v2 removes the back-dating entirely, so
  the in-frame paths are now **completely unchanged** and the claim does not need to be made.
  v1's "`StopFrameProcessing` … also closes the same latent hazard for `SynthActivate`'s
  immediate paint" was wrong: that paint is reached from `ProcessWindowEvents`, outside the
  frame handshake, guarded only by the `g_FbBits != NULL` test inside
  `PwPatchSynthChildClipped`. `StopFrameProcessing` still clears `g_FbBits`/`g_FbPitch` (it is
  a genuine narrowing and costs nothing) but the comment now says **narrows**, not closes.
- **Not done (optional in review):** early-stop when a pass copies bytes identical to the
  previous one. It would mean either a memcmp inside `PwPatchSynthChildClipped` — which is on
  the in-frame path, and those were required to stay unchanged — or duplicating the clip
  arithmetic in the heal path. With the burst bounded at 3 passes the whole worst case is 3
  redundant `MSG_SHMIMAGE`s per popup, which is not worth the diff.

## Idle-cost statement

**Zero extra wakeups once every burst has completed — including with a long-lived synthesized
child on screen.** `SynthNextHealTimeout()` returns `INFINITE` after a single read of
`g_SynthHealArmed`, before any lock is taken, so an idle guest with no burst in flight waits
exactly as it did before this change existed. Bursts self-terminate after 3 passes and are
armed only by synthesis and by geometry change, neither of which recurs on a static desktop.
Closing a menu additionally disarms its owner immediately (`SynthDeactivate` zeroes
`SynthHealLeft` when the last child goes away), so a burst never outlives the popup it was
armed for.

**No busy-wait.** Every timeout pass either consumes a `SynthHealLeft` (bounded at 3 per arm)
or leaves a strictly future deadline; when nothing is armable the pass sets
`g_SynthHealArmed = FALSE` and the wait returns to `INFINITE`. A deadline already in the past
yields a wait of 0, which produces exactly one immediate `WAIT_TIMEOUT` that then consumes a
pass — progress, not a spin.

`WAIT_TIMEOUT` is dispatched **before** the `signaledEvent >= MAXIMUM_WAIT_OBJECTS` check —
0x102 is ≥ 64, so the other order would misread a timeout as a wait failure and break the main
loop. The `continue` skips only the `#ifdef DEBUG_DUMP_WINDOWS` block and
`if (exitLoop) break` (`exitLoop` cannot have been set on that path); `vchanIoInProgress` is
re-initialised at the top of each iteration, and `capture` is the loop-local pointer, valid at
that point (`StopFrameProcessing` does not free it; `CaptureTeardown` is immediately followed
by `capture = NULL` with no wait in between).

## Locking summary

The heal path takes **only** `g_csWatchedWindows`, the same lock the in-frame path holds across
its `PwPatchSynthChildren` calls. `PwPatchSynthChildren` → `PwPatchSynthChildClipped` memcpys
and calls `SendWindowDamageEvent` (vchan CS); it never reaches `WcSetMask`/`WcMarkDirty`, the
calls that take the WGC engine lock exclusively. Order stays the established
watched-windows → vchan. `SynthArmHeal` is called only from paths that already hold
`g_csWatchedWindows` (`AddWindow` → `SynthActivate`, and `UpdateWindowData`). No new lock
relationship anywhere.

## How to verify from outside (no code access)

1. **The fix.** In the guest, open a window with menus (Notepad). Let the screen go completely
   static — no cursor motion, no blinking caret in view. Open a dropdown with the **keyboard**
   (Alt+F), or click it and then do not move the mouse at all. The menu must be fully rendered
   in dom0 within ~50 ms and at worst 350 ms, **with no further input of any kind**. Before the
   fix it stays blank indefinitely until the pointer enters it.
2. **Objective form.** `qtest shot` a second or two later, without touching the VM in between.
   Two caveats: the shot must not raise/focus/expose the owner window (that is real damage and
   would heal the bug — a false PASS), and the parent build `b299011` must be shot through the
   identical harness as a control.
3. **Idle regression — the check that would have caught v1.** With the menu **closed** and the
   desktop untouched, `QGAPROTO,msg=SYNTHPAINT` lines must **stop entirely** in the guest log.
   Not "appear at a lower rate" — none at all. Any steady trickle means a burst is being
   re-armed; any 5 Hz pattern means the burst bound is broken. CPU-time comparison is too
   coarse to see 5 Hz, so use the log.
4. **Burst shape.** Open a menu once and count the `SYNTHPAINT` lines for that owner emitted
   with the screen static: at most 3 per popup appearance (plus up to 3 more if the menu
   resized), clustered inside ~350 ms, then silence.

## Open items / risks

- **Not compiled.** Syntax, brace/paren balance and `/W4 /WX` hazards were re-read hunk by
  hunk: signed/unsigned casts are explicit (`(LONG)` on all tick differences, `(DWORD)`/`(UINT)`
  on the constants and the shift operand), no new `C_ASSERT` in `main.c`, both new statics are
  used so no C4505. CI is the real check.
- **Field discipline.** `SynthHealLeft`/`SynthHealDue` are main-thread-only and mutated under
  `g_csWatchedWindows`. Any future code that starts synthesizing a child, or that changes a
  synthesized child's geometry, without going through `SynthActivate` / `UpdateWindowData`'s
  `geomChanged` branch will silently reinstate the blank-menu bug for that case. Unlike v1's
  global counter, a *missed* update here can only cost coverage, never idle CPU — the failure
  mode is one-directional by design.
- **A burst consumed during a capture outage is lost.** If a duplication recovery is in flight
  when the burst comes due, the burst is dropped rather than deferred (that is what keeps the
  outage free of wakeups). The recovery path repaints everything, and the next synthesis or
  geometry change re-arms, so the exposure is a popup that stays stale until the user touches
  it — the pre-fix behaviour, confined to the seconds of a recovery.
