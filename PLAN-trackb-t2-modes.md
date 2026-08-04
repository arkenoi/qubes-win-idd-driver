# Track B / T2 Plan — arbitrary guest resolution that follows the dom0 window

Status: analysis only. No VM was touched and no repo file was modified in producing this. Every number below is either cited to source/docs or explicitly marked as unmeasured.

---

## 1. WHAT IS SETTLED

### 1.1 The dom0→guest channel already exists and needs no protocol change

- A user resize of the qube window produces `MSG_CONFIGURE` addressed to the screen window, remote id 0 (`qubes-gui-daemon/gui-daemon/xside.c:2006→2068`, `send_configure()` at `:1737-1750`; `FULLSCREEN_WINDOW_ID 0` at `xside.h:69`). This is the **only** channel; nothing else carries a qube-window resize.
- `qubes.SetMonitorLayout` is dom0's *physical* xrandr topology, emitted by `qvm-start-gui` on screen-layout change (`qvm_start_daemon.py:475-523`, `:593-601`). It is not a resize channel. There is **no Windows consumer** of it (agent fork, 577 commits, zero hits).
- The daemon accepts whatever size the guest reports for window 0 unconditionally — window 0 is exempt from `have_queued_configure` flow control, so the ack branch is skipped and the guest's geometry is adopted (`xside.c:2063-2069`, `:2124-2153`). Sanitisation is only `MAX_WINDOW_WIDTH/HEIGHT` = 16384x6144 (`qubes-gui-protocol.h:102-103`) and `width>0 && height>0`.
- Consequence: **the guest de facto owns the screen size.** 2566x1022 is legal on the wire today. The Linux agent already works this way (it *discards* `msg_xconf` — `vmside.c:2506-2507` — and synthesises modelines with `cvt`/`xrandr --newmode`: `qubes-set-monitor-layout:21-43`). An IddCx driver is the Windows equivalent of `xrandr --newmode`.
- `msg_xconf` is sent exactly once per vchan connection and never refreshed, not even on the daemon's SIGHUP (`xside.c:5041-5042`, only call site of `send_xconf`; `reload()` at `:801-810`).

### 1.2 The stock adapter's mode list is a limitation, not a constraint to satisfy

29 fixed modes; 1600x1000, 1234x777, 2566x1022 all rejected by `ChangeDisplaySettings(CDS_TEST)`; 1920x1080 accepted. Confirmed twice (agent `InitVideoModes()` at LogLevel=5, and CDS_TEST directly). Not re-derived here.

### 1.3 The agent chain: one lossy step, three latent bugs

Chain: `MSG_CONFIGURE` w0 → `RequestResolutionChange` (`vchan-handlers.c:543-566`) → 500 ms debounce, latest-wins (`resolution.c:196-221`) → `SetVideoMode` → `SelectSupportedMode` → `ChangeDisplaySettings`. Everything downstream of the snap is size-agnostic.

- **Lossy step:** `SetVideoMode` overwrites the caller's width/height with the snapped mode before doing anything else (`resolution.c:161-164`). `SelectSupportedMode` never fails and never reports substitution; it returns the highest-IoU entry (`:119-155`). It also filters out any mode larger than the never-refreshed `g_HostScreenWidth/Height` (`:131`).
- **Silent no-op:** after snapping, the snapped size is compared to the current one and returns "No change" (`resolution.c:166-170`). A dom0 resize 2560x1024 → 2566x1022 currently produces *no action and no diagnostic*.
- **Mode list built once**, at `Init()`, from `EnumDisplaySettingsW(NULL, …)` (`resolution.c:49-86`, called from `main.c:3922`). A driver adding a mode at runtime is invisible until agent restart.
- **No readback:** `SetVideoModeInternal` checks only the return code (`resolution.c:100-116`); `g_ScreenWidth/Height` are assigned from what was *requested*, in the only place in the whole agent that assigns them (`resolution.c:181-182`).
- **Two sources of truth for the framebuffer size:** the grant is sized from `ctx->width/height` (DXGI desc, `capture.c:524`) but the `MSG_WINDOW_DUMP` page count and header are sized from `g_ScreenWidth/Height` (`main.c:3404`, `:3551-3553`; `send.c:111-114`), written by a different thread. If the sent count is too small, **dom0's gui-daemon calls `exit(1)`** (`xside.c:3903-3913`); too large and the agent reads past its `malloc`'d `grant_refs` array (`capture.c:526`).
- **Cache read as intent:** `SetVideoMode` writes `FullscreenWidth/Height` on every successful change including its own (`resolution.c:183-185`); `HandleXconf` reads them as "user-chosen resolution" (`vchan-handlers.c:117-134`). This is why the guest reported host 5120x1440 and set 3440x1440.
- **Seamless forces the host size** on every `StartFrameProcessing` (`main.c:1888-1897`, called with `forceUpdate=TRUE` at `main.c:3409`). Any "default 1600x1000" is overwritten within milliseconds in seamless mode.
- **No pitch anywhere.** `msg_window_dump_hdr` carries `{type,width,height,bpp}` only (`qubes-gui-protocol.h:308-313`); the agent assumes `stride = g_ScreenWidth*4` (`util.c:360`); `DXGI_MAPPED_RECT.Pitch` is never read.
- **Resolution change destroys window 0** rather than re-dumping it: capture error → `StopFrameProcessing` → unmap+destroy all windows → recreate (`main.c:3716-3721`, `:3422-3441`, `:3701-3712`). The protocol does *not* require this — `handle_window_dump` calls `release_mapped_mfns()` first (`xside.c:3875`) and `MSG_WINDOW_DUMP_ACK` exists (`xside.c:3692-3694`).

### 1.4 0x887A0026 is not a keyed mutex, and is mostly fixed here

`0x887A0026 == DXGI_ERROR_ACCESS_LOST`; the string is a `FormatMessage(FROM_SYSTEM)` artefact (`instrumentation/ACCESS-LOST-BUG.md:29-38`, in-code note `capture.c:752-756`). The fork recovers in place on both acquire and release paths (`capture.c:757-763`, `:807-813`, `:212-294`).
**Still broken, and it is exactly the T2 path:** `RecreateDuplication` deliberately returns FALSE when the geometry changed (`capture.c:272-280`), and a resolution change *always* changes geometry — so in-place recovery is unreachable by construction for the one event T2 generates continuously.

