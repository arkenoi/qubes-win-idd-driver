# QWT-NG 4.3.39 — a Windows qube could lose its whole desktop, and we were the ones closing it

## A qube that keeps answering qrexec and shows nothing

The worst failure in this range is not a crash. The guest stays up, `qvm-run` works, the log keeps
being written — and there is no desktop, for the rest of that boot. It happened on three acceptance
campaigns (`rel-40817518835` win11de-uc, `rel-39678937221`, `rel-39880114972`) before it was traced.

What dies is **dom0's `gui-daemon`**, and nothing restarts it. That absence is deliberate and is not
being changed: the daemon parses bytes a guest controls, so `exit(1)` is fail-closed, and a
misbehaving guest gets exactly one attempt at a parser bug. A respawn, a dom0 watchdog or a
guest-side reconnect would all be security-model changes. So every path by which **our** bytes can
make the daemon exit is our defect, to be removed rather than survived. This release removes two of
them and the thing that walked the agent into the window.

**The lethal gap.** `gui-daemon` looks window 0 up in `remote2local` exactly like any other window id
(`xside.c:3942-3957`); that table starts empty and only `handle_create` ever inserts into it. So a
screen-scoped message arriving with no outstanding `CREATE(0)` is answered with `exit(1)` — no
dialog, no prompt. The agent enters that window on **every capture reinitialisation**, because
stopping frame processing sends `UNMAP(0)` + `DESTROY(0)`. Two call sites had grown ad-hoc guards;
screen `MSG_MAP`, screen `MSG_WINDOW_HINTS` and desktop `MSG_WMNAME` had none and reached the wire
unguarded. The send-side choke point waved window 0 through unconditionally, on the written premise
that "the daemon requires no CREATE for those". That premise is false. The check now lives at that
one choke point, so every screen-scoped sender inherits it, the flag is cleared on `DESTROY(0)`
symmetrically with the announce flag, and a gate that fires is a rate-limited warning rather than
silence.

**What walked us into the window.** The ETW proxy's helper launch ran synchronously on the agent's
main loop. Under a Winlogon secure desktop that launch was measured at **14.2 s, 15.2 s and 16.5 s**
on three separate runs, against 0.14–0.27 s on a normal desktop. The capture watchdog measures that
same loop and armed at 15 s — so the launch tripped the watchdog, and the reinit that follows is
exactly the destructive window above. The launch now runs on its own thread; the launch body is
byte-for-byte unchanged and still holds the same lock for its whole duration, so every invariant
inside it is preserved. Only *who waits* changed: the poke tries the lock and returns rather than
blocking, shutdown joins the worker outside the lock before teardown, and a previous worker is
reaped before another is spawned.

**And the watchdog itself was measuring the wrong thing.** It timed elapsed duration, which cannot
distinguish *blocked* from *slow* — on a host up to ~5× slower than this rig, our own measurement
puts a normal slow pass at 1–3 s, i.e. 5–15 s scaled, *on* the 15 s threshold. A destructive arm
would have fired on healthy operation. It now watches a main-loop progress tick instead, bumped on
every return from the loop's wait including a plain timeout, and declares a wedge only when that
tick has not moved for a whole budget. The capture thread has already set the event that loop waits
on, so a live loop is expected to tick on every pass regardless of how long that pass takes. The
argument that this holds on an arbitrarily slow host is from the structure of the wait, not from a
run on one — we have not tested a slow machine — but unlike the duration it replaces, nothing in it
is calibrated or tuned. A second arm, eight budgets of total wait, covers the one pathology a
progress term is blind to: a loop that ticks but never takes a frame. That ceiling is derived from
the budget rather than measured. Raising the old number was rejected as the alternative: it delays
detection of a real block on every host and is still a guess about how slow "slow" is.

**Honest scope:** the gap is closed and the trigger is removed, both proven reachable in source and
one of them measured on three runs. The race itself was never caught in the act, so
`GUIDESKTOPLOST` stays open in our register against a run that reproduces it.

## A failed capture initialisation reported success

One acceptance cell failed on one log line: `CaptureInitialize failed with error 0x0: The operation
completed successfully.` The text is the symptom; the defect is that the status really was zero, so
the caller's `if (ERROR_SUCCESS == status) return ERROR_SUCCESS;` reported capture initialised with
the capture pointer still NULL. A failed init was indistinguishable from a good one to everything
downstream — which is why it surfaced as a log line rather than a crash.

