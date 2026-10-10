# BUG: a live Windows guest shows no windows in dom0, permanently

## CURRENT STATE

**OPEN, P1, cause NOT established.** Written 2026-10-10 as a cold-read handover; this whole file is
the current state, nothing here is a dated log. Maintain by editing in place.

The guest is alive and has windows; dom0 shows none; it never recovers without a qube restart. It
reproduces TODAY (F1). The daemon dies first and the agent only notices (F3). Whether the GUI comes
back is decided inside dom0's guid by which of its two EOF paths fires (F4) — but **every daemon death
whose cause was ever established here was OUR protocol violation**, class (i), which bypasses
`restart_guid` and can never self-heal (F5). **On no occurrence has the exit path been established**,
because no dom0 guid log was ever collected (F6, F7).

Next action: **G0** (bottom of this file) — guest-side, ~10 cold boots, never run. It decides class (i)
vs class (ii), i.e. whether this is our bug. Nothing else should be spent before it.

---

## The defect

A Windows guest with our QWT reaches a state where **the guest is alive and has windows, and dom0
shows none of them — and it never recovers on its own.** qrexec keeps working, the agent keeps
running, applications keep launching and painting guest-side. Only a qube shutdown/start restores the
GUI.

The guest-side terminal state is: the agent is parked on `Awaiting for a vchan client` with its vchan
server node published and healthy, and **no `qubes-guid` process exists in dom0 for that domain.**

---

## Established facts

Seven, each with a receipt. Nothing here is inference.

**F1 — It reproduces, currently, and it is the reported condition.** 2026-10-10, inside the gate, on an
unrelated run: `FAIL WIN10-appvm boot 3: the guest shows 1 notepad window(s) but the dom0 capture
returned none on six tries`. Measured deliberately the same night, one guest, one variable: after an
agent restart notepad had a visible top-level HWND, the agent sat on `Awaiting for a vchan client`,
`qtest shot` returned 0 PNGs; after a qube reboot the agent logged `A vchan client has connected`
0.32 s later and the same capture returned 1.

**F2 — The agent states the condition in its own log**, and this line is the one to grep for in any
report (`main.c:13328`):
`no gui-daemon client in 90000 ms after 3 restarts, but this guest HAS had one before - dom0's
gui-daemon for this qube is gone and is not coming back on its own. The qube keeps running (qrexec
works) and will show no windows until it is restarted.`
Before that line the agent deliberately exits and is respawned 3 times (`VCHAN_FIRST_CLIENT_MAX_RESTARTS`),
each respawn re-announcing its vchan node. So a log from this defect contains 3 agent generations; that
is by design, not a crash loop.

**F3 — The daemon dies first; the agent only notices.** In the 08-04 incident the dying agent logged
`libxenvchan_send: vchan not open` on `MSG_MAP`/`MSG_SHMIMAGE` *before* `WatchForEvents: vchan
disconnected`. That ordering is what `libxenvchan_write` produces when the peer is **already** gone
(`io.c:355` returns −1 on `!is_open`). The agent is not emitting a bad message at that moment.

**F4 — Whether it self-heals is decided by which of guid's two EOF paths fires**, and only one of them
restarts (`gui-common/txrx-vchan.c`, source-verified):

| path | outcome |
|---|---|
| poll helper → `libvchan_is_eof` → `vchan_at_eof()` | `restart_guid()` → re-`execv` → **GUI recovers** |
| write helper → `handle_vchan_error` → `exit(0)` | **no restart, ever** → this defect |

`handle_vchan_error` never consults `vchan_at_eof`. The precondition for the fatal path is only *"the
daemon had anything to send at that instant"* — `libxenvchan_buffer_space` does not check `is_open`, so
it returns non-zero ring space after the peer dies. The daemon writes back constantly in response to us
(every honoured `MSG_MAP` produces a `MSG_MAP` write-back, `xside.c:2510-2513`; every destroy a
`MSG_DESTROY` echo at protocol ≥ 1.5, and we negotiate minor 8). Matches the record: 08-03 recovered
twice, 08-04 did not, twice.