### 1.5 The driver as vendored

- Stock upstream Microsoft source; only the INF was changed in this repo (`git log --follow` shows only `IddSampleDriver.inf`).
- Mode lists are three `const` C arrays plus a hardcoded target list inside the callback body (`Driver.cpp:29-35`, `:41-75`, `:772-781`; arity fixed by `szModeList=3`, `Driver.h:41-51`). Nothing is runtime-writable.
- The frame loop is a pure acquire/release no-op with a TODO where processing belongs (`Driver.cpp:368-469`, TODO at `:428-437`). No dirty rects, no cursor, no `ReportFrameStatistics`, no adapter flags (`AdapterCaps = {}`, `:494-513`).
- `IDD_SAMPLE_MONITOR_COUNT = 3` (`Driver.cpp:27`) with only 2 EDIDs, and the INF declares **two** hardware IDs (`Root\IddSampleDriver` and `IddSampleDriver`), both of which were observed live in Phase 1B. Each node instantiates the full monitor count. `IddSampleApp` holds the SWD node open with a `_getch()` console loop (`IddSampleApp/main.cpp:76-88`) — over qrexec its lifetime is not controllable.

### 1.6 The IddCx rules that shape the design

- The OS offers the **intersection** of the monitor mode list and the target mode list (stated in the sample itself, `Driver.cpp:768-770`).
- `IddCxMonitorUpdateModes` carries **target modes only** — `IDARG_IN_UPDATEMODES = {Reason, TargetModeCount, pTargetModes}`, no monitor member (DDI ref; struct confirmed in IddCx.h 10.0.14393.0:1399-1415).
- Monitor modes come only from `EvtIddCxParseMonitorDescription` / `EvtIddCxMonitorGetDefaultDescriptionModes`, both described as fired by the OS when a monitor is **connected**.
- The escape flag `IDDCX_ADAPTER_FLAGS_REMOTE_ALL_TARGET_MODES_MONITOR_COMPATIBLE` is IddCx **1.10 and remote-only** — unavailable. `IddCxAdapterDisplayConfigUpdate` is likewise remote-only. **A console IDD must have the mode applied by a session-side caller — which the gui-agent already is.**
- Guest is Win10 19045 → **IddCx 1.5** (`IddCxGetVersion` 0x1500). Everything needed for the feature exists in IddCx 1.0. 1.5 additionally provides `IddCxSwapChainInSystemMemory` / `…ReleaseAndAcquireSystemBuffer` (availability on this build unverified — the DDI pages list a Server 2022 minimum with a blank client field).
- An IDD monitor is enumerated by the DX runtime **on the render adapter**, not on a separate DXGI adapter (IddCx 1.4 console/remote table). On this guest adapter 0 is already "Microsoft Basic Render Driver" (WARP).

### 1.7 What Phase 1B actually established — and the caveat

`instrumentation/PHASE1B-RESULT.md:19-20` records `DesktopImageInSystemMemory = TRUE` with the IDD **present and INACTIVE**, 1 DXGI output, BDA owning the desktop; and `:74-76` says in terms that this does **not** carry over. `:53-68` records that `DisplaySwitch /extend` was refused ("Your PC can't project to another screen").

**Evidence quality caveat, stated plainly:** no raw ddaprobe JSON was committed for that run, `FINDINGS.md` has no Phase 1B entry, and the `monitor_count` the coexistence script collects was never reported. The stock sample calls `IddCxMonitorArrival` three times, yet the run saw one DXGI output and an unchanged bounding box. **"Present but inactive" and "present but no monitor ever came up" are not distinguishable from that record**, and the second reading explains the "can't project" message with no topology theory at all. Any plan that assumes the first reading is building on thin evidence.

---

## 2. THE GATING QUESTION — `DesktopImageInSystemMemory` under an IDD

### 2.1 What is documented

- The flag's **only** documented consequence: `MapDesktopSurface` is permitted. If FALSE it returns `DXGI_ERROR_UNSUPPORTED` and the app must `CopyResource` into a staging texture and `Map` that. Desktop Duplication itself works either way.
- **Nothing** in Microsoft's documentation states what an indirect display reports. `DXGI_OUTDUPL_DESC` names no condition making it TRUE or FALSE; the DDA overview never mentions indirect displays.

### 2.2 What the agent does with a FALSE

`capture.c:317-324` in this fork (= upstream `capture.c:176-183`, same code) releases the duplication, logs `"TODO: desktop is not in system memory"`, and returns NULL. There is no fallback.

- Cold path: `CaptureInitialize` fails → `StartFrameProcessing` fails → `exitLoop` → **gui-agent process exits** (`capture.c:380-382`, `:398-401`; `main.c:3391-3393`, `:3664-3670`, `:3954-3958`). The watchdog restarts it every second (`watchdog.c:153-160`) → ~1 Hz crash loop, **no windows at all in dom0**.
- Hot path (flag flips mid-run): 20 × 250 ms = **5 s frozen desktop**, then teardown of every window, then the cold path.

Two further kill paths exist that are **independent of the flag** and are not in CLAUDE.md:

- **Output selection is unselectable.** `GetAdapter` keeps only adapter index 0 (`capture.c:44-77`); `GetOutput` returns the first output with `AttachedToDesktop` (`:107-153`). Two attached outputs on adapter 0 → the agent captures whichever is enumerated first, with no override.
- **Stride.** Everything assumes rows are tightly packed at `width*4`. Today `pitch == 13760 == 3440*4` exactly (`instrumentation/baseline-bda-idle.txt`). Nobody has ever checked `pitch == width*4` as an acceptance criterion.

### 2.3 Hypothesis (explicitly not a result)

The flag is TRUE today because **the render/composition adapter is WARP** — the baseline shows exactly one DXGI adapter and it is "Microsoft Basic Render Driver" — not because of anything the BDA display path does. IddCx does not composite; the OS renders on the POST adapter, or WARP if none, and on a GPU-less Xen HVM the renderer is software-backed system RAM either way. So I would put "stays TRUE on this guest" at better than even odds — and near zero on any guest with a real GPU. **This conclusion will not generalise to GPU passthrough; do not port a PASS.**

