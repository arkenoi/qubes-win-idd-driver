# KVM/Proxmox guest display path vs the Qubes GUI path - what decouples

Grounding rule: every claim carries a repo `file:line` read this session (paths in Sources) or a URL fetched this session. Third-party code is cited from the scratchpad clones/raw files listed in Sources with their commits. Anything else is marked INFERRED or UNKNOWN.

## 1. Scope and the apples-to-oranges caveat

Three corrections to the background facts, from source:

- **Fact #1 is stale on the shipped default.** `SeamlessNoScreenGrant` defaults ON (`main.c:146-170`): in seamless mode the staging buffer is filled but never granted and dom0 draws only from per-window grants; the whole-desktop grant survives only on `service.gui-fullscreen` guests (`main.c:10612-10616`). "Zero-copy" means one memcpy per dirty rect into a once-granted buffer, not zero copies (`capture.c:70-89`).
- Fact #2's hard-fail now lives at `capture.c:558-562`.
- The quoted numbers are the superseded 8 s-settle draft (`docs/BENCHMARKS.md:243-259`). The current 45 s-settle win10 row is idle 3.906→0.498, drag 29.035→16.225, scroll 41.010→2.649, typing 22.815→2.312 (`BENCHMARKS.md:110-118`). Unit: gui-agent process CPU inside a harness phase ÷ wall time, as % of one core (`tools/bench-phase-cpu.py:10-12`). It measures neither frame rate, nor latency, nor dom0 cost (`BENCHMARKS.md:205-215`).

What each stack solves: KVM/Proxmox presents ONE composed Windows framebuffer to a viewer; it has no seamless mode. Qubes presents each guest window as a bordered dom0 X window, so dom0 must be handed per-window geometry and pixels (`docs/PLAN-composition-layer.md:118-123`). Therefore:

- **Meaningful comparisons:** guest frame source (display-driver present callback vs Desktop Duplication), copies per dirty rect, dirty-rect fidelity, push vs poll at the consumer, buffer lifetime, resize mechanics. All are WDDM properties independent of the hypervisor.
- **Meaningless comparisons:** "KVM drag/scroll is faster" (drag 16.2 % core is seamless per-window work with no KVM counterpart); "SPICE sends fewer bytes" (we send zero pixel bytes: `msg_shmimage` is four ints, `qubes-gui-protocol.h:230-235`); Proxmox latency folklore (no fetched primary source measures viogpudo or qxl-dod present-to-pixel latency; the forum threads compare noVNC with RDP).

## 2. How the KVM guest display path works

**Driver class.** Both Windows drivers are display-only (KMDOD). DWM composes in software - Microsoft: BasicRender "can also be used on systems that don't have a render-capable driver installed (for example, display-only devices ...)" [MS-BDD] - and dxgkrnl calls `DxgkDdiPresentDisplayOnly` with a flat system-memory source plus `pMoves`/`pDirtyRect` [MS-PDO]. Nothing per-window reaches the driver.

**virtio-gpu (viogpudo).** `ExecutePresentDisplayOnly` BltBits every move and dirty rect from DWM's source into a driver-owned framebuffer, collapses all of them into ONE bounding rect (`FindUpdateRect`, whole screen if none), then queues one `TransferToHost2D` and one `ResFlush` (`viogpudo.cpp:2764-2772, 2881-2922`). Host: QEMU `iov_to_buf`-copies that box from guest pages into a host pixman image (`virtio-gpu.c:494-560`), then `resource_flush` updates the console (`:566`); the DisplaySurface aliases the host copy (`:778`). The Windows header defines no BLOB commands (`viogpu.h`, grep), so Windows never gets the udmabuf zero-copy path. Cursor is a 64x64 resource on a separate queue (`viogpudo.cpp:4030-4032`). Commands are unfenced; there is no vsync source.

**QXL (qxl-wddm-dod).** Per dirty rect the driver builds a `QXL_DRAW_COPY` and RtlCopyMemory's rows into ≤64 KiB chunks in the VRAM BAR (`QxlDod.cpp:4546-4562, 4715-4725`; `QxlDod.h:507`); moves become `QXL_COPY_BITS` (`:4038, 4526`). The copy is synchronous in the present callback; only the ring push is offloaded (`:4063-4074`). spice-server validates every guest pointer via memslots (`red-parse-qxl.cpp:145, 189`) and keeps raw pointers into guest bitmap memory (`:394`). Vsync is faked from a 200 ms timer (`QxlDod.cpp:25-26, 5310-5313`); `WaitForCmdRing` blocks untimed on a full 32-entry ring (`:5043`).

