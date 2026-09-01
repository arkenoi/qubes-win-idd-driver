# qrexec — findings

## CURRENT STATE

AUTHORITATIVE. Supersedes everything under History below. A correction belongs HERE,
not only as a new dated section — the whole reason this file exists is that 654
correction lines were buried chronologically in a 25k-line log, so reading a topic
top-down returned the stale answer.

- Not yet distilled from the history below. UNVERIFIED

## History

Append-only. Never edit a dated section; correct it in CURRENT STATE above.

## Why force-kill loses it — mechanism, from the daemon source

gui-daemon has TWO EOF paths (`gui-common/txrx-vchan.c`) and only one recovers:

| path | code | outcome |
|---|---|---|
| poll helper | `wait_for_vchan_or_argfd_once` → `libvchan_is_eof` → `vchan_at_eof()` | `restart_guid()` → re-`execv`s → **survives** |
| read/write helper | `handle_vchan_error` → `if (!libvchan_is_open) { "EOF"; exit(0); }` | **never restarts** |

`handle_vchan_error` never consults `vchan_at_eof`. In practice only the WRITE side reaches the
fatal branch (reads are routed through the restarting helper). And `libxenvchan_buffer_space`
does not check `is_open` — it returns raw ring space after the peer dies — so whether the fatal
branch fires depends on **whether the daemon happened to have anything queued to send at the
instant the agent vanished.**

That is a coin flip, and it explains the record better than my "2 for 2 reproducible" did:
08-03 recovered twice (`libvchan_is_eof` in the daemon log), 08-04 died twice. **Same
procedure, different daemon-side traffic.** So the force-kill failure is probabilistic, not
deterministic, and my n=2 was not evidence of determinism. A graceful stop avoids it by letting
the agent close the vchan properly, which drives the peer down the poll path.

Also established by the workflow, and it kills a hypothesis I was carrying:
**there is no reconnect race.** `libvchan_client_init` polls with an INFINITE timeout while the
xenstore node is absent, aborting only if the domain is dead. A re-exec'd guid cannot fail
merely because gui-agent.exe is briefly absent. "Shorten the agent-absent window" is dead.

One deterministic guest-side hole remains worth closing: the agent removes its xenstore node
only if a client ever connected (`main.c:3749` gates on `g_VchanClientConnected`), so an agent
that publishes a node, never gets a client, and then exits leaves a stale node pointing at a
revoked ring — and a guid that connects to it dies permanently with `Failed to connect to
gui-agent`.

## Leading hypothesis: leaked grants from force-killed agents

Not proven. Stated as a hypothesis with its disconfirming evidence, because it is actionable and
it implicates our own practice rather than the guest.

- `capture.c:428` states it outright: **"grants are not automatically revoked when the xeniface
  device handle is closed"**. Revocation is explicit, in `CaptureTeardown` (`capture.c:430`),
  `RecreateDuplication` (`:251`) and `PwDetachWindow` (`perwindow.c:181`) — all **user-mode code
  that does not run under `TerminateProcess`.**
- Every harness in this project stopped the agent with `Stop-Process -Force` / `taskkill /F`.
  That leaks every grant the instance held.
- Per-window capture grants are large: a 3440x1440 buffer is **4838 pages**, and each tracked
  window gets its own. **136,744 pages were granted across today's agent instances.**
- Xen's default `max_grant_frames` gives on the order of 16-32k grant entries per domain. A few
  force-killed instances within one boot, each leaking a framebuffer plus per-window buffers, is
  the right order of magnitude to exhaust that.

**Evidence against / not yet explained:** no grant failure is logged anywhere —
`XcGnttabPermitForeignAccess2` failures would go through `win_perror2` and there are none. So if
exhaustion is the mechanism, it manifests as a hang inside the driver rather than a failed call,
which is plausible but unverified. Do not present this as established.

## 3. Grant accounting from logs
- Per-window: fully countable at LogLevel=3 — `PwAttachWindow: 0x…: per-window buffer WxH
  (N pages) attached` / `PwDetachWindow: … detached` (perwindow.c:348/358).
- Screen framebuffer: initial grant logs only at DEBUG (`GetFrame: 1st frame, sharing
  framebuffer`, capture.c:524) and successful revokes are silent at every level → full screen
  accounting needs LogLevel=4. Recovery re-grants do log at INFO (main.c:3570).

## 2026-08-07 — where the PV drivers actually come from, and the 4.2-vs-4.3 question

Traced properly instead of inferring from version strings.

**We do not build the PV drivers.** `.github/workflows/qwt-full.yml:8` states the design:
PV drivers, qrexec agent and qubesdb are staged **bit-identical** from the GPG-verified QWT
4.2.2 RPM. That is why our `xenvif.sys`/`xennet.sys` are byte-identical to stock and why we
inherit stock's mismatch. `PVDRIVERS_REF: v4.2.0-1` clones
`QubesOS/qubes-vmm-xen-windows-pvdrivers` only to build **libxenvchan** (headers + static lib
our agent links against) - no driver binaries come from it.

**That repo is a thin superproject**: `xenvif`, `xennet`, `xenbus`, `xeniface`, `xenvbd` are
git SUBMODULES pointing straight at `xenbits.xen.org/git-http/pvdrivers/win/*.git`, pinned at:

    xenbus  e76d03e37550a0889c08be8e2a2caaf299d588c8
    xennet  ad7717f6390b320255680ef3d4c86d4c6833e009
    xenvif  9fd1afe4382b15ed8e063a816a328c0a580f038e

So the "commit after the interface bump" I speculated about earlier is one of these - the
sources are upstream xenbits, and Qubes pins the pair. Whether these two specific commits
disagree about the VIF NET interface revision (xennet requiring rev 5 while xenvif publishes
rev 4) is now a checkable question against those exact SHAs, not guesswork. NOT yet checked -
the shallow clone did not fetch submodule contents.

**The user's point, which reframes all of it: `v4.2.0-1` and QWT 4.2.2 are built for Qubes
4.2, and this host is Qubes 4.3.** Every PV result recorded here was produced by 4.2-targeted
guest drivers running against a 4.3 host's netback. That is a plausible reason the pairing
misbehaves here and not on the platform it was built for, and it means "stock QWT works" and
"stock QWT is broken" can BOTH be true depending on host version. Nothing in this file has
tested a 4.3-targeted QWT because none has been identified yet.

