# Overlapping windows in motion — the remaining blocker, with direct evidence

`visual/overlap-in-motion.png` is a dom0 full-desktop capture taken mid-drag, with the agent's
own build running.

## What it shows

The dragged Notepad is on top **in the guest**. dom0 draws **chromerepro** on top instead. In
chromerepro's client area the left of every line is sliced away - `ndow repro`,
`sparent/toolwindow`, `ppable chrome`, `dump inventory  Esc quit` - because the region is
covered by the Notepad in the guest, so the composited framebuffer holds the Notepad's white
pixels there and chromerepro's pixmap receives them.

## Why both available behaviours are wrong

* **No clipping** (current, popups only): an occluded window receives the occluder's pixels
  straight out of the composited framebuffer. That is the effect above.
* **Clipping against guest z-order** (tried, reverted to popups-only): the withheld region is
  exactly what dom0 draws on top, so it renders as a stale band instead. Measured earlier: a
  stale vertical band through chromerepro's text that vanished the moment the guest's stacking
  was made to agree with dom0's.

Neither is fixable by choosing better clipping. The defect is that **dom0's stacking and the
guest's are allowed to disagree**, and the agent never tells the daemon about z-order.

## The cheap thing to try first, before any protocol work

The agent already hooks `EVENT_SYSTEM_FOREGROUND` territory for tracking. If re-sending
`MSG_MAP` (or `MSG_CONFIGURE`) for the guest's foreground window causes the daemon to raise it,
dom0's stacking would follow the guest's with no protocol change at all. That is one build and
one mid-drag capture to falsify - and it must be falsified before proposing anything larger,
because a protocol change is Phase 3 and needs upstream design review.

If the daemon does not raise on remap, then a stacking message is genuinely required and this
becomes a design writeup, not code.

## Status

This is the only remaining criterion. Everything measurable about it is captured here; what is
missing is the one experiment above.
