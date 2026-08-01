# xenvif start / NIC-unplug flow — source-verified reference (2026-08-02)

Purpose: settle the netvm-attach blocker (SESSION-HANDOFF-qwt-full.md "BLOCKER" +
"EVIDENCE GATHERED") against the *actual shipped source*, and give a decision tree for
interpreting `tools/netforensics.ps1` output after a FAIR two-boot test.

Legend: **[V]** = verified by reading the shipped source/INF/MSI listed below.
**[I]** = inferred (standard Windows semantics or reasoning), not read from this tree.

---

## 1. Exact PV driver bits QWT 4.2.2 ships

Extracted from `/home/user/qubes-win-idd-driver/vendor/qwt-4.2.2/installer.msi` (7z; MSI
File table maps mangled `fil...` names → real names; verified via embedded version
resources and INF contents). **[V]**

| package | DriverVer (INF) | file version | files | INF Class | service start |
|---|---|---|---|---|---|
| xenbus  | 04/07/2025, 9.1.0.0 | 9.1.0.0 | xen.sys, xenbus.sys, xenfilt.sys, xenbus_monitor.exe/.dll | System | xenbus: demand (PnP); **xenfilt: BOOT (0x0), group "Boot Bus Extender"**; xenbus_monitor: auto (Win32 service) |
| xenvif  | 04/07/2025, 9.1.0.0 | 9.1.0.0 | xenvif.sys | System | demand (0x3) — **demand-start is the DESIGNED value** (xenvif.inf `[XenVif_Service]`), PnP loads it when the VIF devnode starts; "Start=3, Stopped" is not per se a fault |
| xennet  | 04/07/2025, 9.1.0.0 | 9.1.0.0 | xennet.sys | Net | demand |
| xenvbd  | 04/07/2025, 9.1.0.0 | 9.1.0.0 | xenvbd.sys, xencrsh.sys, xendisk.sys | SCSIAdapter | boot |
| xeniface| 04/07/2025, 9.1.0.0 | 9.1.0.0 | xeniface.sys | System | demand |

