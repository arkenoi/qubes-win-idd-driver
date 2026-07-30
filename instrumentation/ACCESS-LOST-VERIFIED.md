# Goal item (b) VERIFIED: ACCESS_LOST recovers in place, no window unmapping

Trigger used: a forced desktop switch inside the guest (`CreateDesktop` + `SwitchDesktop`
away and back) — a documented `DXGI_ERROR_ACCESS_LOST` cause, and the same class of event as
a resolution change. Run on win-idd-test with the instrumented Phase 2A agent.

## Before the fix (stock handling)
```
ReleaseFrame: duplication->ReleaseFrame failed with error 0x887a0026
SendWindowUnmap: 0x0
SendWindowUnmap: 0x0
SendWindowUnmap: 0x500f6      <- every window torn down
```
`unmaps=6`, `recovered=0`. In dom0 this is the qube's windows vanishing and reappearing.

## After the fix
```
GetFrame: initial GetFrameDirtyRects failed with error 0x887a0026
```
then, measured directly from the log after that line:
```
QGAPERF_after_error = 11      <- capture continued, 11 frames processed
unmaps_after_error  = 0       <- NO window teardown
agent_alive         = True
notepad_alive       = True    <- the mapped window survived
```

## What the verification changed about the fix

Two iterations were needed, both found by measuring rather than reasoning:

1. The first version only handled `AcquireNextFrame`. The live trigger showed the failure
   actually arriving from **`ReleaseFrame`** — by the time a desktop switch lands the agent
   is usually holding a frame, so the invalidation surfaces on release. The acquire-side
   recovery was unreachable in practice and the teardown still ran.
2. After fixing the release path, the next run showed the failure arriving from a **third**
   call site, `GetFrameDirtyRects`. `ACCESS_LOST` can surface from any duplication method,
   which is why it is now handled at the `GetFrame` and `ReleaseFrame` call sites (covering
   every API used inside them) rather than per-API.

Also: the recovery message was initially `LogDebug`, invisible at the guest's default
`LogLevel=3`, which made a working recovery look like a no-op (`recovered=0`). Promoted to
`LogInfo` so in-place recovery is distinguishable from a silent teardown.

## Residual
`RecreateDuplication` deliberately returns FALSE — falling back to the full reinit — when the
geometry actually changed, because the grants and the dom0-side window are sized for the old
framebuffer. That path is correct but has NOT been exercised here (the desktop switch keeps
the mode). It is the path a genuine dom0-window resize will hit, so Phase 2B-resize must
re-test it.
