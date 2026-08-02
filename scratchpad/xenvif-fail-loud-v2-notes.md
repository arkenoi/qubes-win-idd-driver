# xenvif-fail-loud v2 — notes

Date: 2026-08-02.
Patch: `scratchpad/xenvif-fail-loud-v2.patch` (git format-patch, 1 commit, 1 file,
`src/xenvif/frontend.c`, +351/-10).
Base: xenvif submodule `9fd1afe4382b15ed8e063a816a328c0a580f038e`, as checked out in
`upstream/ro/qubes-vmm-xen-windows-pvdrivers/xenvif`. Verified with
`git apply --check` against that tree: **applies cleanly**.

---

## 0. Read this first — two honesty items

### 0.1 Nothing has been compiled or run

**No build, no deployment, no VM contact.** There is no WDK/EWDK in this qube and the task
forbade builds and pushes. Everything below is source reasoning against the checked-out
submodule. Specifically unverified:

- It has never been through a compiler. Balanced braces/parens were checked
  mechanically; MSVC `/W4 /WX` (which these drivers build with) has not seen it. The most
  likely warning candidates are the `ULONGLONG` → `ULONG` cast in `FrontendStall()` (explicit,
  should be fine) and `%u` against a `USHORT` domid (promoted, should be fine).
- The claim "PnP shows **Code 10**" is inference. What is verified is that
  `PdoStartDevice()`'s failure arm completes the IRP with the failure status
  (`pdo.c:1490-1491`); `STATUS_UNSUCCESSFUL` on a start IRP mapping to
  `CM_PROB_FAILED_START` (10) is standard Windows behaviour, not something read in this tree.
- The exact wall-clock behaviour of the new deadline has not been observed.
- Whether the measured mirage wedge is *fully* cured is **conditional** — see §3.

### 0.2 The four prior artifacts named in the task do not exist

`scratchpad/xenvif-defect-anatomy.md`, `scratchpad/xenvif-faildesign.md`,
`scratchpad/xenvif-fail-loud.patch` (v1) and `scratchpad/xenvif-fail-review.md` are **not
present on disk and are not in any commit** of `qubes-win-idd-driver` (checked
`git log --all --diff-filter=A --name-only`). The only xenvif artifact in the repo is
`ci-notes/xenvif-start-flow.md`.

v2 was therefore reconstructed from:

- the two blocker statements in the task, which carry the review's file:line findings;
- `ci-notes/mirage-netback-incompat.md` (the de facto defect anatomy, incl. the
  2026-08-02 measured xenstore capture) and `ci-notes/xenvif-start-flow.md`;
- a fresh read of the xenvif/xenbus source.

Consequence: **I could not diff v2 against v1.** Where v1 made a choice the review did not
mention, v2 may differ silently. Everything the review explicitly accepted (the diagnostic
contract, the log constraints) is reproduced below and is present in the patch.

---

## 1. Blocker-by-blocker disposition

### BLOCKER 1 — the probe must not fail the PDO into an eject/re-create loop. **FIXED.**

The review's path is real. Confirmed in source:

| step | evidence |
|---|---|
| `FrontendPrepare` unwind falls `fail3` → `fail2` | `frontend.c:1598-1608` (pre-patch) |
| `fail2` calls `FrontendSetOffline()` | `frontend.c:1606` |
| `FrontendSetOffline()` calls `PdoRequestEject()` | `frontend.c:1247-1257` |
| `PdoRequestEject()` sets `Pdo->Eject`, invalidates BusRelations | `pdo.c:306-323` |
| the scan then ejects the PDO for real | `fdo.c:779-780` `if (PdoIsEjectRequested(Pdo)) IoRequestDeviceEject(...)` |
| eject marks it Deleted + Missing, destroys it | `pdo.c:2251-2252` |
| the next scan re-creates it — the vif is still in xenstore | `fdo.c:830` `PdoCreate(Fdo, Number, Address)` |
| and `PdoCreate`'s own gate fails the PDO if the flag is set | `pdo.c:2760-2762` → `fail11` |
| whose unwind wakes the scan thread again | `fdo.c:680` `ThreadWake(Fdo->ScanThread)` |