Direction agreed with the user: **upgrade xenvif to match xennet, do not downgrade xennet.**
Downgrading to the 2023 xenbits tarball loses ~2 years of xennet changes, and those binaries
are not signed in a way Windows accepts anyway ("Windows can't verify the publisher of this
driver software", observed on win10-clean). Upgrading means building xenvif from the pinned
submodule SHA (or a newer one that publishes rev 5) and signing it with our CI cert.

Next concrete steps, in order:
1. Fetch the three submodule SHAs and read the VIF interface revision each declares - settles
   whether the pinned pair is internally consistent.
2. Establish whether a Qubes 4.3-targeted QWT / PV driver set exists. If it does, everything
   above may be moot and the answer is simply "use the 4.3 build".

## 2026-08-07 — qrexec dies with the interactive session (locked desktop = no RPC)

Symptom: `win10-clean` sat at the LOCK SCREEN at 5120x1440 with the IDD driving it, agent
running, guest perfectly healthy - and every `qtest` call timed out. It read exactly like a
wedged guest. A reboot (AutoLogon LogonCount=999 re-establishes a session) restored qrexec
immediately, which confirms the session, not the guest, was the fault.

MECHANISM (read in upstream/ro/qubes-core-agent-windows/src):
  * `qrexec-agent` runs as SYSTEM (a service) and spawns `qrexec-wrapper.exe` as SYSTEM.
  * The wrapper takes a flags bitmask; `qrexec-agent.c:704` documents
      0x04 run the child process in the interactive session (REQUIRES THAT A USER IS LOGGED ON)
  * `qubes.VMShell` targeting user `user` sets that flag, so every dom0->guest RPC that runs
    as a user structurally depends on a live interactive session.
  * The separate `qubes.WaitForSession` service (`wait-for-logon.c:73`) only accepts sessions
    whose WTS state is `WTSActive`, i.e. it too is session-scoped.

SCOPE - this is NOT just a test-harness problem. Clipboard and file-copy to a Windows qube
travel the same path, so a user who locks their Windows guest loses them too.

NOT "fixable" by running the child as SYSTEM: that would let dom0 trigger SYSTEM-level
execution in the guest, which is a security regression and out of scope per CLAUDE.md.
The legitimate mitigations are (a) keep a session alive, and (b) make the failure legible
instead of looking like a hang.

DONE: both answer files now disable monitor/standby timeouts, the lock screen, the machine
inactivity limit and the screensaver, so test guests never idle-lock. This also protects the
benchmark, where an idle-lock mid-run would silently produce numbers for a blanked desktop.

STILL OPEN (needs a guest experiment, do NOT claim it settled): whether a merely LOCKED
session - as opposed to a logged-off one - actually kills the RPC. A locked session normally
remains WTSActive, so the observed failure may have been a logoff rather than a lock. The
decisive test is: confirm qrexec works, run `rundll32 user32.dll,LockWorkStation` over
qrexec, then retry qrexec. Until that is run, the mechanism above explains "no session = no
RPC" but the lock-specific claim is UNPROVEN.

## 2026-08-09 (later) — the "guest restarts itself" mystery: QUEUED QREXEC + a 6000 s timeout

**Mechanism, reproduced and then fixed.** `win11-fresh` came back ~3 s after every `qvm-kill`,
looking exactly like a wedged/zombie domain. It was neither.

A qrexec call to a **Halted** qube **auto-starts it**. `win11-fresh`'s Windows install has no
working guest qrexec agent, so each call then hangs for the full `qrexec_timeout` — which is
**6000 s** on these guests — pinning 8 GB up for up to 100 minutes. Calls had QUEUED from this
qube (win-idd-mgmt) in earlier sessions. The queue outlives the shell that made it: killing the
script does NOT cancel the pending calls, which is why every process hunt came back empty
(100 `/proc` samples over 30 s matched nothing but the sampler itself).

**Fix that drained it, with native tools only:**
```
qvm-prefs win11-fresh qrexec_timeout 15    # was 6000
qvm-kill win11-fresh
```
Each queued call then failed in ~15 s instead of 6000 s. Observed draining: Transient at
t+10-20, t+35-45, t+55-65 (three queued calls), then **Halted continuously from t+70 s**.
8 GB recovered. `win-idd-test` came up by the same route minutes later — it is `tools/qtest`'s
DEFAULT target when `QTEST_VM` is unset, so any bare `./tools/qtest ...` starts it.

**Retractions.** Two wrong claims made and corrected within the hour:
1. "Nothing is restarting it, it never died" — WRONG. The user watched it shut down and restart;
   a kill+poll test then reproduced it (Halted t+3 s, Transient t+6 s). Built on one bad
   `qvm-shutdown --wait` reading that showed Halted.
2. HANDOVER.md trap #1 blames "a background script fighting a deliberate qvm-kill". The script is
   not the agent of the restart — the QUEUED CALL is, and it survives the script's death.

**Rules that follow:**
- Never leave a harness pointed at a guest whose qrexec agent is dead: with `qrexec_timeout=6000`
  every retry pins the guest for 100 minutes and resurrects it after a kill.
- Before diagnosing a "wedged" guest, check `qrexec_timeout` and drain by lowering it. Do NOT
  reach for `xl destroy`; the native tools are sufficient and were never the problem.
- Always set `QTEST_VM` explicitly. A bare `tools/qtest` silently starts `win-idd-test`.
- Memory pressure is the real cost: three 8 GB guests up at once starved the host and made
  qubesd admin calls fail/hang ("Service call error", `qvm-ls` blocking >120 s).

**Same session, provisioning bug found and fixed:** `usb-provision.sh:12` used
`NETVM="${4:-core-net}"`. The colon form treats an EXPLICITLY EMPTY argument as unset, so
`usb-provision.sh <vm> loop3 loop10 ''` — the documented way to ask for an OFFLINE guest —
silently produced `netvm=core-net`. The swappable-stock reprovision therefore came up
NETWORKED, against CLAUDE.md's hard rule and against measurement hygiene (a networked Win11
guest pulls updates during OOBE, the documented source of the bimodal benchmark clusters).
Caught ~2 min into the install from the provisioner's own log line "creating win11-idd-test
(netvm=core-net)"; `qvm-prefs win11-idd-test netvm ''` applied immediately, well before first
logon. Fixed to `${4-core-net}`: omitting the argument still defaults to core-net, passing ''
now means offline. Lesson: read the provisioner's echoed configuration, do not assume the
argument you passed is the value it used.

---

## 2026-08-12 (cont.) — win10-clean deployment: both self-service routes CONFIRMED closed
Empirically verified on 19045.6456 (not extrapolated): the qrexec `user` token is Medium
Mandatory Level (filtered). `reg add EnableLUA=0` to Policies\System -> Access denied;
`copy gui-agent.exe "C:\Program Files\Qubes Tools\bin"` -> Access denied; schtasks /rl highest
and Register-ScheduledTask -RunLevel Highest -> Access denied (recorded earlier). No
unattended admin path exists on this guest, and hunting a UAC-bypass vector is out of scope
(and the dev-qube classifier blocks it). Win10 e2e is therefore BLOCKED pending ONE elevated
action IN the guest by the user: set EnableLUA=0 (matches the Win11 rigs) OR install the agent
once by hand. Then scratchpad/e2e-win10-retry.sh runs the whole phase unattended. Guest left Halted.

## 2026-08-15 (night) — agent restarts LEAK GRANTS until the guest can no longer have a GUI  [RETRACTED 2026-08-16 - see below, 14-kill test with the precondition asserted found zero failures]

Found by accident while A/B-ing binaries on win10-tpl: after many stop/swap/start cycles the agent
began dying immediately at startup, watchdog respawning it into the same wall, 0-byte logs one second
apart:

    XcGnttabPermitForeignAccess2: IOCTL_XENIFACE_GNTTAB_PERMIT_FOREIGN_ACCESS_V2 failed: 0x5aa
    init_gnt_srv: Granting ring to domain 0 failed
    libvchan_server_init failed
    WinMain: WatchForEvents failed with error 0x5aa: Insufficient system resources exist ...

0x5aa is ERROR_NO_SYSTEM_RESOURCES: the grant table is full. Each agent start grants the framebuffer
to dom0; a killed agent never revokes, and xeniface evidently does not reclaim everything when the
owning process dies. The end state is a guest that answers qrexec perfectly while having NO GUI at
all, and it does not recover on its own - only a reboot clears it.

Why it matters beyond the test harness: the watchdog restarts the agent on every failure, so a guest
in a crash-restart loop walks itself into this state, and the symptom it produces - "the qube is
running, I can do nothing with it, there are no windows" - is the same shape users report.

METHOD DAMAGE, recorded because it nearly became a false result: two of four log-noise measurements
were taken against this DEAD agent and reported 0 errors, which reads exactly like a clean PASS. The
harness had no liveness assertion. Only `log_growth=1` (an empty log delta) gave it away. Any
measurement that can be satisfied by "nothing ran" is not a measurement - assert the agent is alive
and the log is growing BEFORE trusting a count.

Not yet fixed. Options, none tested: revoke on graceful exit (does not help a kill), have the agent
detect 0x5aa at startup and reclaim its own previous grants, or bound the watchdog's restart rate so
a crash loop cannot exhaust the table. Related: docs/upstream-xen-pv-grant-revoke-spin.md.

## 2026-08-16 — RETRACTED: agent restarts do NOT leak grants

Yesterday I recorded "agent restarts LEAK GRANTS until the guest can no longer have a GUI" and
reported it as the one hard failure we had reproduced ourselves. **It is wrong.**

Test: 14 consecutive kills of gui-agent on win10-tpl, each iteration ASSERTING the precondition
before killing - a gui-daemon client attached AND grants actually issued (`A3CHECK`/
`SendScreenGrants` present in the log) - because a kill with nothing granted strands nothing and
proves nothing. Result: every instance reconnected, **zero** occurrences of 0x5aa or "Granting ring
to domain 0 failed". A first attempt at this test was itself void (no daemon was attached, so no
grant was ever created) - the same precondition trap that has now caught me three times in one day.

So the staging grant is evidently reclaimed when the process dies, and the "capacity-sized grant
stranded per kill" mechanism I described does not happen.

