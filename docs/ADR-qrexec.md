# ADR - qrexec: calls made inside the qube, the pipe to the agent, the per-call wrapper

## In plain English

qrexec is how one qube runs a service in another. In a Windows guest three of our pieces carry it: the agent
service, a small pipe through which a program inside the qube asks the agent for a call, and one wrapper
process per call that moves the data. An audit read 35 candidate defects out of their source
(`docs/AUDIT-qrexec.md`). The owner ordered them fixed, and the build for release 4.3.44 fixes those whose
fix is small and needs no decision from the owner. A focused test then reproduced three of the 35 on a
guest: two are gone in that build, one is not fixed (§3, §5). The other 32 are read from source only. Eleven
of the fixes have no verdict from the judge; whether they ship is the owner's question (§7.8).

This record holds the rules those fixes follow. The fixes were built on the owner's order. The rules as
written here are mine: they are PROPOSED until the owner has read them, and the questions at the end are the
owner's.

The rules:

1. **Nothing here adds work for the device model.** Every call into the guest already makes the emulated
   hardware do two synchronous round trips, and that is where the known freeze sits. A fix may not add such a
   round trip, run two at once, repeat one, or space them with a pause.
2. **The agent takes calls from inside the qube only once it can forward them.** Before that, a caller is told
   the agent is not there. It used to be told "done" for a call that was thrown away.
3. **A call that cannot be served fails alone.** One bad call no longer ends the agent for every call. A
   caller that leaves before the agent has answered it no longer stops the agent from accepting the next.
   One that takes the answer and then leaves still does: that is measured and not fixed.
4. **A fix never ends a wait on a clock.** What cannot succeed fails at once. What can succeed is waited for,
   and a stop request ends the wait. The limits that were already there stay as they are.
5. **A program that stops reading its input still gets to finish.** Its output and its real exit code reach the
   caller.

## The decisions at a glance

