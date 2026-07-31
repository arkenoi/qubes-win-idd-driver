# Proposed upstream PR — recover from DXGI_ERROR_ACCESS_LOST in place

**Status: NOT SUBMITTED.** Per CLAUDE.md, upstream contact requires explicit approval of the
exact diff and text. This file is the proposed text; `access-lost-recovery.patch` is the exact
diff (6 commits, +224/-3 in `gui-agent/capture.{c,h}` and `gui-agent/main.c`).

Target: `QubesOS/qubes-gui-agent-windows`. Branch: `pr-access-lost`, cherry-picked onto
upstream `431e4517` and **verified to build standalone in CI** (no dependency on the Phase 2A
work in the same fork).

## Problem

When the desktop duplication is invalidated - desktop switch, resolution change, session
change, driver reset - the agent tore down its whole capture context and reinitialised. That
path sends `MSG_WINDOW_UNMAP` for every window, so from dom0's point of view every window in
the qube disappears and comes back. In seamless mode the user sees all windows blink out.

`DXGI_ERROR_ACCESS_LOST` is documented as recoverable by recreating the duplication; nothing
requires discarding window state.

## Change

Recreate the duplication in place, keeping the watched-window list, with a bounded retry
(20 x 250 ms) and fallback to the existing reinitialise path if recovery genuinely fails.

Four things that are not obvious, each found by testing rather than by reading:

1. **The failure usually arrives from `ReleaseFrame()`, not `AcquireNextFrame()`.** By the
   time a desktop switch lands the agent is normally holding a frame, so the invalidation
   surfaces on release. An acquire-only fix is unreachable in practice. It can also surface
   from `GetFrameDirtyRects`, so recovery is handled at the `GetFrame`/`ReleaseFrame` call
   sites rather than per-API.

2. **`DuplicateOutput()` returns `E_ACCESSDENIED` if the calling thread is not on the current
   input desktop** - exactly the state a desktop switch leaves the capture thread in. Without
   re-attaching, every retry fails and recovery can never succeed for the most common trigger.
   Re-attach before *every* attempt: the switch may still be in progress on the first.

3. **The framebuffer grant must be refreshed.** The desktop surface belongs to the duplication
   object. Keeping `grant_refs` across a recreate means `GetFrame` never maps the new surface
   and the daemon keeps reading the pages of the duplication that was torn down: windows stay
   mapped and correctly positioned while their contents freeze permanently. Recovery revokes
   and clears the grant, re-grants on the next frame, re-sends `MSG_WINDOW_DUMP` *before* any
   damage for that frame, then forces a full repaint (an idle window would otherwise never be
   damaged again).

4. `ReleaseFrame()` can fail at `UnMapDesktopSurface` and leave `mapped` set while freeing
   rects only on the path it completes, so recovery resets the whole frame state; otherwise
   the replacement inherits stale flags and the next `GetFrame` double-unmaps.

## Testing

win-idd-test, standalone Win10 22H2 HVM, QWT 4.2.2, trigger = `CreateDesktop` +
`SwitchDesktop` away and back (documented `ACCESS_LOST` cause, same class as a resolution
change).

| | before | after |
|---|---|---|
| agent log | `duplication lost..., reinitializing` + `SendWindowUnmap` per window | `RecreateDuplication: duplication recreated in place after 1 attempt(s) - windows kept` |
| dom0 window images | uniformly black (`std = 0.0`) | live, and match the guest's own screenshot to mean abs difference 0.0-1.7 / 255 |
| contents after recovery | byte-identical across captures minutes apart (frozen) | update normally |

Recovery is logged at INFO deliberately: the guest's default `LogLevel=3` does not show DEBUG,
which would make a working recovery indistinguishable from a silent teardown.

## Notes for review

- The in-place path is strictly additive; the previous teardown remains as the fallback.
- Only the per-thread part of `AttachToInputDesktop()` is used, since that helper also writes
  shared globals unsynchronised and closes the process-default desktop handle - the same
  reasoning already applied to the hook thread in `main.c`.
- No protocol change: `MSG_WINDOW_DUMP` re-send uses the existing message.
