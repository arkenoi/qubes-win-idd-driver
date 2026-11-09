# QWT-NG 4.3.40 — one wait, four defects, three components

## The shape of this release

Almost everything here is downstream of a single idiom: **a sender blocked because the vchan write
ring is full**. Every component we ship writes to dom0 over a vchan, every one of them has to handle
"no room right now", and all three had copied the same wait. It was wrong in four independent ways,
and the ways compound: each one makes a Windows qube feel slow, unresponsive, or — in the worst
arrangement — stops it answering at all while the log keeps saying everything is fine.

The other three strands are the agent's **main loop no longer being held hostage** by a subprocess,
the **toast hold** finally holding the right thing, and **supervision** getting one decision instead
of nine.

---

## 1. The full-ring send wait

The same wait existed at four sites: `core-agent`'s `qrexec-agent` and `qrexec-wrapper`,
`winutils`' shared `vchan-common.c` helper, and the `gui-agent`. Four defects, found in this order:

**The send lock was held across the wait.** A sender that found the ring full sat in the wait still
holding the lock every other sender on that vchan needs. So one slow reader on the dom0 side did not
slow one send — it froze every thread that wanted to say anything. In `qrexec-agent` that includes
the agent's own service loop, which is why a slow daemon could freeze the agent outright rather than
merely delay one message.

**`qrexec-agent` committed a header and then waited for the body.** The message header went onto the
wire, then the sender blocked waiting for room for the rest of it. A peer reading that stream sees a
header promising bytes that have not arrived and will not arrive until the ring drains.

**The wait blocked on a handle the peer's close can shut.** `libvchan_fd_for_select` hands back the
vchan's *own* event handle, and `libvchan_close` closes it. A sender parked on that raw handle while
a close runs is waiting on a handle that no longer exists — undefined, not merely racy. Every site
now duplicates the handle it waits on and closes its own copy on every exit path.

**The senders shared an auto-reset event with the reader, and it releases exactly one waiter.** This
is the subtle one and it is the reason the first three fixes were not enough. The event the vchan
hands out is auto-reset: when dom0 consumes from the ring, the resulting signal wakes **one** waiter.
The main loop waits on that same event for incoming data. So when a reader and a sender were both
parked, the wake went to whichever Windows picked — and the loser did not learn that room had
appeared. It learned it when its own timeout slice expired.

The fix is a process-wide auto-reset room event per component. Only the reader waits on the channel;
every wake it takes is relayed to the room event, unconditionally, because a data-less wake *is* the
room notification a sender armed. Auto-reset is not an accident: a manual-reset event stays signalled,
so the sender would wake, find no room, loop, and spin at full speed under a lock. A condition
variable is also wrong — it stores no state, so a wake landing between a sender's ring check and its
wait is lost outright unless the reader signals under the send lock, which restores the very
reader-blocks-on-send-lock shape that releasing the lock exists to avoid. An event's state covers
the check-to-wait window; that is why it is an event.

**What is measured.** In `qrexec`, where the wait is reachable on a shipping configuration, stalls
attributable to the lost wake went from **67–72% of 187** recorded stalls to **0 of 149** after.
In the `gui-agent` the fix is settled by a waiter count rather than a rate: sends issued on the main
loop cannot be concurrent with the main loop's own wait (same thread), and the only off-thread sender
is the capture-worker pool, which `perwindow.c:128` fixes at 1 by default. One reader relaying to one
waiter on an auto-reset event reaches that waiter, so the `gui-agent` has no residual at the default
configuration.

**What is not measured, said plainly.** The `gui-agent`'s lost-wake *rate* was never observed,
because an ordinary upgrade cycle does not fill a 64 KiB ring — a non-regression run over the release
package produced **zero** reservation-wait records across 63 log inputs. Counters are now in the
field that record their own wake/slice split the first time a real guest fills a ring, at no cost
when it never happens. `qrexec`'s sender-against-sender residual (it has two output pumps, so one
reader relaying to two waiters can still lose one) is real and unmeasured. The `gui-agent` acquires
the same residual only if `CaptureWorkers` is raised above its default.

**`winutils` deliberately got a different fix.** Its shared helper got the handle ownership and the
failed-wait guard, and **not** the room event — on purpose. Its wait is unreachable from every live
caller: `qrexec-wrapper`, `qrexec-agent` and the `gui-agent` all reserve the whole message before
they reach it, and the only path in is a fault-injection branch that exists precisely to *be* the old
behaviour. Giving it a room event would have been machinery around a dormant path.

Two smaller corrections at the same sites: ordinary backpressure was being announced at WARNING,
which makes a healthy busy guest look sick in every sweep; and a wait that *fails* returns at once,
so the loop needed a guard to stop it spinning on the failure.

---

## 2. The agent's main loop stops waiting on `schtasks.exe`

Three helper launches — the capture/menu broker, the notification bridge, and the ETW proxy's helper
— ran **synchronously on the agent's main loop**, and each one is three `schtasks.exe` calls. While
that ran, the loop processed nothing: no window events, no capture, no vchan reads.

