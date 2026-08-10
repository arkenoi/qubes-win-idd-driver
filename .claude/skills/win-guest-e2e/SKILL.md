---
name: win-guest-e2e
description: >
  Validate a QWT build's REAL behavior end-to-end on the Windows test guest (win-idd-*) via
  tools/qtest — unattended, self-healing across reboots, and honest. Use whenever asserting that
  an installer/agent/driver change actually works: install → reboot → assert, or upgrade/reinstall
  paths, IDD activation, updates, autologon. Codifies the hard rules: test the build that CONTAINS
  your fix, screenshot-when-in-doubt (and LOOK), stuck-detection + kill/restart, bounded timeouts
  (never forever), verify pixels not JSON, defect-reintroduced proof.
---

# Windows guest E2E validation

You control ONLY the `win-idd-*` test guest, only via `tools/qtest`. This skill is how to validate
a change on it without lying to yourself. Every rule here was paid for by a real miss this project
made. Follow them.

## The seven rules (non-negotiable)

1. **Test the build that CONTAINS your fix — prove it before asserting.**
   A deployed setup tree / installed binary routinely PREDATES your commits. Before you conclude
   "the fix works" or "the fix failed", PROVE the artifact under test carries the change:
   - grep the deployed `install.cmd` for the new option, check `DisplayVersion`/a file hash against
     the manifest, or diff the running binary's sha256 vs what you built.
   - Real miss: `/iddonly` "failed" as *Unknown option* — the test tree was built before `/iddonly`
     existed. Both E2E phases were invalid; the fix was fine. The logs never said so — a screenshot did.

2. **Screenshot when in doubt — and actually LOOK at it.**
   Device/process JSON and log tails miss what the eye catches instantly: a cmd window reading
   `Unknown option`, an error dialog, a stuck *Working on updates*, a lock screen, a toast with a
   huge dead surround. Capture the guest's windows at EVERY verdict and ON EVERY FAILURE, then
   `Read` the PNG. `idd:OK` is not "the desktop renders." `agent:running` is not "pixels reach dom0."
   - `tools/qtest shot out.tar` → tar of PNGs of the guest's mapped windows. Open a window first
     (e.g. `notepad`) if the desktop is bare. If the shot is 0 bytes, the screenshot service or its
     policy is the problem — fix that before trusting anything.

3. **Bounded everything — nothing waits forever.**
   Every guest call wrapped in `timeout -k <grace> <secs>`. Every wait loop is `for i in $(seq 1 N)`
   — NEVER `while true`. A separate hard-stop watchdog kills the whole run + any stuck `qtest` at a
   deadline (e.g. 3h) and logs it. Every phase continues on failure (`... || log WARN`), so one wedged
   step logs and moves on instead of stalling the rest.

4. **Stuck-detection + recovery — don't just wait, unstick.**
   The guest can be Running (Xen sees it up) but VMShell-DEAD (lock screen, hung finalize). Passive
   waiting only times out. Detect Running-but-not-alive for ~5 min and `qtest kill` + `qtest start`
   to force it forward. This qube HALTS on reboot, so also restart on `Halted`. (`bootwait` in
   `e2e-lib.sh` does both.)

5. **Self-heal through reboots.**
   Installs reboot (often several times: "Working on updates"). The interactive session — and thus
   qrexec/VMShell — only returns when autologon fires. Ensure autologon RE-ARMS every boot (a SYSTEM
   onstart task or the watchdog service), or the session never comes back and every post-reboot
   check fails. A one-shot autologon dies the first time an update resets Winlogon.

6. **Verify pixels + judge output, not logs — and prove the check can FAIL.**
   Assert the intended EFFECT, against a control. A check counts as evidence only once it has been
   seen to FAIL with the defect deliberately re-introduced (e.g. wipe autologon, confirm the re-arm
   recovers). "No regression" ≠ "fix demonstrated." A metric must be stable on ≥3 runs of ONE
   unchanged build before any verdict; interleave build-vs-build comparisons.

7. **Serial VM-mutating jobs; cold boot in acceptance.**
   Never run two installs/reboots against the guest concurrently — they reboot underneath each other.
   Acceptance includes a real cold boot (`shutdown`/`kill` then `start`), not a live-session restart —
   a restart clears exactly the faults a cold boot exposes.

## Harness

`e2e-lib.sh` (in this skill dir) provides the bounded, stuck-aware helpers: `qstate qrun qpr alive
cap bootwait wait_install`. Source it and build a linear phase script:

```bash
source .claude/skills/win-guest-e2e/e2e-lib.sh
R=/path/results.log; : > "$R"; log(){ echo "[$(date +%H:%M:%S)] $*" >>"$R"; }
bootwait 10 log || { log FATAL; exit 1; }
# ... per phase: push the RIGHT tree -> launch detached -> wait_install/bootwait -> verify -> cap on doubt/fail
```

Then, ALWAYS:
- A watchdog: `for i in $(seq 1 180); do pgrep -f your-run.sh || exit 0; sleep 60; done; pkill -9 -f your-run.sh; pkill -9 -f tools/qtest`
- Launch the run + watchdog with `run_in_background`. When done, `Read` the phase PNGs and confirm real pixels before reporting PASS.

## Report honestly

State PASS/FAIL per phase with the evidence (the JSON AND the screenshot). If a phase was invalid
(wrong build, harness bug), say so loudly and re-run — an invalid PASS is worse than a FAIL. Retract
any earlier claim the moment it turns out wrong.