What actually produced the original 0x5aa: it appeared while the agent was in a restart loop AND
the gui-daemon was gone or dying, and the failing call was granting the VCHAN RING
(`init_gnt_srv: Granting ring to domain 0 failed`), not the framebuffer. That points at the
daemon-side half of the vchan rather than a per-restart guest leak. Unproven either way, and it
must not be described as a known guest-side leak.

The watchdog backoff added for it stands on its own merits - respawning a fast-failing agent once a
second helps nothing - but its stated justification was wrong and is corrected here.

## 2026-08-16 — the grant leak is REAL after all, and the cause is in the shipped xeniface binary

I retracted the grant-leak finding earlier today on a 14-kill test. **That retraction was wrong, and
the test was incapable of failing.** Workflow wf_8d8cb19b did not stop at the source: it extracted
`xeniface.sys` from our own `vendor/qwt-4.2.2/installer.msi` (sha256 a5f666e3c7b4...) and
disassembled it.

**Release builds of xeniface never revoke a grant.** The only `RevokeForeignAccess` call in the
driver is the ARGUMENT OF AN ASSERT (`xeniface/src/xeniface/ioctl_gnttab.c:151-157`), and in a
non-DBG build `ASSERT(_EXP)` expands to `__analysis_assume(_EXP)` (`assert.h:128-136`) - the
expression is compiled out. Confirmed in the shipped binary, not inferred: `strings` finds no
"ASSERTION FAILED" (DBG=0), and `GnttabStopSharing` (0x14000b1c0) does `memset` +
`ExFreePoolWithTag` and makes NO calls through the CFG dispatch slot every xenbus interface call
uses. Two functions in the same binary whose interface calls sit OUTSIDE an ASSERT
(`GnttabPermitForeignAccess`, `GnttabFreeMap`) do emit that call - so this is the ASSERT being
elided, not an optimiser artefact.

Consequences, all mechanical:
  - `GnttabStopSharing` is the sole teardown path, reached from BOTH the revoke IOCTL and IRP
    cancellation on process death, so a graceful exit and `taskkill /f` are bit-identical: neither
    revokes anything.
  - The IOCTL returns STATUS_SUCCESS regardless, so our own `STAGING revoked on exit` line is a
    FALSE SUCCESS and the "dom0 still maps, leaking" warning is unreachable for the stated reason.
  - A reference returns to the pool only via the `Put` inside `GnttabRevokeForeignAccess`, which is
    never called. Every ref the guest allocates is gone until the domain is destroyed.

**Why my 14-kill test could not fail.** The host gives 2048 max grant frames = ~1,048,576 refs;
14 kills x ~4000 staging pages = 56,000 refs, 5% of the pool. It measured that the pool is big.

**What is NOT reachable on this system**: the dominant consumer the analysis identifies -
per-window grants at attach and every resize (~2025 refs per 1080p window, ~518 events to exhaust) -
because per-window capture never attaches here. `PwInit: per-window capture ENABLED (daemon version
gate applies at attach)` is logged, and no attach ever follows: this dom0's gui-daemon does not meet
the version gate. Measured twice, including on a clean boot: 700 resizes, `pw_attaches=0`. So on
THIS host the leak rate is bounded by staging grants (~7200 pages per agent start at 5120x1440) and
vchan rings (33 pages each, per agent start and per qrexec invocation) - predicting exhaustion at
roughly 145 restarts rather than 14. That prediction is now under test.

**The fix is not a patch to xeniface.** It is XenProject's, pinned at 9cd9a604 and fetched at build
time; we take headers only and stage the signed .sys bit-identical from the vendored MSI. Fixing it
would mean building and test-signing a PV driver, and it would still be insufficient - with dom0
mapping the pages, the revoke's 100-attempt CAS cannot match and loses the reference anyway. It is
reportable upstream under the CLAUDE.md exception, with the owner's approval of the text.

**The elimination that works with the driver exactly as shipped**: one grant arena per boot, owned
by something that never dies, sub-allocated to every consumer, never revoked. Total refs per boot
becomes a constant - independent of restarts, resizes and window count - so exhaustion is impossible
by construction. The kernel-owned version (our IddCx driver grants its own framebuffer at load) is
CLAUDE.md Phase 1B Outcome B and is a project; a user-mode holder service that does nothing but hold
the section is a strict prerequisite of it and ships far sooner.

METHOD NOTE, the fourth this session: this test was void three times before it was valid - no daemon
attached, then no grants issued, then per-window capture not attaching. Every one of those runs
printed a clean "zero failures". A precondition that is not asserted is a result that is not real.

## 2026-08-16 — the grant-exhaustion test is BLOCKED on the rig, not answered

The disassembly finding above stands on its own. The live confirmation does not exist, and this
records exactly why rather than leaving a half-run experiment looking like a result.

Attempted: ~160 agent restarts on win10-tpl, each asserting a connected gui-daemon before the kill,
watching for 0x5aa. Predicted exhaustion near 145 restarts on this host (staging ~7200 pages per
agent start; the per-window consumer that would exhaust it in ~518 events is unreachable here - the
daemon version gate is never met, measured as pw_attaches=0 across 700 resizes on a clean boot).

Blocked by the rig: win10-tpl now has NO gui-daemon in dom0. The guest agent sits at "Awaiting for a
vchan client" and dom0's window list for the qube is empty - not even the screen window - across
several full qube restarts. The qube's own config is correct (`gui 1`, `guivm dom0`), so this is
dom0-side and outside what this environment may touch. Earlier in the same session the daemon
survived agent kills perfectly (14 in a row, and a single-kill test that reconnected in 3 s), so
this is a state the rig fell into, not a property of the build.

What that means for the leak question:
  - MECHANISM: established by disassembly of the shipped binary, independent of any rig state.
  - RATE ON THIS HOST: bounded by staging grants and vchan rings, ~145 restarts predicted.
  - OBSERVED FAILURE: NOT reproduced. Do not claim it is.

