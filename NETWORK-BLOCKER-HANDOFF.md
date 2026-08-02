# Networking blocker — RESOLVED 2026-08-02: the netvm was mirage-firewall

## ROOT CAUSE (found by the user)

The netvm in use for every failing test was **`fw-net` = qubes-mirage-firewall**, a MirageOS
unikernel. Switching the Windows qube to a conventional (Linux-based) netvm released the
hang immediately. Nothing on the guest side was ever at fault.

Mechanism, consistent with all telemetry below: the Windows PV network frontend never
completes its handshake against mirage-firewall's netback, so `xenvif` never starts, no
`XENVIF\...&DEV_NET` child is enumerated, `xennet` is never installed, `Unplug\NICS` is
never armed, and the guest spins ~2 cores in PnP retry with qrexec starved out. Detaching
the netvm removes the frontend and the guest recovers.

**Everything in the sections below was measured against that constant.** They remain useful
as evidence and as a record of what was eliminated, but the conclusion each was reaching for
("upstream QWT defect", "our deploy machinery", "PV driver regression") is WRONG. The one
variable never tested was the other end of the vif.

### What this explains at a stroke
- Stock QWT 4.2.2 starving identically to our fork (the netvm was the shared constant).
- Win10 AND Win11 qubes both failing (same netvm).
- Feature set, vCPU count, memory, MSI byte-identity, offline-install timing all coming back
  negative — every one of them was a guest-side variable.
- The user's long-lived Windows qube working fine: conventional netvm, traffic over the
  emulated Realtek NIC, PV networking never involved.
- Community users on Qubes 4.3 reporting success: `sys-firewall`, not a unikernel netvm.

### Status of the fix
User-confirmed on their side ("the lock released itself"). NOT yet re-measured on
`win-idd-test`: this qube's policy only permits referencing `fw-net`, so the A/B on identical
hardware needs the user to point it at a conventional netvm (or name it for me).

### Worth reporting upstream
A Windows HVM with QWT 4.2.2 PV drivers (Xen Project 9.1.0) cannot use qubes-mirage-firewall
as its netvm; it hangs the guest rather than merely failing to get a link. Candidate venues:
qubes-mirage-firewall and qubes-issues (C: windows-tools). The source-verified frontend flow
in `ci-notes/xenvif-start-flow.md` plus the telemetry below is enough material for a report.
Before filing, capture the mirage side's view (xenstore backend state for the vif) — nothing
we have shows how far the backend handshake got.

---

# Historical record (pre-root-cause investigation)



Self-contained brief for a session that has not seen the earlier work. Read this before
touching anything network-related. Companion documents: `ci-notes/xenvif-start-flow.md`
(source-verified driver flow + decision tree), `FINDINGS.md` entries dated 2026-08-01 and
2026-08-02. **Section 6 lists experiments that must NOT be repeated** — several plausible
ones are already known to produce no new information at ~30–60 min each.

---

## 1. The symptom, stated precisely

`win-idd-test` is a Win10 22H2 Pro standalone HVM with Qubes Windows Tools 4.2.2 (our
from-source rebuild; PV drivers are the stock, byte-identical ITL/Xen Project 9.1.0 bits).

With **no netvm**, everything works: qrexec answers in ~20–60 s, seamless GUI, full display
acceptance suite passes.

With a netvm (`fw-net`) attached — whether attached while halted and then booted, or
hot-attached to a running guest — the guest becomes unusable:

* ~2.0 cores burned continuously (of 4 vCPUs), indefinitely;
* qrexec never connects (attach-at-boot) or dies within seconds (hot-attach);
* no gui-agent windows in dom0;
* ACPI shutdown is not serviced (ignored for 7+ minutes; the guest must be destroyed);
* detaching the netvm and rebooting restores full health.

The PV network driver never comes up, so the guest has no network either way. **A Windows
qube that cannot have a netvm is not a working qube**, so this blocks shipping regardless of
how good the display side is.

## 2. What is NOT the cause (each ruled out by evidence, do not re-litigate)

