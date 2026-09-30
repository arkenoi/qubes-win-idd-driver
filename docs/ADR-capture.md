# ADR — window content capture (the agent's PrintWindow engine and the WGC broker)

**Status: per section** — ACCEPTED (built and in force), PROPOSED (written down to be judged before it is
built), OPEN (a tradeoff that is the owner's to decide), REJECTED (kept so that it is not tried again).

This file records DECISIONS about where a guest window's pixels come from and when the agent asks an
application to paint. It is not a status report: what a guest measured on a given day belongs in `findings/`,
and the mechanism lives in the design notes and the code headers.

| record | content |
|---|---|
| `DESIGN-per-window-capture.md` | per-window buffers; Gate 0 (PrintWindow returns an occluded window's content) |
| `DESIGN-pure-per-window.md` | the per-window model; the classes PrintWindow cannot render |
| `DESIGN-wgc-broker.md` | the user-session WGC broker: slots, routes, IPC |
| `agent/gui-agent/wincapture.cpp` (header comment) | the PrintWindow engine as built: service loop, sweep, echo guard |
| `findings/issues.md` | open defects, and the measurements quoted here |

Rules for editing this file: add or change a section only when a DECISION changes. Write every tradeoff with
its cost and a bound - a cost that cannot be written down with a bound is not understood yet, and a bad
tradeoff is easiest to see once it is written out. Every section is classified by Jev (`tools/jev.py`) and the
verdict is recorded in it; a PROPOSED section is not built before its verdict.

---

## 1. The pixel source is chosen per window class; capabilities are decided at start — ACCEPTED

**Decision.** Every tracked window gets one pixel source, chosen by its class (`PwWindowClassify`) and by
capabilities latched once at agent Init:
- an ordinary window: the agent's own PrintWindow engine, or the composited desktop while it is unoccluded (§2);
- a window PrintWindow cannot render correctly from the agent's context - override-redirect popups,
  `WS_EX_NOREDIRECTIONBITMAP` windows (UWP frames, toasts, Windows Terminal), per-pixel-alpha and colour-key
  layered windows: on build 26100 and later the user-session WGC broker (§12), below that slices of the
  composited desktop.

The broker is eligible on build 26100+ unless qubesdb switches it off, and eligibility is never re-read at
runtime. A broker that was working and stops is a FAILURE, reported loudly - never a capability change.

**Why.** The agent runs as SYSTEM, where `Windows.Graphics.Capture` refuses (`IsSupported` threw `0x80070424`
in the service context, measured 2026-09-02); the interactive user's session can use it, hence a broker there.
A capability re-read at runtime turns a failure into a silent mode change.

**Jev 2026-09-30.** accept 0.79, accept-measure-owed 0.19; cost bounded 0.09; conflicts with the owner's direction 0.11; a user-visible regression possible 0.71.

## 2. An unoccluded window is copied from the composited desktop - established once, then left alone — ACCEPTED

**Decision.** While a window is unoccluded and otherwise eligible (`PwDdaEligible`: not moving, geometry
matches, fully on screen, not layered, nothing tracked above it), its damaged sub-rects are copied from the
desktop duplication frame. Entering that mode costs ONE PrintWindow, which establishes the buffer; nothing
re-renders the window while it stays eligible - there is no periodic PrintWindow "to correct" differences
between the two sources.

**Why.** PrintWindow on the typing path cost 50-76 ms per frame; a periodic re-verify turned a static
difference between the two sources into a visible content swap at about 0.5 Hz (agent e97edb8).

**Cost.** A difference between the sources (alpha byte, Windows 11 rounded corners) persists as a one-time
transition instead of being corrected.

**Jev 2026-09-30.** accept 0.83, accept-measure-owed 0.16; cost bounded 0.31; conflicts with the owner's direction 0.09; a user-visible regression possible 0.73.

## 3. A partly covered window is captured whole - never a mixed buffer — ACCEPTED

**Decision.** A window that anything tracked above it overlaps is captured with one whole-window PrintWindow
whenever its own visible pixels change (§5). Its visible part is never taken from the desktop while its covered
part comes from elsewhere.

**Why.** The covered part has no change signal: dirty rects there belong to the window on top. A mixed buffer's
two halves age independently, and dom0 may be showing the covered half (§7).

**Cost.** Every change in the visible part costs a whole-window PrintWindow on the application's own UI thread
(32-438 ms measured per call on this rig), and for an application that repaints when asked to paint, that
PrintWindow is itself a change (§8).

**Jev 2026-09-30.** accept 0.77, accept-measure-owed 0.14; cost bounded 0.95; conflicts with the owner's direction 0.12; a user-visible regression possible 0.79.

## 4. No TIMED PrintWindow — ACCEPTED (owner, 2026-09-30)

**Decision.** The owner: *"but no TIMED PrintWindow. if it is event driven it is not that bad"*. PrintWindow
runs only because something happened to THAT window - its first capture, a change in its own visible pixels
(§5), the settle after a move or drag, a change the echo guard held back (§11) - never because a timer fired.

**Why.** A PrintWindow runs on the captured application's UI thread whether or not anything changed, and some
applications repaint because they were asked to paint (§8), so a timed render is also a source of damage.

**Consequence.** The timed renders that exist are defects to retire:
- the engine's round-robin sweep (`wincapture.cpp`: one window per 250 ms slot; a window that keeps coming back
  unchanged backs off to one sweep per 2 s);
- the broker's backstop render on its PrintWindow route (every `WGCBRK_POKE_SAFETY_MS` = 1 s, doubling to
  `WGCBRK_POKE_BACKOFF_MAX_MS` = 8 s while its renders publish nothing);
