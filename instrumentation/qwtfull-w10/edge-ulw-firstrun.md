# Edge ULW first-run check (handoff step 5.4) — BLOCKED, 2026-08-02 00:25–00:42

**Verdict: BLOCKED. The check never ran.** Edge was never launched; none of the five
acceptance points were exercised. The guest is in the documented starvation state
(SESSION-HANDOFF-qwt-full.md "BLOCKER — netvm attach still starves the guest") and
qrexec is dead; recovery requires a guest reboot, which this session is forbidden to
perform (hard rule: never qtest kill/shutdown/start).

## What was found instead (all evidence in `edge-fr/`)

1. **qrexec is DOWN.** Every `qubes.VMShell` attempt fails with
   `vchan_timeout.c:46 ... vchan connection timeout` /
   `qrexec-agent-data.c:371:handle_data_client: Data vchan connection failed`.
   The data-vchan connect times out after exactly 120 s (single long attempt
   00:36:36 → 00:38:36, `qrexec-long-attempt.txt`). 7+ attempts over ~17 min
   (00:25–00:42), zero successes (`qrexec-retry-log.txt`).

2. **Guest burns ~3.76 cores continuously** (admin.vm.CurrentState cputime deltas,
   ns):
   - 00:28:48→00:34:48 (4x90 s samples): ~340 s CPU per 90 s wall = 3.78 cores
   - 00:40:25→00:41:25 (60 s): 9311462396999-9085643851065 = 225.8 s CPU = 3.76 cores
   This matches the diagnosed watchdog-respawn starvation signature (handoff
   "Starvation/respawn defect"), NOT a healthy idle guest (~0.05 cores).

3. **Cause: the netvm-attach BLOCKER was triggered between sessions.** The dom0
   fullshot (`fullshot-blocked.tar`, crop `dom0-terminal-netvm-evidence.png`) shows
   dom0 terminal scrollback: `qvm-prefs win-idd-test netvm fw-net` followed by
   `qvm-prefs win-idd-test netvm ""` (user ran the handoff's "PING THE USER for the
   netvm" experiment, then detached). Current state: `qvm-prefs win-idd-test netvm`
   = empty (detached), `gui`=1, `qrexec`=1 features set.

4. **NEW datum vs the previous session's measurements:** the handoff says
   "Detaching netvm → CPU drops to ~0.05 cores immediately". That did NOT hold this
   time — netvm is detached, yet the burn persists at 3.76 cores and qrexec never
   recovers. The starvation survived the detach (>17 min observed here; onset time
   unknown, before this session started).

5. **gui-daemon is alive but seamless is gone.** Fullshot `geometry.txt` lists
   exactly one win-idd-test window: `0x1c00188 0 0 3440 1440 0 win-idd-test
   (Windows Desktop)` — the full-desktop window only, no seamless windows.
   `local.WinScreenshot+win-idd-test` (qtest shot) returns rc=1 with an empty tar
   (`pre-state.tar`, 0 bytes) = no visible per-window content.

## Evidence files (this dir, `edge-fr/`)

- `qrexec-retry-log.txt` — 5 timed attempts with cputime samples
- `qrexec-long-attempt.txt` — 320 s-budget attempt, 120 s vchan timeout
- `fullshot-blocked.tar` + extracted `fullshot-blocked/{screen.png,geometry.txt,cap.err}`
- `screen-vm-area.png` — downscaled 3440x1440 guest-area crop of the dom0 screen
- `dom0-terminal-netvm-evidence.png` — crop showing the netvm attach/detach commands
- `pre-state.tar` — 0-byte qtest shot result (kept as evidence of the failure)

## What this session did NOT do

- Did not launch Edge; opened nothing in the guest (nothing to close).
- Did not touch LogLevel, did not restart the agent, did not reboot/kill the VM,
  did not change netvm or any qube setting.
- Could not read gui-agent logs (qrexec down), so the log-census discriminator
  ("one process spinning" vs "respawn loop", handoff line re gui-agent-*.log
  file count) is still unanswered for this episode — worth running FIRST thing
  after the VM is rebooted, before the log dir is buried in new files.

## To unblock

The guest needs a reboot (user or a session allowed to use qtest shutdown/start).
After reboot: (a) immediately census `C:\Program Files\Qubes Tools\log\gui-agent-*.log`
file mtimes/count to confirm/refute the respawn loop for THIS episode, then
(b) rerun this Edge ULW first-run check per the task steps — the install is still
pristine w.r.t. Edge (it was never launched), so the true-first-run condition is
preserved.
