# Design: surviving a gui-agent restart without killing the qube's GUI

**Status:** proposal, needs approval before any code. Written 2026-08-04.
**Scope note:** all dom0/daemon line numbers below come from the read-only upstream clone in the scratchpad. dom0's *installed* `qubes-gui-daemon` was never version-matched (that would be a dom0 action). Treat daemon line numbers as indicative and daemon *strings* as robust.

---

## 1. MECHANISM

### 1.1 What is established

**The daemon dies first; the agent only notices.** In the 08-04 incident the dying agent logged `libxenvchan_send: vchan not open` on `MSG_MAP`/`MSG_SHMIMAGE` *before* `WatchForEvents: vchan disconnected`. That ordering is what `libxenvchan_write` produces when the peer is already gone (`io.c:355` returns −1 on `!is_open`). This is not the agent emitting a bad message.

**The terminal state is "no `qubes-guid` process exists in dom0, and nothing recreates one."** The agent parks at "Awaiting for a vchan client" with its vchan server node published and healthy; `qtest shot` returns zero PNGs; only a qube shutdown/start recovers, because that is what makes something in dom0 launch a fresh guid.

**guid has exactly two EOF paths, and only one of them restarts it** (`gui-common/txrx-vchan.c`, verified in the clone):

| path | code | outcome |
|---|---|---|
| poll helper | `wait_for_vchan_or_argfd_once` → `if (!libvchan_is_open) { "libvchan_is_eof"; libvchan_close; vchan_at_eof(); }` (:125-133) | `restart_guid()` → `execv("/usr/bin/qubes-guid", …-f)` → survives |
| read/write helper | `handle_vchan_error` → `if (!libvchan_is_open) { "EOF"; exit(0); }` (:45-54) | **no restart, ever** |

`vchan_at_eof` is never consulted by `handle_vchan_error`. Note the Linux *agent's* copy of the same function does consult it (`gui-agent-linux/gui-agent/txrx-vchan.c:39-43`) — the daemon's copy diverged.

**The read side is not actually a gap; the write side is.** `read_data` waits with `while (!libvchan_data_ready(vchan)) wait_for_vchan_or_argfd_once(...)` (:95-96), so a read-path EOF is already routed through the restarting helper. Only `write_data_exact` (:64) can reach the fatal branch in practice. Earlier write-ups that said "every read and every write" overstate this by half.

**The precondition for the fatal path is "the daemon had *anything* to send", not "the daemon had a backlog."** `write_data` (:71-85) appends to the double buffer, then `count = min(libvchan_buffer_space, datacount)` and calls `write_data_exact`. `libxenvchan_buffer_space` does **not** check `is_open` — it returns raw ring space, which stays non-zero after the peer dies (`libxenvchan/io.c:250-258`, Windows port of the same upstream algorithm; the Linux copy is vendored nowhere in this environment). So:

* daemon's outbound queue empty at that instant → `count == 0` → `write_data_exact` loop body never runs → no error → poll → `libvchan_is_eof` → **restart, GUI recovers**
* daemon has one byte to send → `libvchan_write` returns −1 → `handle_vchan_error` → `exit(0)` → **GUI gone until qube restart**

This is a genuine coin-flip on daemon-side traffic at the moment of death, and it is consistent with the record: 08-03 09:57 twice recovered (`libvchan_is_eof` → `Icon size: 128x128` twice in `guid.win-idd-test.log.old`), 08-03 15:45 in-place restart survived, 08-04 twice did not.

Relevant: the daemon writes back constantly in response to us. Every agent `MSG_MAP` that guid honours produces a `MSG_MAP` write-back (`xside.c:2510-2513`), every window destroy produces a `MSG_DESTROY` echo at protocol ≥ 1.5 (`xside.c:3018-3028`; we negotiate minor 8), plus `MSG_KEYMAP_NOTIFY`/`MSG_FOCUS`/`MSG_CROSSING` from X events.

