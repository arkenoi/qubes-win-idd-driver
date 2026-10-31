# ADR — the guest clock

## CURRENT STATE

AUTHORITATIVE. Maintain by editing in place; never append dated sections (the pre-commit hook
refuses them).

**The qube carries `timezone=localtime` from CREATE time, the installer sets the guest's zone from
`/qubes-timezone`, and nothing anywhere writes `RealTimeIsUniversal`.** That is the whole design.

**It is correct for the RTC and incomplete for the clock Windows derives from it, across a DST
boundary.** Windows converts the RTC with the `ActiveTimeBias` already in its registry, then
updates that bias for the current date *without moving the clock it just set*. An image sealed on
the other side of a transition therefore boots exactly one hour out, with a bias that reads correct
afterwards. Measured 2026-10-30 on a fresh clone of `win11r-qwt` (sealed 2026-10-15, summer; Sofia
left DST 2026-10-25), first boot, nothing else run on it: host `2026-10-30T20:10:16Z` against guest
`2026-10-30T19:10:21Z` - **3594 s behind**, `ActiveTimeBias -120`, `DST False`. The bias is the one
field that repairs itself, so reading it is not a test of this. See `findings/issues.md`
ETWCLOCKDST (parked, P2).

## Why that is all there is

A hardware clock holds a number; two parties have to agree what it means.

* **Windows** reads it as **LOCAL time**. Always. The only thing that changes that is
  `HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation\RealTimeIsUniversal`, consulted at
  boot — and this product never writes it.
* **Qubes** decides what goes *into* it, per qube, through the `timezone` feature. Set to
  `localtime`, Xen puts **dom0's local time** there. Absent, it defaults to **true UTC**.

So a qube with `timezone=localtime` and a guest whose zone is dom0's is correct with nothing
declared: `guest_local = RTC = dom0_local`, and `guest_UTC = dom0_local - dom0_offset = real UTC`.

**Stock QWT relies on exactly this.** Its entire time handling is
`src/qubes-rpc-services/update-time.bat`, one line:

```bat
qrexec-client-vm.exe @default|qubes.GetDate|powershell.exe ... set-time.ps1
```

It asks dom0 for the date and sets the **clock**. It sets no zone and no convention - the Linux side
does the same (`qubes.SetDateTime` is `date -u -s`, skipped entirely when the difference is <= 2 s).
The time pull is drift correction, not a convention fix.

## The one real problem, and the one-line fix

`qubes-core-admin`'s `qubes/ext/windows.py` sets the feature **when the guest reports**:

```python
if guest_os == "Windows" and qrexec:
    if vm.features.check_with_template("timezone", None) is None:
        vm.features["timezone"] = "localtime"
```

That report needs QWT running, so it cannot happen before the first install. A qube created without
the feature therefore runs Windows Setup and the whole install on a **true-UTC** clock, and then -
one boot after the install, at the next domain creation - the clock's content moves by dom0's offset
with no signal inside the guest. The guest's only source of truth is dom0's time, fetched by the
boot-time pull ~60 s in, i.e. AFTER the clock has already been read wrong.

**Measured 2026-10-15** on a clean cell, with the guest's zone already dom0's:

```
RTC held 15:35:55Z, dom0 said 15:35:46Z  -> true UTC   -> guest 3 h BEHIND (skew +10790.9 s)
RTC held 18:41:06Z, dom0 said 15:41:03Z  -> dom0 local -> guest 3 h AHEAD  (skew -10803.2 s)
```

That is `clock_boot_correction_s = 10800` against a max of 60 - the P1 this release turned on.

**The fix is to remove the window, not to manage it:** every path that creates a guest sets the
feature before its first boot - `mgmt/reprovision-usb.sh` (the pristine base, at `qvm-create`),
`mgmt/harness/prime-run.sh` (the churn target), `mgmt/harness/quick-upgrade.sh` (the subject), and
`mgmt/harness/matrix.sh` (the cell subject and the AppVM). The clock then holds dom0 local time from
the first instant of Setup onward, Windows reads it as local, and the guest's zone is dom0's
throughout. There is no second configuration to pair with and nothing to converge.