| hypothesis | why it is dead |
|---|---|
| Our gui-agent / display work | Burn occurs with qrexec dead and **zero** gui-agent windows; a post-wedge log census showed **no agent respawn loop** and a near-idle frame thread. The behaviour is identical on builds before and after all display fixes. |
| Missing PV network package in our MSI | `ADDLOCAL` always included `PvDriversNetwork`; DifX staged it; the driver store contains `xenvif.inf` (oem4) **and** `xennet.inf` (oem5). |
| Driver-store / publisher-trust failure | `setupapi.dev.log` shows the xenvif install **succeeding**: `Driver INF - oem4.inf`, `Created new service 'xenvif'`, `Hardlinking … xenvif.sys`, then `Start:`. testsigning is `Yes`. |
| "The unplug was armed and lost by a hard kill" | `Services\XEN\Unplug\NICS` is **consumed (deleted) by xen.sys on every boot** (`xen/unplug.c:263`), so its absence on a later boot is the *normal* state and proves nothing. My session-6 conclusion here was wrong and is retracted. |
| "We used `qtest kill` instead of a graceful reboot, so the two-boot dance never got a fair test" | Retested properly (§4). The graceful path is **unexecutable**: an attached guest never becomes responsive enough to service ACPI. Kill is forced, not chosen. |
| Byte-identity argument ("our PV drivers are stock, so stock behaves the same") | Rejected as reasoning — byte identity is not behavioural proof. It remains **untested**: see §7.1. |

## 3. Source-verified mechanism (what *should* happen)

From the pinned upstream sources (`upstream/ro/qubes-vmm-xen-windows-pvdrivers` →
xenbits `pvdrivers/win`, xenvif `9fd1afe`, xenbus `e76d03e`, all DriverVer 04/07/2025 9.1.0,
vendor prefix `XP`). Details and file:line in `ci-notes/xenvif-start-flow.md`.

1. xenbus enumerates a VIF PDO: `XENBUS\VEN_XP0001&DEV_VIF&REV_0900000A`.
2. **xenvif** binds and starts on it (function driver for that PDO).
3. A started xenvif enumerates a child `XENVIF\VEN_XP0001&DEV_NET&REV_09000005`.
4. **xennet** installs on that child. Its `PdoStartDevice` (`xenvif/src/xenvif/pdo.c:1405,
   1439-1445`) writes `Services\XEN\Unplug\NICS`, calls `DriverRequestReboot`, and fails the
   start with `STATUS_PNP_REBOOT_REQUIRED` (device problem code **14**). `RawDeviceOK=0`, so
   **xennet must already be installed for the arm to ever run**.
5. `xenbus_monitor` pops a modal "restart required" dialog and **waits forever** — QWT sets no
   `AutoReboot`/`PromptTimeout`. Boot 1 never reboots itself; this is normal upstream
   behaviour, not a hang.
6. On the **next** boot, `xenfilt` (boot-start) calls `UnplugDevices` during early PCI
   enumeration (`xenbus/src/xenfilt/driver.c:323`, gated by `DriverIsActivePresent()` at
   `:283`), which consumes `NICS` and writes port 0x10 to make QEMU detach the emulated
   RTL8139, before NDIS binds it. Veto conditions: `NICS==0`, no `Enum\XENBUS\*VIF*` key
   (`xen/unplug.c:212`, logs `VETO Unplug VIF`), `ActiveDeviceID` device absent, Safe Mode, or
   QEMU blacklisting the protocol.

## 4. Telemetry — the fair two-boot retest (2026-08-02)

Protocol: healthy detached boot first (qrexec OK, forensics collected) → **graceful** ACPI
shutdown (**halted in <10 s**, proving the guest shuts down cleanly when healthy) → `fw-net`
attached **while halted** → boot. Raw CSVs:
`instrumentation/qwtfull-w10/netvm-netvm-boot1.csv`, `…-boot2.csv` (columns:
`elapsed_s,cputime_ns,delta_cores,qrexec`, sampled every ~35 s).

| boot | netvm | duration observed | CPU | qrexec | outcome |
|---|---|---|---|---|---|
| 1 | attached | 15 min soak | 0.00 → 1.34 cores by 58 s → **2.00 cores sustained, 93 s–618 s (16 consecutive samples, mean 2.00)** | never up (27/27 probes down) | ACPI shutdown sent, **ignored 7+ min**, destroyed |
| 2 | attached | 8+ min | **2.02 cores** (independent 30 s measurement) | never up | no unplug, no progress; destroyed |
| 3 | detached | 15 min | **0.05 cores (idle)** | never up* | *this boot was Windows sitting pre-desktop after two unclean shutdowns — see note |
| recovery | detached | — | normal | **up in 20 s** | full health restored |

Note on boot 3: idle-but-dead is a *different* state from the starvation (0.05 vs 2.0 cores) —
it was WinRE/repair after two consecutive unclean shutdowns, not the netvm defect. It is the
reason the install was subsequently wiped and reinstalled.