**There is no reconnect race.** `libvchan_client_init` (`qubes-core-vchan-xen/vchan/init.c:245-275`) polls with an **infinite** timeout while `libvchan_client_init_async_finish` returns 1 (`init.c:210-217`, `/* no xenstore entry (yet), wait more */`), aborting only if the *domain* is dead. A re-exec'd guid therefore cannot fail merely because `gui-agent.exe` is absent for the duration of a Stop-Service/copy/Start-Service. **The "shorten the agent-absent window" family of ideas is dead**, and so is the timing-race framing of E12/E13. Please discard it from the mental model.

**One deterministic guest-caused variant does exist.** `libvchan_client_init_async_finish` fails hard (→ `Failed to connect to gui-agent`, `exit(1)`) if the xenstore node is **stale** rather than absent. The agent removes its node only at first client connect (`main.c:3625 libvchan_cleanup`) or via `libvchan_close`, which is gated on `g_VchanClientConnected` (`main.c:3749`). So an agent that publishes a node, never gets a client, and is then killed leaves a live-looking node pointing at a revoked ring — and any guid that connects in that window dies permanently. This is not the first death in E13 (there the node had been cleaned at first connect), but it is a real, deterministic, guest-side way to make the state unrecoverable after the first loss, and it is cheap to close.

### 1.2 What is NOT established, and what would settle it

**Which exit path fired on 08-04 is unknown.** Three candidates — `exit(0)` on the write path, `exit(1)` on a protocol violation nobody saw, `exit(1)` failed reconnect on a stale node — produce an identical guest-side symptom. No dom0 guid log was collected that day. This is the single biggest hole and every ranking below is provisional until it is closed.

**Experiment D1 — collect the dom0 log (no agent restart required to observe).** Discriminator strings, all source-verified: `libvchan_is_eof` = restarting path; bare `EOF` = fatal write path; `Failed to connect to gui-agent` = stale node; `msg 0x.. without CREATE` = protocol `exit(1)`. Two constraints the user must be told:
* **The evidence is perishable.** guid rotates `.log`→`.log.old` and `O_TRUNC`s on every start *without* `-f` (`xside.c:4930-4967`), and the recovery reboot is exactly such a start; a self-restart appends to the same file. The failing generation survives exactly one recovery cycle. Instruction: reproduce → recover → **immediately** copy both `/var/log/qubes/guid.win-idd-test.log` and `.log.old`, before any further agent or qube restart.
* **"No line at all" is a distinct pre-registered outcome**, not "inconclusive". A guid killed by signal, or one exiting via `get_boot_lock` (`xside.c:4806-4826`, prints nothing), leaves no discriminator.

**Experiment D2 — read-only dom0 inspection while the qube is in the dead state** (one command, no restart, no mutation): is there a `qubes-guid` process for the domain, and does `/run/qubes/guid-running.<domid>` exist? Distinguishes "guid gone" from "guid alive and blocked", and detects the stale-lock trap in which every future guid launch silently `exit(0)`s.

**Experiment D3 — the only *guest-side* discriminator, and it needs no agent restart to observe.** Ship the in-process re-listen (§2.2). Then, the next time the daemon disappears on its own, the surviving agent republishes its vchan server node and we watch its log:
* a client connects within ~1 s → guid took `restart_guid` and was blocked on the xenstore watch → the class is "restarting path, agent exit was the only reason the GUI stayed down" ;
* no client ever connects → guid is *gone* → the class is a hard `exit()`.

This is the experiment the brief asked for: the observation happens on a **live, un-restarted** agent, and in the first case it is simultaneously a fix.

**Whether the 08-04 defect tracks our binary is untested.** Every daemon death with an *established* cause (E1 `img_data_size`, E2 UNMAP/DESTROY-then-SHMIMAGE, E3 materialisation, E9 `msg 0x86`, by inference E7) was an agent-side protocol violation — class (i), which bypasses `restart_guid` and can never self-heal. E13's "the SAME binary" was one of the 08-04 A/B builds, not the validated `98eed30` that carries the `CreateSent` send-side gate. **Experiment G0 (below) settles class (i) vs class (ii) entirely guest-side and should run before we spend anything on class (ii).**

---

## 2. WHAT WE CAN DO GUEST-SIDE

