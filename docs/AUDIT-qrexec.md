# qrexec and qrexec-wrapper: race, TOCTOU and deadlock audit, with a verdict on every change

Status: REPORT (2026-11-10). Owner asked for this audit, and then for the report to be committed on its
own, apart from the issue register (`findings/issues.md`). It is a report only: no source file was
changed, nothing in it was measured on a guest, and as of that date nothing in it is fixed or entered in
the register. **Section 1.6, added 2026-11-14, records what was changed for release 4.3.44 and which
candidates were reproduced on a guest since.** Every other section is the report as it was written, and its
line numbers are those of the audited commits.

Audited at `winutils` c09bfc6 (fork base tag `R4.3.0`), `core-agent` 6013dff (fork base tag
`mm_a75b5e10`), parent repo 3d23fe6e. Linux reference: `upstream/ro/qubes-core-qrexec` at fa04483.

| You asked | Where it is answered |
|---|---|
| "audit whole qrexec and qrexec-wrapper work for race conditions, toctou and deadlocks" | sections 1, 3 and 4 |
| "verdict on every significant change if it was necessary, not overengineered and free of side effects" | section 5 |
| "use linux counterpart as desired functionalty reference point" | every finding in section 3, and section 6 |
| "process creation and service plumbing is exactly the place where shit happens" | `exec.c` and `service.c` were audited as a unit of their own and read in full; `log.c` I read in full myself, because the finders had read only parts of it. See #3, #15, #25, #29, #30, #35, section 3.3 and section 7 |
| "make a report, do not implement fixes yet" | this file; section 1.4 lists what I would fix first, none of it started |

## 1. Bottom line

### 1.1 The count

The audit produced 35 candidate defects: 17 races, 9 time-of-check/time-of-use windows, 9 deadlocks or
unbounded waits.

- **14 were confirmed by the judge** (Jev) as possible exactly as described: #9, #11, #15, #16, #17, #20,
  #22, #25, #26, #27, #29, #30, #32, #35. Ten of those were also judged user-visible; for #25, #26, #27 and
  #30 the judge gave no verdict on impact.
- **21 have no verdict.** The judge's confidence stayed under its floor of 0.70 on both asks. That means
  not confirmed and not refuted: in none of the 21 did "the code prevents this" or "the claim misreads
  the source" reach the floor either.
- **None was reproduced on a guest. Four have a trace in real data.** [Since then three were: section
  1.6.] The one recorded crash of the
  agent service (2026-10-14, closed in the register as QREXECAGENTAV) fits #9 step for step, and the
  cause it points at is still in the code: the fix that shipped guards the crash, not the early free
  behind it. The thread kill behind #11 is logged four times in captured qubesdb-daemon logs, the
  failing stdin write behind #1 is logged once in a captured wrapper log, and the event behind #2 is
  recorded in a comment the fork itself wrote into `pipe-server.c`.
- **27 of the 35 sit on lines that were already there at the fork base; 8 sit on lines the fork wrote.**
  The plan for this audit expected the opposite ("mostly in code our fork added"). Inherited does not
  mean someone else's: `winutils` is carried in tree and `core-agent` is our fork, so all 35 are ours to
  fix or to leave.

### 1.2 Three differences from Linux carry most of what a user would see

1. **The program that makes a call from inside the qube is released before anything has happened.**
   `qrexec-client-vm.exe` writes its request and returns 0 without waiting for an answer
   (`qrexec-client-vm.c:136-140`, inherited). Whatever goes wrong after that write is invisible to the
   caller. The Linux caller stays connected until dom0 has answered. Findings #16, #2, #20, #9, #28 and
   the first half of #34 all end the same way: the call silently did nothing and the caller saw success.
