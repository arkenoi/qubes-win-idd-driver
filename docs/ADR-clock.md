# ADR — the guest clock

## CURRENT STATE

AUTHORITATIVE. Maintain by editing in place; never append dated sections (the pre-commit hook
refuses them).

**The qube carries `timezone=localtime` from CREATE time, the installer sets the guest's zone from
`/qubes-timezone`, and nothing anywhere writes `RealTimeIsUniversal`.** That is the whole design.

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

* **Pulls the time at every boot** - `guest/sync-clock-from-dom0.ps1`, stock's behaviour with our
  retry/deadline handling. It decides nothing.
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

## Not done

* The first guest built under this design has not yet been measured. Until a cell reports
  `clock_boot_correction_s = 0`, this is reasoned and offline-tested, not witnessed.
* `win11de-qwt` was booted twice on 2026-10-15 and its seal could not be rewritten either time
  (`w_halt` expired at 900 s with the guest still Running - DEGOLDENHALTSLOW), so its seal describes
  pre-boot revisions. Its measured state is `RealTimeIsUniversal` absent and zone `FLE Standard Time`.
* An unmapped IANA zone leaves the guest on whatever zone Setup gave it, which is wrong by the
  difference from dom0's. Reported, not guessed at.
