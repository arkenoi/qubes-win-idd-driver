# FINDINGS — index

The record lives in `findings/<topic>.md`. **Each file is a CURRENT STATE head and nothing
else** — the 25k-line chronological log was split by topic on 2026-09-01 and its dated
histories were amputated the same day (owner call): the log format itself caused
stale-first reads and contaminated sessions. Git history retains the old log for
deliberate forensics only; do not load it into context.

| topic | file |
|---|---|
| appmenus | [`findings/appmenus.md`](findings/appmenus.md) |
| autologon | [`findings/autologon.md`](findings/autologon.md) |
| capture | [`findings/capture.md`](findings/capture.md) |
| console | [`findings/console.md`](findings/console.md) |
| drag | [`findings/drag.md`](findings/drag.md) |
| idd | [`findings/idd.md`](findings/idd.md) |
| **issues (prioritized, by tag)** | [`findings/issues.md`](findings/issues.md) |
| install | [`findings/install.md`](findings/install.md) |
| misc | [`findings/misc.md`](findings/misc.md) |
| network | [`findings/network.md`](findings/network.md) |
| protocol | [`findings/protocol.md`](findings/protocol.md) |
| qrexec | [`findings/qrexec.md`](findings/qrexec.md) |
| rig | [`findings/rig.md`](findings/rig.md) |
| updates | [`findings/updates.md`](findings/updates.md) |
| wedge | [`findings/wedge.md`](findings/wedge.md) |
| windowing | [`findings/windowing.md`](findings/windowing.md) |

## Rules (enforced by tools/lint-harness.py and .githooks/pre-commit, not by good intentions)

1. Every `findings/*.md` is a `## CURRENT STATE` block ONLY. Dated `## YYYY-MM-DD` sections
   are refused at commit time — new information goes into the bullets, in place.
2. Every bullet carries `[verified <date>]` or `UNVERIFIED`.
3. This file holds the index and nothing else.
4. A correction EDITS or DELETES the wrong bullet — it does not append a counter-claim.

## 2026-09-23 - a new window was announced only after the application rendered it

**Symptom (owner):** "when a new window appears, it is visible how components are drawn";
Explorer slow, Notepad fine. On win11.

**Root cause, measured:** the whole CREATE->MAP delay - the time before dom0 can display a new
window at all - was one call: the synchronous `WcPrefill` (PrintWindow) that ran in
`PwAttachWindowCarry` *before* `SendWindowMap`. PrintWindow is serviced on the **target
application's UI thread**, so the agent held the announce hostage to how busy that application
happened to be. A new `PWATTACH` probe timed every call in the path:

| run | slab | WcAddWindow | **WcPrefill** | SendWindowDump | total |
|---|---|---|---|---|---|
| 1 | 15 | 0 | **438** | 0 | 453 |
| 2 | 0  | 0 | **32**  | 0 | 32  |
| 3 | 0  | 0 | **329** | 0 | 329 |

`total` equalled the independently measured CREATE->MAP in every run. Everything except the
prefill is 0-15 ms.

**It was not buying what it cost.** A window is prefilled at *creation* time, before the app has
painted, so the prefilled frame was superseded immediately: a full-window damage went out in the
same millisecond as MAP and painting continued for another 1.5-4.3 s. Jev: "the prefill earns its
cost" **0.22**.

**Fix** (agent `82b3976`): for a genuinely new window the first capture moves to the engine thread,
which does the same PrintWindow and already owns the diff-and-report path; `WcMarkDirty` wakes it
immediately, and the mark is issued *after* `SendWindowDump` so damage never names a buffer the
daemon does not know. Two cases keep the synchronous prefill, because there the pixels already
exist and the slab is zeroed: a **rebuild** (`PwResizeWindow`, `carry != NULL`) - this prefill *is*
the carry mechanism for a PrintWindow-captured window, and dropping it would reinstate the
2026-09-13 black blink - and a **pre-existing** window (new `PwPreExisting`), one found by an
enumeration pass rather than its own create event (agent restart, mode transition, resync). Jev put
the risk of ignoring the second case at 0.69 and named the guard at 0.97.

**A/B, interleaved, 3 runs per side, running binary hash verified against the artifact each run:**

| | CREATE->MAP per run | mean |
|---|---|---|
| control | 36, 89, 62 ms | 62.3 ms |
| fixed   | 16, 8, 2 ms   | **8.7 ms** |

Cold-application case (measured before the A/B, Explorer not warm) was 329-438 ms -> ~0.
`pre=0` on every fixed run confirms the fast path was actually taken rather than assumed.
Rendering verified on pixels, not logs: the window comes up fully painted, no black frame.
Owner, watching live: "i see major difference visually!"

**Also established, and NOT acted on:**
- `wincapture.cpp` is **PrintWindow-based, not WGC** - "needs no session broker". An earlier note
  in this session calling the per-window path the "broker path" was wrong and is retracted.
