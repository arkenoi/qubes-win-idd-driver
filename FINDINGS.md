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
