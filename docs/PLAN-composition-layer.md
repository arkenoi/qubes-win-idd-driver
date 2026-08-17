# Plan: a composition layer that deals in window bitmaps

Written 2026-08-16 from the owner's framing, after a night of bugs that all turned out to be the
same coupling. Not scheduled. Do not start any stage on top of an unverified drag baseline.

## The idea

dom0 takes bitmaps and a pointer. The guest presents **window** bitmaps — never a desktop bitmap.
Each window publishes its own surface, rect and z-order, and nothing else.

This is not a protocol change: the Qubes GUI protocol already supports per-window buffers, which is
how the Linux agent works, and our per-window grants (`perwindow.c`, the slab pool) are already that
path. What blocks it is local, and identified below.

## Two problems that share one mechanism today

The single most useful thing to come out of 2026-08-16 is that `synthesis` is currently carrying two
unrelated jobs, and doing neither cleanly.

**1. Compound windows are genuinely synthetic.** An Office or Explorer window is a main frame plus
shadow strips, ribbon chrome and task panes — separate HWNDs that DWM composites and the user
experiences as ONE window. Presenting that as one window to dom0 is the FAITHFUL model, not a
workaround. (Owner, 2026-08-16: *"office and explorer window are genuinely synthetic. but on windows
side they behave as monolith, so we can do the same."*)

**2. Transient popups are separate windows** that merely happen to sit inside their owner. A menu is
not part of the monolith: it does not move with the owner, and it is dismissed independently.

Synthesis treats both identically, by **geometric containment** (`SynthQualifies`, within
`SYNTH_OVERHANG_MAX` = 12 px). Containment correlates with membership only while nothing moves — and
a drag is precisely where the correlation breaks. That is why the orphaned-ribbon bug looked like a
drag bug when it is really a classification bug.

### The property that actually defines membership

**Does it move with the owner.** Chrome does; a menu does not. Restated as a test we can run:

- **static**: non-activating owned chrome (`WS_EX_NOACTIVATE`, often `TRANSPARENT|LAYERED`,
  non-interactive) is a member; an activatable popup that takes mouse capture is not;
- **empirical, one number**: the child's offset from the owner is CONSTANT across owner moves.
  Constant offset = member. This needs no drag - any owner move samples it.

## Why popups cannot have their own bitmap today

`perwindow.c:381`, `PwWindowEligible()`:

    // Override-redirect windows (menus, tooltips, bubbles, splash overlays) are slice-fed
    // as a class... PrintWindow is unreliable for them from the agent's SYSTEM/session-1
    // context: Edge's "Restore pages" bubble captures fine from a user-context probe but
    // comes back blank in the agent (the WGC lesson again: user-context probes do not
    // predict SYSTEM-context behavior).
    if (entry->IsOverrideRedirect)
        return FALSE;

So popups are excluded from per-window capture **because the agent runs as SYSTEM**, and are
therefore slice-fed out of the composited desktop — which is where occlusion bleed and stale bands
come from.

That is the SAME root cause as the caption work the same day: `SetWindowLongPtr` refused with
`ERROR_ACCESS_DENIED` because the agent is SYSTEM and the windows belong to the interactive user.
Two unrelated-looking messes, one origin.

And we now have a proven technique for it: a one-shot copy of the agent launched under the window
owner's token does what SYSTEM cannot (shipped for the caption strip). Whether the same works for
CAPTURE is unmeasured and is stage 1 below - a per-frame capture across a process boundary is a far
bigger commitment than a one-shot style change.

## Stages

Each stage stands alone and leaves the tree shippable. Numbers are the order I would do them.

**Stage 1 - measure whether user-context capture works at all.** Build a probe that runs as the
window owner and captures an override-redirect popup (Edge's "Restore pages" bubble is the recorded
hard case). Compare against the agent's blank result. If this fails, stages 2 and 4 are dead and the
plan stops here - say so and keep slice-feeding. MEASURE FIRST; do not design on the assumption.

**Stage 2 - membership instead of containment.** Give `SynthQualifies` a membership test (constant
offset across owner moves, plus the static attribute rule). Members composite; non-members are
announced as their own windows from the start, not at drag time. This alone deletes the orphaning
bug, the containment race, and makes the freeze-time detach added on 2026-08-16 a safety net rather
than the mechanism.

**Stage 3 - announced geometry independent of the OS window rect.** The agent already owns the
buffer and the announced rect; make the two separable, with input coordinates translated by the same
offset. Gives caption cropping for free and retires the style-mutation helper (which fights apps for
control of their own frames). `toastcrop.c` is the in-tree precedent.

**Stage 4 - popups get their own surfaces** (needs stage 1 to have succeeded). `PwWindowEligible`
stops excluding override-redirect windows. Removes slice-feeding for that class, and with it the
occlusion coupling.

**Stage 5 - retire desktop-slice feeding entirely**, once nothing depends on it. This is the point
where "the guest never presents a desktop bitmap" becomes true rather than aspirational.

## Constraint: cropping and occlusion must live in the SAME coordinate space

Raised by the owner while reviewing this: does the crop break occlusion?

It does, if done carelessly, and this is the trap to design against. Cropping makes a window's
ANNOUNCED rect smaller than its OS window rect. Occlusion today (`rgnCovered`, accumulated over
watched windows, `main.c:4656`/`5167`) reasons about the desktop in OS-rect terms - and its safety
argument is that it knows every occluder. Under a crop:

- if occlusion keeps using OS RECTS, a cropped window claims to cover a strip that dom0 no longer
  draws, so the window beneath it is skipped exactly where it is actually visible -> stale pixels;
- if it uses ANNOUNCED rects, the claim matches what dom0 renders and stays correct.

Rule: **everything visible to dom0 is computed in announced coordinates** - occlusion claims, damage
rects, and input translation - while capture SOURCE rects stay in OS coordinates, with the crop
offset applied at exactly one boundary. Any place that mixes the two is a bug of this class.

The same rule already has a precedent and a scar: `WcSetCrop` exists for per-window capture, and the
2026-08-16 black-band bug was precisely a stale crop offset (the window's invisible border ending up
inside the buffer, drawn by dom0 at the visible-rect position). One offset, one owner, recomputed on
every geometry change.

## What this does NOT buy

Fullscreen mode is already "bitmaps and a pointer", and it is simple precisely because dom0 does not
know where windows are. Seamless cannot take that shortcut: the per-window coloured border is the
trust indicator, so dom0 must know window boundaries. Compound windows still need composition after
all of the above, because Office really is many HWNDs pretending to be one - stage 2 makes that
honest rather than accidental.
