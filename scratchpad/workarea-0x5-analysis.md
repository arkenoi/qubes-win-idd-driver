# WorkAreaCreateListener CreateWindowEx 0x5 — root cause and fix

Date: 2026-08-02. Source analysis only, against agent submodule `perwindow` @ 382fa05.
Companion patch (draft, verified with `git apply --check`, NOT applied):
`/home/user/qubes-win-idd-driver/scratchpad/fix-workarea-listener.patch`

## Symptom

`WorkAreaCreateListener: CreateWindowEx(workarea listener) failed with error 0x5:
Access is denied` — 3x at agent start on Win10 19045 (evidence:
`instrumentation/qwtfull-w10/workarea-check.md`). Listener dead → Explorer's
asynchronous work-area recompute overwrites the agent's `(5,56)-(3435,1435)` with
`(0,0)-(3440,1400)` and is never re-asserted → maximized windows overflow the dom0
screen bottom by 16 px.

## Where the listener is created (VERIFIED from source)

- `WorkAreaCreateListener()` (`agent/gui-agent/workarea.c:278`) has exactly one call
  site: `agent/gui-agent/main.c:429`, inside the **outer loop** of
  `WindowEventThreadProc` (the window-event thread that owns the `SetWinEventHook`
  hooks and pumps messages for them).
- Per loop iteration the thread does, in order:
  1. `OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS | DESKTOP_HOOKCONTROL)`
     (main.c:401) + `SetThreadDesktop` (main.c:404) — deliberately NOT
     `AttachToInputDesktop()` for the shared-globals/CloseDesktop reasons documented
     in the comment at main.c:392-400;
  2. arms the WinEvent hooks;
  3. `WorkAreaCreateListener()` — registers class `QubesGuiAgentWorkArea` and
     creates a hidden real top-level window (`WS_POPUP`,
     `WS_EX_TOOLWINDOW|WS_EX_NOACTIVATE`, 0x0 at 0,0, never shown) whose wndproc
     re-asserts on `WM_SETTINGCHANGE(SPI_SETWORKAREA)` / `WM_DISPLAYCHANGE`.
- The loop re-runs (rearm) whenever `RearmWindowEvents()` is signalled: from
  `StartFrameProcessing` (main.c:3174) and from `EnsureOnInputDesktop` (main.c:1615,
  reached from the resync path `AddAllWindows`). Each rearm unhooks, re-attaches to
  the (possibly new) input desktop, and calls `WorkAreaCreateListener()` again.

Context: process runs as SYSTEM in session 1 (watchdog), window station WinSta0,
attaching to the current input desktop (`Default` after logon).

## Root cause (VERIFIED from source + documented Win32 semantics)

`OpenInputDesktop` at main.c:401 requests only
`DESKTOP_READOBJECTS | DESKTOP_HOOKCONTROL`. **`DESKTOP_CREATEWINDOW` is absent.**
Desktop access checks in win32k are performed against the *handle's granted access
mask*, not the caller's token: any `CreateWindow(Ex)` on a thread whose current
desktop handle was opened without `DESKTOP_CREATEWINDOW` fails with
`ERROR_ACCESS_DENIED` (0x5), regardless of the caller being SYSTEM. This is the
documented purpose of the `DESKTOP_CREATEWINDOW` right.

That mask is sufficient for everything else the thread does — `SetWinEventHook`
needs `DESKTOP_HOOKCONTROL`, enumeration needs `DESKTOP_READOBJECTS` — which is why
only the listener fails and the hooks arm fine.

Cross-reference with the paths that *can* create windows / do full work:

