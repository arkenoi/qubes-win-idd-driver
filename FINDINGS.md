# FINDINGS — index

The record lives in `findings/<topic>.md`. **Each file is a CURRENT STATE head and nothing
else** — the 25k-line chronological log was split by topic on 2026-09-01 and its dated
histories were amputated the same day (owner call): the log format itself caused
stale-first reads and contaminated sessions. Git history retains the old log for
deliberate forensics only; do not load it into context.

| topic | file |
|---|---|
| appmenus | [`findings/appmenus.md`](findings/appmenus.md) |
| autologon | [`findings/autologon.md`](findings/autologon.md) |
| capture | [`findings/capture.md`](findings/capture.md) |
| console | [`findings/console.md`](findings/console.md) |
| drag | [`findings/drag.md`](findings/drag.md) |
| idd | [`findings/idd.md`](findings/idd.md) |
| **issues (prioritized, by tag)** | [`findings/issues.md`](findings/issues.md) |
| install | [`findings/install.md`](findings/install.md) |
| misc | [`findings/misc.md`](findings/misc.md) |
| network | [`findings/network.md`](findings/network.md) |
| protocol | [`findings/protocol.md`](findings/protocol.md) |
| qrexec | [`findings/qrexec.md`](findings/qrexec.md) |
| rig | [`findings/rig.md`](findings/rig.md) |
| updates | [`findings/updates.md`](findings/updates.md) |
| wedge | [`findings/wedge.md`](findings/wedge.md) |
| windowing | [`findings/windowing.md`](findings/windowing.md) |

## Rules (enforced by tools/lint-harness.py and .githooks/pre-commit, not by good intentions)

1. Every `findings/*.md` is a `## CURRENT STATE` block ONLY. Dated `## YYYY-MM-DD` sections
   are refused at commit time — new information goes into the bullets, in place.
2. Every bullet carries `[verified <date>]` or `UNVERIFIED`.
3. This file holds the index and nothing else.
4. A correction EDITS or DELETES the wrong bullet — it does not append a counter-claim.
