# Cold-boot defect — reproduces on the current build, blocks "drop-in ready"

Same sequence both sides: install, full VM shutdown, start, wait for qrexec, open the scene,
capture the full dom0 desktop, count `EnumWindows` failures in the agent log since boot.

| | dom0 windows | `EnumWindows` failures |
|---|---|---|
| ours `EDD43F6F4784` (1aafdc9) | 1 | **8** |
| stock 4.2.2 `3D2E6BCE` | 2 | **0** |

The window counts are NOT comparable - the scene failed to launch on the stock pass, so stock
had nothing to show. The failure count is comparable and is the point: `0x80070006`
ERROR_INVALID_HANDLE from `EnumWindows`, repeating on the ~2 s resync interval, only with our
agent. Windows never enter the watched list, so they are never mapped.

It does not reproduce when the agent is restarted inside a live session, which is why every
check in this suite missed it for so long - a restart clears it.

**Root cause not established.** Candidates not yet separated:
* `AttachCaptureThreadToInputDesktop` (added for ACCESS_LOST recovery) calls `SetThreadDesktop`
  and `CloseDesktop` on the capture thread;
* `CollectZOrder` adds a second per-frame `EnumWindows` caller on the main thread;
* the boot path runs before the interactive desktop is fully up, and our agent reaches window
  enumeration earlier than stock does.

The bisect that would separate these was attempted with an unvalidated discriminator and had to
be thrown away (see `BISECT-TRUNCATION.md`). Redoing it needs the cold-boot check itself as the
discriminator, run serially, with the binary hash verified per iteration - roughly 8 minutes
per candidate build.

Until this is fixed the package is not drop-in installable: a user who reboots the qube gets
an agent that never maps windows.

---

# RETRACTED: the cold-boot bisect, and the justification for the fix

Characterising the check the way the other two metrics had to be characterised shows it is not
stable. The SAME binary (`EDD43F6F4784`, agent `1aafdc9`) across cold boots:

```
run 1: EnumWindows_failures=8  => FAIL
run 2: EnumWindows_failures=0  => PASS
run 3: EnumWindows_failures=0  => PASS
```

and a second build of the same commit (`340178330A90`) gave 0 twice. So:

* the bisect result - `final` (7c17564) PASS / `f2` (42beb78) FAIL - is **single samples of an
  unstable check** and does not establish that the capture-thread desktop re-attach is the
  cause;
* commit `a4a64a7` ("Do not close the previously installed desktop handle") is therefore
  **not justified by the evidence its message cites**. The change itself is defensible on its
  own terms - MSDN warns against closing a desktop that may still be in use by another thread
  of the process, and leaking one handle per recovery is cheap - but it must not be described
  as a bisected fix, and it has NOT been shown to change the failure rate.

## What is actually established

The defect is real and intermittent: 8 `EnumWindows` failures (`0x80070006`) on a cold boot,
observed on more than one build, roughly 1 run in 3. When it fires, no window enters the
watched list and the qube renders nothing until the agent is restarted.

Whether stock is immune is also unestablished - stock was measured once (0 failures), which by
the same standard proves nothing.

## What a valid answer needs

The failure rate is around 1 in 3, so distinguishing builds needs enough runs per build to
separate ~33% from ~0% - on the order of 8-10 cold boots per candidate, at roughly 8 minutes
each. That is 1-1.5 hours per build, and a binary search over the candidate range is a day of
machine time. Sampling more cheaply would need the fault reproduced without a full reboot,
which nothing found so far does.