## What this replaced

Five successive designs, all of them scaffolding around a value that should never have been written:
the constant forced in four answer files and baked into the goldens; the harness writing it after
every install; the installer writing it as a constant; the installer deriving it from whether QWT was
installed; and finally the installer writing it on its payload-clock gate's failure branch with a
per-boot task converging it from a `SETTIME` witness, a bounded wait and a monotonic deadline. Each
was reasoned, scored and tested, and each managed consequences of the first write rather than its
cause. The owner's question that ended it: *"why cannot we set timezone=localtime at qubes
creation?"*

## What the product still does about the clock

* **Does NOT pull the time at boot. Removed 2026-10-28, and actively unregistered on upgrade.**
  A SYSTEM task (`QwtClockSync`, `BootTrigger PT15S`) used to run `guest/sync-clock-from-dom0.ps1`,
  looping a `qrexec-client-vm` call to `qubes.GetDate` piped into `powershell.exe -File
  set-time.ps1`. Per successful boot: FOUR processes, two of them complete PowerShell runtimes,
  and one vchan, all inside boot+15 s. It was never stock's behaviour - stock's `update-time.bat`
  is called by nothing but `qubes.SuspendPostAll`; the boot task was ours.

  It is gone because this ADR's own fix removed its reason. The three-hour defect it was built for
  (2026-10-08) was a convention problem, and `timezone=localtime` at create time settled that:
  `clock_boot_correction_s = 0` on 2026-10-15 where the same cell read 10800 that morning. What
  was left is drift, and this ADR already said so - *"The time pull is drift correction, not a
  convention fix."* The only measured drift on record is **2.9 s** (19709's `set-time.ps1` log:
  `was -2.9 s out, now 0 s`), against a `clock_boot_correction_s` maximum of 60.

  Drift is corrected without us. dom0 ships
  `/etc/cron.d/qubes-sync-clock` - `0 * * * * root /usr/bin/qvm-sync-clock` - an HOURLY push of
  `qubes.SetDateTime` to every running qube, served by the same `set-time.ps1` the pull used. The
  residual exposure is boot-to-next-hourly-tick, worst case ~60 min, on an RTC that already holds
  dom0 local time.

  **CORRECTED 2026-10-30: that residual is not 2.9 s of drift.** Across a DST boundary it is a full
  hour of wrong clock for up to 60 minutes of every boot (measurement in CURRENT STATE above), and
  everything that reads a clock in that window reads it wrong - certificate validity at driver
  install, a `--since` log window, a scan's measured duration.

  **The pull is still not the answer, and the reason is stronger than cost.** `findings/wedge.md`
  records it as the last thing the guest completes before two wedge onsets - 2026-10-28
  `034440.252 CLOCKSYNC ... pulled from dom0` -> `034440.385 XcOpen` -> nothing on the volume, and
  2026-10-23 `20:09:44 CLOCKSYNC` -> `20:09:47.027 XcOpen`, the last line that guest ever wrote. It
  is guest-initiated, so the vchan SERVER role, inside the boot+15 s window every recorded onset
  sits in. Owner, 2026-10-28: *"the clock sync is the mechanism, not the engine."* Restoring it
  would trade one hour of clock error for a suspected trigger of the open P1 wedge.

  **What would end it, and why it is not done here.** `RealTimeIsUniversal` with the `timezone`
  feature absent puts true UTC in the RTC and takes the bias out of the boot conversion entirely -
  zero runtime cost, zero boot traffic, no expiry. This ADR rejects that value and `lint-harness.py`
  L26 enforces the rejection, so changing it is an owner call, not a rig fix. Until then the rig is
  covered by `primitives.sh` `clock_correct` on every cell ENTRY path, and a real guest is covered
  only by dom0's hourly push. Re-sealing a golden in winter fixes its clones until the March 2027
  transition and not past it. Jev, asked about the objective rather than about iterating the script:
  `pull_is_needed_at_all` = not_needed **0.85**, `cheapest_sufficient_shape` = drop_the_task
  **0.89**, `three_hour_premise_is_gone` **0.94**, `setter_powershell_is_wasteful` **0.88**.

  **The installer unregisters it** (`Install-QwtImproved.ps1`), because the task's action path was
  deliberately copied into the Qubes Tools tree to outlive setup - a guest upgraded from an older
  build would otherwise keep running it for ever.

  WHAT IS UNTOUCHED: `set-time.ps1` (the `qubes.SetDateTime` service dom0 pushes to) and
  `update-time.bat` (the suspend/resume path). Both still work; only the boot task is gone.
