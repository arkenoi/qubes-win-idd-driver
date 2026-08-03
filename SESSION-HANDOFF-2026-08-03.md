# SESSION HANDOFF — 2026-08-03

Written at the end of a very long session that produced four good fixes, one retracted
finding, and three self-inflicted outages. **Read "Traps" before touching the guest.**

Everything below was re-read from the machine or the repo at handoff time, not recalled.

---

## 1. Verified current state

### Guest `win-idd-test`
| thing | value | how to re-verify |
|---|---|---|
| power state | Running, stable (6 consecutive probes / 2.5 min) | `qvm-ls --fields NAME,STATE` |
| `gui-agent.exe` | sha `4B4CE2B1C5441C88`, **identical to `.orig`** — i.e. the PRE-SESSION binary | `Get-FileHash` both |
| `PerWindowCapture` | **0** | `HKLM\Software\Invisible Things Lab\Qubes Tools` |
| QdbDaemon / QrexecAgent / QubesGuiWatchdog | all Running | `Get-Service` |
| **`netvm`** | **`core-net` — THE GUEST IS ONLINE** | `qvm-prefs win-idd-test netvm` |
| OS build | 19045.**6466** (was .6456 at session start; updated itself mid-session) | `ver` |
| Office | Microsoft 365 Apps installed, unlicensed/reduced-functionality | |

The guest is back to exactly its pre-session configuration. Nothing from this session is
deployed to it.

### Repo
- superproject `de321b5`, agent submodule `6b5b298`, all pushed, CI green.
- `agent` branch: `fix-mso-shadow-adoption`.

---

## 2. What shipped (code), and what is actually proven

| commit | what | validated on guest? |
|---|---|---|
| `98eed30` | send-side CreateSent gate + synth overlap test + DeletePending skip | **YES — 6/6 checks, one clean dom0 window, vchan healthy** |
| `aaa8c37` | reject `MSO_BORDEREFFECT_WINDOW_CLASS` in ShouldAcceptWindow | no |
| `66fc670` | never re-home an owned popup whose GW_OWNER is untracked | no |
| `6b5b298` | never capture while the secure desktop is up | no |

**Do not treat the last three as proven.** `6b5b298`'s only deployment coincided with the
QdbDaemon outage (trap 2 below), so its evidence is unusable in both directions — it is
neither implicated nor cleared.

The one fully closed defect: Office's shadow strips fed gui-daemon a `MSG_CONFIGURE` for a
window it had no CREATE for (`msg 0x86 without CREATE for 0x20340` in
`guid.win-idd-test.log.old`), which `exit(1)`s the daemon and costs the qube its GUI. Root
cause, mechanism and fix are in FINDINGS 2026-08-03.

---

## 3. The five open tasks, reassessed

### T1 — Validate `aaa8c37` / `66fc670` / `6b5b298` on the guest — **STILL ACTUAL, do first**
Three shipped fixes with no on-guest evidence. Needs: deploy, reproduce Word's sign-in
dialog, confirm (a) no `synth paint … outside owner`, (b) no `msg=SYNTH` for the strips,
(c) the frozen L-shaped shadow band in the document area is gone, (d) vchan healthy.
Prerequisite: quiesce the guest (T5) so servicing does not confound it again.

### T2 — 1600×1000 default resolution + resize→resolution — **STILL ACTUAL, highest value**
Untouched by today's confusion; design agreed and decisions settled (§5). This is the
largest genuinely-actionable piece of work outstanding.

### T3 — Hybrid capture design (`scratchpad/hybrid-capture-design.md`) — **DOWNGRADE, premise now suspect**
The design still stands on its own (the occlusion analysis, the mask/coordinate-space
constraints, the locking argument). But its *motivation* has weakened twice:
1. The original Office typing lag was already explained and fixed guest-side — Office
   hardware acceleration on a GPU-less VM (FINDINGS 2026-08-02), not PrintWindow.
2. Every latency number taken this afternoon is polluted: a cumulative update was
   installing underneath them (12:12→16:05) and the OS build changed mid-measurement.
3. The guest currently runs `PerWindowCapture=0`, so PrintWindow is not even in the path,
   and no typing lag has been reported in that configuration.

**Do not implement it.** Re-run its §7 gate first (the `PerWindowCapture` 1-vs-0 A/B) on a
quiesced, offline guest. If the delay is upstream of the DDA frame, the whole design buys
nothing and should be closed, not built.

### T4 — The 09:57 silent agent deaths — **DOWNGRADE, may not be a bug at all**
Two agent instances vanished mid-frame with no vchan error, no teardown and no WER entry.
I flagged these as unexplained all session. Reassessing honestly: that morning the guest
was also servicing updates (KB5066135 installed 02/08 19:30; update activity resumed 10:16;
Kernel-Power 41 at 10:06). An unclean host-level restart explains a process disappearing
with nothing in its own log at least as well as an agent bug does.
**Recommendation: do not chase this until the guest has been offline and stable for a full
session.** If it never recurs on a quiesced guest, it was servicing.