Ranked. Every measurement below uses cold-boot-per-side, ≥5 trials per side, interleaved with the control, and a **forcing function** (see §2.6) — without one, a control can pass by luck and void the comparison.

### 2.0 (G0, do first) Control experiment: does the defect track the binary?
Not a code change. Cold-boot A/B of the in-place-restart procedure itself: `98eed30` vs the 08-04 build (`aaa8c37`/`6b5b298`), n≥5 per side, interleaved, hash-verified install. Pass = the newly started agent logs "A vchan client has connected" within 30 s. If the defect tracks the binary, this is class (i) — our bug, in our code, fixable and measurable — and most of §2 and all of §3 is irrelevant. Cost: ~10 cold boots. Risk: none beyond the GUI losses we already incur.

### 2.1 Graceful stop instead of `Stop-Process -Force`
**Change.** The machinery already exists and is unused by our tooling: `Global\QGA_SHUTDOWN` is `watchedEvents[0]` (`main.c:3483`, `common.h:46`) and sets `exitLoop`. Three parts:
1. `tools/`-side: signal the event and wait for exit, instead of killing. No agent code needed for this part.
2. `main.c` exit path: insert a **quiesce** before `libvchan_close` — stop all senders, keep draining the daemon's inbound traffic for a short quiet window (e.g. until 200 ms pass with no readable bytes), *then* close. Rationale: the fatal branch fires only if the daemon has something to send at the instant `srv_live` goes to 0; going silent first lets guid's reply queue drain and its double buffer empty.
3. Make the drain a **purpose-built reader**, not `HandleServerData`: re-entering `case 4`/`case 5` on an incoming `MSG_DESTROY` for window 0 sets `g_LocalScreenDestroyed`, calls `CaptureTeardown` and then `StartFrameProcessing`, which re-grants and re-sends `MSG_WINDOW_DUMP` + `MSG_MAP` — i.e. it un-quiesces and provokes fresh daemon writes.

