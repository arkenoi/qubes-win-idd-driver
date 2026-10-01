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

## 2. An unoccluded window is copied from the composited desktop - established once, then left alone — ACCEPTED, TO RETIRE (owner, 2026-09-30)

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

**To retire.** This is slicing: the source is the composited desktop picture, which the owner is removing as a
window source entirely (*"i desperately try to fully get rid of it"*, 2026-09-30; see §15). On 26100+ it retires
with §18; the desktop duplication stays only as a damage signal. Below 26100 there is no per-window source that does
not ask the application to paint, so it stays there until the owner decides otherwise.

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

## 18. Every window on 26100+ is captured with WGC through the broker; at rest nothing runs — ACCEPTED, MEASUREMENT OWED

**Decision.** Where `DirectRequired()` holds (26100+, broker enabled, decided at start), every window - ordinary ones
too - is a broker WGC session; broker frames are copied when the broker signals, by WGC's dirty regions; in seamless
mode the desktop image is never copied (its dirty-rect metadata remains the damage/liveness signal); every wait on
both sides is event-driven, with a one-shot deadline only while a request is pending; heartbeats become request
deadlines; a deaf session is recreated once and then fails loudly; registration failures and WGC refusals hold
loudly; the relay is skipped where its destination cannot open; menus come only from their own frame. Below 26100 and
under the explicit opt-out nothing changes. The full design, its stages (S0 instruments, then S1-S5) and its
measurement plan: `docs/DESIGN-rest-zero-capture.md`.

**How it was decided.** Jev first: four premise-framed calls on distilled facts (owner rules R1-R4 as the premise)
decided the forks - WGC for ordinary windows 0.87, broker-event delivery 0.97, dirty regions 0.87, every timed wake
replaced by events 0.92-0.99, request deadlines for hangs 0.97, own-change pokes 0.92, recreate-then-loud 0.77, relay
skip 0.87, the 2026-09-02 concessions retired (drag attribution 0.95, repair tick 1.00, menus from their own frame
0.92). Then one Fable agent wrote the design from those verdicts. Then Jev validated it: no decision rejected; meets
R1-R4 once complete 0.75; reintroduces a 2026-09-02 concession 0.23; ready for S0 0.66; the shutdown "kick window"
rejected (0.66) and replaced by proving every stop path is released by an existing event or process exit.

**Why.** §14 without slicing (§15, §2). This closes the premises that made the 2026-09-02 study settle for
concessions: the broker's FrameArrived is the per-window paint signal a SYSTEM agent could not have, and a WGC frame
costs the application no paint.

**Cost.**
- Capacity (32 slots, 128 MiB committed arena today): OPEN (Jev 0.55 insufficient evidence) until a window census and a
  per-allocation-commit probe; S2 ships measured constants.
- Windows WGC refuses at session creation: OPEN (hold-loudly 0.49 vs retry-on-state-change 0.40) until a capture-target
  probe on 26100.1742 and 26200; hold-loudly first.
- Foreground typing/scroll latency without the desktop copy: measured before any mitigation (a3); proposed bar p50 no
  worse than the candidate by 10 ms - the owner's to confirm.
- A hang at rest surfaces at the next request, not within seconds; a lost wakeup is no longer masked by a timeout
  (every converted wait gets a signal-before-wait test).
- A menu's first paint waits for its own frame (~109 ms first content measured) - accepted by Jev 0.65.
- Builds below 26100: unchanged; whether they change is the owner's decision (d7).

## 19. Rest-zero S3/S4 as built: the choices the design left open, and one it got wrong — ACCEPTED (Jev), MEASUREMENT IN PROGRESS

Recorded while implementing §18's stages S3 (own-change pokes, deaf hold, no PrintWindow backstop) and S4 (no timed
wake on either side), 2026-10-01. Each changes what fails, and how loudly.

- **A quiet WGC session that has delivered is recreated, every time; DEAF only when a fresh session delivers nothing.**
  This REPLACES design E's "recreate once, then deaf". Measured on w11-ds the same day: a system menu opened over a
  focused Notepad - its drawing, its appearance, its drop shadow - poked Notepad 273 times; WGC correctly delivered
  nothing (Notepad had not changed); Notepad had already used its one recreate at startup, so E declared the healthy
  window deaf and froze it (QGAWGCDEAF). DDA's dirty rects are coarser than a window's own change, so any poke-based
  deafness detector sees false pokes; a recreate makes one cost a session open and a frame, a freeze makes it cost the
  window. Jev: both this and the occluder fix below, 0.64 (keep E 0.01); recreates at rest 0.21 (there are no pokes at
  rest), recreates every ~2 s under content WGC misses 0.79, acceptable 0.62. Every recreate is said (QGAWGCRECREATE).
- **For a WGC slot every window above counts as an occluder for its poke, a popup with a 24 px shadow margin.** Its
  poke is only a liveness hint. A PrintWindow slot (a menu) keeps the opaque-only rule: there the poke is the render
  trigger, and a change beneath a translucent popup must render.
