# QWT-NG 4.3.32 — windows appear when they are created, and a window in the background stops costing its application

Everything in 4.3.31 is carried forward unchanged. This release is about one thing a user feels
constantly and could not previously name: **how long a window takes to show up, and what having
several windows open costs.**

## A new window is announced when it is created

Opening a window used to stall before dom0 was told it existed. The agent rendered the window
first, with a synchronous `PrintWindow` — a call Windows services **on the application's own UI
thread** — and only then announced it.

That call was the entire delay. Timing every step of the announce on Windows 11:

| step | cost |
|---|---|
| grant the window's buffer | 0–15 ms |
| open the capture channel | 0 ms |
| **render it synchronously** | **438 / 32 / 329 ms** |
| tell dom0 about it | 0 ms |

It also was not buying what it cost: a window is rendered at *creation* time, before the
application has painted anything, so that frame was replaced almost immediately — a full-window
repaint went out in the same millisecond as the announce, and painting continued for another
1.5–4.3 seconds.

So the first capture now happens on the capture thread instead, and the window is announced at
once. Measured back to back, alternating builds and verifying the running binary each run:
**create-to-announce fell from a mean of 130.7 ms to 8.7 ms.**

Two cases deliberately keep the synchronous render, because there the pixels already exist and
announcing early would show an empty frame: a window being **rebuilt** after a resize, and a window
that **already existed** when the agent attached to it (agent restart, mode change). The black
blink fixed in September does not come back.

## A window in the background stops costing the application it belongs to

Every capture is a `PrintWindow`, and Windows runs it on the **target window's own UI thread**. A
window that was not in front could never be skipped — the agent declined to examine it and assumed
it had changed — so it was captured on every frame that considered it.

With two Explorer windows open, the second landing over the first:

| | before | after |
|---|---|---|
| captures of the first window | 117 / 119 / 118 | **26 / 28 / 35** |
| its own UI thread spent on them | 6057 / 5800 / 4735 ms | **1994 / 1835 / 2553 ms** |
| of those captures, produced nothing | 113 / 115 / 116 | — |
| **time for the second window to finish drawing** | 11610 / 11795 / 1222 ms | **2235 / 203 / 1402 ms** |

All Explorer windows share one process, so those wasted seconds were starving the very process that
had to paint the new window. The agent now compares only the part of a window you can actually see,
so a change *on top of* a window no longer counts as a change *to* it. A window that nothing covers
is copied from the desktop image the agent already has, instead of being rendered again.

This also fixes a visible symptom: a window would go unresponsive while something animated on top
of it.

**The fast path is untouched.** An unoccluded window takes the original comparison unchanged. A
foreground window behaves exactly as before. Where no window ordering is available, nothing new
runs at all.

## Also in this release

- A newly created window's first capture is served ahead of other windows' refreshes, so a new
  window no longer waits behind them (third window of a sequence: 168 ms → 107 ms, 3 of 3 pairs).
- The broker keeps a window's capture slot across a resize instead of releasing and re-acquiring
  it, which made the capture session be destroyed and rebuilt. Validated on this release build:
  the slot survived a menu's real resize oscillation 17 times against 6 re-registrations.
- Diagnostics, all behind the existing `ProtoTrace` switch, for attributing capture cost per window.

## What was verified before release

Full acceptance on the packaged release, all eight cells — clean install, same-version reinstall,
upgrade from the previous release, and AppVM cold boot, on both Windows 10 and Windows 11:
**90 passed, 0 failed**, with no cell skipped. Plus the notification-error and crop-before-map
feature tests. The installer and ISO were both verified to match the commit they were built from.

Menus on the release build: held 62–297 ms, six of six released on their own terms rather than by
timing out.

## Known and not fixed

- How long a **menu** takes to appear is still unexplained. Measured at 156–547 ms with everything
  else held constant; the probe built to attribute it does not work yet, and that is recorded
  rather than guessed at.
- An application's own paint time is unchanged — an Explorer window still takes about 1.4 s to
  finish assembling, and that is the application, not the transport.
- The guest itself, not the agent, accounts for roughly 560–580 ms of the time a right-click menu
  takes to appear: measured with the agent **stopped**, it was 560 ms, against 582 ms with the
  agent running.