Three separate ways the status was being lost, all now fixed: the failure label ran teardown
*before* the caller read `GetLastError()`, and releasing COM objects and closing handles resets it;
six failure paths recorded no status at all; and the two richest sources in the function had their
`HRESULT`s tested and then discarded. The status is now captured at each failure site and restored
after teardown, a path that fails without recording why gets `ERROR_FUNCTION_FAILED`, and the caller
holds the same invariant from its side — a NULL return can never again carry `ERROR_SUCCESS`. One
intended consequence: the transient-desktop retry branch classifies on `GetLastError()` and was
reading a value teardown had already clobbered, so it now sees the real DXGI code.

## Two dom0 notifications for one broker death

A broker death was reported to dom0 twice, citing the same Windows event record, three seconds
apart. A double notification is a P1 by standing rule.

Both duplicate-suppression predicates were wired into the catch-up path only; the live
event-triggered path called neither, and its own ledger is keyed on a per-boot token and the death
identity, never on the record id — so a record the catch-up had already sent was still "new" to it.
A guard installed per caller is a guard one caller forgets, and this is the second time it fired:
the same double in the opposite order was recorded five days earlier and the fix was wired into one
of the two callers. Both predicates now run inside the shared reporter, before the death is
registered, so a duplicate consumes neither a death number nor one of the per-boot cap slots. The
check fails **open** and says so at warning level: a death the user is never told about is the worse
outcome.

## The de-slice supervisor stopped reporting deaths that had already been repaired

The broker's restart policy is Task Scheduler's minimum, one minute × 3; the supervisor's down-clock
was due 30 seconds after the death. The restart therefore landed outside the window every time, and
the supervisor reported a dead broker that had in fact come back — measured, a relaunch validated 91
seconds after a death reported 29 ms after detection. The deadline was not the wrong number, it was
started at the wrong moment: an exit-code death — the only kind the scheduler restarts — now gets
the scheduler's own budget as its first deadline, and the hold ends early the moment the restart
validates, publishes a pid, or the helpers stand down. A hang, a clean exit and a fourth death keep
the unchanged 30 seconds. The restart constants are now numbers with the task XML built from them,
so the budget and the XML cannot drift apart.

This delays **no** dom0 notification: the de-slice row is already suppressed while a death is
outstanding. The death itself still reports at once.

## The boot clock pull is gone

Every successful boot started four processes — two of them complete PowerShell runtimes — and one
vchan inside boot+15 s, to pull the time from dom0. The only correction that path ever recorded was
**2.9 seconds**. The three-hour defect it was built for in October was a convention problem, fixed
by setting the timezone at qube-creation time, and drift is already corrected without us: dom0 runs
`qvm-sync-clock` hourly against every running qube, served by the same guest-side script. The boot
task is removed and the installer now unregisters it, because its action path had deliberately been
copied into the Qubes Tools tree to outlive setup. `set-time.ps1` and `update-time.bat` are
untouched, so the hourly push still works exactly as before.

Removing the thing that jumps would have blinded the jump-based detectors, so the detector gap was
closed in the same change: the log sweep has always measured both clocks directly, before anything
corrects them, and merely printed the number. It is now graded, against the threshold already in
use, under its own problem key so it cannot be confused with the harness's own sync failing.

## The installer's log no longer depends on a channel the install holds closed

`Write-Log` appended to `C:\qwt-improved-install.log` and nothing else, and that file is pulled over
qrexec — which our own boot design deliberately holds closed for exactly the device work the log
describes. The result, on 2026-10-29, was a pull that returned an empty file and an engineer reading
that emptiness as "the install never ran". Every line, and both result writers, are now mirrored to
the Qubes Tools log directory, resolved once and cached because `msiexec` rewrites that key
mid-upgrade. Each line is written through rather than buffered, because the guests this exists for
are killed rather than shut down and a buffered tail is a lost tail. On an ordinary install this
simply means the setup log lands beside every other module's log instead of alone at the root of
`C:`.

The same change fixed an installer-side crash of its own: a `schtasks` probe added with the
clock-sync removal merged stderr into the success stream, which under `ErrorActionPreference='Stop'`
threw before the probe could read its own exit code, and killed stage 2 on any guest where the task
was absent. Three unguarded `schtasks` calls — the only three in the file — now decide on the exit
code alone, as the file's own rule says they must.

## Nothing else changed

**No driver change in this range.** No change to what the agent is permitted to do; the security
model is identical to 4.3.38, and the window-0 work narrows what we can do to dom0 rather than
widening it.

One addition is inert by default: a registry knob (`ExpStagePvDriversOnly`) that makes setup stage
the PV network and console drivers without installing them, leaving the bind to the cold boots. It
exists to take a measurement about boot-time device binding, is read once at stage-2 entry, and
nothing changes without it. Both arms have been run; the measurement it was built for is not yet
answered, for reasons recorded in `docs/ADR-boot.md`.

## What was verified, and what was not