**std VGA** (Proxmox's default for Windows, `QemuServer.pm:3091-3099`; Qubes' stubdom uses the same QEMU `VGA`, `qubes-xen.xml`). No driver cooperation: QEMU dirty-logs VRAM pages (`vga.c:1486`), snapshots on a console timer (`:1696`) and reports FULL-WIDTH bands (`:1744, 1768`). The timer is 30 ms backing off to 3 s (`qemu-console.c:101-112`); VNC keeps a second framebuffer with its own 30 ms..3 s tick (`vnc.c:61-63, 3175`). A poll, not a push. Qubes' tool-less HVM path is exactly this scan with a grant-shared DisplaySurface (`stubdom-qubes-gui.c:88, 133, 668`), including a filter that drops 1-line updates "Windows send constantly" (`:413`).

**What the host trusts.** virtio-gpu 2D: ids, formats, rects, strides, page lists - bounds-checked, no drawing commands. QXL: a drawing language plus guest pointer graphs parsed and rasterised in the host; the CVE history attached to it is INFERRED from search summaries (pages not fetched).

## 3. How the Qubes path works today

**Guest.** A capture thread blocks in `AcquireNextFrame` on adapter 0's Desktop Duplication (`capture.c:118-227`); since 4.3.1 that adapter is our IddCx monitor, solo, on WARP, with `DesktopImageInSystemMemory` measured TRUE 6/6 cold boots (`findings/idd.md:12, :15`). Per frame: OS dirty rects, `MapDesktopSurface`, row memcpy of ONLY the dirty rects into a persistent page-aligned staging buffer (`capture.c:942-953`; cost "microseconds per MB", `:87-89`). Move rects are settled empty on 300/300 drag frames (`:1131-1133`). Zero-dirty frames are skipped (`:1318-1322`); otherwise the capture thread signals and BLOCKS until the main loop finishes (`:1324-1342`) - capture and processing are serialised.

Seamless: `ProcessNewFrame` walks visible windows; each has a read-only granted slab (`XENIFACE_GNTTAB_READONLY`, `capture.c:656-662`) announced once by `MSG_WINDOW_DUMP`. Pixel sources: sub-rect memcpy from the mirror (~121 µs/frame, `DESIGN-pure-per-window.md:126`), the WGC broker on 24H2+ (CopyResource→Map→memcpy, `wgcbroker.cpp:155-164`), or PrintWindow at 2.7-40 ms/call on win10 and up to 66.8 ms on win11 (`DESIGN-pure-per-window.md:185-187, 265-266`). Non-seamless: one `MSG_SHMIMAGE` per dirty rect for window 0 (`main.c:7852-7872`). Stock's cost was per-frame `EnumWindows` at 97.5 % of frame time (`instrumentation/PHASE1A-RESULT.md:13, 28`); the DDA source itself acquires in 5.3 ms median with an 8 ms timeout (`:78`).

**Wire.** `MSG_SHMIMAGE` = {x,y,w,h} (`qubes-gui-protocol.h:230-235`); `MSG_WINDOW_DUMP` = header + one grant ref per page (`:309-328`); cursor = one whitelisted X glyph id (`:105-108`), which the Windows agent never sends (grep `MSG_CURSOR` in `agent/gui-agent/*.c`: 0 hits). No pixels cross; the daemon has no throttle (`DESIGN-pure-per-window.md:141`).

**dom0.** gui-daemon maps each ref with `IOCTL_GNTDEV_MAP_GRANT_REF` and attaches the fd to Xorg (`xside.c:3671-3687`); shmoverride accepts only `PROT_READ|MAP_SHARED` (`shmoverride.c:184`). Each rect is clamped (`xside.c:2258-2264, 2292-2301`) and becomes ONE `xcb_shm_put_image` (`xside.h:316`; blit `xside.c:2452-2462`). No screen window is required (`xside.c:733`). Wrong lengths or unknown types exit (`xside.c:3731, 3928-3970`).

**IDD.** The driver acquires every DWM frame and releases it unprocessed - `TODO: Process the frame here` (`Driver.cpp:636-692`) - and contains zero grant/xeniface code (grep: 0 hits). Built against IddCx 1.6, minimum 1.4 (`IddSampleDriver.vcxproj:139`). Every novel size needs an IOCTL replug that tears down duplication; `IddCxMonitorUpdateModes` was tried and reverted (`findings/idd.md:17, :23`). At 60 Hz the agent's whole per-frame cost was 114 µs of a 16.9 ms frame (`Driver.cpp:111-115`, 2026-08-16 comment).

