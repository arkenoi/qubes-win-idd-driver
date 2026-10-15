# ADR — the guest clock: whose convention the hardware clock follows

## CURRENT STATE

AUTHORITATIVE. Maintain by editing in place; never append dated sections (the pre-commit hook
refuses them).

**The normal configuration is left alone until a measurement says otherwise.** The answer files
declare nothing, no golden carries a forced value, the harness only reports, and
`tools/lint-harness.py` L26 refuses a new writer. The product touches the convention in exactly two
places: the installer writes it ONLY on the failure branch of its payload-clock gate — the one
moment it demonstrably matters — and the per-boot task converges it from an independent witness.
Every bound that can span a correction is monotonic.

## In plain English

A PC keeps a battery-backed clock, and two operating-system families disagree about what it holds.
Linux stores UTC in it. Windows stores local time. Neither is wrong; they are conventions, and a
virtual machine has to be told which one its virtual clock follows.

On Qubes that is decided per qube by the `timezone` feature, which Xen turns into its `localtime`
setting. Unset, the qube's RTC holds true UTC — Xen's default and what every Linux qube gets. Set to
`localtime`, the RTC holds **dom0's local time**, which is what Windows expects.

**Qubes gives every Windows qube the second one, by itself.** `qubes-core-admin`'s
`qubes/ext/windows.py`:

```python
if guest_os == "Windows" and qrexec:
    if vm.features.check_with_template("timezone", None) is None:
        vm.features["timezone"] = "localtime"
```

Windows declares which convention it believes through one registry value,
`HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation\RealTimeIsUniversal`: 1 means "read the
RTC as UTC", absent or 0 means "read it as local time". It is consulted **only at boot**.

## The two defaults were already consistent, and we broke the pairing

Windows' own default is to read the RTC as **local time**. Qubes makes a Windows qube's RTC hold
**dom0's local time**. Those are the two halves of the same convention. Set the guest's zone to
dom0's — which Qubes publishes to every qube in qubesdb as `/qubes-timezone`, an IANA name such as
`Europe/Sofia` — and the guest is correct from the first instant of the boot:

```
guest_local = RTC = dom0_local          and          guest_UTC = dom0_local − dom0_offset = real UTC
```

with nothing written, nothing derived and nothing to correct. **Writing 1 is what broke it.** A
guest told to read a dom0-local RTC as UTC sits dom0's whole offset AHEAD, for ever. Measured
2026-10-15 on a live guest: `RealTimeIsUniversal=1`, guest timezone UTC, guest clock `10:38:51Z`
against a real UTC of `07:38:40Z` — exactly +10800 s.

So the design is: **the image declares nothing, and the product derives what it needs.** Jev,
premise-framed on the measured mechanism: `defaults_are_already_consistent` 0.79,
`forcing_vs_product_write` = stop forcing, keep a derived product write, 0.92.

### The guest's ZONE has a correct value per window too, and that is the other half

The zone and the convention are two halves of one sum: `guest_UTC = RTC_content − guest_zone_offset`.
Each half has a correct value, and which one depends on the qube's `timezone` feature at that moment.

| window | the feature | the RTC holds | correct convention | correct guest zone |
|---|---|---|---|---|
| Windows Setup and the first install | not set yet | true UTC | read as UTC, or a zero-offset zone | **UTC** (offset 0) |
| every boot after the guest has reported | `localtime` | dom0 local | read as LOCAL (the default) | **dom0's** |

So our answer files pin `<TimeZone>UTC</TimeZone>`, and the installer sets dom0's zone LATE, from
`/qubes-timezone`, at the end of the install — that late step IS the transition between the two
windows. By the first real boot both halves are right and there is nothing to correct.

