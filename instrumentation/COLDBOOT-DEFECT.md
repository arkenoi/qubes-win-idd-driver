
---

# Root cause NOT the CloseDesktop violations

Both `CloseDesktop` contract violations have been removed:

* `a4a64a7` - capture.c, the handle `AttachCaptureThreadToInputDesktop` previously installed;
* `b01a146` - util.c, the handle from `GetThreadDesktop`, which MSDN says must never be closed
  and which two racing startup callers (`StartFrameProcessing`, `ResolutionChangeThread`) could
  close out from under each other.

The second is genuinely an upstream bug in stock QWT - `AttachToInputDesktop` is untouched
upstream code, and the existing comment at the hook thread already flagged the call as
MSDN-forbidden. It is worth keeping and worth upstreaming on its own merits.

**But it does not fix this defect.** With both removed, 5 cold boots (3 valid, 2 refused for a
failed install):

```
FAIL  EnumWindows_failures=8
PASS  EnumWindows_failures=0
PASS  EnumWindows_failures=0
```

1 in 3, unchanged from before the fixes. So the desktop-handle theory - which fit the signature
well (a race, cold boot only, cleared by restart) - is wrong, or at most one contributor among
several.

## What is left to examine

* `SetThreadDesktop` itself failing on one of the racing callers, leaving that thread on a
  desktop that is later torn down - the return value is checked, but the *loser* of the race
  is not distinguished from the winner in the log;
* the boot-time order: our agent reaches window enumeration earlier than stock, possibly before
  the interactive desktop is fully constructed, and `ERROR_INVALID_HANDLE` may be what
  `EnumWindows` reports for a desktop that exists but is not yet ready;
* whether the failure is permanent for the process once it starts, or self-clears - the log
  shows it repeating on every resync, but no run has been watched long enough to know.

The cheapest next measurement is to log, on every `AttachToInputDesktop` call, the thread id,
the desktop name (`GetUserObjectInformation`), and whether `SetThreadDesktop` succeeded - then
correlate the first `EnumWindows` failure against that sequence on a boot where it fires.