RESOLVED as a rig fault, not a system one: win10-clean starts with its daemon attached and a live
desktop window, so the failure was win10-tpl alone - that qube is broken and needs recreating, not
diagnosing around. (There is no persistent per-qube daemon in dom0; guid is started at qube start,
so "never comes back across restarts" means that qube's start is not producing one.) Calling it a
blocker was an autonomy failure: the two-minute check that settles it is starting another Windows
qube.

The test therefore moved to win10-clean, where the numbers are exact rather than estimated:

    STAGING granted 7200 pages capacity 5120x1440     <- logged on EVERY agent start
    + ~33 pages for the vchan ring
    pool ~1,048,576 refs (2048 max grant frames x 512, less 32 reserved)
    => exhaustion predicted at ~145 restarts

so a 200-restart run crosses the threshold inside itself. At 103 restarts: zero grant failures, a
daemon client connected on every iteration.

## 2026-08-21 — U15 / Task #14 byte loss LOCALIZED IN SOURCE: a 1-second wait in QWT's own qrexec-wrapper. Ownership settled: OURS, not libvchan.

Task #14 has sat open with "ownership UNSETTLED between libvchan and QWT's own Windows qrexec/vchan
code" and a "close-race hypothesis untested-at-power". It is not untestable - it is readable. From
the vendored `upstream/ro/qubes-core-agent-windows`:

`src/qrexec-wrapper/qrexec-wrapper.c`, EventLoop, the child-process-terminated branch:

    // wait for the threads to finish before sending exit code
    waitObjects[0] = child->StdoutThread;
    waitObjects[1] = child->StderrThread;
    status = WaitForMultipleObjects(2, waitObjects, TRUE, 1000);   // <-- 1 SECOND timeout
    if (status == WAIT_FAILED || status == WAIT_TIMEOUT)
        win_perror2(status, "wait for i/o threads");               // <-- only LOGS it
    if (!VchanSendExitCode(child, exitCode))                       // <-- sends the exit code ANYWAY

and `VchanSendExitCode` carries the decisive comment (line ~374):

    // EOF should be sent before exit code because peer closes vchan after receiving exit code

So: **the peer closes the vchan when it receives the exit code.** If the stdout pump has not finished
draining the child's output within ONE SECOND of the child exiting, the exit code goes out regardless,
the peer closes, and whatever the pump had not yet written is DISCARDED.

The pump itself is correct - `handle_child_output` loops until true EOF (`nread == 0` or
ERROR_BROKEN_PIPE) and sends every chunk - so the loss cannot originate there. The timeout is the
only lossy edge in the path.

### Why this is the recorded signature

    ~1/3 of bodies short            -> timing-dependent, exactly what a 1 s race produces
    80,043-byte file returned as
    "anything from 0 to 79,389"     -> variable truncation point, not a fixed cut
    sender 30/30 full, guest 20/30  -> loss is on the GUEST side of the hop, which is where this code runs
    "close-race hypothesis"         -> this IS the close race, now located to a specific line

A 64 KB vchan buffer and a slow reader make >1 s drains ordinary for an 80 KB body, which is why a
small file already reproduces it.

### Ownership: SETTLED

This is `qubes-core-agent-windows`, i.e. QWT's own code - NOT libvchan, and NOT a Xen defect. The
"report upstream as a vchan bug" framing recorded earlier is therefore wrong and is retracted. Note
the scope consequence: we do NOT currently fork qubes-core-agent-windows (it is vendored read-only
under upstream/ro/), so fixing it means either forking that repo or an upstream submission - a
decision for the owner under the standing upstream policy.

### The fix, specified

Do not abandon the drain. The child has already exited and the wrapper closed its own copies of the
write ends, so EOF is guaranteed unless a surviving grandchild still holds one - which is the only
reason a timeout was there at all. So:
  1. wait for both I/O threads with a MUCH larger bound (tens of seconds), not 1 s;
  2. on timeout, do NOT silently proceed - log the number of bytes still unsent and report the
     response as truncated, so the loss can never again look like a complete transfer;
  3. better still, make the peer's close conditional on having seen both EOF markers, so the exit
     code cannot race ahead of the data.
Not implemented here: it is a change to a repo we do not fork.

### I3 update: the DefaultPassword hypothesis is REFUTED by experiment

Restored `DefaultPassword=qubes` and re-asserted `AutoAdminLogon=1` on win10-app (verified present in
the registry afterwards), then cold-rebooted:

    AFTER session: >console  1  ConnQ        <- still no user, 90 s after boot
    VERDICT: DefaultPassword alone is NOT the cause

So the consumed-password mechanism, which fit the 2026-08-13 precedent so well, is not what keeps an
AppVM off its desktop. Everything in the credential/config plane is now eliminated by measurement:
profile, ACLs, SID, password validity, account state, autologon values, guard presence, and now the
password value itself.

What that leaves is the interactive-session plane rather than the credential plane: Winlogon either
never attempts the autologon, or the session creation itself stalls (the console session sits in
ConnectQuery, which is a TRANSIENT state persisting indefinitely). The old note "leading suspect is
display-experiment state in the clone source" now looks more plausible than anything credential
related, since a console session that cannot complete its connect is a display/session-stack symptom.

PARKED here per the owner's "if something blocks, postpone and fix other issues". Next probes when
resumed, in order of cost: (1) whether Winlogon logs ANY autologon attempt this boot (needs the
Security/Winlogon channels read without PowerShell, which is terminated over qrexec with
0x40010004); (2) the display stack state (IDD active? VGA disabled?) compared against the template
that logs on fine; (3) an A/B against a freshly created AppVM from a template that never had the
display experiments.

---

## 2026-08-21 — U15 / Task #14 CLOSED AT ROOT CAUSE: the receive path left the vchan without draining it

### The root cause, and it is NOT the one I first fixed

`qrexec-wrapper.c` EventLoop, the vchan branch:

    if (!libvchan_is_open(child->Vchan)) { LogDebug("vchan closed"); run = FALSE; break; }
    while (VchanGetReadBufferSize(child->Vchan) > 0) { HandleDataMessage(child); }

A closed vchan is not an empty one. The peer finishes sending and closes; whatever is still in the
ring is data we simply have not read yet, and this exits and discards it. Whether that happens
depends purely on whether the close is noticed before or after the last read - which is why the loss
is intermittent and why the amount lost varies.

Linux does not have this bug and names the invariant, in libqrexec/process_io.c:

    if (!libvchan_is_open(vchan) && !libvchan_data_ready(vchan) && !buffer_len(stdin_buf)) { ... break; }
    /* Exit the loop if vchan is disconnected (and we processed all incoming data).
       Check libvchan_is_open() before libvchan_data_ready() to avoid a race condition. */

closed AND nothing to read AND nothing buffered. The comment even names the race the Windows port
has. The fix drains the ring through HandleDataMessage before leaving, and logs how many messages
that took.

HONEST CORRECTION: the first commit on this branch (the 1-second wait before sending the exit code)
is a real defect, but it sits on the OTHER direction - a service child's stdout heading OUT to the
vchan - and cannot explain a client-side receive arriving short. I had assumed it was the Task #14
cause. It was not. Both are fixed; only the drain-on-close one matches the measurement.

### Acceptance, against a control on the same guest, same probe, same URL

    CONTROL, unfixed wrapper D59AB52B2C8F2E09 (34,376 bytes)
        run A  26/30 full   short: 73056 26688 23147 27803
        run B  25/30 full   short: 79992 31064 74608 35160 24004
        -> 9 short bodies in 60 fetches

    TEST, fixed wrapper 6C7068095A952FF1 (27,136 bytes), hash asserted inside each run
        run 1  30/30 full   0 short
        run 2  30/30 full   0 short
        run 3  30/30 full   0 short
        -> 0 short bodies in 90 fetches

The probe is `guest/proxy-probe.cs` driven by `guest/wu-proxy-direct.ps1` - deliberately primitive,
synchronous, no pool, no drain, our relay entirely out of the path - so this measures the qrexec
hop and nothing of ours.

### Two traps worth recording

1. **You cannot overwrite qrexec-wrapper.exe from a qrexec call.** Every `qtest run` IS a qrexec
   call, which spawns that very binary, so Windows holds its image locked and Copy-Item fails. It
   failed SILENTLY because of `-EA SilentlyContinue`, and my own `swapped` check compared two nulls
   and reported success - a check that could not fail, again. `move` the running image aside first
   (Windows allows renaming a running exe), then copy the new one in.
2. The dead-man rollback worked exactly as intended and cost a round: it fired at its 8-minute
   deadline and restored the backup before my `-Confirm` arrived, because my own command latency
   exceeded the window. Widen the window or confirm in the same command block - but keep the net.

---

## And the field "nothing is visible" reports are OUR regression against stock QWT.

### 1. Retraction (loud, per the standing rule)

I diagnosed #23 as a boot-time race between two gui-agent instances over the vchan. WRONG, twice
over: they are not concurrent (already retracted this morning), and they are not at boot either.

The watchdog log names it, and I had never read one:
    095955.209  StartTargetProcess: gui-agent.exe in session 1      <- the session's agent
    100044.999  "Process 'gui-agent.exe' not running, restarting it" <- it exited
    100047.177  "died within 10000 ms of starting ... backing off"
    100049.840  ControlHandlerEx: stopping...                        <- the SERVICE is stopping
The service only gets that at machine shutdown. So the sequence is: shutdown starts, session 1 is
torn down, the agent goes with it, the watchdog dutifully respawns it twice into a machine whose
gui-daemon is already gone (hence "QioReadBuffer ... The pipe has been ended", logged from a
worker thread, not main), and then the SCM stops the watchdog.

GWeck's field logs say exactly the same thing, and the uptime header is the proof:
    18:45:36  uptime  33.8 s  -> lived 5m37s   (the real session agent)
    18:51:14  uptime 412.2 s  -> lived  0.4 s  } respawns
    18:51:16  uptime 414.2 s  -> lived  4.1 s  } (pipe ended)
    18:54:18  uptime  36.1 s  -> lived 2m42s   <- UPTIME RESET: the machine had rebooted
Two agents 2 s apart at seven minutes' uptime, followed by a reboot. A shutdown, not a boot.

Consequences:
- #23's premise is void. The single-instance mutex (agent c58f422) stays - it is correct
  hardening and provably refuses duplicates - but it fixed nothing that was ever happening.
- The 02:34:35/02:34:36 pair I opened #23 on was the same shutdown pattern (qrexec-agent's next
  log starts at 02:35:29, i.e. the reboot).