| Path | Desktop open mask | Window creation possible? |
|---|---|---|
| `AttachToInputDesktop` (util.c:274, used by main thread / `StartFrameProcessing` / resolution thread) | `DESKTOP_CREATEMENU\|DESKTOP_CREATEWINDOW\|DESKTOP_ENUMERATE\|DESKTOP_HOOKCONTROL\|DESKTOP_JOURNALPLAYBACK\|DESKTOP_READOBJECTS\|DESKTOP_WRITEOBJECTS` | yes |
| `capture.c:183` (capture thread) | `GENERIC_ALL` | yes |
| `wincapture.cpp:74` (WGC thread) | `GENERIC_READ` | no (doesn't need it) |
| **window-event thread (main.c:401)** | `DESKTOP_READOBJECTS\|DESKTOP_HOOKCONTROL` | **no → 0x5** |

Not the cause (ruled out):
- (b) class registration — `RegisterClassEx` succeeds (a failure would log
  `RegisterClassEx(workarea listener)` and it doesn't); class registration isn't
  desktop-scoped anyway.
- (c) UIPI/integrity — irrelevant to window *creation*; UIPI filters message
  delivery between existing windows.
- (d) desktop-switch timing / wrong desktop — the thread *is* correctly attached
  (SetThreadDesktop succeeds with this mask; hooks on the same desktop deliver
  events). It's on the right desktop with the wrong handle rights.
- "thread already has windows so SetThreadDesktop failed" — inverted: today
  SetThreadDesktop succeeds *because* the window never gets created. See "latent
  bug" below.

### Why the error appears exactly 3x at start

One `WorkAreaCreateListener()` call per outer-loop iteration: the initial arm plus
one rearm per `RearmWindowEvents()` during startup — `StartFrameProcessing`
(capture init) and the `EnsureOnInputDesktop` re-attach from the first resync both
fire at boot. 3 iterations → 3 identical 0x5 lines. (Inferred count attribution;
the per-iteration call structure is verified.)

### Why it was believed Win11-only

Coverage artifact, not an OS difference (inferred, supported by git history):
- The narrow mask arrived with the Phase-2A event-tracking rework (6d46132 /
  e5ea33d, Jul 31); `WorkAreaCreateListener` was added onto that thread the next
  day (826ad82, Aug 1, "Work area: event-driven re-assert instead of polling").
  The bug has existed on *every* OS since the listener was born — there was never a
  listener build that predated the narrow mask.
- All early testing of the listener build happened on the Win11 qube
  (FINDINGS.md line ~605 lists the 0x5 among "Open Win11 items"), so the first
  sighting got filed as a Win11 quirk. The first pristine-Win10 run with this build
  (2026-08-01 workarea-check) reproduced it immediately. Nothing in the failing
  code path is OS-version dependent.

## Latent second bug the fix must not trip

`SetThreadDesktop` fails if the calling thread has any windows or hooks on its
current desktop. Today the loop unhooks the WinEvent hooks before re-attaching but
**never destroys the listener window** — harmless only because creation always
fails. The moment the 0x5 is fixed in isolation, the first rearm would:
1. fail `SetThreadDesktop` forever after (thread owns a window) → hooks re-arm on
   the *stale* desktop → window tracking degrades to the 2 s resync after any
   desktop switch — a real regression far worse than the work-area bug; and
2. leak one listener window per iteration (duplicate re-asserts per broadcast).

So the fix is necessarily two-part: access right + listener lifecycle.

## The fix (draft patch, 3 changes)

1. **main.c:401** — open the input desktop with
   `DESKTOP_READOBJECTS | DESKTOP_HOOKCONTROL | DESKTOP_CREATEWINDOW`; on failure
   fall back to the old narrow mask (hooks are the thread's critical function;
   SYSTEM is never denied, but the guard makes the change strictly non-regressing).
2. **Listener lifecycle** — new `WorkAreaDestroyListener()` called at the bottom of
   the outer loop (after `UnhookWinEvent`, before the next `SetThreadDesktop`);
   `WorkAreaCreateListener()` stores the HWND in a thread-affine static and is
   idempotent (destroys a leftover before creating). The listener is thereby
   re-created on the *new* input desktop after every rearm — required anyway, since
   broadcasts are per-desktop and a stale listener would go deaf.
3. **Safety net** — new `WorkAreaEnsureApplied()`: compare `SPI_GETWORKAREA` to
   `g_WaLastApplied` (no-op until something was applied), `WorkAreaReassert()` on
   mismatch. Called from `ProcessWindowEvents` (main.c, after the
   `TrackWindows` critical section is released) gated on `stats.Resync` — i.e. the
   existing 2 s resync tick (`WINDOW_RESYNC_INTERVAL_MS`), which becomes 150 ms
   only in the hook-thread-death fallback. Deliberately *not* inside
   `AddAllWindows`/`TrackWindows`: those run under `g_csWatchedWindows`, and
   re-assert does cross-process calls (`EnumWindows` + `SetWindowPlacement` refit)
   that must not run under agent locks (workarea.c's own WaRefitProc comment).

### Which tick, and why not the 200 ms one

`SynthLastFullPatch` (SYNTH_FULL_PATCH_MS = 200 ms) is per-window, per-frame, inside
composite paint — wrong layer and would run the check up to N-windows times per
frame. The 2 s resync is a single process-wide tick on the main loop with lock-free
placement available; a drifted work area for up to 2 s is imperceptible next to the
current "forever".

### Ship both, or event-only, or poll-only?

**Ship both.** The listener remains the primary mechanism (instant re-assert;
catches the `WM_DISPLAYCHANGE` resolution case where re-fitting maximized windows
promptly matters most, since `WorkAreaApply` deliberately sets without
`SPIF_SENDCHANGE` and refits manually). The resync compare is one
`SystemParametersInfoW` read every 2 s — effectively free — and covers every way the
event path can silently fail: this exact bug recurring, hook-thread death
(`g_WindowEventThreadDead`), the rearm window between destroy and re-create, or a
future OS delivering broadcasts differently. Poll-only would also work functionally
but gives up sub-tick latency on display changes and keeps a hard 2 s glitch window;
event-only leaves the design with the same single point of failure that just
produced a shipped defect.

## Risks

- **Wider desktop handle rights**: adds one access right to a handle held by an
  agent-internal thread; SYSTEM already has full desktop access via the security
  descriptor, so no privilege change in practice. Fallback open preserves old
  behavior in any deny case. No isolation/security-model impact (all in-guest).
- **`DestroyWindow` timing**: called on the creating thread (the only caller is the
  window-event thread) — thread-affinity requirement satisfied. Destroy happens
  while the thread still pumps no messages for it; pending broadcast messages to a
  destroyed window are discarded by USER32, no UAF (wndproc holds no state).
- **Drift-check false positives**: if no source ever produced a rect,
  `g_WaLastApplied` stays empty and the check is inert — guests without the
  work-area feature see zero behavior change. If dom0/registry values change,
  `WorkAreaApply` updates `g_WaLastApplied` first, so the compare always tracks the
  current target. The check can fight a user who manually sets a different work
  area in-guest — identical to the listener's existing (intended) behavior.
- **Refit churn**: a genuine drift triggers `WorkAreaReassert` →
  `EnumWindows(WaRefitProc)` + `SetWindowPlacement` on maximized windows; that is
  the existing re-assert cost, now bounded to once per drift event, not periodic.
- **Untested on hardware**: patch is `git apply --check`-verified against 382fa05
  and compiles by inspection only (C99 mid-block declarations match existing file
  style, MSVC-accepted elsewhere in workarea.c). Needs a CI build + the standard
  win10 workarea-check re-run (expect: no 0x5 lines, listener-created LogDebug
  line per rearm, `SPI_GETWORKAREA` == agent rect after 16+ min soak, maximized
  Notepad bottom edge on-screen in dom0).
