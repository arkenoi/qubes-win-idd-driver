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