**This was `FLE Standard Time` for one day, and that is instructive.** Commit `27f4b320` changed the
zone and added the forced `RealTimeIsUniversal=1` in the same breath, and the two only worked
together: with the convention forced to "read as UTC", a non-zero Setup zone is harmless. When the
forced half was removed and the zone half left behind, a fresh install would have landed its own
offset BEHIND real time — the direction that makes a CI-minted catalog look not-yet-valid — and the
installer's own gate would have refused every clean-install cell. **One half of a pair going missing
is the exact failure mode this area keeps producing**, and it nearly shipped again in the commit that
was fixing it. It was caught by predicting the arithmetic before running the campaign, not by the
campaign.

The objection that pinning UTC hides zone bugs — recorded in the answer file when UTC was removed —
is answered by where the measurement happens: the real zone is set before the first boot the
acceptance sweep ever sees, so every measured boot runs with dom0's non-zero offset and a wrong zone
still shows up as `clock_boot_correction_s`. Only the Setup window, which validates no catalog
against a guest zone, has a zero offset. Jev: `coverage_after_the_change` 0.82. The German answer
file keeps its own zone deliberately — it is the reproduction environment for the hang and the only
rig image that enters the Setup window with a non-zero offset; nothing in the gate matrix
clean-installs from it.

### Why the bug emerged before the forcing was removed

Because every layer forced the value, and each had a comment explaining why it was right:

| layer | what it did | why it was wrong |
|---|---|---|
| four `mgmt/autounattend*.xml` | `reg add … RealTimeIsUniversal /d 1` in the specialize pass | baked into every image, inherited by every golden and clone |
| `mgmt/harness/set-rtc-utc-golden.sh` | wrote it into a sealed golden | the harness deciding a product setting, one layer earlier |
| `w_rtc_utc`, called from `prime-run.sh` | wrote it into the subject the moment qrexec answered — i.e. AFTER the install | whatever the installer and the per-boot task derived was overwritten on every primed subject |
| four create paths | `qvm-features --unset <vm> timezone` | made the RTC hold true UTC, the one configuration where a wrong value is invisible |

The gate therefore measured the forcing, not the product. On run 11 the installer logged
`RealTimeIsUniversal set to 0 for the next boot (was 1)` and every boot that followed ran with **1**
and a three-hour error. Jev: `report_not_decide_is_right` 0.94, `harness_clear_hides_it` 0.84.

That is also why the metric looked like an artefact and was not. `detect_clock_offset` finds a
BACKWARD JUMP between consecutive lines of one log file, which nothing but a real mid-boot
correction produces. I claimed twice that it was an artefact — first an unavoidable install-era
boot, then the sweep misreading local-time stamps as UTC. **Both were wrong.** Forcing 1 on a qube
whose RTC holds dom0 local made the guest boot an offset ahead, the puller corrected it back, and
that correction *was* the jump.

## A localtime RTC PROPAGATES dom0's zone; only a UTC RTC lets the guest choose one

**This is a constraint of the mechanism, not a policy of ours.** A hardware clock holding dom0's
local time carries no zone label, so the guest cannot recover real UTC from it without knowing
dom0's offset:

```
guest_UTC − real_UTC = dom0_offset − guest_offset        (with a localtime RTC)
guest_UTC           = RTC = real UTC, whatever the zone  (with a UTC RTC)
```

So, in the owner's words: *a guest may choose its own timezone only if its RTC is UTC; if it is
localtime, the zone is propagated with it.* On a `timezone=localtime` qube — which is what
qubes-core-admin gives every Windows qube — a guest set to any zone but dom0's is wrong by the
difference, on every boot, for ever, and **no `RealTimeIsUniversal` value can correct it**. Our
per-boot puller would re-correct the clock each boot and never converge, which is a silent paper-over.

### How the guest learns dom0's zone, and how far that actually goes

dom0 publishes it in qubesdb as `/qubes-timezone`. Verified 2026-10-15 from a qube on this host:
`qubesdb-read /qubes-timezone` → `Europe/Sofia`, matching dom0's `Timezone=Europe/Sofia`. That part
works and is not an assumption.

**What does not scale is the translation.** `/qubes-timezone` carries an IANA name and `tzutil` takes
Windows zone ids, which .NET Framework on the guest cannot convert (`TryConvertIanaIdToWindowsId` is
.NET 6+). The installer therefore carries a hand-written map, and its real coverage is:

* **60 entries against ~598 IANA zones** on this host — about 10%, chosen for the regions we ship to.
* **The quarter- and half-hour zones are mostly absent.** `Asia/Kolkata` (+05:30) is mapped; Nepal
  (+05:45), Iran (+03:30), Afghanistan (+04:30), Myanmar (+06:30), Chatham (+12:45) and Lord Howe
  are not.
* **A Windows zone id is not a faithful IANA zone.** One id covers several zones with different DST
  histories — the map sends `Europe/Rome` and `Europe/Berlin` to the same id — so even a "mapped"
  zone can disagree with dom0 around a transition or after a rule change.

**Therefore the localtime pairing is only safe where the guest's zone can be made EXACTLY dom0's,
and we cannot guarantee that in general.** The configuration that is proof against arbitrary offsets
is the other one: a UTC hardware clock, where zone, half-hours and DST rules are display concerns and
cannot affect correctness.

### What the product does about it

* **Propagates** dom0's zone when it can map it, late in the install, where qubesdb is readable.
* **Reports and does not guess** when it cannot map it — and the message now names the consequence
  (the guest's UTC will be out, and the per-boot task will correct it every boot rather than
  converge) instead of the older line, which claimed the guest's UTC was "still correct" and was only
  true while we forced the convention.
* **Names a zone mismatch as one.** A guest whose offset differs from dom0's lands in the
  fits-NEITHER branch by construction — `fitsLocal` tests exactly `|dom0_offset − guest_offset| < tol`
  — and used to be told only that the RTC "fits neither convention", which reads like a convention
  problem and sends the reader to the wrong fix. `CLOCKCONV` now recovers dom0's offset from the
  witness (`rtc − dom0_utc` under the localtime hypothesis), reports the difference, and names both
  remedies: match dom0's zone, or give the qube a UTC clock (`qvm-features <vm> timezone utc`, which
  dom0 does not overwrite once defined — it fills that feature only when it is undefined) and keep a
  zone of its own. Covered by `clock-convention-selftest.sh` PART K.
* **Does not set the qube's feature itself.** Which hardware-clock convention a qube gets is a
  dom0-side decision about that qube, and the same reasoning that took this value away from the
  harness applies: we report what we measure and name the fix.
* **Does not force the guest's zone over a user's choice.** On a UTC-RTC qube that choice is
  legitimate and free; forcing it would break the one configuration that handles complex offsets.

## Where the product touches it, and why only there

### 1. The installer: only on the failure branch of a measurement

**The normal configuration is already correct, so the installer declares nothing by default.** It
used to write 1 unconditionally on every install, and the answer files wrote it before that — which
is how a forced value reached every golden and every clone. An install that writes a convention into
a healthy guest is pre-empting a decision it has no evidence for.

There is exactly one moment the value matters, and it is measurable: a guest whose clock cannot
validate the payload's driver catalogs. `Assert-PayloadClockSane` already measures that, for the
WHOLE payload rather than one driver — the audit that produced it found four sites that would hang
identically, including `msiexec`'s own `ADDLOCAL InstallDriverPackages`. So:

```
$skewed = Assert-PayloadClockSane -Root $Root -Why 'stage 1 pre-flight'
if ($skewed.Count -gt 0) { $fixed = Set-RtcConventionForNextBoot; Fail (... cause, and the fix ...) }
```

measure, branch on the result, then act. Nothing writes the value on the healthy path, and
`rtc-utc-selftest.sh` asserts that ORDER — measurement line before the branch, branch before the
call — rather than asserting a value, because every previous version of that check asserted whichever
constant I believed that morning and went green each time I changed my mind.