### T5 — Detach the netvm **while measuring** — a control, NOT a solution
`qvm-prefs win-idd-test netvm ''` before any timing or stability measurement, so servicing
does not confound it (it confounded everything today).

**This is measurement hygiene only. Do not mistake it for a fix, and do not leave the guest
offline as the end state** — see T6, which is the actual requirement.

Also worth doing while there (autologon trap, §4.3):
```
net user user qubes
net accounts /lockoutthreshold:0
```
Ask before the password line — the account was *created* at install on 02/08 14:33 (events
4720/4722/4724 under `WIN-IDD-TEST$`, preceded by the same pattern under the setup-time
name `MINWINPC$`), so `qubes` is the documented value but has not been re-verified.

### T6 — A networked, self-updating Windows qube must stay stable — **THE REAL REQUIREMENT**
Stated by the user at handoff, and it reframes most of today: the target is a Windows qube
that has a netvm, installs its own updates, and survives doing so. Today's servicing cycle
was not noise to be eliminated — **it was the first real test of that requirement, and the
qube did not pass it cleanly.** What the day actually demonstrated, as requirements:

1. **The gui-daemon must survive, or be restartable.** When it exits, nothing brings it back:
   the agent parks at "Awaiting for a vchan client" forever and the qube has no GUI until a
   full restart. `98eed30` removed one cause of daemon death; the *fragility* is untouched.
   This is the single biggest robustness gap and it is dom0-side, so it needs design
   discussion before code (Phase 3 discipline).
2. **A servicing window makes the qube look dead to Qubes tooling.** During the cumulative
   update the guest was unreachable over qrexec for ~10+ minutes while `power_state=Running`.
   Check what `qrexec_timeout` is actually set to (kit default 300 s; PROVISION-LOG records
   7200 applied) and whether dom0 tooling degrades gracefully across that window.
3. **Autologon must survive an update reboot.** Today's trap (§4.3) is not a lab artifact:
   updates reboot the machine, autologon retries with an invalid credential, and the account
   locks itself out. On a real user's Windows qube that is a hard lockout after a routine
   patch cycle.
4. **The agent must tolerate repeated unclean restarts and long secure-desktop periods.**
   Kernel-Power 41 unclean reboots and multi-minute logon-screen stalls both occurred. The
   agent+watchdog did recover each time — that part worked. `6b5b298` (never capture on the
   secure desktop) is aimed squarely here and is still unvalidated (T1).
5. **This connects to Track C** (CLAUDE.md): Windows update status/management from dom0.
   Today produced a free, unplanned end-to-end sample of what a real update cycle does to a
   Windows qube. Mine it rather than discard it.

**Suggested order: T5 (as a control) → T1 → T2. T6 is the standing requirement the others
serve; T3 gated on its own experiment; T4 parked.**

---

## 4. Traps that cost this session — read before touching the guest

### 4.1 `netvm=core-net` → Windows Update runs underneath everything
Attached for the Office install and never removed. Consequences observed today: two
TrustedInstaller "Operating System: Upgrade (Planned)" restarts (16:04:24, 16:05:46), an
unclean Kernel-Power 41 reboot, a `user / Welcome` logon stall that looked exactly like a
hang, and an OS build change mid-benchmark. **Any measurement taken on a networked guest is
worthless.** Check `qvm-prefs`, not CLAUDE.md's "offline" claim — the rule states intent,
`qvm-prefs` states reality.

**But do not over-correct into "keep it offline".** A networked, self-updating Windows qube
that stays stable is the actual goal (T6). Offline is a control you switch on for a
measurement and off again afterwards. The failures above are not reasons to avoid the
network — they are the defect list for T6.

### 4.2 `scratchpad/deploy.ps1` has a service-selection bug — do not use it
```powershell
$svc = Get-Service | Where-Object { $_.DisplayName -match 'Qubes' -and $_.Status -eq 'Running' } | Select -First 1
if ($svc) { Stop-Service $svc.Name -Force }   # ...later: Start-Service $svc.Name
```
Non-deterministic; it selected **`QdbDaemon`**. `Stop-Service -Force` takes down QubesDB
*and its dependents* including `QrexecAgent`; `Start-Service` restarts only QubesDB, so
qrexec never comes back and the guest goes mute. This produced two "the guest is broken"
scares that were entirely self-inflicted.
**Correct pattern:** name `QubesGuiWatchdog` explicitly, never `-Force` anything else. A
known-good version is `scratchpad/revert-uniq-c3.ps1`.