Note a refinement to the review's account: the dominant loop is
`stall → SetOffline → PdoRequestEject → IoRequestDeviceEject → PdoDestroy → rescan →
PdoCreate → start → stall`, i.e. through `fdo.c:779-780`. The `pdo.c:2760` gate is the narrower
race (eject requested while the *replacement* PDO is being built), reachable because the
scan thread and the start path run concurrently. Both are driven by the same root cause —
`PdoRequestEject()` being called for a backend that has not gone anywhere — and both are
removed by the same fix.

**Fix:** a dedicated `stall:` unwind arm in `FrontendPrepare()` that does *not* enter the
`fail3`/`fail2` chain. It performs the same balancing work — `FrontendReleaseBackend()`,
`XENBUS_STORE(Release)` — but clears `Online` via a new `FrontendSetOfflineNoEject()`
(`frontend.c` new, next to `FrontendSetOffline`) instead of `FrontendSetOffline()`. No
`PdoRequestEject()`, so `Pdo->Eject` is never set, `fdo.c:779` never fires, `pdo.c:2761`
cannot trip, and the device node survives carrying a start failure.

Chosen over the review's alternative ("or explicitly clears the eject request") because not
setting the flag is strictly safer than setting and racing to clear it — `fdo.c:779` runs on
the scan thread and could observe it in between.

Balance check of the new arm against the pre-patch `fail3`+`fail2` sequence: `WatchAdd` has
not run yet (we break out before it), so `Frontend->Watch` is still `NULL` and there is
nothing to remove — and because `FrontendPrepare` returns failure, `Frontend->State` stays
`FRONTEND_UNKNOWN`/`FRONTEND_CLOSED`, so `FrontendClose()` (whose `ASSERT(Frontend->Watch !=
NULL)` would otherwise fire) is not reached.

### BLOCKER 2 — must not break out of a wait with a live backend. **FIXED, by not doing it.**

The review is right and v1 was wrong. Verified on both sides:

- `FrontendSetState()`'s `FRONTEND_CONNECTED` → `PREPARED/CLOSED/UNKNOWN` arm
  (`frontend.c:2611-2618`, pre-patch numbering) runs `FrontendClose()` then `FrontendDisconnect()` on
  every device disable, driver unload, PnP stop and qube shutdown, with a backend that has
  connected and holds the rings and fragment pages foreign-mapped.
- Revocation failure is discarded at **17** call sites in this driver:
  `transmitter.c:971,1136,1482,1556,2583,3800,4071`,
  `receiver.c:1913,2091,2744,2958`,
  `controller.c:545,703,942,960,1121,1139` — all `(VOID) XENBUS_GNTTAB(RevokeForeignAccess, ...)`.
- And it genuinely can fail: `xenbus/src/xenbus/gnttab.c:574-596` spins 100 ×
  `SchedYield()` trying to clear `GTF_permit_access` while `GTF_reading|GTF_writing` are
  set, then `goto fail1` returning `STATUS_UNSUCCESSFUL` — after which xenvif frees the page
  back to non-paged pool anyway.

So the unbounded wait is load-bearing: it is what makes the later revocation safe. v2 does
not touch it. The same argument applies to `FrontendConnect()`'s wait loop, which v1's
review did not name but which has the identical hazard — by the time it runs,
`ReceiverConnect()`/`TransmitterConnect()` (`frontend.c:2249-2255`) have already granted the
rings, and its `fail9` unwind revokes and frees them. v2 leaves that loop unbounded too.

Both unbounded loops still get the full diagnostic, emitted once, then keep waiting.

---

## 2. The bounded / unbounded table

Rule, stated once: **a wait may be bounded if and only if the frontend has never reached
`FRONTEND_CONNECTED`**, because `FrontendConnect()` is the only thing that grants the rings
and fragment pages to the backend.