**Why 1 is the right thing to write at that moment, and the only lever available.** A guest that
fails the gate is BEHIND real time: `drvinst` rejects a certificate minted on the CI runner as
not-yet-valid and then waits rather than failing — `0x800B0101`, measured 2026-09-25 on a German
25H2 guest as twenty-five minutes at 0.125 s of CPU. There is no time source to correct it with: a
clean install has no qrexec and no dom0. Setting `RealTimeIsUniversal=1` moves the guest FORWARD by
its own zone offset, which is exactly what a behind clock needs, and if the RTC's content turns out
to be dom0-local instead, being wrong in THAT direction leaves the guest AHEAD — which every driver
catalog still validates against. Our rig never reproduced the hang because every rig image is pinned
to UTC, where the offset is zero and there is nothing to be behind by.

The value takes effect only at the next boot, so this install is still refused — but the refusal now
names the cause and a one-reboot fix instead of a clock the user must repair by hand, and it happens
TERMINALLY and EARLY: before a CI certificate is trusted as a machine root CA, before testsigning,
before autologon, before any reboot.

### 2. The per-boot task: convergence, from an independent witness

`guest/sync-clock-from-dom0.ps1` (`CLOCKCONV`) runs at every boot, has just learned real UTC from
dom0, and is the only actor that can see both what the RTC holds and what the time really is. Jev
0.85 that it must keep WRITING rather than only reporting: the installer's lever is a one-way nudge
taken with no time source, so a guest it moved has to be able to come back.

**Either half alone is a shipped defect.** A write with no convergence is the +3 h we shipped — a
guest nudged forward and left there. Convergence with no write at all leaves a behind guest unable
to install anything, because the convergence needs qrexec and the install is what delivers it. So
`rtc-utc-selftest.sh` asserts the PAIR: that the installer's write is reachable only from a
measurement, that it NAMES the convergence it depends on, and that the named convergence exists.

### The measurement needs a witness that is not the guest's clock

The derivation first compared the guest's clock BEFORE the time pull with its clock AFTER it, and
concluded the convention fitted whenever they agreed. But the script cannot see whether the pull did
anything: qrexec hands dom0's date straight to `set-time.ps1`, whose exit code does not come back
through the client. A pull that changes nothing makes both readings the same number, so the test
could not fail — and it reported `RealTimeIsUniversal=1 matches this qube's RTC convention` four
times on a guest three hours out.

`set-time.ps1` DID see dom0's value, and logs it:

```
SETTIME clock set to 2026-10-15T09:24:50.0000000Z (was -10821.2 s out, now 0 s;
        guest zone FLE Standard Time, offset 02:00:00)
```

dom0's UTC, the pre-set skew (negative when the guest ran ahead) and the guest's offset — all
measured before anything wrote to the clock. From those, what the RTC held is recoverable, and
whether it equals dom0's UTC or dom0's local time names the value Windows should carry. **No
witness, or a zero offset where the two conventions are the same arithmetic, means no decision and a
loud line.** Jev: `detector_is_now_sound` 0.84.

Two defects in reading that witness, both fixed:

* **The offset must be the one IN EFFECT, not the zone's base.** `set-time.ps1` logs
  `(Get-TimeZone).BaseUtcOffset`, which for FLE Standard Time is `02:00:00` all year while the
  offset in effect under DST is `03:00:00`. Using the base value made a real three-hour displacement
  match NEITHER hypothesis, so the convention was never flipped. The block takes the effective
  offset from `[TimeZoneInfo]::Local` and reports both, so the two can never be confused again.
* **The pull is fire-and-forget, so the witness lands after we asked for it.** The client writes the
  request to the guest's own qrexec agent and exits; dom0 then pipes its date into a SEPARATE
  `set-time.ps1` process. Reading the log immediately afterwards finds the PREVIOUS boot's line, or
  nothing — measured on run 13 cell 1, where `CLOCKCONV` refused at `14:18:14.479` while the line it
  needed was written at `14:18:14.305`, 174 ms earlier. `Wait-ClockWitness` now waits, bounded, for
  a witness whose freshness is judged **on content** (dom0's own UTC, close to the clock the pull has
  just corrected) rather than on a file mtime this script moves backwards by hours. Three exits: a
  fresh witness, the deadline with nothing, the deadline with only a stale line — and the last two
  are reported rather than guessed around. `Get-ClockWitness` also picks the newest line BY CONTENT:
  it used to sort files by mtime descending and take the last match the pipeline emitted, which is
  the newest line of the OLDEST file.

