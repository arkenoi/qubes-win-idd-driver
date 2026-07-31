# The acceptance protocol was broken. What was wrong and what replaced it.

The user reported three defects visible on sight - wobbling window contents, corrupted menu
items on hover, a dom0 rectangle over every menu, and an off window border - on a build whose
acceptance suite I had reported fully green. A protocol that cannot fail is worthless. This
records why mine could not, because the failure mode is more important than the defects.

## Why it could not fail

**1. The dom0 capture was blind to the reported defects by construction.**
`local.WinScreenshot` enumerates `_NET_CLIENT_LIST` (managed windows only) and captures with
`import -window <client>`. Menus are override-redirect, so they are not in that list at all;
decorations are drawn on the frame, not the client, so a dom0-drawn border can never appear in
the output. The rig physically could not photograph two of the three complaints.

**2. The comparison tool searched for the offset that made content match.**
`compare-views.py` calls `locate()` to find the best alignment before judging. That was added
to fix a real crop bug - and it also absorbs exactly the misregistration that "wobble" IS. A
tool that auto-aligns cannot report misalignment.

**3. Verdicts were inferred from guest state, never from the wire.**
Menus were declared "sent with override_redirect" because their WS_POPUP style implied it. The
actual protocol field was never observed. (It turned out to be correct - but by luck, not by
measurement, and the same reasoning had already produced two wrong conclusions.)

**4. Checks skipped silently on missing data.** Several passes reported PASS because the data
needed to fail them was absent - a window with no announced origin, a log level that could not
emit the counter being counted, a size-matched window pair that aliased.

**5. Harness string marshalling was broken.** `GetClassNameW`/`GetWindowTextW` were imported
without `CharSet.Unicode`, so every window title and class collected all session truncated to
its first character. "Is a menu present?" was answered by comparing `'#'` to `'#32768'`.

## What replaced it

**QGAPROTO** - the agent records what it actually tells the daemon (CREATE/MAP/CONFIGURE/
DAMAGE with the deciding fields, plus the style/exstyle the decision came from). Off by
default; registry `ProtoTrace` or env `QUBES_GUI_PROTO`. This is ground truth for a protocol
defect: not guest state, not agent intent, the field that went out.

**tools/check-protocol.py** - invariants that a visible defect must violate:

| invariant | catches |
|---|---|
| popup-class windows announced `override_redirect` | dom0 decorating menus |
| damage inside the announced geometry | content drawn outside its frame |
| announced geometry equals the guest's real frame bounds | wrong border size/position |
| every menu Windows showed was mapped | menus missing in dom0 |
| **no damage delivered to an occluded window** | menu pixels painted into the window beneath; debris when windows overlap |
| origin known for every damaged window | the checker proving nothing and calling it PASS |

Rules the checker follows, learned the hard way:
* **Missing data fails.** It never substitutes an approximation. Using Windows'
  `GetWindowRect` in place of the announced origin shifted every rect by 7px and silently
  stopped the occlusion coincidence from matching.
* **The agent is restarted before a trace run**, so every window has a traced CREATE. Windows
  that predate the trace have no announced origin and would be skipped.

## First run of the new protocol

Against the build that the old suite passed:

```
FAILED 2 invariant check(s):
  [no-damage-to-occluded-window] the same screen region 229x196 at (499,427) was sent as
    damage to BOTH hwnd=0xd006c and hwnd=0x201fe (10 times)
  [geometry-matches-guest] hwnd=0x201fe announced 2566x1022 but Windows has 2580x1029
```

The first is the mechanism behind corrupted menu items on hover and debris when one window is
dragged over another: the dirty rect is in screen coordinates, so it intersects both the menu
and the window underneath, and the daemon paints the menu's pixels into the lower window's
pixmap. I had previously called this "architectural, needs a protocol change" - it is not; the
agent can clip.

The second needs the ground truth corrected before it can be trusted: the agent deliberately
announces DWM extended frame bounds (the visible window), which is 7px inset from
`GetWindowRect` on three sides. The invariant must compare against extended frame bounds, and
only a deviation from THAT is a defect.