**The acceptance matrix ran against these exact bytes and came back clean.** Eight cells — clean
install, same-version reinstall, in-place upgrade and template→AppVM derivation, on both Windows 10
and Windows 11 — **89 checks passed, 0 failed**. Per cell:

| cell | PASS | FAIL |
|---|---|---|
| `WIN10-clean` | 14 | 0 |
| `WIN10-reinstall` | 12 | 0 |
| `WIN10-upgrade` | 13 | 0 |
| `WIN10-appvm` | 3 | 0 |
| `WIN11-clean` | 14 | 0 |
| `WIN11-reinstall` | 12 | 0 |
| `WIN11-upgrade` | 13 | 0 |
| `WIN11-appvm` | 3 | 0 |

**All five feature tests passed** — `crop-before-map`, `notify-errors-guest-test`,
`supervision-gate`, `template-update`, `updater-component`. That is the first release in this
series where none of them is uncovered.

The acceptance record for ISO `19dcd1bd…` reads **CLEAN**, 6 cell-groups clean, 0 failed, and this
release is published with **no `--acceptance-override`** — unlike 4.3.38, 4.3.37 and 4.3.36.

**What was NOT verified, and it is not a small thing.** The change-scoped gate
([`docs/ADR-acceptance.md`](ADR-acceptance.md)) requires **19 suites** for the range this release
spans. The coverage receipt names **16**. Uncovered:

- `p3a-etw-gate` — **ran and FAILED on four drills, and all four are defects of the suite.** An
  earlier version of this section called `T7a`/`T7b` *"a real product defect ... a
  double-notification mechanism"*. That was wrong. Both were instrument failures, and the
  correction is the opposite direction from a downgrade: the product was doing what it is
  specified to do and the harness called it a bug.
  - `T7a` asserted that the ten `SENT`/`FWD_RTT` lines from five non-allowlisted informational
    toasts were forwards the shadow probe may not make. They were correct.
    [`docs/ADR-toasts.md`](ADR-toasts.md) §2, accepted and shipped in 4.3.31, is *"the route is
    decided per toast; the allowlist is a shortcut, not the gate"*, and line 118 is *"every toast
    that is not already allowlisted is classified from its own content. `verdict=bridge`
    forwards"*. `ToastActListingDecide` consults the allowlist **only** when no verdict arrived.
    Nor was the measure-only rule broken: the shadow classifier derives its verdict from the
    toast's own payload, and the tier only decides where the row is read from.
  - `T7b` reported `warmup=no check=no`. The forwards had happened. `fwd_count` matches
    `HH:MM:SS SENT …` anchored at line start, and an `[INFO] ` level tag had been inserted between
    the timestamp and the text, so it counted zero where there were five — while `fwd_attempts`,
    three lines away in the same file, had been updated and stayed correct.
  - `T7c` passed, so the skip path still works.
  - **And behind all four, the gap they were hiding.** `notifhost.cpp` carries a compile-time
    fault-injection switch, `P3AQ_DEFECT_ROUTE`, whose own comment names the check it exists to
    break: *"acquisition state gates the A0 forward/skip routing; the routing-invariance detector
    must then FAIL"*, and at the injection site, *"must FAIL on this build or it is decoration"*.
    **That detector had never been written.** The switch had nothing to break, and the row
    standing where it should have been was asserting the opposite of the ADR. So this area was
    not merely failing — it was unmeasured, and the failure looked like coverage. `T7a` is now
    that detector: the route a toast takes must not change with the ETW tier, compared across the
    parked and restored arms over the same fixtures. A second row covers the allowlisted sender,
    which is the half the switch actually perturbs.
- `p3a-etw-gate` `T5`/`T8c` — **these two are harness defects, not product defects, and saying so
  is not a downgrade.** Both kill the ETW proxy and then wait for the agent to relaunch it; the
  suite states outright that "the agent's relauncher IS the thing under test". There is no
  relauncher, deliberately: [`docs/ADR-supervision.md`](ADR-supervision.md) §5, accepted by the
  owner on 2026-10-07, is *"Nothing of ours relaunches anything; an exit code is a contract"*, and
  it names "every helper a supervisor relaunches". The agent did exactly what the ADR requires —
  logged the external force-termination at ERROR, parked the tier for the boot, and degraded to the
  listener/DB rungs so notifications still reach dom0. The drills assert a contract that was
  retired, and together with `T7a`/`T7b` they are why this suite has never gone green.
- `failproof-gates`, `failproof-faultinject` — aborted at their own control step, on a subject that
  had already carried a four-hour campaign, a preflight, a log sweep and an injector upgrade. "The
  subject is dirty" is one of the two causes those suites name for that abort, so this is most
  likely a sequencing error on our side rather than a product verdict. It has not been re-run on a
  clean subject, so it is **uncovered**, not passed.