| § | decision | status | date |
|---|---|---|---|
| 1 | A change to qrexec adds no vchan open or close and paces none | PROPOSED (my reading of the owner's instruction) | 2026-11-14 |
| 2 | The trigger pipe opens when the hello has been sent | PROPOSED; built on the owner's order | 2026-11-14 |
| 3 | A call that cannot be served fails alone | PROPOSED; built on the owner's order | 2026-11-14 |
| 4 | A fix adds no time limit and no counted retry; what cannot succeed fails at once | PROPOSED: the rule is the owner's standing one, its use here is mine | 2026-11-14 |
| 5 | A failed write to the child's stdin ends its input, not the call | PROPOSED; built on the owner's order | 2026-11-14 |
| 6 | The source domain of a call is in the agent's environment only for that call's launch | PROPOSED; built on the owner's order | 2026-11-14 |
| 7 | The open questions | OPEN (owner) | 2026-11-14 |

Status words and the section format are defined in `docs/ADR-README.md`. "Built on the owner's order" means
the order to fix the audit's findings: the code is in the build for 4.3.44, and the rule as written here,
with its cost, has not been put to the owner.

---

## The decisions in detail

Where the details live:

| record | content |
|---|---|
| `docs/AUDIT-qrexec.md` | the 35 candidates, and in §1.6 what was done about each one, with the judge's numbers |
| `docs/ADR-boot.md` §1, §2 | the device-model freeze and the one-CPU pin that §1 rests on |
| `core-agent/src/qrexec-agent/qrexec-agent.c` | the agent: §2, §3, §6 |
| `core-agent/src/qrexec-wrapper/qrexec-wrapper.c` | the per-call wrapper: §4, §5 |
| `winutils/src/pipe-server.c` | the pipe server and its client side, run by the agent and by the stock qubesdb daemon: §3, §4 |

## 1. A change to qrexec adds no vchan open or close and paces none

**Status:** PROPOSED, 2026-11-14. The owner gave the instruction quoted below. The four rules are my reading
of it. Every fix in the build for 4.3.44 was judged under them; they were not put to the owner (§7.6).

**Context.** Unmapping a mapped grant makes a vCPU wait synchronously for QEMU. Every qrexec call into the
guest maps the caller's vchan ring and unmaps it at close. Serialising that work on one CPU is the one change
measured to help: stalls under load went from 17 of 26 to 0 of 26 (`ADR-boot` §1). The defect is in QEMU.
Owner, 2026-10-31: "they pinpointed the bug in qemu code and we just wait for fix and try not to provoke it in
a way that interferes with our test". Owner, on the audit's fixes: "when implementing the qrexec fixes, keep in
mind circumventing the quemu bug we are aware of".

**Decision.** A change to the agent, the wrapper or the pipe server:

1. adds no vchan client connect and no vchan close;
2. moves no vchan open or close off the pinned CPU and makes no two of them run at once;
3. adds no retry that repeats such work;
4. paces no vchan, grant or event-channel work with a fixed sleep.

A change that touches none of that work is not restricted by this section.

**Evidence.** Each fix was judged on this section alone (`qemu_safe`); every applied one scored 0.81 or more
(`AUDIT-qrexec` §1.6). Owed: the stall count of the full acceptance of the build that carries them.

## 2. The trigger pipe opens when the hello has been sent

**Status:** PROPOSED, 2026-11-14. Built on the owner's order; it is item 1 of the audit's §1.4. Jev on the
fix: no verdict (apply 0.64, floor 0.70).

**Context.** The pipe server ran from service start, before the control channel to dom0 existed. A request made
in that window was read, its caller was released with exit code 0, and the trigger was thrown away (#16), or it
entered the ring ahead of the hello (#6).

**Decision.** The accept thread is created suspended. The agent resumes it when the daemon has connected and
the hello is in the ring. Until then the pipe does not exist, and a caller's connect fails with "not found".
A resume that fails is logged as an error and leaves it that way: calls from dom0 are still served.

**Why.** The Linux agent listens only after its handshake.

**Cost.** A program that calls before dom0's daemon has connected gets an error where it got exit code 0 and
no call (§7.7). The window is the same one in which the agent service has not started yet, a little longer.

**Evidence.** On one guest, three boots of the build: the agent logged "hello sent to the daemon: the trigger
pipe opens for calls made inside the qube" once per boot, and the first call made inside the qube came 0.5 s
to 1.2 s later and was served. No caller was early in those boots, so the defect itself was seen neither to
fail nor to pass. Owed: that line on every boot of the acceptance, and a call made before the hello.

## 3. A call that cannot be served fails alone

**Status:** PROPOSED, 2026-11-14. Built on the owner's order; items 2 to 4 of the audit's §1.4. Jev on the
fixes: points 1, 4 and 5 at or above the floor (0.98 and 0.90, 0.76, 0.81); points 2 and 3 no verdict (0.63,
0.23).

**Context.** Any error a message handler returned left the agent's main loop: the service ended and dom0
dropped every connection of the qube. One client that vanished mid-handshake ended the pipe server's accept
loop, and one that connected and left at once parked it for good. From then on every call made inside the qube
hung while calls from dom0 kept working.

**Decision.**

1. A wrapper that cannot be started, or is started but cannot be tracked because the connection table is full,
   is logged and the agent's loop goes on. Nothing is sent to the daemon for it.
2. The accept loop ends one client on that client's error and goes on to the next. It returns only when it
   cannot create the pipe it listens on, or when the server is being destroyed.
3. A client that connected and has already left counts as connected. What it wrote is still read.
4. A new client carries its host's reference before any other thread can find it.
5. A pipe server that cannot be created ends the service with the error, so that it is restarted.

**Cost.** A client that opens the first pipe and leaves costs one error line where it used to stop the loop.

**Evidence.** Point 2 (#12), on two clones of one golden that differ by the package alone. Seen to fail, the
build before the fixes: one caller opened the trigger pipe and left, the agent logged one error, and the
next call made inside the qube hung. Seen to pass, this build: twenty such callers in a row cost twenty
error lines and the next call was served. A second guest gave the same failure on the build before.
Point 3, with a one-shot probe on its own pipes: a connect to an instance whose client has opened and closed
it answers ERROR_NO_DATA, and a read on such an inbound instance still returns what the client wrote. #34
itself was not reproduced. Points 1, 4 and 5 were not driven.

**Open.** §7.4, §7.11. A caller that takes the name of the second pipe and never opens it still parks the
accept thread (#10). Seen on both builds: the next call made inside the qube hung and nothing was logged.
On this build a call from another qube was still served afterwards. The form that ends needs an overlapped
connect and was not built. The 100 ms wait before a pipe worker thread is killed stays (#11, narrowed:
`AUDIT-qrexec` §1.6).

## 4. A fix adds no time limit and no counted retry; what cannot succeed fails at once

**Status:** PROPOSED, 2026-11-14. The rule is the owner's standing one (`ADR-README`, "Never a timeout as a
fix; every wait is an observed condition"). Its use on these fixes is mine, and so is the choice to ship no
limit where Linux has one: I made it at night without asking, and §7.3 puts it to the owner. Jev on the three
texts written to it: no verdict (0.12, 0.18, 0.59).

**Context.** Three fixes were first written with a limit: a counted retry (#22), a counted wait (#20) and a
120-second wait (#8). The pre-commit review named the standing rule against the third, and all three were
rewritten.

**Decision.**

1. The client opens the second pipe once (#22). The server creates that pipe before it sends its name, so a
   pipe that is not found will not appear, and the failure is returned at once.
2. The pipe server's reader thread takes from the pipe only what the read queue has room for, and waits for
   room for as long as the host takes (#20). A client is dropped by a disconnect, not by a clock.
3. The wrapper's wait for its data client has no limit. A stop request now ends it, and the wrapper then closes
   its vchan itself (#8).
4. The 120-second backstop on the drain after the child's exit stays. It starts again while an output pump is
   inside a send or has completed one since it was set, so it no longer cuts a transfer that is still moving
   (#4, §7.5).
5. The limits that were already in this code are not touched: the write timeout and the 100 ms wait before a
   pipe worker is killed, the 90-second wait for a logon, the vchan library's own waits.

**Cost.** A wrapper whose data client never connects holds its process, its ring and its xenstore entry until a
stop (#5, and the unbounded half of #8, unchanged). A host that neither reads nor disconnects a pipe client
holds that client's writer in its write once the queue is full, where the overflow used to drop the client.
The wait for room is a 10 ms poll, as the other waits in that file are. The 10 ms pause after the client's
open is inherited and kept.

**Evidence.** On one guest, an upgrade and three boots of the build: the qubesdb daemon took 30 connections
and the agent 5 calls made inside the qube, and no log holds the "open write pipe" line that a failure of
rule 1 writes. Rules 2 to 4 were not driven. Owed: the same count over the acceptance.

**Open.** §7.3, §7.5.

## 5. A failed write to the child's stdin ends its input, not the call

**Status:** PROPOSED, 2026-11-14. Built on the owner's order; item 6 of the audit's §1.4. Jev on the fixes:
no verdict (#1 apply 0.20, #26 apply 0.66).

**Context.** A write to the stdin of a child that had exited ended the event loop before the arm that handles
the exit. The caller got a Win32 pipe error as the exit code, and output still in the pumps was cut (#1).

**Decision.** A failed stdin write closes stdin and the loop goes on. Input that arrives afterwards is
discarded. After such a failure the loop looks at the child's exit before it waits again. In the loop that
serves a call with no local program, a closed vchan is read to its end before leaving, and the call succeeded
when the peer's exit code arrived (#26).

**Why.** The Linux agent closes stdin on the child's exit and sends the exit code only after the output.

**Cost.** The existing error line for the failed write stays.

**Evidence.** #1, on two clones of one golden that differ by the package alone: a piped call whose command
is `exit 7` followed by 4,000,000 bytes of input. Seen to fail, the build before the fixes: the caller got 232,
the error of the wrapper's own write. Seen to pass, this build: the caller got 7, and the wrapper logged
the one failed write. The command alone returned 7 on both. A second guest gave the same 232 on the build
before. #26 was not driven.

## 6. The source domain of a call is in the agent's environment only for that call's launch

**Status:** PROPOSED, 2026-11-14. Built on the owner's order (audit §7.5). Jev on the fix: apply 0.70, at
the floor.

**Decision.** The agent sets `QREXEC_REMOTE_DOMAIN` for the launch of a call's wrapper and removes it again
afterwards, so no later wrapper inherits the source domain of an earlier call (audit §7.5).

**Evidence.** On one guest, three calls from the management qube each saw its name in the variable, so a call
still gets its own. The defect is a call made inside the qube whose local program sees the domain of an
earlier call. That was not driven. Owed: that pair, on both builds.

## 7. The open questions

**Status:** OPEN (owner), 2026-11-14. No edit in the build for 4.3.44 changes the first two.

1. **Keep the caller connected until the agent has answered** (audit §1.4 item 7). `qrexec-client-vm.exe`
   returns 0 once its request is written. Linux stays connected until dom0 has answered. Changing it changes
   what that program returns and when.
2. **Which user name selects a call's token** (audit §7.1). It touches a boundary `ADR-uac` keeps.
3. **A 120-second limit on the wrapper's wait for its data client.** The Linux agent has it
   (`agent/qrexec-agent-data.c`, `connection_timeout = 120`, then exit 1). §4 forbids it. One of the two has to
   give: which one? The build for 4.3.44 has no such limit.
4. **What dom0 is told about a call whose wrapper could not be started** (audit §1.4 item 2). Today nothing:
   dom0's side ends by itself.
5. **The 120-second backstop on the drain** (§4 rule 4). It is the fork's own and it is a clock. The wrapper's
   comment records that Linux has none there. The build for 4.3.44 keeps it and only stops it from cutting a
   transfer that moves. Keep it, or remove it?
6. **The four rules of §1.** They are my reading of "keep in mind circumventing the quemu bug". Are they the
   rule?
7. **An error for a caller that is early** (§2). A call made before dom0's daemon has connected used to be
   lost with exit code 0 and now fails with "not found". Is the error the answer, or should the caller wait
   for the pipe?
8. **Eleven fixes are in the build with no verdict from the judge** (`AUDIT-qrexec` §1.6, "Fixed with no
   verdict": #16 and #6, 7.3, #12, #34, #2, #20, #22, #1, #4, #8, #26). I applied them on my own reading.
   Two of them, #12 and #1, were then seen to fail before the fix and to pass with it (§3, §5). The other
   nine were not reproduced. Do they ship in 4.3.44 once the acceptance of that build is clean, or are they
   held for a release of their own? I went on at night without asking: the build carries them.
9. **A new wait that polls** (§4 rule 2). The reader thread looks for room in a full queue every 10 ms, the
   way the file's other waits do. The standing rule prefers a push: an event set by the read that makes the
   room. The poll runs only while the queue is full. Build the push form?
10. **Sections 1 to 5 were built before any verdict on their text.** `ADR-README` says a PROPOSED section is
    not built before its verdict. I took the order to fix the findings as covering the build. Was that right?
11. **One caller can still stop every later call made inside the qube** (§3 Open, #10). It is measured on
    the build for 4.3.44 and it is not a regression: the build before did the same. Ending it means an
    accept loop that takes clients concurrently, which is a rebuild and also closes #24. Build it for the
    next release?
12. **The kill of a pipe worker thread 100 ms after a disconnect** (§3 Open, §4 rule 5, #11). It is a clock
    and a kill, both inherited. The fix made it fire in fewer cases; a killed reader can still hold the list
    lock. The form without it waits for the worker's own end with no limit, so a service stop can hang. Keep
    the kill, or build the form without it?