- **Requests are acknowledged by sequence.** The broker writes `CtlAck` = the ControlSeq its main loop last handled per
  slot; the agent's hang deadline (2 s) and its arena reclaim key on it. E's "AckState leaves REQUESTED" would have read
  a PrintWindow popup whose first render is black as a hung broker.
- **The agent's death reaches the helpers through a mutex it owns.** The broker and the notification bridge run with
  the interactive user's limited token, denied SYNCHRONIZE on the SYSTEM agent; they relied on a heartbeat and a pid
  poll. The agent's main thread owns a nonce-named mutex per helper for its life; abandoned = the agent died.
- **The relay capability is probed at the first ladder descent, not at process start** (§18/G said "at start"): the
  agent tells a broker window from a user window only by the broker's validated pid, and a destination-shaped window
  from a broker not yet validated was measured (2026-09-26) to be mapped to dom0.
- **A PrintWindow popup's first frame is retried at 0/50/100/200/400 ms after its open**, then only its own pokes render
  it: a popup rendered before it painted comes back black, and its own paint can land in the pass the agent attributes
  to its appearance. Bounded; armed by the open, ended by the first published frame.
- **The diagnostic signature of a burst's last frame keeps a one-shot 500 ms deadline** armed by the burst; without it a
  static window's published signature stays on the frame before its last change (measured 2026-09-27).
- **A measured SAME on a relay's source answers its pending poke** (26200); left pending, the quiet test re-ran a source
  PrintWindow every 0.5-8 s for as long as nothing changed.
- **Held maps on 26100+ get one deadline per window** (the crop ceiling, then the declaration once both graces end), not
  a 32/100 ms re-check; a consumed frame and a completed crop measurement queue that window for the tracking pass.
- **A busy broker is not a hung one.** The hang deadline (2 s without an ack) also requires the broker's progress counter
  (`BrokerProgress`, bumped at every call it starts or finishes) not to have moved: a fresh broker opening eight sessions
  in one pass was reaped as hung (measured). Jev: fixes it 0.94, still detects a real hang 0.94 - confirmed by
  suspending the broker: QGABROKERHUNG 2 s after the next request, reaped, back in 594 ms.
- **The notification bridge lists on the ETW proxy's records, not on a clock.** On 26100.1742 NotificationChanged throws
  for the unpackaged bridge, which therefore listed the Notification Center every 2 s for ever (~25 wakes/s, the last
  rest load of the stack). The notification database is NOT written when a toast arrives on that build (wpndatabase.db-wal
  untouched across 10 toasts), so a file-watch push saw none of them - with it alone an allowlisted app's toast would
  have been banner-suppressed and never forwarded. The ETW tier's proxy delivered every toast's records within the
  second. Jev (re-asked with that measurement): ETW push 0.73; verify every toast listed promptly and a dead proxy falling
  back loudly to the 2 s floor (both 0.77).

**Measured so far (S3/S4b, w11-ds 26100.1742, "burn scene" - NOT the burn scene: no Terminal, no Paint, see the §20 correction; 3 interleaved arms each with the agent-stopped floor):** the
broker's wakes at rest fell from ~6/s to 0-9 per 60 s (an Explorer window that repaints itself ~1/15 s accounts for
them); its CPU 0; our family CPU 0.31-0.41% of a core vs 0.03-0.08% for the floor, all of it the notification bridge
(S4c); every window's delivered frame matched the guest's own render (MAD <= 1.5/255). Still open: the bridge (a
system-started thread inside it wakes ~20.7/s; its 30 s listing floor), and the false-deafness fix above, built, not
yet re-measured.

## 20. Rest-zero S2 and the three loops the acceptance found — ACCEPTED (Jev), MEASURED 2026-10-01

Recorded while running the rest-zero acceptance passes rz2-rz3b on w11-ds (26100.1742, burn scene), 2026-10-01. The
instruments that found these are in §19's measurement plan; each fix was reviewed by Jev before commit.