Countervailing: TRUE also requires DXGI to expose the surface as *mappable linear* system memory, not merely physically resident. A driver-chosen tiling/alignment can legitimately yield FALSE for a texture that is in RAM. This is where the flag question and the pitch question converge, and why it must be measured.

### 2.4 The exact first experiment

**Do not run it on the stock sample.** The stock configuration differs from anything that could ship in four load-bearing ways — 3 monitors × up to 2 device nodes, an `IddSampleApp` console-loop lifetime, no adapter flags, and 1920x1080 (a 64-byte-aligned width). The flag is a property of exactly those variables. Running it on stock would repeat the Phase 1B non-transfer error one level up.

**Precondition build (D0, constants only, ~20 lines):** `IDD_SAMPLE_MONITOR_COUNT = 1`; EDID-less monitor (`MonitorDescription.DataSize = 0` — routes modes through the simple driver-side callback); single hardware ID in the INF (drop the SWD models line so no `IddSampleApp` is needed); **no adapter-flag change** (see §5). Do not rebrand yet — a rebrand changes the device path and invalidates the existing install recipe for no measurement gain.

**Precondition safety:** the decisive configuration cannot be reached by extend (Phase 1B). It requires the IDD to **replace** the BDA. Before the BDA is ever disabled, the PnP re-enable must be **proven to fire** — see experiment 7 in §7. The `SetDisplayConfig` half of any auto-revert is **not** load-bearing and must not be counted: `SetDisplayConfig` returns `ERROR_ACCESS_DENIED` when the caller has no access to the current desktop, so a SYSTEM task in session 0 cannot repair session 1's topology.

**Run:** three interleaved runs — BDA-primary control, IDD-primary test, BDA-primary control — each `ddaprobe.exe 100 30 --json out.json` with `instrumentation/activity-gen.ps1` driving desktop activity concurrently (idle desktops yield ~1 acquired frame in 15 s; the latency and dirty-rect numbers are meaningless without activity). **Cold boot per side.**

**Read, in this order:**

| JSON field | Meaning |
|---|---|
| `outputs[].adapter_index` / `.adapter` / `.output_index` / `.device_name` / `.attached_to_desktop` | *Asked before the flag.* Where did the IDD monitor land? Is the BDA output still attached? Which is first on adapter 0? Two attached outputs on adapter 0 is a **blocking finding independent of the flag** — `capture.c` has no override. |
| `summary.agent_capture_would_work` | The direct `capture.c:317-324` verdict; ddaprobe models the agent's exact selection (`ddaprobe.cpp:1155-1174`). |
| `outputs[].desktop_image_in_system_memory` and `…_ever_false` | The flag, plus whether it **flipped mid-run**. A flip means even a passing cold check is unsafe. |
| `outputs[].map_desktop_surface.{ok,hr_name,pitch,pbits_non_null}` | Independent corroboration via the exact call `capture.c:515` makes. **`pitch` must equal `mode.width*4`.** |
| `outputs[].duplication_ok` / `duplication_hr_name` | A `DuplicateOutput` failure is *worse* than Outcome B — the per-window engine also relies on DDA dirty rects as its trigger. |
| `outputs[].loop.{access_lost,reduplications,reduplication_failures}` | Non-trivial counts on a steady desktop mean the IDD churns the duplication, promoting the §3 A6 fix from prerequisite to hard blocker. |
| `outputs[].mode.format` | Must be `B8G8R8A8_UNORM` (87). Any other format is silent corruption, not an error. |

**What each result means:**

- **TRUE + pitch == width\*4 + single attached output on adapter 0** → Outcome A **for this configuration**. Proceed to §4 D2. Record the verdict as scoped to the D0 driver; re-measure if the driver's adapter caps or mode source change.
- **TRUE but pitch != width\*4** → Outcome A *with a blocker*. Capture survives; the image shears; there is no protocol field to fix it. This escalates to a Phase 3 protocol design issue (stride in `MSG_WINDOW_DUMP`) — see §6.
- **TRUE but two attached outputs, or the IDD on a non-zero adapter** → blocked on an agent change (explicit output selection) before anything else in Track B.
- **FALSE** → Outcome B. **Do not go to CLAUDE.md's swapchain-grant design first.** Prefer **B1: keep DDA, delete the hard-fail, allocate a persistent `D3D11_USAGE_STAGING` texture, `CopyResource`, `Map` once, grant those pages.** ~150 lines confined to `capture.c`; the grant already targets a stable VA (`capture.c:511-552`) and a persistent staging texture gives the same. Cost is one copy per frame, restrictable to dirty rects. B2 (IDD owns the grant) costs an unverified UMDF→xeniface capability, a new IPC trust boundary, and a blast radius that includes **bugchecking the guest** — from Win10 1903 IddCx bugchecks on any `EvtIddCxMonitorAssignSwapChain` return other than `STATUS_GRAPHICS_INDIRECT_DISPLAY_ABANDON_SWAPCHAIN`.
- **`DuplicateOutput` fails outright** → stop; present to the user. The per-window path loses its trigger too.

**Instrument validation before any of the above counts** (CLAUDE.md rule): (a) hash the on-guest `ddaprobe.exe` against the CI manifest every run; (b) assert `session_id: 1`, `WinSta0`, `Default` in the JSON — session 0 voids the run and ddaprobe only warns; (c) three baseline runs on the *current* configuration must all agree — note `baseline-bda-idle.txt` reads `os_build 19044.1288` (LTSC) while the guest is now retail 19045, so every existing baseline is from a different SKU and must be retaken; (d) **honesty requirement:** ddaprobe's FALSE branch has never executed against real DXGI (`tools/ddaprobe/README.md:166-181` — validated on Linux against hand-written stubs). Invert the flag test in a scratch build and confirm the summary flips and the exit code is non-zero. That proves the reporting path can express failure; it does **not** prove DXGI can produce FALSE here. Record any PASS as unproven until then.

---

