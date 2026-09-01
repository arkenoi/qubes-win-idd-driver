# FINDINGS — index

The running record is split by topic under `findings/`. **Read the CURRENT STATE block at
the top of a topic file; it supersedes the dated history below it.**

Split 2026-09-01 from a single 24,994-line append-only log whose 566 dated sections
contained 654 correction lines scattered chronologically, so reading any topic top-down
gave the stale answer first. That is not a filing preference; it produced wrong work.

| topic | sections | file |
|---|---:|---|
| appmenus | 5 | [`findings/appmenus.md`](findings/appmenus.md) |
| autologon | 29 | [`findings/autologon.md`](findings/autologon.md) |
| capture | 54 | [`findings/capture.md`](findings/capture.md) |
| console | 12 | [`findings/console.md`](findings/console.md) |
| drag | 49 | [`findings/drag.md`](findings/drag.md) |
| idd | 43 | [`findings/idd.md`](findings/idd.md) |
| install | 88 | [`findings/install.md`](findings/install.md) |
| misc | 24 | [`findings/misc.md`](findings/misc.md) |
| network | 58 | [`findings/network.md`](findings/network.md) |
| qrexec | 24 | [`findings/qrexec.md`](findings/qrexec.md) |
| rig | 35 | [`findings/rig.md`](findings/rig.md) |
| updates | 75 | [`findings/updates.md`](findings/updates.md) |
| wedge | 62 | [`findings/wedge.md`](findings/wedge.md) |
| windowing | 66 | [`findings/windowing.md`](findings/windowing.md) |

## Rules (enforced by tools/lint-harness.py, not by good intentions)

1. Every `findings/*.md` has a `## CURRENT STATE` block.
2. Every CURRENT STATE bullet carries `[verified <date>]` or `UNVERIFIED`.
3. This file holds the index and nothing else, so it cannot regrow into the log.
4. A commit that appends a dated section to a topic file must also touch that
   file's CURRENT STATE block.
