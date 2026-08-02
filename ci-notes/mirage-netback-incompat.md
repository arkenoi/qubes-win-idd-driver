# Windows HVM + qubes-mirage-firewall netvm: why the guest wedges — source + spec analysis

Date: 2026-08-02. Companion to `ci-notes/xenvif-start-flow.md` (device topology, unplug
lifecycle) — read that first for who-enumerates-what; this note is about the **xenvif
frontend ↔ netback xenbus handshake** and the CPU burn.

Legend: **[V]** verified — I read the cited source/spec text. **[I]** inferred — reasoning
on top of verified facts, not itself read anywhere.

Source trees cited:
- xenvif/xenbus: `/home/user/qubes-win-idd-driver/upstream/ro/qubes-vmm-xen-windows-pvdrivers/`
  (QubesOS/ITL repo, HEAD `8cffcc0`; the submodule checkouts that produce the shipped
  9.1.0.0 / vendor-prefix `XP` binaries — see `xenvif-start-flow.md` §1).
- mirage-net-xen `main` @ `509eb9ebc37d` (2025-10-09), byte-identical to tag `v2.1.7` in
  `lib/xenstore.ml` and `lib/features.ml`. [V]
- qubes-mirage-firewall `main` (`dispatcher.ml`, `CHANGES.md`, issues/PRs).
- Xen `netif.h` (xen.git master, GitLab mirror).

---

## 0. Verdict up front

**A registry-only workaround that makes the PV path actually WORK is not plausible. [I]**
Registry knobs can only make the guest *survive* (stop wedging) by disabling the PV network
path; they cannot make the handshake complete, because nothing xenvif reads from the backend
is the blocker.