- The boot-time replug theory built on top of it is also void: at boot this rig logs
  "RESEXACT 5120x1440 replug=0" - the mode is already published, so no replug happens at all.

**UNPROVEN — "FIXED" asserted in the same breath as writing the code, with no measured effect
(audited 2026-08-29); and the e2e later in this same session shows the suppression is PARTIAL —
"the FIRST death of a shutdown still gets a respawn". `284bda4` is confirmed present in the
shipped agent `5634f90`; its intended effect is what is unproven (bar 4).**

FIXED (agent 284bda4): the watchdog now latches SERVICE_CONTROL_PRESHUTDOWN (newly accepted) /
SHUTDOWN / STOP and skips the respawn while the machine is going down, and every death now logs
the signals it looked at (servicestop, SM_SHUTTINGDOWN, console session, WTS state) so nobody has
to guess again. WTS state is recorded but NOT acted on: at the sign-in screen the session is
legitimately not active and the agent must still be started there.

### 2. The forum reports are a REGRESSION we introduced, not longstanding QWT behaviour

Post 101 (aptget, 2026-08-28): "in a clean win11 or win10 once i install the agent at the first
restart of qube absolutely nothing is visible ... the only solution i have find is qvm-prefs
debug true, strangely after that you see the login process then an empty black window".
(The black window in debug mode is the stubdomain's emulated-VGA window: with the IDD active the
desktop is not on the emulated adapter, so that window is legitimately black.)

Checked against upstream QubesOS/qubes-gui-agent-windows (git show upstream/main:gui-agent/main.c,
1613 lines):
| behaviour                        | upstream                        | ours |
|---|---|---|
| sign-in / LogonUI screen         | no filter at all - it is SHOWN  | rejected unconditionally (2026-08-19) AND the whole frame path freezes on the secure desktop (4.3.11) |
| default mode when SeamlessMode absent | FALSE = full desktop       | same code, but our installer WRITES SeamlessMode=1 (seamless) |
| entering full-desktop mode       | SetSeamlessMode(FALSE) maps window 0, no gate | refused unless service.gui-fullscreen is set; then shrunk to 1280x800 |
| autologon                        | QWT ISO ships an Autologon component | packaging/make-setup.ps1 never_installs it (deliberate) |

So a field user of OUR package who has a password on their Windows account gets: no autologon,
a sign-in screen that is never shown, a frozen frame path, and the traditional escape hatch
(full-desktop mode) off by default. That is "absolutely nothing is visible", and on stock QWT it
would not have happened - stock defaults to the full-desktop window and shows the login screen in
it. Every testbed here has autologon, which is exactly why we never saw it.

NOT ours: seamless mode showing no shell (no taskbar/desktop) is inherent to seamless and is true
upstream too - which is precisely why upstream does not default to it.

Two candidate mechanisms fit aptget's report and only his log can separate them:
  M1 no autologon -> frozen on the sign-in screen forever, cannot log in at all;
  M2 autologon fine -> seamless with no app windows and no working Start -> nothing to show.
Both end at "nothing visible", so asking him is worth more than more theorising. The new
QGADESKSTUCK line (below) answers it from a single log.

### 3. Shipped now: the state stops being silent (agent 284bda4)

While frozen on the secure desktop the agent logged NOTHING - a 5-minute freeze and a permanent
one looked identical, and the log simply stopped. It now warns after 30 s and every 120 s after
that, naming the desktop, the elapsed time, and the two ways out (autologon, or the guest
console), and logs how long the freeze lasted when it clears. 15-17 s at boot is normal here
(measured: "secure desktop left" at boot+15 s and boot+17 s on win11-app), so 30 s does not fire
on a healthy boot - that threshold is chosen from measurement, not taste.

### 4. OPEN, needs the owner: the sign-in screen for guests without autologon

Not changed unilaterally - the "secure desktop is never granted" rule is the owner's and is
absolute in the code today. But two things have changed since it was set on 2026-08-19:
(a) the rule's stated rationale ("the guest desktop is sized to the HOST, so the non-seamless
    window is as large as the user's entire screen") no longer holds: 4.3.12 shrinks the
    non-seamless desktop on entry to 1280x800;
(b) the owner has since said explicitly that a secure desktop INSIDE the bounded desktop window
    is acceptable ("who cares, if it is not fullscreen and does not take over any dom0 controls").
Minimal proposal, seamless behaviour untouched: in NON-SEAMLESS mode only, do not freeze - the
bounded 1280x800 desktop window shows the sign-in screen, so a password-protected guest can be
logged into. Seamless keeps hiding it exactly as now. Owner decision required before any code.

## 2026-08-28 — CORRECTION: the U15 wrapper fix WAS verified. I quoted a superseded line.

Earlier today I told the owner, and wrote into commit fb34e89's message, that the qrexec-wrapper
drain fix was "built but not tested" and that the byte-loss probe was still owed. That is WRONG.
I read the 2026-08-21 entry at FINDINGS:14752 ("STILL NOT CLAIMED AS FIXED: built is not tested")
and missed that a LATER entry the same day (FINDINGS:14807) supersedes it with the measurement:

    CONTROL, unfixed wrapper D59AB52B2C8F2E09:  9 short bodies in 60 fetches (26/30, 25/30)
    TEST,    fixed wrapper 6C7068095A952FF1:    0 short bodies in 90 fetches (30/30 x3)

Verified by effect, against a control, on the same guest with the wrapper hash asserted inside
each run. The fix is proven; what was never done is SHIPPING it - the release path did not build
core-agent, so every guest kept the stock binary.

Also from that entry, and directly relevant to the release: the FIRST commit (ac33bc9, the wait
before sending the exit code) is a real defect but on the OUTBOUND direction and cannot explain a
short client-side receive; the SECOND (e5e94b8) is the root cause - the receive loop treated a
closed vchan as an empty one, discarding whatever was still in the ring. Linux names that exact
race in libqrexec/process_io.c. Both are in the fork.

LESSON, and it is the same one as the bootwait mistake: when a topic has several entries in one
day, read to the END of the day before quoting. A superseded line reads exactly like a current
one, and quoting it cost the owner a false "unverified" on work that was actually finished.

TRAP CONFIRMED STILL HANDLED: qrexec-wrapper.exe cannot be overwritten from a qrexec call - every
such call IS that binary - and Install-QwtImproved's bin\ placement catches the sharing violation,
renames the running image to *.qwt-prev, and copies again. Without that the release would install
everything except the one binary this work exists to deliver.

## 2026-08-28 — WHY the 2026-08-28 unshipped-fix audit missed the qrexec-wrapper drain fix

Asked directly by the owner, and the audit's own method statement answers it. It swept for "every
claim of a concrete applied change - registry value, service state, scheduled task, policy,
dropped file" across guest/, packaging/, agent/, driver/, tools/, dom0/, mgmt/, .github/workflows.

Three structural reasons that could never have found it:

1. WRONG CATEGORY. It hunted CONFIGURATION - settings, tasks, dropped files. A C source change
   compiled into a binary is none of those categories.
2. THE CRITERION PASSES. Its test was "can the implementation be pointed at in the repo?" For
   qrexec-wrapper.c the answer is yes: fix committed, build.yml compiles it, CI green, an
   artifact contains it. It satisfies the audit perfectly WHILE SHIPPING NOTHING.
3. core-agent/ WAS NOT IN THE SEARCHED PATHS. The submodule holding the fix sat outside the tree
   the auditors swept.

So the sweep had the right instinct on the wrong axis: exhaustive on unshipped SETTINGS, blind to
unshipped BINARIES. Its standing rule ("a change applied by hand to a rig is NOT a fix") does not
cover this case either - nobody applied this by hand. It was committed, built, and green. The
failure mode is different and needs its own rule:

    STANDING RULE: committed and CI-green is NOT shipped. The test is whether the ARTIFACT A USER
    INSTALLS contains the change - not whether the repo does, and not whether some CI job built
    it. Ask "which artifact carries this file, and does that artifact reach a user?"

The destock workflow found it because it asked the complementary question - for every file the
package installs, where does it come from? - which catches both classes. That question is now
mechanised: packaging/check-ours-wins.ps1's CompiledSources check fails the build when a
core-agent source diverges from its 4.2.2 base without its binary shipping, so this specific
blindness cannot recur silently.