- the broker's relay source measurement: a PrintWindow that repeats (500 ms, doubling to 8 s) for as long as a
  poke on a relay stays unanswered - anchored to an event, but a timer once it has started.

The one real job these do - content that has no change signal - is §7, which is OPEN.

**Jev 2026-09-30.** accept 0.70, accept-measure-owed 0.21; cost bounded 0.62; conflicts with the owner's direction 0.20; a user-visible regression possible 0.86.

## 5. A window's change is a change of its OWN visible pixels — ACCEPTED

**Decision.** Desktop damage marks a window only if the window's own uncovered pixels changed:
`PwScreenUnchanged` hashes the spans that nothing tracked above covers, and a window whose ordering is unknown
counts as changed. For a broker window, damage confined to its outer 2-pixel border, or lying wholly inside one
opaque window stacked above it, does not poke it (agent 7f3f248, c21d6fd).

**Why.** Damage under a window above belongs to that window. Attributing it to the window beneath made 113-116
of 117-119 Explorer captures find nothing (2026-09-24), and poked a healthy WGC session into demotion
(2026-09-30).

**Cost.** A window whose ordering cannot be described (no capture-grade z-order, or more than 16 occluders) is
treated as changed by any damage that touches it.

**Jev 2026-09-30.** accept 0.76, accept-measure-owed 0.22; cost bounded 0.83; conflicts with the owner's direction 0.10; a user-visible regression possible 0.73.

## 6. Guest stacking follows dom0 only through focus — ACCEPTED (a protocol fact the design must carry)

**Decision.** The agent aligns guest stacking with dom0 only when dom0 focuses a window (`MSG_FOCUS` ->
`SetForegroundWindow`, plus `BringWindowToTop` behind the `FocusRaise` switch). It never infers dom0's stacking
otherwise.

**Why.** The GUI protocol has no restack message; anything touching it needs a design writeup and upstream
review first (CLAUDE.md). The focused window is on top in both, which is what the unoccluded path (§2) serves.

**Cost.** Stacking can differ: a guest window that is topmost in the guest, an application that activates
itself, a dom0 window manager that focuses without raising. Where it differs, dom0 shows pixels that the guest
covers - see §7.

**Jev 2026-09-30.** accept 0.60, accept-measure-owed 0.34; cost bounded 0.09; conflicts with the owner's direction 0.10; a user-visible regression possible 0.77.

