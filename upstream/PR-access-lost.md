# Upstream PR (DRAFT — NOT SUBMITTED, needs user approval of this exact text)

Target: `QubesOS/qubes-gui-agent-windows`
Patch: `upstream/0001-access-lost-recover-in-place.patch` (+104 / −4, one file: `gui-agent/capture.c`)

This is deliberately split out of our larger work so it can be reviewed on its own. It has
no dependency on our instrumentation or on the window-tracking rework — it applies to
pristine `capture.c` and uses only symbols already present there (`GetDuplication`,
`g_CaptureThreadEnable`, the DXGI wrappers, and `LogInfo`, which `main.c` already uses and
`capture.c` already has via `#include <log.h>`).

---

## Title
`capture: recover from DXGI_ERROR_ACCESS_LOST in place instead of unmapping every window`

## Problem

`DXGI_ERROR_ACCESS_LOST` (0x887A0026) is the routine "your duplication object is stale,
create a new one" signal. It fires on display mode changes, desktop switches, and every trip
to the secure desktop (UAC prompt, Ctrl-Alt-Del).

The agent currently treats it as a fatal capture failure: it disables the capture thread and
signals the main loop, which reinitialises and **unmaps every window**. In dom0 the qube's
windows visibly vanish and reappear after an entirely expected event.

Two secondary problems:

* The log message is misleading. `win_perror2()` renders 0x887A0026 through
  `FormatMessage(FROM_SYSTEM)`, which prints the unrelated string
  **"The keyed mutex was abandoned."** There is no keyed mutex involved. This sent our own
  investigation chasing a nonexistent mutex bug for a while.
* Because mode changes raise this constantly, any feature that changes resolution (e.g.
  following a dom0 window resize) glitches by construction.

## Change

Add `RecreateDuplication()`: release the held frame and the stale duplication, then
`DuplicateOutput()` again with bounded retry (20 × 250 ms, enough to cover a secure-desktop
visit), re-reading the desc because both the mode *and* `DesktopImageInSystemMemory` can
change across the event. The watched window list is left untouched.

Handled at **both** call sites — `GetFrame` and `ReleaseFrame`. That second one matters: by
the time a desktop switch lands the agent is usually *holding* a frame, so in practice the
invalidation surfaces on release, and an acquire-only fix never runs (we measured exactly
that). `ACCESS_LOST` has been observed arriving from `AcquireNextFrame`, `ReleaseFrame` and
`GetFrameDirtyRects`.

A genuine geometry change still falls through to the existing full reinit, because the
grants and the dom0-side window are sized for the old framebuffer.

## Testing

Windows 10 Enterprise LTSC 2021 (19044.1288) HVM on Qubes R4.3, QWT 4.2.2, seamless mode.
Trigger: a forced desktop switch in the guest (`CreateDesktop` + `SwitchDesktop` away/back),
which is the same class of event as a mode change.

Before:
```
ReleaseFrame: duplication->ReleaseFrame failed with error 0x887a0026
SendWindowUnmap: 0x0
SendWindowUnmap: 0x0
SendWindowUnmap: 0x500f6        <- every window torn down
```

After:
```
GetFrame: initial GetFrameDirtyRects failed with error 0x887a0026
duplication recreated in place after 1 attempt(s) - windows kept
```
measured from the log after the error line: **11 frames captured, 0 window unmaps**, agent
and the mapped window both alive.

## Notes for the reviewer

* The recovery message is `LogInfo`, not `LogDebug`, on purpose: the default guest config is
  `LogLevel=3`, and at DEBUG a successful in-place recovery is indistinguishable from a
  silent teardown.
* `RecreateDuplication` resets `frame.mapped` and frees `frame.dirty_rects`, because
  `ReleaseFrame()` can fail at `UnMapDesktopSurface` and leave that state behind; without the
  reset the replacement duplication inherits stale flags and the next `GetFrame` asserts on a
  non-NULL texture.
* Not changed here, but worth a separate issue: `win_perror2()` on `0x887Axxxx` HRESULTs
  should print the symbolic DXGI name rather than `FormatMessage` text.