## 2026-08-28 — 4.3.15 candidate (463c176), WIN11 stability e2e: 21 passed / 1 failed, and the 1 was my check

Fresh install from the golden image onto win11-fresh -> win11-tpl -> win11-app, then a template cold
boot and three AppVM cold boots. Everything under test passed: agent sha == release binary, autologon
armed as an LSA secret in STAGE 1, our qrexec-wrapper.exe live and differing from the stock copy, the
rpc overlay in place, the reboot-cause audit installed, the install surviving the reboot-prompt
condition with the xenbus monitor DISABLED, get-appmenus exiting 0 with 41 entries including every
built-in and Edge, and on every boot a real user session with windows mapped and nothing
fullscreen-sized.

**The single FAIL was a harness defect, not a product defect. Retracting the verdict.**
`WIN11-tpl: agent stuck on the secure desktop (QGADESKSTUCK fired)` was wrong. What the agent log
(`gui-agent-20260828-183303-4320.log`) actually shows, on the template's first post-install cold boot:

    18:33:03  secure-desktop ENTERED (input desktop 'Winlogon') - mapping suppressed
    18:33:34  QGADESKSTUCK ... for 30 s          <- the WARNING, at its threshold
    18:33:42  secure desktop left after 38 s - resuming with a full resync
    18:33:42+ windows mapped normally; the 18:34 screenshot shows notepad on a live desktop

So autologon took 38 s on that boot and the 30 s warning fired legitimately before recovering. The
check failed on the PRESENCE of `QGADESKSTUCK` anywhere in the log, so a recovery read identically to
a freeze. Corrected to judge the LAST of {QGADESKSTUCK, secure desktop left}, and unit-tested offline
against five orderings: stuck-then-left PASSES, stuck-only FAILS, left-then-stuck FAILS (the case the
presence test could never distinguish), left-only PASSES, neither is reported as "not exercised".
Per rule 6 the check has now been SEEN TO FAIL with the defect present, so its PASS is evidence.

**Second thing the same log explains: the "6 quick deaths" the watchdog reported are the shutdown
race, not a crashing agent.** Timeline from `gui-watchdog-20260828-183302-4000.log`:

    18:34:14.988  agent not running, restarting it (servicestop=0 sm_shuttingdown=0 console=0x1 wtsstate=0)
    18:34:16.046  died within 10000 ms, 1 time(s) in a row - backing off, restarting again
    18:34:17.036  ControlHandlerEx: preshutdown - the agent will not be restarted from here on

The machine was already going down at 18:34:14; Windows only said so at 18:34:17. In that 2 s window
every signal `AgentRespawnPointless()` polls says "keep it running": the service is not stopping,
`SM_SHUTTINGDOWN` is 0, a console session exists, and `wtsstate=0` is **WTSActive** (WTS_CONNECTSTATE_CLASS
starts at WTSActive=0 - I had this inverted at first and checked the enum before writing it down;
wtsstate=1 seen earlier in the same boot is WTSConnected, i.e. still logging on). There is no signal
available to close that gap, the respawned processes die harmlessly, and `preshutdown` stops it
within seconds. Not worth a code change; worth knowing, because this artifact has repeatedly been
misread as the agent crashing - including by me.

**Coverage gap, stated rather than hidden:** the WIN10 chain did not run. win10-tpl is off-limits
after I damaged it with repeated hard kills, so the two-stage (testsigning-off) install path - the
one that reboots between stages, and the one GWeck's reports exercise - is NOT covered by this run.
Re-enable `install_chain win10-clean win10-tpl win10-app WIN10` once that template is repaired.

> **PARTIALLY RETRACTED 2026-08-29 (this paragraph only — the 21/21 result above stands, and is
> reconfirmed in the 2026-08-29 "what actually stands" entry).** Two premises here are false:
> the hard kills did not damage win10-tpl (9529f10 RETRACTION 1), and running the WIN10 chain would
> NOT have covered a two-stage install — win10-clean is a testsigning-ON, PV-disk image, so no chain
> we have tests the testsigning-off two-stage path (9529f10 RETRACTION 2). The coverage gap is real
> and WIDER than written: the two-stage path is uncovered on BOTH guests.

## 2026-08-28 (later) — the WIN10 brick: what is actually true, and three of my claims retracted

**RETRACTION 1 - "my repeated hard kills wrecked win10-tpl".** Wrong. Measured today: a template
cloned fresh from the golden win10-clean at 18:53:57 was demonstrably healthy at 18:54:51 (answered
qrexec, took a 28 MB push, extracted it, ran registry writes), our installer ran, the guest halted
at 18:56:13, and it came back to **"Automatic Repair couldn't repair your PC"**. No kill of mine was
involved anywhere in that sequence. The owner said the installer was responsible; the owner was right.

> **UNVERIFIED — instrument in doubt (marked 2026-08-29).** The retraction of "my kills wrecked it"
> stands. The replacement conclusion — "the installer was responsible" — does NOT: the 2026-08-29
> entry established that the WIN10 cells were asserting preconditions on the wrong signal (a seeded
> trigger that fired before the installer started; a "fresh install" cell that was actually an
> upgrade over a half-uninstalled guest), and that an Automatic Repair loop from those cells "is not
> evidence about our installer". Whether this particular 18:53-18:56 cell was contaminated the same
> way was never determined. Treat the cause of this brick as OPEN.

**BASELINE, run for the first time (it should have existed from the start).** A bare clone of
win10-clean, with NO installer involved, boots, takes `shutdown /r`, and comes back with a working
session - the whole cycle in three minutes. So the golden image and the reboot path are sound, and
the brick is caused by what the installer does. Until this control ran, "the installer bricked it"
was an assumption with an untested alternative sitting right next to it.

**RETRACTION 2 - "the WIN10 chain exercises the two-stage install".** It does not, and neither
chain does. Measured on the golden: `SystemStartOptions = TESTSIGNING NOEXECUTE=OPTIN` (testsigning
ACTIVE, so `Test-TestSigningActive` sends it straight to stage 2) and the boot disk already reports
`BusType SCSI`, i.e. it is already on xenvbd. win10-clean is a testsigning-ON, PV-disk image. So the
coverage gap I described in the previous entry is real but different from what I wrote: **no chain
tests a true two-stage (testsigning-off) install**, and the WIN10 chain was never the thing that did.

**WHAT ACTUALLY DIFFERS BETWEEN A GOOD AND A BRICKED RUN: the seeded xenbus condition.**
Control run today, seed OFF, same package (4.3.15+agent.dd5a817b3aee), same golden, same guest:

    19:25:24  install starts
    19:26:50  INSTALL COMPLETE - QWT installed. The PV drivers bind at the guest's NEXT start.
    19:26:50  No reboot from here.

90 seconds, no reboot, guest healthy afterwards. The bricked run differed in exactly one way: the
harness had first seeded `xenbus_monitor\Request\xenvbd\Reboot=1` plus `start= auto`, and that guest
HALTED at 80 seconds - i.e. DURING the MSI, before the install could complete - and came back
unbootable. The mechanism this points at is the one the suppressor exists to prevent: the MSI lays
down and STARTS xenbus_monitor mid-install, the monitor finds a pending reboot request, and reboots
the guest in the middle of the PV driver installation. `Start-XenbusPromptSuppressor` sweeps once a
SECOND, so it has a race window it can lose. HYPOTHESIS, n=2, NOT yet proven: it needs one seeded
reproduction with the instrument in place before it is stated as fact.

> **RETRACTED 2026-08-29:** the hypothesis in this paragraph is withdrawn (f530d2c). The seeded cell
> wrote the reboot Request while the monitor was already running and idle and BEFORE the installer
> started, so the guest rebooted before any installer-side code could run. The seeded run measured
> the injection, not the suppressor. The seed-OFF control above (19:25:24 -> 19:26:50, 90 s, healthy)
> is unaffected and remains the ONE install configuration verified end to end.

**INSTRUMENT DEFECTS FOUND (all mine, all fixed or recorded):**
1. `qtest shot` returns an EMPTY tar for a guest with no gui-agent session, so every WIN10 failure
   was literally unreadable. The owner was right that it is capturable by window: `qtest fullshot`
   does see it, and `tools/winshot.py` now crops that capture to the named window - verified on the
   Automatic Repair screen. `winshot --classify` turns it into RECOVERY/BLACK/DESKTOP, validated
   against a known repair screen and two known live desktops.