2. **One thread accepts those callers, and nothing watches it.** It can be parked for ever or end in
   five ways (#34, #10, #12, the unchecked pipe creation in #22, and the failed resume in #9). From then on every call started
   inside the qube hangs until the agent service restarts, while calls from dom0 keep working, so the
   qube looks healthy. Linux accepts on a non-blocking socket inside its main loop.
3. **An error on one call ends the agent for every call.** Any error a message handler returns leaves
   the agent's main loop (`qrexec-agent.c:1675-1680`, inherited). The service exits, dom0 drops every
   qrexec connection of the qube, and Windows restarts the service after 5, 15 and then 60 seconds.
   Linux logs and keeps serving in the same situations. Fork commit 190c190 added one more way in: a
   full connection table now returns an error whose own comment says it fails "the one call", but which
   takes this exit (section 5.3).

### 1.3 The fork's own changes

75 change units were judged: 62 `core-agent` commits, one of them split in two, and 6 `winutils`
commits, the assimilation commit split in seven. **Nothing was judged unnecessary or overengineered at
the floor.** Of the 51 units that change behaviour or could not be classified, the judge could see for
itself the defect the change closes in 37, and judged 41 proportionate. In 32 of the 51 it could see
behaviour changing outside the stated purpose; that verdict does not grade harm, and it counts reworded
log lines and departures from Linux along with defects. The ones I confirmed by reading and consider
worth your attention are in section 5.3:

- The `winutils` pipe-server connect rewrite (2026-10-14, now part of e25cbc1): written after the
  recorded agent crash, it closes a window the old code's lock already excluded on the success path and
  leaves open the one the crash log shows (#9).
- 190c190: a full connection table now stops the whole agent.
- The `winutils` pipe-server change plus 598903e: together they removed the ERROR trace of a real request
  loss (#2) and replaced it with a line that says nothing was lost.
- 70dd82e: the agent and the caller now accept service names up to 65000 bytes, but the pipe queue
  between them still holds 4096, so a long request is accepted on paper and cannot be delivered (#20).
- ac33bc9, 224cb46 and d228a03 together: after a 120-second deadline the exit code overtakes output the
  wrapper still holds (#4).
- 9ad4dfc: the wrapper waits up to 90 seconds for a logon after connecting, then runs the command without
  looking whether the caller is still there (#23).
- a493b63, the one-CPU pin: the judge found its necessity claimed rather than shown (`claimed_only`
  0.81 on the diff alone, 0.59 with the wider extract); a grandchild of the service can inherit the pin
  for life (#30); it plausibly widens the window of #34; and it is what keeps a non-atomic update in
  the vchan library from mattering (#19).
- 2d2b55d, 933d01d and d63b88b, three log demotions: together they make the logger's unlocked first use
  reachable from two threads (#35), and a wrapper serving a call into the qube now writes its birth
  line when it exits, or never if it hangs.

### 1.4 What I would fix first (none of this is started)

[The state on 2026-11-10. What was built of items 1 to 6 for release 4.3.44, and what was left: section
1.6. Items 7 and 8 are untouched.]

1. Open the trigger pipe only after the control channel is connected and the hello has been sent, as
   Linux does. Removes #16 and #6. Small.
2. Make a failed call fail that call only: a failed launch (#3), a full table (190c190) and an unknown
   request id (#13) should be logged and the loop should go on, as on Linux. Small, and it needs a
   decision on what dom0 is told about the port.
3. Accept loop: treat "the client connected and already left" as a finished connection, check both
   `CreateNamedPipe` results, never return from the loop on one client's error, bound the second connect
   (#34, #10, #12, #22).
4. `QpsConnectClient`: give a new client its host reference before it is published, so no release can
   reach zero while the accept thread still uses it (#9). A few lines, and it is the cause the recorded
   agent crash points at.
5. `QpsRead`: look at the buffer once more under the lock before giving up on a disconnect (#2), and
   stop the reader thread from reading ahead of the consumer or size the queue to what is accepted (#20).
6. Wrapper stdin: a failed write to a child that has exited should close stdin and go through the
   child-exit arm, as on Linux (#1); the write should not block the only event thread (#15).
7. Keep the caller connected until the agent answers. This is the Linux contract and removes the premise
   of section 3.1, but it changes what `qrexec-client-vm.exe` returns and when, so it is your decision.
8. Decide the user-name question in section 7.1. It is outside the three classes, but it is the one
   item in this report that touches a boundary your UAC decision record says the product keeps.

### 1.5 What this audit cannot tell you

How often any of this happens. Everything was derived from source; Win32, Xen and dom0 behaviour was
taken from documentation and from reference copies of the libraries, and no probe was run on a guest.
The captured logs I searched come from harness runs, and several of the lines that would witness these
defects are written at DEBUG or were demoted by the fork, so "0 occurrences" is weak evidence. Section 8
has the full list of limits. One recorded wrapper crash (2026-10-09, section 7.9) turned up in the
log search and I did not explain it.

### 1.6 What was done about each one for release 4.3.44 (2026-11-14)

You ordered the findings fixed, with one instruction: "when implementing the qrexec fixes, keep in mind
circumventing the quemu bug we are aware of". The rules the fixes follow are in `docs/ADR-qrexec.md`.
The code is `winutils` 41ab843 and `core-agent` 47145b3.

**How.** For each source file one reader wrote the edits and a second tried to break them. Code checked
that every edit's anchor and every objection's quote exist in the file. The judge then scored each fix
on its edits and the objections: does it fix the candidate, does it introduce a defect, does it keep to
the device-model rule (`ADR-qrexec` §1), and what should be done with it. Its floor is 0.70, and under
it there is no verdict. I applied the edits myself. Only small fixes were taken: an edit that needs a
new thread, a new lock, a protocol change or your decision was left, with its design below.

Three fixes were first written with a time limit or a counted retry. The standing rule forbids a clock
as a fix (`ADR-qrexec` §4), so I rewrote #20, #22 and #8 without one, asked the judge again, and had a
second reader try to break the rewritten text. That reader returned no defect. It is a reading.

**What is measured.** The audit reproduced no candidate. The focused test of the fixes (2026-11-14) ran two
reproducers on one guest type, a clone of the same Windows 11 25H2 golden upgraded once to the package
before the fixes (parent 797b6e58) and once to the package that carries them (build-4.3.44.1299). The two
packages differ by the two submodule commits only.

| # | stimulus | before the fixes | with the fixes |
|---|---|---|---|
| 1 | a piped call whose command is `exit 7`, followed by 4,000,000 bytes of input | the caller gets 232 | the caller gets 7; the wrapper logs the one failed write |
| 12 | a caller opens the trigger pipe and leaves before the server has written the second pipe's name | one error line; the next call made inside the qube hangs | twenty such callers, twenty error lines; the next call is served |
| 10 | a caller takes that name and leaves without opening the second pipe | nothing is logged; the next call hangs | the same. Not fixed |

Each run began with its control: the command alone returned 7, and a call made inside the qube before the
stimulus was served. #1 and #12 failed the same way on a second guest with the package before the fixes, a
German Windows 11 template. The "before" answer of #10 comes from that guest alone. The other 32
candidates stay read from source.

The same test on the build with the fixes, over an upgrade and three boots: the agent logged its hello line
once per boot and served the calls made inside the qube that followed (5); the qubesdb daemon served 30
connections; no log holds an "open write pipe" line; the agent's log holds no error or warning line; and
three calls from another qube each saw its name in `QREXEC_REMOTE_DOMAIN`. The log sweep's breaches are one
burst: twelve error lines of the qubesdb client while the installer has the old daemon stopped. The pipe
code on both ends of it was the golden's (4.3.35), it is in 15 of this upgrade's 17 runs since 2026-10-28,
and the acceptance cells declare it.

One probe on Windows 11 25H2 (build 26200.9974), on pipes of its own, measured what the pipe-server fixes
rest on:

- `ConnectNamedPipe` answers 232 (`ERROR_NO_DATA`) for a client that has opened the instance and closed
  it again, with or without having written;
- a read on such an inbound instance still returns what the client wrote, and then answers 109;
- a write to such an outbound instance answers 232;
- `CancelIoEx` on a handle ends another thread's blocking read with 995, and answers 1168 when no read
  is in flight;
- opening a pipe name nobody created answers 2.

Owed: the acceptance of that build.

**Fixed, with the judge at or above its floor.**

| # | what changed | judge |
|---|---|---|
| 190c190 | a full connection table is logged and the loop goes on; the wrapper serves its call untracked | apply with a correction 0.98; the correction is applied |
| 3 | a wrapper that cannot be started fails that call only (agent side; `exec.c` needed no change) | apply with a correction 0.90; applied |
| 9 | the host's reference exists before the client is published; the client is not touched after the connect callback | apply 0.76 |
| 27 | the disconnect flag is tested and set in one step | apply 0.81 |
| 28 | the lookup takes its reference under the list lock | apply 0.84 |
| 11 | NARROWED. A disconnect cancels the workers' pipe I/O by handle, so a blocked reader or writer ends by itself. The kill after 100 ms stays | apply with a correction 0.71 (fixes the candidate: 0.27) |
| 7.4 | a pipe server that cannot be created ends the service with the error, so that it is restarted | apply 0.81 |
| 7.5 | `QREXEC_REMOTE_DOMAIN` is removed from the agent's environment after each launch | apply 0.70 |
| 7.7 | a log line longer than the buffer is cut instead of ending the process | apply with a correction 0.92; applied |
| 7.8 | the comment at `log.c:506` now says what the code does | apply 0.92 |

**Fixed with no verdict, on my own reading of the code.** Whether these ship in 4.3.44 is your question:
`ADR-qrexec` §7.8.

| # | what changed | judge |
|---|---|---|
| 16, 6 | the trigger pipe's accept thread is created suspended and resumed when the hello is in the ring | apply 0.64 |
| 7.3 | the pipe client is released on every path of its thread | apply 0.68 |
| 12 | the accept loop drops the one client whose step fails and goes on; both pipe creations are checked | apply 0.63. Seen to fail before it and to pass with it (above) |
| 34 | a client that has already closed counts as connected, on both pipes | apply 0.23 |
| 2 | `QpsRead` samples the disconnect flag before it looks at the queue | apply 0.22 |
| 20 | the reader thread takes only what the queue has room for and waits for room without a limit; `QpsRead` takes the queue piece by piece, so a request may exceed it | this form: no option reached 0.30. With a count on the wait: apply with a correction 0.82 |
| 22 | the client opens the second pipe once; the server creates it before it sends its name | this form: insufficient 0.32, apply 0.30. With a counted retry: apply 0.76 |
| 1 | a failed write to the child's stdin closes stdin and the loop goes on to the child's exit; later input is discarded | apply 0.20. Seen to fail before it and to pass with it (above) |
| 4 | the 120 s drain after the child's exit starts again while output is still moving | apply 0.40 |
| 8 | a stop request ends the server's wait for its data client, and the wrapper closes its vchan itself | this form: apply in part 0.59. With the 120 s limit, which also closed #5: apply with a correction 0.63 |
| 26 | the loop with no local program reads a closed vchan to its end; the call succeeded when the peer's exit code arrived | apply 0.66 |

**What the fixes leave, as the second reader and I read it.**

- #11. The kill now reaches a reader in two cases only: its way out takes longer than 100 ms, or it
  looked at the flag just before the flag was set and then started a read. Before, the kill reached
  every reader that was blocked in a read, and that reader held no lock. A reader on its way out can
  hold the list lock for a few instructions. The form with no kill waits for the reader's end without a
  limit and cancels again on each look; it trades the kill for a stop that can hang, and was not built.
- #20. A host that neither reads nor disconnects a client now holds that client's writer in its write
  once the queue is full; before, the overflow dropped the client. Both hosts get there only when they
  cannot create the client's thread (`qrexec-agent.c` `ClientConnectedCallback`, the stock daemon's
  `client_connected_callback`). The wait for room is a 10 ms look; an event set by `QpsRead` would be
  the push form.
- #22. The 10 ms pause after a successful open is inherited and kept.
- #16. A caller that arrives before dom0's daemon has connected now gets "not found" where it got exit
  code 0 and no call.

**Not fixed.**

| # | why, and what it would take |
|---|---|
| 5 | needs the wait for the data client to end by itself. Linux ends it after 120 s; the standing rule forbids that. Your question, `ADR-qrexec` §7.3 |
| 10 | reproduced on both builds (above). The edit written was a counted look before the second connect; the judge said drop (0.23). The form that ends needs an overlapped connect that also waits on the first pipe closing; a client that stays and never opens the second pipe holds the loop until clients are accepted concurrently |
| 13 | edit written: a reply that names no pending request is logged and the loop goes on. Judge: apply in part 0.42, fixes the candidate 0.15. Not applied. The other half, ids that restart at 1, was left as unshown |
| 19 | edit written: a 10 s limit on the event loop's wait, served as a wake. It is a clock, and the judge said apply in part 0.52 (fixes 0.26). Not applied. The cause is a non-atomic OR in the vchan library, kept harmless by the one-CPU pin |
| 30 | edit written: the payload is created suspended, given the full CPU mask, then resumed. Judge: apply in part 0.53 (fixes 0.38): the SYSTEM-token path is created inside `exec.c` and stays as it is. Not applied |
| 29 | edit written: the service context outlives the control dispatcher. Judge: apply 0.27, introduces a defect 0.67. Not applied |
| 35, 7.8 `LogLock` | edit written: the logger's lock is created by the first call at any level, and the start runs under it. Judge: 0.27 and 0.62. Not applied |
| 7 | the send wait needs "the service is stopping" as an exit, and the stop event is closed by `service.c` while senders can still wait on it. Linux has the same shape |
| 14 | belongs in the vchan library: wait on the xenstore watch for the server's entry, then connect once. A retry of the connect in the wrapper is what `ADR-qrexec` §1 forbids |
| 15 | stdin as an overlapped pipe whose write is one more object in the loop's wait, with reads from the vchan held back while it is pending. Four functions |
| 17 | the retry sits in the library's `VchanInitServer`; it needs xeniface to vanish between two calls |
| 18, 21 | keep serving the vchan after the local program has exited, until the remote's exit code or its close. Needs an end of its own, because the library's check for a dead peer is a stub, and has no consumer until item 7 of 1.4 is decided |
| 23 | after 18 and 21: in the client role, do not launch when the vchan has closed during the logon wait |
| 24 | an accept loop that waits on a stop event and is joined, not killed. The same rebuild as #10 |
| 25 | one lookup of session and token, handed from the wait to the launch. It settles which account runs: section 7.1 |
| 31, 33 | who may open and who may serve these pipes is the descriptor in `exec.c`: your decision |
| 32 | a flag for "the peer is gone", so that the writer flushes once on a disconnect the host asked for. It touches the stop path of the stock qubesdb daemon |
| 7.2 | a non-zero status on a daemon disconnect would have the service restarted. The code keeps 0 on purpose, and each restart opens the control channel again |
| 7.9 | not explained by the wrapper's source. The reader suspects the grant-map request's `OVERLAPPED` on the stack in xencontrol; unproven |
| item 7 of 1.4, 7.1 | yours; no edit touches either |

Read again and left as they are: #3's `exec.c` half, 7.6 (the three pipe ends are the only inheritable
handles by convention, not by enforcement) and the pid note of 7.8.

## 2. How to read this

**Programs and words.** The *agent* is `qrexec-agent.exe`, the SYSTEM service `QrexecAgent`. The
*wrapper* is `qrexec-wrapper.exe`: the agent starts one per call, and it carries that call's data and
starts the call's local program (the *child*). The *caller program* is `qrexec-client-vm.exe`, which a
program inside the qube runs to make a call. The *trigger pipe* is the named pipe through which the
caller program hands its request to the agent. The *control channel* is the agent's vchan to dom0's
qrexec daemon; a *data channel* is the vchan of one call. A wrapper in the *server role* serves a call
started inside the Windows qube (it creates the data channel and waits for the far side); a wrapper in
the *client role* serves a call into the Windows qube. A *pump* is one of the wrapper's two threads that
copy the child's stdout and stderr into the data channel.

**Evidence grades.**

| Grade | Meaning |
|---|---|
| READ | I read the cited lines at today's heads in this session. |
| FINDER | A workflow agent claimed it. Every line it quoted was checked by script against the source: 1732 quotes exact, 49 found at a moved line, 4 absent, 10 too short to check. |
| SECOND READER | A second agent re-derived the steps from the source and listed what it could not find. 33 of the 35 candidates have one; #34 and #35 are mine and have none. |
| MEASURED | Counted in captured logs under `scratchpad/` (3829 `*.log` files). |
| INFERRED | Follows from source plus a document. Not measured. |
| ASSUMPTION | Behaviour of Win32, Xen, the vchan libraries or dom0, taken from documentation or a reference copy. |

**Jev verdicts.** Each candidate was put to Jev as an extract built by script: the claim, the Windows
source around every cited line, and the Linux lines located for the same job. Three questions:

- `real`: can the claimed interleaving happen in the Windows code as shown? (`possible_as_shown`,
  `prevented_as_shown`, `claim_misreads_source`, `insufficient_evidence`)
- `impact`: if it happened, would a user see it? (`user_visible`, `internal_only`,
  `insufficient_evidence`)
- `reference`: does the Linux code shown give a guarantee the Windows code shown does not?
  (`diverges_from_reference`, `matches_reference`, `no_counterpart`, `insufficient_evidence`)

The floor is 0.70. Under the floor there is no verdict. A weak answer was asked once more with a wider
extract (28 of 35 candidates). The rule for the result: the first ask if it reached the floor, otherwise
the re-ask if it did, otherwise NO VERDICT. Two candidates sit on the floor with one ask above and one
below: #11 (`real` 0.71, then 0.64) and #35 (`real` 0.63, then 0.72). A verdict is about the extract Jev
was shown, not about the whole file. Appendix A has every verdict exactly as `jev.py` printed it; the
short forms in the text are the script's.

**Line origin.** `git blame` of the line at the candidate's primary site. "ours" followed by a commit
means the fork last wrote that line, which is not always the same as the fork introducing the behaviour.
Where I checked, the finding says which it is.

**Grouping.** Section 3 groups findings by what a person using the qube would see, not by the finders'
high, medium and low.

**Candidate numbers** are file names: the full claim, the second reader's steps and the extract Jev saw
are in `cands/<n>.claim.txt`, `cands/<n>.source.txt` and `cands/<n>.linux.txt` beside this report.

## 3. Findings, by what a user sees

### 3.1 A call made inside the qube does nothing, and the caller is told it succeeded

**The premise (READ, inherited 2012-2015).** `qrexec-client-vm.exe` closes its read pipe as soon as it
is connected (`qrexec-client-vm.c:106`), writes the request in eight writes (`:109-133`), closes the
pipe (`:136`) and returns `ERROR_SUCCESS` (`:140`). It cannot receive an answer and does not wait for
one. So whatever happens after the last write, a policy refusal by dom0 included, the program that made
the call sees exit code 0. The Linux caller stays connected until the agent answers and reads a refusal
as end-of-file (`agent/qrexec-client-vm.c:286`; guarantee rows 23, 48 and 73 in section 6). Each finding
below is a different way to lose the request after that point.

**#16. A request that arrives before the control channel exists is read, the caller is released, and
the request is thrown away.** The agent starts its pipe server at `qrexec-agent.c:2132` and only then
enters `WatchForEvents`, which waits for qubesdb (`:1461`, up to 360 s, `:136`) and creates the control
channel (`:1485`, up to 5 minutes). Until that returns, `g_DaemonVchan` is NULL; a request that arrives
is read in full, the client is disconnected (`:1931`), and `VchanSendMessage` refuses the trigger at
`:409-412` with an INFO line; its caller logs `sending trigger params to daemon failed` at ERROR
(`:1960`) and gives up. Nothing retries it. This is not a narrow race: every call in that window
is lost. The window is normally short at boot and as long as the two waits when qubesdb or xeniface is
slow, and it reopens whenever the service restarts.
Origin: the order is inherited (`:2132` 2024, `:1485` 2015); the send line is 70dd82e.
Linux: the trigger socket is created only after the control channel exists and the hello exchange
succeeded (`agent/qrexec-agent.c:417`; rows 21, 49, 70).
Evidence: READ. Captured logs: neither witness line occurs (`QGAGOINGDOWN the daemon vchan was closed
before` 0 times, `sending trigger params to daemon failed` 0 times).
Jev: real possible_as_shown 0.84 | impact user_visible 0.96 | reference diverges_from_reference 0.95.

**#2. `QpsRead` gives up on a disconnect flag it reads after its buffer check, and drops a complete
request that arrived in between.** `QpsRead` takes the client lock, fails to get the bytes it wants
(`pipe-server.c:927`), releases the lock (`:940`) and then tests `client->Disconnecting` (`:946`) with
no second look at the buffer. The reader thread can append the whole request and then, on the
end-of-file that follows at once (the caller closes right after its last write), set that flag
(`:742`). `QpsRead` returns `ERROR_BROKEN_PIPE` with the complete request in the buffer, and the agent
drops the call (`qrexec-agent.c:1810-1814`). The window on the consumer side is a few instructions wide
(`:940` to `:946`), so it needs that thread held off the CPU there.
The fork's own comment at `pipe-server.c:928-938` records the event: acceptance run 40297264818,
2026-10-26, `QpsRead: [3] peer gone mid-message: 426 of 0 bytes` on the 4-byte magic read. The comment
explains the line as two observations taken at different instants, which is right, and stops one step
short: the flag that made `QpsRead` give up is set by the reader thread only after its last append, so
when `QpsRead` returned, those 426 bytes were in the buffer. They were, most likely, the whole request,
and it was dropped. (INFERRED from the quoted line; I did not see that run's log.)
Origin: inherited (`:946`, 2015). Section 5.3 describes what two fork changes did to its trace.
Linux: a request that arrived whole is served even if the client hangs up right after writing it
(`agent/qrexec-agent.c:869`; row 42).
Evidence: READ for the code; INFERRED for the event.
Jev: real NO VERDICT (possible_as_shown 0.63, re-ask 0.57) | impact user_visible 0.86 | reference NO
VERDICT (diverges_from_reference 0.44, re-ask 0.39).

**#20. A request over 4096 bytes survives only if the consumer drains in time, and a single field over
4096 bytes can never be delivered.** The reader thread reads whatever is in the pipe and appends it to a
queue whose capacity is the 4096 the agent passes (`qrexec-agent.c:2116-2118`); when an append does not
fit it logs `read buffer full` and disconnects the client (`pipe-server.c:444-450`, beside an inherited
`FIXME: block here until there's space`). `QpsRead` needs a field whole in that queue, so a field
longer than 4096 bytes cannot be read at all, and a shorter request is dropped whenever more than 4096
unread bytes pile up. The size checks accept far more: service name up to 65000 bytes
(`qrexec-client-vm.c:79`, `qrexec-agent.c:1839`), command line up to 65536 bytes (`:1903`). Whether the
caller sees an error depends on how much it still had to write when the agent disconnected.
Origin: the queue and the reader are inherited; the 65000-byte service name is 70dd82e (at the base the
service name was a fixed field and only the command line could exceed the queue).
Linux: reads only the bytes the request still needs, into a buffer sized for the whole request
(`agent/qrexec-agent.c:870`; row 41).
Evidence: READ. Captured logs: `read buffer full` occurs 0 times.
Jev: real possible_as_shown 0.85 | impact user_visible 0.97 | reference diverges_from_reference 0.83.

**#9. A new client is published before its owner holds a reference, so its own reader thread can free
it while the accept thread is still using it. This is the one finding with a recorded crash behind
it.** `QpsConnectClient` inserts the client with a count of 0 (`pipe-server.c:620`), resumes the reader
and writer threads (`:629-630`), and only then takes the host's reference (`:657`) and passes
`client->Id` to the agent (`:658`). The reader takes a reference of its own; when its read ends, its
release at `:424` returns the count to 0 and frees the client (`:320-333`) unless the writer or the
host got a reference in first. The accept thread then increments a counter inside freed memory and
hands the agent an id read from freed memory. The agent's first read for that id fails with
`ERROR_NOT_CONNECTED`, which since 598903e is logged at INFO as `departed before sending its request
header ... nothing was dispatched` (`qrexec-agent.c:1810-1811`), and a request that had arrived whole
is gone. If the free lands between the two resumes, the second resume fails on a handle read from
freed memory, `QpsConnectClient` returns the error and the accept loop ends (`:899-901`), which is
section 3.2. It needs the accept thread held off between `:629` and `:657` until the reader has seen
the caller's end-of-file; the caller's remaining life at that point is at most one `Sleep(10)`
(`:1154`) and eight small writes.

The recorded event (MEASURED: `scratchpad/crash-excerpt.log:11-16`, agent 4.3.36.958, a test guest
about 28 seconds after boot):

```
[20261014.150653.055-3768:3960-I] QpsConnectClient: [2] (000001D9CB4B6A30) connected (1 total)
[20261014.150653.117-3768:6752-W] QpsDisconnectClientInternal: [2] not connected
[20261014.150653.171-3768:6768-E] ErrUEF: Unhandled exception c0000005 at 00007FFFF52E54A8, flags: 0
[20261014.150653.220-3768:2396-E] PipeClientThread: QpsRead(magic) failed with error 0x8ca: This network connection does not exist.
[20261014.150653.283-3768:6768-E] ErrUEF: Parameter 0: 0000000000000000
[20261014.150653.305-3768:6768-E] ErrUEF: Parameter 1: 0000000000000018
```

Read against the code that ran that day (INFERRED; the connect and counting code was the base's, READ
with `git show R4.3.0:src/pipe-server.c`; the one patch on the file by then changed log lines only).
Client 2 was in the list at .055 and no longer in it at .117, when a disconnect looked it up and found
nothing. The only thing that removes a client from the list is a release that reaches 0 (base
`:257-273`, the single `RemoveEntryList`). A worker thread calls that disconnect only after releasing
a reference it held (base `:303-304`, `:320-321`), so thread 6752 was the reader, and its own release
was the one that reached 0: neither the host's reference (base `:517`, taken after the lock is dropped
at `:509`) nor the writer's had been counted. The writer thread, 6768, then looked itself up, got NULL
and read `WritePipe`, offset 0x18, through it. Thread 2396 is the agent's per-client thread, started
by the connect callback, so the accept thread did carry on past the free. Had the host's reference
been counted before the reader's release, the client would still have been in the list and the `not
connected` line could not have been written.

What the fork did about it (READ; two patches of 2026-10-14, now inside `winutils` e25cbc1). First,
NULL checks at the top of both thread entries (`:376-381`, `:472-477`); these are what stop the crash.
Second, a rewrite of `QpsConnectClient` that creates both threads suspended and resumes them after the
insert, so that a thread cannot "run before its own client existed" in the list (comment at
`:551-560`). In the base that could not happen on the success path either: the base held the server
lock from before the first `CreateThread` until after the insert (base `:449-509`), and the lookup
takes the same lock (base `:204`). Only the error returns after a thread had been created were exposed.
The rewrite's commit message does say the measured crash "came from a client UNLINKED by a disconnect
mid-run", but the disconnect in the log found nothing to unlink; what unlinked the client was the
early release. The order that allows it, publish at 0 and take the reference afterwards, went through
the rewrite unchanged, and the register closed the crash as QREXECAGENTAV, "FIXED IN SOURCE - unbuilt,
unrun on a guest".

Captured logs since then: the `not connected` line occurs once (the crash itself); `not in the client
list`, `worker threads could not be resumed` and `departed before sending its request header` occur 0
times. No second instance is recorded. With the NULL checks in place a repeat would leave two WARNING
lines and that INFO line, and no crash.
Origin: the order is inherited (2015); the fork rewrote the function and kept it.
Linux: no counterpart; a client connection has one owner and no worker threads.
Evidence: READ for today's code and for the base; MEASURED for the log; INFERRED for the chain.
Jev (asked on the code alone, before I found the crash log): real possible_as_shown 0.83 | impact
user_visible 0.98 | reference NO VERDICT (no_counterpart 0.29, re-ask 0.51).

**#28. The client lookup takes its reference after leaving the lock that guards the free**
(`pipe-server.c:280` leaves the lock, `:285` increments). Same family as #9 at another site; its
claimed actors are the qubesdb daemon's stop path, not qrexec. Origin: inherited (2015). Evidence: READ.
Jev: real NO VERDICT (possible_as_shown 0.57, re-ask 0.36) | impact user_visible 0.96 | reference NO
VERDICT.

### 3.2 Every later call made inside the qube hangs

**The premise (READ, inherited 2015-2024).** One thread runs the accept loop (`qrexec-agent.c:2132`,
`pipe-server.c:836-902`). It is not in the main loop's wait set, nothing restarts it, and the service
looks at it only when stopping (`qrexec-agent.c:2149`). Once it is parked or gone, no listening instance
of the trigger pipe is created again, and a later caller waits in
`WaitNamedPipe(..., NMPWAIT_WAIT_FOREVER)` (`pipe-server.c:1108`; ASSUMPTION: Windows answers "pipe
busy" while the old instance exists). Calls from dom0 keep working. Linux accepts on a non-blocking
listening socket inside its main loop, and an error on one client closes that client only
(`agent/qrexec-agent.c:938-943`; rows 28, 45, 47, 53).

**#34 (mine, no second reader). A caller that opens the second pipe and has closed it again before the
accept thread reaches `ConnectNamedPipe` leaves that thread retrying the same pipe instance every 10 ms
for ever.** The loop at `pipe-server.c:889-895` counts only success and `ERROR_PIPE_CONNECTED` as
connected. Microsoft's ConnectNamedPipe page says a client that connected and already closed its handle
yields `ERROR_NO_DATA`; microsoft/go-winio handles that case explicitly ("If the connection was
immediately closed by the client, try again"), with a new instance per try. Here the same instance is
retried, so the answer never changes, the request the caller wrote is never read, and the accept thread
never returns to create the next listening instance. An ordinary caller is enough: its life after
opening the second pipe is one `Sleep(10)` (`:1154`) plus eight small writes, so the accept thread has
to be delayed by a little over 10 ms between `:882` and `:892`. The agent pins itself to one CPU
(`qrexec-agent.c:2217`, a493b63), so every other agent thread competes for that CPU.
Origin: inherited loop; the pin is the fork's. Evidence: READ for the code; the `ERROR_NO_DATA` step is
an ASSUMPTION from Microsoft's page and was not measured.
Jev: real NO VERDICT (possible_as_shown 0.45, re-ask 0.37; `claim_misreads_source` got 0.22 and 0.26) |
impact user_visible 0.91 | reference diverges_from_reference 0.71 (re-ask). The judge did not confirm
this one, and it is my own candidate.

**#10. A caller that dies between its two opens parks the accept thread for ever.**
`ConnectNamedPipe(readPipe, NULL)` at `:892` has no timeout and no stop signal; the inherited comment at
`:887` says `FIXME: this blocks forever if the client never connects here`. Evidence: READ.
Jev: real NO VERDICT (0.65, re-ask 0.57) | impact user_visible 0.92 | reference
diverges_from_reference 0.76.

**#12. A caller that disappears before the server writes the second pipe's name ends the accept
thread.** `WriteFile` at `:877` or `:882` fails, `QpsMainLoop` returns (`:879`, `:884`), the thread ends
(`qrexec-agent.c:2027`), both pipe handles leak, and the service keeps running without a pipe server.
The same exit exists at `:858-861`. Evidence: READ; that the write fails is an ASSUMPTION about the
pipe file system.
Jev: real NO VERDICT (0.51, re-ask 0.56) | impact user_visible 0.85 | reference
diverges_from_reference 0.77 (re-ask).

**#22. The caller program retries the second pipe for ever on "not found".** `QpsConnect` loops on
`ERROR_FILE_NOT_FOUND` with a 10 ms sleep and no bound (`pipe-server.c:1141-1155`), so a caller that
connected just before the agent went away (a tools update, a service restart) spins for ever instead of
failing. Variant: neither `CreateNamedPipe` result is checked (`:838`, `:866`); if the second one fails
the accept thread loops for ever at `:892` on an invalid handle. Evidence: READ.
Linux: one connect on one socket, which fails at once when the agent is not there
(`agent/qrexec-client-vm.c:66`; row 72).
Jev: real possible_as_shown 0.73 | impact user_visible 0.98 | reference diverges_from_reference 0.84.

**#11. A disconnect kills worker threads it cannot unblock, and a kill inside the worker's exit path
orphans a lock.** `CancelIo` is called from the disconnecting thread (`:751`, `:773`); by Microsoft's
documentation it cancels only I/O issued by the calling thread, so a reader blocked in `ReadFile` is
untouched and is killed with `TerminateThread` after 100 ms (`:776-780`; the inherited comment says
"this may leak memory or do other nasty things but should never happen"). The usual result is a leaked
reference. If the kill lands while the worker holds `Server->Lock` (`:316-337`), the pipe server stops
answering for good.
Evidence: READ. MEASURED: the kill line (`reader thread didn't terminate in time, killing it`) is in
captured qubesdb-daemon guest logs 4 times (2026-10-09, twice on 10-10, 10-23); it is in no qrexec-agent
log. The orphaned lock was not observed.
Jev: real possible_as_shown 0.71 (re-ask 0.64) | impact user_visible 0.98 | reference NO VERDICT
(no_counterpart 0.65, re-ask 0.69).

**#31 and #33. The pipe names are not the agent's alone.** The pipe's descriptor grants Everyone
read, write and the right to create further instances (`exec.c:416`), the server never asks to be the
first instance (`pipe-server.c:838-845`, `:866`), and the process id read on the first pipe (`:858`) is
never checked on the second. Another process in the qube can therefore take the second pipe of someone
else's call, or listen on the trigger name and receive or withhold other accounts' requests, while the
caller program reports success. It stays inside one qube. Evidence: READ for the three facts; which
instance Windows hands a connecting client is an ASSUMPTION.
Linux: one accepted socket per client, and exactly one listener on the name (rows 46, 71).
Jev #31: real NO VERDICT (0.65, re-ask 0.67) | impact user_visible 0.88 | reference
diverges_from_reference 0.71 (re-ask). Jev #33: real NO VERDICT (0.39, re-ask 0.43) | impact
user_visible 0.85 | reference diverges_from_reference 0.77.

### 3.3 One failing call takes the agent down for every call

**The premise (READ).** `WatchForEvents` leaves its loop on any non-success from `HandleDaemonMessage`
(`qrexec-agent.c:1675-1680`, inherited 2022). `ServiceCleanup` then closes the control channel
(`:2145`), the worker returns the error (`:2163`) and the service ends with it (`service.c:247`). On
the dom0 side the daemon terminates every qrexec client of the qube and aborts pending requests
(`daemon/qrexec-daemon.c:1605-1625`, reference copy). The installer arms a restart after 5 s, 15 s and
then every 60 s (`packaging/setup/Install-QwtImproved.ps1`, `Set-QubesServiceRecovery`), so the outage
is the restart delay plus dom0's reconnect, and every connection in flight is cut. The wrappers are not
killed; they run on, unknown to the new agent instance. Before two fork changes (7bcaad5 in the agent,
which made the worker return its error, and the service exit-code patch of 2026-10-03, now in `winutils`
e25cbc1, which made `SvcMain` report it) the service ended with code 0 on these paths and stayed
stopped for the rest of the boot, so the restart is an improvement; what remains is that a per-call
error is fatal at all.

Ways in:

- **#3. A wrapper launch that fails.** Every wrapper is launched into the console session, even for a
  SYSTEM service (`exec.c:320-322`). `exec.c:133-137` reads the console session once and returns
  `ERROR_NOT_SUPPORTED` when there is none; `HandleExec` returns `StartChild`'s error unchanged
  (`qrexec-agent.c:1346-1361`). ASSUMPTION (Microsoft's WTSGetActiveConsoleSessionId page): the call
  returns 0xFFFFFFFF while the console session is being attached or detached, so a call from dom0 that
  arrives during a logoff, a logon or a session switch takes the agent down. Evidence: READ; captured
  logs: `No active console session` occurs 0 times.
  Jev: real NO VERDICT (possible_as_shown 0.36, re-ask 0.39; `claim_misreads_source` 0.23 and 0.26) |
  impact user_visible 0.89 | reference NO VERDICT.
- **A full connection table (190c190).** `register_vchan_connection` returns `ERROR_NO_MORE_ITEMS` when
  all 128 slots are taken (`qrexec-agent.c:504-536`), `StartChild` passes it on (`:1107-1114`), and the
  main loop ends. The comment at `:525-529` says this "makes the exec fail visibly on the one call that
  cannot be tracked, instead of silently degrading the whole subsystem". The wrapper of that call has
  already been started and keeps running. Slots stay taken by wrappers that never exit (#8, #15).
  Evidence: READ; captured logs: `No free slot for child` occurs 0 times.
  Linux: a full table is logged and the loop keeps serving (`agent/qrexec-agent.c:541`; rows 37, 100).
- **#13. A reply for a request id the agent does not know.** `HandleServiceConnect` returns
  `ERROR_INVALID_PARAMETER` (`:1185-1190`). Ids restart at 1 with each agent instance (`:80`,
  `:1925-1926`) and are matched by string alone (`:1135`), so the claim is that a reply to a
  pre-restart request is either taken by an unrelated new request or stops the freshly restarted
  agent. The second reader found that dom0 aborts pending requests when the agent restarts
  (`daemon/qrexec-daemon.c:1620-1625`), which undercuts the scenario. What stands on its own: Windows
  stops on an unknown id, Linux logs and ignores it (`agent/qrexec-agent.c:712`; rows 36, 78, 99).
  Captured logs: `not pending` occurs 0 times.
  Jev: real NO VERDICT (possible_as_shown 0.31, re-ask insufficient_evidence 0.24) | impact
  user_visible 0.97 | reference NO VERDICT.
- **#6. A trigger can enter the control channel ahead of the agent's hello.** Same root as #16, in the
  later window between `:1485` (the ring exists) and `:1629` (the hello is sent, only after dom0
  connects; `daemonConnected` is a local variable no other thread can read). A trigger sent in that
  window passes the test at `:409` and goes into the ring first. The claim is that dom0 then rejects
  the handshake because the first message is not a hello (`daemon/qrexec-daemon.c:246`), the agent sees
  the disconnect and stops with exit code 0, and exit code 0 is not restarted (see section 7). It
  rests on two ASSUMPTIONS: the shipped vchan library reports a server ring as open before a client
  connects, as the reference copy does, and dom0's daemon matches the reference copy.
  Jev: real NO VERDICT (0.53, re-ask 0.61) | impact user_visible 0.86 | reference NO VERDICT.

For comparison, one exit that is not a divergence: an unknown message type also ends the Windows loop
(`:1426-1427`), and the Linux agent exits there too (`agent/qrexec-agent.c:755-758`).

Captured logs: `HandleDaemonMessage failed` occurs 0 times, and all 73 distinct `Shutting down, status`
lines of the agent say status 0.

### 3.4 Wrong exit code, truncated output, or a command run for nobody

**#1. A stdin write that fails because the child has exited ends the wrapper's loop before the
child-exit arm runs.** `EventLoop` serves the vchan before the child's handle when both are signalled
(`qrexec-wrapper.c:1983`, `:2037-2058`). `HandleRemoteData` writes inbound stdin to the child
(`:1165`); if the child has exited the write fails, the loop ends with that error, and the arm that
waits for the pumps and sends the real exit code (`:2062-2169`) never runs. In the client role the
cleanup then sends the Win32 error as the exit code (`:2422-2434`; the caller sees its low byte, 232 or
109), and whatever the pumps still held is dropped when the vchan closes. In the server role no exit
code is sent at all (`:1094-1095`), so there the effect is the cut output.
Origin: inherited (2015); the line at `:2434` is 54999a1 because the block moved.
Linux: on child exit the stdin side is closed at once, and inbound data for a closed stdin is discarded
by a check made right before the write (`libqrexec/process_io.c:216`, `remote.c:85`; rows 12, 13).
Evidence: READ. MEASURED: the failing write is logged once, in
`scratchpad/gweck-logs-1027/Qubes Logs/qrexec-wrapper-20261027.log:167-172`, pid 5468, a server-role
wrapper, 15 seconds after its start: `HandleRemoteData: writing stdin data failed with error 0xe8`.
That is the first half of the mechanism in a real run; what the far side received is not in the log.
Jev: real NO VERDICT (possible_as_shown 0.65, re-ask 0.67) | impact user_visible 0.98 | reference
diverges_from_reference 0.87 (re-ask).

**#4. After 120 seconds the exit code overtakes output a pump still holds.** After the child exits,
`EventLoop` computes one deadline (`:2101`) and waits for the pumps; nothing extends it when a pump is
making progress or is waiting for ring room. If the far side is connected but reading slowly for two
minutes, the wait expires (`:2114`), and `VchanSendExitCode` sends the two end-of-file messages and the
exit code (`:1099-1103`). Since d228a03 a pump waiting for room does not hold the send lock (`:846`),
so those three small messages go into the ring ahead of the chunk the pump holds and of everything
still in the pipe. The caller gets a short output under the child's normal exit code.
Origin: the fork's (ac33bc9 introduced the wait for the pumps, 224cb46 is the current line, d228a03
released the lock). The fork's comments (`:47-51`, `:2090-2094`) record that hitting the backstop
truncates, but expect it only when a surviving grandchild holds a pipe; a slow reader reaches the same
arm. Before ac33bc9 the exit code was sent without waiting for the pumps at all, so the common case
got better.
Linux: the exit code is sent only when stdin, stdout and stderr have all reached end-of-file, with no
deadline (`libqrexec/process_io.c:222`; rows 1, 87).
Evidence: READ for `:2098-2116` and `:1094`; the rest FINDER and SECOND READER. Captured logs: the
drain-expiry line occurs 0 times.
Jev: real NO VERDICT (possible_as_shown 0.64, re-ask 0.63) | impact user_visible 0.97 | reference
diverges_from_reference 0.93.

**#15. The wrapper's only event thread writes child stdin synchronously.** The write at `:1165` is a
blocking `WriteFile` on a 64 KiB pipe, on the thread that owns the wait at `:1983`. A child, or a
grandchild holding the inherited read end, that does not read its stdin parks that thread where neither
the far side hanging up, nor the child's exit, nor a stop can wake it. The wrapper and its slot in the
agent stay until the reader drains or dies; on logoff or shutdown such a wrapper always takes the
3-second timeout and exits with the vchan unclosed.
Origin: inherited (2015).
Linux: a stdin write never blocks the loop; what the child does not take is buffered and no more is
read from the vchan until it is flushed (`libqrexec/remote.c:53`; row 14).
Evidence: READ.
Jev: real possible_as_shown 0.87 | impact user_visible 0.98 | reference diverges_from_reference 0.92.

**#18 and #21. In the server role the wrapper closes the data channel as soon as its local program has
exited.** Two finders reported the same behaviour at two sites. `VchanSendExitCode` returns at once in
the server role (`:1094-1095`, inherited 2015), nothing waits for the far side's exit code
(`g_exitCodeReceived` is read only in the no-local-process loop, `:2349`), and cleanup closes the vchan
(`:2462-2464`). So for a call started inside the qube, the far side's remaining output and its exit
status are never read. The stronger claim, that data the far side had not yet read is lost because the
ring pages are given back, rests on an unverified ASSUMPTION about xeniface.
Linux: the calling side closes only when the local process has finished and the remote exit code has
arrived (`libqrexec/process_io.c:232`; rows 2, 62). The second reader of #21 noted that the role
mapping behind this comparison was not established.
Jev #18: real NO VERDICT (0.36, re-ask 0.35) | impact user_visible 0.74 | reference
diverges_from_reference 0.85. Jev #21: real NO VERDICT (0.47, re-ask 0.19) | impact user_visible 0.85
| reference NO VERDICT (0.61, re-ask 0.68).

**#23. The wrapper connects the data channel first and only then waits up to 90 seconds for a logon; it
then runs the command without looking at the channel again.** `InitVchan` runs at `:2295`,
`QwWaitForInteractiveLogon` polls the console session once a second and waits on the stop event only
(`:462-519`), and `StartChild` launches as soon as a user appears (`:566`, `:624-640`). A command whose
caller gave up during the wait still runs when someone logs on, with its output going nowhere.
Origin: the fork's (9ad4dfc; the line is 9cc4bce, a rename).
Linux: the wait for a session happens in the agent before any data channel is connected, and the far
side's hello is read immediately before the service is started (`agent/qrexec-agent.c:631`,
`qrexec-agent-data.c:236`; rows 38, 64, 65).
Evidence: READ for `:462-519` and `:556-606`.
Jev: real NO VERDICT (possible_as_shown 0.69, re-ask 0.61) | impact user_visible 0.97 | reference
diverges_from_reference 0.85.

**#8 and #5. A server-role wrapper waits for its data client with no bound.** `libvchan_wait` at
`:1892` has no timeout and no stop event, and runs before the child exists (inherited 2015). If the far
side never connects, the wrapper, its slot in the agent and its port in dom0 are held until reboot (#8).
#5 claims a worse consequence: the stale xenstore node of such a wrapper is found by the next call to
the same qube when dom0 hands the port out again, so that call's far side is wired to the old wrapper
and runs the old request's local command. The second reader could not establish that dom0 frees the
port in that state or that the far side reads the node before the new wrapper overwrites it. If #5 is
real it is the worst outcome in this report, and it is the least established.
Linux: the wait for the data channel is bounded at 120 s in both roles (`qrexec-agent-data.c:219`,
`:373`; rows 11, 61).
Jev #8: real NO VERDICT (0.41, re-ask 0.39) | impact user_visible 0.85 | reference
diverges_from_reference 1.00. Jev #5: real NO VERDICT (insufficient_evidence 0.51, re-ask 0.44) |
impact user_visible 0.91 | reference diverges_from_reference 0.99.

**#14. The client-role connect gives up after about a second, although the server it connects to is
created only after the exec message was sent.** The Windows vchan client waits twice for 500 ms
(`upstream/ro/qubes-core-vchan-xen/windows/src/init.c:138`, `:147`, reference copy, READ); Linux waits
120 s (row 63). A loaded dom0 or a Windows caller that must first start its own wrapper can be later
than that; the call then fails with one `QGAVCHANFAIL` line and nothing runs. MEASURED: `QGAVCHANFAIL`
occurs on 71 distinct lines in 22 captured files. The source attributes those to a far side that left;
this ordering is a second way to reach the same line, and the line cannot tell the two apart.
Jev: real NO VERDICT (0.51, re-ask 0.48) | impact user_visible 0.96 | reference NO VERDICT.

For scale, the wrapper's own loss line (`vchan already closed with N byte(s) of ... still to send`) is
in captured guest logs 7 times: one 4096-byte chunk of output, four hellos and two exit codes, all
where the far side had closed first.

### 3.5 A service stop that hangs

**#17. A stop that lands while the control channel is being created goes unseen for up to five
minutes.** `VchanInitServer` retries on `Sleep(1000)` while xeniface answers "not supported" and never
looks at the stop event (`vchan-common.c:44-52`; called at `qrexec-agent.c:1485` with a 5-minute
budget). `SvcMain` waits for the worker with no bound (`service.c:215`), so the service sits in
STOP_PENDING and whoever asked for the stop times out first.
Origin: inherited (2015).
Linux: a termination request during start-up takes effect at once (`agent/qrexec-agent.c:1049`;
rows 33, 34).
Evidence: READ.
Jev: real possible_as_shown 0.89 | impact user_visible 0.97 | reference diverges_from_reference 0.75.

**#7. A full-ring send made on the main loop's own thread can be ended only by a teardown that the
same thread performs.** `release_connection` sends `MSG_CONNECTION_TERMINATED` from the main loop
thread (`:538-557`). `VchanSendMessage` leaves its wait only on room, on the far side closing or on the
agent's own teardown (`:389-478`), and never looks at the stop event; `ServiceCleanup` is called only
from that same thread (`:1703`, `:2145`). If dom0's daemon stops draining while the ring still reads
open, the next wrapper exit parks the thread, a stop hangs, and no dom0 request is read. A variant at
the hello: the main loop holds the daemon lock (`:1623`) when it calls `VchanSendHello` (`:1629`), so
the single release inside the wait (`:442`) does not free it; that needs the ring to be full already at
connect, which needs #6.
Evidence: READ. It needs a dom0 daemon in a state I have not shown to exist.
Jev: real NO VERDICT (0.41, re-ask 0.37) | impact user_visible 0.98 | reference NO VERDICT.

**#29. The service control handler and `SvcMain`'s teardown share `g_Service` with no serialisation.**
`SvcStop` runs on the dispatcher thread (`service.c:125-132`); `SvcMain` reports STOPPED, closes the
handles, frees `g_Service` and sets it to NULL (`:247-254`). A stop that arrives just as the worker
ends on its own writes the status struct from two threads and can use the freed pointer: an access
violation in the agent during stop, or STOP_PENDING reported after STOPPED.
Origin: inherited. Evidence: READ.
Jev: real possible_as_shown 0.84 | impact user_visible 0.98 | reference no_counterpart 0.93.

**#24. Every stop kills the accept thread with `TerminateThread`.** The loop has no way to stop, so
the 1-second wait at `qrexec-agent.c:2149` always times out on an ordinary stop and `:2150` kills the
thread (inherited; the comment at `:2146` says `FIXME: pipe server doesn't have the ability for
graceful stop`). If a caller connects at that moment and the thread dies inside the logger's lock, the
worker's next log line (`:2156`) blocks and the service never reports STOPPED. The second reader notes
the thread is far more likely to be killed where it holds no lock.
Jev: real NO VERDICT (0.47, re-ask 0.56) | impact user_visible 0.96 | reference no_counterpart 0.89.

### 3.6 The wrong account, or work confined to one CPU

**#25. The console session and its token are looked up twice.** `QwWaitForInteractiveLogon` reads the
session, its token and its user name (`:464-473`) and `StartChild` compares and logs the name
(`:594-599`); `QwCreateProcessAsSessionUser` then reads the session and token again (`:354-357`) and
launches on whatever that returns. A logoff or a switch in between makes the log name one account while
the service runs as another, or fails the launch just after the wait reported a user. The comparison at
`:594` only warns and never gates the launch, so no new boundary is crossed.
Origin: the fork's (e0db61a). Evidence: READ for `:462-481` and `:556-606`.
Jev: real possible_as_shown 0.93 | impact NO VERDICT (user_visible 0.49, re-ask 0.55) | reference NO
VERDICT.

**#30. The service process is created running and its CPU mask is widened afterwards.** The agent pins
itself to one CPU (`qrexec-agent.c:2217`), the wrapper inherits the mask, and the child is created
without `CREATE_SUSPENDED` (`qrexec-wrapper.c:420-421`) and widened later (`:726-727`). Anything the
child starts in between, `cmd /c` launching the real program for instance, keeps the one-CPU mask for
life, and nothing is logged because the widening succeeds on the process it names.
Origin: the fork's (a493b63). Evidence: READ for `:721-728` and `:2217`.
Linux: everything the service must start with is set in the forked child before exec
(`qrexec-agent-data.c:179`; row 20).
Jev: real possible_as_shown 0.72 (re-ask 0.79) | impact NO VERDICT (user_visible 0.26, re-ask 0.34) |
reference NO VERDICT.

### 3.7 Confined to the log, or outside qrexec's own calls

**#35 (mine, no second reader). The logger starts itself on the first line that passes the level
filter, with no lock.** `_LogFormat` filters by level (`log.c:836`) before the unlocked
`if (!g_LoggerInitialized) LogInitDefault(NULL)` (`:839-840`); `LogStart` initialises the logger's
critical section (`:468-470`) and sets the flag only at `:604`. In a client-role wrapper at the default
level, no line passes before the pumps exist: the first line is DEBUG (`qrexec-wrapper.c:2292`), the
library's records are held and replayed at DEBUG (`:1915`, `:1531`, 2d2b55d), and `Running ...` is DEBUG
since 933d01d. So the first passing line can come from two threads at once, the usual pair being the
closing `RINGPEER` line on the main thread (`:2456-2461`, d63b88b) and a pump's error line (`:988`). The
ordinary outcome stays in the log: two birth lines for one process, a line sent to stderr, a stray
byte-order mark, a leaked handle. The narrow outcome, the lock initialised again while held so that a
later log call waits for ever, needs one thread descheduled between `:468` and `:470`.
Origin: the unlocked start is inherited (2024); the fork's three log changes made it reachable here.
Linux: logging is set up by the first statement of `main` and the programs have no threads.
Evidence: READ. MEASURED: none of 242 distinct wrapper birth lines in captured logs is one process's
second.
Jev: real possible_as_shown 0.72 (re-ask; first ask 0.63) | impact user_visible 0.74 | reference NO
VERDICT.

**#19. The reader and a pump update the same notify byte without a common lock.** The reader arms its
data notify outside the send lock (`:2037`) while a pump arms its room notify under it (`:813`); the
reference copy of the vchan library does that with a plain `|=` in non-MinGW builds
(`upstream/ro/qubes-vmm-xen-windows-pvdrivers/src/libxenvchan/io.c:75`, READ). A lost arm would leave
`EventLoop` in an infinite wait. It cannot happen while the wrapper really runs on one CPU with a
single or-to-memory instruction, which is what the pin of a493b63 gives; it becomes possible when the
pin was not applied (`running UNPINNED`, `qrexec-agent.c:2220`).
Jev: real NO VERDICT (prevented_as_shown 0.11, re-ask possible_as_shown 0.17) | impact user_visible
0.89 | reference diverges_from_reference 0.71.

**#27. `Disconnecting` is tested and set with no lock** (`pipe-server.c:736`, `:742`), so the reader
on end-of-file and the host's disconnect can both run the full teardown of one client: double
`CloseHandle` on four handles and the disconnect callback delivered twice. Mostly internal. READ.
Jev: real possible_as_shown 0.81 | impact NO VERDICT (user_visible 0.50, re-ask 0.50) | reference NO
VERDICT.

**#32. Bytes queued by `QpsWrite` are thrown away when a disconnect lands before the writer thread's
next poll**, although `QpsWrite` returned success (`:497` leaves on the flag before `:507` looks at the
queue). qrexec-agent never calls `QpsWrite`; the stock qubesdb daemon does, and loses the error reply it
writes just before dropping a client. READ.
Jev: real possible_as_shown 0.91 | impact user_visible 0.97 | reference diverges_from_reference 0.89.

**#26. The no-local-process loop in `wmain` leaves on a closed vchan without reading what is still in
the ring** (`:2332-2336`, inherited 2021), so the far side's exit code is seen or missed depending on
when the close is noticed. `EventLoop` got the drain in e5e94b8; this sibling loop did not. Internal as
far as the finder could trace: nothing reads the wrapper's own exit status in that mode.
Jev: real possible_as_shown 0.72 | impact NO VERDICT (internal_only 0.33, re-ask 0.38) | reference
diverges_from_reference 0.88.

## 4. All 35 candidates in one table

[What was done about each one for release 4.3.44, and which were reproduced on a guest: section 1.6.]

Generated by script from the candidate files and the Jev answers. "found by" names the finder unit and
round (`r1`, `r2`, `rmain` for the two I added); "merged" counts claims at the same site and class that
a script folded into this one (10 claims folded into 9 candidates). **none** means no verdict, with the
leading option in brackets.

| # | class | site | line origin | found by | real | impact | reference | claim |
|---|---|---|---|---|---|---|---|---|
| 1 | race | `qrexec-wrapper.c:2039 EventLoop` | inherited | wrapper r1 +1 merged | **none** (possible 0.65; re-ask possible 0.67) | visible 0.98 | diverges 0.87 | A stdin write that fails because the child has exited ends EventLoop before the child-exit arm runs: the Win32 write error is sent as the exit code an |
| 2 | toctou | `pipe-server.c:946 QpsRead` | inherited | vchan-pipe r1 +1 merged | **none** (possible 0.63; re-ask possible 0.57) | visible 0.86 | **none** (diverges 0.44; re-ask diverges 0.39) | QpsRead gives up on a disconnect flag read after its buffer check, dropping a complete request that arrived in between |
| 3 | toctou | `exec.c:133 CreatePipedProcessAsUser` | inherited | proc-service r1 | **none** (possible 0.36; re-ask possible 0.39) | visible 0.89 | **none** (no-counterpart 0.64; re-ask no-counterpart 0.44) | The agent reads the console session once and launches the wrapper into it; a session that is detached or replaced in that window fails the launch, and |
| 4 | race | `qrexec-wrapper.c:2114 EventLoop` | ours 224cb46 | wrapper r2 | **none** (possible 0.64; re-ask possible 0.63) | visible 0.97 | diverges 0.93 | The drain deadline is absolute: after 120 s the exit code overtakes output a pump still holds, so a caller that is merely slow gets a truncated transf |
| 5 | toctou | `qrexec-wrapper.c:1892 InitVchan` | inherited | cross-process r2 | **none** (insufficient 0.51; re-ask insufficient 0.44) | visible 0.91 | diverges 0.99 | A server-role wrapper nobody connected to keeps its xenstore node published forever; when the target's daemon hands the port out again, the next call' |
| 6 | race | `qrexec-agent.c:1956 PipeClientThread` | ours 70dd82e | agent r1 | **none** (possible 0.53; re-ask possible 0.61) | visible 0.86 | **none** (diverges 0.56; re-ask diverges 0.53) | A guest-initiated trigger can enter the daemon ring before the agent's MSG_HELLO, because the pipe server runs before the control channel is connected |
| 7 | deadlock | `qrexec-agent.c:548 release_connection` | inherited | agent r1 | **none** (possible 0.41; re-ask possible 0.37) | visible 0.98 | **none** (diverges 0.44; re-ask diverges 0.29) | A full-ring send made on the main loop's own thread can only be ended by a teardown that this same thread performs, and never looks at the stop event  |
| 8 | deadlock | `qrexec-wrapper.c:1892 InitVchan` | inherited | wrapper r1 +1 merged | **none** (possible 0.41; re-ask possible 0.39) | visible 0.85 | diverges 1 | Server-role wrapper waits forever for the data client inside InitVchan: an INFINITE wait on the vchan event with no timeout and no stop event, during  |
| 9 | race | `pipe-server.c:657 QpsConnectClient` | inherited | vchan-pipe r1 | possible 0.83 | visible 0.98 | **none** (no-counterpart 0.29; re-ask no-counterpart 0.51) | QpsConnectClient keeps using the client after publishing it with RefCount 0, so the reader thread can free it first |
| 10 | deadlock | `pipe-server.c:892 QpsMainLoop` | inherited | vchan-pipe r1 +1 merged | **none** (possible 0.65; re-ask possible 0.57) | visible 0.92 | diverges 0.76 | A client that never opens the second pipe parks the only accept thread forever, and later clients wait forever behind it |
| 11 | deadlock | `pipe-server.c:780 QpsDisconnectClientInternal` | inherited | vchan-pipe r1 | possible 0.71 | visible 0.98 | **none** (no-counterpart 0.65; re-ask no-counterpart 0.69) | Disconnect kills worker threads that CancelIo cannot unblock; a kill landing in the worker's exit path orphans Server->Lock or client->Lock |
| 12 | race | `pipe-server.c:877 QpsMainLoop` | inherited | cross-process r1 | **none** (possible 0.51; re-ask possible 0.56) | visible 0.85 | diverges 0.77 | A client that disappears before the server writes the second pipe's name makes QpsMainLoop return, and nothing restarts or watches the accept thread |
| 13 | toctou | `qrexec-agent.c:1135 FindServiceRequest` | ours 70dd82e | cross-process r1 | **none** (possible 0.31; re-ask insufficient 0.24) | visible 0.97 | **none** (diverges 0.24; re-ask diverges 0.27) | Request ids restart at 1 with each agent instance and are matched by string alone, so a dom0 reply to a pre-restart request is taken by an unrelated n |
| 14 | race | `qrexec-wrapper.c:1916 InitVchan` | inherited | cross-process r1 | **none** (possible 0.51; re-ask possible 0.48) | visible 0.96 | **none** (diverges 0.51; re-ask diverges 0.59) | The wrapper's client connect gives up after a bounded wait, but the vchan server it connects to is only created after the exec message was sent |
| 15 | deadlock | `qrexec-wrapper.c:1165 HandleRemoteData` | inherited | proc-service r1 | possible 0.87 | visible 0.98 | diverges 0.92 | The wrapper's only event thread writes child stdin synchronously: a child that does not drain stdin parks it where neither peer hang-up, child exit no |
| 16 | race | `qrexec-agent.c:1956 PipeClientThread` | ours 70dd82e | agent r2 | possible 0.84 | visible 0.96 | diverges 0.95 | A request that arrives before the control vchan exists is read, the caller is released with exit code 0, and the trigger is then thrown away |
| 17 | deadlock | `qrexec-agent.c:1485 WatchForEvents` | inherited | agent r2 +1 merged | possible 0.89 | visible 0.97 | diverges 0.75 | A service stop that lands while the control vchan is being created goes unseen for up to five minutes: VchanInitServer retries on Sleep(1000) and neve |
| 18 | race | `qrexec-wrapper.c:1094 VchanSendExitCode` | inherited | wrapper r2 | **none** (possible 0.36; re-ask possible 0.35) | visible 0.74 | diverges 0.85 | In the vchan-server role the wrapper closes the vchan the moment its local program has exited, without waiting for the remote exit code or for the rem |
| 19 | deadlock | `qrexec-wrapper.c:1983 EventLoop` | ours 53cbbb3 | wrapper r2 +2 merged | **none** (prevented 0.11; re-ask possible 0.17) | visible 0.89 | diverges 0.71 | The reader arms its data notify outside g_VchanCs while a pump arms its room notify on the same byte with a non-atomic OR; a lost arm leaves EventLoop |
| 20 | race | `pipe-server.c:444 QpsReaderThread` | inherited | vchan-pipe r2 | possible 0.85 | visible 0.97 | diverges 0.83 | The reader thread pulls bytes nobody asked for into a 4096-byte queue and drops the client when it overflows, so a request over 4 KiB survives only if |
| 21 | race | `qrexec-wrapper.c:2464 wmain` | inherited | cross-process r2 | **none** (possible 0.47; re-ask possible 0.19) | visible 0.85 | **none** (diverges 0.61; re-ask diverges 0.68) | In the server role the wrapper closes the vchan it owns as soon as its local child has exited, without waiting for the remote's exit code or for the r |
| 22 | deadlock | `pipe-server.c:1155 QpsConnect` | inherited | cross-process r2 | possible 0.73 | visible 0.98 | diverges 0.84 | qrexec-client-vm retries the second pipe forever on 'not found': an agent that goes away, or that failed to create that pipe, between the two connects |
| 23 | toctou | `qrexec-wrapper.c:566 StartChild` | ours 9cc4bce | cross-process r2 | **none** (possible 0.69; re-ask possible 0.61) | visible 0.97 | diverges 0.85 | The wrapper connects the data vchan first and only then waits up to 90 s for a logon; it launches the command afterwards without looking at the vchan  |
| 24 | deadlock | `qrexec-agent.c:2150 ServiceExecutionThread` | inherited | agent r1 +1 merged | **none** (possible 0.47; re-ask possible 0.56) | visible 0.96 | no-counterpart 0.89 | TerminateThread on the pipe accept thread at every stop can orphan the heap, log or pipe-server lock that the stopping thread takes next |
| 25 | toctou | `qrexec-wrapper.c:354 QwCreateProcessAsSessionUser` | ours e0db61a | wrapper r1 +1 merged | possible 0.93 | **none** (visible 0.49; re-ask visible 0.55) | **none** (no-counterpart 0.64; re-ask no-counterpart 0.53) | The console session and its token are looked up twice: the account that was waited for, named and compared is not necessarily the one the process is l |
| 26 | race | `qrexec-wrapper.c:2332 wmain` | inherited | wrapper r1 | possible 0.72 | **none** (internal 0.33; re-ask internal 0.38) | diverges 0.88 | The no-local-process loop in wmain still leaves on a closed vchan without reading what is in the ring, so the peer's exit code is seen or missed depen |
| 27 | toctou | `pipe-server.c:736 QpsDisconnectClientInternal` | inherited | vchan-pipe r1 | possible 0.81 | **none** (visible 0.5; re-ask visible 0.5) | **none** (no-counterpart 0.27; re-ask diverges 0.4) | Disconnecting is tested and set with no lock, so two threads can both run the full teardown of one client |
| 28 | toctou | `pipe-server.c:285 QpsGetClientRaw` | inherited | vchan-pipe r1 | **none** (possible 0.57; re-ask possible 0.36) | visible 0.96 | **none** (no-counterpart 0.56; re-ask no-counterpart 0.57) | Client lookup drops Server->Lock before taking its reference, so the last release can free the client in between |
| 29 | race | `service.c:132 SvcStop` | inherited | proc-service r1 | possible 0.84 | visible 0.98 | no-counterpart 0.93 | The service control handler and SvcMain's teardown share g_Service with no serialisation: a STOP that lands as the worker ends on its own uses a freed |
| 30 | race | `qrexec-wrapper.c:727 StartChild` | ours a493b63 | wrapper r2 +1 merged | possible 0.72 | **none** (visible 0.26; re-ask visible 0.34) | **none** (no-counterpart 0.47; re-ask no-counterpart 0.25) | The payload is created running and its CPU mask is widened afterwards: anything it spawns before that inherits qrexec's one-CPU pin for life |
| 31 | toctou | `pipe-server.c:866 QpsMainLoop` | inherited | vchan-pipe r2 | **none** (possible 0.65; re-ask possible 0.67) | visible 0.88 | diverges 0.71 | The inbound pipe goes to whoever opens its predictable name first: the PID read on the first pipe is never checked on the second |
| 32 | race | `pipe-server.c:497 QpsWriterThread` | inherited | vchan-pipe r2 | possible 0.91 | visible 0.97 | diverges 0.89 | Bytes queued by QpsWrite are thrown away when a disconnect lands before the writer thread's next 1 ms poll, although QpsWrite returned success |
| 33 | race | `pipe-server.c:838 QpsMainLoop` | inherited | cross-process r2 | **none** (possible 0.39; re-ask possible 0.43) | visible 0.85 | diverges 0.77 | The trigger pipe's name is not the agent's alone: Everyone may create further instances of it and nothing asks for the first instance, so another proc |
| 34 | race | `pipe-server.c:892 QpsMainLoop` | inherited | vchan-pipe rmain | **none** (possible 0.45; re-ask possible 0.37) | visible 0.91 | diverges 0.71 | A client that opens the second pipe and has closed it again before the accept thread reaches ConnectNamedPipe leaves that thread retrying the same pip |
| 35 | race | `log.c:839 _LogFormat` | inherited | proc-service rmain | possible 0.72 | visible 0.74 | **none** (no-counterpart 0.63; re-ask no-counterpart 0.45) | The logger starts itself on the first line that passes the level filter, with no lock: since the wrapper's start-up lines were held back or demoted, t |

## 5. A verdict on every change the fork made to this code

### 5.1 What was judged, and what the answers mean

**Units.** Every fork commit since the base tags that touches the audited files: 62 in `core-agent`
and 6 in `winutils`. Two were split by file because they are too large to judge whole: c5b5ade in two,
and the `winutils` assimilation commit e25cbc1 in seven (`pipe-server.c` in two parts). That gives 75
units. e25cbc1 is the commit that turned the build-time patch stack into ordinary history on
2026-11-07, so its units hold several older patches each; where it matters, section 5.3 names the
patch and its date.

**First pass, all 75.** The judge saw an extract built by script: the commit message, the diff of the
audited files, and a script-computed list of where the touched functions are used. Four questions:

| Question | Options (each also had `insufficient_evidence`) |
|---|---|
| class | `behaviour_change`: control flow, waiting, locking, threads, handles, process creation, bytes, exit codes, timeouts. `log_or_text_only`. `comment_or_style_only`. |
| necessary | `shown_necessary`: the shown code itself shows the defect or gap the added lines close. `claimed_only`: the message states a problem the shown code does not let the judge confirm. `unnecessary`: the shown code already handled the case, or the added lines close nothing. |
| proportion | `proportionate`: about the smallest change that closes the problem shown. `overengineered`: a visibly smaller change would close it. |
| side effects | `none_shown`. `side_effect_shown`: the shown code or the listed uses show behaviour changing outside the purpose. |

**Second pass, 51 units.** Every unit not classed as log-only or comment-only at the floor was asked
again with a wider extract (the earlier code, the surrounding code, and the Linux lines a finder had
located for the same job) and one more question, `reference`: after this commit, does the Windows code
do what the Linux lines shown do (`matches_reference`, `diverges_from_reference`, `no_counterpart`).
For these 51 the table in 5.6 shows the second-pass answers, because that pass saw more. The other 24
units were asked once; they are marked ¹ and have no `reference` answer.

**How to read an answer.**

- The floor is 0.70. **none** means no verdict, and the table gives the leading option in brackets. It
  is not a soft "no": "necessary: none (shown 0.64)" means the judge leaned towards "shown" and did not
  reach the floor.
- `claimed_only` is about the extract. The evidence for a change often lives in a run log or a
  findings entry the judge was not shown; then the honest answer from a diff is "claimed".
- `side_effect_shown` does not grade harm. A reworded log line that another tool matches on counts,
  and so does a deliberate departure from Linux.
- A verdict is about what the judge was shown. It did not see whole files, and it did not see section
  3 of this report.

**Stability between the two passes** (computed from the two verdict tables). 51 units times the three
shared questions is 153 pairs. No verdict changed sides at the floor. 30 answers rose from under the
floor to it. 9 fell from the floor to under it with the same leading option; six of those are
`proportionate` verdicts that weakened once the judge could see the existing code and the Linux lines
(224cb46, 53cbbb3, 6061882, b475127, c6b66f0 and the `service.c` part of e25cbc1), two are `shown
necessary` (1df5a7b, 9a4d77f), and one is the `claimed_only` of a493b63 (0.81, then 0.59).

### 5.2 The tallies

| | 51 units asked twice | 24 units asked once ¹ |
|---|---|---|
| necessary: shown | 37 | 2 |
| necessary: no verdict | 14 | 22 |
| proportionate | 41 | 21 |
| proportion: no verdict | 10 | 3 |
| side effects: shown | 32 | 3 |
| side effects: none shown | 0 | 3 |
| side effects: no verdict | 19 | 18 |
| reference: diverges | 2 (1df5a7b 0.72, 190c190 0.87) | not asked |
| reference: matches | 1 (05044b4 0.85) | not asked |
| reference: no counterpart | 2 (a0e5113 0.72, 9cc4bce 0.93) | not asked |
| reference: no verdict | 46 | not asked |

First-pass classes: behaviour 45, log or text only 18, comment or style only 6, no verdict 6.

**No unit was judged unnecessary at the floor, and none was judged overengineered at the floor.** The
two nearest misses:

- `log.c` in e25cbc1: the judge was split almost evenly on proportion, `overengineered=0.49
  proportionate=0.47` on the second ask and `proportionate=0.52 overengineered=0.41` on the first. It
  is the only unit where "overengineered" led.
- 6013dff: `unnecessary=0.63 claimed_only=0.28`, confidence 0.51. It is the only unit where
  "unnecessary" led. The commit adds comments only and says so; it records which sends can and cannot
  be woken by the reader thread.

That the judge found nothing overengineered is a statement about each diff against the problem its
message names. It is not a statement about the sum; section 5.5 has the sizes.

### 5.3 The changes I confirmed by reading

Each entry gives the judge's answers, then what I read at today's heads. These are the changes where
my reading adds something to the verdict: a consequence the judge could not see from the extract, or a
stated purpose the code does not deliver.

**The pipe-server NULL checks and connect rewrite (two patches of 2026-10-14, parent commits 47a60b91
and e85a95bc; now unit `winutils-e25cbc1-pipe_server.c.p1`).**
Judge: necessary shown 0.89 | proportion none (proportionate 0.64) | side effects shown 0.98 |
reference none.
Written the same evening as the recorded agent crash. The NULL checks are necessary and are what
stops that crash. The rewrite fixes real things on the error returns, which used to abandon a half-built
client and could leave a thread looking for a client that would never be inserted. Its headline
purpose is a different matter: the window it describes, a thread looking itself up before the insert,
was already excluded on the success path by the old lock, and the cause the crash log shows, the
host's reference being taken after the client is published, is unchanged (#9). The rewrite also added
a place where the accept thread reads the client after another thread may have freed it
(`pipe-server.c:630`, the second resume). The register closed the crash on these two patches.
My verdict: the checks, yes; the rewrite is defensible as cleanup and did not fix what was measured.

**190c190, "the agent waited on up to 130 handles against a 64-handle API, and a failed wait killed
the loop".**
Judge: necessary shown 0.87 | proportion none (proportionate 0.37) | side effects shown 0.98 |
reference diverges 0.87.
The wait fix is real. The side effect is the one in section 3.3: a full connection table now returns
`ERROR_NO_MORE_ITEMS` through `StartChild` to the main loop, where any error ends the agent. The
comment at `qrexec-agent.c:525-529` says the error fails "the one call that cannot be tracked, instead
of silently degrading the whole subsystem"; as wired, it stops the subsystem. Linux logs a full table
and keeps serving. This is the unit the judge was least sure is proportionate and most sure diverges.

**`pipe-server.c` second part of e25cbc1, and 598903e: the trace of a lost request.**
Judge, e25cbc1 part 2: necessary shown 0.81 | proportionate 0.92 | side effects shown 0.94. Judge,
598903e ¹: log or text only 0.84 | necessary none (shown 0.56) | proportionate 0.92 | side effects
none (shown 0.35).
An earlier patch had made `QpsRead` log `peer gone mid-message: N of M bytes` at ERROR, and on
2026-10-26 that line fired with 426 bytes pending on a 4-byte read (#2). The response was to take the
pending count under the same lock as the failed read (`pipe-server.c:939`), which makes the two
numbers consistent. In the interleaving of #2 the count taken at that instant is 0, so the same event
now logs `peer gone, nothing pending` at DEBUG (`:956-957`). 598903e then turned the agent's line for
a failed first read into INFO, `departed before sending its request header ... nothing was
dispatched` (`qrexec-agent.c:1810-1811`), with a comment that "nothing is lost". Each change is
reasonable alone. Together they removed the only ERROR trace of a request that was received and
dropped, and the line that replaced it says the opposite. The same INFO line is also what #9 would
leave behind, because 598903e lists `ERROR_NOT_CONNECTED` among the ordinary departures and that is
the code a freed client returns.

**70dd82e, protocol v4.**
Judge: necessary shown 0.97 | proportionate 0.79 | side effects shown 0.83.
Needed to speak to current dom0. It raised the accepted service name to 65000 bytes on both sides
(`qrexec-client-vm.c:79`, `qrexec-agent.c:1839`) while the queue between them still holds the 4096
bytes it held at the base (#20). At the base only the command line could exceed the queue. `git
blame` also puts the trigger send of #6 and #16 on this commit, because it changed the message type;
the order that makes those two possible is inherited.

**ac33bc9, 224cb46 and d228a03: the wrapper's wait for its output pumps.**
Judge: ac33bc9 necessary shown 0.88 | proportionate 0.88 | side effects shown 0.73. 224cb46 necessary
shown 0.80 | proportion none (proportionate 0.56) | side effects shown 0.83. d228a03 necessary shown
0.83 | proportionate 0.76 | side effects shown 0.92.
ac33bc9 fixed a real loss: the exit code used to be sent without waiting for the pumps at all. What it
put in place is a single 120-second deadline that nothing extends, and d228a03 took the send lock away
from a pump that is waiting for ring room, so at the deadline the exit code goes into the ring ahead
of data the pump still holds (#4). The common case got better; a slow reader on the far side now
gets a short output under a normal exit code. Linux has no deadline here.

**9ad4dfc, 5cdda32 and e0db61a: the logon wait and the session token.**
Judge: 9ad4dfc necessary none (shown 0.64) | proportionate 0.70 | side effects shown 0.80. 5cdda32
necessary shown 0.88 | proportionate 0.82 | side effects shown 0.89. e0db61a necessary shown 0.83 |
proportionate 0.74 | side effects shown 0.76.
Three consequences. The wait for a logon happens after the data channel is connected and the command
runs without another look at the channel (#23). The session and its token are read twice (#25). And
since the password path is gone, the service process runs on whatever token the console session has,
unless the name is one of the three that select the service's own token; the user name a call
carries is compared and logged, never enforced (`qrexec-wrapper.c:594-599`). That last point is part
of the question in section 7.1.

**a493b63, one CPU for the agent and its wrappers.**
Judge: necessary none (`claimed_only` 0.59; 0.81 on the diff alone) | proportionate 0.86 | side
effects none (shown 0.34).
The judge could not see the problem in the code, on either ask. What I read: the pin is inherited by
the wrapper and by the service process, and the service process is widened only after it is already
running, so anything it starts in between stays on one CPU for life (#30). Every agent thread now
competes for one CPU, which plausibly widens the windows of #34 and #9; both need the accept thread
held off for a moment. And the pin is what keeps a non-atomic update in the vchan library from
mattering (#19), so removing it is not free either.

**2d2b55d, 933d01d and d63b88b: three log demotions in the wrapper.**
Judge ¹: 2d2b55d necessary none (shown 0.65) | proportion none (proportionate 0.60). 933d01d necessary
none (claimed_only 0.45) | proportionate 0.92. d63b88b necessary none (claimed_only 0.32) |
proportionate 0.91.
Each quiets lines that were noise. Their sum, in a wrapper serving a call into the qube at the default
level: no line passes the filter until the closing `RINGPEER` line, and the logger starts itself on
the first line that passes. So the process's birth line is written when it exits, and a wrapper that
hangs leaves no line at all. MEASURED: in the newest captured build (4.3.39.1213), 28 of 34 wrapper
birth lines are followed directly by the `RINGPEER` line. It also makes the logger's unlocked start
reachable from two threads (#35).

**7bcaad5 and the service exit-code patch (2026-10-03, now `service.c` in e25cbc1).**
Judge: 7bcaad5 necessary shown 0.84 | proportionate 0.77 | side effects shown 0.98. `service.c`
necessary shown 0.95 | proportion none (proportionate 0.64) | side effects shown 0.82.
An improvement. Before them the worker returned success whatever happened and `SvcMain` reported
`NO_ERROR`, so a failed agent stayed stopped for the rest of the boot; now the error reaches the
service manager and the restart fires. Two things remain: a per-call error is still fatal (section
3.3), and a disconnect by dom0's daemon still ends the service with 0, which is not restarted
(section 7.2).

**54999a1, "always close the data vchan before exiting".**
Judge: necessary shown 0.81 | proportionate 0.85 | side effects none (shown 0.55).
`git blame` puts the line that sends a Win32 error as the exit code (#1) on this commit, but the
commit only moved the block; the behaviour is from 2015.

**1e9155e, "SYSTEM and root mean the service's own token on every path".**
Judge: necessary shown 0.76 | proportionate 0.94 | side effects none (shown 0.68).
Read with `exec.c:416` and `qrexec-agent.c:1887`, this is one half of the question in section 7.1.

**1df5a7b, "close the data vchan only when no output pump can be using it".**
Judge: necessary none (shown 0.68) | proportion none (proportionate 0.60) | side effects shown 0.96 |
reference diverges 0.72.
One of the two units judged to diverge from Linux at the floor. I did not read it beyond the lines
cited in #1, #4, #18 and #21.

### 5.4 Where the judge gave no verdict

**Proportion, 10 of the 51 asked twice:** 53cbbb3, 224cb46, 1df5a7b, c6b66f0, b475127, 190c190,
6061882, and three parts of e25cbc1 (`log.c`, `pipe-server.c` part 1, `service.c`). Among the 24 asked
once: 2d2b55d, dabaeed, 01e9bc4. In every one but `log.c` the leading option was "proportionate".

**Necessity where "claimed only" led:** a493b63, 671b650, a52441a, b8b3649 among the units asked
twice; f65a5f1, 933d01d, d63b88b, c898227, f37a735 among those asked once. For these the diff does
not show the problem. That is expected for changes whose evidence is a run (b8b3649 says a service
"lost all its output") and for comment-only commits; it is a real gap only for a493b63, whose
mechanism has side effects.

**Reference, 46 of 51.** The Linux lines the judge was shown were located by the finders for the
candidates, not for each commit, so for most commits there was little to compare against. The
comparison with Linux that this report stands on is in sections 3 and 6, not in this column.

### 5.5 Size

Computed with `git diff --numstat` between the base tags and today's heads, and a count of lines that
begin with a comment marker.

| File | Lines at base | Lines today | Comment lines at base | Comment lines today |
|---|---|---|---|---|
| `qrexec-wrapper.c` | 1003 | 2535 | 157 | 892 |
| `qrexec-agent.c` | 1512 | 2243 | 240 | 606 |
| `pipe-server.c` | 923 | 1158 | 94 | 273 |
| `log.c` | 703 | 967 | 56 | 144 |
| `vchan-common.c` | 146 | 309 | 26 | 126 |

`service.c` grew by 49 lines, `exec.c` by 11, `qrexec-client-vm.c` by 24; `buffer.c` is unchanged.

Roughly half of the growth of the wrapper is comment. Many comments carry measurements and the reason
for a line, which is useful. Two of the ones I checked state something the code does not do: the
comment at `qrexec-agent.c:525-529` (5.3, 190c190) and the comment at `pipe-server.c:551-560`, which
attributes the measured crash to a window that could not open (#9). A third, at
`qrexec-agent.c:1786-1788`, says "nothing is lost" where #2 and #9 can lose a request. A comment
that records a measurement reads as settled, so a wrong one costs more than a missing one.

### 5.6 Every unit in one table

Generated by script from the verdict files. Columns show the judge's short form and confidence;
**none** means no verdict, with the leading option in brackets. ¹ marks a unit asked once (5.1).
"its lines are cited in" lists the candidates of section 3 that cite a line this unit last wrote; it
is a join on `git blame`, not a statement that the unit caused the candidate.

| change | date | subject | first-pass class | necessary | proportion | side effects | reference | its lines are cited in |
|---|---|---|---|---|---|---|---|---|
| `core-agent-ac33bc9` | 2026-08-21 | qrexec-wrapper: do not send the exit code before the i/o pumps have drained | behaviour 1 | shown 0.88 | proportionate 0.88 | shown 0.73 | **none** (diverges 0.49) | #18 #19 #4 |
| `core-agent-e5e94b8` | 2026-08-21 | qrexec-wrapper: drain the vchan before leaving on close - the actual Task #14 byte loss | behaviour 1 | shown 0.96 | proportionate 0.91 | **none** (shown 0.66) | **none** (diverges 0.31) | #26 |
| `core-agent-7bcaad5` | 2026-09-08 | audit fixes: qrexec-agent readiness, advertise-tools session wait, relocate-dir reporting | behaviour 1 | shown 0.84 | proportionate 0.77 | shown 0.98 | **none** (diverges 0.6) | #17 #24 #3 |
| `core-agent-a0e5113` | 2026-09-08 | deferred: advertise-tools qdb handle lifetime | behaviour 0.96 | **none** (shown 0.35) | proportionate 0.91 | **none** (shown 0.33) | no-counterpart 0.72 | #3 |
| `core-agent-a756805` | 2026-09-11 | qrexec-wrapper: say loudly when a run-as user logon fails and the service degrades to SYSTEM | log-or-text 0.89 | **none** (shown 0.52) ¹ | proportionate 0.88 ¹ | **none** (shown 0.37) ¹ | not asked | - |
| `core-agent-54999a1` | 2026-09-29 | qrexec-wrapper: always close the data vchan before exiting, not only while it is open | behaviour 1 | shown 0.81 | proportionate 0.85 | **none** (shown 0.55) | **none** (matches 0.48) | #1 |
| `core-agent-a493b63` | 2026-09-27 | qrexec: keep the per-call vchan/event-channel work on one CPU | behaviour 1 | **none** (claimed-only 0.59) | proportionate 0.86 | **none** (shown 0.34) | **none** (no-counterpart 0.59) | #19 #29 #30 #34 |
| `core-agent-53cbbb3` | 2026-09-29 | qrexec-wrapper: close the data vchan before exiting on a console control event | behaviour 1 | **none** (shown 0.51) | **none** (proportionate 0.43) | shown 0.74 | **none** (diverges 0.29) | #1 #15 #19 #26 #8 |
| `core-agent-224cb46` | 2026-09-29 | qrexec-wrapper: the post-exit drain wait also wakes on a console-control stop | behaviour 1 | shown 0.8 | **none** (proportionate 0.56) | shown 0.83 | **none** (diverges 0.67) | #18 #19 #21 #4 |
| `core-agent-6e1cb63` | 2026-09-30 | qrexec-wrapper: send the final hello only if ours has not gone out | behaviour 1 | shown 0.72 | proportionate 0.76 | **none** (none-shown 0.24) | **none** (matches 0.33) | - |
| `core-agent-1df5a7b` | 2026-09-30 | qrexec-wrapper: close the data vchan only when no output pump can be using it | behaviour 1 | **none** (shown 0.68) | **none** (proportionate 0.6) | shown 0.96 | diverges 0.72 | #1 #18 #21 #4 |
| `core-agent-5c56fee` | 2026-09-29 | qrexec-wrapper: negotiate data-vchan protocol v3 (64 KiB chunks); the control vchan stays v2 | behaviour 1 | shown 0.79 | proportionate 0.72 | **none** (shown 0.66) | **none** (diverges 0.32) | - |
| `core-agent-671b650` | 2026-09-29 | qrexec-wrapper: under data-vchan v3, receive up to 64 KiB but keep sending 4 KiB | behaviour 0.89 | **none** (claimed-only 0.19) | proportionate 0.94 | **none** (none-shown 0.28) | **none** (diverges 0.33) | #19 #35 #4 |
| `core-agent-70dd82e` | 2026-09-29 | qrexec: speak protocol v4 like upstream - MSG_TRIGGER_SERVICE4, full service names, v4 data hel | behaviour 1 | shown 0.97 | proportionate 0.79 | shown 0.83 | **none** (diverges 0.4) | #13 #16 #2 #20 #6 |
| `core-agent-0457e26` | 2026-09-30 | qrexec-agent (v4): fixes from the pre-commit review of the v4 change | behaviour 1 | shown 0.95 | proportionate 0.91 | shown 0.85 | **none** (diverges 0.44) | #13 #20 |
| `core-agent-a4a6001` | 2026-10-07 | qrexec-agent: an Autostart value nobody set is not an error - it was one error line per boot, p | log-or-text 0.89 | shown 0.73 ¹ | proportionate 0.97 ¹ | **none** (none-shown 0.34) ¹ | not asked | - |
| `core-agent-2d2b55d` | 2026-10-07 | qrexec-wrapper: a SUCCESSFUL vchan connect stops writing ERROR lines; the failed case stays lou | log-or-text 0.79 | **none** (shown 0.65) ¹ | **none** (proportionate 0.6) ¹ | **none** (shown 0.67) ¹ | not asked | #14 #35 |
| `core-agent-064a420` | 2026-10-07 | qrexec-wrapper: the pump-at-exit line says WHICH cause, and a successful call returns 0 | behaviour 0.92 | shown 0.96 | proportionate 0.85 | shown 0.94 | **none** (diverges 0.69) | #1 #4 |
| `core-agent-d88e7df` | 2026-10-08 | qrexec-wrapper: the console-control close reports only what can leave a mapping behind | behaviour 0.73 | shown 0.75 | proportionate 0.89 | shown 0.76 | **none** (diverges 0.35) | #8 |
| `core-agent-052e6a8` | 2026-10-08 | The guest clock was wrong and nothing pulled it; a normal stream teardown logged an ERROR | log-or-text 0.95 | **none** (shown 0.65) ¹ | proportionate 0.89 ¹ | **none** (shown 0.52) ¹ | not asked | #35 |
| `core-agent-dabaeed` | 2026-10-09 | qrexec-wrapper: a failed vchan connect is ONE error line, not four | log-or-text 0.91 | **none** (shown 0.25) ¹ | **none** (proportionate 0.6) ¹ | **none** (shown 0.5) ¹ | not asked | #14 |
| `core-agent-01e9bc4` | 2026-10-09 | qrexec-wrapper: the one vchan-failure line says what happened, in words | log-or-text 0.71 | **none** (shown 0.57) ¹ | **none** (proportionate 0.6) ¹ | **none** (shown 0.61) ¹ | not asked | #14 |
| `core-agent-c6b66f0` | 2026-10-09 | The guest found three defects in the one-line collapse; the offline model could not | **none** (behaviour 0.45) | shown 0.73 | **none** (proportionate 0.49) | shown 0.91 | **none** (diverges 0.45) | - |
| `core-agent-da8b8c3` | 2026-10-09 | Terse error lines: the diagnosis in 125 characters, not 250 | log-or-text 0.75 | shown 0.72 ¹ | proportionate 0.85 ¹ | **none** (shown 0.68) ¹ | not asked | - |
| `core-agent-1af4007` | 2026-10-09 | A lost handshake is not lost output; and one condition, one line | log-or-text 0.89 | **none** (shown 0.51) ¹ | proportionate 0.98 ¹ | shown 0.7 ¹ | not asked | - |
| `core-agent-b266e57` | 2026-10-09 | Name the third vchan failure shape: the peer's ring could not be mapped | **none** (log-or-text 0.63) | **none** (shown 0.32) | proportionate 0.97 | **none** (none-shown 0.38) | **none** (diverges 0.55) | - |
| `core-agent-1e9155e` | 2026-10-10 | qrexec-agent: SYSTEM and root mean the service's own token on every path | behaviour 1 | shown 0.76 | proportionate 0.94 | **none** (shown 0.68) | **none** (diverges 0.55) | - |
| `core-agent-2d2d9e1` | 2026-10-10 | advertise-tools: say what this process saw, not what it deduced | log-or-text 0.96 | **none** (shown 0.36) ¹ | proportionate 0.92 ¹ | **none** (shown 0.38) ¹ | not asked | - |
| `core-agent-9ad4dfc` | 2026-10-11 | qrexec-wrapper: wait for the logon before a user-context service, and say why if it never comes | behaviour 1 | **none** (shown 0.64) | proportionate 0.7 | shown 0.8 | **none** (diverges 0.67) | #23 #25 |
| `core-agent-5cdda32` | 2026-10-11 | Delete the password fallback outright, and fail where it used to paper over | behaviour 1 | shown 0.88 | proportionate 0.82 | shown 0.89 | **none** (diverges 0.51) | #23 #25 |
| `core-agent-9cc4bce` | 2026-10-11 | Do not call the Windows interactive session a "console logon" | **none** (comment-or-style 0.56) | **none** (shown 0.12) | proportionate 0.91 | **none** (none-shown 0.35) | no-counterpart 0.93 | #23 #25 |
| `core-agent-e0db61a` | 2026-10-11 | Take the console session's token directly, so the LogonUser path is GONE not unreachable | behaviour 1 | shown 0.83 | proportionate 0.74 | shown 0.76 | **none** (diverges 0.4) | #23 #25 #30 |
| `core-agent-a52441a` | 2026-10-11 | No console for a piped service, so nothing for DefTerm to hand to Terminal | behaviour 1 | **none** (claimed-only 0.27) | proportionate 0.86 | shown 0.92 | **none** (diverges 0.33) | - |
| `core-agent-b8b3649` | 2026-10-14 | Back to CREATE_NO_WINDOW: the no-console service lost all its output | behaviour 0.99 | **none** (claimed-only 0.23) | proportionate 0.83 | **none** (shown 0.64) | **none** (diverges 0.12) | #30 |
| `core-agent-31a7c59` | 2026-10-16 | qrexec-wrapper: one logon failure, one line - and it named a call that never ran | behaviour 0.83 | **none** (shown 0.67) | proportionate 0.94 | shown 0.7 | **none** (diverges 0.44) | - |
| `core-agent-54827ce` | 2026-10-17 | one truncated transfer, one error line | log-or-text 0.97 | **none** (shown 0.47) ¹ | proportionate 0.94 ¹ | **none** (none-shown 0.25) ¹ | not asked | - |
| `core-agent-f65a5f1` | 2026-10-18 | qrexec-wrapper: QGAVCHANFAIL keeps its level, and that was tested | comment-or-style 0.91 | **none** (claimed-only 0.33) ¹ | proportionate 0.82 ¹ | **none** (none-shown 0.68) ¹ | not asked | - |
| `core-agent-44668de` | 2026-10-18 | qrexec-wrapper: an ending session is Info; an interruption keeps its warning | log-or-text 0.85 | **none** (shown 0.33) ¹ | proportionate 0.96 ¹ | **none** (shown 0.46) ¹ | not asked | #35 |
| `core-agent-179bc52` | 2026-10-20 | qrexec-wrapper: one teardown, one line - a loss already reported is not reported twice | **none** (log-or-text 0.69) | **none** (shown 0.45) | proportionate 0.85 | **none** (shown 0.35) | **none** (diverges 0.37) | - |
| `core-agent-4383ef2` | 2026-10-20 | qrexec-wrapper: the data error names its own cause instead of writing "a data error" | **none** (log-or-text 0.47) | shown 0.87 | proportionate 0.83 | shown 0.72 | **none** (diverges 0.28) | - |
| `core-agent-933d01d` | 2026-10-21 | log noise: per-call mechanics are debug, not events | log-or-text 0.99 | **none** (claimed-only 0.45) ¹ | proportionate 0.92 ¹ | **none** (shown 0.4) ¹ | not asked | #35 |
| `core-agent-5533ff4` | 2026-10-21 | qrexec-wrapper: declare whyBuf at the top of the block - this unit is C89 | comment-or-style 0.99 | **none** (shown 0.47) ¹ | proportionate 0.97 ¹ | none-shown 0.96 ¹ | not asked | - |
| `core-agent-0d1b565` | 2026-10-22 | qrexec-wrapper: brace the final else, so one exit is one log line | **none** (log-or-text 0.39) | shown 0.73 | proportionate 0.7 | **none** (none-shown 0.35) | **none** (diverges 0.12) | - |
| `core-agent-b475127` | 2026-10-24 | qrexec-agent: the WaitForQdb bound now covers the CALL, not just the gaps between calls | behaviour 1 | shown 0.8 | **none** (proportionate 0.55) | shown 0.8 | **none** (no-counterpart 0.31) | #17 |
| `core-agent-05044b4` | 2026-10-26 | qrexec-wrapper: the client sends its hello in InitVchan, like the server already did | behaviour 1 | shown 0.83 | proportionate 0.97 | **none** (shown 0.44) | matches 0.85 | - |
| `core-agent-3509b88` | 2026-10-26 | qrexec-wrapper: the chunk-limit comment names the guarantee that actually holds | comment-or-style 0.96 | **none** (shown 0.29) ¹ | proportionate 0.92 ¹ | none-shown 0.85 ¹ | not asked | - |
| `core-agent-d63b88b` | 2026-10-28 | qrexec-wrapper: count the peer's liveness flag at cleanup, so bullet 12 stops being an argument | log-or-text 0.8 | **none** (claimed-only 0.32) ¹ | proportionate 0.91 ¹ | **none** (none-shown 0.33) ¹ | not asked | #21 #23 #35 |
| `core-agent-87a7114` | 2026-10-28 | qrexec: honour the stop in the logon poll, close a dead branch, fix the agent's format string | behaviour 0.99 | shown 0.92 | proportionate 0.92 | shown 0.86 | **none** (diverges 0.2) | #23 #35 |
| `core-agent-9a4d77f` | 2026-10-30 | two verified defects in the wrapper's own exit path, and NOT a fix for the wedge | behaviour 1 | **none** (shown 0.65) | proportionate 0.92 | **none** (shown 0.6) | **none** (matches 0.43) | - |
| `core-agent-190c190` | 2026-10-30 | the agent waited on up to 130 handles against a 64-handle API, and a failed wait killed the loo | behaviour 1 | shown 0.87 | **none** (proportionate 0.37) | shown 0.98 | diverges 0.87 | #7 |
| `core-agent-c766a4f` | 2026-11-07 | qrexec-wrapper: a going-down we asked for is not a warning | log-or-text 0.99 | **none** (shown 0.39) ¹ | proportionate 0.79 ¹ | **none** (shown 0.35) ¹ | not asked | - |
| `core-agent-598903e` | 2026-11-08 | a client that hung up before asking for anything was logged as an error of ours | log-or-text 0.84 | **none** (shown 0.56) ¹ | proportionate 0.92 ¹ | **none** (shown 0.35) ¹ | not asked | #2 |
| `core-agent-c898227` | 2026-11-09 | the full-ring wait has no exit for an impossible size, so the ring floor becomes a build error | comment-or-style 0.88 | **none** (claimed-only 0.2) ¹ | proportionate 0.96 ¹ | none-shown 0.8 ¹ | not asked | - |
| `core-agent-ec50065` | 2026-11-09 | qrexec-agent closed the daemon vchan with no lock at all, and the senders' pointer was a copy | behaviour 1 | shown 0.85 | proportionate 0.85 | shown 0.83 | **none** (diverges 0.59) | #7 |
| `core-agent-d3c07bf` | 2026-11-09 | qrexec-agent committed a header and then waited for the body, so a slow daemon froze the agent | behaviour 1 | shown 0.8 | proportionate 0.89 | shown 0.92 | **none** (diverges 0.49) | - |
| `core-agent-d228a03` | 2026-11-09 | qrexec: the vchan send lock was held across the wait for ring room | behaviour 1 | shown 0.83 | proportionate 0.76 | shown 0.92 | **none** (diverges 0.16) | #16 #17 #19 #4 #6 #7 |
| `core-agent-2d9b086` | 2026-11-09 | qrexec: the lock-releasing wait blocked on a handle the peer's close can shut | behaviour 1 | shown 0.83 | proportionate 0.82 | **none** (shown 0.6) | **none** (diverges 0.49) | - |
| `core-agent-5b2bff9` | 2026-11-09 | qrexec: the ring-room wait announced ordinary backpressure at WARNING | log-or-text 0.81 | **none** (shown 0.39) ¹ | proportionate 0.82 ¹ | shown 0.76 ¹ | not asked | #17 |
| `core-agent-f37a735` | 2026-11-09 | qrexec: cut the level-change comments down to what the site needs | comment-or-style 0.92 | **none** (claimed-only 0.21) ¹ | proportionate 0.77 ¹ | **none** (none-shown 0.42) ¹ | not asked | - |
| `core-agent-6061882` | 2026-11-09 | the full-ring wait dropped the guard that stops a failed wait spinning | behaviour 1 | shown 0.88 | **none** (proportionate 0.62) | shown 0.89 | **none** (no-counterpart 0.27) | - |
| `core-agent-c5b5ade-qrexec_agent.c` | 2026-11-09 | qrexec: senders stop sharing the vchan's single-release event | behaviour 1 | shown 0.73 | proportionate 0.88 | shown 0.83 | **none** (diverges 0.25) | #17 #7 |
| `core-agent-c5b5ade-qrexec_wrapper.c` | 2026-11-09 | qrexec: senders stop sharing the vchan's single-release event | behaviour 1 | shown 0.73 | proportionate 0.88 | shown 0.89 | **none** (diverges 0.16) | #15 #19 #4 |
| `core-agent-6013dff` | 2026-11-09 | qrexec: record which sends get a room-event relay and which do not | comment-or-style 0.93 | **none** (unnecessary 0.51) ¹ | proportionate 0.89 ¹ | **none** (none-shown 0.56) ¹ | not asked | - |
| `winutils-e25cbc1-error.c` | 2026-11-07 | assimilate: the QWT patch stack becomes ordinary history | log-or-text 0.89 | **none** (shown 0.61) ¹ | proportionate 0.89 ¹ | **none** (shown 0.34) ¹ | not asked | - |
| `winutils-e25cbc1-exec.c` | 2026-11-07 | assimilate: the QWT patch stack becomes ordinary history | behaviour 1 | shown 0.79 | proportionate 0.8 | **none** (shown 0.55) | **none** (diverges 0.57) | #3 |
| `winutils-e25cbc1-log.c` | 2026-11-07 | assimilate: the QWT patch stack becomes ordinary history | behaviour 0.99 | shown 0.84 | **none** (overengineered 0.24) | shown 0.98 | **none** (no-counterpart 0.52) | #35 |
| `winutils-e25cbc1-pipe_server.c.p1` | 2026-11-07 | assimilate: the QWT patch stack becomes ordinary history | behaviour 1 | shown 0.89 | **none** (proportionate 0.64) | shown 0.98 | **none** (no-counterpart 0.4) | #11 #20 #24 #27 #28 #9 |
| `winutils-e25cbc1-pipe_server.c.p2` | 2026-11-07 | assimilate: the QWT patch stack becomes ordinary history | behaviour 0.85 | shown 0.81 | proportionate 0.92 | shown 0.94 | **none** (diverges 0.47) | #2 |
| `winutils-e25cbc1-service.c` | 2026-11-07 | assimilate: the QWT patch stack becomes ordinary history | behaviour 1 | shown 0.95 | **none** (proportionate 0.64) | shown 0.82 | **none** (diverges 0.43) | #29 |
| `winutils-e25cbc1-vchan_common.c` | 2026-11-07 | assimilate: the QWT patch stack becomes ordinary history | log-or-text 0.99 | **none** (shown 0.27) ¹ | proportionate 0.92 ¹ | shown 0.72 ¹ | not asked | - |
| `winutils-d4db621` | 2026-11-09 | the shared full-ring wait had no exit, and two components inherited it | behaviour 1 | shown 0.79 | proportionate 0.96 | shown 0.83 | **none** (diverges 0.47) | #7 |
| `winutils-f7ffa81` | 2026-11-09 | the shared full-ring wait gains a teardown exit, so a component can close under the lock its se | behaviour 1 | shown 0.8 | proportionate 0.92 | shown 0.73 | **none** (diverges 0.39) | #7 |
| `winutils-bd9a197` | 2026-11-09 | the shared full-ring wait spun at 1 kHz under the caller's lock instead of waiting on the chann | behaviour 1 | shown 0.92 | proportionate 0.77 | shown 0.86 | **none** (diverges 0.51) | - |
| `winutils-eb6e721` | 2026-11-09 | the shared full-ring wait dropped the guard that stops a failed wait spinning | behaviour 1 | shown 0.87 | proportionate 0.97 | **none** (none-shown 0.37) | **none** (no-counterpart 0.24) | - |
| `winutils-c09bfc6` | 2026-11-10 | vchan-common: the send wait must own the handle it waits on | behaviour 1 | **none** (shown 0.6) | proportionate 0.91 | **none** (shown 0.2) | **none** (diverges 0.28) | - |

## 6. What the Linux code guarantees, and where Windows has no line for it

You asked for the Linux counterpart as the reference for desired functionality. Besides the comparison
inside each finding, every finder had to state twenty guarantees that the Linux implementation gives in
its area, each with the Linux line that gives it, and to cite the Windows line or lines that do the
same job. Five finder units give 100 rows; the table follows in 6.2.

**How to read the table.**

- The wording is the finder's. I checked the rows that a finding in section 3 leans on, not all 100.
- The units overlap, so the same guarantee can appear two or three times in different words (rows 21,
  49 and 70 are one guarantee).
- A Windows line in the last column means "this is where Windows does that job". It does not mean
  Windows gives the same guarantee: row 1 points at the wrapper's drain wait, which is finding #4.
- **none cited** means the finder found no Windows line that does the job. 54 of the 100 rows are in
  that state: wrapper 11 of 20, agent 11, pipe and vchan plumbing 11, cross-process 13, process
  creation and service 8.

### 6.1 The 54 rows without a Windows line, by theme

1. **The caller is kept until it has an answer, and reaches the agent in one step.** Rows 23, 48, 73
   and 72. This is the premise of section 3.1, and #22.
2. **Nothing is accepted before it can be forwarded.** The trigger socket exists only after the
   control channel and its hello (rows 21, 49, 70); a failed hello ends the process (22); readiness is
   reported only after dom0's daemon has connected (97); dom0 accepts the connection only if the first
   message is a hello (39). Findings #16 and #6.
3. **One client cannot hurt the others.** An incomplete request is dropped after 5 seconds (rows 27,
   43, 74) and their number is bounded (44); client sockets are non-blocking (45) and are closed at
   once on an error (47); a client is one socket (46) and the name has one listener (71); the agent
   reads only the bytes a request still needs (41) and serves a request that arrived whole even if the
   client hangs up (42). Section 3.2 and findings #2, #20, #31, #33.
4. **One failing call does not end the agent.** An unknown request id is logged and ignored (rows 36,
   78, 99), and so is a full table (37, 100). Section 3.3. Row 31 is the one place where Linux is the
   stricter of the two: a control send that fails is fatal there, and the finder found no Windows line
   that does the same.
5. **Every wait for the other side has a bound.** 120 seconds for the data channel in both roles (rows
   11, 61, 63, 91), a deadline on the vchan connect (59), a 10-second re-check inside the I/O loop (4),
   and dom0 gives the qube's server 5 seconds (80). Findings #8, #5 and #14.
6. **The data loop is one thread that never blocks on the child.** The calling side closes only after
   the remote exit code (rows 2, 62); the vchan stays in the wait set while output drains (5, 88); one
   thread arms both notifications (6); the peer's hello is validated immediately before the service
   starts (10, 64); stdin is closed when the child exits, discarded when closed and never written
   with a blocking call (12, 13, 14); the loop waits for its local process before leaving (17, 69);
   buffered output is flushed until empty (54). Findings #1, #15, #18, #21, #19, #23 and #4.
7. **Sessions and process start.** The wait for a user session happens in the agent, before any data
   channel is connected (rows 38, 65); what the service process must start with is set before it runs,
   and what it inherited from the agent is undone (20, 83); each call's environment is built for that
   child and never lives in the agent (93). Findings #23 and #30, and section 7.
8. **Stop and start.** A stop during start-up takes effect at once (row 34); the loop never enters a
   blocking control send (25); "stopped" means the process is gone (98). Findings #17, #7 and #24.

Rows that do cite a Windows line and are still the site of a finding: 1 and 87 (the exit code after
all three streams have ended, with no deadline: #4), 53 (a listening endpoint that always exists: #34,
#10), 81 (the service keeps only its three standard handles: section 7.6), 84 (the switch to the
requested user happens before the program runs and a failure ends it: section 7.1), 92 (the session
wait is off the agent's main loop; Windows does it in the wrapper, after connecting: #23).

### 6.2 All 100 rows

| # | finder unit | what the Linux code guarantees (the finder's words) | Linux line | Windows line(s) the finder cited for it |
|---|---|---|---|---|
| 1 | wrapper | The exit code is sent only when stdin, stdout and stderr of the child have all reached EOF - data-driven, with no deadline. | `process_io.c:222` | qrexec-wrapper.c:2103, qrexec-wrapper.c:2151 |
| 2 | wrapper | In the client role the loop leaves only when the local process is done AND the remote exit code has arrived (or the vchan closed), so the vchan is never closed under a remote that is still working. | `process_io.c:232` | **none cited** |
| 3 | wrapper | A closed vchan ends the loop only after everything still in the ring has been processed, with is_open checked before data_ready. | `process_io.c:246` | qrexec-wrapper.c:2002, qrexec-wrapper.c:2018 |
| 4 | wrapper | The wait for vchan or pipe activity is bounded at 10 s, after which peer liveness, data-ready and child status are all re-read, so a missed wake costs at most 10 s. | `process_io.c:301` | **none cited** |
| 5 | wrapper | The one loop that waits for the child's output EOF keeps the vchan in its wait set the whole time, so data, ring room and a peer hang-up are serviced while output drains after the child has exited. | `process_io.c:293` | **none cited** |
| 6 | wrapper | Ring room and data-ready are queried (and their notify bits armed) by the same single thread that then waits, so one arm cannot overwrite the other. | `process_io.c:281` | **none cited** |
| 7 | wrapper | Child output is taken from the pipe only when the ring has room for it, so a full ring is plain backpressure and never a blocked sender holding a lock. | `remote.c:167` | qrexec-wrapper.c:994, qrexec-wrapper.c:846 |
| 8 | wrapper | A message's header and payload reach the ring back to back, because one thread is the only sender. | `remote.c:195` | qrexec-wrapper.c:928 |
| 9 | wrapper | Our own HELLO is on the wire before the service process exists and before any data message. | `qrexec-agent-data.c:102` | qrexec-wrapper.c:1929, qrexec-wrapper.c:1900 |
| 10 | wrapper | The peer's HELLO is received and its version validated before the service process is spawned, so an incompatible peer never causes a command to run. | `qrexec-agent-data.c:113` | **none cited** |
| 11 | wrapper | Waiting for the data vchan to connect is bounded at 120 s in both roles. | `qrexec-agent-data.c:219` | **none cited** |
| 12 | wrapper | When the child exits, its status is recorded and the stdin side is closed at once, so nothing is written to a dead child afterwards. | `process_io.c:216` | **none cited** |
| 13 | wrapper | Inbound data for a stdin that is already closed is discarded by a check made immediately before the write, not treated as an error. | `remote.c:85` | **none cited** |
| 14 | wrapper | A stdin write never blocks the loop: what the child does not take is buffered and no more is read from the vchan until it is flushed. | `remote.c:53` | **none cited** |
| 15 | wrapper | A child exit cannot be missed: SIGCHLD is blocked except inside the ppoll that waits for it. | `process_io.c:143` | qrexec-wrapper.c:1976 |
| 16 | wrapper | When the service cannot be spawned, stdout EOF and stderr EOF go out first, then the exit code, then the vchan is closed. | `qrexec-agent-data.c:271` | qrexec-wrapper.c:1101, qrexec-wrapper.c:2434 |
| 17 | wrapper | After the loop the local pipes are closed and the local process is waited for with a blocking wait, so the data process never outlives-by-abandoning its child. | `process_io.c:393` | **none cited** |
| 18 | wrapper | The vchan is closed once, after the loop, by the only thread that ever used it. | `qrexec-agent-data.c:319` | qrexec-wrapper.c:2462, qrexec-wrapper.c:2464 |
| 19 | wrapper | A chunk longer than the negotiated maximum is rejected by a check made after the header and before the payload is read. | `remote.c:66` | qrexec-wrapper.c:1235 |
| 20 | wrapper | Everything the payload must start with is put in place in the forked child before exec, so the payload's first instruction already runs with its final attributes. | `qrexec-agent-data.c:179` | **none cited** |
| 21 | agent | The trigger socket that qrexec-client-vm talks to is created only after the control vchan exists and the hello exchange has succeeded, so no client request can be accepted before it can be forwarded. | `qrexec-agent.c:417` | **none cited** |
| 22 | agent | A failed hello exchange ends the process, so the agent never sits waiting on a control vchan whose handshake did not complete. | `qrexec-agent.c:414` | **none cited** |
| 23 | agent | After a trigger is forwarded the client's connection is kept open (only the slot is cleared), so the caller is not released until dom0 has answered. | `qrexec-agent.c:929` | **none cited** |
| 24 | agent | The loop never blocks with unread control data in the ring: data_ready is checked before every blocking poll. | `txrx-vchan.c:38` | qrexec-agent.c:1673 |
| 25 | agent | The main loop looks at trigger clients and ended connections only while the control vchan has room for a header, so it does not go into a blocking control send from inside the loop. | `qrexec-agent.c:1071` | **none cited** |
| 26 | agent | A control header and its body are written back to back by the only writer, so two control messages can never interleave in the ring. | `qrexec-agent.c:921` | qrexec-agent.c:391, qrexec-agent.c:486 |
| 27 | agent | A client that has not delivered a complete trigger request within 5 seconds is closed, and the number of incomplete clients is bounded. | `qrexec-agent.c:855` | **none cited** |
| 28 | agent | A slow or silent trigger client cannot stall the handling of other clients or of the control vchan, because its socket is non-blocking. | `qrexec-agent.c:943` | qrexec-agent.c:2009 |
| 29 | agent | A child's exit cannot be lost between the check and the wait: SIGCHLD is blocked everywhere except inside ppoll, and the child is registered by the same thread that started it. | `qrexec-agent.c:1054` | qrexec-agent.c:1111, qrexec-agent.c:1531 |
| 30 | agent | MSG_CONNECTION_TERMINATED is sent once per connection and only after the process that owned the data vchan has been reaped. | `qrexec-agent.c:833` | qrexec-agent.c:1694 |
| 31 | agent | A control send that fails is fatal, so the agent never carries on after failing to tell dom0 that a data port was released. | `qrexec-agent.c:805` | **none cited** |
| 32 | agent | The table of running connections has one owner: poll results are matched against a table that cannot have changed since the wait set was built. | `qrexec-agent.c:1114` | qrexec-agent.c:1692 |
| 33 | agent | A termination request is a flag the main loop tests on every pass, and the loop's wait is bounded to one second, so a stop is seen while the loop is running. | `qrexec-agent.c:1061` | qrexec-agent.c:1493, qrexec-agent.c:1605 |
| 34 | agent | A termination request during startup takes effect at once, because the handler that defers SIGTERM to the main loop is installed only after init() has returned. | `qrexec-agent.c:1049` | **none cited** |
| 35 | agent | The control vchan is closed by the only thread that ever uses it, so a close cannot run under a sender. | `qrexec-agent.c:1144` | qrexec-agent.c:2182, qrexec-agent.c:409 |
| 36 | agent | A MSG_SERVICE_CONNECT whose request ident does not name a pending request is logged and ignored, and the loop keeps serving. | `qrexec-agent.c:712` | **none cited** |
| 37 | agent | A full connection table is logged and the loop keeps serving every other call. | `qrexec-agent.c:541` | **none cited** |
| 38 | agent | An exec that needs the user session is parked until the session is ready and started then, instead of being failed on the session state at the moment it arrived. | `qrexec-agent.c:631` | **none cited** |
| 39 | agent | The dom0 peer accepts the connection only if the very first message it reads from the agent is MSG_HELLO. | `qrexec-daemon.c:246` | **none cited** |
| 40 | agent | The dom0 peer frees a data port only when the agent reports the exact domain and port pair it reserved, so the agent must report the pair it was given once that connection is over. | `qrexec-daemon.c:552` | qrexec-agent.c:543, qrexec-agent.c:548 |
| 41 | vchan-pipe | Linux reads from a trigger client only the bytes the request still needs, so anything further stays in the socket and holds the sender back instead of overflowing a buffer. | `qrexec-agent.c:870` | **none cited** |
| 42 | vchan-pipe | A request that arrived whole is served even if the client hangs up right after writing it, because the read loop stops as soon as the wanted bytes are in and never looks for EOF afterwards. | `qrexec-agent.c:869` | **none cited** |
| 43 | vchan-pipe | A client that connects and does not finish its request is closed after TRIGGER_CLIENT_TIMEOUT seconds. | `qrexec-agent.c:855` | **none cited** |
| 44 | vchan-pipe | The number of half-received requests is bounded by MAX_FDS and the oldest is dropped when the table is full, so new callers are still served. | `qrexec-agent.c:966` | **none cited** |
| 45 | vchan-pipe | Every accepted client descriptor is made non-blocking before use, so nothing a client does or fails to do can stall the loop that serves the others. | `qrexec-agent.c:943` | **none cited** |
| 46 | vchan-pipe | A trigger client is one accepted socket, so the peer that connected and the bytes read as its request cannot come from different processes. | `qrexec-agent.c:938` | **none cited** |
| 47 | vchan-pipe | A client whose request is invalid or cannot be read is closed at once on the error path. | `qrexec-agent.c:933` | **none cited** |
| 48 | vchan-pipe | The caller stays connected until dom0 answers and learns a refusal from the read on that same connection. | `qrexec-client-vm.c:286` | **none cited** |
| 49 | vchan-pipe | The trigger socket is created only after the control vchan exists and its handshake has completed, so no request can be accepted before the channel to dom0 is usable. | `qrexec-agent.c:417` | **none cited** |
| 50 | vchan-pipe | The control vchan is closed only after the single loop that accepts and forwards triggers has ended, so no trigger is sent on a closed vchan. | `qrexec-agent.c:1144` | qrexec-agent.c:409, qrexec-agent.c:2182 |
| 51 | vchan-pipe | A forwarded trigger goes into the ring as header then parameters with no other sender able to write in between. | `qrexec-agent.c:921` | qrexec-agent.c:391, qrexec-agent.c:486 |
| 52 | vchan-pipe | Trigger clients are polled only while the control vchan has room, so a full ring delays callers instead of blocking the loop inside a send. | `qrexec-agent.c:1071` | qrexec-agent.c:415, qrexec-agent.c:442 |
| 53 | vchan-pipe | The listening endpoint exists continuously with a backlog, so a caller that arrives while another is being accepted is queued, not refused. | `unix-server.c:55` | pipe-server.c:838, pipe-server.c:1108 |
| 54 | vchan-pipe | Buffered output is written until the buffer is empty before the flush reports OK, so accepted bytes are not discarded. | `write-stdin.c:43` | **none cited** |
| 55 | vchan-pipe | A write to a client loops until every byte is written or an error ends it. | `ioall.c:61` | qubes-io.c:32 |
| 56 | vchan-pipe | A vchan write that cannot proceed ends with failure when the channel reports an error, it does not wait for ever. | `txrx-vchan.c:59` | vchan-common.c:191, vchan-common.c:161 |
| 57 | vchan-pipe | A vchan read returns exactly the requested size or fails. | `txrx-vchan.c:72` | vchan-common.c:294, vchan-common.c:300 |
| 58 | vchan-pipe | The ring is checked before any blocking wait, so a condition that is already true is never slept on. | `txrx-vchan.c:38` | vchan-common.c:175, vchan-common.c:228 |
| 59 | vchan-pipe | The wait for the vchan peer to connect ends at a deadline with an error. | `vchan_timeout.c:46` | **none cited** |
| 60 | vchan-pipe | Bytes buffered for a slow reader are bounded by BUFFER_LIMIT. | `buffer.c:29` | pipe-server.c:1003, buffer.c:106 |
| 61 | cross-process | The calling side's data vchan server waits at most 120 s for its client and then exits, so a server nobody connected to does not stay published. | `qrexec-agent-data.c:373` | **none cited** |
| 62 | cross-process | The calling (non-service) side leaves its I/O loop, and only then closes the data vchan, when the local process AND the remote have both finished: it waits for the remote exit code. | `process_io.c:232` | **none cited** |
| 63 | cross-process | The service side's data client waits up to 120 s for a vchan server that is only created after the exec message was sent. | `qrexec-agent-data.c:231` | **none cited** |
| 64 | cross-process | The peer's HELLO is read and validated on the data vchan immediately before the service process is created, so a service runs only for a peer that is there at that moment. | `qrexec-agent-data.c:236` | **none cited** |
| 65 | cross-process | A request that must wait for a user session is postponed in the agent BEFORE any data vchan is connected; the connect happens only when the session exists. | `qrexec-agent.c:631` | **none cited** |
| 66 | cross-process | Each side's own HELLO is on the data vchan before any data message can be sent. | `qrexec-agent-data.c:102` | qrexec-wrapper.c:1929 |
| 67 | cross-process | The I/O loop is left on a closed vchan only when nothing is left to read from it. | `process_io.c:246` | qrexec-wrapper.c:2018 |
| 68 | cross-process | The service side sends its stream EOFs first and the exit code last, and closes only after that. | `process_io.c:226` | qrexec-wrapper.c:1099, qrexec-wrapper.c:1103 |
| 69 | cross-process | When the vchan closes early the handler still waits for its local process before it exits, so the connection is reported terminated only after that process is gone. | `process_io.c:393` | **none cited** |
| 70 | cross-process | The agent's HELLO exchange on the control vchan is complete before the socket that accepts in-VM callers exists, so no trigger can precede it. | `qrexec-agent.c:414` | **none cited** |
| 71 | cross-process | The rendezvous name in-VM callers connect to has exactly one listener, the agent, which unlinks and binds it itself. | `qrexec-agent.c:417` | **none cited** |
| 72 | cross-process | The caller reaches the agent with one connect that fails at once and ends the caller when the agent is not there; there is no second rendezvous step. | `qrexec-client-vm.c:66` | **none cited** |
| 73 | cross-process | The caller stays connected until the agent answers: it reads the connection parameters, or EOF which means refused. | `qrexec-client-vm.c:286` | **none cited** |
| 74 | cross-process | A caller that connected but has not delivered a complete request is dropped after 5 seconds. | `qrexec-agent.c:855` | **none cited** |
| 75 | cross-process | A request id is unique among the requests the agent has pending (Linux: it is the number of a descriptor held open until the answer). | `qrexec-agent.c:917` | qrexec-agent.c:1925 |
| 76 | cross-process | What an answer will be matched against exists before the trigger is on the control vchan. | `qrexec-agent.c:921` | qrexec-agent.c:1953 |
| 77 | cross-process | A control message reaches the daemon whole, header and body never split by another sender's bytes. | `qrexec-agent.c:923` | qrexec-agent.c:391, qrexec-agent.c:486 |
| 78 | cross-process | A service-connect answer for an id the agent does not know is logged and ignored; the agent keeps serving. | `qrexec-agent.c:712` | **none cited** |
| 79 | cross-process | MSG_CONNECTION_TERMINATED for a domain and port is sent once, when the process that owned that data vchan has exited. | `qrexec-agent.c:833` | qrexec-agent.c:1694, qrexec-agent.c:548 |
| 80 | cross-process | For a call to dom0, dom0 gives the VM's vchan server 5 seconds to exist and then gives the call up (the far side of round 1's unbounded server wait: the Windows server is a process that must first be created). | `qrexec-daemon.c:1256` | **none cited** |
| 81 | proc-service | The service process keeps only its three standard descriptors: everything else the parent had open is closed in the child before exec. | `exec.c:236` | qrexec-wrapper.c:285, exec.c:240 |
| 82 | proc-service | The parent closes its copies of the child's pipe ends immediately after the spawn, so end-of-file arrives when the child closes them. | `exec.c:291` | qrexec-wrapper.c:685, qrexec-wrapper.c:687 |
| 83 | proc-service | The forked child undoes the process state it inherited from the agent (signal mask, dispositions) before exec, so the service never runs with the agent's private settings. | `qrexec-agent.c:170` | **none cited** |
| 84 | proc-service | The switch to the requested user happens in the child before exec and a failure to switch ends the child instead of running the service with more privilege. | `qrexec-agent.c:297` | qrexec-wrapper.c:421 |
| 85 | proc-service | Every exited per-call child is reaped without blocking and produces exactly one MSG_CONNECTION_TERMINATED from the main loop. | `qrexec-agent.c:813` | qrexec-agent.c:1531, qrexec-agent.c:1694 |
| 86 | proc-service | The connection table has one owner: child exits are held off except inside the poll, so registering and releasing a connection cannot interleave. | `qrexec-agent.c:1054` | qrexec-agent.c:1111, qrexec-agent.c:508 |
| 87 | proc-service | The exit code goes out only after stdin, stdout and stderr have all reached end-of-file, so it is the last message on the wire. | `process_io.c:222` | qrexec-wrapper.c:2103, qrexec-wrapper.c:2151 |
| 88 | proc-service | After the child has exited the same loop keeps polling the vchan, so ring room is used when it appears and a closed vchan ends the wait at once. | `process_io.c:293` | **none cited** |
| 89 | proc-service | The exit code sent is the status of the child actually reaped by the process that forwards its output. | `process_io.c:211` | qrexec-wrapper.c:2066 |
| 90 | proc-service | A spawn failure is reported to the caller as an exit code on the data channel and ends only that call. | `qrexec-agent-data.c:271` | qrexec-wrapper.c:2434 |
| 91 | proc-service | The wait for the data-channel peer is bounded (120 s) in both roles before any process is started. | `qrexec-agent-data.c:231` | **none cited** |
| 92 | proc-service | Waiting for the user's session is done off the agent's main loop: the request is postponed and the loop keeps serving other calls. | `qrexec-agent.c:631` | qrexec-wrapper.c:566, qrexec-wrapper.c:502 |
| 93 | proc-service | Each call's QREXEC_REMOTE_DOMAIN is built into that child's own environment and never lives in the agent's. | `exec.c:152` | **none cited** |
| 94 | proc-service | A stop request is a flag the main loop tests on every pass, at most one poll timeout after it is raised. | `qrexec-agent.c:1061` | qrexec-agent.c:1493, qrexec-agent.c:1605 |
| 95 | proc-service | On stop the control vchan is closed by the loop's own thread after the loop has ended. | `qrexec-agent.c:1144` | qrexec-agent.c:2180, qrexec-agent.c:2185 |
| 96 | proc-service | Stopping the agent stops only the agent: calls in flight run in their own processes and are left to finish. | `qubes-qrexec-agent.service:9` | qrexec-agent.c:1107 |
| 97 | proc-service | Readiness is reported to the service manager only after the control channel is up and the daemon has connected. | `qrexec-agent.c:428` | **none cited** |
| 98 | proc-service | The unit is a notify-type service whose stopped state is the exit of its main process, so nothing of the old instance is still running when it is seen as stopped. | `qubes-qrexec-agent.service:6` | **none cited** |
| 99 | proc-service | A connect reply naming a request the agent does not know is logged and ignored; the agent keeps running. | `qrexec-agent.c:712` | **none cited** |
| 100 | proc-service | A full connection table costs only the tracking of that one call; the agent logs it and keeps running. | `qrexec-agent.c:541` | **none cited** |

## 7. Outside the three classes

These are not races, check-then-use windows or deadlocks. I read them on the way and you should know
about them. None was put to the judge.

### 7.1 The account a call's local program runs under is whatever the caller says (your decision)

Facts, all READ at today's heads:

- A program inside the qube makes a call by writing a request to the trigger pipe. The request carries
  a user name and a command line, the local program for that call. The agent reads both from the pipe
  client (`qrexec-agent.c:1887`, `:1917`) and, when dom0 allows the call, starts a wrapper with them
  (`:1193`).
- The pipe's descriptor gives Everyone read and write (`exec.c:416`).
- The names `SYSTEM` and `root` select the service's own token (`:1040-1055`, fork commit 1e9155e,
  2026-10-10). The literal `(null)` does the same in the wrapper (`qrexec-wrapper.c:2300`) and was
  already there at the fork base.
- Any other name runs the program on the token of whoever is logged on at the console. The name is
  compared with that account and a mismatch is logged, not refused (`qrexec-wrapper.c:594-599`).

- The caller program itself takes the user name as one of its arguments and writes it into the request
  (`qrexec-client-vm.c:57`, `:122-126`).

So any local account that can open the pipe can have a command line of its choosing run as SYSTEM, or
as the logged-on user, provided dom0's policy allows the call the request names; the guest's own
components make such calls routinely. On Linux this does not exist: the caller starts its own local
program, as itself (`agent/qrexec-client-vm.c:304`, `:330`), and a trigger carries neither a user nor
a command (`libqrexec/qrexec.h:152-155`; guarantee row 84).

**It was not tested.** One call from an unelevated prompt on a test guest, naming SYSTEM as the user
and `whoami` as the local program, to any service the policy allows, would settle it.

**Whether it matters depends on a position that is already written down.** `docs/ADR-uac.md`
(accepted 2026-08-28) says of the elevation prompt "we do not hide the question and we do not turn the
protection off", and of turning UAC off that it "is the Windows equivalent of passwordless sudo, it is
written down as exactly that, and nothing in our installer or harness ever sets it". Read against
that, this pipe is a way to SYSTEM that asks nobody, in a guest where the prompt was kept on purpose.
In a guest with `service.uac-disable` set it changes nothing. In a stock Linux qube root is one
passwordless `sudo` away by design, which is presumably why the inherited design never treated this as
a boundary.

**What is inherited and what is ours.** The user-name argument of the caller program, the agent
passing the pipe client's name through (base agent `:804`) and the wrapper's `(null)` case (base
wrapper `:904`) are all at the fork base, so stock QWT has the same path. At the base the `SYSTEM` and
`root` mapping applied only to commands from dom0 (base agent `:336`); 1e9155e moved it to where both
paths pass, which added two more names on this one.

The existing note `user-normalise-guard-is-gone.md` is about something else: that no test protects the
mapping for calls from dom0, where it is intended. This is the other path, and I found no decision on
it in `findings/` or `docs/`.

### 7.2 A disconnect by dom0's daemon stops the agent for the rest of the boot

`WatchForEvents` treats a closed control channel as a normal end and returns success
(`qrexec-agent.c:1665-1669`); the worker returns 0 (comment at `:2158-2162`; 7bcaad5 says "A stop
request and a daemon disconnect still return 0 (unchanged)"). A service that stops with 0 is not
restarted by the recovery actions the installer arms (ASSUMPTION: Microsoft's documentation of
failure actions). From then on no call works in either direction until the qube restarts or someone
starts the service; the display keeps working, so the qube looks alive. The Linux agent's main loop
has no exit on a daemon disconnect (`agent/qrexec-agent.c:1041-1147`, READ). Finding #6 ends here if
it is real. Captured logs: `WatchForEvents: daemon disconnected` occurs 0 times.

### 7.3 A request that fails before it is forwarded leaves its client object behind

`qrexec-agent.c:1931` is the only call to `QpsDisconnectClient`, on the success path. Every earlier
`goto cleanup` in the per-client thread keeps the host's reference, so the client object, its two
4096-byte queues and its lock stay allocated for the life of the agent. A local process can repeat
that at will. READ. MEASURED: in 750 distinct `connected (N total)` lines of captured agent logs, N
is 1 in 530, 2 in 141, 3 in 61 and 4 in 18, and the highest client id seen (295) has N = 1, so nothing
accumulated in those runs.

### 7.4 A pipe server that cannot be created is logged, and the agent runs on without one

`qrexec-agent.c:2106-2132`. Calls into the qube then work and calls from inside it never do. READ.

### 7.5 `QREXEC_REMOTE_DOMAIN` lives in the agent's own environment

Each incoming exec sets it with `SetEnvironmentVariable` in the agent (`qrexec-agent.c:1303`, beside
an inherited FIXME), and the next wrapper inherits it. A wrapper started for a call made inside the
qube therefore carries the domain of an unrelated earlier call. Both steps run on the main loop's
thread, so two calls cannot mix. Linux builds the variable into each child's own environment
(`libqrexec/exec.c:152`; row 93). READ.

### 7.6 The service process inherits every inheritable handle of the wrapper

`exec.c:254` creates the process with handle inheritance on whenever its I/O is piped; the wrapper
clears the flag on its own three pipe ends only (`qrexec-wrapper.c:285`, `:294`, `:304`). Linux closes
everything except the three standard descriptors before exec (`libqrexec/exec.c:236`; row 81). I did
not list which other handles are inheritable at that moment. READ for the two sites.

### 7.7 Latent: one over-long log line ends the process

The logger formats every line into a fixed buffer of 65536 characters with `vswprintf_s`
(`log.c:678`), and no invalid-parameter handler is installed anywhere in these programs. ASSUMPTION
(C runtime documentation): output that does not fit calls the default handler, which ends the
process. 70dd82e raised the accepted service name to 65000 bytes and the command line stands at 65536.
I did not trace a line that prints a whole field of that size.

### 7.8 Small ones

- `pipe-server.c:1135` writes the digit `L'0'` where a string terminator was meant (2024). Harmless
  today because the server sends the pipe name with its terminator (`:872-884`).
- Strings received from dom0 are used without checking for a terminator (`qrexec-agent.c:986-1004`).
  dom0 is trusted, so this is robustness only.
- Process ids are reused within about a second on these guests. MEASURED: five pairs of birth lines
  with the same pid, 953 to 1920 ms apart, in one captured relay-handler log, each with a complete
  life in between. Anything that identifies a wrapper by pid alone can be wrong.
- `log.c`, which I read in full: nothing beyond #35 in the three classes is reachable from the qrexec
  programs. They never use the raw-row path or `LogLock` (only commented-out `hex_dump` calls).
  `LogLock` enters the logger's lock whether or not the logger has started (`:73-76`), which matters
  to the components that do use it. The comment at `:506-509` describes a failure, a process left on
  stderr for its lifetime, that the per-process fallback directly below it now prevents.

### 7.9 A recorded wrapper crash I did not explain

MEASURED, `scratchpad/sweep-win11r-up-after-collapse-cell/logs/files/qrexec-wrapper-20261009.log:286-322`,
build 4.3.36.871, 67 seconds after boot:

```
[20261009.101759.501-8384:8388-I] LogInit: Command line: qrexec-wrapper.exe 10858|521|(null)|6|c:\Windows\System32\cmd.exe
[20261009.101759.501-8384:8388-E] ErrUEF: Unhandled exception c0000005 at 0000000000000000, flags: 0
[20261009.101759.545-8384:8388-E] ErrUEF: Parameter 0: 0000000000000008
[20261009.101759.612-8384:8388-E] ErrUEF: Parameter 1: 0000000000000000
```

That is a call through a null function pointer on the wrapper's main thread, in the same millisecond
as its command-line line. Six wrappers were born in that second, all serving calls into the qube
(same command line, ports 513 to 525); the other five logged `QGAVCHANFAIL`, a failed connect of the
data channel. This one died where its siblings reported that failure. It is the only wrapper crash in
the captured logs, and none of the 242 later wrapper births has one. I found no entry for it in
`findings/` under the terms I searched (`ErrUEF`, `c0000005`, "access violation", the address), and
the commit of that day that lists what the guest run found (c6b66f0) names three defects, none of them
a crash. I did not find the cause and I do not know whether today's code can still do it. That run was
the first on a guest of the build that folds the vchan library's failure records into one line
(dabaeed; c6b66f0 says so), which is where I would look first.

## 8. Limits of this audit

- **Nothing was run.** No probe, no fault injection, no guest. Every finding is a reading of source,
  and how often any of them happens is unknown.
- **The lower layers were read from reference copies.** The vchan library, xeniface and dom0's daemon
  were read under `upstream/ro/`, not from the binaries a guest runs. Every step that rests on them or
  on Win32 behaviour is marked ASSUMPTION.
- **A judge verdict is about an extract.** 21 of 35 candidates and most per-change `reference`
  answers have no verdict. No verdict is not a refutation and not a confirmation.
- **Two candidates are mine and had no second reader** (#34, #35), and the judge did not confirm #34.
- **The link between #9 and the crash of 2026-10-14 is inferred** from six log lines and the code of
  that day. The release that freed the client is logged at a level the capture does not have.
- **Captured logs are weak negative evidence.** They come from harness runs at the default level,
  several witness lines are DEBUG, and three were demoted by the fork itself. "Occurs 0 times" means
  not recorded.
- **The finders quoted source; a script checked every quote.** 1732 exact, 49 at a moved line, 4
  absent, 10 too short to check. A quote that exists can still be misread; the second readers and my
  own reads are the guard against that, and they did not cover every step of every candidate.
- **Scope.** Read in full by at least one finder pass: `qrexec-agent.c`, `qrexec-wrapper.c`,
  `qrexec-client-vm.c`, and in `winutils` `pipe-server.c`, `vchan-common.c`, `exec.c`, `service.c`
  and `buffer.c`. `log.c` was read by the finders only in its start-up and formatting parts; I read
  it in full at the end, after the judge had finished. `qubes-io.c` was read in part (lines 25-100).
  Not covered: the GUI agent, the display driver, the qubesdb daemon except where it shares the pipe
  server, the file sender and receiver, the PowerShell services, the updates relay, and everything in
  dom0.
- **The plan's expectation was wrong.** It expected the defects "mostly in code our fork added"; 27 of
  35 sit on inherited lines. Its stop rule (more than 80 percent inherited) did not fire at 77 percent.
- **The first target list was wrong.** I had left `exec.c`, `service.c` and `log.c` out. After you
  objected, `exec.c` and `service.c` went back in as a fifth unit, which followed `log.c` only where
  they call into it; #3, #15 and #29 come from that unit, and #35 from my own read of `log.c`.

## 9. How this was produced, what it cost, and where the pieces are

**Finders.** Five units (wrapper, agent, pipe and vchan plumbing, cross-process, process creation and
service), two rounds each. Every finder read its unit's files in full and returned claims with quoted
lines, plus the twenty Linux guarantees of section 6. A script merged claims at the same site and
class (10 claims into 9 candidates), a second agent re-derived each candidate from the source, and I
added two candidates of my own. 91 agents, 70.2 minutes, 4,442,298 subagent tokens.

**Judge.** 189 extracts, 1,910,627 input tokens: the 75 changes once (461,799), 51 of them again
with wider context (619,611), the 35 candidates once (345,514), and 28 of them again (483,703).

**My own reading** is what sections 3, 5.3 and 7 are graded READ on, plus the log searches graded
MEASURED. The crash-log reading behind #9, the search that found the wrapper crash of 7.9 and the
full read of `log.c` were done after the judge had finished; none of them was put to it.

**Files.** This report is `docs/AUDIT-qrexec.md`. What it was built from is under
`scratchpad/qrexec-audit/`, untracked:

| File | What it is |
|---|---|
| `REPORT.md` | this report as first written, before it was committed |
| `cands/<n>.claim.txt`, `.source.txt`, `.linux.txt`, `.meta.json`, `.facts.json` | each candidate: the claim, the Windows and Linux extracts the judge saw, and the script's facts |
| `jc-table.txt`, `jc2-table.txt` | the judge's answers on the candidates, first ask and re-ask (Appendix A) |
| `out-table.txt`, `jr-table.txt` | the judge's answers on the 75 changes, first and second pass, as printed |
| `units/` | the extract of each change unit |
| `gen-cands.md`, `gen-changes.md`, `gen-guarantees.md` | the three generated tables of sections 4, 5.6 and 6.2 |
| `wf-result.json`, `wf-result-plus.json` | everything the workflow returned; the second adds my two candidates |
| `main-thread-notes.md` | my own reads, with line numbers and blame |
| `qrexec-audit.py`, `rubric-*.json` | the pipeline script and the three sets of questions |
| `../workflow-plan-qrexec-conc-audit.md` | the plan written before the run, with the model tier of each stage |
| `../crash-excerpt.log` | the agent crash of 2026-10-14 used in #9 |

## Appendix A. The judge's answers on the 35 candidates, as printed

One row per candidate: its number, the input tokens of the call, then for each question the choice,
its confidence and the full distribution. `WEAK:` lists the questions that stayed under the floor. The
rule that turns the two tables into the verdicts quoted in the text is in section 2.

### A.1 First ask (35 candidates)

```
1		in=11233	real choice=possible_as_shown conf=0.65 [possible_as_shown=0.74 insufficient_evidence=0.12 claim_misreads_source=0.08 prevented_as_shown=0.06]	impact choice=user_visible conf=0.98 [user_visible=0.99 insufficient_evidence=0.01 internal_only=0.00]	reference choice=diverges_from_reference conf=0.60 [diverges_from_reference=0.70 matches_reference=0.15 no_counterpart=0.12 insufficient_evidence=0.03]	WEAK:real,reference
10		in=8812	real choice=possible_as_shown conf=0.65 [possible_as_shown=0.74 insufficient_evidence=0.12 claim_misreads_source=0.10 prevented_as_shown=0.04]	impact choice=user_visible conf=0.92 [user_visible=0.95 insufficient_evidence=0.05 internal_only=0.00]	reference choice=diverges_from_reference conf=0.76 [diverges_from_reference=0.82 no_counterpart=0.14 matches_reference=0.02 insufficient_evidence=0.02]	WEAK:real
11		in=10286	real choice=possible_as_shown conf=0.71 [possible_as_shown=0.78 claim_misreads_source=0.10 prevented_as_shown=0.08 insufficient_evidence=0.04]	impact choice=user_visible conf=0.98 [user_visible=0.99 insufficient_evidence=0.01 internal_only=0.00]	reference choice=no_counterpart conf=0.65 [no_counterpart=0.74 diverges_from_reference=0.18 matches_reference=0.04 insufficient_evidence=0.04]	WEAK:reference
12		in=9143	real choice=possible_as_shown conf=0.51 [possible_as_shown=0.63 insufficient_evidence=0.24 claim_misreads_source=0.10 prevented_as_shown=0.03]	impact choice=user_visible conf=0.85 [user_visible=0.90 insufficient_evidence=0.09 internal_only=0.01]	reference choice=diverges_from_reference conf=0.64 [diverges_from_reference=0.73 no_counterpart=0.20 matches_reference=0.04 insufficient_evidence=0.03]	WEAK:real,reference
13		in=8011	real choice=possible_as_shown conf=0.31 [possible_as_shown=0.48 insufficient_evidence=0.36 claim_misreads_source=0.11 prevented_as_shown=0.05]	impact choice=user_visible conf=0.97 [user_visible=0.98 insufficient_evidence=0.02 internal_only=0.00]	reference choice=diverges_from_reference conf=0.24 [diverges_from_reference=0.43 no_counterpart=0.36 matches_reference=0.18 insufficient_evidence=0.03]	WEAK:real,reference
14		in=8631	real choice=possible_as_shown conf=0.51 [possible_as_shown=0.63 insufficient_evidence=0.29 claim_misreads_source=0.07 prevented_as_shown=0.01]	impact choice=user_visible conf=0.96 [user_visible=0.97 insufficient_evidence=0.02 internal_only=0.01]	reference choice=diverges_from_reference conf=0.51 [diverges_from_reference=0.63 matches_reference=0.29 insufficient_evidence=0.06 no_counterpart=0.02]	WEAK:real,reference
15		in=10399	real choice=possible_as_shown conf=0.87 [possible_as_shown=0.90 insufficient_evidence=0.05 prevented_as_shown=0.03 claim_misreads_source=0.02]	impact choice=user_visible conf=0.98 [user_visible=0.99 insufficient_evidence=0.01 internal_only=0.00]	reference choice=diverges_from_reference conf=0.92 [diverges_from_reference=0.94 no_counterpart=0.05 matches_reference=0.01 insufficient_evidence=0.00]
16		in=8832	real choice=possible_as_shown conf=0.84 [possible_as_shown=0.88 insufficient_evidence=0.06 claim_misreads_source=0.04 prevented_as_shown=0.02]	impact choice=user_visible conf=0.96 [user_visible=0.97 internal_only=0.02 insufficient_evidence=0.01]	reference choice=diverges_from_reference conf=0.95 [diverges_from_reference=0.96 matches_reference=0.03 no_counterpart=0.01 insufficient_evidence=0.00]
17		in=12078	real choice=possible_as_shown conf=0.89 [possible_as_shown=0.92 insufficient_evidence=0.04 prevented_as_shown=0.02 claim_misreads_source=0.02]	impact choice=user_visible conf=0.97 [user_visible=0.98 internal_only=0.01 insufficient_evidence=0.01]	reference choice=diverges_from_reference conf=0.75 [diverges_from_reference=0.81 matches_reference=0.09 no_counterpart=0.08 insufficient_evidence=0.02]
18		in=10435	real choice=possible_as_shown conf=0.36 [possible_as_shown=0.52 insufficient_evidence=0.24 prevented_as_shown=0.15 claim_misreads_source=0.09]	impact choice=user_visible conf=0.74 [user_visible=0.83 insufficient_evidence=0.17 internal_only=0.00]	reference choice=diverges_from_reference conf=0.85 [diverges_from_reference=0.89 matches_reference=0.07 no_counterpart=0.02 insufficient_evidence=0.02]	WEAK:real
19		in=14520	real choice=prevented_as_shown conf=0.11 [prevented_as_shown=0.33 possible_as_shown=0.31 insufficient_evidence=0.22 claim_misreads_source=0.14]	impact choice=user_visible conf=0.89 [user_visible=0.93 insufficient_evidence=0.06 internal_only=0.01]	reference choice=diverges_from_reference conf=0.71 [diverges_from_reference=0.78 no_counterpart=0.12 matches_reference=0.09 insufficient_evidence=0.01]	WEAK:real
2		in=10215	real choice=possible_as_shown conf=0.63 [possible_as_shown=0.72 claim_misreads_source=0.13 prevented_as_shown=0.12 insufficient_evidence=0.03]	impact choice=user_visible conf=0.86 [user_visible=0.91 insufficient_evidence=0.05 internal_only=0.04]	reference choice=diverges_from_reference conf=0.44 [diverges_from_reference=0.58 no_counterpart=0.27 matches_reference=0.10 insufficient_evidence=0.05]	WEAK:real,reference
20		in=10705	real choice=possible_as_shown conf=0.85 [possible_as_shown=0.89 claim_misreads_source=0.06 insufficient_evidence=0.03 prevented_as_shown=0.02]	impact choice=user_visible conf=0.97 [user_visible=0.98 internal_only=0.01 insufficient_evidence=0.01]	reference choice=diverges_from_reference conf=0.83 [diverges_from_reference=0.87 no_counterpart=0.09 matches_reference=0.03 insufficient_evidence=0.01]
21		in=9252	real choice=possible_as_shown conf=0.47 [possible_as_shown=0.60 prevented_as_shown=0.18 claim_misreads_source=0.11 insufficient_evidence=0.11]	impact choice=user_visible conf=0.85 [user_visible=0.90 insufficient_evidence=0.10 internal_only=0.00]	reference choice=diverges_from_reference conf=0.61 [diverges_from_reference=0.71 matches_reference=0.20 insufficient_evidence=0.05 no_counterpart=0.04]	WEAK:real,reference
22		in=7849	real choice=possible_as_shown conf=0.73 [possible_as_shown=0.80 insufficient_evidence=0.12 prevented_as_shown=0.05 claim_misreads_source=0.03]	impact choice=user_visible conf=0.98 [user_visible=0.99 insufficient_evidence=0.01 internal_only=0.00]	reference choice=diverges_from_reference conf=0.84 [diverges_from_reference=0.88 no_counterpart=0.08 matches_reference=0.02 insufficient_evidence=0.02]
23		in=10146	real choice=possible_as_shown conf=0.69 [possible_as_shown=0.77 insufficient_evidence=0.14 claim_misreads_source=0.05 prevented_as_shown=0.04]	impact choice=user_visible conf=0.97 [user_visible=0.98 internal_only=0.01 insufficient_evidence=0.01]	reference choice=diverges_from_reference conf=0.85 [diverges_from_reference=0.89 matches_reference=0.07 no_counterpart=0.03 insufficient_evidence=0.01]	WEAK:real
24		in=9361	real choice=possible_as_shown conf=0.47 [possible_as_shown=0.60 insufficient_evidence=0.17 prevented_as_shown=0.13 claim_misreads_source=0.10]	impact choice=user_visible conf=0.96 [user_visible=0.97 insufficient_evidence=0.03 internal_only=0.00]	reference choice=no_counterpart conf=0.89 [no_counterpart=0.92 diverges_from_reference=0.04 insufficient_evidence=0.03 matches_reference=0.01]	WEAK:real
25		in=9135	real choice=possible_as_shown conf=0.93 [possible_as_shown=0.95 insufficient_evidence=0.03 claim_misreads_source=0.02 prevented_as_shown=0.00]	impact choice=user_visible conf=0.49 [user_visible=0.66 internal_only=0.32 insufficient_evidence=0.02]	reference choice=no_counterpart conf=0.64 [no_counterpart=0.73 diverges_from_reference=0.20 matches_reference=0.05 insufficient_evidence=0.02]	WEAK:impact,reference
26		in=6842	real choice=possible_as_shown conf=0.72 [possible_as_shown=0.79 insufficient_evidence=0.15 claim_misreads_source=0.04 prevented_as_shown=0.02]	impact choice=internal_only conf=0.33 [internal_only=0.55 user_visible=0.40 insufficient_evidence=0.05]	reference choice=diverges_from_reference conf=0.88 [diverges_from_reference=0.91 matches_reference=0.07 no_counterpart=0.01 insufficient_evidence=0.01]	WEAK:impact
27		in=9676	real choice=possible_as_shown conf=0.81 [possible_as_shown=0.86 prevented_as_shown=0.07 claim_misreads_source=0.06 insufficient_evidence=0.01]	impact choice=user_visible conf=0.50 [user_visible=0.67 internal_only=0.29 insufficient_evidence=0.04]	reference choice=no_counterpart conf=0.27 [no_counterpart=0.45 diverges_from_reference=0.44 matches_reference=0.09 insufficient_evidence=0.02]	WEAK:impact,reference
28		in=8918	real choice=possible_as_shown conf=0.57 [possible_as_shown=0.68 claim_misreads_source=0.18 prevented_as_shown=0.12 insufficient_evidence=0.02]	impact choice=user_visible conf=0.96 [user_visible=0.97 insufficient_evidence=0.03 internal_only=0.00]	reference choice=no_counterpart conf=0.56 [no_counterpart=0.67 diverges_from_reference=0.23 matches_reference=0.05 insufficient_evidence=0.05]	WEAK:real,reference
29		in=8438	real choice=possible_as_shown conf=0.84 [possible_as_shown=0.88 prevented_as_shown=0.07 claim_misreads_source=0.03 insufficient_evidence=0.02]	impact choice=user_visible conf=0.98 [user_visible=0.99 insufficient_evidence=0.01 internal_only=0.00]	reference choice=no_counterpart conf=0.93 [no_counterpart=0.95 diverges_from_reference=0.03 matches_reference=0.01 insufficient_evidence=0.01]
3		in=10505	real choice=possible_as_shown conf=0.36 [possible_as_shown=0.52 claim_misreads_source=0.23 insufficient_evidence=0.20 prevented_as_shown=0.05]	impact choice=user_visible conf=0.89 [user_visible=0.93 insufficient_evidence=0.07 internal_only=0.00]	reference choice=no_counterpart conf=0.64 [no_counterpart=0.73 diverges_from_reference=0.22 insufficient_evidence=0.03 matches_reference=0.02]	WEAK:real,reference
30		in=8689	real choice=possible_as_shown conf=0.72 [possible_as_shown=0.79 insufficient_evidence=0.16 claim_misreads_source=0.04 prevented_as_shown=0.01]	impact choice=user_visible conf=0.26 [user_visible=0.51 internal_only=0.30 insufficient_evidence=0.19]	reference choice=no_counterpart conf=0.47 [no_counterpart=0.60 diverges_from_reference=0.21 matches_reference=0.13 insufficient_evidence=0.06]	WEAK:impact,reference
31		in=7767	real choice=possible_as_shown conf=0.65 [possible_as_shown=0.74 insufficient_evidence=0.12 claim_misreads_source=0.10 prevented_as_shown=0.04]	impact choice=user_visible conf=0.88 [user_visible=0.92 insufficient_evidence=0.08 internal_only=0.00]	reference choice=diverges_from_reference conf=0.51 [diverges_from_reference=0.63 no_counterpart=0.19 matches_reference=0.13 insufficient_evidence=0.05]	WEAK:real,reference
32		in=8990	real choice=possible_as_shown conf=0.91 [possible_as_shown=0.93 prevented_as_shown=0.04 claim_misreads_source=0.02 insufficient_evidence=0.01]	impact choice=user_visible conf=0.97 [user_visible=0.98 internal_only=0.01 insufficient_evidence=0.01]	reference choice=diverges_from_reference conf=0.89 [diverges_from_reference=0.92 no_counterpart=0.04 matches_reference=0.03 insufficient_evidence=0.01]
33		in=8917	real choice=possible_as_shown conf=0.39 [possible_as_shown=0.54 insufficient_evidence=0.35 claim_misreads_source=0.08 prevented_as_shown=0.03]	impact choice=user_visible conf=0.85 [user_visible=0.90 insufficient_evidence=0.10 internal_only=0.00]	reference choice=diverges_from_reference conf=0.77 [diverges_from_reference=0.83 no_counterpart=0.08 matches_reference=0.05 insufficient_evidence=0.04]	WEAK:real
34		in=7481	real choice=possible_as_shown conf=0.45 [possible_as_shown=0.59 claim_misreads_source=0.22 insufficient_evidence=0.10 prevented_as_shown=0.09]	impact choice=user_visible conf=0.91 [user_visible=0.94 insufficient_evidence=0.06 internal_only=0.00]	reference choice=diverges_from_reference conf=0.55 [diverges_from_reference=0.66 insufficient_evidence=0.16 no_counterpart=0.14 matches_reference=0.04]	WEAK:real,reference
35		in=11898	real choice=possible_as_shown conf=0.63 [possible_as_shown=0.72 claim_misreads_source=0.12 prevented_as_shown=0.10 insufficient_evidence=0.06]	impact choice=user_visible conf=0.74 [user_visible=0.83 internal_only=0.14 insufficient_evidence=0.03]	reference choice=no_counterpart conf=0.63 [no_counterpart=0.72 diverges_from_reference=0.14 matches_reference=0.11 insufficient_evidence=0.03]	WEAK:real,reference
4		in=13922	real choice=possible_as_shown conf=0.64 [possible_as_shown=0.73 prevented_as_shown=0.11 insufficient_evidence=0.11 claim_misreads_source=0.05]	impact choice=user_visible conf=0.97 [user_visible=0.98 insufficient_evidence=0.02 internal_only=0.00]	reference choice=diverges_from_reference conf=0.93 [diverges_from_reference=0.95 matches_reference=0.03 no_counterpart=0.01 insufficient_evidence=0.01]	WEAK:real
5		in=10397	real choice=insufficient_evidence conf=0.51 [insufficient_evidence=0.63 possible_as_shown=0.26 claim_misreads_source=0.07 prevented_as_shown=0.04]	impact choice=user_visible conf=0.91 [user_visible=0.94 insufficient_evidence=0.06 internal_only=0.00]	reference choice=diverges_from_reference conf=0.99 [diverges_from_reference=0.99 matches_reference=0.01 no_counterpart=0.00 insufficient_evidence=0.00]	WEAK:real
6		in=11201	real choice=possible_as_shown conf=0.53 [possible_as_shown=0.65 prevented_as_shown=0.14 insufficient_evidence=0.14 claim_misreads_source=0.07]	impact choice=user_visible conf=0.86 [user_visible=0.91 insufficient_evidence=0.08 internal_only=0.01]	reference choice=diverges_from_reference conf=0.56 [diverges_from_reference=0.67 matches_reference=0.16 no_counterpart=0.16 insufficient_evidence=0.01]	WEAK:real,reference
7		in=13096	real choice=possible_as_shown conf=0.41 [possible_as_shown=0.56 prevented_as_shown=0.23 claim_misreads_source=0.13 insufficient_evidence=0.08]	impact choice=user_visible conf=0.98 [user_visible=0.99 insufficient_evidence=0.01 internal_only=0.00]	reference choice=diverges_from_reference conf=0.44 [diverges_from_reference=0.58 no_counterpart=0.25 matches_reference=0.13 insufficient_evidence=0.04]	WEAK:real,reference
8		in=9145	real choice=possible_as_shown conf=0.41 [possible_as_shown=0.56 insufficient_evidence=0.32 claim_misreads_source=0.09 prevented_as_shown=0.03]	impact choice=user_visible conf=0.85 [user_visible=0.90 internal_only=0.06 insufficient_evidence=0.04]	reference choice=diverges_from_reference conf=1.00 [diverges_from_reference=1.00 matches_reference=0.00 no_counterpart=0.00 insufficient_evidence=0.00]	WEAK:real
9		in=10589	real choice=possible_as_shown conf=0.83 [possible_as_shown=0.87 prevented_as_shown=0.07 claim_misreads_source=0.05 insufficient_evidence=0.01]	impact choice=user_visible conf=0.98 [user_visible=0.99 insufficient_evidence=0.01 internal_only=0.00]	reference choice=no_counterpart conf=0.29 [no_counterpart=0.47 diverges_from_reference=0.45 matches_reference=0.05 insufficient_evidence=0.03]	WEAK:reference
35 answer file(s), 28 with at least one verdict under 0.70 or insufficient_evidence
```

### A.2 Second ask with a wider extract (28 candidates)

```
1		in=19907	real choice=possible_as_shown conf=0.67 [possible_as_shown=0.75 prevented_as_shown=0.10 insufficient_evidence=0.08 claim_misreads_source=0.07]	impact choice=user_visible conf=0.98 [user_visible=0.99 insufficient_evidence=0.01 internal_only=0.00]	reference choice=diverges_from_reference conf=0.87 [diverges_from_reference=0.90 matches_reference=0.06 no_counterpart=0.03 insufficient_evidence=0.01]	WEAK:real
10		in=14417	real choice=possible_as_shown conf=0.57 [possible_as_shown=0.68 claim_misreads_source=0.14 insufficient_evidence=0.11 prevented_as_shown=0.07]	impact choice=user_visible conf=0.94 [user_visible=0.96 insufficient_evidence=0.04 internal_only=0.00]	reference choice=diverges_from_reference conf=0.87 [diverges_from_reference=0.90 no_counterpart=0.07 matches_reference=0.02 insufficient_evidence=0.01]	WEAK:real
11		in=17644	real choice=possible_as_shown conf=0.64 [possible_as_shown=0.73 claim_misreads_source=0.15 prevented_as_shown=0.09 insufficient_evidence=0.03]	impact choice=user_visible conf=0.98 [user_visible=0.99 insufficient_evidence=0.01 internal_only=0.00]	reference choice=no_counterpart conf=0.69 [no_counterpart=0.77 diverges_from_reference=0.16 insufficient_evidence=0.04 matches_reference=0.03]	WEAK:real,reference
12		in=17114	real choice=possible_as_shown conf=0.56 [possible_as_shown=0.67 insufficient_evidence=0.19 claim_misreads_source=0.11 prevented_as_shown=0.03]	impact choice=user_visible conf=0.83 [user_visible=0.89 insufficient_evidence=0.10 internal_only=0.01]	reference choice=diverges_from_reference conf=0.77 [diverges_from_reference=0.83 no_counterpart=0.13 matches_reference=0.03 insufficient_evidence=0.01]	WEAK:real
13		in=13669	real choice=insufficient_evidence conf=0.24 [possible_as_shown=0.43 insufficient_evidence=0.43 claim_misreads_source=0.10 prevented_as_shown=0.04]	impact choice=user_visible conf=0.98 [user_visible=0.99 insufficient_evidence=0.01 internal_only=0.00]	reference choice=diverges_from_reference conf=0.27 [diverges_from_reference=0.45 no_counterpart=0.36 matches_reference=0.17 insufficient_evidence=0.02]	WEAK:real,reference
14		in=15939	real choice=possible_as_shown conf=0.48 [possible_as_shown=0.61 insufficient_evidence=0.31 claim_misreads_source=0.07 prevented_as_shown=0.01]	impact choice=user_visible conf=0.92 [user_visible=0.95 insufficient_evidence=0.04 internal_only=0.01]	reference choice=diverges_from_reference conf=0.59 [diverges_from_reference=0.69 matches_reference=0.23 insufficient_evidence=0.06 no_counterpart=0.02]	WEAK:real,reference
18		in=20818	real choice=possible_as_shown conf=0.35 [possible_as_shown=0.51 prevented_as_shown=0.19 insufficient_evidence=0.17 claim_misreads_source=0.13]	impact choice=user_visible conf=0.72 [user_visible=0.81 insufficient_evidence=0.18 internal_only=0.01]	reference choice=diverges_from_reference conf=0.85 [diverges_from_reference=0.89 matches_reference=0.08 no_counterpart=0.02 insufficient_evidence=0.01]	WEAK:real
19		in=26430	real choice=possible_as_shown conf=0.17 [possible_as_shown=0.38 prevented_as_shown=0.34 insufficient_evidence=0.20 claim_misreads_source=0.08]	impact choice=user_visible conf=0.89 [user_visible=0.93 insufficient_evidence=0.06 internal_only=0.01]	reference choice=diverges_from_reference conf=0.72 [diverges_from_reference=0.79 matches_reference=0.10 no_counterpart=0.09 insufficient_evidence=0.02]	WEAK:real
2		in=15784	real choice=possible_as_shown conf=0.57 [possible_as_shown=0.68 claim_misreads_source=0.15 prevented_as_shown=0.14 insufficient_evidence=0.03]	impact choice=user_visible conf=0.88 [user_visible=0.92 internal_only=0.04 insufficient_evidence=0.04]	reference choice=diverges_from_reference conf=0.39 [diverges_from_reference=0.54 no_counterpart=0.30 matches_reference=0.13 insufficient_evidence=0.03]	WEAK:real,reference
21		in=17932	real choice=possible_as_shown conf=0.19 [possible_as_shown=0.39 prevented_as_shown=0.35 claim_misreads_source=0.18 insufficient_evidence=0.08]	impact choice=user_visible conf=0.77 [user_visible=0.85 insufficient_evidence=0.14 internal_only=0.01]	reference choice=diverges_from_reference conf=0.68 [diverges_from_reference=0.76 matches_reference=0.18 insufficient_evidence=0.04 no_counterpart=0.02]	WEAK:real,reference
23		in=18768	real choice=possible_as_shown conf=0.61 [possible_as_shown=0.71 insufficient_evidence=0.18 claim_misreads_source=0.06 prevented_as_shown=0.05]	impact choice=user_visible conf=0.97 [user_visible=0.98 internal_only=0.01 insufficient_evidence=0.01]	reference choice=diverges_from_reference conf=0.80 [diverges_from_reference=0.85 matches_reference=0.10 no_counterpart=0.04 insufficient_evidence=0.01]	WEAK:real
24		in=17724	real choice=possible_as_shown conf=0.56 [possible_as_shown=0.67 insufficient_evidence=0.12 prevented_as_shown=0.11 claim_misreads_source=0.10]	impact choice=user_visible conf=0.96 [user_visible=0.97 insufficient_evidence=0.03 internal_only=0.00]	reference choice=no_counterpart conf=0.89 [no_counterpart=0.92 diverges_from_reference=0.05 insufficient_evidence=0.02 matches_reference=0.01]	WEAK:real
25		in=14614	real choice=possible_as_shown conf=0.96 [possible_as_shown=0.97 claim_misreads_source=0.02 insufficient_evidence=0.01 prevented_as_shown=0.00]	impact choice=user_visible conf=0.55 [user_visible=0.70 internal_only=0.29 insufficient_evidence=0.01]	reference choice=no_counterpart conf=0.53 [no_counterpart=0.65 diverges_from_reference=0.26 matches_reference=0.08 insufficient_evidence=0.01]	WEAK:impact,reference
26		in=11721	real choice=possible_as_shown conf=0.76 [possible_as_shown=0.82 insufficient_evidence=0.12 claim_misreads_source=0.04 prevented_as_shown=0.02]	impact choice=internal_only conf=0.38 [internal_only=0.59 user_visible=0.36 insufficient_evidence=0.05]	reference choice=diverges_from_reference conf=0.95 [diverges_from_reference=0.96 matches_reference=0.04 no_counterpart=0.00 insufficient_evidence=0.00]	WEAK:impact
27		in=14972	real choice=possible_as_shown conf=0.75 [possible_as_shown=0.81 prevented_as_shown=0.11 claim_misreads_source=0.07 insufficient_evidence=0.01]	impact choice=user_visible conf=0.50 [user_visible=0.67 internal_only=0.29 insufficient_evidence=0.04]	reference choice=diverges_from_reference conf=0.40 [diverges_from_reference=0.55 no_counterpart=0.38 matches_reference=0.06 insufficient_evidence=0.01]	WEAK:impact,reference
28		in=13738	real choice=possible_as_shown conf=0.36 [possible_as_shown=0.52 claim_misreads_source=0.23 prevented_as_shown=0.22 insufficient_evidence=0.03]	impact choice=user_visible conf=0.96 [user_visible=0.97 insufficient_evidence=0.03 internal_only=0.00]	reference choice=no_counterpart conf=0.57 [no_counterpart=0.68 diverges_from_reference=0.23 matches_reference=0.06 insufficient_evidence=0.03]	WEAK:real,reference
3		in=18277	real choice=possible_as_shown conf=0.39 [possible_as_shown=0.54 claim_misreads_source=0.26 insufficient_evidence=0.15 prevented_as_shown=0.05]	impact choice=user_visible conf=0.89 [user_visible=0.93 insufficient_evidence=0.07 internal_only=0.00]	reference choice=no_counterpart conf=0.44 [no_counterpart=0.58 diverges_from_reference=0.36 matches_reference=0.03 insufficient_evidence=0.03]	WEAK:real,reference
30		in=15247	real choice=possible_as_shown conf=0.79 [possible_as_shown=0.84 insufficient_evidence=0.11 claim_misreads_source=0.04 prevented_as_shown=0.01]	impact choice=user_visible conf=0.34 [user_visible=0.56 internal_only=0.29 insufficient_evidence=0.15]	reference choice=no_counterpart conf=0.25 [no_counterpart=0.44 diverges_from_reference=0.29 matches_reference=0.21 insufficient_evidence=0.06]	WEAK:impact,reference
31		in=12326	real choice=possible_as_shown conf=0.67 [possible_as_shown=0.75 claim_misreads_source=0.11 insufficient_evidence=0.09 prevented_as_shown=0.05]	impact choice=user_visible conf=0.88 [user_visible=0.92 insufficient_evidence=0.08 internal_only=0.00]	reference choice=diverges_from_reference conf=0.71 [diverges_from_reference=0.78 matches_reference=0.14 no_counterpart=0.06 insufficient_evidence=0.02]	WEAK:real
33		in=15081	real choice=possible_as_shown conf=0.43 [possible_as_shown=0.57 insufficient_evidence=0.29 claim_misreads_source=0.10 prevented_as_shown=0.04]	impact choice=user_visible conf=0.86 [user_visible=0.91 insufficient_evidence=0.09 internal_only=0.00]	reference choice=diverges_from_reference conf=0.84 [diverges_from_reference=0.88 no_counterpart=0.06 matches_reference=0.04 insufficient_evidence=0.02]	WEAK:real
34		in=12566	real choice=possible_as_shown conf=0.37 [possible_as_shown=0.53 claim_misreads_source=0.26 prevented_as_shown=0.15 insufficient_evidence=0.06]	impact choice=user_visible conf=0.89 [user_visible=0.93 insufficient_evidence=0.06 internal_only=0.01]	reference choice=diverges_from_reference conf=0.71 [diverges_from_reference=0.78 no_counterpart=0.11 insufficient_evidence=0.06 matches_reference=0.05]	WEAK:real
35		in=18182	real choice=possible_as_shown conf=0.72 [possible_as_shown=0.79 prevented_as_shown=0.11 claim_misreads_source=0.07 insufficient_evidence=0.03]	impact choice=user_visible conf=0.73 [user_visible=0.82 internal_only=0.16 insufficient_evidence=0.02]	reference choice=no_counterpart conf=0.45 [no_counterpart=0.59 diverges_from_reference=0.22 matches_reference=0.15 insufficient_evidence=0.04]	WEAK:reference
4		in=23137	real choice=possible_as_shown conf=0.63 [possible_as_shown=0.72 prevented_as_shown=0.13 insufficient_evidence=0.08 claim_misreads_source=0.07]	impact choice=user_visible conf=0.98 [user_visible=0.99 insufficient_evidence=0.01 internal_only=0.00]	reference choice=diverges_from_reference conf=0.89 [diverges_from_reference=0.92 matches_reference=0.06 no_counterpart=0.01 insufficient_evidence=0.01]	WEAK:real
5		in=20550	real choice=insufficient_evidence conf=0.44 [insufficient_evidence=0.58 possible_as_shown=0.31 claim_misreads_source=0.07 prevented_as_shown=0.04]	impact choice=user_visible conf=0.92 [user_visible=0.95 insufficient_evidence=0.05 internal_only=0.00]	reference choice=diverges_from_reference conf=1.00 [diverges_from_reference=1.00 matches_reference=0.00 no_counterpart=0.00 insufficient_evidence=0.00]	WEAK:real
6		in=20865	real choice=possible_as_shown conf=0.61 [possible_as_shown=0.71 insufficient_evidence=0.13 prevented_as_shown=0.09 claim_misreads_source=0.07]	impact choice=user_visible conf=0.89 [user_visible=0.93 insufficient_evidence=0.06 internal_only=0.01]	reference choice=diverges_from_reference conf=0.53 [diverges_from_reference=0.65 no_counterpart=0.20 matches_reference=0.14 insufficient_evidence=0.01]	WEAK:real,reference
7		in=23669	real choice=possible_as_shown conf=0.37 [possible_as_shown=0.53 prevented_as_shown=0.26 claim_misreads_source=0.13 insufficient_evidence=0.08]	impact choice=user_visible conf=0.98 [user_visible=0.99 insufficient_evidence=0.01 internal_only=0.00]	reference choice=diverges_from_reference conf=0.29 [diverges_from_reference=0.47 no_counterpart=0.36 matches_reference=0.13 insufficient_evidence=0.04]	WEAK:real,reference
8		in=17068	real choice=possible_as_shown conf=0.39 [possible_as_shown=0.54 insufficient_evidence=0.25 claim_misreads_source=0.13 prevented_as_shown=0.08]	impact choice=user_visible conf=0.88 [user_visible=0.92 internal_only=0.05 insufficient_evidence=0.03]	reference choice=diverges_from_reference conf=1.00 [diverges_from_reference=1.00 matches_reference=0.00 no_counterpart=0.00 insufficient_evidence=0.00]	WEAK:real
9		in=15544	real choice=possible_as_shown conf=0.83 [possible_as_shown=0.87 prevented_as_shown=0.07 claim_misreads_source=0.05 insufficient_evidence=0.01]	impact choice=user_visible conf=0.98 [user_visible=0.99 insufficient_evidence=0.01 internal_only=0.00]	reference choice=no_counterpart conf=0.51 [no_counterpart=0.63 diverges_from_reference=0.27 matches_reference=0.07 insufficient_evidence=0.03]	WEAK:reference
28 answer file(s), 28 with at least one verdict under 0.70 or insufficient_evidence
```
