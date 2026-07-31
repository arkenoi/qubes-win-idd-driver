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

---

# Update 2026-07-31: the fix was incomplete in two ways, both found by rendering checks

Verifying "windows stayed mapped" was necessary but **not sufficient**. Two further defects
survived that check, because in both the windows *did* stay mapped - only their contents were
wrong. Neither is visible in the agent log alone.

## Defect 1: recovery could not succeed after a desktop switch

`DuplicateOutput()` returns `E_ACCESSDENIED` (0x80070005) when the calling thread is not on the
current input desktop - which is exactly the state a desktop switch leaves the capture thread
in, and a desktop switch is a primary cause of `ACCESS_LOST` in the first place. So the retry
loop could not possibly succeed after that trigger:

```
GetDuplication: output->DuplicateOutput() failed with error 0x80070005: Access is denied.  (x20)
RecreateDuplication: failed to recreate duplication after 20 attempts
CaptureThread: duplication lost and could not be recreated, reinitializing
SendWindowUnmap: Unmapping window 0x0
```

The fallback teardown then ran - the exact outcome the in-place recovery exists to prevent.
Every dom0 window image went uniformly black (`std = 0.0`, pure `[0,0,0]`).

Fixed by re-attaching the capture thread to the input desktop before **every** attempt (the
switch may still be in progress on the first). Only the per-thread part of
`AttachToInputDesktop()` is used, for the reasons already documented at the hook thread.

Recovery went from *"after 13 attempt(s)"* (when it worked at all) to **"after 1 attempt(s)"**,
deterministically.

### Why the earlier "verified" result did not catch this

The earlier runs happened to switch back before the retry budget ran out, so recovery
succeeded and the log looked right. The bug was **timing-dependent**, and a log-only check
could not see it. "13 attempts" should itself have been a warning: a healthy recreate takes 1.

## Defect 2: contents froze permanently after a successful recovery

Even once recovery succeeded, dom0's window images stopped updating **forever**.

The desktop surface belongs to the duplication object. `RecreateDuplication` replaced the
duplication but kept `grant_refs`, and `GetFrame` only maps and grants when `grant_refs` is
NULL. So the agent never looked at the new surface and the daemon kept reading the pages of
the duplication that had been torn down - windows mapped, correctly positioned, contents
frozen at the instant of the loss.

Measured decisively: dom0's window PNG was **byte-identical (same md5)** across two captures
minutes apart with typing in between, while the guest's own screenshot changed.

Fixed by revoking and clearing the grant on recreate, letting `GetFrame` re-map and re-grant,
re-sending `MSG_WINDOW_DUMP` **before** any damage for that frame (damage referring to pages
the daemon has not mapped yet would be painted from stale memory), and then forcing a full
repaint - every window the daemon holds came from the old framebuffer, and an idle one would
otherwise stay frozen indefinitely.

Verified: dom0 images now change across the trigger, and match the guest to a mean absolute
difference of 0.0-1.7 out of 255.

## Lesson

This is the same failure of imagination twice: I verified the thing I had set out to fix
(windows are not unmapped) and treated that as the feature working. Both real defects lived in
the gap between "the window object survived" and "the user can see the right pixels". A
recovery path must be judged on **output**, not on its own log line.