**F5 — Every daemon death here whose cause WAS established was our own protocol violation.** E1
`img_data_size`, E2 UNMAP/DESTROY-then-SHMIMAGE, E3 materialisation, E9 `msg 0x86`, E7 by inference.
That is class (i): guid `exit(1)`s fail-closed on bad guest input (`xside.c:3943-3957`), which **bypasses
`restart_guid` entirely and can never self-heal.** This class is ours, in our code, and fixable guest-side.
`agent/gui-agent/send.c` carries the known death sites and the geometry sanitizer written against them —
including `MSG_WINDOW_DUMP` over the protocol maximum → `errx(1)`, daemon dies (`xside.c:3894`).

**F6 — On no occurrence has the exit path ever been established.** Four candidates produce an *identical*
guest-side symptom: `exit(0)` write-path EOF (F4); `exit(1)` protocol violation (F5); `exit(1)` failed
reconnect; killed by signal or exiting via `get_boot_lock`, which prints nothing. No dom0 guid log has
ever been collected for any occurrence. **This is the single biggest hole and every ranking is provisional
until it is closed.**

**F7 — The discriminators exist, are source-verified, and the evidence is perishable.** In
`/var/log/qubes/guid.<vm>.log`: `libvchan_is_eof` = restarting path; a bare `EOF` = fatal write path;
`Failed to connect to gui-agent` = stale node; `msg 0x.. without CREATE` = protocol `exit(1)`; **no line
at all** is a distinct pre-registered outcome, not "inconclusive". guid rotates `.log`→`.log.old` and
`O_TRUNC`s on every start without `-f`, and the recovery reboot is exactly such a start — **the failing
generation survives exactly one recovery cycle.** Reproduce → recover → copy both files immediately.

---

## What this is NOT

- **Not a reconnect race** [verified 2026-08-04] - read in the upstream clone.
  `libvchan_client_init` polls with an infinite timeout while the node is
  merely absent, aborting only if the domain is dead (`init.c:210-217, 245-275`). A re-exec'd guid cannot
  fail because `gui-agent.exe` is briefly missing. The "shorten the agent-absent window" family is dead.
- **Not the stale-node variant** — that one is closed [verified 2026-10-07].
  An agent that exited without ever having had a
  client used to leave a live-looking node pointing at a revoked ring; `main.c:14234` now withdraws the
  announcement unconditionally. It was the leading candidate for dom0's `outdated protocol (0:0)` dialog
  (Jev 0.87), chain never established (0.11).
- **Not fixed by anything done on 2026-10-09/10** [verified 2026-10-10].
  Asked with fair facts, Jev: `reported_defect_fixed`
  **0.03**, `symptom_still_reproduces` **0.97**, `fixes_address_the_report` = **adjacent-not-causal,
  conf 1.00**. Those six fixes (a notification gate, autologon, capture log levels, a helper's task
  registration, an installer step) are real defects and several ship — none is on the path by which dom0
  displays a guest's windows.

---

## The next experiment, and why it is first

**G0 — does the defect track our binary?** Entirely guest-side, needs no dom0 action, has never been run.
Cold-boot A/B of the in-place-restart procedure: a current build vs the 08-04 build (`aaa8c37`/`6b5b298`),
n≥5 per side, interleaved, hash-verified install, with a forcing function (a map/unmap storm running until
the instant of the stop — without daemon→guest traffic at that moment a control passes by luck and voids
the comparison). **Pass = the newly started agent logs `A vchan client has connected` within 30 s.**

It is first because it splits F5 from F4 with ~10 cold boots: if the defect tracks the binary it is class
(i), our bug, in our code, and most of the daemon-side analysis is irrelevant. A dead GUI must be recorded
as a distinct **VOID** outcome, never a FAIL, or dead-daemon rounds silently corrupt every A/B.

The one fact G0 cannot supply is F6 — which exit path fired. That needs the dom0 guid log of a failing
generation (F7), captured before the recovery reboot truncates it.