Hot-attach flavour (measured twice, sessions 3 and 6): worse — ~3.8/4 cores, qrexec dies,
dom0 shows no seamless windows, and unlike the boot-time flavour it did **not** recover on
detach; the domain had to be destroyed.

## 5. Telemetry — in-guest forensics (healthy boot, netvm detached)

From `tools/netforensics.ps1`; raw output
`instrumentation/qwtfull-w10/netforensics-prerestest.txt`. This is the decisive evidence set.

```
ENUM  VEN_XP0001&DEV_CONS / DEV_IFACE / DEV_VBD / DEV_VIF     <- VIF PDO exists
XENVIF enum section                                    EMPTY  <- no Enum\XENVIF key at all
xenvif Settings section                                EMPTY
xenbus_monitor Request section                         EMPTY  <- no reboot ever requested
XEN Unplug values section                              EMPTY  <- no NICS (expected, see §2)
XENFILT ActiveDeviceID=PCI\VEN_5853&DEV_0001&SUBSYS_00015853&REV_01
XENFILT ActiveInstanceID=10                                   <- unplug gate satisfied
SVC xenvif  status=Stopped  start=3        SVC xennet status=absent start=-
SVC xenbus  status=Running  start=0        SVC xenfilt status=Running start=0
SVC xeniface status=Running start=3
PNP [Unknown] Xen PV Network Class :: XENBUS\VEN_XP0001&DEV_VIF\_   problem=(blank)
PNP [OK]      Xen PV Bus (0001) :: PCI\VEN_5853&DEV_0001&…
FILE xenvif.sys  ad6952d4…  262664 B      FILE xenbus.sys 68907f1f…  185352 B
FILE xennet.sys  ABSENT                   (xennet.inf IS in the store as oem5)
setupapi: [Device Install (Hardware initiated) - XENBUS\VEN_XP0001&DEV_VIF\_]
          Driver INF - oem4.inf (…\xenvif.inf), Configuration XENBUS\VEN_XP0001&DEV_VIF&REV_0900000A
          {Add Service: xenvif} → "Created new service 'xenvif'" → Hardlinking xenvif.sys → Start:
          (NO corresponding install section for XENVIF\…&DEV_NET anywhere)
BCD testsigning Yes
```

**What this pins down.** The chain reaches step 2 and stops. xenvif is installed correctly and
its service exists, but the service is `Stopped` with `Start=3` (demand) and **never enumerated
a NET child** (`Enum\XENVIF` does not exist). Because `RawDeviceOK=0`, no xennet means the
arming code at `pdo.c:1405` can never execute — so "no NICS", "no unplug", "no reboot dialog"
are all *downstream consequences of a single upstream failure*, not independent problems.
The failure is: **xenvif does not start (or starts and finds no frontend), on a device Windows
believes is fine.**

Caveat that must be respected: all of §5 was captured on a boot with the netvm **detached**,
where a stopped xenvif and a phantom "Unknown" devnode are the *expected* healthy state. It
establishes what persists across boots; it does **not** show what happens during an attached
boot. That gap is exactly what §7.2 is for, and it is the single biggest hole in the evidence.

## 6. Do NOT do these — measured, no new information, ~30–60 min each

1. **Do not re-run the "graceful two-boot dance."** Tried under correct conditions; boot 1
   never becomes responsive enough for ACPI, so a clean reboot between boots cannot be
   produced from inside the guest. Repeating it just costs two destroys.
2. **Do not repeat plain attach → boot → measure cycles without new instrumentation.** Five
   such boots exist (2 this session, 3 earlier). Every one produced the same numbers:
   ~2 cores, qrexec down, no xennet. The signature is fully established **within 60–90 s** —
   a 15-minute soak adds nothing. If you must confirm the state, 2 minutes suffices.
3. **Do not hot-attach expecting different behaviour from boot-attach.** Measured twice;
   worse and unrecoverable without a destroy.
4. **Do not collect netforensics on a detached boot again.** §5 is that data; re-running it
   yields byte-identical results and cannot answer the open question by construction.
5. **Do not reason from `Unplug\NICS` being absent, or from `xenvif Stopped`, on a detached
   boot.** Both are the documented healthy state (§2, §3). Two earlier sessions burned time
   on this.
6. **Do not `qtest kill` a guest you are trying to diagnose before you have its logs** — and
   do not read a slow guest as a dead one: use probe timeouts ≥40 s and confirm with a
   cputime trend. Premature destroys cost this session two evidence sets.

## 7. What WOULD produce new information, in priority order