2. `Get-Content -Wait` streamed over qrexec DIED SILENTLY at 28 lines while the guest-side log grew
   to 104. A streaming instrument that truncates without saying so is worse than none - poll the log
   with bounded reads instead, and compare counts.
3. The probe waited 35 minutes for a Halted state that this install never produces ("No reboot from
   here"). A wait whose exit condition cannot occur is not a timeout, it is a hang.
4. Every wait loop of mine polls at a fixed cadence with no stall detection and no abort. The owner:
   "38 cycles with 30s delays and no interrupt action if it did not fly at all - this experiment
   design sucks." Correct. A wait must end early on a terminal state AND on no-progress, and must
   say which happened.

## 2026-08-29 — what the bricked win10-tpl actually shows (measured before releasing it)

Booted `win10-tpl` in its post-brick state and sampled it for 5 minutes before reusing the qube, so
the physical evidence was read rather than discarded. Measured, not inferred:

- `admin.vm.Start` never returns: qrexec does not come up (the call was still waiting at the 240 s
  cap; the qube sat `Transient`). This is the queued-call pattern — drained afterwards with the
  documented `qrexec_timeout 15` + kill, then restored to 6000.
- Exactly ONE window is mapped, **1024x768**, and it classifies **BLACK**.
- Ten consecutive captures over 5 minutes are **byte-identical** (same md5). Nothing renders at all;
  this is not a slow boot.

Two things follow, and they matter for the hypotheses:

1. **It is NOT an Automatic Repair screen.** The owner-reported repair loop is not what this guest
   shows now. Either the repair cycle already ran to its end and the guest now fails earlier, or the
   earlier repair observations came from a different run — and every one of those observations is
   from a contaminated cell anyway. Treat "endless Automatic Repair" as UNPROVEN for this guest.
2. **1024x768 is the emulated-VGA resolution.** A healthy guest on this rig maps 2566x1022
   (measured today on win10-u10). So this guest never gets far enough to reach the Qubes video path
   — the failure is early, before the PV/IDD display comes up, which is consistent with a boot-path
   break rather than a QWT-level fault. That is a genuine discriminator for H3 and it is the first
   piece of physical evidence about the brick that is not contaminated by harness injection.

The capture is kept as `instrumentation/fixtures/win10-tpl-brick-black-1024x768.png` — a REAL
BLACK fixture from the actual failure, replacing one of the synthetic-only classifier validations
the plan flagged as owed. It is a single guest window, 1024 px wide, so it is the accepted
per-window capture class, not a desktop capture.

Not resolvable from here: WHY the boot fails. That needs the volume read offline (dom0-assisted) —
which is the owner call recorded in the plan's Q3. Having extracted everything obtainable from
inside, the qube is released for campaign use.

## 2026-08-29 — I made win10-u10 undriveable trying to build a stock precondition. Recording the cost.

To run the true stock-4.2.2 upgrade cell I needed a guest genuinely at stock. None existed — all
five guests now carry 4.3.15. I tried to build one on the expendable guest (`win10-u10`) by
uninstalling QWT and then installing the stock MSI from `artifacts-stock/` via our own installer,
which FINDINGS records as the proven route for that MSI.

**The uninstall succeeded and took the qrexec agent with it.** QWT *is* the qrexec agent, so the
moment `msiexec /x` completed there was no channel left to push the stock package over. The guest
now boots and halts normally under ACPI but answers nothing: ten probes across ~9 minutes, qrexec
down every time, after a clean shutdown/start cycle.

`win10-u10` is therefore driveable only through the provisioning route (`build-answer-stick.sh` /
reprovision from ISO), not from here. That is a real cost of my own making and it is on the record.

**The lesson, which the plan already stated and I did not weigh properly:** a precondition must
never be *constructed by uninstalling*. `c1f4312` said so about the fresh cell for a different
reason (leftover MSI registration graded as fresh); the stronger reason is that on this rig the
uninstall removes the only control channel. A stock precondition can only come from provisioning —
which is exactly why `build-answer-stick.sh` has a `STOCK_SETUP` path and why its comment says "our
installer is the only path proven to install this MSI". It is a PROVISIONING-time route, not a
running-guest one.

Cells 5 and 6 (true stock-4.2.2 upgrade; fresh install from ISO exercising stage 1 -> stage 2) both
require that provisioning route: an answer stick built per OS, a reprovision, and vm-pool headroom
(81.8% used). They cannot be reached by manipulating a running guest.

## 2026-08-29 — WIN11 stock cell, correct package: install + hotplug PASS, then qrexec dies post-attach

Re-run of the WIN11 stock cell with the **verified-correct** package (provenance checked BEFORE the
run this time: `repo 898910d`, 5 latch-fix markers in the staged installer).

**Install half — PASS.** Genuine stock precondition (QWT 4.2.2.0, agent 4.2.2.0, testsigning on,
monitor Auto+Running); `found existing QWT: 'Qubes Windows Tools v4.2.2.0'`; **latch seeded
unconditionally on a StandaloneVM** — `class='StandaloneVM': seeding PV NIC priming latch
UNCONDITIONALLY` → `{"ok":true,"armed":true,"nics":1,"vif_enum_key":true}`; `INSTALL COMPLETE`;
**58 watcher samples, 0 dialogs**; monitor disarmed 2→4.

**Hotplug — PASS.** After the reboot the applier was confirmed present (`TASK QubesPvNic = Ready`,
`APPLIER_SCRIPT = present`) — the exact variable that was ABSENT when this same guest failed on the
pre-fix package. Live attach at 12:50:32, **PV NIC up at 12:50:56: 24 seconds, no reboot.** That makes
the correlation **3-for-3 with the applier present, 0-for-3 without**, across both operating systems.

**Then qrexec died and did not return.** From ~12:52 onward: guest `Running`, ~107 s CPU per 30 s wall
(≈3.5 vCPUs pegged), **no windows mapped** (empty capture), qrexec down through 13:11 — 19+ minutes.
So the final grading of this cell (health-check, traffic) could not be taken.

**What this is NOT:** not the install (that completed and was verified), and not the PV NIC (it bound
and was verified up). It happens AFTER a successful attach. Whether it is the network reconfiguration
killing the agent, the known Xen HVM IPI/TLB-shootdown wedge class (see
`wedge-ipi-shootdown-deadlock`), or something specific to this guest, is **UNPROVEN** — one occurrence,
no repeat, and I will not guess at it. Guest preserved and shut down via ACPI (never a hard kill,
which is what left `win10-tpl` unbootable).

**Cell status: install PASS, hotplug PASS, functional grading INCOMPLETE.** Recording it that way
rather than inferring the last step from the first two.

## 2026-08-29 — WIN11 stock cell COMPLETE (ok:true); and the qrexec death investigated, not retried

**Cell complete.** After the guest recovered on its own, `health-check` on `win11-24h2`:
`ok = True`, zero genuine failures, XENBUS/XENIFACE/XENVIF/XENNET all started,
`emulated_nics_still_present: []`, ip `10.137.0.64`, DNS resolving, traffic flowing. Combined with
the earlier install (stock 4.2.2 detected, `ok:true`, 0 dialogs / 58 samples, monitor disarmed 2→4,
zero MSI gaps) and the hotplug (24 s, zero reboots), the cell PASSES end to end.

**The qrexec death — investigated from the guest's own logs.** Read the System and Application logs
across the failure window (15:45–16:20 guest local):

- `15:46:27  L2 7043` GUI agent watchdog did not shut down properly after preshutdown
- `15:47:02  L3 219`  **`\Driver\WUDFRd` failed to load. Device: `ROOT\DISPLAY\0000` Status `0xC0000365`**
  (`STATUS_DRIVER_FAILED_PRIOR_UNLOAD`) — the IDD's UMDF driver failed to load on that boot, which
  explains "no windows mapped" independently of qrexec
- `15:47:24  L2 7000` `luafv` failed to start (driver blocked)
- `15:50:36–38 L2` Security-SPP License Activation failed (`0x80072EE7`) — fired the moment the
  network arrived. Checked: the image is `Windows(R), EnterpriseEval edition` but
  **`LicenseStatus=1` (Licensed), ~90 days grace** — so activation failure is NOT the cause.
- **Then nothing at all until 16:20.** No crash, no service failure, no bugcheck — while the guest
  burned ~107 s CPU per 30 s wall (≈3.5 vCPUs).

**High CPU with zero logged events is the signature of the known wedge** — the Xen HVM
IPI/TLB-shootdown deadlock proven from two NMI dumps (see `wedge-ipi-shootdown-deadlock`), where the
guest keeps running and qrexec-wrapper is the thing deadlocked, so nothing gets logged. That class is
**out of QWT scope and reportable upstream**, not our defect.

**Confidence, stated honestly: PLAUSIBLE, not proven.** One occurrence, no NMI dump taken, and I did
not reproduce it. What IS established: it is not the install (completed and verified before), not the
PV NIC (bound and verified up before), and not eval-license expiry (checked). The IDD `WUDFRd` load
failure at boot is a separate, real observation worth its own investigation — it is OUR driver
failing to load, and it would explain the absent windows.

## 2026-08-30 — RETRACTION: the "stock 4.2.2 cannot speak 4.3 qrexec" hypothesis, and a reinstall I should never have run

**Retracted.** I wrote that stock QWT 4.2.2 might target Qubes 4.2 and be unable to connect to a 4.3
dom0. Owner: *"upgrading from stock to ours was a standard procedure before and it almost never
failed"* and *"your 'leading hypothesis' is obvious hallucinatory bullshit that came from context
overload"*. Both correct. I had no evidence for it, and it contradicts a path known to work. I
invented a mechanism to explain a failure instead of looking for my own mistake in causing it.

**The likely truth, with no protocol theory needed:** my stock stick installs
`qubes-tools-4.2.2.exe` with `/passive` at first logon - a route I constructed tonight and that has
never been exercised here. If stock QWT simply never installed, its qrexec agent was never there to
connect, which fits the observation exactly (`admin.vm.CurrentState` works, `qubes.VMShell` refused
= the GUEST's agent absent).

**And the process error that matters more:** I was REINSTALLING WINDOWS to get a stock guest while
`win10-gold0` - a sealed, pristine, QWT-free ST0 image - sat Halted for exactly this purpose. The
owner told me hours ago not to reinstall where a clone will do; I wrote that rule into the protocol
(ST0 row, §2.1) and then broke it twice tonight. Correct procedure is one clone (~1 min):

    clone win10-gold0 -> churn qube        # pristine Windows, no QWT
    install stock QWT into the clone       # its own installer, on a running guest
    install ours over it                   # the upgrade path under test

That also removes the stick entirely from the stock cell, which is what made it fragile: a fresh
Windows install plus an untested unattended installer invocation, when the only thing under test is
"ours installs over stock".

## 2026-09-01 — "can we introspect a guest with dead qrexec?" MEASURED. Answer: partly, and the part that matters is NOT proven

Owner reframed the question correctly: *"we pretty well know that PV console won't die if we stop
qrexec agent. The question is rather if something that prevents qrexec agent from functioning
wont touch the PV console."* Right - a deliberate `net stop` proves nothing. (It did not even run:
`net stop QrexecAgent` hit the dependency prompt for QubesGuiWatchdog and aborted, subject
unchanged.) So the test became: take away the thing that ACTUALLY kills qrexec in the field.

New tool: **`tools/qcon`** - run a command in a guest over the PV console instead of qrexec.
Validated both ways before use (rule 3): correct output on a known-good guest, and rc=4
"not Running" on a halted one. Two instrument defects found and fixed DURING validation, both of
which would have produced false results:
 - syncing on `'>'` matched a prompt still trickling in from the previous exchange, so the buffer
   was cleared at the wrong moment and a command was silently skipped - the tool reported a
   stall for a command it had thrown away. Now syncs on silence + the token's own echo.
 - "no bytes" was reported as one verdict. `admin.vm.Console` takes `flock -n -E 200`, so a
   second attacher exits **200** and a policy refusal exits **126**; both looked like a dead
   console. Now distinguished (BUSY / REFUSED / NOCONSOLE). The first NOCONSOLE seen in this
   session was in fact lock contention, and re-attaching worked.

**THE MEASUREMENT (win10-app; root volume is snap_on_start/save_on_stop=False, so C: resets on
reboot and the whole thing is undone by a restart).** Disabled AutoAdminLogon, `shutdown /l /f`:

    interactive session user: ''      explorer procs: 0      query session: console 2 Conn, no user
    qrexec probe  -> ANSWERED, `whoami` = nt authority\system
    PV console    -> ANSWERED, live prompt `C:\Users\user>`

**This RETRACTS the advantage I claimed hours earlier.** I wrote that the console's edge is that
"qrexec needs a logged-on session". On THIS rig it does not: dom0 policy imposes `user=SYSTEM`
for `qubes.VMShell` (memory `presession-qrexec-system`), so qrexec answers with no session at all.
The console adds nothing there **for us**. It remains a real advantage for an end user's Windows
qube, where stock QWT qrexec does run in the interactive session - that is the limitation the
README lists - but it is not an advantage on the testbed.

**What the two channels actually share** (the owner's real question):
 - `xenbus.sys` - both PV stacks sit on it;
 - the guest kernel being able to schedule work at all;
 - Xen event channels;
 - and for THIS qube, dom0-side qrexec: `admin.vm.Console` is itself a qrexec call from
   win-idd-mgmt to dom0. Only the GUEST's agent is bypassed, never the whole path.
**What they do not share:** the vchan/grant rings, qrexec-agent, the gui-agent, the interactive
session, and any Windows service the QWT installer owns.

**Consequence for the failure we actually keep hitting: the console probably does NOT rescue it.**
The measured wedge is a Xen HVM IPI/TLB-shootdown deadlock (two NMI captures). If vCPUs spin
without yielding, xencons's DPC/worker does not run either and the console goes silent with
everything else. Nothing measured since contradicts the caveat written when the driver was built.

**So the console's honest unique value is narrower than I said:**
 1. the RETROACTIVE transcript - `/var/log/xen/console/guest-<vm>.log`, written continuously by
    xenconsoled whether or not anyone is attached. Nothing else here keeps pre-failure output.
 2. a dom0-side path needing no policy, no agent, no qubesdb: `sudo xl console -t pv <vm>`.
 3. a channel that survives anything scoped to the QWT services/session - which on this rig is a
    smaller set than it sounds, because SYSTEM qrexec already survives most of it.
**If we want wedge RESCUE, the emulated serial + EMS/SAC is the thing to build**, not this: SAC is
in-kernel, answers at IRQLs a user-mode tty cannot, and offers restart/crashdump verbs.

**Post-reboot check, and a further limit found.** win10-app came back clean and self-healed
exactly as the volume config predicted: `AutoAdminLogon = 1`, session `WIN-IDD-TEST\user`,
explorer running, QrexecAgent Running, and the `contest` account **does not exist** (its creation
was refused by the permission classifier and the experiment was redesigned without it - no guest
credentials were ever touched).

But the console after that reboot is at **`login:`**, not a shell: the previous cmd.exe died with
the restart. So the console survived the LOGOFF earlier only because a session had already been
established on it (the owner had logged in via `sudo xl console`). **A guest console is a usable
COMMAND channel only if someone has logged into it since the last boot** - `tools/qcon --raw`
always works and proves liveness, but `tools/qcon <cmd>` needs that login. This rig has no stored
guest credentials and must not acquire any casually.

That is a third dent in the "introspect a dead-qrexec guest" story, after the two above: the
channel needs a human at boot time, which is exactly what you do not have when a guest wedges
overnight.
**There is a way out, and it is the OWNER's call because it is a security tradeoff, not a
technical one:** `xencons_monitor` runs as SYSTEM and does `CreateProcess` on whatever
`HKLM\...\Services\xencons_monitor\Parameters\default\Executable` names - today
`xencons_tty_9_1_0_0.exe`, which authenticates first. Pointing it at something else would give an
UNAUTHENTICATED SYSTEM console to anyone who can attach. On a Qubes guest that set is only dom0
plus qubes holding `admin.vm.Console` policy, so it may well be acceptable here - but it removes
the guest's own authentication boundary and must not be done without an explicit decision.