## 3. WHAT CAN LAND WITHOUT THE DRIVER

All five are independently valuable, all are prerequisites for trusting any driver measurement, none needs the gating question answered. **Each is a separate branch** (CLAUDE.md Phase 2A).

### A0 — `tools/modeprobe` (instrument, lands first)

A small console tool: `EnumDisplaySettingsExW` over every display device (all modes + `ENUM_CURRENT_SETTINGS`), `CDS_TEST` for a requested size, JSON out. Read-only apart from `CDS_TEST`, which applies nothing. This is the **external witness** — the only thing in the project that can contradict the agent's own claims, and the PowerShell probe it replaces is already known-broken.
*Acceptance (failable):* must list the BDA's 29 modes, must include 1920x1080, must **not** include 1600x1000 — corroborated independently by `FINDINGS.md:1848-1853`.

### A1 — make the snap visible (instrument in the agent, lands second)

Log, on every resolution decision: `RESREQ w×h` (what arrived), `RESSNAP w×h` (what `SelectSupportedMode` chose, plus an explicit `SNAPPED` marker when it differs), `RESAPPLIED w×h` (readback), `RESSOURCE {xconf|preferred|lastapplied|default|dom0}`.
This build is the **control build** for A2–A4. Instrumenting first is what makes those controls able to fail rather than abstain: the pre-fix binary emits comparable lines, so a disagreement is data, not missing data.
*Measurement:* request 1600x1000 via a scripted `MSG_CONFIGURE` (dom0 resize) or directly; the log must show `RESREQ 1600x1000 / RESSNAP 1920x1080 SNAPPED`.
*Control that fails:* request 1920x1080 → no `SNAPPED` marker. If the marker appears on an exact match, the instrument is wrong.

### A2 — readback + single writer for `g_ScreenWidth/Height`

After `ChangeDisplaySettings`, call `EnumDisplaySettings(…, ENUM_CURRENT_SETTINGS)` and assign `g_ScreenWidth/Height` from **what Windows applied**, not from the request. Fail loudly if they differ from the snap.
*Measurement:* three interleaved rounds, cold boot per side, A1-build vs A2-build, requesting an unsupported size.
*Control that fails, and is known to fail on the defective build:* on the A1 build, the agent's `RESAPPLIED` must disagree with `modeprobe`'s `ENUM_CURRENT_SETTINGS` read from a separate process. This is a check seen to fail with the defect present — CLAUDE.md rule 5 satisfied.

### A3 — one source of truth for the framebuffer size

Derive **both** the `MSG_WINDOW_DUMP` page count and the header geometry from the capture context's DXGI desc (`ctx->width/height`), not `g_Screen*` (`main.c:3404`, `:3551-3553`; `send.c:111-114` vs `capture.c:524`).
This is a **dom0-crash-prevention fix** — the short-count case is `exit(1)` in the gui-daemon (`xside.c:3903-3913`) — and it stands entirely on its own, independent of every driver decision.
*Measurement:* add an assertion + log line comparing the two derivations on every dump, then drive a resolution change.
*Control that fails:* on the A1 build the assertion must **fire** during a resolution change (they are written by different threads at different times). If it never fires, either the race is narrower than traced or the instrumentation is in the wrong place — say so rather than declaring the fix validated.
*Honesty note:* I traced this divergence in source but it has **not been observed happening**.

### A4 — preference vs cache split

Three distinct registry roles under `HKLM\Software\Invisible Things Lab\Qubes Tools`:
- **NEW** `PreferredWidth`/`PreferredHeight` — written only by the installer or an explicit user action, **never** by the agent. This is intent.
- **EXISTING** `FullscreenWidth`/`FullscreenHeight` — keep being written by `SetVideoMode`, but re-read only as continuity-across-reboot. Rename in comments to `LastApplied*`.
- Compiled-in fallback **1600x1000**.

`HandleXconf` precedence: `Preferred` (if valid and ≤ ceiling) → `LastApplied` (if valid and ≤ ceiling) → `min(1600,hostW) × min(1000,hostH)`. First boot with nothing set takes branch 3 and writes **nothing** to `Preferred*`.

*Ordering constraint:* `HandleXconf` runs **before** `WorkAreaInit`/`WorkAreaApply` (`main.c:3651-3661`) and the qubesdb work area arrives asynchronously (`workarea.c:270-311`). The ceiling is not available when the boot mode is chosen unless `HandleXconf` does a synchronous `qdb_read` first.

*Measurement — and this is the acceptance nobody had:* **cold boot**, in **non-seamless mode**, with no registry values → `modeprobe` `ENUM_CURRENT_SETTINGS` must read the honest snap of 1600x1000 and must **still read it 60 s later**. A reboot is part of acceptance.
*Control that fails:* the A1 build on the same cold boot must land on the `FullscreenWidth` cache value (the already-recorded 3440x1440-from-a-5120x1440-host behaviour).

**Do not touch `SetSeamlessMode`'s force-to-host in this branch.** In seamless mode the default is overwritten within milliseconds (`main.c:1888-1893`), and `StartFrameProcessing` re-enters `SetSeamlessMode(…, forceUpdate=TRUE)` after every capture teardown (`main.c:3409`, `:3701-3713`). Applying a preference there, while `RecreateDuplication` still bails on geometry change (`capture.c:272-280`), builds a resolution oscillator: apply → `ChangeDisplaySettings` → `ACCESS_LOST` → teardown → `StartFrameProcessing` → re-apply. **A6 must land before that is even considered**, and T2 is a non-seamless goal, so it need not be considered at all for T2.

### A5 — work area as an unclamped ceiling

