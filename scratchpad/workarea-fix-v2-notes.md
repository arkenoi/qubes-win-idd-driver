# workarea fix v2 — changes vs v1 and review disposition

Date: 2026-08-02. Commit `2c5dad2` on branch `workarea-fix-v2` in the agent repo
(pushed to `/home/user/qubes-win-idd-driver/agent`), based on perwindow @ `382fa05`.
Supersedes the v1 draft `scratchpad/fix-workarea-listener.patch` (never applied).
Files: `gui-agent/main.c`, `gui-agent/workarea.c`, `gui-agent/workarea.h`
(+170/-7). Unbuilt — needs the standard CI build + workarea-check re-run.

## Kept from v1 (unchanged in substance)

- **Mask fix** (main.c WindowEventThreadProc): input desktop opened with
  `DESKTOP_READOBJECTS|DESKTOP_HOOKCONTROL|DESKTOP_CREATEWINDOW`; narrow-mask
  fallback if the wide open is denied, so hooks survive regardless.
- **Listener lifecycle**: `WorkAreaDestroyListener()` at the bottom of the outer
  loop — after `UnhookWinEvent`, before the next `SetThreadDesktop`, and on every
  thread-exit path (verified: no return/goto inside the loop; all exits break out
  of the inner loop only). HWND tracked in a thread-affine static; create is
  idempotent (replaces a leftover) and re-runs after each re-attach, putting the
  listener on the NEW desktop.

## Blocker 1 — drift check starved/unreachable (FIXED)

v1 gated `WorkAreaEnsureApplied` on `stats.Resync` inside `ProcessWindowEvents`
only. Reviews proved that (a) `ProcessNewFrame`'s `TrackWindows` (main.c:2860)
drains the 2 s resync tick without running the check (starved under steady frame
traffic), and (b) after hook-thread death `ProcessWindowEvents` is never invoked
again (`g_WindowEventSignal` is set only by the hook thread; main-loop wait is
INFINITE) — dead code precisely in the "150 ms fallback" its comment claimed.

v2: the check carries its **own GetTickCount interval** (`WA_DRIFT_CHECK_MS`
2000, wrap-safe `now - lastCheck >= interval`, static local — both call sites are
on the main-loop thread) and is called from **both** paths:

- frame path: main loop case 1, immediately after `ProcessNewFrame` returns —
  no locks held, outside the frame's perf accounting (deliberately not inside
  `ProcessNewFrame`, which holds `g_csWatchedWindows` until its cleanup label
  and emits `PerfEmitFrame` right after release);
- event path: `ProcessWindowEvents`, after `LeaveCriticalSection(&g_csWatchedWindows)`.

Lock discipline per constraints: `g_WaLastApplied` is copied under `g_WaLock`,
the lock is released, then `SPI_GETWORKAREA` / `WorkAreaReassert` run lock-free.

**Comments state only actual coverage**: fires as long as frames OR window events
flow — including after hook-thread death, when frames keep arriving. Explicitly
documented as NOT covering a fully idle desktop (no frames, no events, main loop
parked): only the broadcast listener catches an overwrite there. The false "150 ms
in the hook-death fallback" / "bounds staleness to one resync interval" claims
from v1 are gone.

## Blocker 2 — uninitialized g_WaLock at boot (FIXED)

The listener goes live at window-event-thread start (`Init()`), before
`WorkAreaInit()` (vchan connect, main.c:3434) initialized `g_WaLock`; an early
`WM_DISPLAYCHANGE` (HandleXconf mode set) or Explorer autologon broadcast would
enter a zeroed CRITICAL_SECTION via `WaWndProc -> WorkAreaReassert`. Fixed on
three levels:

1. New `WorkAreaLockInit()` (idempotent, single-threaded-startup contract
   documented in workarea.h) called from `Init()` **before**
   `StartWindowEventThread()` — CreateThread orders the write, so the lock
   deterministically exists before any thread that can execute `WaWndProc`.
   `WorkAreaInit()` now calls it instead of `InitializeCriticalSection` directly.
2. `WorkAreaCreateListener` refuses to create the listener (ERROR log) if
   `g_WaLockInit` is false — belt-and-braces against future call-order changes.
3. `WorkAreaReassert` gains the same `g_WaInitDone` guard as `WorkAreaApply`:
   a broadcast between listener creation and `WorkAreaInit` is a no-op (nothing
   has been applied yet, so there is nothing to re-assert). This also makes
   pre-first-apply Reassert semantics explicit.

## Non-blockers addressed

- **Loud DestroyWindow failure**: `WorkAreaDestroyListener` now logs at ERROR
  level spelling out the consequence (thread keeps owning a window → every
  subsequent `SetThreadDesktop` rearm fails → tracking silently degrades to the
  periodic resync), plus `win_perror` for the code. Handle is still cleared so
  create/destroy stays re-runnable.
- **Bounding WaWndProc's re-assert work** — judgement call, documented in the
  commit message: the re-assert **stays synchronous on the hook thread**.
  Deferring it to the new tick path was rejected because the tick is
  frame/event-driven: on an idle desktop the deferred re-assert would never run,
  and "Explorer overwrites the work area while the desktop idles ~16 min" is the
  measured defect scenario — deferral would regress the primary fix. Instead the
  unbounded part is bounded: `WaRefitProc` now skips hung windows
  (`IsHungAppWindow`, same pattern as wincapture.cpp's CaptureAndDiff), so the
  synchronous cross-process `SetWindowPlacement` can no longer park the hook
  thread behind a hung app. Re-asserts happen only on real work-area/display
  changes. No new threads (constraint).

## Deferred (with reasons)

- **`g_WaLastApplied` committed before SPI_SETWORKAREA succeeds** (review 2
  non-blocker): on persistent set failure the drift check now re-detects every
  2 s → failed set + 2 log lines per tick until geometry converges. Bounded and
  self-healing (failure mode is a transient resolution mismatch); changing
  commit-on-success semantics touches `WorkAreaApply`'s changed-shortcut and lock
  flow — out of the minimal-diff budget for this fix.
- **Drift check fights an in-guest user who sets their own work area** — intended
  listener behavior, unchanged; note in FINDINGS.md when this lands.
- **Stale g_ScreenWidth/Height read in WaRectSane during resolution transition**
  — pre-existing class, self-corrects next tick/broadcast; unchanged.
- **User directive conflict** (review 2 non-blocker): the 2 s drift compare is a
  timed check after the user chose event-driven over polling. It is one
  SPI read per 2 s, only while frames/events already flow, and exists solely to
  backstop listener death. Flag to the user before upstreaming.

## Verification plan (unchanged from v1 analysis, plus review additions)

CI build; on win10: expect zero `CreateWindowEx(workarea listener)` 0x5 lines,
one "work-area listener window created" LogDebug per arm/rearm, SPI_GETWORKAREA
== agent rect after a 16+ min idle soak, maximized-Notepad bottom edge on-screen
in dom0. Add (per review): an explicit rearm exercise (resolution change /
desktop switch) confirming `SetThreadDesktop` still succeeds with the listener
alive and tracking stays event-driven; and a boot-race eyeball of the log for
any re-assert before `WorkAreaInit` (should be absent — guard makes it a no-op).