Shipped INF identity strings (from the MSI's xenvif.inf): `Vendor="Xen Project"`,
vendor prefix **XP**, device name **"Xen PV Network Class"**, hardware IDs
`XENBUS\VEN_XP0001&DEV_VIF&REV_0900000A` and `VEN_XP0002&...`. **[V]** — this is exactly
the device the forensics saw.

### Source lineage (already cloned — no new clone needed)

`/home/user/qubes-win-idd-driver/upstream/ro/qubes-vmm-xen-windows-pvdrivers` (QubesOS/ITL
repo, HEAD `8cffcc0`) pins the drivers as **git submodules of the upstream Xen Project
repos at xenbits.xen.org/git-http/pvdrivers/win/** (the same code mirrored as
github.com/xenserver/win-xenbus etc.; XCP-ng's xcp-ng/win-xenvif is a further fork —
NOT the QWT lineage): **[V]**

| submodule | commit | describe | build default version |
|---|---|---|---|
| xenbus | e76d03e37550a0889c08be8e2a2caaf299d588c8 | (9.1 line) | 9.1.0 (`xenbus/build.ps1`) |
| xenvif | 9fd1afe4382b15ed8e063a816a328c0a580f038e | 9.0.0-71-g9fd1afe (2024-12-02) | **9.1.0** (`xenvif/build.ps1` MAJOR=9 MINOR=1 MICRO=0) |
| xennet | ad7717f6390b320255680ef3d4c86d4c6833e009 | 9.0.0-rc1-42 | 9.1.0 |
| xeniface | 9cd9a604191bf26da18b564d1686e4ee0ccf3d32 | 9.0.0-55 | 9.1.0 |

The checked-out submodules produce exactly the shipped 9.1.0.0 / vendor-prefix XP bits
(DriverVer date 04/07/2025 = QWT build date). The `sources` file listing 8.2.1 tarballs is
stale legacy metadata — the build uses the submodules. **[V]** All file:line references
below are into these submodule checkouts.

---

## 2. Annotated flow (file:function into the cloned source)

### 2a. Device topology / who creates what **[V]**

```
PCI bus (root \ACPI\PNP0A03) ── xenfilt.sys (BOOT start, upper filter; xenbus.inf
 │                              [XenFilt_Parameters]: filters "*PNP0A03"=PCI, IDE)
 │
 ├─ emulated RTL8139 (QEMU)         ← the thing that must be unplugged
 └─ Xen platform PCI device (5853:0001)
      └ xenbus.sys FDO  ................ xenbus/src/xenbus/fdo.c
          - FdoSetActive() fdo.c:740 (called from FdoStartDevice ~:5762):
            first platform device claims "active" → ActiveDeviceID/ActiveInstanceID
            under Services\XENFILT\Parameters (xen/config.c:54 ACTIVE_PATH,
            ConfigSetActive config.c:190). Children are only enumerated on the
            ACTIVE device (many __FdoIsActive gates in fdo.c).
          - FdoScan thread fdo.c:1339: reads xenstore dir "device" (classes: vif,
            vbd, ...), intersects Services\xenbus\Parameters\SupportedClasses =
            "VIF","VBD","VKBD","IFACE","CONS" (xenbus.inf:96), FdoEnumerate fdo.c:1075
            creates ONE PDO PER CLASS: XENBUS\VEN_XP0001&DEV_VIF&REV_0900000A etc.
            → a VIF PDO exists ONLY while xenstore has device/vif/* — i.e. only while
            a netvm is attached. Hotplug works: a xenstore watch re-triggers FdoScan.
          - xenbus PdoStartDevice (xenbus/src/xenbus/pdo.c) is trivial: D3→D0, always
            SUCCESS. No unplug logic here.
              └ XENBUS\...DEV_VIF PDO  ← "Xen PV Network Class" devnode
                  └ xenvif.sys FDO ..... xenvif/src/xenvif/fdo.c (function driver,
                    matched by xenvif.inf on VEN_XP000{1,2}&DEV_VIF&REV_0900000A).
                    No reboot/unplug logic in the FDO. Its own scan thread
                    enumerates one child PDO per xenstore vif instance:
                      └ XENVIF\VEN_XP0001&DEV_NET&REV_09000005 PDO
                        (xenvif/src/xenvif/pdo.c; RawDeviceOK=0 at pdo.c:1864
                        → Windows will NOT start it without a function driver)
                          └ xennet.sys NDIS miniport (xennet.inf)
```

Consequence for "Xen PV Network Class = Unknown": with the netvm **detached** there is no
`device/vif` in xenstore, so no VIF PDO; the devnode recorded under `Enum\XENBUS\...DEV_VIF`
is a **phantom** and `Get-PnpDevice` reports Status=`Unknown` for phantoms. **[I]** On a
netvm-detached boot, `xenvif Stopped` + Status `Unknown` + `NICS absent` is the EXPECTED
healthy state and proves nothing (see NICS lifecycle below). The 23:35 forensics therefore
did NOT demonstrate a fault — it sampled the wrong boot.

### 2b. Where `Services\XEN\Unplug\NICS` is written **[V]**

The key itself: created non-volatile by xen.sys DriverEntry
(xenbus/src/xen/driver.c: `RegistryCreateSubKey(ServiceKey, "Unplug", REG_OPTION_NON_VOLATILE)`
under `Services\XEN` — xen.sys loads as an export library the moment boot-start
xenfilt.sys loads, i.e. on EVERY boot regardless of netvm).

Writers of the `NICS` value:

1. **INF install time**: both `xenbus.inf [XenBus_Unplug]` (src:107-108) and
   `xenvif.inf [XenVif_Unplug]` (src:90) contain
   `HKLM,SYSTEM\CurrentControlSet\Services\XEN\Unplug,"NICS",0x00010001,0`
   → installing the driver package creates `NICS = 0` (DWORD, unconditional write).
2. **Arming**: xenvif child-PDO start → `PdoUnplugRequest(Pdo, TRUE)`
   (xenvif/src/xenvif/pdo.c:1230) → `XENBUS_UNPLUG(Request, ..., NICS, Make=TRUE)`
   → xenbus/src/xenbus/unplug.c:73 `UnplugRequest` → **`UnplugIncrementValue(UNPLUG_NICS)`
   (xenbus/src/xen/unplug.c:319): read-or-0, increment, `RegistryUpdateDwordValue`** →
   `NICS = 1`. Plain ZwSetValueKey path; **no ZwFlushKey anywhere in the kernel drivers**
   (only the user-mode monitor calls RegFlushKey, on its own Parameters key,
   monitor.c:517/815). **[V]** Persistence relies on the OS lazy hive flusher (~ seconds);
   a domain destroy can lose a recent write, and a guest starved for CPU/IO can widen that
   window considerably. **[I]**
3. **Revoke**: PdoUnplugRequest(FALSE) → UnplugDecrementValue (unplug.c:~380) — happens on
   PDO eject/removal paths.

Gating conditions for the ARM (pdo.c:1439-1445):
```c
status = PdoParseMibTable(Pdo, SoftwareKey);          // pdo.c:1278
if (status == STATUS_PNP_REBOOT_REQUIRED              // an ALIASING emulated NIC with the
                                                      // SAME permanent MAC is currently UP
                                                      // (→ SettingsSave of its IP config)
    || !PdoUnplugRequested(Pdo)) {                    // pdo.c:1257 → XENBUS_UNPLUG(IsRequested)
                                                      // = IN-MEMORY flag "unplug was requested
                                                      // at THIS boot's xen.sys init" — NOT a
                                                      // registry read
    PdoUnplugRequest(Pdo, TRUE);                      // registry NICS++  (the arm)
    DriverRequestReboot();                            // see 2c
    status = STATUS_PNP_REBOOT_REQUIRED;              // start FAILS
    goto fail5;
}
```
So the arm+reboot branch is taken on any boot where the unplug was not performed at early
boot — first install, or any boot where NICS was 0/absent/vetoed. No emulated-NIC
coexistence is required for the arm itself; coexistence (same-MAC adapter Up) only forces
the branch even when unplug already happened, and additionally snapshots the emulated NIC's
TCP/IP settings via `SettingsSave` (xenvif/src/xenvif/settings.c:532) into non-volatile
**`Services\xenvif\Settings\<pdo-name>`** (driver.c:456 creates the Settings key) — a
persistent breadcrumb that this code ran. **[V]**

### 2c. STATUS_PNP_REBOOT_REQUIRED / DriverRequestReboot **[V]**

- Which start fails: the **XENVIF\...DEV_NET child PDO's** IRP_MN_START_DEVICE — i.e. the
  bottom of the *xennet* device stack. It can only be reached after: xenvif.inf installed
  → VIF devnode started (loads xenvif.sys, service→Running) → child NET PDO enumerated →
  **xennet.inf installed from the driver store (RawDeviceOK=0)** → PnP starts the NET stack.
  The handoff's phrase "xenvif PdoStartDevice" is this function
  (xenvif/src/xenvif/pdo.c:1405) but note it is NOT the start of the "Xen PV Network
  Class" devnode — the VIF devnode itself starts fine, xenvif goes Running, and the
  failure/arming happens one level down. Therefore **xennet's service must already exist
  by the time the arm can occur**. The observed "xennet service ABSENT" implies the chain
  broke BEFORE the arming point ever ran.
- DriverRequestReboot (xenvif/src/xenvif/driver.c:249→174): writes
  `HKLM\SYSTEM\CurrentControlSet\Services\xenbus_monitor\Request\xenvif\Reboot = 1`
  (RequestKey from xenvif.inf `Parameters\RequestKey`; the `xenvif` subkey is
  REG_OPTION_VOLATILE → gone after any reboot). Latched once per driver load
  (`Driver.NeedReboot`).
- What Windows does with the failed devnode: PnP marks it problem
  **CM_PROB_NEED_RESTART = 14** ("cannot work properly until you restart"). **[I]**
  (standard mapping for STATUS_PNP_REBOOT_REQUIRED; not in this tree). The VIF devnode
  above it stays started/OK; xenvif and xennet services both show Running (images loaded)
  on that boot. **[I]**
- Who reboots: the user-mode **xenbus_monitor** service (xenbus/src/monitor/monitor.c),
  watching the Request key. `PromptForReboot` (monitor.c:587):
  `TryAutoReboot` (monitor.c:457) reads `Services\xenbus_monitor\Parameters\AutoReboot`
  (max auto-reboot count) — **absent → 0 → no auto reboot**; then it pops a WTSSendMessage
  MB_YESNO box on the active session: *"Xen PV Network Class needs to restart the system to
  complete installation. Press 'Yes' to restart..."* with timeout
  `Parameters\PromptTimeout` — **absent → 0 → waits forever** (IDYES or IDTIMEOUT would
  trigger `InitiateSystemShutdownEx`). **[V]** The QWT 4.2.2 MSI sets NO AutoReboot /
  PromptTimeout (checked the MSI Registry table strings and the ITL installer repo). **[V]**
  ⇒ **on boot 1 the system will NOT reboot itself; it sits at the dialog.** The dialog is
  a first-class forensic marker (it's exactly what Qubes forum thread #5900 shows for a
  working stock install). The "two-boot dance" needs a human/scripted reboot — and it must
  be a GRACEFUL one.
- Expected state BETWEEN boot 1 (armed) and boot 2:
  `Unplug\NICS = 1`; xenvif Running; xennet service exists (Running, image loaded);
  NET devnode problem 14; `Enum\XENVIF\...` key exists; reboot dialog on screen;
  `xenbus_monitor\Request\xenvif\Reboot=1` (volatile). Emulated RTL8139 still present and
  carrying traffic.

### 2d. Early-boot consumption + veto conditions **[V]**

At every boot, xen.sys DriverEntry (xen/driver.c:611) → `UnplugInitialize`
(xen/unplug.c:469) → `UnplugSetRequest(NICS)` (unplug.c:263):

1. Read `Services\XEN\Unplug\NICS`. Absent → nothing.
2. **DELETE the value** (`RegistryDeleteValue`) — consume-once, EVERY boot, even when 0.
3. If value ≠ 0 → `UnplugCheckEnumKey("VIF")` (unplug.c:212): enumerate subkeys of
   `HKLM\SYSTEM\CurrentControlSet\Enum\XENBUS`; if **no subkey name contains "VIF"** →
   `Info("VETO Unplug VIF")`, value forced 0. This is the "vetoed until a VIF appeared
   once" rule: never unplug the emulated NIC unless a PV NIC devnode has existed at least
   once (the Enum key persists across boots).
4. Latch `Request[NICS] = (value != 0)` in memory.

The actual unplug — `UnplugDevices` (unplug.c:446): protocol preamble on I/O port 0x10
(magic 0x49d2, else drivers BLACKLISTED per docs/misc/hvm-emulated-unplug.markdown), then
`WRITE_PORT_USHORT(0x10, 0x0002)` = "unplug NICs" (QEMU detaches the emulated PCI NIC).
Call sites:
- **Main boot path: xenfilt** DriverSetFilterState (xenbus/src/xenfilt/driver.c:323, called
  from xenfilt fdo.c:386 when each filtered bus FDO finishes enumeration): on the
  ENABLED→PENDING transition, when ALL filtered bus FDOs (PCI) have enumerated AND
  `DriverIsActivePresent()` (driver.c:283: `Services\XENFILT\Parameters\ActiveDeviceID`
  exists AND that device is currently present per the emulated-device interface — logs
  `ACTIVE DEVICE [NOT ]PRESENT`) AND not Safe Mode → `UnplugDevices()`. This runs during
  early PnP enumeration, before NDIS binds the RTL8139.
- Resume paths: xenbus fdo.c FdoS4ToS3 and suspend.c:210 (re-unplug after resume/migration).

Extra veto inputs: boot option `XEN:BOOT_EMULATED=TRUE` (unplug.c UnplugSetBootEmulated),
Safe Mode, and QEMU-side blacklist via the version handshake.

**NICS lifecycle cheat-sheet (what a probe can legitimately see):**

| system state at sampling time | `Unplug\NICS` |
|---|---|
| right after MSI install, before any reboot | `0` (INF AddReg) |
| ANY later boot in which no NET PDO start succeeded or armed (incl. every netvm-detached boot) | **ABSENT** — consumed at xen.sys load |
| boot 1 with netvm, after arming (chain reached NET PDO start) | `1` |
| healthy steady state, PV NIC running | `1` (re-armed by PdoUnplugRequest at pdo.c:1454 after every successful start, ready for next boot) |

⇒ "NICS absent" is only meaningful **while the netvm is attached and enough time has
passed for the install chain**; sampled on a detached boot it is the healthy no-op state.
The handoff's reading "unplug never armed, or armed and lost" has a third, most likely
branch: "sampled on a boot where absence is expected".

### 2e. Known-failure writeups

Nothing public matches "xenvif installed-but-never-starts + no NICS + no unplug" exactly.
Related: XCP-ng troubleshooting docs cover multi-reboot requirement + `AutoReboot` registry
value and (older 8.2.x layout) deleting `Services\XENFILT\UNPLUG\nics|disks` to force
re-plug; XenServer PV Network Class Code 19/Code 31 issues after Windows Update are
version-mixing/registry corruption, not this signature. Qubes forum #5900 confirms the
boot-1 reboot dialog appears on stock QWT (their actual bug was an unrelated dead netvm
upstream). Sources:
[XCP-ng Windows guest tools troubleshooting](https://docs.xcp-ng.org/troubleshooting/windows-pv-tools/),
[Qubes forum: Windows Xen PV Network Class issue](https://forum.qubes-os.org/t/windows-xen-pv-network-class-issue/5900),
[xcp-ng win-xenvif](https://github.com/xcp-ng/win-xenvif),
[XenServer tools removed by Windows Update](https://www.rootusers.com/xenserver-tools-removed-by-windows-update/).

---

## 3. DECISION TREE for netforensics.ps1 after a FAIR two-boot test

Fair test = netvm attached while halted; **boot 1** left alone ≥10 min (screenshot the
desktop for the xenbus_monitor dialog); **graceful** `qtest shutdown` or in-guest
`shutdown /r /t 0` (never `qtest kill`); **boot 2** ≥5 min; run netforensics on each boot
if qrexec answers. Because qrexec is dead while starved, ALSO register a scheduled task
(at startup + every 2 min, netvm-attached boots included) that appends netforensics output
to `C:\netforensics-<boot>.log`, and collect the files on a later healthy boot. dom0's
guest console log (`/var/log/xen/console/guest-*.log` — ask the user) carries xen.sys
`LogPrintf`/`Info` lines: look for `UNPLUG: PRE-AMBLE (DRIVERS [NOT ]BLACKLISTED)`,
`UNPLUG: NICS`, `VETO Unplug VIF`, `NICS (<n>)`, `ACTIVE DEVICE [NOT ]PRESENT`.

Interpretation (netforensics tags: `ENUM`, `UNPLUG`, `SVC`, `PNP`, `SETUPAPI`, `EVT`):

**BOOT 2 outcomes (primary verdicts)**

| observation | verdict |
|---|---|
| `SVC xenvif status=Running`, `SVC xennet status=Running`, PNP shows "Xen PV Network Class" OK **and** an OK Xen net adapter, **no Realtek**, `UNPLUG NICS=1` | **Flow healthy. The earlier failure was self-inflicted (domain destroy between boots / never rebooting boot 1).** Close the blocker; the 2-core burn on boot 1 is the separate "emulated-NIC + starved guest" issue. |
| Realtek still present, xenvif Running, xennet Running-or-installed, NET device problem **14** again, `UNPLUG NICS=1`, dialog visible again | Arm happened again ⇒ boot 2's early-boot unplug did NOT fire. Discriminate via dom0 console log: `VETO Unplug VIF` → Enum\XENBUS lost/renamed (check `ENUM` list vs "VIF" substring); `ACTIVE DEVICE NOT PRESENT` → xenfilt active-device gate (check `Services\XENFILT\Parameters\ActiveDeviceID`); `DRIVERS BLACKLISTED` or no `UNPLUG:` lines at all → QEMU unplug protocol absent on this Xen/stubdom — **environmental, stock QWT would fail identically → upstream issue**. Boot-1 registry write lost (no lazy flush before shutdown) is only plausible if boot 1's own log showed NICS=1 present. |
| Realtek present, xenvif Stopped, no xennet, no NICS, and boot-1 evidence shows the arm never happened | Not a two-boot problem at all — fall through to the boot-1 table: the chain dies before arming. |

**BOOT 1 outcomes (where in the chain it dies)** — read in order; each row assumes the
previous rows' indicators were healthy:

| observation (boot 1, netvm attached, ≥10 min) | broken step / next look |
|---|---|
| `ENUM` has no `DEV_VIF` entry & PNP no VIF device | xenbus never enumerated the VIF: xenstore `device/vif` missing or xenbus FDO not active/started. Check dom0: xenstore-ls of the domain; console log for xenbus banner + `ACTIVE DEVICE`. Realtek-only is then EXPECTED. Environmental/Qubes-side. |
| VIF devnode present, `PNP [Error] ... problem=28` (no driver) | Driver store matching failed — compare devnode HardwareID REV (`REV_0900000A`) against the oem INF actually staged; a stock/ours xenbus↔xenvif version mix changes REV and silently unbinds. setupapi: "no drivers found". |
| VIF present, setupapi shows install + `Start:` section, but `SVC xenvif status=Stopped` **on this attached boot** and PNP VIF problem= 10/31/39/52 | xenvif.sys load/start failure: 52 = signature (testsigning off?), 39/31 = image load, 10 = FdoStartDevice failed (interface version mismatch against xenbus below — console log shows xenvif banner + fail lines). `EVT` Service Control Manager 7000/7026 entries discriminate load-vs-start. |
| xenvif Running, but no `Enum\XENVIF` key, no xennet, no NICS | xenvif FDO started but never enumerated a NET child: its scan thread needs xenstore `device/vif/<n>` frontend area — starvation or xenstore trouble; console log xenvif `VIF/...` lines absent. This is the "look at X" bucket for a guest burning 2 cores: PnP/xenstore may simply never progress. |
| `Enum\XENVIF` exists, but `SVC xennet status=absent` (no service key) | xennet.inf device install from the store never ran/completed for `XENVIF\VEN_XP0001&DEV_NET&REV_09000005` — setupapi tail must show that hardware ID; if setupapi has NO section for it, PnP's install queue stalled (starvation again); if it errored, the log names the cause. NICS absent here is consistent (arm point never reached). |
| xennet installed, NET device **problem=14**, `UNPLUG NICS=1`, reboot dialog in screenshot | **Chain fully healthy through the arm.** Boot 1 is DONE; anything after this is the boot-2 table. `Services\xenvif\Settings\...` populated additionally proves PdoParseMibTable saw the aliasing Realtek. |
| everything as previous row but `UNPLUG NICS` absent | Arm's registry write didn't land (start failed some other way — check NET device problem code ≠14) or was consumed by an unnoticed intervening boot. Cross-check `EVT` Kernel-Power 41 / event log boot count. |

**Cross-cutting checks**
- `SVC` start values: xenvif/xennet Start=3 and xeniface Start=3 are correct-by-design;
  xenfilt must be Start=0 and xenvbd Start=0. A xenfilt ≠ boot-start would break the whole
  unplug (it hosts xen.sys at early boot).
- Problem-code discrimination: **14** NEED_RESTART (armed, waiting) · **28** no driver
  (matching/REV) · **52** unsigned (testsigning) · **10/31** start/load failed ·
  **19** registry corrupt (known Windows-Update-vs-XenServer signature).
- setupapi lines that matter: `Device Install (Hardware initiated) - XENBUS\VEN_XP0001&DEV_VIF...`
  → `Driver Node: ... xenvif.inf` → `<<< Section end ... Exit status: SUCCESS` → later a
  SEPARATE `XENVIF\VEN_XP0001&DEV_NET` install for xennet. The absence of the second
  install is the single strongest "died between VIF start and NET enumeration" marker.

**Recommended netforensics.ps1 additions** (tools/netforensics.ps1):
`Enum\XENVIF` subkeys; `Services\xenvif\Settings` subkeys;
`Services\xenbus_monitor\Request` subkeys (boot-1 only, volatile);
`Services\XENFILT\Parameters` Active* values; `bcdedit /enum {current}` testsigning;
and the `ProblemCodeDescription`/problem for the `XENVIF\` NET device explicitly (current
InstanceId regex already matches it).

**Note on the starvation itself**: nothing in this flow explains ~2 cores of burn by
design; on a working stock install boot 1 runs at normal load with the dialog waiting.
Sustained burn + qrexec dead during PnP install is a separate defect/confounder (agent
capture load, interrupt storm, or PnP stall) — measure it in the stock-QWT control run the
handoff already mandates.