## 7. Content dom0 shows but the guest covers — OPEN (the owner's call)

**The problem.** Where stacking differs (§6), dom0 shows part of a window that is covered in the guest. That
part makes no desktop damage, so nothing event-driven sees it change. Today the sweep (§4) refreshes it: at
best every 250 ms, at worst every 2 s or one 250 ms slot per swept window, whichever is longer.

**Options.**
- (a) WGC through the broker for covered ordinary windows on 26100+: arrival-driven, no cost on the
  application's UI thread, no echo. Costs: broker slots (32, shared with §1's classes), a WGC session and
  broker memory per covered window. Below 26100 it changes nothing.
- (b) Refresh on uncover only: uncovering makes damage in the guest, and the window is captured then. Stale in
  dom0 for as long as stacking differs and that part keeps changing.
- (c) Keep a timed sweep for covered windows: violates §4.

**Recommendation.** (a) on 26100+. Below 26100 the sweep stays until the owner answers the question put on
2026-09-30 (there is no per-window change event there: no broker, and SYSTEM cannot use WGC).

**Jev 2026-09-30.** accept-measure-owed 0.54, owner-decision 0.38; cost bounded 0.56; conflicts with the owner's direction 0.33; a user-visible regression possible 0.69.

## 8. Some applications repaint because they were asked to paint — ACCEPTED (a measured fact the design must carry)

**Decision.** The engine treats its own PrintWindow as a possible CAUSE of damage, never as a neutral read.

**Why.** Measured on w11-ds (26100.1742), with no agent running: a bare PrintWindow loop on a Windows 11
Notepad made DWM report its whole visible area dirty about 4 times per call. With our agent, the agent's own
hash of that Notepad's visible desktop pixels had changed before every capture it requested in the burn
window (per-minute counters: capture decisions = hash changes) - so the repaint changes the pixels on screen,
at least while it is drawn. NOT MEASURED: whether it settles back to the same picture (a flicker sampled
mid-repaint) or leaves different pixels. (An earlier wording here, "a 19x18 px element changing each time", read a
dirty rect as a pixel change; a dirty rect only says an area was re-presented.) A repaint of identical pixels is
not a change - the detector compares pixels (§5) - so only a repaint that changes them can feed a loop. With our agent, two overlapping Notepads kept the engine re-rendering them about 15 times a second for
about 29 minutes after they opened - DWM, the agent and the Notepads at about 150% of one core, on a desktop
nobody touched.

**Jev 2026-09-30.** accept 0.85, accept-measure-owed 0.14; cost bounded 0.45; conflicts with the owner's direction 0.09; a user-visible regression possible 0.54.

## 9. The echo guard — ACCEPTED, PROVISIONAL (its main cost is not measured)

**Decision (agent 78e925e, 45aeedb).** A mark that arrives while we are capturing that window, or within
`WC_ECHO_MS` (250 ms) of that capture's return, is treated as the ECHO of our own render. Three echoes in a row
pause the window's captures for 1 s, doubling to 4 s while pauses pass quietly; a mark outside that window ends
the pause. An echo that lands while the window is paused is DROPPED.

**Why.** §8. The guard cut the attributed CPU of that scene about 4x (3+3 interleaved A/B, disjoint ranges,
2026-09-30).

**Cost - written out, because this is the tradeoff.** The guard cannot tell "this window changed because we
rendered it" from "this window changes all the time". A window that animates on its own while partly covered is
captured in bursts of three and then not at all until `WC_ECHO_MS` after the last capture: at most one capture
per (capture time + 250 ms), against one per capture time without the guard. A 20 Hz animation that costs 10 ms
to capture would reach dom0 at about 8 updates a second instead of 20 - DERIVED, NOT MEASURED. And a genuine
change that lands inside the echo window just as a pause starts is dropped; only the next capture of that window
delivers it, and today that capture is the sweep, which §4 retires (§11).

**Owed.** The throttle on a self-animating, partly covered window, measured against a build without the guard.