All three now launch off the loop. The launch bodies are unchanged and still hold the same locks for
their whole duration, so every invariant inside them is preserved; only *who waits* changed. Three
consequences of the split are handled in the same change rather than left to be discovered: the exit
path waits bounded on an in-flight registration before deleting the task, so a `/delete` cannot
overtake the `/create` and strand a task the scheduler then restarts; the disarm guard counts a launch
**issued**, not reaped; and the loop takes one 250 ms wake while a launch is in flight, because its
default wait is infinite and a *failed* launch would otherwise go unsaid until the pending window
expired and named the wrong reason.

The exit-path bound is **20 s**, and how it got there is worth recording because the first number was
wrong. It was initially sized at 50 s from a stacked 48.5 s guarantee. 48.5 s is bound arithmetic;
**7.524 s** is the worst registration ever measured here. Holding the exit path for 48 s would turn a
rare `schtasks` stall into an agent that hangs on shutdown past the SCM's patience, so the bound is
sized on the measurement. An earlier comment claiming a "30.5 s worst case" was also wrong and is
corrected in the tree.

The broker also **pushes** its readiness now instead of the agent noticing it a pass later, and the
grant rendezvous gained an exit for a dead worker — previously one stuck grant stopped the whole
agent.

The off-loop launch is measurable rather than asserted: a role line, the registration time in
milliseconds, and the main-loop tick delta across it.

---

## 3. The toast hold was holding the wrong thing

A toast's window has to be on screen when the toast arrives, or dom0 gets a notification with nothing
behind it. The hold exists to keep that window's frames alive across the gap. It had three defects
that each produce the same user-visible symptom — a notification that does not show:

- **A banner still BUILDING was classified as a flyout and shown unheld.** That misclassification
  *is* the lost toast: the window was let go while it was still becoming the thing that needed
  holding.
- **The gate's release was never written to the log**, so a window gated once at the swap edge read
  as never-showing for the rest of the run, and a healthy suppression ended silently — the bound
  needed to judge it had no clock.
- **The gate waited on a clock where it should have waited on the read**, and a refused read is not a
  landed one. A banner was measured withdrawn **4.47 s before** the toast that needed its window;
  its frames are held now.

The repaint is paid at the *release*, not at the next capture frame: a gate release is not a repaint,
and for a slice-fed banner a repaint that waits for a frame waits for something that, at rest, never
comes. Neither end of that was being logged before.

Related capture fixes in the same range: after a geometry-changed recreate the kept windows are
repainted (dom0 was holding pre-loss frames), and a repaint that **failed** now gets its own error
line instead of one word inside the success line.

---

## 4. Supervision: one going-down decision

"Is this session or system going down?" was being answered nine different ways at nine complaint
sites. There is now one decision, and the nine route through it. The going-down state is published as
a named kernel object that carries the **fact** where the channel previously carried only the
message — so a launch site can refuse before starting a process, including when the only witness to
the session ending is a process that has already exited.

The watchdog's stop event is the *service's*, created before the agent runs: in the first
milliseconds of a launch the old question was impossible to ask, and now it is not asked.

---

## 5. Display and seamless

- **Mode 2 fullscreen deny**: a caption *we* stripped still counts as a caption at the deny. Without
  that, a borderless app could be mistaken for a window that never had a caption and let through.
- A seamless config gate was being skipped by the optional-value idiom and is now read.

Neither fullscreen rule changed: boot/logon/shutdown fullscreen stays unconditionally off, and
borderless-app fullscreen still requires `service.gui-fullscreen 1`.

---

## Verification

| what | result |
|---|---|
| package | 4.3.40.1257 — `verify-release-package` **PACKAGE COMPLETE**, 14 gates passed, 0 skipped, `ours=22` binaries stamped, 86 manifest files, analyser rc=0 |
| CI at the build commit | every required workflow green (`build`, `test`, `qwt-full`, `release-package`) |
| short-cycle non-regression | in-place MSI major upgrade 4.3.35.0 → 4.3.40 over the sealed Win11 retail golden: 12 checks passed, 0 failed, zero E/W lines in the agent log, log sweep clean over 63 inputs, a real rendered window judged in pixels |
| supervisor discipline, end to end | 18 cells, **18 PASS**, zero FAIL, zero INVALID — one agent per boot, zero deaths at a shutdown, a suspended broker not reaped, one dom0 notification per death and zero per graceful shutdown, a launch refused while the going-down latch is held, and a forced `WaitForQdb` timeout recorded by the SCM with 1460 and the guest coming back |
| full release gate | enforced by the cut itself: `cut-release.sh` refuses to publish without a CLEAN acceptance record for these exact ISO bytes and a coverage receipt that satisfies `gate-scope.py` for this diff. There is no flag that skips either |

**A known instrument gap, recorded rather than glossed.** The acceptance plan marks a secondary log
volume as *required* for every cell that boots a guest, and no harness attaches one yet. The failure
collector therefore runs with `--logvol none` and each failure package records the gap. If a guest
wedges during a campaign, guest-side module logs for the last moments before the hang are not
recoverable without the guest.

---

## Upgrading

In-place MSI major upgrade from any 4.3.x. The short-cycle non-regression above is exactly that path
from 4.3.35. Automatic updates remain **off** in the guest by design; dom0 drives every install.
