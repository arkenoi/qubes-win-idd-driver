# ADR — the guest clock: whose convention the hardware clock follows

## CURRENT STATE

AUTHORITATIVE. Maintain by editing in place; never append dated sections (the pre-commit hook
refuses them).

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

So a correct Qubes Windows guest is: `RealTimeIsUniversal` **0**, and the guest's own timezone equal
to dom0's — which Qubes publishes to every qube in qubesdb as `/qubes-timezone` (an IANA name such
as `Europe/Sofia`). Then `guest_UTC = RTC − dom0_offset = dom0_local − dom0_offset = real UTC`,
right from the first instant of the boot, with nothing to correct.

## The decision, and why it is not a constant

**The correct value changes during a guest's life**, because the extension above is driven by what
the guest REPORTS, not by what dom0 already knows. Both `guest_os` and `qrexec` are read out of the
`untrusted_features` payload of a `features-request` event, which our own agent triggers by calling
`qubes.NotifyTools` when it first starts. Setting `qvm-features <vm> os Windows` from dom0 does not
trigger it.

| phase | RTC holds | correct `RealTimeIsUniversal` |
|---|---|---|
| Windows Setup and the first install, before QWT reports | true UTC | **1** |
| every boot after dom0 has set `localtime` | dom0 local | **0** |

Measured independently: `win10-base` (pristine, no QWT) and a fresh `qvm-create` qube have the
feature unset; every QWT-carrying guest has `localtime`.

Each window has a real failure mode, and both have been observed:

* **Getting it wrong early breaks driver installation.** A true-UTC RTC read as local puts the guest
  BEHIND real time by its own zone offset, and Windows validates driver catalogs against the clock —
  a certificate minted on the CI runner then looks *not yet valid*. Measured 2026-09-25 on a German
  25H2 guest: `0x800B0101`, with `drvinst` sitting at 0.125 s of CPU for twenty-five minutes rather
  than failing. The rig never reproduced it because every rig image is pinned to UTC, where that
  offset is zero.
* **Getting it wrong later puts the guest dom0's whole offset ahead, for ever.** Measured 2026-10-15
  on a live guest: `RealTimeIsUniversal=1`, guest timezone UTC, guest clock `10:38:51Z` against a
  real UTC of `07:38:40Z` — exactly +10800 s. Ahead is harmless to the catalog gate, which is why it
  survived unnoticed while our own clock puller re-corrected it on every boot and the log analyser
  silently shifted the timestamps.

So the installer and the answer files write **1**, which is right for their window and harmless
afterwards, and the per-boot task **derives** the convention and flips the value when it no longer
fits (`CLOCKCONV` in `guest/sync-clock-from-dom0.ps1`). The derivation is possible because that task
has just learned real UTC from dom0: inverting what the guest believed gives what the RTC actually
holds, and comparing that against real UTC says which convention fits. The write takes effect at the
next boot, so a guest converges within one boot instead of being corrected for ever.

**Either half alone is a shipped defect.** 1 without the convergence is the +3 h we shipped. 0 in the
installer reintroduces the twenty-five-minute hang. A constant cannot be right in both windows.

### An RTC that fits neither convention is an anomaly

On Xen the RTC is emulated by the hypervisor itself, and a guest's *write* to it is intercepted,
broadcast as a `TIMEOFFSET` ioreq, relayed by QEMU and persisted by the toolstack at
`/vm/<uuid>/rtc/timeoffset` — surviving restarts. Setting the system clock writes the RTC, so a
subject that has been corrected on every boot for weeks can hold an RTC that matches neither
hypothesis. Measured on `win10-acc`, which read dom0-local **plus three hours** after a
correct-and-reboot cycle. The derivation says so loudly and changes nothing in that case: a wrong
guess would be worse than the puller we already have.

This is also why a used subject cannot validate this decision. The measurement that matters comes
from a fresh install, where the persisted offset starts at zero.

### Who owns the value: the product, from a measurement

**The harness must not write it, and that was the whole bug.** `mgmt/harness/rtc-lib.sh` used to
carry `w_rtc_utc`, which did `reg add ... RealTimeIsUniversal /d 1` inside the subject, and
`prime-run.sh` called it the moment qrexec answered — after the install. So whatever the installer
and the per-boot task derived was overwritten on every primed subject, and the gate could not
measure the product at all. `set-rtc-utc-golden.sh` did the same to a sealed golden, so every clone
inherited a forced value too.

