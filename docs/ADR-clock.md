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

* The pairing has not been measured on a FRESH install. Every reading so far comes from a subject
  with months of clock-write history (see the anomaly above). That measurement is the acceptance run.
* `/qubes-timezone` carries an IANA name and `tzutil` takes Windows zone ids. The installer maps the
  common zones and REPORTS anything it cannot map rather than guessing; an unmapped zone therefore
  leaves the guest's zone alone while the RTC convention has changed, and those two then disagree.
* The installer's map is duplicated in the installer only; the per-boot task does not set the zone,
  so a guest whose install-time qubesdb read fails keeps a UTC zone until the next install.