### The two fragile moments a correction can touch

Reaching the consistent state EARLIER is better, and the pairing above reaches it at the first
instant of the boot with no correction at all. Where a correction still happens — the one-boot
convergence case — it lands in a boot that has two clock-sensitive moments, and both are now
explicitly protected.

**1. Certificate and catalog validation.** Windows validates driver catalogs against the system
clock, so a guest BEHIND real time rejects a freshly minted CI certificate as not-yet-valid and
`drvinst` waits rather than failing. Protected by `Assert-PayloadClockSane`, which refuses the
install TERMINALLY and EARLY — before a CI certificate is trusted as a machine root CA, before
testsigning, before autologon, before any reboot — and now names the cause and a one-reboot fix
rather than a clock the user must repair by hand.

**2. The timers that bring the agents up.** Both relevant triggers are BOOT-relative and therefore
immune to a wall-clock jump: the clock task is a `BootTrigger` with `Delay=PT15S`, and the `-Auto`
resume task is `ONSTART+30 s`. What is NOT immune is a wall-clock *deadline* that spans the
correction. `(Get-Date).AddSeconds(n)` compared against `Get-Date` breaks in both directions: a
backward correction of dom0's offset — 10800 s, measured — leaves the limit unreached for three
hours, and a forward one expires it instantly. Both bounds in `sync-clock-from-dom0.ps1` are now
`[Diagnostics.Stopwatch]`, which is `QueryPerformanceCounter` and cannot be moved by a clock set:
the retry loop that asks dom0 for the time, and `Wait-ClockWitness`, whose entire purpose is to span
the moment `set-time.ps1` sets the clock. The clock READINGS stay on the wall clock on purpose —
comparing dom0's own stamp against our just-corrected clock IS the measurement.

That split is tested rather than asserted: `clock-convention-selftest.sh` PART J stubs `Get-Date` to
hand out the real time once and three hours earlier on every call after it, which is the shape of
the correction. With the monotonic bound the wait returns; reverting that one line to the wall clock
makes it hang past a 25 s limit (verified, rc=124).

### An RTC that fits neither convention is an anomaly

On Xen the RTC is emulated by the hypervisor itself, and a guest's *write* to it is intercepted,
broadcast as a `TIMEOFFSET` ioreq, relayed by QEMU and persisted by the toolstack at
`/vm/<uuid>/rtc/timeoffset` — surviving restarts. Setting the system clock writes the RTC, so a
subject that has been corrected on every boot for weeks can hold an RTC that matches neither
hypothesis. Measured on `win10-acc`, which read dom0-local **plus three hours** after a
correct-and-reboot cycle. The derivation says so loudly and changes nothing in that case: a wrong
guess would be worse than the puller we already have.

This is also why a used subject cannot validate this decision. The measurement that matters comes
from a fresh install on a golden rebuilt without a forced value.

## Enforcement, because prose did not hold

Every layer that forced the value carried a comment saying why it was right, and the forcing
survived three campaigns of chasing one symptom each. The deviation was found only by writing the
invariant down and grepping every file that touches it.

* `tools/lint-harness.py` **L26** — exactly two writers, both in the product, both writing a
  variable; and no `qvm-features --unset … timezone` anywhere. Seen to fail: planting a forced write
  in an answer file is reported at that file and line. Exempt: the rule's own regex and
  `tools/tests/`, which must contain the shape to prove they catch it.
* `tools/tests/rtc-utc-selftest.sh` — the invariant, including that BOTH halves exist, with a
  mutation that turns the derived write back into a constant and is seen to fail.
* `tools/tests/clock-convention-selftest.sh` — runs the shipped decision block with the registry and
  the log stubbed, including the stale-witness, fresh-witness and content-selection cases.
* `clock_boot_correction_s` (P1, max 60) — the acceptance witness. With nothing forcing the value, a
  correctly-paired guest needs no mid-boot correction at all.