**Jev 2026-09-30.** accept-measure-owed 1.00; cost bounded 0.93; conflicts with the owner's direction 0.26; a user-visible regression possible 0.93.

## 10. Widen the echo window to 500 ms — PROPOSED

**Proposal.** `WC_ECHO_MS` 250 -> 500.

**Why.** Of 21 changes that ended a Notepad's echo pause (w11-ds, 2026-09-30), 8 came 265-468 ms after our own
capture of that window: the tail of our own render.

**Cost.** §9's throttle doubles: a self-animating partly covered window drops to one capture per (capture time +
500 ms), and more genuine changes are classed as echoes and held back.

**Jev 2026-09-30.** accept-measure-owed 0.75, reject 0.21; cost bounded 0.80; conflicts with the owner's direction 0.19; a user-visible regression possible 0.90.

## 11. Stop sweeping windows that have visible pixels, and serve a held-back change when its pause ends — PROPOSED

**Proposal.**
- (a) The sweep skips a window with any pixel visible on the guest desktop, from the capture-grade z-order;
  with no usable ordering the window counts as not visible and is swept as before.
- (b) When an echo pause ends and a mark was dropped during it, the window is captured once.

**Why.** §4: a visible window's changes arrive as desktop damage, so its sweep is a timed render and nothing
else. (b) is required by (a): the sweep is what delivered a change dropped at the start of a pause (§9), and
without it that change stays lost until the window changes again.

**Cost.**
- The covered part of a partly visible window is refreshed only when its visible part changes or when it is
  uncovered: stale where dom0 shows it (§7).
- An application that echoes gets one capture per pause period (at most 4 s) for as long as it stays open. It is
  triggered by its own echo, so it is an event-anchored loop that behaves like a 0.25 Hz timer. The sweep
  delivered the same captures before.
- Windows with no visible pixel are still swept: (a) alone does not meet §4.

**Jev 2026-09-30.** accept-measure-owed 0.55, accept 0.20; cost bounded 0.80; conflicts with the owner's direction 0.35; a user-visible regression possible 0.87.

## 12. UWP frame windows are captured with WGC on the frame itself — ACCEPTED

**Decision (wgcbroker c661f08, 4ada067).** An `ApplicationFrameWindow` is captured with a WGC session on the
frame window itself. The broker's quiet ladder (WGC -> relay -> PrintWindow) demotes a session only when damage
the agent saw stays unanswered for `WGCBRK_WGC_QUIET_MS` (2 s), counted from the first unanswered poke.

**Why.** WGC is arrival-driven: nothing renders while nothing changes. The earlier up-front re-route to
relay/PrintWindow rested on a misreading, and a quiet test timed from the last frame demoted every WGC session
at its next change.

**Measured.** Settings stayed on WGC 6 of 6 times with the binaries swapped in, 6 of 6 installed from the release
package on 26100.1742, and 6 of 6 on German 26200. Idle: 0 renders, against 288 renders in 20 s with DWM at
47-53% of a core on the PrintWindow route.

**Jev 2026-09-30.** accept 0.69, accept-measure-owed 0.30; cost bounded 0.36; conflicts with the owner's direction 0.23; a user-visible regression possible 0.59.

## 13. Keep the echo escalation for 10 s after a pause — REJECTED

**Proposal (agent c274a51).** A genuine change during an echo episode ends the pause but keeps the escalation
for 10 s after the last pause.

**Why rejected.** No measurable effect in a 3+3 interleaved A/B on the same scene; reverted (agent 301cf6f).

**Jev 2026-09-30.** reject 0.84, accept 0.06; cost bounded 0.18; conflicts with the owner's direction 0.19; a user-visible regression possible 0.55.

## 14. At rest, zero work — ACCEPTED (owner, 2026-09-30)