**File.** `agent/gui-agent/main.c` (exit path ~3741-3760), plus a new `tools/` stop helper.
**Risk.** Adds a bounded delay to every stop. Does not help a crash or a `TerminateProcess` — this only makes *our* restarts safer. Probabilistic, not a guarantee: dom0-side X events (pointer motion over the qube's windows) can queue at any moment.
**Measurement.** Control = current kill-based restart, same binary, which fails 2/2 today — a control that has been *seen to fail*, satisfying the evidence rule. Pass criterion is guest-observable and needs no dom0: new agent gets a vchan client within 30 s (`A vchan client has connected` in its log) **and** `qtest shot` returns a non-empty window set matching a pre-restart baseline. Attribution (which guid path ran) still needs D1.

### 2.2 In-process vchan re-listen on EOF (also the diagnostic instrument, D3)
**Change.** On `!libvchan_is_open`, instead of `exitLoop = TRUE` (`main.c:3680-3686`), close the vchan, call `VchanInit` again, and let the existing first-connect branch (`case 4`, `main.c:3620+`) do the resync: it already calls `SendResetCreatedWindows()` before anything else, then `SendProtocolVersion`/`HandleXconf`, then the window re-announce. Mirror of the Linux agent's `handle_guid_disconnect` (`vmside.c:2535-2553`).
**Scoped deliberately narrower than the version the critique holed:**
* **Do not tear down capture and do not revoke/re-grant the framebuffer.** `main.c:3720` says the revoke is unsafe until the daemon confirms `MSG_DESTROY` for `0x0` — a confirmation a dead daemon will never send. The grant is to the GUI domain and remains valid; the new guid needs only a fresh `MSG_WINDOW_DUMP` carrying the stored `ctx->grant_refs` (`SendScreenGrants` already does exactly this on the duplication-recovery path).
* `VchanInitServer`'s 5-minute parameter is a retry-until-xeniface-loads loop, not a wait-for-client, so it returns promptly and cannot deadlock the shutdown event.
* The `CreateSent` set must be cleared before re-announcing or the 98eed30 gate will *suppress* the new CREATEs and produce a healthy vchan with an empty dom0 window set. `SendResetCreatedWindows()` in the first-connect branch already does this — this must be asserted in review, not assumed.

**File.** `agent/gui-agent/main.c`, `vchan.c`.
**Risk.** Turns one-shot code into repeatedly-executed code. Bounded by the "no capture teardown" scoping above. Honest limitation: **it does not fix the reported 08-04 repro** (there the agent is killed, so there is nothing left to re-listen); it fixes and diagnoses *daemon-first* deaths, which is what E7/E12 actually were.
**Measurement.** Its value as an instrument (D3) is measured passively — no restart needed. Its value as a fix cannot be measured guest-side without inducing a daemon-only disconnect, which we cannot do from the guest. State that limitation in the commit message rather than claiming a validated fix.

### 2.3 Unconditional xenstore node removal on agent exit
**Change.** Drop the `g_VchanClientConnected` gate at `main.c:3749` so the node is removed on every orderly exit, not only when a client had connected. Closes the deterministic `Failed to connect to gui-agent` path described in §1.1.
**File.** `agent/gui-agent/main.c`.
**Risk.** Very low. Does nothing under `TerminateProcess` (no user-mode code runs), so it is worth little without §2.1.
**Measurement.** Directly checkable without a GUI-loss trial: stop a *never-connected* agent gracefully and have the user read `xenstore-ls /local/domain/<id>/data/vchan` (read-only dom0 inspection). Control = same procedure on the unmodified binary, which must show the node still present. That control has a definite failure mode, so the check can fail.

### 2.4 Fix the always-failing screen teardown (small, real, upstreamable)
`StopFrameProcessing` sends `MSG_UNMAP`+`MSG_DESTROY` for the screen window, but at `main.c:3756-3759` it runs **after** `libvchan_close`, so both sends provably always fail. Correct place is inside the quiesce of §2.1, with the daemon's `MSG_DESTROY` echo drained by the dedicated reader. Ship it as part of §2.1 or not at all — on its own it only adds daemon write-backs at the worst possible moment.
**Explicitly not included:** the per-window UNMAP+DESTROY sweep over `g_WatchedWindowsList`. That would make dom0 emit O(N) write-backs in the last milliseconds before close — manufacturing the exact precondition of the fatal path. Risk would scale with window count, matching the record (E7/E12 many windows → died; E10 one dialog → survived).

### 2.5 Class-(i) hardening: mirror the daemon's *bounds* checks agent-side
Refuse to emit anything the daemon would `errx`/`exit` on: message length, oversized window geometry (`too_big_window_error`, which is what killed E1), MFNDUMP/WINDOW_DUMP limits, clipboard size. **Excluding** the proposed duplicate-CREATE mirror invariant: HWND values are recycled, and dropping a second CREATE for an hwnd the daemon no longer has desynchronises us into exactly the `msg 0x86 without CREATE` kill it was meant to prevent. The correct response to a duplicate would be DESTROY-then-CREATE; that is not in scope now.
**File.** `agent/gui-agent/send.c`.
**Measurement.** Per evidence rule 5, each check must be seen to FAIL with the defect deliberately re-introduced (send an oversized geometry on a scratch build) before its PASS counts.

### 2.6 Harness changes required to make any of the above measurable
* **Forcing function.** The mechanism requires daemon→guest traffic at the moment of stop. Guest-side, the only available lever is a map/unmap storm (every honoured `MSG_MAP` provokes a guid `MSG_MAP` write-back, `xside.c:2510-2513`) running until the instant of the stop. Without it, a control that passes 3/3 by luck voids the comparison.
* **VOID ≠ FAIL.** `scratchpad/boot-measure.ps1` currently reports a dead GUI as a build FAIL. A dead GUI must be a distinct VOID outcome, or dead-daemon rounds silently corrupt every A/B. Acceptance for this change requires inducing the dead state once and seeing VOID.
* Keep hash-verifying the installed binary against the manifest; keep cold-boot-per-side.

---

## 3. WHAT NEEDS DOM0 / UPSTREAM — proposal only, requires user approval

**Verdict on "is daemon-exits-on-disconnect design or gap?" — both, and the distinction matters:**

* **Design, and must not be touched:** guid's `exit(1)` on protocol violations (`xside.c:3943-3957`) is a deliberate fail-closed response to untrusted guest input. Weakening it would reduce isolation and is out of scope, permanently. It is also, right now, the only external validation of our own `CreateSent` gate — four real agent bugs (E1, E2, E3, E9) were found *because* the daemon died loudly.
* **Design, deliberately:** guid is a one-shot per VM start with no supervisor; the intended lifecycle is externally orchestrated (`-K pid` hand-off). Caveat: "nothing in dom0 restarts guid" is **unverified** — `qubes-core-admin`/`qubesd` is not cloned here. What *is* verified locally is `qubesadmin/tools/qvm_start_daemon.py`: `start_gui_for_vm` runs only if `/var/run/qubes/guid-running.<xid>` is absent. Do not publish the "no supervisor" claim as fact.
* **Gap, and the one worth reporting:** `handle_vchan_error` never consults `vchan_at_eof`, diverging from the Linux agent's copy of the same function, so a disconnect noticed on the write path skips the restart the daemon otherwise implements. Given `libxenvchan_buffer_space` ignores `is_open`, this branch is reachable whenever dom0 has any queued or new outbound byte.

**Proposal DOM0-1 (writeup, then user-approved upstream issue referencing #1861).** Report, without a patch and without claiming it as the cause of our incident:
(a) the write-path EOF bypassing `vchan_at_eof`;
(b) the use-after-free if `execv` fails in `restart_guid` — `libvchan_close(vchan)` has already `free`d the handle and the main loop keeps dereferencing it (`txrx-vchan.c:127-130`, `xside.c:4838-4839` has no `_exit`);
(c) the observation that a restart destroys all dom0 windows anyway (`cleanup()` → `XCloseDisplay`), so an in-process re-attach — not a faster restart — is what would actually preserve state.
Must state up front that our line numbers come from an unversion-matched clone and that we **cannot validate any daemon change**: we cannot install into dom0's TCB (setuid-root `/usr/bin/qubes-guid`, mode 4750), so any patch would ship on a code-symmetry argument alone. That is defensible as an upstream observation; it is not defensible as "our fix".

**Proposal DOM0-2 (operational, user-run, no code).** Two read-only asks and one recovery ask, in this order: D1 (log collection with the perishability rules), D2 (process + lock-file inspection), and — only if the user wants the qube back without a reboot — `qvm-start-daemon` for that VM. Note the last one is *not* a diagnostic: guid's absence is already proven by the guest-side symptom, and all three candidate deaths leave the identical state. Its real value is turning each future trial from a qube reboot into one dom0 command. Two caveats to hand over: for an HVM, `start_gui` may spawn a stubdomain guid first depending on the `gui`/`gui-emulated` features (we cannot read features without `qvm-*`), and a stale `guid-running.<xid>` makes both the launcher and `get_boot_lock` silently no-op.

---

## 4. WHAT WE SHOULD NOT DO

Considered and killed:

* **Shorten the agent-absent window** (stage the binary at a new path + registry repoint; rename-the-running-binary with the watchdog live; any "restart faster" scheme). The window does not matter — `libvchan_client_init` blocks indefinitely on the xenstore watch. The registry variant additionally cannot work: the watchdog reads `GuiAgentPath` once in `ServiceMain` (`watchdog.c:204-210`). The rename variant risks the watchdog launching a *second* agent that overwrites the first's xenstore node.
* **Single-instance guard via `ERROR_ALREADY_EXISTS` on `Global\QGA_SHUTDOWN`.** The name is world-writable (public ACL). Any process squatting it — or a handle held by a not-yet-reaped instance — would permanently prevent the agent from starting, with the watchdog relaunching it at 1 Hz forever. Strictly worse than the two-instance scenario it guards, which appears in none of the 14 recorded events. If a guard is ever wanted it must be a private, non-squattable object.
* **"Don't exit on errors" (continue after `SetSeamlessMode`/`StartFrameProcessing` failures).** Trades class (ii), which sometimes self-heals, for class (i), which never does: running on capture/screen-window state dom0 no longer shares is precisely how window-scoped messages for unknown windows get emitted. Also fails "judge output, not logs" by construction — a live agent with a dead capture thread shows dom0 frozen pixels.
* **Duplicate-CREATE mirror invariant.** Fail-dangerous under HWND recycling (§2.5).
* **Agent-authored health/status file.** A stale `{"state":"connected"}` from a dead instance reads as healthy; and in the failure of interest the agent is fine and the *daemon* is gone, which an agent-authored file cannot see. `boot-measure.ps1:56-66` already names that state.
* **Runtime reconfiguration via a second global event.** Addresses none of the 14 events, adds another world-writable lever over the GUI agent, and creates runtime states that cannot exist at boot — the state CLAUDE.md requires to be the one under test.
* **Session-0 SYSTEM service owning the framebuffer grant.** Not implementable: the grant is over capture-owned memory in the interactive session (`capture.c:528`); a session-0 service cannot run Desktop Duplication or grant another process's private mapping. Would require rebuilding the transport (forbidden) or a copy (destroys zero-copy), and still forces a fresh grant + `MSG_WINDOW_DUMP` on every worker restart.
* **A dom0 supervisor for guid.** Converts a deliberate defensive abort against untrusted guest input into an automatic restart loop — an isolation reduction, out of scope. It would also have masked E1/E2/E3/E9.
* **Softening `xside.c:3943-3957` (log-and-drop instead of `exit(1)`).** Same reason, plus it hands an untrusted guest unbounded dom0 log volume.
* **Making `tools/qtest shot` the standard A/B criterion.** It cannot see override-redirect or layered/transparent windows — exactly the MSO strips under test — and "bytes changed between two shots" false-PASSes on a blinking caret. Keep the per-HWND `SendWindowMap` counting; use `shot` only as the coarse "is there any GUI at all" gate.
* **A blanket ban on in-place agent restarts.** It would make §2.1–§2.4 permanently unvalidatable. The right posture is: cold-boot per side for *builds*, and treat the in-place restart as the thing under test, not as a tool.

---

## 5. OPEN QUESTIONS

1. **Which guid exit path fired on 08-04.** Unresolved; needs D1. Everything in §2 is ranked provisionally on the assumption it was the write-path `exit(0)`. If D1 says `msg 0x.. without CREATE`, the priority becomes class (i) and §2.5 moves to the top.
2. **Does the defect track our binary?** Untested (G0). The historical base rate strongly favours class (i): every daemon death with an established cause was an agent-side protocol violation, and the E13 binary was not the validated `98eed30`.
3. **Is the phenomenon deterministic?** 2/2 on 08-04, 0/1 on 08-03 with the identical procedure on the same guest. The write-path mechanism predicts dependence on daemon traffic, not on the build — which is why §2.6's forcing function exists. n=2 cannot distinguish; no interleaved control has ever been run on this claim.
4. **Linux `libxenvchan_buffer_space` behaviour after peer death** is inferred from the Windows port of the same algorithm; the Linux copy is vendored nowhere in this environment. If the Linux version short-circuits on `!is_open`, the write-path mechanism weakens considerably and §2.1's rationale goes with it.
5. **Does dom0's installed daemon match the clone?** Never checked; checking is a dom0 action.
6. **The two silent agent deaths of 08-03 09:57 remain unexplained** (no WER, no crash dump, log ends mid-frame). Ruled out: the watchdog, the ~10:06 operator restart, Windows Update. `PerWindowCapture=1` in both instances is an uncontrolled difference never tested. Unrelated to this document's defect — the daemon survived both — but still open.
7. **IRP-cancel ordering on a hard kill:** whether `GnttabFreeGrant`'s `EvtchnNotify` still fires after `XenIfaceCleanup` has closed the event channel. If it inverts, dom0 learns of `srv_live=0` only on its next poll rather than by an immediate kick, which would shift the timing of exactly the race in §1.1. Not verified in source.