### 4.3 Autologon can lock the account out
`AutoAdminLogon=1` with **no `DefaultPassword`** → Winlogon retries interactive logon every
~12 s → threshold-10 lockout (event 4740 at 02/08 19:27:46), 10-minute duration, during
which even a correct password is refused. No screensaver/idle lock exists on this box, so
any "it locked itself" is this. Note: **no 4625 events today**, so today's prompt-and-denial
is more likely the post-update logon screen than a lockout — stated as uncertainty, not fact.

### 4.4 My own failure mode — the one to actually internalise
Repeatedly acted on a stale in-memory model instead of re-reading state: asserted the guest
was offline without checking `qvm-prefs`; committed a confident FINDINGS entry blaming
`PerWindowCapture` and had to retract it (`8040d31` → `61d87e4`); attributed my own commits
and an overwritten `deploy.ps1` to the user twice; claimed the VM "recovered on its own"
when my own `qvm-kill` had done it. **Re-read the machine and the repo at the start of any
task, and again before any destructive step.**

---

## 5. Agreed design, not yet implemented (T2)

**Premise (user's, and it inverts the earlier approach):** we do not want the Windows
desktop fullscreen. Default to a moderate window suitable for typical guest software; the
fact that Windows *wants* the whole screen is irrelevant. Honour a guest *program's*
fullscreen request later, behind policy — never the desktop itself unless asked.

| piece | decision |
|---|---|
| default guest resolution | **1600×1000** (was: `HandleXconf` copies host resolution verbatim, vchan-handlers.c:117-134) |
| dom0 window resize → resolution change | **already wired** — window-0 `MSG_CONFIGURE` → `RequestResolutionChange`, 500 ms debounce, vchan-handlers.c:543-565; `IS_RESOLUTION_VALID` is only a 320×200 minimum |
| workarea + frame extents | a **ceiling**, not a target — never propose a mode dom0 cannot display decorated |
| registry `FullscreenWidth/Height` | **split it**: today it is written by `SetVideoMode` (a cache of the last applied mode) yet read as if it were user intent. Needs a user-preference value distinct from the last-applied cache |
| scope | **non-seamless first**; leave seamless alone (shrinking the screen there constrains where dom0 can place guest windows) |

Feasibility caveat, unverified: whether the display driver accepts arbitrary modes was never
measured — the probe was written (`scratchpad/modes.ps1`) but never ran, because the guest
went unreachable. **Run it before implementing**; if the Basic Display Adapter only offers a
fixed mode list, this becomes a Track B (IddCx) dependency.

Work-area machinery already exists and is better than the design doc implies — three
sources in priority order (registry / qubesdb `/qubes-workarea` + frame extents / inference
from daemon-dictated origins), plus `MSG_WORKAREA` handling. See `workarea.h`. Unverified:
which source is actually live on this guest, and whether `/qubes-workarea` is written at all
(needs the optional dom0 watcher script installed).

---

## 6. Quick verification block for the next session

```bash
qvm-prefs win-idd-test netvm            # MUST be '' before any measurement
qvm-ls --fields NAME,STATE
cd ~/qubes-win-idd-driver && git log --oneline -3 && git -C agent log --oneline -3
./tools/qtest run "echo SHELL_OK"       # mute => qrexec down, reboot the qube
```
In-guest: confirm `gui-agent.exe` hash vs `.orig`, `PerWindowCapture`, and that
QdbDaemon/QrexecAgent/QubesGuiWatchdog are all Running.

## Correction to T4's downgrade (added after review)

T4 (the two silent agent deaths) was parked above on the reasoning that the 10:06 Kernel-Power 41
unclean restart could explain "a process vanishing with nothing in its own log". **That does not
fit the timeline and should not be relied on:**

```
09:57:00  agent 3952 dies silently   -> daemon logs libvchan_is_eof, RESTARTS
09:57:51  agent 3432 dies silently   -> daemon logs libvchan_is_eof, RESTARTS
09:58:07  agent 8016 sends MSG_CONFIGURE for an unannounced window
          -> "msg 0x86 without CREATE for 0x20340" -> daemon exit(1), never restarts
~10:06    Kernel-Power 41 unclean restart
```

Both deaths precede the restart by ~8-9 minutes, and the daemon demonstrably kept running and
restarting between and after them - so the session was live, not tearing down. A host restart at
10:06 cannot retroactively kill a process at 09:57. The Windows-Update servicing argument does not
cover it either: servicing restarts processes it owns, and would not produce two agent exits with
no WER entry while the gui-daemon stayed up.

So T4 is **still unexplained, and still possibly a real bug**. Keep it parked only in the sense of
"needs a quiet guest before it can be chased", NOT in the sense of "probably wasn't a bug". The
thing that WAS explained today is the daemon's death at 09:58:07, which is a different event with
a different cause (the zero-overlap strip chain, fixed).