- The engine captures a channel only on a dirty flag, whose producers are (a) DDA screen-damage
  intersection and (b) a round robin that marks **exactly one channel per 250 ms** - so a window's
  guaranteed refresh period is **N x 250 ms** with N live channels. Jev called this the cause of a
  measured 1332 ms damage hole at **conf 1.00**, and it degrades linearly with open windows (0.88).
  BUT: that 1332 ms did not reproduce across three later runs (largest mid-paint gaps 1219/724/893
  ms), and "mark every channel per sweep" is **not** a safe fix (Jev 0.10) because each capture is
  a synchronous round-trip into a different application's UI thread. Jev split the residual cause
  0.47 round-robin / 0.46 "the app genuinely paints over seconds" - i.e. it is **not established**
  that changing the sweep would help. Needs its own measurement before any change.
- `PWDECIDE` showed the DDA producer is alive and prolific: 554 consecutive frames judged changed.

## 2026-09-24 - the empty-window flash, and where a context menu's time actually goes

**Black flash (owner, same day): REAL MECHANISM, FIXED.** Yesterday's prefill change announced a
new window immediately, but `PwSlabAcquire` zeroes every slab - so dom0 was told to show a window
holding nothing until the engine's capture landed, i.e. for exactly the 32-438 ms the synchronous
prefill used to occupy. The existing `DirectWouldShowBlack` guard did NOT cover it: it requires
`PwSliceFed`, and these are the non-slice-fed windows. Fixed by routing such a window through the
SAME map-defer machinery everything else uses (`PwAwaitFirstCap` + new `WcHasCaptured`), bounded by
`CROP_BEFORE_SHOW_TIMEOUT_MS`. Jev: mechanism 0.90, revert 0.27 (no), this fix 1.00.
A/B after the fix, interleaved, hash-verified: CREATE->MAP **49.0 ms** (51/45/51) vs control
**130.7 ms** (66/256/70) - the win survives AND the spread collapses, because the announce no
longer blocks on the application's UI thread.

**"Every second window comes slower" (owner): that was my A/B.** An interleaved experiment was
swapping the agent binary every ~40 s on the guest the owner was watching, and six cells ran with
the agent deliberately STOPPED. Jev had already attributed the flash sighting to the procedure at
0.81. **Tell the owner before running an A/B on a guest they are using.**

**Context menu - the budget, measured.** Click -> menu visible in dom0 is ~1.1 s, split:
| stage | cost | whose |
|---|---|---|
| Windows produces the XAML menu | ~560-580 ms | the GUEST |
| agent notices the window | ~135 ms (n=1) | ours, unexplained |
| agent holds the map | 375-640 ms | ours, by design |

The guest share is proven by an **agent-off control**: agent stopped, mean 560 ms (646/486/547) vs
agent running 582 ms (574/577/594). Jev: "the agent inflates it" **0.17**. The guest is a 4-vCPU
HVM with no GPU, so the XAML menu is software-composited. (Jev also rated more runs worthwhile at
0.72 - the off-arm spread, 160 ms, exceeds the 22 ms between arms.)

**The hold has no slack (Jev 0.85).** New `HOLDTERMS` probe reports when each term of
`(BrokerOpaqueInsets || !CropPending) && SliceChromeContentReady` first becomes true:
```
menu1: held=640  insets=593  nopend=422  chrome=640  checks=13
menu2: held=375  insets=375  nopend=16   chrome=375  checks=9
menu3: held=500  insets=297  nopend=0    chrome=500  checks=5
```
`chrome_ms == held_ms` in all three - the crop terms resolve early and the wait is entirely on the
menu's own first PAINTED frame. That is the render-before-show guarantee the owner asked for on
2026-09-11, when menus mapped in 15-47 ms with `painted=0` on 8 of 8 - empty. So the menu can be
sped up **only by making its first frame arrive sooner** (Jev 0.96); changing the hold just buys
latency with a black frame again.

**Two constraints I checked instead of asserting:**
- the broker's 250 ms `Reconcile` loop is NOT a floor on first capture - `BrokerRegister` does
  `SetEvent(g_WgcCtl)` and the broker waits on it, so it wakes immediately;
- the resize churn does NOT reset `PwSliceContentTick`, so it does not extend the hold - which
  weakens my own churn hypothesis. It is still worth removing on its own merits (Jev 0.81): the
  menu oscillates between two sizes up to 8 times and each one does a full detach + re-attach +
  fresh MSG_WINDOW_DUMP + full-window damage + BrokerRegister, while every size fits the SAME
  already-granted 256-page slab (145/96/99).

**Next (Jev 0.98):** instrument the chain BrokerRegister -> CreateForWindow -> first FrameArrived ->
PublishFrame -> `PwSliceContentTick` to find where the 375-640 ms goes. Not yet done.