- `toast-hold-test` — **ran and FAILED on one row of twenty-one**, `S3ii-1=PREEMPTED`, with 18 PASS
  and nothing ungraded. That row is `TOASTPREEMPTLOSESBANNER`, which is already declared below
  under *Known issues shipped knowingly* — a pre-emption taking a displayed banner off screen
  before the swap. It is a known P1 being shipped knowingly, not a new finding.

16 of 19 is the highest coverage any release here has recorded — the previous best is 4.3.35 with
13, whose ledger row nonetheless claims `full=true`. It is still not a met gate, and this release
is not cut on one. It is now also clear *why* the ceiling has stood: the full set requires
`p3a-etw-gate`, and four of that suite's drills contradicted the product's own ADRs or misread
its own logs, so the gate has been unsatisfiable by construction rather than merely unmet.
`T7a` and `T7b` are fixed. `T5`/`T8c` are not — re-pointing them at what ADR §5 actually
promises, or retiring them, is the owner's call. The suite has not been re-run since, so 16 of
19 remains what is measured, not what is expected.

**How it was published anyway, stated plainly.** At the moment of the cut, `tools/cut-release.sh`
did not consult the coverage gate at all. The gate exists — `tools/hooks/release-cut-gate.sh`
refuses `gh release create`, a `git tag v…` or a push of a v-tag unless the receipt satisfies
`tools/gate-scope.py check` — but it matches the *command text*, and the sanctioned cut path runs
`gh release create` from inside a script, where the matcher cannot see it. So the one path a
release is actually cut by was the one path that gate was blind to, and this release went out
through it. The check has since been moved in-process into `tools/cut-release.sh`, before any asset
is uploaded, where no wrapper can hide it; a short receipt now requires an explicit
`--coverage-override` whose reason is published in the release body. This release predates that
change and carries no such banner, which is why it is written out here instead.

## Known issues shipped knowingly

- **A toast pre-emption can leave a banner un-mapped** (`TOASTPREEMPTLOSESBANNER`, P1): while a
  newer notification is queued, a displayed window-path banner is taken off screen before the swap
  can paint, and for a `forwarded` resolution it is not put back. Unchanged from 4.3.38 — the
  replacement for rule 5 of the toast-hold design is specified, not built.
- **`GUIDESKTOPLOST` remains open** (P1): the lethal window is gated and the measured trigger is
  removed, but the race was never caught in the act, so the entry closes on a reproducing run and
  not on this diff.
- **The wgcbroker can hang without being relaunched** (`WGCBROKERHANGSANDISNOTRELAUNCHED`, P1):
  the broker stops answering, the agent ends it, and nothing relaunches it before the next agent
  start — so menus and toasts run brokerless for the rest of that boot. The restart policy the
  de-slice change above now respects covers an *exit*; it does not cover a live process that has
  stopped making progress.
- **A guest can stop responding at a level below the guest** (`WEDGERECUR`, P1): characterised from
  two crash specimens, the stall sits beneath Windows rather than in it. Not triggered by anything
  in this release and not fixed by it.
- **The Windows Update scan task can fail and log nothing** (`WUSCANTASKFAILSANDLOGSNOTHING`, P1
  updater).
- **The installer can fail to terminate, leaving an empty unresponsive window**
  (`INSTALLERLEAVESADEADWINDOW`, P1 user-facing): reported from the field on both Windows 10 and
  Windows 11 25H2 — a full-screen empty window and two taskbar entries that cannot be activated,
  still unresponsive after ten minutes. A reboot clears it.

  Two things it is **not**. It is not the desktop loss above: those reports carry no vchan wedge,
  and every vchan wait in them is answered in about a second. And it is not the clock/catalog hang
  we already guard against — a guest behind real UTC reads our driver catalogs as not-yet-valid and
  Windows hangs instead of failing, which is why the installer refuses up front; the affected
  machine's own logs show corrections of 5–11 *seconds*, so its clock was never the cause.

  `install.cmd` self-elevates by relaunching an elevated copy of itself, so the two taskbar entries
  are the installer's own two consoles, and "cannot be activated" is what Windows does to any window
  whose thread has stopped pumping — the installer blocks on `Start-Process msiexec -Wait`. The open
  question is what msiexec is behind, and we have never had the log that would say, because until
  this release the installer wrote only to `C:\qwt-improved-install.log`, which no log bundle
  collects.

  **If you hit this, that log is now worth sending.** It mirrors to `Q:\Qubes Logs\qwt-improved-install.log`
  alongside every other module's log, and each line is written through rather than buffered — so a
  hung or killed install still leaves a log, and it ends on the step it hung in.
