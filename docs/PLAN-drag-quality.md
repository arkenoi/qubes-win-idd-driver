# Drag quality — what is fixed, what is parked, and what the real fix would be

Status 2026-08-13: the cheap, measured wins are SHIPPED and on by default. The remaining
defect (drag wobble) is PARKED by the user — "the difference is marginal, both suck in a
way, let's record experiment results and put improvement on long term plan, not now".

This file exists so the next session does not re-derive any of it or repeat the failures.

## Shipped and on by default (all measured, all independent of the parked work)

| change | knob | what it fixed | evidence |
|---|---|---|---|
| Freeze window content during a guest drag | `InputDragFreezeContent=1` | Startup stall: `PrintWindow(PW_RENDERFULLCONTENT)` is a synchronous cross-process render that runs in the DRAGGED APP'S UI thread, so the app could not process the mouse messages that move its own window | 193 ms and 211 ms from injected-cursor-moves to window-moves (221 px of cursor travel banked in one case) → **0 ms on four of seven drags** |
| Freeze also OWNS the capture channel | (same) | The capture engine sweeps live channels on its own timer; each sweep is another `PrintWindow` into the app thread. Suppressing only our own recapture left that path open | cold first drag 156–259 ms → "initial okayish" |
| Input drained at input rate while dragging | `DragEventPriority=1` | Jumpiness: the pump drains the vchan only on its own event or at the top of a frame, so motion reached the app in frame-sized clumps and it moved its window once per clump | guest's own window rect advanced only every **54–70 ms in 12–68 px hops** (~16 Hz) |
| Monitor/display-mode cache | `MonInfoCache=1` | Announce-blocking stalls in the tracking pass (`GetRealWindowRect` did DWM + monitor + `EnumDisplaySettings` per window per pass) | 3× interleaved: `upd` p95 3457→1631 µs, `upd` max 40.2→14.6 ms |

## Parked: the wobble, and why it is structural

`gui-daemon` sends **window-relative** motion (`xside.c process_xevent_motion`: `k.x = ev->x`).
The X event also carries `ev->x_root` (absolute) and the daemon does not send it. The agent
must therefore add a window origin back to get an absolute position, and the result is exact
only when that origin equals **dom0's applied window origin** — which lags our announces and
is unobservable during a guest drag (measured: ZERO inbound `MSG_CONFIGURE` in a 5.85 s
latch window; the daemon suppresses the echo when it applies what we asked). Gain-1
correction plus transport lag is a textbook oscillator: **16 % of announces reverse
direction on the good build, 19 % on a regressed one**, amplitude 40–163 px.

Three exact fixes exist. Two are unavailable:

1. **Daemon sends `ev->x_root`** — one line, makes the whole class disappear. FORBIDDEN: the
   user's standing constraint is "no dom0 changes, period".
2. **Freeze dom0's window during the drag** (`InputDragFreeze=1`, implemented, default off) —
   exact, because a frozen reference frame cannot lag. REJECTED by the user: the dom0 window
   then does not move until release.
3. **Predict dom0's applied origin** (`InputDragServo`, implemented, **default off**) — a
   Smith predictor over a timestamped ring of our own announces. Theory is sound (the
   transport delay cancels out of the loop equation; one real pole), simulation gave 1.6 %
   residual reversals vs 43 %. In practice on the guest it failed in BOTH directions:
   applying the reconstruction at full gain produced "crazy extrapolated jumps", and a
   reconstruction that ran ahead collapsed the deviation to zero so the window "just sits
   there". Side by side with it off, the user judged the difference **marginal**.

### If this is picked up again, start here
- The predictor's weakness is the *estimate*, not the control law. Instrument
  `DragAnnounceOriginAt()` against ground truth before tuning anything: log the reconstructed
  origin and, separately, sample where dom0's window actually is (`qtest fullshot` geometry)
  and correlate. Do not tune gain/tau until the reconstruction error is quantified.
- The clamp (`InputDragServoClamp`) was added to stop extrapolation and is discontinuous by
  construction: its bound collapses to 32 px at every direction change, which is a candidate
  for the "chaotic on complex trajectories" report. If revived, make the bound a function of
  recent speed, not the instantaneous per-axis delta.
- A per-axis damped servo distorts curved motion (each axis damped independently). Damp the
  deviation MAGNITUDE and preserve direction instead.
- Whatever is tried, the acceptance measurement already exists and is honest:
  `guest/sample-window-motion.ps1` samples the guest's own cursor and window at 10 ms and is
  retrieved afterwards, so observation cannot perturb the drag. Arm it for several minutes —
  60 s windows repeatedly missed real drags.

## Also parked (measured, not fixed)

- **Cold first drag** still 156–259 ms vs ~0 warm. Remaining suspect is outside the agent
  (DWM waking the window's redirection surface on a cold desktop).
- **Platform floor**: at 5120×1440 the guest composite/frame quantum is ~46 ms vs ~18 ms at
  1920×1080, and announces are slaved to it. The resolution A/B (predicted announce gap p50
  66 → 20–25 ms) was authorised but never run. This is likely the largest single remaining
  factor and it is *not* agent code.
- **`tot_max` did not improve with `MonInfoCache`** (89.6 → 168.2 ms median across 3 runs) and
  is unexplained. Not claimed as a win.
- **Wedged windows**: twice in one day a long-lived Notepad instance ended up rendering its
  own content wrongly *inside the guest* (white body; later content displaced to mid-right),
  proven guest-side and not a capture artefact. A fresh window is always clean. Whether
  hundreds of programmatic moves/renders can wedge an app is unanswered and matters for real
  users.

## Process rules earned here (the expensive ones)

- A generated edit is not applied until it is **grepped in the file**. A knob's registry read
  silently failed to land, so the value was hardcoded and a misbehaving experiment could not
  be switched off — the binary had to be rolled back instead.
- `LogLevel` is read from the **module** key; a stale `gui-agent\LogLevel=3` silently discards
  every `LogDebug` line. Hours of instrumentation went to a file nobody wrote.
- `ProtoTrace=1` multiplies the frame-walk tail (`tot` max 580 ms vs 66 ms off). Never judge
  latency with it on.
- A remote grep echoes the command text back: grepping the OUTPUT for the pattern yields a
  false positive of 1. Count real log lines only.
- Screenshot BEFORE rolling back. Evidence of a visual defect is destroyed by the fix.
