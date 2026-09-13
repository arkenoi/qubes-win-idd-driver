# RESEARCH — xenbus store-wait, and the wedge it did not explain (2026-09-12)

Work preserved on branch **`xenbus-store-wait-research`**. Reverted from `main` because it is
**unproven against the defect it targets**, not because it is wrong.

## What the code does

`StoreSubmitRequest` (xenbus `src/xenbus/store.c`) waits for its xenstore request while holding
`Context->Lock` at DISPATCH_LEVEL, and `XENBUS_EVTCHN(Wait)` is a pure `_mm_pause()` busy-spin
(`evtchn.c`). So it burns a core with the store lock held for up to 5 s per iteration and, since
a timeout only logs `TIMED OUT` and iterates, forever if the request never completes. About ten
xenstore entry points contend on that lock and every PV path in the guest goes through xenstore.

That is a real defect, visible by reading the code, and it ships in stock QWT too. The branch
carries a two-patch series:

- `xenbus-store-no-lock-while-waiting.patch` — poll, drop the lock, stall 100 us, retake it.
  A request is completed by whoever polls next (`StoreDpc` runs `__StorePoll` independently), so
  the lock was never needed to make progress. IRQL stays raised throughout, because the
  `// Make sure we don't suspend` raise is load-bearing: `SuspendTrigger` → `SyncCapture` queues
  a DPC on every CPU and spins until all run it, so a thread at DISPATCH_LEVEL is what prevents
  a Xen suspend landing mid-request.
- `xenbus-store-wait-watchdog.patch` — warnings from 5 s, then `BUG()` at a tunable deadline
  (`StoreRequestTimeout`, 0 disables). Counters (`StoreMaxWaitSeconds`, `StoreSlowRequests`) are
  published by the existing `StoreWatchdog` thread to the registry and the Windows event log,
  because `Warning()` is debugger-only and `LogPrintf` is discarded unless `ConsoleLogLevel` is
  set — a diagnostic nobody can read is not a diagnostic.

A 15-agent adversarial review returned SHIP WITH CHANGES and found three defects in an earlier
revision, all fixed: a 1 s DISPATCH deadline that would have broken PV device bring-up
(`FrontendSetState` holds a spinlock across the whole state machine and upstream budgets 120 s);
withdrawing a half-sent request, which desynchronises the ring permanently; and a NULL return
leaking watches/transactions into `BUG()` via a `KEVENT` on a dead stack frame.

## Why it is not on main

**It was never shown to fix, or affect, the wedge.** The evidence:

- The wedge is real: three reproductions with a synthetic harness
  (`mgmt/harness/pnputil-trigger-ab.sh`) plus one live campaign failure. Fingerprint: domain
  Running, qrexec deaf, PV console unbindable, zero windows mapped, ~2.4–6 cores burning, the
  guest not writing its own event log, ACPI shutdown ignored.
- **The package is not the variable.** Run through the real feature-test path
  (`notify-errors-guest-test.sh` on `win11-nfy` from the `win11-qwt` golden), both
  `9.1.0.491` (with these patches) and `9.1.0.483` (the build that wedged during the 2026-09-12
  campaign) passed 11/11. A pure-upstream build (`skip_patches`, no code of ours) passed 5/5
  under a synthetic protocol.
- Therefore every package-level comparison run that day measured nothing.

## Hypotheses tested and refuted

| hypothesis | outcome |
|---|---|
| `pnputil /install` on the live PV boot bus is the trigger | REFUTED by a positive control: the `/install` arm never wedged; the stage-only arm did |
| the wedge follows our xenbus code | NOT SUPPORTED: the wedging build passes the real path; upstream-only also passes |
| adding any higher-ranked xenbus package provokes it | not established; survives as a weak hypothesis only |
| signer-cert trust state is the variable | untested |
| accumulated rig state across a full campaign | **untested, and the best remaining candidate** — every observed wedge occurred inside or after a full 8-cell campaign, never on a freshly-cloned guest on an idle rig |

## What would settle it

Run the **complete** procedure that produced the failure — `tools/release-acceptance.sh --run
<id>`, all eight cells then the feature tests — not the feature test in isolation. Until the
wedge reproduces there, no package comparison means anything.

## The bucket-lock patch is PARKED TOO (owner call, 2026-09-13)

`patches/xenbus-hash-table-lock.patch` is no longer applied and no longer on `main`; it is in
git history and on this branch. We now ship **stock xenbus**.

The defect it fixes is real — a lost update in `__HashTableBucketLock` — and
`mgmt/harness/evtchn-storm-ab.sh` proved the patch fixes it: stock wedged at t+81 s at 300% of a
core, patched survived 2,972,459 open/close pairs, same golden, one variable.

But that storm is four threads hammering event-channel open/close at 6-8k/s. It demonstrated
that the lock breaks under synthetic pressure; it never showed our wedges came from it. Two
facts argue they did not:

- the wedge RECURRED on the patched driver (9.1.0.470, 2026-09-12 campaign);
- a defect in OUR install path was found on 2026-09-13 that leaves the gui-agent's grants
  orphaned across PV-driver re-enumeration (see below), and its introduction on 09-08 is
  immediately followed by the wedge cluster.

So the patch was plausibly suppressing a symptom of our own code while a real upstream bug
provided cover. Carrying it is not free: a patched PV driver must be rebuilt, re-signed and
version-ranked every release, and on 2026-09-12 an installer change silently stopped it binding
at all with nothing noticing until an assertion was added.

TO RESURRECT IT: the patch applies to `src/xenbus/hash_table.c` at the pinned commit; the CI
step that applied it (with its marker assertions) is in this file's history.

## The install-path defect that likely mattered instead

`4d2de2b` (09-08 15:04) quiesced the gui-agent for all of stage 2 by KILLING it. `capture.c`
states at its own revoke site that "grants are not automatically revoked when the xeniface
device handle is closed" - the whole-desktop framebuffer grant and the staging grant are
released ONLY on the agent's exit path. So stage 2 went on to install xenvif and xencons,
create the IDD device and disable the adapter while dom0 still mapped pages of a dead process.

A graceful request existed from `4a97d97` (09-08 21:21) but was gated on the watchdog SERVICE
stop succeeding - which the code's own comment says throws exactly when it matters. `1ac052b`
(09-13) makes the graceful exit unconditional: respawner first, then QGA_SHUTDOWN, then kill
whatever remains.

`20f1f60` (stage xenbus instead of `pnputil /install`) was REVERTED in `49eeecb`. Acceptance
proved it prevented the driver from ever binding: six cells failed with "xenbus bound is
9.1.0.0 but the package ships 9.1.0.494 - staging did NOT bind". That also voided the
2026-09-12 ours-vs-upstream comparison a second time, since both of its packages carried the
stage-only installer and therefore both guests ran stock xenbus regardless of what was shipped.
With `/install` restored the assertion reads "bound 9.1.0.496 (packaged 9.1.0.496)".