Add `WorkAreaGetDom0Ceiling(int *w, int *h)` returning the **unclamped** dom0 usable size minus frame extents — `(g_WaDom0.right-left) - fl - fr` × `(g_WaDom0.bottom-top) - ft - fb` — and returning FALSE when only the *inference* source is available (inference is expressed relative to the current screen and carries no absolute size).
The existing work-area code cannot be reused: both `WaCompute`'s dom0 branch and `WaRectSane` clamp against `g_ScreenWidth/Height` — the very thing we are choosing (`workarea.c:46-51`, `:78-84`). Using it to pick a mode is circular.
**The ceiling clamps the default/preferred mode only.** It must **not** be applied to a size dom0 explicitly requested via `MSG_CONFIGURE` on window 0 — that size is by construction the client area dom0 can display.
*Measurement:* log `CEILING w×h source={registry|dom0|none}` at boot and compare against the dom0 window's actual usable size.
*Control that fails:* with neither the registry value nor the qubesdb watcher installed (the measured live state — `FINDINGS.md:911-914`), the accessor must return **FALSE/none**, not a plausible-looking inferred number. If it returns a number, it is fabricating one.

### A6 — in-place recreate across a geometry change (needs a design note, see §6)

`RecreateDuplication` should update `ctx->width/height` from the new desc, let `GetFrame` re-map and re-grant, republish `MSG_WINDOW_DUMP` at the new geometry, and send `MSG_CONFIGURE` for window 0 — instead of returning FALSE and tearing down every window. A3 is a hard prerequisite (the republish is what would otherwise send the mismatched count that `exit(1)`s dom0).
**This is grant-lifecycle work.** Today the agent revokes the grant *before* dom0 has been told anything (`capture.c:244-252`), and dom0 releases its mapping only at the top of `handle_window_dump` (`xside.c:3875`) — an inversion that is currently rare (recovery only) and that A6 promotes to the steady-state per-resize path. `MSG_WINDOW_DUMP_ACK` is handled but drives only `PwRevokeTick()` for the per-window path (`vchan-handlers.c:698-702`); the screen grant has no ack gating. CLAUDE.md Phase 3 requires a design writeup and user review before this code. **Write the note, get approval, then implement.**

### A7 (small, high value, unconditional) — degrade instead of dying

Make a failed `CaptureInitialize` a degraded mode rather than a process exit. The per-window engine (`wincapture.cpp`, `perwindow.c`) uses `PrintWindow`, opens its own xencontrol handle, and does not need DDA except as a dirty trigger — but it is killed by the same hard-fail because `StartFrameProcessing` calls `CaptureInitialize` unconditionally and exits on failure (`main.c:3391-3393`). This converts a class of fatal capture failures into a degraded seamless session **whether or not the flag ever goes FALSE**. It is *not* a fallback for T2, which needs a whole-desktop framebuffer.

---

## 4. THE DRIVER PLAN, STAGED

Only stages that survived critique, in dependency order. Every stage names a control that can fail.

### D0 — minimal shippable identity (constants only)

`IDD_SAMPLE_MONITOR_COUNT = 1`; EDID-less monitor; single hardware ID in the INF (no `IddSampleApp` dependency, so the monitor set does not evaporate when a qrexec session ends); no adapter-flag changes; no rebrand.
*Measurement:* with the IDD installed and inactive — exactly **one** device node, exactly **one** IDD monitor (`WmiMonitorBasicDisplayParams` count, reported this time), desktop bounding box (`GetSystemMetrics(SM_CXVIRTUALSCREEN/SM_CYVIRTUALSCREEN)`) unchanged from baseline, `qtest shot` decoded-pixel output equivalent to baseline.
*Control that fails:* a scratch build with `MONITOR_COUNT = 3` **must** change the monitor count and/or the bounding box. If it does not, the driver is not bringing monitors up at all and the entire Phase 1B "present but inactive" reading is wrong — which is a finding in itself, and the one that would explain the "can't project" message.

### D1 — the gating measurement

Exactly §2.4. Cold boot per side. Verdict is scoped to the D0 driver.

### D2 — virtual-mode sweep (free, same configuration as D1)

With the IDD owning the desktop and **no** `USE_SMALLEST_MODE`, the OS is in virtual-mode composition: it can serve extra desktop sizes by DWM-scaling into a larger swapchain, with no display mode change. Sweep `CDS_TEST` then apply over 1600x1000, 2566x1022, 1234x777, 1400x1050 — sizes in neither the monitor nor the target list — and read `modeprobe` + `ddaprobe` after each.
*Why this comes before any mode-store work:* if the OS already serves arbitrary desktop sizes, **T2 needs no runtime mode-add at all** and D3/D4 evaporate.
*What to record per size:* accepted or `DISP_CHANGE_BADMODE`; `ENUM_CURRENT_SETTINGS`; `ddaprobe` `mode.width/height`; **`map_desktop_surface.pitch` vs `width*4`**; whether `desktop_image_in_system_memory` held.
*Control that fails:* the same sweep on the **BDA** must reject all four (already established twice). If the BDA accepts them, the harness is not applying what it thinks it is.
*Caveat:* under virtual modes the driver's swapchain surface is *not* the desktop size. Under Outcome A that is irrelevant — the agent grants DDA's desktop surface — but it would matter enormously under Outcome B, so record the branch.

### D3 — the `UpdateModes` spike (throwaway, ~50 lines, only if D2 says no)

Publish one extra target mode at runtime (hardcoded timer is enough; no IOCTL, no mode store, no `iddctl`) and poll `EnumDisplaySettingsExW` on the IDD's device name for it.
*Why now, before any engineering:* the plan's own facts predict this **fails** — `IDARG_IN_UPDATEMODES` carries target modes only, monitor modes come only from connection callbacks, and the OS offers the intersection — and the one public report of exactly this use case (MS Q&A 5924412, unanswered) says the monitor blinked black and the resolution never appeared. Settling it costs one throwaway build; getting it wrong costs the whole D4 apparatus.
*Precondition note (thin evidence):* I expect this to be observable with the IDD **present but inactive**, since `EnumDisplaySettingsEx` enumerates modes for an unattached display device. I have not verified that. If it is not observable, D3 folds into the D1 configuration and inherits its BDA-disable precondition.
*Control that fails:* a mode published in the target list at **arrival** (not at runtime) must appear in `EnumDisplaySettingsEx`. If even that does not appear, the probe is looking at the wrong device name and the negative result is meaningless.

### D4 — mode supply, branched on D3