### 7.1 Stock-QWT control install — the decisive experiment (ready to run)
Everything is prepared: `~/win-iso/win-idd-unattended-stock.iso`, verified so that its staged
`payload/installer.msi` is **bit-identical to the vendored stock ITL MSI**
(`vendor/qwt-4.2.2/installer.msi`, sha256 `70493221…`), with autounattend and every other
payload file hash-identical to the media used for our own builds — the MSI is the only
difference. Procedure: clear guest-advertised features (`qvm-features --unset win-idd-test
qrexec`; `gui ''`; `gui-emulated 1`), `udisksctl loop-setup --read-only`, `qvm-start
--cdrom=win-idd-mgmt:loopN`, babysit with `mgmt/win-install-watch.sh` (~25 min), then attach
`fw-net` while halted and take **one** 2-minute measurement.
* Stock also starves → defect is upstream/environmental (PV drivers vs this Xen/Qubes 4.3
  combination). We are cleared and it becomes an upstream issue worth filing with this data.
* Stock works → the defect is ours, and the search narrows to what our MSI rebuild changed
  around driver packaging/ordering.

Cost: one install cycle. This is the only experiment that discriminates, so run it before
any further theorising.

### 7.2 In-guest telemetry *during* an attached boot (the missing evidence)
qrexec is dead exactly when we need data, so instrument **before** attaching. Both tools
already exist in-repo:
* `tools/netvm-instrument.ps1` — registers a SYSTEM scheduled task (at startup + every 2 min)
  that appends `tools/netforensics.ps1` output to `C:\netforensics-boot.log`; it self-tests
  before you go blind (`RESULT=OK samples=N`). Collect the file on a later detached boot.
* `tools/burnwatch.ps1` — 5 s-interval recorder to `C:\burnwatch.log`: per-process CPU
  deltas, `% Interrupt Time` / `% DPC Time` / `% Processor Time`, xenvif/xennet service state,
  `Enum\XENVIF` presence, `NICS` value. **This answers the question the whole investigation
  turns on: is the burn a user-mode process, or kernel DPC/interrupt time?** Nothing measured
  so far distinguishes those.
Note the current guest is a fresh install (`b299011`) that has never had a netvm attached, so
both tools must be installed on it first. This is one boot with genuinely new data — unlike §6.2.

### 7.3 dom0-side data (requires the user; this qube cannot)
* `xenstore-ls` of the domain while the netvm is attached: does a `device/vif/0` frontend/
  backend area exist, and what state does it reach? If the backend never reaches state 4, the
  guest side is blameless and the problem is the vif backend / netvm side.
* Guest console log `/var/log/xen/console/guest-win-idd-test.log`: xen.sys/xenfilt print
  `UNPLUG: PRE-AMBLE (DRIVERS [NOT ]BLACKLISTED)`, `UNPLUG: NICS`, `VETO Unplug VIF`,
  `ACTIVE DEVICE [NOT ]PRESENT`. These lines settle the unplug-gate questions directly and are
  invisible from inside the guest.
* Whether `fw-net` itself is healthy for this domain (other qubes on it work?).
Ask the user for these; do not attempt dom0 access.

### 7.4 Cheap configuration probes (only after 7.1/7.2)
* vCPU count 4 → 2 (`qvm-prefs`, dom0 — ask): #10932/#10427 suggest 4 vCPUs can itself glitch
  this stack, and a 2-core guest would change the "2.00 cores" signature meaningfully.
* `xen-pciback`/emulated NIC model: the unplug protocol targets the emulated RTL8139; confirm
  what device model this HVM actually presents.

## 8. One-line summary for the next session

xenvif installs cleanly and its service exists, but it never starts a NET child, so xennet is
never installed, so the emulated-NIC unplug is never armed and the guest burns ~2 cores with
qrexec dead for as long as a netvm is attached; every "why didn't the unplug happen" question
is downstream of that single failure, the evidence gap is what happens *during* an attached
boot (§7.2), and the experiment that assigns blame is the stock-QWT control install (§7.1).

---

# UPDATE 2026-08-02 (later) — stock control run, and what it did NOT settle

## Stock-QWT control: ran, and the result is a trap for the unwary
Stock QWT 4.2.2 (`gui-agent.exe` 80968 B, sha `3d2e6bce…`, distinct from ours) installed on a
wiped disk from `win-idd-unattended-stock.iso`, netvm attached while halted:

| build | cores burned | qrexec |
|---|---|---|
| ours (`a459f0e` / `b299011`) | 2.00 sustained | never |
| **stock 4.2.2** | **1.92–1.99, 8/8 samples** | **never** |

