# The "keyed mutex was abandoned" fault is really DXGI_ERROR_ACCESS_LOST — and the agent
# over-reacts to it

Prerequisite bug for Phase 2B-resize (CLAUDE.md flags it as such). Now diagnosed.

## What actually happens

Reproduced across multiple sessions on win-idd-test. Sequence from
`gui-agent-20260731-010455-1232.log`:

```
010455.188  HandleXconf: host resolution: 5120x1440
010455.188  SetVideoModeInternal: New resolution: 3440 x 1440
010455.532  SetSeamlessMode: Seamless mode changed to 1
010456.032  ResolutionChangeThread: resolution change: 5120x1440     <- change #1
010513.141  GetFrame: AcquireNextFrame() failed 0x887a0026
            "The keyed mutex was abandoned."                          <- fault, ~17 s later
010513.141  CaptureThread: failed to get frame
010513.157  SendWindowUnmap: 0x0
010513.422  SendWindowUnmap: 0x0 / 0x1003c                            <- unmaps EVERY window
010513.532  SetSeamlessMode: Seamless mode changed to 1
010513.923  ResolutionChangeThread: resolution change: 5120x1440      <- change #2 = RECOVERY
```

Note the ordering: the second resolution change is the agent's **recovery**, not the cause.
(An earlier reading of the log counts — "faults happen when reschange=2" — had the causality
backwards; the fault *produces* the second change.)

## The misleading error string

`0x887A0026` is **`DXGI_ERROR_ACCESS_LOST`**. The agent renders it via
`win_perror2()` -> `FormatMessage(FROM_SYSTEM)`, which maps that numeric value to an
unrelated system message, "The keyed mutex was abandoned." There is no keyed mutex involved.
`tools/ddaprobe` prints symbolic DXGI names precisely to avoid this trap (see the comment
above `HrName()` in ddaprobe.cpp) and reports `access_lost` / `reduplications` as their own
counters.

Anyone searching the logs for a mutex bug is chasing a phantom.

## Why it matters, and the fix

`DXGI_ERROR_ACCESS_LOST` is the **routine** signal that the duplication interface must be
recreated — it fires on mode changes, desktop switches, the secure desktop (UAC/Ctrl-Alt-Del),
and session changes. The documented handling is: release the duplication, call
`DuplicateOutput()` again, carry on.

The agent instead treats it as a capture failure and performs a full re-init that
**unmaps every window** and re-sends the seamless mode + resolution. In dom0 that is a
visible glitch: all the qube's windows vanish and reappear.

Fix (small, upstreamable):
1. In `GetFrame`/`CaptureThread`, special-case `DXGI_ERROR_ACCESS_LOST` (and
   `DXGI_ERROR_ACCESS_DENIED`, which the secure desktop raises): release and re-`DuplicateOutput()`
   in place, with a bounded retry, and continue **without** tearing down the window list.
2. Log the symbolic DXGI name, not `FormatMessage` text, for `0x887Axxxx` HRESULTs.
   `ddaprobe.cpp`'s `HrName()` table can be lifted verbatim.
3. Only fall back to the full re-init if re-duplication itself keeps failing.

`ddaprobe` already implements exactly this recovery (release -> re-duplicate -> re-read the
desc, since the mode *and* `DesktopImageInSystemMemory` can change across the event) and
survived every run, which is direct evidence the approach works on this guest.

## Impact on Phase 2B-resize
Resize drives mode changes continuously, so it will raise `ACCESS_LOST` constantly. With the
current handling every resize step would unmap all windows. **Fix this first** — otherwise
"resolution follows the dom0 window" cannot be made smooth no matter how good the IDD is.