| # | wait loop | call site | bounded? | why that is safe / necessary |
|---|---|---|---|---|
| 1 | `FrontendPrepare()` state loop | `frontend.c:1773` (post-patch) | **BOUNDED** | Nothing has been granted. `ReceiverConnect`/`TransmitterConnect` run later, in `FrontendConnect`, only after Prepare returns success. Breaking out cannot free a mapped page. Unwinds via the new `stall:` arm (no eject). |
| 2 | `FrontendClose()` state loop, called from `FRONTEND_PREPARED` → `CONNECTED` **failed** | `frontend.c:2906` `FrontendClose(Frontend, TRUE)` | **BOUNDED** | Frontend never reached `FRONTEND_CONNECTED`. `FrontendConnect()`'s own `fail5..fail9` unwind has *already* revoked and freed whatever it granted, before `FrontendClose()` is even entered — so this wait no longer protects anything, and bounding it adds no exposure that the pre-existing unwind ordering did not already create. (That ordering is a separate latent bug; see §5.) |
| 3 | `FrontendClose()` state loop, called from `FRONTEND_PREPARED` → `CLOSED/UNKNOWN` | `frontend.c:2916` `FrontendClose(Frontend, TRUE)` | **BOUNDED** | Frontend never connected; no rings, no fragment pages ever existed. |
| 4 | `FrontendClose()` state loop, called from `FRONTEND_CONNECTED` → `ENABLED` **failed** | `frontend.c:2936` `FrontendClose(Frontend, FALSE)` | **NOT bounded** | Backend is connected and has the rings mapped; `FrontendDisconnect()` on the next line revokes them. The wait is the only thing that orders unmap-before-revoke. |
| 5 | `FrontendClose()` state loop, ordinary teardown from `FRONTEND_CONNECTED` (device disable, driver unload, PnP stop, qube shutdown) | `frontend.c:2952` `FrontendClose(Frontend, FALSE)` | **NOT bounded** | The path blocker 2 is about. A merely-slow netvm taking >30 s to walk Connected → Closing → Closed must not cause revocation of still-mapped pages. |
| 6 | `FrontendConnect()` state loop | `frontend.c:2611` (post-patch) | **NOT bounded** | Rings and fragment pages are already granted at this point; the `fail9` unwind revokes and frees them. Same hazard as 4/5. Diagnostic only. |
| 7 | inner `FrontendWaitForBackendXenbusStateChange()` | `frontend.c:1519` | unchanged, now parameterised | Its 120 s cap was always per-call, never a bound on the outer loops. It now takes the caller's remaining budget so that an outer deadline is actually *effective* — previously an outer 30 s deadline would not have been checked until the inner call returned at 120 s. Unbounded callers pass `FRONTEND_MAX_WAIT` (120000), i.e. byte-for-byte the old behaviour. |

Mechanism: `FrontendGetStallBudget()` returns the remaining milliseconds (capped at
`FRONTEND_MAX_WAIT`), or 0 once the deadline passes. Bounded callers treat 0 as "stop";
unbounded callers treat 0 as "log once, then keep waiting with a full budget".

**Escape hatch:** `HKLM\SYSTEM\CurrentControlSet\Services\xenvif\Parameters\
FrontendBackendStallTimeout` (REG_DWORD, ms). Default 30000. **0 disables stall detection
entirely**, restoring pre-patch behaviour exactly (all loops unbounded, no diagnostic).
Read once at `FrontendInitialize()` time — it must be read at PASSIVE_LEVEL, because the
state machine itself runs at DISPATCH_LEVEL under `Frontend->Lock` and cannot touch the
registry. Same pattern as the existing `FrontendMaxQueues`.

---

## 3. Residual: v2 may not fully cure the *measured* mirage wedge

This is the most important caveat and it follows directly from blocker 2.

The 2026-08-02 capture (`ci-notes/mirage-netback-incompat.md`) recorded, during the hang:

```
backend/vif/446/0  type = "vif_ioemu"  state = "2"   (InitWait)
/local/domain/446/device/vif/0/state = "5"           (Closing)
```

