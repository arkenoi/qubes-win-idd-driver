# Audit - a timer must never pace the discovery of a state change

Status: FINDINGS (2026-10-23). Owner asked for this audit; it is written down because the first
pass of it missed the defect below, which then cost a night and a campaign.

## The rule being audited

**A delay is not a state change.** If something can tell us a condition became true, we wait for
that thing. A timer is legitimate only as a *bound* on waiting for a signal we already expect, or
as a deliberate *re-assert* of a value something else keeps overwriting. A timer used to decide
*when to look* is the antipattern, because the latency it adds is invisible and ends up being read
as the cost of the thing it was looking at.

This project already states it twice - "prefer push over poll", and "idle load must GO"
(`docs/DESIGN-rest-zero-capture.md` S4, which removed a 1 s wait cap from the agent's main loop).

## How this audit was run (so it can be re-run, not re-derived)

Searched by CONTENT in `agent/gui-agent/`, `agent/watchdog/`:

1. `*NextDue()` functions - the main loop takes the soonest of these as its wait timeout, so they
   are the complete set of timers that can pace the loop.
2. `Sleep(` and `WaitForSingleObject(h, <constant>)`.
3. Re-check guards of the shape `if (now < g_Next…) return;` / `if (now - last < INTERVAL) return;`.

Then each hit was classified against the rule, NOT by whether it looked like a poll.

## Findings

| # | site | shape | on the time-to-first-window path | status |
|---|---|---|---|---|
| 1 | `BrokerNextDue` (main.c) | while the de-slice broker was down and unlaunched it armed **only** `g_BrokerNextWarn`, the QGADESLICEDOWN deadline. The one launch happens on a wake, so **the complaint timer was the launch's start signal** | **yes** | **FIXED** agent `f9ef238` |
| 2 | `BridgeNextDue` (main.c:4973) | before the notification host's first launch it returns **0** - arms nothing at all. Its first launch rode whatever wake happened, which was finding #1's complaint timer | **yes** | **FIXED** by the same event (armed while `!g_WgcLaunched \|\| !g_NotifLaunched`) |
| 3 | `EtwProxyPoke` (etwproxy.c:1037) | `ETWPROXY_POKE_MS` = 5000 self-throttle, and `etwproxy.c:676` says it plainly: *"no console user session yet - Poke retries on the existing loop pass"*. Same console-session precondition as #1/#2, discovered by polling AND dependent on someone else waking the loop | no (ETW signals, not window mapping) | **OPEN** - see below |
| 4 | `g_NotifNextPoll` (main.c:4564) | 5 s retry, armed only while `g_NotifRestorePending` | no | **not this antipattern** - it retries OUR OWN write (restoring banner suppressions) and clears when it succeeds. A retry of an action, not discovery of a state change |
| 5 | `WA_DRIFT_CHECK_MS` (workarea.c:20) | 2 s work-area re-assert, with a documented backoff after `WA_LOST_FIGHT_TRIES` | no | **not this antipattern** - a deliberate re-assert of a value Windows overwrites, which is the legitimate use. The file argues it itself |

Bounded waits on a known signal - a process handle, an ack, `g_WindowReady`, a stop event - were
checked and are **not** instances: each waits for a specific thing with a stated bound, which is
what `wait-needs-three-exits-and-a-real-marker` requires.

## What #1 cost, since it is the reason this audit exists

MEASURED 2026-10-23 on two subjects: the broker launched 29.0 s and 27.0 s after the agent's Init,
against a 30 s complaint deadline - half a minute with no seamless menus and no toasts after the
shell was up. The complaint then fired 1.5 s after the launch and 49 ms before the broker reported
ready, which is how it was found: as a false client-visible toast, not as the latency it was.
Corroboration that it was one wake rather than two slow operations: the notification host started
0.47 s after the broker.

The first fix attempt widened the complaint window instead of removing the wait, and a second used
a 1 s re-check. Both were wrong in the same way - treating the timer as the thing to tune. The
landed fix is a push: `g_HelperEligibleEvent`, signalled by the shell-seen latch and by
`WM_WTSSESSION_CHANGE` on the agent's only message window, with `BrokerNextDue` arming no launch
timer at all. `tools/tests/lifecycle-selftest.sh` asserts that negatively so it cannot return.

## Finding 3 - what is left, and why it is not fixed in the same commit

`EtwProxyPoke` now gets woken by the session-change push (the loop calls it on every wake), so the
worst case is no longer bounded by the de-slice complaint. What remains is its own 5 s throttle: on
a wake caused by the session arriving, the poke can still be suppressed for up to 5 s.

The clean fix is to let an eligibility change clear that throttle - but `g_NextPoke` is documented
"main-loop thread only" and the signal arrives on the window-event thread, so it must not be written
from there. The shape is an interlocked "eligibility pending" flag that the MAIN loop consumes
before calling the supervisors, and that is a separate, deliberate change with its own review, not
a fourth edit piled onto one night.

## The habit this audit is really about

Finding #1 was in a path the owner had repeatedly asked to shorten ("how can we cut down time to
first window"), and it was never surfaced - it was found only by chasing a toast that fired next to
it. An audit that enumerates shapes but does not ask *"what latency does each of these add to
something a user waits for?"* will miss the next one the same way.
