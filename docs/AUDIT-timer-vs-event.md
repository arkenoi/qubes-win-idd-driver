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

| # | site | shape | user-visible cost | status |
|---|---|---|---|---|
| 1 | `BrokerNextDue` (main.c) | while the de-slice broker was down and unlaunched it armed **only** `g_BrokerNextWarn`, the QGADESLICEDOWN deadline. The one launch happens on a wake, so **the complaint timer was the launch's start signal** | **UNPROVEN** - the A/B found none (see the retraction below) | **REVERTED, agent `3196c0b`** - measured 13 s WORSE to first window |
| 2 | `BridgeNextDue` (main.c:4973) | before the notification host's first launch it returns **0** - arms nothing at all. Its first launch rode whatever wake happened, which was finding #1's complaint timer | **UNPROVEN**, same as #1 | **REVERTED with #1** (armed while `!g_WgcLaunched \|\| !g_NotifLaunched`) |
| 3 | `EtwProxyPoke` (etwproxy.c:1037) | `ETWPROXY_POKE_MS` = 5000 self-throttle, and `etwproxy.c:676` says it plainly: *"no console user session yet - Poke retries on the existing loop pass"*. Same console-session precondition as #1/#2, discovered by polling AND dependent on someone else waking the loop | no (ETW signals, not window mapping) | **OPEN** - see below |
| 4 | `g_NotifNextPoll` (main.c:4564) | 5 s retry, armed only while `g_NotifRestorePending` | no | **not this antipattern** - it retries OUR OWN write (restoring banner suppressions) and clears when it succeeds. A retry of an action, not discovery of a state change |
| 5 | `WA_DRIFT_CHECK_MS` (workarea.c:20) | 2 s work-area re-assert, with a documented backoff after `WA_LOST_FIGHT_TRIES` | no | **not this antipattern** - a deliberate re-assert of a value Windows overwrites, which is the legitimate use. The file argues it itself |

Bounded waits on a known signal - a process handle, an ack, `g_WindowReady`, a stop event - were
checked and are **not** instances: each waits for a specific thing with a stated bound, which is
what `wait-needs-three-exits-and-a-real-marker` requires.

## What #1 actually cost - RETRACTED AND MEASURED, 2026-10-23

**The latency claim this audit was written around is DISPROVEN.** Recorded in full, because the
claim was committed before it was measured.

What was observed: on two churn subjects the broker launched 29.0 s and 27.0 s after the agent's
Init against a 30 s complaint deadline, and the complaint fired 1.5 s after the launch and 49 ms
before the broker reported ready. I read that as "half a minute with no seamless menus after the
shell was up" and treated the scheduling shape in finding #1 as its cause. Two things were wrong.

1. **The interval cannot be decomposed.** Both logs come from a build that emits NO shell-seen
   marker - `QGASHELLSEEN` count is 0 in each, and they still carry the legacy six-line LogInit
   banner. So Init+29 s is equally consistent with the SHELL arriving 28 s into a cold boot, which
   is normal, and nothing in those captures separates that from waiting for a wake. My claim that
   the shell was up early rested on an inference about which branch had run, not on a marker.

2. **The A/B shows no effect.** `mgmt/harness/ttfw-ab.sh`, 3 interleaved rounds on win11r-ttfw,
   binary swapped in place with the RUNNING hash verified every sample (`754B82642D8D56B0` with the
   fix, `3E3700B09E54E5F6` without):

       shell -> WgcLaunch     A(no fix) 700, 375, 418 ms    median 0.42 s
                              B(fix)    659, 532, 1123 ms   median 0.89 s
       shell -> broker ready  A 5114, 1997, 2334 ms         B 4719, 3351, 4485 ms
       QGADIRECTSUPPRESS = 0 on EVERY sample, both sides

   `VERDICT=OVERLAPPING` - the harness refuses a claim from these, and the median moves the wrong
   way. **The pre-fix binary launches the broker just as fast.** There is no 29 s wait on the
   current build with either binary, so finding #1's shape was not causing one.

**What survives, and on what grounds.** The toast was real and client-visible: a dom0-bound report
announcing a down de-slice broker 1.4 s before that broker validated ready - P1 by the standing
rule, whatever the arithmetic said. Holding the down-clock until a launch has been ISSUED fixes
exactly that, because a report cannot fire for something nothing has asked to run yet, and it
stands on that alone with no latency claim attached. Removing a timer that paces a launch is
defensible cleanup on its own terms (Jev: 0.92 that it removes the timer, 0.91 to land). Neither is
evidence of a user-visible speed-up. The fixed build's own boot does sweep CLEAN
(`LOGSWEEP-RESULT rc=0 status=CLEAN`), which is a pass, not a benefit.

Two earlier attempts are kept here because they are the same error twice: the first widened the
complaint window, the second used a 1 s re-check. Both tuned the timer instead of removing it, and
neither was measured against the pre-fix binary - which is what would have caught all of this.

**AND THE FIX WAS REVERTED, 2026-10-23, as a measured regression.** Once every A/B sample was
required to END in a window whose pixels classify DESKTOP - rather than in a log line - the result
was immediate and disjoint:

    boot -> demonstrated window   without f9ef238  10.7, 12.0, 13.3 s
                                  with it          20.9, 24.9, 27.4 s
    median 12.0s vs 24.9s, delta -13.0s, VERDICT=REGRESSED
    shell -> broker ready         without 0.26, 1.88, 0.99 s   with 6.86, 3.97 s

The wake that the complaint timer happened to provide was ALSO what drove the supervise pass that
validates the broker as ready. Replacing it with an event made that pass happen later, so the
broker became ready seconds later and the first window with it. Reverted in agent `3196c0b`;
185794f's de-slice hold is kept pending its own A/B, because it fixes a real client-visible defect.

**The lesson is the measurement, not the mechanism.** The first A/B read only the agent's own stamps
and reported OVERLAPPING - no effect. It never proved the guest reached a sane end state, and the
owner named exactly that: *"a measurement that does not prove end state is sane is futile, we may
claim zero seconds immediately."* A 13 s regression looked like "no effect" until the end state was
asserted.

**Still unexplained:** why those two instances took 27-29 s from Init to the launch. Answering it
needs a build that emits the shell-seen marker, i.e. a fresh reproduction, not these captures.

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

Two habits, and the second is the worse one.

The first: an audit that enumerates shapes without asking *"what does each of these cost something a
user waits for?"* will keep missing the ones that matter. Finding #1 sat in a path the owner had
repeatedly asked to shorten and was surfaced only by chasing a toast that fired next to it.

The second, and this audit is itself the example: **a shape that looks like a defect is not a
defect until it is measured against the build that lacks the fix.** Finding #1's scheduling was
genuinely wrong - a launch paced by a complaint deadline - and removing it was still right. But the
27-29 s was attached to it by inference, written into this document as MEASURED, and committed
before any A/B existed. The A/B then showed the pre-fix binary launching just as fast. The order
has to be: reproduce, measure both sides, then claim.