## 4. Where the time goes, side by side

| Per-frame step | KVM DOD path (viogpudo / qxl-dod) | Qubes today | Qubes IDD-fed (Track B stage 3) |
|---|---|---|---|
| Composition | WARP, software [MS-BDD] | WARP, software (IDD solo, `findings/idd.md:15`) | same |
| Frame source | Present callback, synchronous (`viogpudo.cpp:2827`; `QxlDod.cpp:4074`) | DDA `AcquireNextFrame`, 5.3 ms median acquire (`PHASE1A-RESULT.md:78`); frame held until main loop done (`capture.c:1324-1342`) | Swapchain acquire on driver thread (`Driver.cpp:636`) |
| Dirty metadata | DWM rects; viogpudo collapses to 1 box (`:2892`); QXL keeps rects | OS rects kept (`capture.c`) | `IDDCX_METADATA` rects [MS-META]; moves always 0 |
| Guest pixel copies | 1 per rect (BltBits / RtlCopyMemory to VRAM) | 1 per rect into staging; +1 per window slab in seamless (`DESIGN:126`) | 1 per rect if `IddCxSwapChainInSystemMemory` TRUE [MS-1.6]; else CopyResource+Map = +1. UNKNOWN |
| Host pixel copies | virtio: `iov_to_buf` of the box (`virtio-gpu.c:553`); QXL: lazy rasterise | Xorg ShmPutImage of the exact rect (`xside.h:316`), unmeasured | same |
| Consumer wake | virtqueue kick → BH; viewers poll 30 ms..3 s (`qemu-console.c:112`, `vnc.c:61-63`) | evtchn push, no poll | same |
| Buffer sharing | attach-backing once per mode / VRAM alloc per drawable | once per process (staging), once per window (slab) | once per swapchain; owner outlives the agent |
| Cursor | separate plane (`viogpudo.cpp:4030`) | dom0's own cursor; no shape hint | same |
| Mode change | escape/config-interrupt + connect-only hot-plug, no replug (`docs/RESEARCH-hypervisor-resize.md:30-41`) | IOCTL replug + DDA teardown (`findings/idd.md:23`) | same limitation (IddCx) |
| Seamless per-window | n/a | slice / WGC / PrintWindow (2.7-66.8 ms) | unchanged |