**Decision.** The owner: *"idle load should GO, not just be reduced"*, *"anything pause-driven is meh. avoid
whenever possible"*, *"change does not occur on idle desktop"*, and *"while window moves you can do whatever
fuck you want. i want zero idle polls while it is stopped and no pixel changes."* When no window moves and no
pixel changes, the agent and the broker do NOTHING: no PrintWindow, no thread woken by a timer, no heartbeat.
Every wait is on an event, or on a deadline that exists only while work is pending. While a window moves,
anything goes, including timers, dwells and PrintWindow.

**Why.** On a desktop at rest nothing changes, so every cost measured there is our own: a timer acting without
a change, or a PrintWindow manufacturing the change it then reacts to (§8). Reducing it - the echo guard cut it
about 4x (§9) - leaves a desktop that is never at rest while our agent runs. The bar is the agent-stopped floor.

**Consequence - what wakes today at rest, and must not.** Measured by reading the code, 2026-09-30:
- the agent's desktop-duplication thread: `AcquireNextFrame` with a 1 s timeout, and a stale-grant sweep on
  every pass (1/s);
- the capture engine's worker: waits of at most 250 ms for the sweep (4/s), plus the sweep's PrintWindows;
- the agent's main loop: a 1 s timeout whenever the broker or the notification bridge is up (1/s);
- the broker's main loop: 250 ms, or 33 ms while any window is on its PrintWindow route (4/s or 30/s); agent and
  broker heartbeats (each gives up after 10 s of silence); input-desktop and console-session polls;
- the broker's backstop render (§4) and the echo loop (§8) wherever PrintWindow serves a window at rest.

**Bound.** None at rest: zero wakeups, zero PrintWindow. Measured as per-thread context switches of our
processes and DWM CPU on a static multi-window desktop, against the same desktop with our agent stopped.

**Jev 2026-09-30.** accept-measure-owed 0.50, accept 0.47; cost bounded 0.72; conflicts with the owner's direction 0.14; a user-visible regression possible 0.58.

## 15. A window at rest is copied from the desktop, whatever covers it; PrintWindow only establishes — REJECTED (owner, 2026-09-30)

**Proposal.** Supersedes §3, §10 and §11. A window that is not moving, and that nothing moving overlaps, takes
its changes from the desktop duplication frame: every damaged sub-rect, minus the rectangles of the tracked
windows above it, is copied into its buffer - the §2 path, clipped by occlusion instead of refused by it. The
change detector already reads exactly those pixels (§5); nothing asks the application to paint. PrintWindow runs
only to establish a buffer: first capture, a resize, and the settle after motion (§14 allows anything then),
which also brings the covered part up to date.

**Why.** §14. A read that does not perturb the application gives an idle desktop nothing to react to: a Windows
11 Notepad's repaint after the settle PrintWindow is copied from the desktop once and the desktop is at rest
again - no loop, no guard, no pause. The skew that made §3 reject mixed buffers (the window list newer than the
frame, so an occluder that just moved leaks its pixels into the window below) exists only while something
moves, and §14 hands motion to PrintWindow.

**Cost.**
- The covered part of a window at rest is as old as its last establish or its last uncovering: stale in dom0
  wherever dom0 shows it (§6, §7). Today it is refreshed by the next whole-window PrintWindow or the sweep.
- A window above casts its shadow onto the one below, and the desktop holds the shadow: the copy bakes it in, as
  §2 already does for a window beside one above it. A translucent window above (layered, not opaque) is treated
  as covering.
- A window that cannot be copied at all (translucent itself, off the desktop) stays on PrintWindow, and an
  application whose repaint changes its visible pixels (even only while it is drawn) would loop there - it must show up in §14's measurement and be moved to a
  non-perturbing source (WGC, §7a), never guarded with a pause.

**Jev 2026-09-30.** accept-measure-owed 0.90; cost bounded 0.15; conflicts with the owner's direction 0.23; a user-visible regression possible 0.83.

**Why rejected.** The owner: *"desktop-copy is slicing in disguise, right?"* / *"the exact design we tried to
retire?"* It is. The source is the composited desktop picture - what slicing used, and what the de-slice retired
as a window source. Cutting around the windows above removes only the most visible artifact of that source; the
copy still carries the composite's others (the shadow a window above casts, what shows behind rounded corners, the
window list being newer than the picture). Written down here so it is not proposed again; the non-slicing route to
§14 is §18. Built as agent 2b47ae3 on experiment branch `rest-zero` and never measured.