Frontend at **Closing (5)** is diagnostic: the only code in xenvif that writes 5 with the
backend at InitWait is `FrontendClose()`'s `case XenbusStateConnected: case
XenbusStateInitWait:` arm. `FrontendPrepare()` writes 5 only when the backend is at
*Connected*; `FrontendConnect()` only ever writes 4. **So the guest was wedged inside
`FrontendClose()`.** And since the backend never reached Connected, `FrontendConnect()` and
`FrontendEnable()` cannot have succeeded, so `Frontend->State` cannot have been
`FRONTEND_CONNECTED` — which puts it in rows **2 or 3** of the table, both **bounded**.

⇒ On that evidence, v2 cures the measured wedge: the close gives up after 30 s, the start
fails, the node shows Code 10, and the console explains it.

But how `FrontendConnect()` returned in order to reach `FrontendClose()` is **not determined
by the captured evidence** (candidates: `ReceiverConnect`/`TransmitterConnect` failure, the
xenstore transaction exceeding 10 retries, or `PdoD3ToD0` requesting `FRONTEND_CLOSED`
directly). If on a retest the guest instead parks with **frontend state = 4 (Connected)**
and backend = 2, it is spinning in `FrontendConnect()`'s loop — row 6, deliberately
**unbounded** — and v2 will emit the diagnostic and then still wedge. That is the accepted
cost of not corrupting memory, and it makes the follow-on work in §5 mandatory rather than
optional. **Acceptance test A3 below is the discriminator; run it before declaring victory.**

---

## 4. The diagnostic contract (kept from v1, as the review accepted it)

Emitted by `FrontendStall()`, **at most once per stall episode**, six `Error()` lines:

```
XENVIF-BACKEND-STALL phase=%s frontend=%s
XENVIF-BACKEND-STALL backend=%s domid=%u
XENVIF-BACKEND-STALL observed=%u(%s) expected=%u(%s) elapsed=%ums
XENVIF-BACKEND-STALL this is a BACKEND fault, not a guest fault
XENVIF-BACKEND-STALL dom0: xenstore-ls -f %s
XENVIF-BACKEND-STALL %s                      <- per-call-site action line
```

`phase` is one of `PREPARE`, `CONNECT`, `CLOSE`, `CLOSE-CONNECTED` — which also tells the
reader whether the wait was bounded. Action lines:

| phase | action line |
|---|---|
| PREPARE | `failing device start; expect Code 10, no PV network` |
| CLOSE | `abandoning close; nothing was granted, so this is safe` |
| CLOSE-CONNECTED | `still waiting; backend must reach CLOSED before we revoke` |
| CONNECT | `still waiting; rings are granted, cannot revoke yet` |

Plus the xenstore error node, same shape as the existing `FrontendEjectFailed()`
(`frontend.c:461-466`): `error/<frontend-path>/error` =
`XENVIF-BACKEND-STALL <phase>: backend <path> stuck in <name> (<n>), expected <name> (<n>), after <n>ms`.

Constraints respected (all re-verified in source):

- **Free-build filter**: `xenbus/src/xen/log.c:558-565` drops any line whose first three
  bytes are not `x`,`e`,`n` (lowercase, literal byte compare). The `Error()` macro prefixes
  `__MODULE__ "|" __FUNCTION__ ": "` = `xenvif|FrontendStall: ` — passes. The helper is named
  `FrontendStall` deliberately: short, so the 22-byte prefix leaves room.
- **`LOG_BUFFER_SIZE` 256 with unchecked `RtlCopyMemory`** (`log.c:45`, `log.c:575`). Worst
  line is the `dom0:` one: 22 (prefix) + 42 (literal) + backend path (~45 for
  `/local/domain/427/backend/vif_ioemu/446/0`) ≈ **109 bytes**. All others are shorter.
  Comfortable margin.
- **32-slot ring shared with the other xen\* drivers** (`log.c` `Context->Slot`): six lines
  per episode, and the `Reported`/`Stalled` latches guarantee one episode's block is emitted
  once, not per loop iteration.
- `Error()` and `XENBUS_STORE(Printf)` at DISPATCH_LEVEL under `Frontend->Lock` are both
  already done by existing code on these paths (`FrontendSetXenbusState`,
  `FrontendEjectFailed`), so the new calls add no new IRQL constraint.

---

## 5. Follow-on work this patch deliberately does not do

1. **Make grant revocation non-fatal-but-non-freeing.** The only way to bound rows 4/5/6
   safely: on `RevokeForeignAccess` failure, *leak* the page instead of returning it to
   non-paged pool, and fail the operation loudly. 17 call sites plus their ownership/teardown
   paths (and `FrontendTeardown`'s `ASSERT(IsZeroMemory(...))` would need a leaked-object
   escape). This is the prerequisite for ever bounding `FrontendConnect()`.
2. **Pre-existing ordering bug, unrelated to this patch but found while writing it:**
   `FrontendConnect()`'s `fail5..fail9` unwind revokes the ring grants *before*
   `FrontendSetState()` calls `FrontendClose()` — i.e. before the backend is driven to
   Closed. If the backend had mapped the rings, they are revoked and freed while it may
   still hold them. Same class as blocker 2, already in shipping code.
3. **Get the handshake off DISPATCH_LEVEL.** The real cure for the CPU burn is running the
   state machine at PASSIVE_LEVEL under a mutex and using `KeWaitForSingleObject` with a real
   timeout instead of `KeStallExecutionProcessor(1000)` — as
   `ci-notes/mirage-netback-incompat.md` §7(b)(2) already argued. Touches `pdo.c`'s D0
   transitions. Larger, riskier, and orthogonal to failing loudly.
4. **Cosmetic consequence of a bounded close:** when `FrontendClose(…, TRUE)` gives up, the
   frontend's xenstore `state` node is left at whatever it last wrote — typically
   `Closing (5)` — rather than `Closed (6)`, because `FrontendClose()` only removes its
   `attr/vif/<name>` prefix, not `device/vif/<n>`. This is identical to the pre-existing
   behaviour when the loop breaks on `!FrontendIsOnline()`, and it is arguably *useful*: a
   frontend parked at 5 against a backend parked at 2 is precisely the signature dom0 should
   see. Noted so nobody reads it as a new bug.
5. **`ASSERT(FALSE)` in the `default:` arms** of both switches is untouched. On a checked
   build an out-of-range backend state still bugchecks; on a free build it is a no-op and the
   new deadline now catches it. Closing those arms explicitly is a separate cosmetic patch.

---

## 6. Acceptance tests

None of these have been run. All need dom0 assistance (attaching netvms, reading the guest
console log) — **ask the user**; do not attempt from this qube.

Common instrumentation for every test:

- dom0 guest console log `/var/log/xen/console/guest-*.log` — the primary artifact.
  `grep XENVIF-BACKEND-STALL`.
- dom0 `xenstore-ls -f /local/domain/<win>/device/vif` and
  `.../local/domain/<netvm>/backend/vif*/<win>` — captures the frontend/backend state pair.
- in-guest (only if qrexec survives, which is itself a result):
  `Get-PnpDevice -InstanceId 'XENVIF*'` for the problem code, and CPU load.

### A1 — backend stuck at **Initialising (1)**, i.e. BELOW InitWait  ← blocker 1's trigger

Setup: a netvm whose backend is parked below InitWait. Cheapest synthetic version: from
dom0, create the vif then hold the backend at `state=1` (never write 2), or point the guest
at a netvm known to park there. Pre-0.9.5 qubes-mirage-firewall reproduces this class
naturally (issue #127).

Expect, with the patch:
- console: `XENVIF-BACKEND-STALL phase=PREPARE ... observed=1(Initialising)
  expected=2(InitWait) elapsed=~30000ms`, plus the backend path/domid, the "BACKEND fault"
  line and the `dom0:` line;
- xenstore `error/device/vif/0/error` set;
- **the device node still exists** and shows a start failure (Code 10) — this is the
  regression test for blocker 1;
- **no eject/re-create loop**: sample `Get-PnpDevice` and the dom0 `xenstore-ls` repeatedly
  over ≥5 min; the `XENVIF\...&DEV_NET` instance must be *the same node throughout*, and
  `XENVIF-BACKEND-STALL` must appear a bounded number of times (once per PnP start attempt),
  not on a ~30 s cadence forever;
- guest reaches the desktop, qrexec answers, CPU is idle.

Fail signatures: repeated `PdoCreate`/`fail11` in the console, or the devnode disappearing
and reappearing, or a 30 s-periodic stall block ⇒ blocker 1 is not fixed.

### A2 — backend **dead after writing Closed (6)**  ← the other blocker-1 trigger

Setup: netvm writes backend `state=6` then stops servicing (or is paused from dom0 right
after). `FrontendPrepare`'s `case XenbusStateClosed` reads backend `online`; with `online`
absent/0 it takes `FrontendSetOffline()` — the genuine-disappearance path, eject is correct,
**and this test asserts we did NOT change that**. With `online=1` it writes Initialising and
waits, and the deadline should fire.

Expect: `online` false ⇒ clean eject, node goes away, no stall block (unchanged behaviour).
`online` true ⇒ `XENVIF-BACKEND-STALL phase=PREPARE ... observed=6(Closed)` and a surviving
Code 10 node.

### A3 — the measured mirage case, and the §3 discriminator  ← primary regression test

Setup: `fw-net` running qubes-mirage-firewall 0.9.5 as the guest's netvm (the exact
2026-08-02 configuration).

First, **before** judging the fix, capture the wedge point from dom0 while it hangs:
- frontend `state = 5` (Closing), backend `2` ⇒ wedge is in `FrontendClose()` (rows 2/3,
  bounded) ⇒ v2 should cure it. Expect `XENVIF-BACKEND-STALL phase=CLOSE ... observed=2(InitWait)
  expected=6(Closed)`, guest boots, qrexec alive, CPU normal, PV NIC Code 10.
- frontend `state = 4` (Connected), backend `2` ⇒ wedge is in `FrontendConnect()` (row 6,
  **not** bounded) ⇒ expect `XENVIF-BACKEND-STALL phase=CONNECT ...` on the console **and the
  guest still wedged**. That is the documented residual, not a regression — and it makes §5.1
  mandatory. Report it to the user rather than "fixing" it by bounding row 6.

### A4 — slow-but-healthy teardown must NOT be cut short  ← blocker 2's regression test

Setup: a working PV link (a Linux netvm), guest fully connected and passing traffic, then
make the backend's Connected → Closing → Closed walk take **longer than the 30 s deadline**
— e.g. from dom0, heavily starve or briefly pause the netvm domain, then `qvm-shutdown` the
Windows qube; or `Disable-PnpDevice` the Xen adapter under the same starvation.

Expect:
- console shows `XENVIF-BACKEND-STALL phase=CLOSE-CONNECTED ... still waiting; backend must
  reach CLOSED before we revoke` — **the diagnostic fires**;
- and the guest **keeps waiting**: no `FrontendDisconnect()`, no revocation, no pool free
  until the backend actually reaches `state=6`. Verify by watching the backend state go to 6
  and only then seeing the frontend teardown complete.
- Run the guest with **Driver Verifier** on `xenvif.sys` (special pool + pool tracking) for
  this test; a premature free of a still-mapped ring is exactly what special pool catches.

Fail signature: teardown completing while the backend is still at 4 or 5 ⇒ blocker 2 has been
reintroduced.

### A5 — no behavioural change on the happy path

Healthy Linux netvm, ordinary boot/shutdown/disable/enable cycles, plus a suspend/resume
(`__FrontendResume`/`__FrontendSuspend` drive the same state machine).

Expect: **zero** `XENVIF-BACKEND-STALL` lines, PV NIC connects and passes traffic, timings
indistinguishable from the unpatched driver.

### A6 — the escape hatch

Set `xenvif\Parameters\FrontendBackendStallTimeout = 0`, reboot, repeat A1.

Expect: pre-patch behaviour exactly — no stall block, unbounded spin. Confirms the knob and
gives support a one-value rollback without swapping the binary. Also spot-check a non-default
value (e.g. 5000) and confirm `elapsed=~5000ms`.

---

## 7. Change inventory (file:line, post-patch `frontend.c`)

| line | change |
|---|---|
| 86 | `ULONG BackendStallTimeout;` added to `struct _XENVIF_FRONTEND` |
| 140-150 | `FRONTEND_MAX_WAIT` (120000) and `FRONTEND_STALL_TIMEOUT_DEFAULT` (30000) |
| 272-297 | `FrontendSetStallTimeout()` — registry read at PASSIVE_LEVEL |
| 1299-1327 | `FrontendSetOfflineNoEject()` — blocker-1 primitive |
| 1407-1440 | `FrontendGetStallBudget()` (comment from 1407, body 1418) — deadline arithmetic |
| 1442-1516 | `FrontendStall()` (comment from 1442, body 1458) — the diagnostic contract + xenstore error node |
| 1520-1527 | `FrontendWaitForBackendXenbusStateChange()` gains `IN ULONGLONG TotalTimeout` (was a hard-coded local const) |
| 1636-1655 | rationale comment on `FrontendClose()`'s bounded/unbounded contract |
| 1656-1661 | `FrontendClose()` gains `IN BOOLEAN Bounded` |
| 1673-1708 | `FrontendClose()` deadline check; `break` only if `Bounded` |
| 1769-1794 | `FrontendPrepare()` deadline check, sets `Stalled` |
| 1839-1876 | `FrontendPrepare()`: `if (Stalled) goto stall;` (label at 1857) and the new `stall:` arm |
| 2512, 2606-2646 | `FrontendConnect()` diagnostic-only stall reporting (loop stays unbounded) |
| 2906, 2916 | `FrontendClose(Frontend, TRUE)` — never-connected call sites |
| 2936, 2952 | `FrontendClose(Frontend, FALSE)` — connected call sites |
| 3225, 3320, 3418 | `FrontendSetStallTimeout()` call; field zeroed in the `FrontendInitialize` `fail6` unwind and in `FrontendTeardown` (both feed `ASSERT(IsZeroMemory(...))`) |
