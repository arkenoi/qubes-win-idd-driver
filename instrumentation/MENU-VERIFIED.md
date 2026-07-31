# Menus (override-redirect windows): agent side verified

User report, against the build that also carried the since-reverted drag-freeze change:
*"menus are fully broken: they draw weird dom0-generated frame with no content"*, later
*"menus are still there... mouseover acts weird all over the window"*.

## Why this needed in-guest instrumentation

`local.WinScreenshot` enumerates **managed** windows only. Menus are override-redirect, so
they never appear in its output: with a menu held open the service returns 4 window PNGs and
the 229x196 menu is not among them, while the agent log shows it mapped. "The agent never
mapped it" and "my capture tool cannot see it" are indistinguishable from outside - so the
dom0 screenshot path cannot answer anything about menus, and earlier NOT-IN-DOM0 verdicts for
them mean nothing.

`LogVerbose`, where the per-window damage trace lives, is compiled out of Release builds, so
raising LogLevel does not help either. Hence a dedicated counter.

## Verified

Trigger: open Notepad's File menu, sweep the cursor down 8 items (one hover repaint each).

| question | evidence | result |
|---|---|---|
| is the menu mapped? | `SendWindowMap: Mapping window 0x90040` | **yes** |
| is it override-redirect? | styles `WS_POPUP\|TOPMOST\|TOOLWINDOW`, `ex=0x189`, not layered | **yes**, sent with `override_redirect` as the Linux agent does |
| do hover repaints reach the daemon? | `popup damage: ... window 0x90040` on **10 frames**, 10 messages | **yes** |
| is it wrongly rejected as Office chrome? | not layered and not transparent, so the chrome predicate cannot match it | **no** |

So the agent maps menus and delivers a damage message per hover repaint. The blank-menu
report is addressed by the full-window repaint sent on map; the "mouseover acts weird" report
was made against the build carrying the drag-freeze change, which suppressed damage
permanently for any window whose `MOVESIZEEND` was missed - reverted since.

## Limit of this result

This verifies what the **agent sends**. Whether dom0 *paints* menu content correctly cannot be
checked with the tooling available here, because the screenshot service cannot capture
override-redirect windows. That last step needs a human look, or a dom0-side change that is
out of scope for this qube.

## Two traps hit while measuring, both previously documented

1. `LogDebug` is invisible at the guest's default `LogLevel=3`. The counter was first added at
   DEBUG and read a confident `POPUP-DAMAGE-FRAMES=0` - a "confirmed zero" that meant only
   that the message could not be printed. Same trap as the ACCESS_LOST recovery message
   (`ACCESS-LOST-VERIFIED.md`). The calibration counter is what caught it.
2. `Restart-Service QubesGuiWatchdog` does **not** restart `gui-agent.exe`, so a registry
   LogLevel change silently does not take effect. The agent process has to be killed and let
   the watchdog restart it. Check the log **filename** changed before trusting a level change.

Any in-guest measurement should carry a calibration counter that distinguishes "the thing did
not happen" from "the instrument could not have recorded it".