## 16. The echo guard is retired — PROPOSED

**Proposal.** Remove §9's guard once §15 holds.

**Why.** §14: it is pause-driven, and it cannot tell an echo from a window that animates on its own (§9), so
it throttles the latter. With §15 no stationary window is captured with PrintWindow because it changed, so
nothing echoes into the capture path.

**Cost.** Any window still captured with PrintWindow at rest (§15, last point) loses its only protection
against an echo loop; §14's measurement is what finds one.

**Jev 2026-09-30.** accept-measure-owed 0.97; cost bounded 0.12; conflicts with the owner's direction 0.17; a user-visible regression possible 0.81.

## 17. Liveness from process handles and system notifications, not heartbeats — PROPOSED

**Proposal.** The agent and the broker watch each other through process handles only; the broker learns of an
input-desktop switch and a console-session change from system notifications (`EVENT_SYSTEM_DESKTOPSWITCH`,
`WTSRegisterSessionNotification`), not by polling. The desktop-duplication thread waits without a timeout and
is stopped by an event of its own; the stale-grant sweep, the arena reap and every other deferred job arm a
one-shot deadline only while they have work.

**Why.** §14. A heartbeat is a timer on both sides; a process handle signals the exit it exists to detect.

**Cost.** A process that is alive but hung is no longer noticed by its peer: the broker keeps serving a hung
agent (it is idle then), and the agent's existing broker stage/hang diagnostics become the only record.

**Jev 2026-09-30.** accept-measure-owed 0.84, owner-decision 0.06; cost bounded 0.27; conflicts with the owner's direction 0.14; a user-visible regression possible 0.58.

## 18. Every ordinary window on 26100+ is captured with WGC through the broker — PROPOSED

**Proposal.** On build 26100 and later, where the broker is eligible (§1), an ordinary window gets a broker WGC
session like the classes §1 already sends there, and its buffer is filled from the broker's frames. On those builds
the composited desktop stops being a window source altogether: §2's desktop copy retires there as the de-slice
retired the cut-outs. PrintWindow stays only where WGC refuses a window or the broker is down. Below 26100 (no
broker) nothing changes.

**Why.** §14 without slicing (§15). WGC hands over the window's own surface: an application is never asked to paint
(no echo, no storm, no guard, no pause); a frame arrives only when that window's content changed (nothing at rest);
no other window's pixels or shadows are in it; and a covered window's content stays live, which closes §7 on the
target builds.

**Cost.**
- Capacity: 32 broker slots, shared with menus, toasts and the other classes; a pixel arena budgeted at 128 MB,
  which two maximized windows at 5120x1440 (29.5 MB per buffer, two buffers each) nearly fill. Both must grow, or
  the overflow needs a policy.
- 26100.1742's WGC refuses some windows when a session is created (E_INVALIDARG, measured for disabled, tool and
  no-activate windows as relay destinations; not yet measured as capture targets). Those need a fallback, and the
  only other own-content source is PrintWindow, with its echo.
- WGC sessions have gone deaf after a cold boot (the de-slice census); the quiet ladder's last rung is the
  broker's PrintWindow route, whose backstop render is itself a timer (§4).
- The agent copies the whole window per broker frame (the slice-fed path), not only the changed rows: more copying
  per change than a desktop copy, nothing at rest.
- The agent picks broker frames up in its desktop frame loop, which runs only when the desktop changes or its 1 s
  timeout fires: a covered window's frame needs its own wake-up from the broker, the same work §17 needs.
- Typing latency on the foreground window moves from the desktop copy (§2) to WGC arrival plus two copies: not
  measured.

**Jev 2026-09-30.** accept-measure-owed 0.93, owner-decision 0.03; cost bounded 0.46; conflicts with the owner's direction 0.39; a user-visible regression possible 0.86.