## Rejected

* **`xenagent`'s `HostTime=UTC`.** The vendor documents a registry knob on the PV drivers' agent that
  derives UTC from the hypervisor clock. It does not exist in the version we ship: `HostTime` and
  `TimeSyncMode` appear zero times in `xenagent_9_1_0_0.exe`, and the `Xen Project\Windows PV
  Drivers` key is absent on our guests. The agent IS running and does call `SetSystemTime`, so it is
  a third actor on the clock — we simply cannot configure it at this version.
* **Clearing the qube's `timezone` feature from the harness.** It makes the RTC hold true UTC, which
  makes `RealTimeIsUniversal=1` true — on the rig only. A user's qube keeps `localtime`, so this put
  the rig in the one configuration where a shipped defect is invisible. Jev 0.84. Removed from all
  four create paths and refused by L26.
* **Forcing the value in the images, and patching it into a sealed golden in place.** Both are the
  gate measuring our own forcing. The goldens are rebuilt from vendor media with the corrected
  answer files rather than edited (owner: "redo from scratch, dont reuse"), so a golden is what the
  answer file would now produce rather than a patched copy of what it used to.
* **Removing the product's write entirely.** The Windows default paired with dom0's zone is correct
  for a qube in service, but a guest that has been MEASURED behind the payload's certificates cannot
  install anything and has no time source to fix itself with; Jev scored `remove-every-write` at
  0.08. The write stays — on that branch only.
* **Deriving the installer's value from whether QWT is installed, and writing it on every install.**
  An intermediate version of this decision did that: no QWT meant the qube had never reported, so
  its RTC held true UTC, so write 1. Jev scored that derivation at ~0.60 and named its residual at
  0.90 — a clean install onto a qube dom0 has ALREADY flagged, which is every reinstall cell and
  every user reinstalling Windows in an existing qube, sees no QWT while the RTC already holds dom0
  local. The owner's rule settled it: take the normal initial configuration and do not touch it
  until it is needed, exactly when it is needed. A guess on every install is not that; the gate's
  own verdict is.
* **Asking dom0 to publish or change anything.** Out of scope by standing rule, and unnecessary: the
  guest already has everything it needs in `/qubes-timezone` plus the time it pulls at every boot.

## Not done

* **`win11de-qwt` is corrected IN PLACE, not rebuilt** — the owner's distinction: where QWT is
  present the value can be fixed on the run, and only the rest needs a redeploy. This golden carries
  QWT, so qrexec answers; its defect is one registry value, where `win10-base`'s is its provenance.
  Rebuilding it would also need German vendor media and a base `rebuild-rig` deliberately excludes.
  The operation is one authorised boot under `GOLDEN_UNSEAL`, a DELETE of the value (absent is
  Windows' default — 0 would be the same instruction with an extra claim), a read-back, a clean
  shutdown and a re-seal whose reason carries the measured before/after. The seal is rewritten
  whatever the outcome, because `revisions_to_keep` is 2 and the boot alone rotates the revisions the
  previous seal named; a failed revert therefore produces a seal that says so.
* The goldens acceptance DOES enter from — `win10-base` and `win11r-base`, plus the `-iqi` and
  `-tpl` fixtures built from them — are rebuilt from vendor media with the corrected answer files.


* The pairing has not yet been measured on a fresh install from a golden rebuilt without a forced
  value. That measurement is the acceptance run after the golden rebuild; until it reports
  `clock_boot_correction_s = 0`, the enforcement is reasoned, Jev-confirmed and offline-tested, but
  not witnessed on a guest.
* `/qubes-timezone` carries an IANA name and `tzutil` takes Windows zone ids. The installer maps the
  common zones and REPORTS anything it cannot map rather than guessing; an unmapped zone therefore
  leaves the guest's zone alone while the RTC convention may have changed, and those two then
  disagree.
* The installer's map is duplicated in the installer only; the per-boot task does not set the zone,
  so a guest whose install-time qubesdb read fails keeps its previous zone until the next install.