**The blocker is a mirage-side bug, already fixed upstream.** [V, on both sides]
qubes-mirage-firewall **≥ 0.9.5** (released 2025-10-29, PR #219) is the fix:

> "HVM Clients, such as Windows, have two network interfaces but only use one. This causes
> deadlock states because the connection protocol for one interface is not completed,
> leading the unikernel to wait for the client to shut down. Now, each connection uses its
> own thread, and the unikernel can handle Windows HVM (#219 @palainp)."
> — qubes-mirage-firewall `CHANGES.md`, 0.9.5

**xenvif turns that mirage deadlock into a full guest wedge** rather than a failed device,
because of a genuine defect on the Windows side: `FrontendPrepare` has **no exit path for a
backend parked in `XenbusStateInitialising (1)`**, and it waits by busy-spinning at
`DISPATCH_LEVEL` while holding a spinlock. That is the ~2-core burn. [V]

**Top 3 actionable items** (details in §6/§7):
1. Ask the user which qubes-mirage-firewall version `fw-net` runs; if < 0.9.5, upgrade. Not
   a registry fix, not our code — but it is *the* fix.
2. `HKLM\SYSTEM\CurrentControlSet\Services\xenvif\Parameters\Enumerate = 0` (DWORD) —
   known-safe fallback: xenvif never creates the NET child PDO, the frontend state machine
   never runs, the guest boots and uses the emulated RTL8139 (verified working).
3. `...\Services\xennet\Start = 4` (disable xennet) — same effect one level up, and
   reversible without touching xenvif; keeps `Enum\XENVIF` populated for diagnostics.

---

## 1. The xenvif frontend connect state machine, traced

### 1.1 Where it runs, and at what IRQL — this is the crux

| step | file:line | note |
|---|---|---|
| `FdoScan` reads xenstore `device/vif` dir | `xenvif/src/xenvif/fdo.c:969-974` | [V] |
| `__FdoEnumerate` → per instance reads `device/vif/<n>/mac`, **skips the device if `mac` is unreadable** | `fdo.c:821-828` | [V] |
| `PdoCreate` → `FrontendInitialize` | `fdo.c:830`, `pdo.c:2747` | [V] |
| `FrontendSetMaxQueues` = vCPU count, capped by registry `FrontendMaxQueues` | `frontend.c:236-258` | [V] — **purely local, touches no xenstore**; its `Info()` is the last log line in bug #127 |
| PnP starts the `XENVIF\...&DEV_NET` PDO → `PdoStartDevice` | `pdo.c:1405` | [V] |
| → `PdoD3ToD0` → `__PdoD3ToD0`, **`ASSERT3U(KeGetCurrentIrql(), ==, DISPATCH_LEVEL)`** | `pdo.c:957-969` | [V] |
| → `FrontendSetState(FRONTEND_CONNECTED)` — **takes `KeAcquireSpinLock(&Frontend->Lock)` and holds it for the entire state machine** | `frontend.c:2506-2657` (acquire :2514, release :2652) | [V] |
| → `FrontendPrepare` (drive backend to InitWait) | `frontend.c:1516-1615` | [V] |
| → `FrontendConnect` (write rings, drive to Connected) | `frontend.c:2215-2409` | [V] |
| `FrontendEnable` only from xennet via `vif.c:136/176` | `vif.c` | [V] |

Consequence: **the whole handshake runs at `DISPATCH_LEVEL` inside a spinlock.** It cannot
block, so it polls — see §2.

### 1.2 `FrontendPrepare` — required backend states, in order

`frontend.c:1526-1590` [V]:

1. `XENBUS_STORE(Acquire)`; `FrontendSetOnline`.
2. `FrontendAcquireBackend` (`frontend.c:1291-1335`): **requires frontend key `backend`**
   (fails the whole prepare if missing); `backend-id` is optional (defaults 0).
3. Loop until backend `state` == `InitWait (2)`:

| backend `state` read | xenvif action (`frontend.c:1545-1576`) |
|---|---|
| key unreadable → `Unknown (0)` | `FrontendSetOffline` → `PdoRequestEject`, loop breaks, **`goto fail3`** — clean failure |
| `Closed (6)` | if backend `online` != 0 → write frontend `state = Initialising (1)`; else go offline |
| `Connected (4)` | write frontend `state = Closing (5)` |
| `Closing (5)` | write frontend `state = Closed (6)` |
| **`Initialising (1)`** | **`break` — no action, loop repeats forever** ⚠ |
| `InitWait (2)` | `break` — loop exit condition satisfied, proceed |
| `Initialised (3)`, `Reconfiguring (7)`, `Reconfigured (8)` | `default: ASSERT(FALSE); break;` — **`ASSERT` is a no-op in free builds** (`assert.h:134-137` [V]) ⇒ same infinite loop ⚠ |

4. On success: add a store watch on backend `online` bound to the **eject thread's** event
   (`frontend.c:1583-1588`). [V]

### 1.3 `FrontendConnect` — what it publishes and requires

Reads from backend, all optional with safe defaults [V]:

| backend key | file:line | missing ⇒ |
|---|---|---|
| `multi-queue-max-queues` | `frontend.c:1786-1800` | `BackendMaxQueues = 1` → `NumQueues = min(vCPUs, 1) = 1` |
| `feature-split-event-channels` | `frontend.c:1842-1856` | `Split = FALSE` → single shared `event-channel` |
| `feature-ctrl-ring` | `controller.c:426-442` | `Feature = FALSE` → `goto done`, ctrl ring skipped entirely, **success** |
| `feature-dynamic-multicast-control` | `transmitter.c:4696-4709` | `MulticastControl` stays default (FALSE) |
| `online` | `frontend.c:354-379` | treated as `FALSE` (only consulted in the `Closed` branch and by the eject thread) |
| frontend `mtu` | `mac.c:441-459` | `ETHERNET_MTU` |

Writes, in one xenstore transaction (retry ≤ 10, `frontend.c:2261-2311`) [V]:

- `request-rx-copy=1`, `feature-sg=1`, `feature-rx-notify=1` (`receiver.c:3455-3485`)
- `feature-gso-tcpv4`, `feature-gso-tcpv6` (`receiver.c:3363-3390`),
  `feature-no-csum-offload=0`, `feature-ipv6-csum-offload=1` (`receiver.c:3410-3432`)
- **`rx-ring-ref` + `event-channel`** and **`tx-ring-ref`** at the *flat top level* whenever
  `NumQueues == 1` — `Path = (FrontendGetNumQueues(Frontend) == 1) ? FrontendGetPath(...) :
  Ring->Path` (`receiver.c:2793-2796`, `transmitter.c:3849-3852`) [V]
- `multi-queue-num-queues = 1` unconditionally (`frontend.c:2286-2292`) — a divergence from
  Linux netfront, which omits the key for a single queue; harmless, mirage never reads it [V]
- `ctrl-ring-ref` / `event-channel-ctrl` only if `feature-ctrl-ring` was advertised
  (`controller.c:601-621`, guarded by `if (!Controller->Connected) goto done`) [V]

Then loop until backend `state == Connected (4)` (`frontend.c:2317-2349`), with **the same
hole**: `Initialising (1)` is not in the switch → `default: ASSERT(FALSE)` → no-op →
infinite loop. `InitWait (2)` / `Initialised (3)` → write frontend `state = Connected`. [V]

---

## 2. Where the CPU burn comes from — exact loops

### 2.1 The primary spinner: `FrontendWaitForBackendXenbusStateChange`

`frontend.c:1337-1433` [V]. Called from `FrontendPrepare`, `FrontendConnect`, `FrontendClose`.

```c
Timeout.QuadPart = 0;                                     /* :1372 — zero timeout */
while (*State == Old && TimeDelta < TotalTimeout) {        /* :1374, TotalTimeout = 120000 ms (:1350) */
    if (Watch != NULL) {
        ULONG Attempt = 0;
        while (++Attempt < 1000) {                        /* :1381 */
            status = KeWaitForSingleObject(&Event, ..., &Timeout);   /* returns immediately */
            if (status != STATUS_TIMEOUT) break;
            XENBUS_STORE(Poll, &Frontend->StoreInterface);           /* :1392 */
            KeStallExecutionProcessor(1000);              /* :1395 — 1 ms BUSY SPIN */
        }
        ...
    }
    ... read backend "state" ...                          /* :1401-1415 */
}
```

`KeStallExecutionProcessor` is a hard busy-wait, not a sleep. The comment at `:1390-1391`
says it outright: *"We are waiting for a watch event at DISPATCH_LEVEL so it is our
responsibility to poll the store ring."* So **one CPU is pinned at 100% at DISPATCH_LEVEL
for up to 120 s per call.** [V]

**The 120 s cap does not bound the burn**, because the *outer* loops in `FrontendPrepare`
(`:1537`) and `FrontendConnect` (`:2317`) re-enter it. On timeout the function leaves
`*State` unchanged (it only forces `Unknown` when the *read fails*, `:1407-1408`) — so with
the backend parked at `Initialising (1)`, every iteration reads 1, hits the no-op switch
branch, and loops. `FrontendIsOnline` stays TRUE (only `FrontendSetOffline` clears it, and
that is only reached from the `Unknown` branch). **Unbounded, uninterruptible, at
DISPATCH_LEVEL, holding `Frontend->Lock`.** [V]

### 2.2 The second spinner: anything else that wants `Frontend->Lock`

`Frontend->Lock` is a `KSPIN_LOCK`. While thread A holds it inside `FrontendSetState`, any
other CPU acquiring it spins at DISPATCH_LEVEL too. Callers: the **eject thread**
(`FrontendEject`, `frontend.c:411` — woken by the backend-`online` watch added at `:1583`),
the **MIB thread**, `FrontendSetHashAlgorithm` / `SetHashMapping` / `SetHashKey` /
`SetHashTypes`, `FrontendSetFilterLevel`, `FrontendAdvertiseIpAddresses`, and the
`vif.c` entry points called by xennet. [V for the call sites; **[I]** that this is the
second core]

This is the cleanest explanation for the measured **~2.0 cores on a 4-vCPU guest and ~1.95
on a 2-vCPU guest**: exactly two spinning threads, independent of vCPU count — one in the
stall loop, one blocked on the spinlock. A per-vCPU-scaling cause would have given ~4.0 and
~2.0. [I]

### 2.3 Corollaries that explain the post-mortem evidence

- **2 vCPUs ⇒ both CPUs at DISPATCH_LEVEL ⇒ nothing at PASSIVE_LEVEL ever runs**: no
  qrexec, no ACPI/shutdown handling, no lazy registry hive flush, no PnP progress. On 4
  vCPUs, PnP is still wedged because the stuck `IRP_MN_START_DEVICE` never completes and
  Windows' device-install queue is serialized. [I]
- ⇒ **`Enum\XENVIF` empty / `xennet` not installed / `Unplug\NICS` unarmed after a hard kill
  is expected regardless of how far the boot actually got** — those registry writes were
  made in the in-memory hive and never flushed, because the lazy writer never ran. Combined
  with the fact (from `xenvif-start-flow.md` §2a/§2d) that detaching the netvm removes
  `device/vif` → xenvif deletes the NET PDO → `Enum\XENVIF` empties, and that `Unplug\NICS`
  is *consumed and deleted at every boot* (`xenbus/src/xen/unplug.c:296-300` [V]) — **none
  of the three "broken-state" registry observations are independent evidence about where the
  hang is.** They are consistent with the DISPATCH_LEVEL wedge, but do not prove it. See §8
  for the discriminating tests.
- Bounded spins elsewhere, for completeness: `transmitter.c:4001` (`KeStallExecutionProcessor`
  ×100 = 100 ms, on disable) and `xenbus/src/xenbus/gnttab.c:587` (`SchedYield` ×100) are
  both hard-capped and cannot sustain a burn. [V]

---

## 3. What qubes-mirage-firewall's netback actually publishes

All from `mirage-net-xen/lib/xenstore.ml` + `lib/features.ml` + `lib/backend.ml`; the
backend is instantiated by qubes-mirage-firewall `dispatcher.ml:3,413`
(`module Netback = Backend.Make (Xenstore.Make (Xen_os.Xs))`). [V]

`init_backend` (`xenstore.ml:237-246`) writes, in one transaction: six feature keys, then
backend `state = InitWait (2)`. Feature values from `features.ml:26-34`. **The full set of
xenstore key literals in the entire mirage-net-xen codebase is 13** — an exhaustive grep
found nothing else. [V]

| backend key | mirage | xenvif treats as | verdict |
|---|---|---|---|
| `feature-sg` | **`1`** | (frontend advertises its own) | fine |
| `feature-gso-tcpv4` | **`0`** | frontend advertises its own | fine |
| `feature-gso-tcpv6` | **absent** | spec: absent = not capable | fine |
| `feature-rx-copy` | **`1`** | frontend writes `request-rx-copy=1` | fine |
| `feature-rx-flip` | **`0`** | unused by xenvif | fine |
| `feature-rx-notify` | **`1`** | frontend writes its own | fine |
| `feature-smart-poll` | `0` (non-spec extra) | unread | fine |
| `feature-no-csum-offload` | **absent** | `transmitter.c` → spec default **ON** ⇒ Windows offers TX csum offload; mirage `backend.ml:166` **discards TX flags** and never computes the checksum | **functional hazard, post-connect** [I] |
| `feature-ipv6-csum-offset/-offload` | **absent** | spec default off | fine |
| `feature-multicast-control`, `feature-dynamic-multicast-control` | **absent** | `transmitter.c:4696-4709` → optional | fine |
| `feature-ctrl-ring` | **absent** | `controller.c:426-442` → skip ctrl ring, success; also kills toeplitz/hash, which xenvif already refuses for `NumQueues==1` (`frontend.c:1976-1983`) | fine |
| `multi-queue-max-queues` | **absent** | `frontend.c:1798-1800` → `BackendMaxQueues = 1` | fine |
| `feature-split-event-channels` | **absent** | `frontend.c:1854-1855` → `Split = FALSE` | fine |
| `feature-hash` / toeplitz | **absent** | needs ctrl ring; unreachable | fine |
| `mac` | **not written** (backend MAC hardcoded `fe:ff:ff:ff:ff:ff`, `xenstore.ml:83`, per qubes-issues#5013) | xenvif reads *frontend* `mac`, written by libxl | fine |
| `hotplug-status` | **never written** (string absent from repo) | xenvif never reads it | fine |
| `online` | **not written by mirage** (libxl writes it) | `frontend.c:354-379` → missing = FALSE | see §5 rank 3 |
| `state` | `2` at init, `4` after rings mapped, `6` at teardown | the whole handshake | see §5 rank 1 |

Backend **reads** only the flat legacy layout: `frontend/{tx-ring-ref, rx-ring-ref,
event-channel, mac, mtu, state, backend, backend-id}` (`xenstore.ml:184-200`). **No
multi-queue (`queue-N/...`) support, no split event channels** — neither string occurs
anywhere in the repo. [V]

Spec check (`netif.h`, xen.git master) [V]: multi-queue and split-evtchn are *optional
backend advertisements*, and the single-queue case is explicitly specified to use the flat
top-level keys —

> "For frontends requesting just one queue, the usual event-channel and ring-ref keys are
> written as before, simplifying the backend processing to avoid distinguishing between a
> frontend that doesn't understand the multi-queue feature, and one that does, but requested
> only one queue."

**⇒ mirage-net-xen is spec-conformant, just minimal; and xenvif's degraded path lands on
exactly the layout mirage implements.** The feature-negotiation theory is DEAD. [V both sides]

---

## 4. Cross-reference: optional vs required

Every backend feature key mirage omits is **optional** in xenvif, with a defined default and
a success path — cited in the table above. There is **no** backend key whose absence makes
`FrontendPrepare` or `FrontendConnect` return failure. [V]

The only backend-side inputs that can stall or fail xenvif are:

| input | xenvif behaviour | severity |
|---|---|---|
| backend `state` never leaves `Initialising (1)` | **unbounded DISPATCH_LEVEL spin** (§1.2, §2.1) | **fatal wedge** |
| backend `state` = `Initialised (3)` seen in `FrontendPrepare` | `default: ASSERT(FALSE)` → no-op → same unbounded spin | fatal wedge |
| backend `state` node absent/unreadable | → `Unknown` → `SetOffline` → `fail3`, clean failure, PDO eject | benign |
| backend `state` = `Connected (4)` while frontend is preparing | writes `Closing`→`Closed`, converges | benign |
| frontend `backend` key absent | `FrontendAcquireBackend` fail1 → prepare fails cleanly | benign |
| frontend `device/vif/<n>/mac` absent | NET PDO never created (`fdo.c:827`) | benign (no PV net) |

---

## 5. Ranked candidate incompatibilities

**Rank 1 — mirage < 0.9.5 serializes the two vifs an HVM presents; one backend never leaves
`Initialising`. CONFIRMED as the mechanism. [V on both sides; [I] that it is *this* user's
instance]**

qubes-mirage-firewall PR #219 / CHANGES 0.9.5 (2025-10-29): *"HVM clients have two client
interfaces (appvm and appvm-dm), and therefore the unikernel sees two vif interfaces. But
only one should be active at the same time (one in state 4 … and the other in state 2) …
This causes deadlock states because the connection protocol for one interface is not
completed, leading the unikernel to wait for the client to shut down."*

Mechanism, joined to the mirage source: `Backend.make` → `C.init_backend` (writes that
backend's `state = 2`) → `C.read_frontend_configuration`, which **blocks** in `Xs.wait`
until the *frontend* state is `Initialised (3)` or `Connected (4)`
(`xenstore.ml:165-183`) [V]. Pre-0.9.5 this ran on a single thread across both vifs, so the
second vif's `init_backend` never runs and **its backend `state` stays at the `1`
(`Initialising`) that libxl wrote at device-create time**. Windows' xenvif, sitting on that
vif, hits §1.2's missing branch and spins forever. Perfectly matches: no state advance, no
error, permanent burn, ACPI ignored.

Historical corroboration [V]: **qubes-mirage-firewall issue #127** (2020-11-24), *"Windows
Xen PV Driver XENVIF fails to install FrontendSetMaxQueues: device/vif/0:4"* — *"Freezes on
`xenvif|FrontendSetMaxQueues: device/vif/0:4`. Fix is to chose sys-firewall for NetVM."*
Closed 2022-10-27 with no fix. `FrontendSetMaxQueues` is the **last `Info()` emitted before
the PDO start** (`frontend.c:257`, called from `FrontendInitialize` ← `PdoCreate`), and the
`:4` is just the guest's vCPU count — so that freeze point is exactly the `PdoStartDevice` →
`FrontendPrepare` spin identified here. Same bug, six years old, same workaround (use a
Linux netvm). Related: #56 (Win10 HVM does not work with mirage firewall), #61/qubes-issues#5013
(backend MAC hardcoded to fix HVM clients). **No qubes-issues entry exists for this.**

**Rank 2 — mirage never writes `hotplug-status`, and there is no `-emu` tap.** [V that
`hotplug-status` is absent from the whole repo; [I] for the consequences] A unikernel cannot
run a hotplug script or create a `vifX.Y-emu` tap device. Per PR #219 the unikernel *does*
see the device-model vif as its own second backend, so the emulated NIC's frames do have a
mirage-side owner once 0.9.5's per-connection threads exist — but on a pre-0.9.5 firewall
this is precisely the second interface that deadlocks. This is why the failure is
HVM-specific and does not reproduce with Linux PV/PVH clients.

**Rank 3 — backend `online` semantics.** mirage never writes `online`; libxl does. If it is
ever absent, `FrontendIsBackendOnline` returns FALSE (`frontend.c:366-368` [V]), which in
`FrontendPrepare`'s `Closed` branch drives `FrontendSetOffline` — a *clean* failure, not a
wedge. Low likelihood of causing the observed symptom, but it changes which failure you see.

**Rank 4 — TX checksum offload.** [I, from verified code on both sides] mirage omits
`feature-no-csum-offload`; `netif.h` says *"if it is missing then the feature is assumed to
be on"*; xenvif acts on that default. Windows then emits `NETTXF_csum_blank` packets, and
mirage `backend.ml:166` destructures TX requests as `{ flags = _; … }` — flags discarded, no
checksum computed. Predicted symptom: link up, ARP/DHCP fine, TCP/UDP egress silently
dropped. **This is a post-connect data-plane bug; it cannot produce the wedge**, but it is
the next thing to break after mirage 0.9.5 fixes the handshake, so budget for it.

**Rank 5 — multi-queue / split event channels.** Ruled out (§3). Both sides degrade to the
same spec-mandated flat single-queue layout.

---

## 6. Ranked, testable workarounds

All xenvif values live under
`HKLM\SYSTEM\CurrentControlSet\Services\xenvif\Parameters` (opened by
`DriverEntry` → `RegistryOpenSubKey(ServiceKey, "Parameters", …)`, `xenvif/src/xenvif/driver.c:435-443` [V]);
xennet values under `…\Services\xennet`. All are `REG_DWORD`. **All require a reboot** — the
frontend state machine only runs at PDO start.

| # | key / value | code path | predicted effect | in-guest success check |
|---|---|---|---|---|
| **1** | *(not a registry fix)* qubes-mirage-firewall **≥ 0.9.5** on `fw-net` | mirage `dispatcher.ml` per-connection threads; backend `state` 1→2→4 | handshake completes; `xennet` binds; guest boots normally | `Get-Service xenvif` = Running; `Enum\XENVIF\VEN_XP0001&DEV_NET&REV_09000005` present with `Get-PnpDevice` Status OK; an "Xen PV Network Device" adapter appears; **from dom0** `xenstore-read /local/domain/<fw>/backend/vif/<win>/0/state` = `4` |
| **2** | `xenvif\Parameters\Enumerate = 0` | `__FdoEnumerate`, `fdo.c:737-744` — `if (Enumerate == 0) goto done;` **before any `PdoCreate`** [V] | NET child PDO never created ⇒ `PdoStartDevice`/`FrontendSetState` never run ⇒ **no spin, guest boots**; PV net disabled entirely; traffic stays on the emulated RTL8139 | **`Enum\XENVIF` stays EMPTY** (that is the *success* signal here); `xenvif` service Running (the FDO still starts); guest reaches desktop + qrexec with `fw-net` attached |
| **3** | `xennet\Start = 4` (SERVICE_DISABLED) | Windows PnP: NET PDO has `RawDeviceOK = 0` (`pdo.c:1864` [V]) ⇒ with no function driver PnP never sends `IRP_MN_START_DEVICE` ⇒ `PdoStartDevice` never runs [I] | same as #2 (no spin) but **keeps `Enum\XENVIF` populated**, so you can still see whether the devnode was enumerated — better diagnostic value than #2 | `Enum\XENVIF\…&DEV_NET` present, `Get-PnpDevice` Status = `Unknown`/problem 18/28; guest boots; `Unplug\NICS` stays unarmed (correct — arming lives in `PdoStartDevice`) |
| **4** | `xenvif\Parameters\UnsupportedDevices = "0"` (**REG_MULTI_SZ**, not DWORD) | `FdoScan`, `fdo.c:993-1024` — device instance names matched by `strncmp` are blanked before `__FdoEnumerate` [V] | surgical variant of #2: suppress only vif instance 0 | as #2, but selective; verify with a second vif attached |
| **5** | `xenvif\Parameters\FrontendMaxQueues = 1` | `FrontendSetMaxQueues`, `frontend.c:248-252` [V] | **predicted NO EFFECT.** `NumQueues` is already `min(vCPUs, BackendMaxQueues=1) = 1` (`frontend.c:1806`) and xenvif already writes the flat layout at 1 queue. Listed only to close it out — it is the knob bug #127's log line names, and it is a red herring | `Enum\XENVIF` populated *and* guest still wedges ⇒ confirmed no-effect |
| **6** | `xenvif\Parameters\TransmitterDisableMulticastControl = 1` | `transmitter.c:4510`, gates the `feature-dynamic-multicast-control` read at `:4696` [V] | no effect on the wedge (that read is already optional and mirage omits the key). Only relevant post-connect | — |
| **7** | `xenvif\Parameters\FrontendDisableToeplitz = 1` | `frontend.c:2894-2897` → `FrontendSetHashAlgorithm` returns `STATUS_NOT_SUPPORTED` (`frontend.c:1976-1983`) [V] | no effect — toeplitz is already refused at `NumQueues == 1`, and it needs `feature-ctrl-ring` which mirage does not advertise | — |
| **8** | `xenvif\Parameters\ReceiverAllowGsoPackets`, `Receiver/TransmitterDisableIpVersion{4,6}Gso`, `ReceiverCalculateChecksums`, `TransmitterValidateChecksums`, `TransmitterAlwaysCopy`, `ReceiverAlwaysPullup`, `ReceiverIpAlignOffset`, `MacSpeed` (`mac.c:229`) | `receiver.c:3121-3151`, `transmitter.c:4486-4510` [V] | **all post-connect data-plane knobs — none can affect the handshake.** `TransmitterDisableIpVersion4Gso=1` + `TransmitterValidateChecksums=1` are the ones to try against the Rank-4 checksum hazard *after* mirage 0.9.5 | ping/TCP works over the Xen adapter |

Notes:
- Nothing under `xenvif\Parameters` can shorten or break the spin: the 120 s
  `TotalTimeout` (`frontend.c:1350`) is a compile-time constant, and the outer loops have no
  registry-controlled bound. [V]
- `Enumerate=0` is safe to leave in place permanently on this test VM: `xenvbd` (disks) and
  `xeniface` (qrexec/vchan) are separate drivers and unaffected. [V — separate INFs/services]
- Deploying #2/#3 needs the guest bootable, i.e. **detach the netvm, boot, set the value,
  shut down, attach `fw-net`, boot** — or apply it offline to the hive. Do not apply it by
  booting with `fw-net` attached; you cannot reach a shell.

---

## 7. Registry-only, or code change? — explicit answer

**Registry-only cannot make it work. [I, on verified code]** The handshake fails because the
backend never leaves `Initialising`; xenvif has no registry-controlled timeout, retry limit,
or state-machine override. The only registry outcomes available are "don't run the frontend
at all" (#2/#3), which restores a bootable guest with the emulated NIC — genuinely useful,
and the right immediate unblock for this project, but it is not PV networking.

**Two code changes are warranted, on opposite sides, and they are independent:**

**(a) mirage-net-xen / qubes-mirage-firewall — the functional fix. Already upstream.**
Per-connection threads so both of an HVM's vifs get `init_backend` (backend `state → 2`)
without one blocking on the other. Landed in qubes-mirage-firewall **0.9.5** (PR #219,
2025-10-29). Nothing for us to write; verify the deployed version. If `fw-net` is already
≥ 0.9.5 and the symptom persists, that is a **new** upstream bug and worth a report against
mirage/qubes-mirage-firewall referencing #127 and #219 — with, per the project rules, the
exact text approved by the user first.

Secondary mirage hardening, worth proposing only if we hit Rank 4:
publish `feature-no-csum-offload = 0` (or honour `NETTXF_csum_blank` in `backend.ml:166`),
one line in `write_features` (`xenstore.ml:128-145`) plus a field in `features.ml`.

**(b) xenvif — the robustness fix (this is a real upstream-worthy defect).**
A guest must not livelock because a backend is slow or stuck. Minimal, reviewable patch in
`xenvif/src/xenvif/frontend.c`:

1. **Close the missing branches.** In `FrontendPrepare`'s switch (`:1545-1576`) and
   `FrontendConnect`'s (`:2325-2348`), handle `XenbusStateInitialising`,
   `XenbusStateReconfiguring`, `XenbusStateReconfigured` explicitly, and replace the
   `default: ASSERT(FALSE)` no-op with a **bounded** retry counter that fails the transition
   (`goto fail3` / `fail9`, both of which already exist and unwind cleanly) after N
   iterations. Effect: the device fails to start with a real error and PnP moves on, instead
   of wedging the machine. This alone converts the symptom from "guest unusable" to "PV NIC
   yellow-banged".
2. **Stop busy-waiting.** `FrontendWaitForBackendXenbusStateChange` spins because
   `FrontendSetState` holds a `KSPIN_LOCK` across the whole state machine (`:2514`/`:2652`).
   The correct fix is to run the handshake at `PASSIVE_LEVEL` under a mutex (as
   `xenbus`'s own unplug interface already requires — `unplug.c:80` `ASSERT3U(…PASSIVE_LEVEL)`)
   and use `KeWaitForSingleObject` with a real timeout. That is a larger, riskier change
   touching `pdo.c`'s D0 transitions; **propose (1) first**, and only float (2) as a design
   note. Both belong upstream at xenbits/win-pvdrivers, not in a Qubes fork.

Do not attempt (b) as part of the current tracks without the user's go-ahead — it is a
kernel-driver change to a component the whole Windows qube depends on.

---

## 8. Diagnostics that would discriminate (cheap, do these before anything else)

The three "broken-state" registry facts (`Enum\XENVIF` empty, `xenvif` not Running,
`Unplug\NICS` unarmed) are **not** discriminating — §2.3 explains why each is expected after
a hard kill *and* after a netvm detach, independent of where the hang is. To actually pin it:

1. **From dom0 (ask the user — we cannot run dom0 commands):** with the wedged guest still
   running, `xenstore-ls -f /local/domain/<fw-net-domid>/backend/vif/<win-domid>` and
   `xenstore-ls -f /local/domain/<win-domid>/device/vif`. Decisive:
   - backend `state = 1` and no `feature-*` keys ⇒ **Rank 1 confirmed** (mirage never ran
     `init_backend` on this vif).
   - backend `state = 2` with the six mirage feature keys, frontend `state = 1` ⇒ the
     backend *is* up and xenvif is stuck elsewhere — re-open the analysis.
   - two backend dirs, one at `4` and one at `1` ⇒ the #219 two-vif deadlock, textbook.
2. **Guest console log** (`/var/log/xen/console/guest-*.log` in dom0 — ask the user). xenvif
   emits `Info()` via the same `LogPrintf` path as xenbus. Expected tail on Rank 1:
   `FrontendSetMaxQueues: device/vif/0:<vcpus>` then `FrontendSetState: … 'UNKNOWN' ->
   'CONNECTED'` (`frontend.c:2516`) then **silence** — no `FrontendSetNumQueues` line
   (`frontend.c:1809`, only reached inside `FrontendConnect`). Silence after
   `FrontendSetState ====>` ⇒ stuck in `FrontendPrepare`; a `FrontendSetNumQueues` line
   followed by silence ⇒ stuck in `FrontendConnect`'s loop instead.
3. **`fw-net` version:** ask the user for the qubes-mirage-firewall build date/version. < 0.9.5
   (before 2025-10-29) ⇒ stop, upgrade, retest. This is one question and it may end the
   investigation.
4. **Falsification test for the whole model:** apply workaround #3 (`xennet\Start = 4`),
   boot with `fw-net`. Model predicts: guest boots normally, qrexec up, no CPU burn,
   `Enum\XENVIF` populated, no Xen network adapter. If the guest **still** burns 2 cores with
   xennet disabled, the hang is not in the xenvif frontend at all and this analysis is wrong
   — go look at xenbus/xenfilt instead.