- **D3 positive:** mutable, lock-protected mode store in `IndirectDeviceContext`/`IndirectMonitorContext` (replacing the `const` tables and the fixed `szModeList`), a custom IOCTL via `EvtIddCxDeviceIoControl` (the sample has the line commented out at `Driver.cpp:219-221`) plus `WdfDeviceCreateDeviceInterface` with a Qubes GUID and a SYSTEM/Administrators SDDL, and `IddCxMonitorUpdateModes` on the target side. **The agent applies the mode** — a console IDD cannot. Registry for the boot-time list, IOCTL for live requests. Named pipes and a qubesdb client inside `WUDFHost` are rejected (§5).
- **D3 negative:** a **dense pre-declared monitor-mode grid** published at arrival (e.g. widths and heights on a fixed step across the plausible dom0 window range), with the target list matching. Delivers T2 honestly as *"follows the dom0 window to within N px"*, needs no runtime monitor-mode mutation, and avoids the replug entirely. **This changes the T2 acceptance criterion and must be re-agreed with the user before it is built.**

*Measurement (either branch):* `modeprobe` must list the requested size on the IDD device within a bounded wait after the request, and `ENUM_CURRENT_SETTINGS` must equal it after the agent applies it.
*Control that fails:* the driver must **refuse** a size outside its policy (e.g. beyond a configured cap) and the refusal must be visible at the IOCTL return — **not** by requesting 100x100, which the *agent* rejects at `vchan-handlers.c:554-558` before the driver is ever consulted and would therefore "pass" with no driver installed.
*State hygiene:* any A/B across agent builds on a D4 driver must reset the driver's mode store between sides (reload the driver, or assert an empty store via a GET_STATE IOCTL). Otherwise the old agent enumerates modes the new agent published and the comparison is void.

### D5 — end-to-end T2

