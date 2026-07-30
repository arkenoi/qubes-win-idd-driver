# Phase 1B stage 1 — IDD coexistence: PASS (Outcome A)

Per CLAUDE.md, Phase 1B is **stage 1 only**: the IDD installed but IGNORED by QWT, with the
agent still duplicating the Basic Display Adapter. The design is explicit that the IDD
monitor must be **connected but INACTIVE** — an active second monitor enlarges the desktop
bounding box the agent maps as the screen, letting Windows place windows in a region dom0
never sees, which breaks seamless coordinates. So "no second DXGI output" is the *intended*
stage-1 state, not a shortfall.

Measured on win-idd-test (Win10 Enterprise LTSC 2021, 19044.1288), IddSampleDriver built and
test-signed by CI, installed elevated.

| Phase 1B question | result |
|---|---|
| Does the IDD driver install on this guest? | **Yes** — `Drivers installed successfully` (after two INF fixes, below) |
| Does it coexist with the Basic Display Adapter? | **Yes** — `Microsoft Basic Display Adapter` **OK** and `IddSampleDriver Device` **OK** simultaneously; two IDD nodes (`ROOT\DISPLAY\0000` from devcon, `SWD\IDDSAMPLEDRIVER\...` from IddSampleApp), both `CM_PROB_NONE`, both `Service: WUDFRd` |
| Did the UMDF driver actually load? | **Yes** — `WUDFHost.exe` running; `WudfRd` service went Stopped→**Running** |
| Which adapter stays primary? | **BDA** — `\\.\DISPLAY1` Primary, `(0,0)-(3440,1440)`, unchanged |
| Is the IDD inactive as stage 1 requires? | **Yes** — 1 DXGI output, desktop bounding box unchanged. (`DisplaySwitch /extend` was attempted before re-reading the staging rule; it was a no-op and the desktop stayed single-headed. Do NOT extend in stage 1.) |
| **`DesktopImageInSystemMemory` with the IDD present** | **TRUE** — `capture.c:176-183 verdict: PASS` |
| Does QWT keep streaming? | **Yes** — QdbDaemon / QrexecAgent / QubesGuiWatchdog all Running |
| Is seamless unchanged vs baseline? | **Yes** — `qtest shot` returns live windows; Notepad renders at 2566x1022, pixel-identical to the pre-IDD capture |

## Verdict: **Outcome A**

The IDD can slide under the existing capture path as incremental work. It does **not** need
its own grant path (no staging copy in the swapchain loop, no xeniface gnttab IOCTLs), which
was the "bigger project, flag to the user before starting" branch. Phase 2B proceeds as
planned.

## Two real defects had to be fixed to get here

Both diagnosed from guest evidence (`setupapi.dev.log`, PnP state), not guesswork:

1. **INF targeted Windows 11+.** `[Manufacturer]` decorated `NT$ARCH$.10.0...22000`, so the
   models section never matched 19044 and `pnputil` rejected the package. Retargeted to
   `10.0...19041` (covers Win10 2004..22H2).
2. **`0xe0000219` — "a function driver was not specified for this device instance"**, with
   `setupapi.dev.log` reporting *"No INF AddService directives contained the flag
   SPSVCINST_ASSOCSERVICE"*. Root cause: **Windows 10 Enterprise LTSC 2021 does not ship
   `C:\Windows\INF\WUDFRD.inf`** (only `wudfusbcciddriver.inf`), so the sample's
   `Include=WUDFRD.inf` / `Needs=WUDFRD.NT.Services` resolved to nothing. The `WudfRd`
   reflector *service* and `IddCx.dll` are both present, so the platform can host the driver
   — only the INF-side association was missing. Fixed by declaring it explicitly:
   `AddService=WUDFRd,0x000001fa,WUDFRD_ServiceInstall` plus a `[WUDFRD_ServiceInstall]`
   section. **Keep this for the QubesIDD rebrand in Phase 2B** — it is not sample-specific,
   it is required on any LTSC image.

Also: CI collected only `*.dll,*.inf,*.cat`, so `IddSampleApp.exe` never shipped. It is what
actually instantiates the software device (`SwDeviceCreate` on hardware id
`IddSampleDriver`, the INF's second models line). Now packaged.

## Finding that matters for stage 2: Windows REFUSES to extend onto the IDD

`DisplaySwitch.exe /extend` did not silently no-op — it opened the "Project" flyout, which
reported verbatim:

> **"Your PC can't project to another screen. Try reinstalling the driver or using a
> different video card."**

(Visible as a third captured window in the seamless screenshot; caught by the user reading
the shot, not by the console output, which said nothing.)

The Microsoft Basic Display Adapter is single-head: while BDA owns the desktop, Windows will
not build an extended display topology, so the IDD monitor cannot be attached via the normal
Project/`SetDisplayConfig(SDC_TOPOLOGY_EXTEND)` path. The IDD device itself is healthy
(`WUDFHost` loaded, `CM_PROB_NONE`), so this is a topology/primary-adapter constraint, not a
driver fault.

Consequence for **stage 2** (agent duplicates the IDD output instead of the BDA): it is not
simply "extend the desktop and re-point the agent". Either the IDD has to *replace* the BDA
as the desktop's display adapter (`SetDisplayConfig` with an explicit path, or disabling the
BDA), or the guest must run without the emulated adapter entirely. That question must be
answered before stage 2 is attempted — and note CLAUDE.md fact #2: taking the desktop off
the BDA is exactly what risks `DesktopImageInSystemMemory` going FALSE and killing capture.
Stage 1's PASS does **not** carry over to that configuration; it must be re-measured.

## Stage 2/3 (NOT Phase 1B, do not start without the plan)
- stage 2: agent duplicates the IDD output instead of the BDA.
- stage 3: IDD feeds frames directly, DDA drops out.
Both change which surface the agent captures and therefore need the seamless-coordinate
question settled first.