**This exonerates our agent fork and NOTHING ELSE.** The control swapped the MSI *bytes* while
keeping our unattended ISO, our `install-qwt.cmd`, our `ADDLOCAL`, and our qube-creation
parameters. Everything those share remains untested by it. I initially wrote this up as
"upstream/environmental, we are cleared" — that was wrong and the user corrected it.

## Additional variables eliminated by measurement (each an attach + <=4 min sample)
| variable | outcome |
|---|---|
| feature set: our 4-feature `ADDLOCAL` vs `ADDLOCAL=ALL` (adds PvDriversDisk/MoveUsers/Autologon) | identical failure, 1.89–1.98 cores |
| vCPUs 4 vs 2 | identical failure (on 2 vCPUs that is both cores pegged) |
| memory 8192 | community script uses 2048; user states not the cause |
| offline install (no netvm at QWT install time) | community script ALSO installs with `netvm ""` — not a difference |
| MSI provenance | our vendored MSI is byte-identical to the official R4.3 dom0 RPM's ISO copy (`70493221…`) |
| OS version | Win10 22H2 AND Win11 24H2 both fail (user's observation) |

## POSITIVE CONTROL — the same machinery works for storage in the same guest
With `PvDriversDisk` installed: xenvbd started, armed `Unplug\DISKS=1`, requested a reboot
(the user saw the modal "Xen PV Storage Host Adapter needs to restart the system" dialog —
exactly the `DriverRequestReboot` path from `ci-notes/xenvif-start-flow.md`), the emulated IDE
was unplugged, and the disks are now `XENSRC PVDISK`. So arm → reboot → unplug is FUNCTIONAL
in this guest. Only the network branch never reaches it: `Enum\XENVIF` stays empty, `NICS`
never armed, and after a re-install the VIF devnode reverts to raw `[Unknown] XP0001 XENBUS VIF`
with no `xenvif` service at all.

## What the guest looks like while starved (user observation — I am blind here)
"High CPU load in guest but nothing comes up" — **no dialog on screen**. So the starvation is
NOT a modal prompt nobody can click; the guest is genuinely wedged. This kills the boot-1
reboot-dialog explanation for the netvm case.

## Reference guest data (user's long-lived working Windows qube)
- PV drivers **xenbus 8.2.23, xeniface 8.2.2.1** — the 8.2.x generation, vs our 9.1.0 (2025-04-07).
- **Networking there runs over the EMULATED Realtek NIC and always has.** PV `xennet` is not
  what carries traffic. So a working Windows qube does NOT require the PV network path at all.
- That guest is now itself degraded (qrexec unreliable), so it is not a clean reference.
- **No older QWT is obtainable to test**: `qubes-windows-tools-4.1.68/4.1.69/4.1.70` RPMs in the
  r4.1/r4.2 repos are PLACEHOLDERS (a symlink to a 164-byte README, no binaries) post-QSB-091.
  4.2.2 from the R4.3 dom0 RPM is the only real QWT available.

## Community project (`ElliotKillick/qvm-create-windows-qube`) — what it says
- Its QWT source is the same `/usr/lib/qubes/qubes-windows-tools.iso` dom0 file we used.
- It installs via the **Burn bundle** (`start qubes-tools-*.exe /passive`) = default feature set,
  where we drive `msiexec` with an explicit `ADDLOCAL` subset. Tested — not the cause (above).
- Issue #99 "completely broken in Qubes 4.3 with Windows 10 & Windows 11" (open). A May 2026
  comment reports Win10 on 4.3 **working**, with unrelated rough edges; their networking issue
  was dom0-side (`reject with icmp admin prohibited`, fixed by `qvm-firewall <vm> reset`).
- Issue #85 "Windows do not have network access" (open, 2024) — undiagnosed.
- Neither describes a guest burning ~2 cores with qrexec dead. Our failure mode is not
  documented anywhere public that I could find.
- ⇒ QWT 4.2.2 + netvm on Qubes 4.3 apparently CAN work, which points back at our qube-creation
  or provisioning path rather than the package.

## Next step in flight
User is building a Windows qube manually via the community script; that qube is the missing
positive control. When it exists, diff EVERY `qvm-prefs`/`qvm-features` value and the guest's
PV device state against `win-idd-test`. Also in flight here: removing ONLY the PV network
drivers (xenvif/xennet) from our guest so it must use the emulated Realtek like the user's
working guest — if the burn disappears, the 9.1.0 PV net driver is the burner and emulated
networking is a viable workaround.