**CORRECTED 2026-10-01: "the burn scene" in this section and in §19 was NOT the burn scene.** Every pass from rz1 to rz7
ran on 2 Notepad 3816x1004, Settings, the quiet Explorer folder, two shell "File Explorer" windows and two "Location is
not available" error dialogs. The two Windows Terminals and Paint that the scene names never opened, and nothing said so:
the launches threw nothing, and the harness only counted windows (>= 7), so the dialogs and stray Explorer windows made
up the number. This had been RECORDED on 2026-09-30 (findings/issues.md, the DWM P1: "the opener must assert what it
opened") and was not acted on until the owner asked whether Paint was there. The rest results below therefore cover
Notepad, Settings (a UWP frame), Explorer and the dialogs. **They do not cover Terminal or Paint**, which draw through
their own swap chains rather than GDI. Re-measurement is pending on a scene opener that checks every intended window by
class and owning process, and fails on anything else.

- **On 26100+ in seamless nothing is copied out of the desktop image (S2, as designed).** The capture thread copied every
  desktop frame into the staging buffer although no window took a pixel from it (QGACOMPOSITECOPY 0 over whole runs).
  It now copies only while window 0 shows the desktop (non-seamless, or on its way there); otherwise a desktop frame is a
  damage signal with no framebuffer at all, and the buffer is refilled whole - on any next frame, delivered even with no
  dirty rects, whole-screen damage - when window 0 wants it again. A non-seamless entry asks Windows for that frame with
  one asynchronous RedrawWindow of every window: measured, it made desktop duplication deliver 44 and 29 frames against 0
  and 0 for the same launch without it. A fence on each side keeps a skip racing an entry from losing both.
  **Found by the acceptance, not the review:** a broker frame was clipped to the published image's size, now 0 - every
  window stayed black and was declared (8 of 8, rz3). The S2 audit had listed the image pointer's readers and not its
  dimensions'. A broker frame is clipped to the screen now. rz3b: QGADESKCOPY off on every agent start, never on;
  QGACOMPOSITECOPY 0; every window's delivered frame matched the guest's render (MAD <= 1.6/255).
- **A PrintWindow slot's own render is not a change.** Rendering a window makes Windows present it again with the same
  pixels - a desktop dirty rect, a poke, the next render. A held, untouched system menu looped at ~11 renders and ~46
  desktop frames a second at rest (rz2); with the broker merely suspended, 0. Both PrintWindow paths echo (WM_PRINT: one
  present per render; PW_RENDERFULLCONTENT: more). The damage poke on a PrintWindow slot now carries a signature of the
  window's on-screen pixels for that frame (the desktop surface mapped READ-ONLY for the frame being processed - DDA stays
  a damage signal, nothing copied, nothing sent) and pokes only if they changed; input pokes are unchanged. Jev chose this
  over "converge, then input only" (0.80 vs 0.16: async content such as a suggestion list filling must still render).
  rz3b: the held menu, navigated three times, rendered 4 times (fid 4) and was then silent - capture, main and broker 0.
- **A WGC arrival whose card equals the published one is not republished** (the same rule on the WGC path; ABI 20 counts
  them as SameFrames). Only in steady state: an arrival answering a registration is published whatever it holds, and the
  broker's quiet/deaf test keys on arrivals, not publishes. Jev: fits the rule 0.84, registration-safe 0.91.
- **The notification bridge's database watcher is not a listing trigger.** A listing is served from the database the
  watcher watches, so a watcher-triggered listing can re-trigger itself; on this build the watcher never fired for a toast
  arrival anyway. Removing the trigger did NOT remove the toast-tail load (next item), so it was not that load's cause.
- **The bridge lists for a notification id it has not seen, not for every ETW record.** In the ~90 s after a toast burst
  every record named a toast already listed (or none) and each cost a full listing plus two retries; a listing works a
  system thread inside the bridge (start shcore.dll+0x259c0) hundreds of times - 3500-9900 wakes per 20 s, while a process
  merely HOLDING a listener woke 0 times in the same tail (so the platform does not push; our listings were the cost).
  An ETW dump of a burst shows every toast's arrival carrying its own id in 5+ events, the same numbers as the listener's.
  An id-bearing record now queues its id; the main loop lists only if one is unseen; an id-less record lists only until
  the first id ever arrives. Jev: this rule 0.97. Measured (rz5): the tail went from 7475-9358 bridge switches to 21 in
  40 s, the shcore thread silent, all 10 toasts still listed (<= 1.8 s), the proxy-down toasts 2/2.
- **S5 is moot on 26100+.** Synthesis needs an owner that is not slice-fed, and every window there is; a menu is its own
  override-redirect window on a PrintWindow slot, whose rest behaviour is the pixel-checked poke above.

**Measured, rz3b (build 362b761):** at rest, per minute, the agent wakes 8-24 times (main and hooks, following the
guest's window events and one Explorer window's 10-15 frames a minute; capture 0), the broker 0-3, the bridge 0-2, the
ETW proxy 0; our family CPU 0.00 in every arm, attributed CPU (DWM + ours) 0.00-0.03 against the agent-stopped floor's
0.03-0.05, five arms interleaved with three floors. Toasts 10/10 listed within 1.2 s;
with the ETW proxy killed the bridge said so and recovered in 7 s (2/2 listed). Hangs: the broker hung and asked is
reaped in 2 s (back in 625 ms), hung and not asked is left alone (by design); the agent hung while a window published
moved the broker's AgentStalls. **rz5 (cf46ea0, the quiet-folder scene, ABI 21 wake counters):** in three of four rest
samples the agent's named threads (main, hooks, capture, toastcrop) woke 0 times (2-4 switches of a pool thread remain),
broker 0-2, bridge 0-2, proxy 0; the main loop's wakes between two peeks were all window events (the instrument's own
PowerShell windows) - deadline 0, desktop frame 0, broker frame 0 - and five consecutive decay minutes ended at 0/0/0/0.