* **Sets the guest's zone from `/qubes-timezone`**, late in the install where qubesdb is readable.
  Stock leaves the zone to whoever runs Setup; we install unattended, so nobody picks one. dom0
  publishes an IANA name (verified: `qubesdb-read /qubes-timezone` -> `Europe/Sofia`) and `tzutil`
  takes Windows ids, so the installer maps the common zones and REPORTS anything it cannot map
  rather than guessing. Replacing a zone the guest already held is reported to the user at **ACTION**
  severity and recorded in the RESULT as `timezone_overridden`.
* **Refuses an install whose clock cannot validate the payload** - `Assert-PayloadClockSane`, before
  anything is mutated. A guest lands there only on a qube with no `timezone` feature, so the refusal
  names that: `qvm-features <vm> timezone localtime`.

## Enforcement

* `tools/lint-harness.py` **L26** - nothing writes `RealTimeIsUniversal`; nothing clears a qube's
  `timezone` feature. Patterns verified against all three write spellings, and against the shapes
  that must NOT trip it (a mention in prose, a `reg query`, `timezone localtime`).
* `tools/tests/rtc-utc-selftest.sh` - the absence, plus the feature set on all five create paths,
  with planted-writer and planted-clear cases seen to fail.
* `clock_boot_correction_s` (P1, max 60) - the detector, in the sweep, where it belongs: a backward
  jump in the guest's own logs. Left strictly as it is.
* `bootclockskew` (`tools/log-sweep.py`) - the residual the removal leaves: the sweep already
  MEASURES the pre-sync guest-vs-host skew (`mgmt/harness/log-sweep.sh` -> `context.guest_clock.
  presync_skew_s`), and it is now GRADED against `max_skew_s` (`LOGSWEEP_MAX_SKEW_S`, default 120).
  A distinct key on purpose: `clockskew` keys the predecessor cut at `_clock_ok`.
  **WHERE IT DOES NOT RUN, measured 2026-10-28:** only harnesses that call `log-sweep.sh` carry
  this context, and `quick-upgrade.sh` - the short cycle, the one that runs on every fix - uses its
  own sweep-gate instead and emits no `guest_clock`. On that path the gate's silence is not
  evidence of a synced clock; it is the gate not running. `matrix.sh` (the campaign) does call it.

## Not done

* **MEASURED 2026-10-15, witnessed.** A `win10-clean` cell against package 38771352401 (head
  3ca82a2c), clean-installed from the rebuilt `win10-base`: **`clock_boot_correction_s = 0`** against
  a max of 60, where the same cell read 10800 that morning. P1 breaches on that cell: **0**.
  Corroborating, from the same subject: the sweep's own pre-sync probe read `skew -6 s` (it read
  ±10800 on every prior run); guest local `20:09:26` against dom0 `20:09:34`; guest zone
  `FLE Standard Time`, which is dom0's `Europe/Sofia`; `RealTimeIsUniversal` -> `ERROR: the system
  was unable to find the specified registry key or value`; installer RESULT `ok:true` with no
  error-class flags. Three guests at three stages read dom0's clock with nothing declared: the
  pristine base at 19:36, the primer churn at 19:58 (its own output `Date: 15/10/2026 19:54:29`),
  and the installed subject above.
* `win11de-qwt` was booted twice on 2026-10-15 and its seal could not be rewritten either time
  (`w_halt` expired at 900 s with the guest still Running - DEGOLDENHALTSLOW), so its seal describes
  pre-boot revisions. Its measured state is `RealTimeIsUniversal` absent and zone `FLE Standard Time`.
* An unmapped IANA zone leaves the guest on whatever zone Setup gave it, which is wrong by the
  difference from dom0's. Reported, not guessed at.