Measured on run 11: the installer logged `clock: RealTimeIsUniversal set to 0 for the next boot
(was 1)` and the boots that followed ran with **1** and a three-hour error.

Only one of the two values is correct for a given qube, and which one depends on a dom0-side feature
set at runtime in response to the guest reporting in. A harness cannot know that, so it has no
business deciding it. It now only REPORTS, via `w_rtc_report`, which prints the value *and* the zone
so a cell's verdict can be read against both. Jev: `report_not_decide_is_right` 0.94.

### The measurement needs a witness that is not the guest's clock

The per-boot derivation first compared the guest's clock BEFORE the time pull with its clock AFTER
it, and concluded the convention fitted whenever they agreed. But the script cannot see whether the
pull did anything: qrexec hands dom0's date straight to `set-time.ps1`, whose exit code does not come
back through the client. A pull that changes nothing makes both readings the same number, so the test
could not fail — and it reported `RealTimeIsUniversal=1 matches this qube's RTC convention` four
times on a guest three hours out.

`set-time.ps1` DID see dom0's value, and logs it:

```
SETTIME clock set to 2026-10-15T09:24:50.0000000Z (was -10821.2 s out, now 0 s;
        guest zone FLE Standard Time, offset 02:00:00)
```

dom0's UTC, the pre-set skew (negative when the guest ran ahead) and the guest's offset — all
measured before anything wrote to the clock, which is exactly what the decision needs. From those,
what the RTC held is recoverable, and whether it equals dom0's UTC or dom0's local time names the
value Windows should carry. **No witness, or a zero offset where the two conventions are the same
arithmetic, means no decision and a loud line.** Jev: `detector_is_now_sound` 0.84.

### What `clock_boot_correction_s` actually measures

I claimed twice that this metric was an artefact — first that it counted an unavoidable install-era
boot, then that the sweep was reading QWT's local-time log stamps as UTC. **Both were wrong.**
`detect_clock_offset` finds a BACKWARD JUMP between consecutive lines of one log file, which nothing
but a real mid-boot correction produces. The sweep was right every time. Forcing `1` on a qube whose
RTC holds dom0 local made the guest boot dom0's offset ahead, the puller corrected it back, and that
correction *was* the jump.

The lesson is the method rather than the arithmetic: the deviation was found by writing the invariant
down and grepping every file that touches it — seven deviations across five harness files, a
golden-baking script, two selftests and three stale comments — after three campaigns of chasing one
symptom each. One of the target state's own entries was withdrawn by that same exercise.

## Rejected

* **`xenagent`'s `HostTime=UTC`.** The vendor documents a registry knob on the PV drivers' agent that
  derives UTC from the hypervisor clock. It does not exist in the version we ship: `HostTime` and
  `TimeSyncMode` appear zero times in `xenagent_9_1_0_0.exe`, and the `Xen Project\Windows PV
  Drivers` key is absent on our guests. The agent IS running and does call `SetSystemTime`, so it is
  a third actor on the clock — we simply cannot configure it at this version.
* **Clearing the qube's `timezone` feature from the harness.** It makes the RTC hold true UTC, which
  makes `RealTimeIsUniversal=1` true — on the rig only. A user's qube keeps `localtime`, so this puts
  the rig in the one configuration where a shipped defect is invisible. Jev: 0.84 that it hid the
  defect from the gate. Removed; the harness now only reports which convention a cell ran under.
* **Asking dom0 to publish or change anything.** Out of scope by standing rule, and unnecessary: the
  guest already has everything it needs in `/qubes-timezone` plus the time it pulls at every boot.

## Not done

* The pairing has not yet been measured on a fresh install with the harness no longer forcing the
  value. That measurement is the acceptance run against sha 425fb58a; until it reports
  `clock_boot_correction_s = 0`, the enforcement is reasoned and Jev-confirmed but not witnessed.
* `/qubes-timezone` carries an IANA name and `tzutil` takes Windows zone ids. The installer maps the
  common zones and REPORTS anything it cannot map rather than guessing; an unmapped zone therefore
  leaves the guest's zone alone while the RTC convention has changed, and those two then disagree.
* The installer's map is duplicated in the installer only; the per-boot task does not set the zone,
  so a guest whose install-time qubesdb read fails keeps a UTC zone until the next install.