Structurally the DOD path has one MORE full copy (the host copies from guest pages because the device model does not scan out from them) and LESS rect fidelity (viogpudo's bounding box). No fetched source measures end-to-end latency on either side.

## 5. Advantages that decouple from KVM

Ranked by grounded payoff.

**1. IDD as frame source and long-lived grant owner** (the KMDOD/RdpIdd lesson; RdpIdd.dll is "Rdp Indirect Display", a UMDF driver [STRONTIC], and IddCx 1.4 added remote-session IDDs [MS-VER]). *Mechanism:* consume `IDDCX_METADATA.DirtyRectCount` via `IddCxSwapChainGetDirtyRects`, treat one all-zero rect as no-update, ignore `MoveRegionCount` (always zero since 1.7) [MS-META]; on WARP use `IddCxSwapChainInSystemMemory` + `IddCxSwapChainReleaseAndAcquireSystemBuffer` for a pointer+pitch "avoiding a subresource copy", variant chosen once per swapchain, mixing bugchecks the UMDF host [MS-1.6]. *Cost it reduces:* NOT a bench number (capture-side cost is ~114 µs + ~121 µs per 16.9 ms frame). It reduces lifecycle costs: the 7200-page staging grant per agent start, never reclaimed (`findings/capture.md:27`) - now only on fullscreen-enabled guests; the per-novel-size duplication recreate (0x887a0026 +2 per resize, `findings/idd.md:23`; recovered in place, `findings/capture.md:31`); and the `DesktopImageInSystemMemory` dependency (`capture.c:558`). *Trust:* clean - dom0 still gets read-only grants + clamped rects; the agent stays the sole vchan writer. *Qubes-native form:* driver-owned page-aligned buffer, rects + buffer handed to the agent over a shared section (the broker seqlock precedent, `wgcbroker.cpp`).

**2. `IDDCX_ADAPTER_FLAGS_PREFER_PRECISE_PRESENT_REGIONS`** (IddCx 1.8, Win11) [MS-1.8]. *Reduces:* dirty AREA per frame → the mirror memcpy, the FrameRedundant hash over ≤1.5 Mpx (`main.c:7570`), and Xorg's w·h·4 copy. Ceiling is small: win11 is already indistinguishable from stock (`BENCHMARKS.md:88-108`). *Trust:* none. *Form:* one flag, runtime-gated on IddCx ≥1.8.

**3. One damage notification per present, per window** (the viogpudo lesson minus its bounding-box collapse): the latest-wins ~16 ms per-window pacer already proposed (`DESIGN-pure-per-window.md:140-143`). *Reduces:* `MSG_SHMIMAGE`→PutImage count; dom0 throughput is UNVERIFIED (`DESIGN:78`). *Trust:* none (guest-side choice; rects still clamped). *Form:* agent-side coalescing.

**4. `MSG_CURSOR` shape hint.** The only cursor-plane item that survives the trust gate: dom0 whitelists a glyph id and uses its own cursors (`qubes-gui-protocol.h:105-108`). *Reduces:* nothing measured - a UX gap (guest I-beam/resize cursors never reach dom0). *Trust:* none. *Form:* map guest HCURSOR class to `CURSOR_X11 + XC_*`, as the Linux agent does.

## 6. Advantages that do not decouple

- **Host executes a drawing language** (QXL/SPICE: drawables, pointer chains, rasteriser, in-place bitmap pointers `red-parse-qxl.cpp:394`). Needs dom0 to trust guest commands; gui-daemon has no extension point and exits on unknown types (`xside.c:3928`). Killed.
- **Host maps/pointer-chases guest device memory; host renders INTO guest memory** (QEMU BARs, spice canvas). Dom0 maps only validated refs, read-only (`xside.c:3671`; `shmoverride.c:184`). Killed.
- **virtio resource/offset command model** (`TransferToHost2D(resid, offset, ...)`, `viogpudo.cpp:2916`). The rect half already IS `MSG_SHMIMAGE`; a guest-chosen offset interpreted in dom0 is a parsing surface. Killed.
- **Blob/udmabuf/GL zero-copy scanout.** Needs a QEMU device model with guest RAM plus GL in the trusted process; Windows has no blob support anyway. Killed.
- **Guest bitmap cursor** (virtio `UPDATE_CURSOR`, QXL `CURSOR_SET`, IddCx hardware-cursor DDI). Requires a new message dom0 parses → Phase 3 design-first. Killed as pixels.
- **Device-tells-host geometry.** Dom0 dictates geometry and re-asserts its own configure; host→guest push with agent-applies is already Phase 2B-resize. Killed as a direction.
- **No-replug mode injection via raw DXGK verbs** (`DxgkCbIndicateChildStatus`, `docs/RESEARCH-hypervisor-resize.md:30-41`). IddCx hides them; the only console-legal verb was tried and reverted (`findings/idd.md:23, :32`). Not a Xen limit, but not reachable from an IDD.
- **Codecs, image caches, stream detection, VNC/SPICE servers.** They buy network bytes; we move none, and they add the polling stages Proxmox users complain about.

## 6b. Would adding an RDP path speed anything up?

**What RDP does per window.** RAIL (MS-RDPERP) sends window orders - owner/style/showstate, window and client rects, `VisibilityRects`, z-order - and a local move/resize protocol where the client's window manager owns the drag [MS-RAIL, MS-RAIL-MOVE]. Enhanced RemoteApp (RDP 8.1) maps one MS-RDPEGFX surface per window so the client "will always have access to the complete contents of a RAIL window, even if the window is obscured on the server" and the background is not remoted [MS-ERA]; updates are per-rect `WireToSurface` PDUs with a codec tag [MS-EGFX]. Our equivalents: `MSG_CONFIGURE` from `SetWinEventHook` + dom0-owned placement + the drag latch; per-window slabs + `MSG_WINDOW_DUMP`; `MSG_SHMIMAGE` with codec "none" and zero pixel bytes. Occlusion-independent content exists via the WGC broker on 24H2+ for app/NRB windows; shell CoreWindows refuse `CreateForWindow` (`findings/capture.md:19`). Whether RDP's per-window source is the same DWM redirection surface is INFERRED, undocumented. No public API exposes it without an RDP session: RDPSRAPI "uses the Desktop Duplication API" [MS-WDS]; DVCs ride a session [MS-DVC]; `IWRdsWddmIddProps` binds a protocol stack to a remote-session IDD, server SKUs only [MS-WDDMIDD].

**Shape A - RDP server feeding dom0.** Trust: dom0 parses a guest-authored surface/codec stream - the QXL-class surface. KILLED.

**Shape B - RDP decoded in a disposable proxy qube feeding the grant path.** Trust: neutral (dom0 still maps the proxy's read-only grants). Speed: NO - a strict superset. RDP's frame source is itself an IddCx swapchain frame (RdpIdd); Shape B adds an RDP stack, an encoder, pixel bytes over a vchan (today zero), a decoder, a second grant and a second PutImage on top of a path whose guest cost is one dirty-rect memcpy plus ~114 µs. It also requires a REMOTE session: a remote IDD is per session and its devnode is destroyed on disconnect [MS-1.4R], so the remoted session is not the console session where the agent, broker and toasts live. RDP-server availability on the owner's images is UNKNOWN and irrelevant.

**Shape C - borrow only the per-window mechanism.** This IS the shipped architecture (per-window grants, geometry metadata, WGC broker, no desktop grant). RDP adds nothing reachable.

**Shape D - the RdpIdd lesson.** Make our IddCx driver the frame source (section 5 item 1). Trust: clean. Speed: moves no bench number; buys lifecycle and robustness.

**Plain verdict:** no. RDP begins with the same IddCx frame we already have and adds stages after it.

**The one measurement that overturns it:** join `IDDCX_METADATA.PresentDisplayQPCTime` (driver) with `AcquireNextFrame`-return QPC / `signal_qpc` (`capture.c:1325`) per `PresentationFrameNumber` during the drag-harness phases. If the DDA hop - including the frame hold at `capture.c:1324-1342` - is consistently ≥ one frame period (16.9 ms) or drops presents, Shape D becomes a latency win, not only a lifecycle one. Input-to-pixel latency has never been measured on this rig (`BENCHMARKS.md:205-215`).

## 7. Implementation prompts

```text
PROMPT: IDD as frame source and grant owner (Track B stage 3) - INSTRUMENT FIRST
Goal: decide, from measurements, whether the IddCx driver should replace DDA as the
frame source; then implement only if the numbers say so.
Files: driver/IddSampleDriver/Driver.cpp (SwapChainProcessor::RunCore, :629-697;
EvtIddCxMonitorAssignSwapChain), IddSampleDriver.vcxproj:139 (IDDCX_VERSION 1.6);
agent/gui-agent/capture.c (StagingCopyFrame :936-1002, frame hold :1324-1342),
agent/gui-agent/perf.c:638 (QGAPERF dr=/area=).
Step 1 (instrument-only build): in AssignSwapChain log IddCxSwapChainInSystemMemory;
per acquired frame log PresentationFrameNumber, DirtyRectCount, summed rect area,
PresentDisplayQPCTime. Do not change the acquire variant yet.
Step 2 (only if InSystemMemory TRUE and the DDA-hop >= 16.9 ms): switch that swapchain to
IddCxSwapChainReleaseAndAcquireSystemBuffer (chosen once per swapchain - mixing variants
bugchecks WUDFHost, MS 1.6 doc), memcpy dirty rects into a driver-owned page-aligned
buffer, publish rects via a shared section (wgcbroker.cpp seqlock precedent); the agent
grants/sends. Probe whether WUDFHost can open xeniface before designing driver-side grants.
Protocol/dom0 changes: none. The agent remains the only vchan writer.
Acceptance: tools/bench-stock-vs-ours.sh, 3 interleaved rounds per side, all four phases
within stock-vs-ours disjointness on the current 45 s row (idle 0.498, drag 16.225,
scroll 2.649, typing 2.312 % core) - no phase may regress out of range; plus 10 scripted
resizes with zero 0x887a0026 events and zero grant growth across 5 agent restarts.
Risks: InSystemMemory FALSE => one extra copy (regression); swapchain reassignment on
every mode change; a second frame source desynchronising the DDA oracle during transition.
Do NOT: set IDDCX_ADAPTER_FLAGS_REMOTE_SESSION_DRIVER; touch dom0; ship before the two
measurements in section 8 exist.
```

```text
PROMPT: PREFER_PRECISE_PRESENT_REGIONS on Win11
Goal: measure whether finer OS dirty rects reduce per-frame dirty area on win11-app.
Files: driver/IddSampleDriver/Driver.cpp (adapter caps in the init path); gate on
IddCxGetVersion >= 0x1800 (Win10 19045 stops at 1.5).
Protocol/dom0: none.
Acceptance: QGAPERF dr=/area= over the scroll and typing phases, 3 interleaved rounds
flag on/off; report only if ranges are disjoint. Bench phases must not regress.
Risks: the flag may shape only the IDD's own list, not DDA's; "small CPU overhead".
Do NOT: claim a gain from a single run; enable on 19045 (flag unknown to IddCx 1.5).
```

```text
PROMPT: per-window damage pacing (latest-wins tick)
Goal: bound MSG_SHMIMAGE count per window per frame without coarsening rects into a
bounding box (viogpudo's FindUpdateRect is the anti-pattern).
Files: agent/gui-agent/main.c (per-window damage send sites; PwSliceCopyAndDamageSrc
:6877-6924), agent/gui-agent/send.c (SendWindowDamageEvent :950-1040).
Protocol/dom0: none; dom0 clamps any rect (xside.c:2258-2301).
Acceptance: sends= per frame in QGAPERF falls; bench phases stay in range; visual check
that carets/underlines (1-px damage) still render (coalesce, never drop).
Risks: up to one tick of added latency; more bytes copied in Xorg if rects merge badly.
Do NOT: measure dom0 effect without a dom0 probe (owner-run) - report guest-side only.
```

```text
PROMPT: MSG_CURSOR shape hint from the Windows agent
Goal: send the whitelisted X glyph id for the guest's current cursor class.
Files: agent/gui-agent/send.c (new send), main.c (WM_SETCURSOR/GetCursorInfo tracking);
reference: upstream/ro/qubes-gui-agent-linux/gui-agent/vmside.c cursor handling.
Protocol/dom0: none - msg_cursor exists (qubes-gui-protocol.h:105-108, 317-320).
Acceptance: qtest shot shows I-beam over a Notepad client area and arrow over chrome;
no bench phase regresses. Not a performance item.
Do NOT: send pixels; send outside CURSOR_DEFAULT / CURSOR_X11..CURSOR_X11_MAX (VERIFY exits).
```

## 8. Measurements to take first

1. **`IddCxSwapChainInSystemMemory` on our IDD-solo 19045 guest** - UNKNOWN; never called (grep). Decides copy count for item 1. Instrument-only CI build, one quick-upgrade cycle.
2. **DDA-hop latency** - UNKNOWN. Join driver `PresentDisplayQPCTime` with `signal_qpc` (`capture.c:1325`) per frame during drag/scroll. THE number for the RDP/IDD decision.
3. **IDD rect fidelity vs DDA rects** - INFERRED equal. Log DirtyRectCount/area in the driver, diff against QGAPERF dr=/area= for the same run.
4. **dom0 ShmPutImage cost / blit throughput** - UNVERIFIED (`DESIGN-pure-per-window.md:78`). Needs an owner-run dom0 probe; escalate.
5. **WUDFHost can open xeniface and hold a grant** - UNKNOWN. One-page probe build.
6. **1-line spurious updates in the DDA stream** (the stubdom filter's premise, `stubdom-qubes-gui.c:413`) - UNKNOWN. Histogram of dirty-rect heights from QGAPERF over an idle window.
7. **Any "KVM is faster" claim** - UNGROUNDED in every fetched primary source; not measurable on this rig and structurally moot.

## Addenda - owner Q&A, 2026-09-16

Three follow-up questions, answered from the material above. Claims that rest on the sections above cite them; reasoning of my own is marked INFERRED.

### A. Is RemoteApp's seamless mode "display-per-app"?

No. It is **surface-per-window on top of ONE session display**. There is exactly one remote session with one virtual monitor (the `RdpIdd` IddCx display, §2/§6b), and DWM composes that session's desktop on it like any other. RAIL adds, on top of the composed session:

- **Classic RAIL** (pre-8.1): window orders (owner, style, show-state, window/client rects, `VisibilityRects`, z-order) plus the pixels of each window's *visible* region [MS-RDPERP, §6b]. Occluded parts are not available - a sliced composed desktop, which is what our Win10 path does (mirror sub-rect / `PrintWindow`, §3).
- **Enhanced RemoteApp** (RDP 8.1+): one MS-RDPEGFX surface per RAIL window, and the client "will always have access to the complete contents of a RAIL window, even if the window is obscured on the server"; the desktop background is not remoted [MS-ERA, §6b]. That behaviour requires an occlusion-independent per-window source. INFERRED, undocumented: DWM's per-window redirection surface - the same buffer `WGC CreateForWindow` captures - which is what our 24H2+ broker path uses (§3).

"Display-per-app" - one IddCx monitor per application, each app maximised on its own virtual monitor - is a different design that neither RDP nor we use. An IDD can expose several monitors, but DWM would then compose N desktops, and application semantics break: multi-window apps, dialogs and menus positioned relative to a parent, cross-window drag, monitor-aware layout. RAIL keeps one desktop and remotes windows *out of* it; our seamless model matches RAIL's, not the per-monitor one. (INFERRED as to cost; the semantics point follows from RAIL's own window-order model.)

### B. Have we already borrowed everything good from it?

At the mechanism level, yes - borrowed or native (§3, §6b): per-window surfaces (WGC broker → per-window slabs), geometry/z-order/show-state as validated metadata (`MSG_CONFIGURE` from `SetWinEventHook`), the client owning the drag (dom0-owned placement + the drag latch = RAIL's local move/resize handshake), the desktop background not remoted (`SeamlessNoScreenGrant` on by default, `main.c:146-170`), and zero pixel bytes on the wire (`MSG_SHMIMAGE` = four ints, `qubes-gui-protocol.h:230-235`) - which RDP cannot match, since it must encode.

Three things are not borrowed; only one of them is borrowable:

1. **Frame source at the driver.** RDP's frames come out of the `RdpIdd` swapchain with DWM's dirty rects. Ours come out of Desktop Duplication running on top of our IDD's monitor - an extra hop with an 8 ms acquire timeout (`instrumentation/PHASE1A-RESULT.md:78`) and the capture-thread frame hold (`capture.c:1324-1342`). §5 item 1; rated a lifecycle win, latency unproven (§8).
2. **Occlusion-independent per-window content on Windows 10.** Enhanced RemoteApp gets full window contents on any supported Windows through the RDS pipeline's internal reach into the composition surface; we have it only on 24H2+ (WGC). On Win10 we slice the composed mirror or call `PrintWindow` (2.7-40 ms/call, §3). This is privileged access to a primitive, not a design idea - the one RDP advantage that cannot be borrowed, and it is Win10-only.
3. **Per-window damage pacing.** EGFX paces per-surface updates through its encoder; we send one `MSG_SHMIMAGE` per dirty rect with no throttle (`DESIGN-pure-per-window.md:141`). The latest-wins ~16 ms per-window pacer (§5 item 3) is proposed, not built.

### C. "vchan feedback loops are slow - move closer to 'guest sends, dom0 handles'?"

Partly, and the "or not" half matters: the loop being described mostly does not exist.

**Damage is already fire-and-forget.** `MSG_SHMIMAGE` carries no ack and no readiness signal, and the daemon has no throttle (`DESIGN-pure-per-window.md:141`): it maps the grant read-only and does one `xcb_shm_put_image` per rect (`xside.h:316`, `xside.c:2452-2462`). There is no damage feedback on vchan to remove. The exposure runs the other way - an unthrottled push can flood dom0 with PutImages - which is why the pacer is the open item, not a leaner loop.

**The vchan feedback loop that does exist is `MSG_CONFIGURE`, and it has already bitten us this way.** dom0 owns placement by design, so during a drag the daemon's configure stream feeds back into the agent. The recorded drag-lag root cause (drag-replay work, 2026-08-12) was "daemon configure stream + async apply + coordinate seam", and the fix - the drag latch - made the guest stop reacting to that feedback mid-drag. So the intuition is right about that loop; it is per geometry change, not per frame, and it was cut where it hurt.

**The serialisation that remains is not on vchan.** Inside the guest: the capture thread signals the main loop and BLOCKS until processing finishes (`capture.c:1324-1342`), and Desktop Duplication is a hop with an 8 ms acquire timeout on top of DWM's 16.9 ms frame. Inside dom0: X compositing. A free-running capture into a ring of granted staging buffers would remove the guest-side hold; the IDD as frame source would remove the DDA hop (§5 item 1). Both are guest-internal. Whether they buy latency rather than lifecycle is UNKNOWN, because -

**- the premise is unmeasured.** Input-to-pixel latency has never been measured on this rig (`docs/BENCHMARKS.md:205-215`); the numbers we have are gui-agent CPU share (`tools/bench-phase-cpu.py:10-12`), which says nothing about where a frame waits.

**The instrument (do this before any protocol change):** QPC stamps at input injection → DWM present (`IDDCX_METADATA.PresentDisplayQPCTime`, driver) → `AcquireNextFrame` return (`capture.c:1325`, `signal_qpc`) → `MSG_SHMIMAGE` sent → dom0 receive → PutImage complete, joined per `PresentationFrameNumber` during the existing drag-harness phases. That partitions latency into guest render / capture hop / vchan / dom0 and says whether vchan is even in the top three. Decision rule: if the capture hop (DDA acquire + the hold) is consistently ≥ one frame period (16.9 ms) or drops presents, §5 item 1 becomes a latency win and the free-running ring is worth building; if vchan itself is a small, flat term, "guest sends, dom0 handles" is already what we have and the remaining work is guest-internal.

## Sources

Repo (`/home/user/qubes-win-idd-driver/`): `agent/gui-agent/capture.c`, `main.c`, `perf.c`, `send.c`, `vchan-handlers.c`; `driver/IddSampleDriver/Driver.cpp`, `IddSampleDriver.vcxproj`; `tools/bench-stock-vs-ours.sh`, `tools/bench-phase-cpu.py`, `tools/wgcbroker/wgcbroker.cpp`; `docs/BENCHMARKS.md`, `docs/PLAN-composition-layer.md`, `docs/RESEARCH-hypervisor-resize.md`; `DESIGN-pure-per-window.md`; `findings/capture.md`, `findings/idd.md`; `instrumentation/PHASE1A-RESULT.md`; `upstream/ro/qubes-gui-daemon/gui-daemon/xside.c`, `xside.h`, `shmoverride/shmoverride.c` (mirror f66fb34c); `upstream/ro/qubes-gui-common/include/qubes-gui-protocol.h`.

Scratchpad clones/raw files (`/tmp/claude-1000/-home-user-qubes-win-idd-driver/cd301cec-161c-4daf-b158-c0a507363c0c/scratchpad/src/`): `qxl-wddm-dod/` (gitlab.freedesktop.org/spice/win32/qxl-wddm-dod @ 459536ec), `spice/` (@ 91d42c4d), `viogpudo.cpp`, `viogpu.h` (virtio-win/kvm-guest-drivers-windows master), `virtio-gpu.c`, `vga.c`, `vnc.c`, `qemu-console.c` (qemu master), `QemuServer.pm` (proxmox/qemu-server master), `stubdom-qubes-gui.c` (QubesOS/qubes-gui-agent-xen-hvm-stubdom), `qubes-xen.xml` (QubesOS/qubes-core-admin).

Fetched this session:
- [MS-1.6] https://learn.microsoft.com/en-us/windows-hardware/drivers/display/iddcx1.6-updates
- [MS-META] https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/iddcx/ns-iddcx-iddcx_metadata

Fetched by the research inputs (URLs as recorded there):
- [MS-BDD] https://learn.microsoft.com/en-us/windows-hardware/drivers/display/microsoft-basic-display-driver
- [MS-PDO] https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/d3dkmddi/ns-d3dkmddi-_dxgkarg_present_displayonly
- [MS-VER] https://learn.microsoft.com/en-us/windows-hardware/drivers/display/iddcx-versions
- [MS-1.4R] https://learn.microsoft.com/en-us/windows-hardware/drivers/display/iddcx1.4-updates-for-remote-idds
- [MS-1.8] https://learn.microsoft.com/en-us/windows-hardware/drivers/display/iddcx1.8-updates
- [MS-WDDMIDD] https://learn.microsoft.com/en-us/windows/win32/api/wtsprotocol/nn-wtsprotocol-iwrdswddmiddprops
- [MS-RAIL] https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdperp/485e6f6d-2401-4a9c-9330-46454f0c5aba
- [MS-RAIL-MOVE] https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdperp/348a2e91-3ea5-415d-ad67-348d96c3f1bd
- [MS-ERA] https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdperp/ead02bce-64ef-41d6-aa06-8565956b9fe7
- [MS-EGFX] https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-rdpegfx/fb919fce-cc97-4d2b-8cf5-a737a00ef1a6
- [MS-WDS] https://learn.microsoft.com/en-us/previous-versions/windows/desktop/rdp/about-windows-desktop-sharing
- [MS-DVC] https://learn.microsoft.com/en-us/windows/win32/termserv/dynamic-virtual-channels
- [STRONTIC] https://strontic.github.io/xcyclopedia/library/RdpIdd.dll-C71035EC60C7BFA3FF9C6FFCF79293A9.html