Cold boot in non-seamless mode → guest at 1600x1000 → dom0 window resized to 2566x1022 → guest at 2566x1022.
*Acceptance, all required:*
1. `modeprobe` `ENUM_CURRENT_SETTINGS` == 2566x1022 (external witness, not the agent's log).
2. `ddaprobe` `map_desktop_surface.pitch == 2566*4`. **Re-assert per size**, not once.
3. A **fiducial** correctness check — render a known full-desktop pattern in the guest, capture via `qtest shot`, decode, and compare. Without this, a pitch-padded sheared framebuffer passes every other criterion. This is the failure class that already voided an acceptance suite.
4. Zero window-0 destroy/create events during the resize (requires A6).
5. gui-agent process start time unchanged across the resize (no crash-loop).
6. Cold boot again → still 1600x1000 unless a resize is requested.
*Control that fails:* the same sequence with the BDA (no driver) must fail criterion 1 by snapping to a different size — and with the A1-only agent must fail criterion 4.
*Blocking dependency:* `tools/qtest` exposes `run/ps/push/pushrun/start/shutdown/kill/state/shot/fullshot` — **there is no way to resize the qube's X window from this qube.** See §6.

---

## 5. KILLED OPTIONS

| Option | Why it is dead |
|---|---|
| Running the gating measurement on the **stock sample** | 3 monitors × up to 2 device nodes, `IddSampleApp`'s `_getch()` lifetime over qrexec, no adapter flags, 64-byte-aligned width. The answer would not transfer to anything that ships — the exact non-transfer Phase 1B already recorded and disclaimed. |
| Setting `IDDCX_ADAPTER_FLAGS_USE_SMALLEST_MODE` up front | Justified as "pixel-exact framebuffer to grant", but under Outcome A the agent grants **DDA's desktop surface** (`capture.c:511-544`), never the driver swapchain. The flag is irrelevant to grant exactness there, costs a real mode change per resize step, and is precisely the flag that **disables the virtual-mode behaviour D2 exists to measure**. |
| `IDDCX_ADAPTER_FLAGS_REMOTE_ALL_TARGET_MODES_MONITOR_COMPATIBLE` | IddCx 1.10 and remote-only. Guest is 1.5. Its documented motivation is literally our use case, and it is unavailable. |
| `IddCxAdapterDisplayConfigUpdate` to apply the mode from the driver | Remote-drivers-only; requires `IDDCX_ADAPTER_FLAGS_REMOTE_SESSION_DRIVER`, which `IddCxAdapterInitAsync` rejects for a non-RDP device. The agent is the session-side applier. |
| Monitor **departure/arrival per resize step** | Documented costs: registry entries accumulate until Windows starts picking resolutions at random; the monitor vanishes mid-cycle, scattering windows and changing the desktop bounding box — the exact hazard CLAUDE.md Phase 1B warns about. Acceptable at most as a rare escalation, never as the interactive path. |
| A new **EDID per resolution** | Same registry-clutter failure, plus flicker from apparent disconnect. |
| Named pipe or a qubesdb client **inside the driver** | The IDD runs in Session 0 in `WUDFHost`; Microsoft's guidance is against inappropriate user-mode APIs there. A pipe needs a hand-written DACL and a per-device name because of `WUDFHost` process pooling. A qubesdb client would put a xeniface/QubesDB dependency inside `WUDFHost` at driver-load time. Correct topology: qubesdb → agent → IOCTL → driver. |
| **B2 (IDD owns the grant path) as the first response to a FALSE flag** | Unverified whether `WUDFHost` can reach xeniface gnttab IOCTLs at all; new IPC trust boundary; and a bug in `EvtIddCxMonitorAssignSwapChain` **bugchecks the guest** from Win10 1903 onward. B1 (DDA + persistent staging texture) is ~150 lines in `capture.c`, touches neither the protocol nor dom0, and fails by killing a restartable user process. Grant cost is not the issue — measured 4.7–6.5 ms per 1080p grant, ~90 µs revoke (`FINDINGS.md:176-188`). |
| **Byte-wise tar diff** of two `qtest shot` captures as a liveness check | Cannot fail: the screenshot service tars a fresh `mktemp` dir (per-run mtimes) and ImageMagick stamps `date:create`/`date:modify` tEXt chunks. Two captures of a frozen desktop differ. Must decode pixels, and the comparator must first be **shown to report "no change"** on a deliberately static desktop. |
| Cropping `qtest fullshot` to isolate the VM | Already retracted in `FINDINGS.md` (~line 682): fullshot captures the whole dom0 desktop and cropping does not isolate our VM. Another qube repainting under the crop yields a false PASS. |
| `SetDisplayConfig` from a SYSTEM scheduled task as the BDA auto-revert | Session 0 has no access to session 1's desktop; documented `ERROR_ACCESS_DENIED`. Only the PnP re-enable is load-bearing, and only it can be validated. |
| The INF `IddCx0102` → `IddCx0104` "fix" | Phase 1B loaded this INF with `CM_PROB_NONE`; no Microsoft documentation for an `IddCx0104` string was found; `IddCx0102` is what shipping drivers declare regardless of compiled `IDDCX_VERSION_MINOR`. Not a problem, and a CI round trip spent on it is wasted. *(Separately: the retained `AddService=WUDFRd` fix was justified by LTSC 2021 shipping no `WUDFRD.inf`; the guest is now retail 19045 where it does ship. The fix is harmless but its premise no longer holds.)* |
| A single agent branch bundling preference split + ceiling + snap logging + readback + single-source-of-truth + teardown rewrite | CLAUDE.md Phase 2A requires one fix per branch with before/after numbers. Bundled, no individual control can fail. |
| Removing `SetSeamlessMode`'s force-to-host as part of T2 | Builds a resolution oscillator until A6 lands (§3 A4 note), and leaves seamless mode with a 1600x1000 desktop on a 5120x1440 host — windows placeable in a region dom0 never sees. T2 is a non-seamless goal; leave seamless alone. |
| Deferring the pitch question behind the driver stages | `1400x1050` is in the BDA's existing 29-mode list and `1400*4 = 5600` is 32-byte but **not** 64-byte aligned. One `ChangeDisplaySettings` plus one existing `ddaprobe` run, today, with no driver, answers a large part of a killer. *(Partial: 2566*4 = 10264 is only 8-byte aligned, so a PASS at 1400x1050 does not clear 2566.)* |
| A ~100-cold-boot measurement schedule | Roughly 1 boot in 9 wedges in Transient, VM-mutating jobs must run serially, and CLAUDE.md escalates after ~3 focused iterations per phase. The schedule in §7 is ~25 boots. If it grows, **cut stages, not controls** — and say which stages were cut. |

---

## 6. OPEN QUESTIONS AND PROTOCOL RISK

**Needs user approval before code:**

1. **Stride in `MSG_WINDOW_DUMP`.** If `pitch != width*4` at arbitrary widths, there is no protocol field to express it and the daemon assumes tight packing. That is a Phase 3 GUI-protocol change: design writeup → user review → upstream design issue referencing qubes-issues #1861, *before* code. Triggered by experiment 2 or D2.
2. **Grant-lifecycle change (A6).** Moving the revoke/re-grant/re-dump sequence onto the steady-state resize path — and possibly gating revoke on `MSG_WINDOW_DUMP_ACK` for the screen window as `perwindow.c` already does for its own buffers — is Phase 3 work. Short design note first.
3. **A dom0-side resize harness.** `tools/qtest` cannot move or resize the qube's X window. D5's acceptance is unreachable without either a new dom0 qrexec service (a dom0 change — CLAUDE.md forbids attempting it) or the user manually resizing for each round. **This is a blocking dependency on the user, and it should be resolved before D4, not discovered at D5.**
4. **Disabling the Basic Display Adapter** to reach the decisive configuration risks a headless guest. The PnP auto-revert must be proven first (experiment 7), but the user should be told before the first attempt, and a VM reinstall is a user-escalation event.
5. **The T2 acceptance criterion itself**, if D3 comes back negative: "follows to within N px" instead of exact. Re-agree before building D4's negative branch.

**Genuinely unknown, listed so nobody reasons them away:**

- Whether an IDD-backed desktop keeps `DesktopImageInSystemMemory` TRUE. Undocumented in both directions. §2.3 is a hypothesis.
- Whether Desktop Duplication works on an IDD output at all on this guest. Third-party projects (OBS, Sunshine) capture IddCx displays, but that is GPU-equipped hardware and is not evidence about the flag.
- Whether the OS re-invokes the monitor-mode callbacks after `IddCxMonitorUpdateModes`. Undocumented; the one public report says no. D3.
- Whether `EnumDisplaySettingsEx` enumerates modes for an **inactive** IDD monitor (decides whether D3 needs the BDA disabled).
- Whether `IddCxSwapChainInSystemMemory` / `…ReleaseAndAcquireSystemBuffer` are callable on 19045. The version table says IddCx 1.5; the DDI pages list a Server 2022 minimum with a blank client field. Runtime-probe with `IDD_IS_FUNCTION_AVAILABLE` before any design depends on it.
- Whether `WUDFHost` can open xeniface and issue gnttab IOCTLs. Load-bearing only for B2 (which §5 deprioritises), unverified either way.
- Whether the OS imposes width alignment on IddCx surfaces (2566 is even but not a multiple of 4).
- Whether the sample's `FillSignalInfo` (`Driver.cpp:82-99`, zero blanking, `pixelRate = VSync*W*H`) survives odd geometries. Probe two awkward sizes early rather than assuming.
- **Convergence/oscillation:** after the guest reports a new window-0 size, the daemon moveresizes its local window; if the dom0 WM adjusts it (decorations, screen edges, tiling), a fresh `MSG_CONFIGURE` comes back with no flow control on window 0. With exact-size support it should converge in one round trip; with snapping it can oscillate. Falsifiable, worth watching in D5, ideally under a tiling WM.
- **Multi-monitor is out of reach of the current protocol.** `msg_xconf` carries one bounding box; `MSG_CONFIGURE` one rectangle. If the driver ever exposes more than one monitor, a Windows `qubes.SetMonitorLayout` handler becomes mandatory. Keep the driver at one monitor.
- Whether the qube sets the `no-monitor-layout` feature (needs `qvm-features`, outside my permitted actions). Cosmetic today; log noise.
- The 4-vCPU question (#10932/#10427) is untouched. If seamless artefacts confound anything, ask the user before changing it.
- Guest configuration hygiene: the guest currently runs agent `6b5b298` (explicitly unvalidated) with `PerWindowCapture=0` — a value already retracted as a test leftover, not a shipped default — plus a hand-set `LogLevel` and a detached netvm. **Reset to a shipped configuration before experiment 0**, or every baseline is anchored to something no user has.

---

## 7. ORDERED EXPERIMENT LIST

Single-threaded, strictly sequential. "**COLD BOOT**" = full `qtest shutdown` + `start`; an in-place gui-agent restart parks the new agent at "Awaiting for a vchan client" with zero windows and is only recoverable by a qube restart (reproduced 2/2). Every A/B is ≥3 interleaved rounds with one cold boot per side. Verify the on-guest binary hash against the CI manifest before every run; missing data fails.

| # | Experiment | Precondition | Boots |
|---|---|---|---|
| **0** | **Reset + re-baseline.** Restore a shipped guest config (remove `PerWindowCapture` override, restore LogLevel, confirm agent build). Then 3× `ddaprobe` on the unchanged BDA config; all three must give `agent_capture_would_work: true`, `map_desktop_surface.ok: true`, `pitch == width*4`, `session_id: 1`. Existing baselines are from 19044 LTSC and do not apply to this retail 19045 guest. | none | 3 |
| **0b** | **Validate the instruments.** (a) Scratch ddaprobe with the flag test inverted → summary must flip and exit non-zero. (b) Decoded-pixel comparator must report *no change* on a deliberately static desktop and *change* under `activity-gen.ps1`. Neither is a VM-state change; fold into 0's boots. | 0 | 0 |
| **1** | **Free pitch probe.** `ChangeDisplaySettings` to **1400x1050** (in the BDA's 29-mode list; 5600 bytes = 32- but not 64-byte aligned) and run `ddaprobe`. Read `map_desktop_surface.pitch` vs `width*4`. Answers a large part of the stride killer with no driver, no BDA disable, no headless risk. *Partial:* a PASS here does not clear 2566 (10264 = 8-byte aligned). Expect window-0 churn from the mode change; use a dedicated boot. | 0 | 1 |
| **2** | **Pin the non-seamless configuration.** Put the guest in fullscreen mode, **COLD BOOT**, confirm it persists, confirm the dom0 window is WM-resizable in the user's setup, and confirm a drag produces a `MSG_CONFIGURE` stream (not a single button-release event). *Every T2 measurement lives here, and every measurement in this repo to date was seamless.* Needs the user (or the §6.3 harness). | 0 | 1 |
| **3** | **Land A0 (`modeprobe`) + A1 (snap logging).** Acceptance: modeprobe lists 29 modes incl. 1920x1080, excl. 1600x1000; agent logs `RESREQ/RESSNAP/SNAPPED/RESAPPLIED/RESSOURCE`. Control: exact-match request emits no `SNAPPED`. | 2 | 1 |
| **4** | **A2 (readback) A/B vs the #3 build.** Request an unsupported size; agent's `RESAPPLIED` vs modeprobe's independent `ENUM_CURRENT_SETTINGS`. Control **must fail on the #3 build** (they disagree) and agree on the A2 build. | 3 | 6 |
| **5** | **A3 (single source of truth).** Assertion comparing `g_Screen*`-derived vs `ctx->*`-derived page count on every dump, driven by a resolution change. Control: the assertion must **fire** on the #3/#4 build. If it never fires, report the race as untriggered rather than the fix as validated. | 4 | 4 |
| **6** | **A4 (preference/cache split) + A5 (ceiling) boot-path acceptance.** **COLD BOOT** with no registry values in non-seamless mode → modeprobe reads the honest snap of 1600x1000 and still does 60 s later. Control: the #3 build on the same cold boot lands on the `FullscreenWidth` cache. A5's control: ceiling accessor returns `none` when neither registry nor qubesdb source exists. | 5 | 6 |
| **7** | **Prove the PnP auto-revert — before anything is ever disabled.** Register the revert task; disable a **harmless** device; confirm the task re-enables it and the marker is written *and* the enable's return code is checked. Do **not** count the `SetDisplayConfig` half. | none (can run any time before 9) | 2 |
| **8** | **D0 driver: install, verify present-and-inactive.** One device node, one IDD monitor (report `monitor_count`), bounding box unchanged, decoded-pixel `qtest shot` equivalent to baseline. Control: `MONITOR_COUNT=3` scratch build **must** change the monitor count and/or bounding box — if it does not, Phase 1B's "inactive" reading is wrong and that is the finding. | 0, CI green | 4 |
| **9** | **THE GATING MEASUREMENT (§2.4).** IDD replaces the BDA. 3 interleaved runs (BDA control / IDD test / BDA control) with `activity-gen.ps1`, cold boot per side. Branch on the result per §2.4. | 7, 8 | 6 |
| **10** | **D2 virtual-mode sweep**, same configuration and boot as 9's test side where possible: 1600x1000, 2566x1022, 1234x777, 1400x1050 — accepted? `ENUM_CURRENT_SETTINGS`? pitch vs `width*4` **per size**? flag held? Control: the identical sweep on the BDA rejects all four. **If this passes, D3/D4 may be unnecessary — stop and report before building a mode store.** | 9 = Outcome A | 2 |
| **11** | **D3 `UpdateModes` spike** (throwaway build) — only if 10 says no. Control: a mode published at *arrival* must appear in `EnumDisplaySettingsEx`; if not, the probe is on the wrong device. | 10 | 2–4 |
| **12** | **D4 mechanism**, branched on 11. If 11 is negative, **return to the user with the dense-grid proposal before building.** | 11 | TBD |
| **13** | **A6 in-place recreate** — design note and user approval first (§6.2), then implement, then measure zero window-0 destroy/create across a resize. | 5, approval | 4 |
| **14** | **D5 end-to-end T2**, all six acceptance criteria including the fiducial correctness check. Requires the §6.3 dom0 resize capability. | 12, 13, §6.3 resolved | 6 |

Running total to the gating verdict (experiments 0–9): **~26 cold boots.** Everything past 9 is gated on its result and should be re-planned, not pre-committed.

**Two things to do first regardless of anything above:** experiment 0's config reset (otherwise every later number is anchored to a configuration no user has) and experiment 0b's instrument validation (otherwise no result counts).