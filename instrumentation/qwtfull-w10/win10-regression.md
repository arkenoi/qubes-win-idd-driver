# Win10 regression pass of the acceptance/protocol suite — BLOCKED (2026-08-02 00:00–00:21)

## Verdict: BLOCKED — zero scenarios executed. Nothing about the five fixes was verified.

The task's precondition ("VM is Running, netvm detached, qrexec OK") did not hold when the
session started. win-idd-test is wedged in the documented starvation state: ~3.8–4.0 of 4
vCPUs pegged continuously for the whole 24-minute observation window, qubes.VMShell data
vchan times out on every attempt, dom0 shows NO seamless windows for the VM. Recovery per
SESSION-HANDOFF-qwt-full.md requires a VM reboot, which this task's hard rules forbid
("NEVER run qtest kill/shutdown/start, never reboot the guest"). Every step of the
regression pass (registry ProtoTrace, agent restart, scenario scripts, log pull) needs
qrexec, so none could run. Per the acceptance protocol, missing data = NOT-PASS; this is
BLOCKED, not FAIL — no evidence exists either way about the build's behavior.

## Measurements (all raw, this session)

qrexec probes — every one failed:

| time | probe | result |
|---|---|---|
| ~23:57 | `qtest pushrun precheck.ps1` | hung; killed at 120 s (qvm-copy also needs guest agent) |
| ~00:01 | `qtest run "echo ..."` timeout 60 | no output, killed |
| 00:02–00:07 | `qtest run` timeout 300 | `vchan_timeout.c:46:qubes_wait_for_vchan_connection_with_timeout: vchan connection timeout` / `qrexec-agent-data.c:371:handle_data_client: Data vchan connection failed` |
| 00:07–00:14 | 3x `qtest run` timeout 90, 60 s apart | 0 marker matches each |
| 00:19–00:21 | `qtest run` timeout 90 | killed, no output |

CPU burn (admin.vm.CurrentState cputime, ns; VM has 4 vCPUs):

| wall time | cputime | interval rate |
|---|---|---|
| ~23:57 | 360,673,984,701 | — |
| ~00:03 | 1,081,660,955,939 | — |
| ~00:04 (+10 s) | 1,119,849,315,448 | **3.82 cores** |
| 00:14 | 3,548,253,549,190 | — |
| 00:14 (+20 s) | 3,625,161,506,282 | **3.85 cores** |
| 00:17:48 | 4,013,054,142,747 | — |
| 00:18:48 | 4,237,897,861,122 | **3.75 cores** |
| 00:21:07 | 4,764,401,549,399 | sustained |

Whole-window average 23:57→00:21 (1330 s): (4764.4−360.7)e9 ns ≈ 4404 s CPU ≈ 3.3 cores,
with every instantaneous sample at 3.75–3.85. This is not a transient scan; it is a
steady-state spin.

dom0 view:

* `qtest shot` (local.WinScreenshot, VM-scoped) → **empty tar** (`regr/pre-state.tar`,
  0 bytes): no managed seamless windows exist for win-idd-test.
* `qtest fullshot` 00:16:41 → `regr/blocked-fullshot.tar`. geometry.txt lists exactly ONE
  win-idd-test window: `0x1c00188 0 0 3440 1440 0 win-idd-test (Windows Desktop)` — the
  full-desktop window only, no per-app windows. (Read from geometry.txt per protocol; the
  screen pixels are overlapped by other qubes' windows and prove nothing extra.)

Qube config (read-only checks): netvm = none (empty), features `gui=1`, `qrexec=1`,
`gui-emulated=''`, state Running throughout. So the netvm-starvation mode (handoff §BLOCKER)
is excluded — no netvm is attached.

## Diagnosis (signature match, not proven from inside — the inside is unreachable)

The state matches the **daemon-absent respawn storm** documented in
SESSION-HANDOFF-qwt-full.md / FINDINGS.md session 6: agent exits when it cannot reach a
gui-daemon, QgaWatchdog relaunches it once per second, each start does real work (grants,
enumeration) → sustained multi-core burn (measured there ~2.8/4; here 3.8/4 — this build's
per-window startup is heavier), qrexec starved to death, "until the VM is killed". The
single stale "(Windows Desktop)" window shows a gui connection existed at some point this
boot and is gone. The definitive discriminator (census of `gui-agent-*.log` files — one per
process start) requires qrexec and could not be run.

Note: `gui=1` is set NOW, but dom0's decision to attach a gui-daemon is made at VM start
with the values current THEN; session 6 deliberately set `gui=''`/`gui-emulated=1` for the
reinstall, and QWT re-advertises `gui=1` only after it connects. If this boot began under
the reinstall-era flags, no gui-daemon was attached this boot and the storm is fully
explained. Unverifiable from this qube (would need dom0 process list).

## What this session did NOT do

* No ProtoTrace/LogLevel change (registry unreachable — nothing to restore).
* No agent restart, no windows opened in the guest (nothing to close).
* No scenario (occlusion/menu/drag/chromerepro) ran; chromerepro.exe IS available locally
  (`artifacts/chromerepro.exe`), so that sub-check is ready once the VM is back.
* check-protocol.py / check-occlusion.py were never fed data.

## What unblocks the rerun (needs the parent/user — outside this task's permissions)

1. Clean reboot of win-idd-test (`qtest shutdown` — ACPI, NOT kill, per session-6 rule —
   then `qtest start`), with `gui=1` (already set) so dom0 attaches the gui-daemon.
2. Verify qrexec answers and seamless windows appear (`qtest shot` non-empty).
3. Then rerun this regression pass from step 1 (ProtoTrace on, agent restart, scenarios).
   Budget ~1 h. All harness pieces exist: tools/viewcheck/protorun.ps1 (menu+trace),
   tools/viewcheck/occlusion-test.ps1 + tools/check-occlusion.py,
   tools/viewcheck/snap.ps1 + snapcmp.sh parse (guest JSON with DWM extended bounds for
   check-protocol.py), artifacts/chromerepro.exe. One heads-up for the rerunner: the
   3c12071 rejection line and the d610454 sub-floor drop line are both LogDebug — the
   'rejecting'/'sub-floor' greps need `gui-agent\LogLevel=4` during the trace runs
   (restore to 3 after). Also check-protocol.py invariant 4 counts only MAP as "announced";
   on this build a contained Notepad menu is SYNTHESIZED (msg=SYNTH, no MAP), so a
   `menu-announced` failure whose hwnd has SYNTH records + SYNTHPAINTs + no separate menu
   window in dom0 is the synthesis path working, not a regression — judge it against the
   dom0 shot, do not paper over it in the checker.

## Secondary observation worth keeping

If the storm cause is NOT the stale-feature boot above, then a gui-daemon died or the agent
lost it mid-session on THIS build and the guest self-destructed into the storm — the same
defect class as the rejected `spin-backoff` fix targets. Either way this is the second
live sighting of the storm on the from-source build; the watchdog's 1 Hz unconditional
respawn with no backoff remains an open defect (candidate fix 53056d5 rejected, see
handoff).

## Evidence files

* `instrumentation/qwtfull-w10/regr/pre-state.tar` — empty WinScreenshot tar (0 bytes, itself the evidence)
* `instrumentation/qwtfull-w10/regr/blocked-fullshot.tar` — fullshot: screen.png + geometry.txt (one desktop window only)
* this file
