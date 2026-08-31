# Fail-proof registry (H5)

**What this file is.** H5 defines `PASS` as *"intended EFFECT demonstrated against a control,
artifact hash-verified, AND the check has a fail-proof on record"*, and states that **a check absent
from this registry can never emit plain `PASS`** — it emits `PASS-UNPROVEN`, counted separately.
This file is that registry. It maps check id → the dated run in which the check **FAILED on a
subject with the defect deliberately present**, with an openable evidence path.

**An entry requires a failing run.** "It would fail" is not an entry. A check whose fail-proof is
owed stays out of this file, and every report citing it must say `PASS-UNPROVEN`.

Created 2026-08-30 during campaign `20260830-acceptance-4.3.16` (P0-PRE.7, previously owed). Before
that date no registry existed, which means **every plain `PASS` written by this project prior to
2026-08-30 was, by H5's own rule, unproven** — recorded here rather than quietly repaired.

---

## Proven — the check has been seen to go red

| check id | seen to fail | how the defect was made present | evidence |
|---|---|---|---|
| `G0 catalog-signature` | 2026-08-30 | a real catalog replaced by a structurally valid PKCS#7 SignedData with an EMPTY `signerInfos` SET — the literal `patch-xenbus-inf.ps1` defect | `tools/tests/g0-negative-control.sh`; two-sided (untouched copy must PASS, planted copy must FAIL **and name the catalog**). Measured: PASS 8/0, then FAIL naming `iddsampledriver.cat` |
| `reboot-dialog watcher` (detector) | 2026-08-30 | `-SelfTest` injects the dialog string the detector keys on | `detector_fires:true` recorded in-session before NET-6 and NET-2 were graded |
| `surface-watch` (detector) | 2026-08-30 | `-SelfTest` creates a topmost window with a known title and requires the sampler to see it | `detector_fires:true`, `matched:["0x30044 WindowsForms10.Window..."]` |
| `primer channel fires` | 2026-08-30 | run with NO job stick attached the hook is inert and writes nothing; run WITH one it must fire and self-unregister | `mgmt/prime-selftest.sh`; Win10 and Win11 both, read off the guest screen (a primed guest has no qrexec) |
| `agent-hash-vs-manifest` | 2026-08-06 | a same-name binary pre-planted at the install path | FINDINGS 2026-08-06 (P1 negative-control ledger, §5) |
| `precondition-mismatch invalidation` | 2026-08-29 | a cell labelled "fresh" pointed at a clone that already carried our package | FINDINGS "contamination 1" |
| `dialog watcher` (product-side) | 2026-08-2x | the unsigned-artifact hang, and a seeded reboot Request with no suppressor | FINDINGS; P1 negative-control ledger |
| `xenbus_monitor DISABLED by INF` | 2026-08-2x | the pre-fix INF starts the service (`SPSVCSINST_STARTSERVICE`, StartType=auto) | the `81d2b79` brick, 5/5 reproduced |
| `harness preflight (require_scripts)` | 2026-08-31 | a required guest script renamed away, on p5-run.sh and p4-run.sh independently | both printed `FATAL: required guest script(s) not found in the repo: <name>` and exited 2. Before this gate the harness ran anyway and printed `deny=?`, silently dropping the vacuity proof |
| `P5 capture-path control` | 2026-08-30 | the capture path WAS blind for a whole run (18 s settle < PowerShell's Add-Type compile); the harness scored SG3 FAIL against a window the agent logged as MAPped | `p5b.log` 2026-08-30; the control Notepad (747x502) now appears in 6/6 samples of every cell, and its absence forces INVALID-INSTRUMENT |
| `SG6 autologon checker` | 2026-08-31 | `AutoAdminLogon=0` + `QubesAutologonGuard` deleted + COLD BOOT — the literal 2026-08-28 field defect | `mgmt/harness/sg6-failproof.sh win10-p46`: control (sessions=1, windows=1) then RED (sessions=0, explorer=0, logonui=1, windows=0, qrexec alive), then re-armed and the subject returned |
| `RND-4 toast detector` | 2026-08-31 | the sampler was prevented from starting (`-ScriptArgs` split at a shell hop) | it reported `samples=0` and the cell graded INVALID-VACUOUS; with `-ArgsB64` the identical run reported 83. `detector_fires:true` proven in-session both times |
| `RND-3 scene-reset gate` | 2026-08-31 | a persistent reminder toast survived from a previous run | the runner refused with `an override-redirect surface is STILL on screen after the reset ... Refusing to grade` and exited 2 rather than grading a dirty scene |
| `U2 boot-pass debounce clear` | 2026-08-31 | `update-status.json` left in place by a scan 9 minutes earlier | the boot-triggered pass fired correctly (`lastresult=0`) and SKIPPED, giving `class_lines:0`; with the file cleared the identical boot gives `class_lines:1, class_correct:true, qdb_retry_evidence:true` |
| `SG1 dom0 boot watch` | 2026-08-31 | the liveness probe inherited a 150s timeout and BLOCKED, so the loop took one sample and waited | the run reported `0 sample(s)` and the `TAKEN < 3` gate refused it as INVALID-INSTRUMENT; with a 5s probe the same boot yields 4-6 samples |
| `pv_console_bound` | 2026-08-31 | `XENBUS\VEN_XP0001&DEV_CONS` disabled via `Disable-PnpDevice` (`problem=CM_PROB_DISABLED`) | `mgmt/harness/failproof-healthcheck.sh`: `failed=[pnp_no_unexpected_errors, pv_console_bound]`, `pass:false bound:false`; re-enabled → `OK CM_PROB_NONE`, `failed=NONE` |
| `pnp_no_unexpected_errors` | 2026-08-31 | same run — a disabled device IS an unexpected PnP error | caught it in the same `failed` list, cleared on restore |
| `updates_dom0_owned` | 2026-08-31 | `NoAutoUpdate=0` — the guest would service itself | `failed=[updates_dom0_owned]`; restored to 1 → `failed=NONE`. Reproduced three times |
| `autologon-armed` | 2026-08-31 | `AutoAdminLogon=0` + guard task deleted + cold boot | `mgmt/harness/sg6-failproof.sh`: read back `autologon=0`, guest mapped ZERO windows with qrexec alive; re-armed → 1 |
| `cold-boot-health` | 2026-08-31 | `NoAutoUpdate=0` planted, then a real COLD BOOT | battery read after the boot: `ok:false failed:[updates_dom0_owned]`; restored → green. Proves the assertion survives and detects across a reboot, not just in a live session |
| `window-chrome-present` | 2026-08-31 | a synthetic PNG with no title bar and no border bands | `tools/tests/failproof-check-chrome.sh`, two-sided: negative → rc=1 *"the window's top band is featureless - title bar / menu bar were cropped out"*; positive (a real capture) → rc=0 `CHROME=OK top_band_colours=23 bottom_band_colours=16` |
| `pixels-reach-dom0` | 2026-08-31 | two captures taken with NO stimulus between them | byte-identical (`f34de700`), so the check correctly reports no pixels reaching dom0; typing a marker changes it (`b29395c0`) |
| `one-precondition-no-mid-reboot` | 2026-08-31 | a second PRECONDITION replayed under the SAME `run_id` | `tools/tests/failproof-install-log.sh` → red on `one_precondition_per_run`; 10/10 real campaign logs pass untouched |
| `no-refusing` | 2026-08-31 | a `REFUSING to install:` line appended | → red on `no_refusing`; 10/10 real logs pass untouched |
| `monitor-disabled-before-msiexec` | 2026-08-31 | every `xenbus_monitor disabled` line stripped (the 81d2b79 brick condition) | → red on `monitor_disabled_before_msiexec`; 10/10 real logs pass untouched |
| `stage1-prepare-ok` / `stage2-install-ok` | 2026-08-31 | the stage RESULT flipped to `ok:false` | `tools/tests/failproof-install-log.sh` negatives 4 and 5 → each turns its own invariant red |
| `resume-fires-once` | 2026-08-31 | a second `stage2-install` RESULT appended | negative 6 → red; the resume must run stage 2 exactly once |
| `reinstall-all-on-msiexec` | 2026-08-31 | `PvDriversDisk` dropped from ADDLOCAL | negative 7 → red. Branch-aware: `REINSTALL=(none)` is CORRECT on clean-install/uninstall-first and reports `na` |
| `pnputil-259-accepted` | 2026-08-31 | a pnputil failure line injected | negative 8 → red; rc=259 "Already exists in the system" stays accepted, which is the check's purpose |
| `no-pv-gate-refusal` | 2026-08-31 | a `REFUSING to install:` line appended | negative 2 → red (same assertion as `no-refusing`, under the cell-specific name for the 2026-08-11 PV-gate guard) |
| `templates-netvm-empty` | 2026-08-31 | the same assertion pointed at `win10-app`, which legitimately HAS `netvm=fw-net` | `mgmt/harness/failproof-config.sh`: templates → True, AppVM → False. **No netvm was ever attached to a template** to manufacture this — that is banned |
| `autologon-guard-shape` / `scan-task-shape` / `latch-task-registered` | 2026-08-31 | the same query against a task name that was never registered | real task → True (boot trigger, SYSTEM); `QubesTaskThatWasNeverRegistered` → False |
| `applier-script-present` | 2026-08-31 | `Test-Path` against a path that does not exist | shipped `bin\pvnic-boot.ps1` → True; absent path → False. (The first attempt failed on the POSITIVE side — I had guessed the wrong directory) |
| `no-loopback-masquerade` | 2026-08-31 | the same predicate over an adapter list that DOES contain a loopback | live adapters → True; synthetic list with `Microsoft KM-TEST Loopback Adapter` → False |
| `no-auto-update-policy` | 2026-08-31 | `NoAutoUpdate=0` | same assertion as `updates_dom0_owned`; battery red, restored green, reproduced 3x |
| `set-resolution-fails-loudly` | 2026-08-31 | asked for `1234x567`, a mode the adapter does not offer | `ok:false, error:"requested mode is not in the adapter's list"` with the offered list printed — the exact defect it was written for (the old version printed a success banner while doing nothing) |
| `exclude-wu-drivers` | 2026-08-31 | `ExcludeWUDriversInQualityUpdate=0` | → False; restored to 1 and verified |
| `run-download-no-triggers` | 2026-08-31 | the same assertion on `QubesWindowsUpdateScan`, which legitimately has triggers | Run/Download `triggers=0 scheduled=False`; Scan `triggers=2 scheduled=True` → False |
| `branch-clean-install` | 2026-08-31 | BOTH directions | strip the marker from a log with `installed_qwt: []` → red; ADD the marker to an upgrade log with `v4.2.2.0` → red. The invariant is empty-entry ⇔ marker-present |
| `distinct-run-ids` | 2026-08-31 | a PRECONDITION replayed under an existing `run_id` | → red |
| `inbox-disk-rearm-done` | 2026-08-31 | `inbox_disk_rearm` flipped `done` → `skipped` | → red |
| `no-restart-during-msiexec` | 2026-08-31 | an Event-1074 restart injected into the install window | → red |
| `entry-is-previous-release` / `entry-is-stock-422` / `entry-carries-N` | 2026-08-31 | the version assertion pointed at a version never shipped | two-sided across REAL logs with NOTHING planted: C3 v4.3.14.0, C4 v4.2.2.0, C6 v4.3.16.0 each pass their own and fail a bogus one |
| `deployed-stack-hashes` | 2026-08-31 | one deployed copy mutated | `tools/tests/failproof-misc.sh`: 5 real shipped scripts vs deployed copies → 0 mismatches; mutate one → exactly 1, naming the drifted file. Runs the same comparison the check performs, on the real artefacts |
| `idd_device_bound` / `desktop_on_idd` / `boot_events_clean` | 2026-08-31 | the `ROOT\DISPLAY` indirect display device disabled | `failed=[idd_device_bound, desktop_on_idd, pnp_no_unexpected_errors, agent_log_healthy, boot_events_clean]`; re-enabled -> `status=OK`, `IddSampleDriver Device 5120x1440`, battery green after a reboot. **`idd_modes_published` did NOT go red** in that run and remains owed |
| `NET-7 applier present` | 2026-08-29 | a guest with no applier (pre-`cace671` package) — the PnP problem-14 state | FINDINGS 2026-08-29 |

## Predicate validated, DEPLOYED CHECK NOT — these do NOT count (added 2026-08-31)

A test that re-implements a check's predicate with literal values shows the *logic* distinguishes
good from bad. It does **not** show the shipped instrument does, which is what H5 asks. Keeping this
tier separate is the difference between measuring the product and measuring my own re-write of it.

| check | what was validated | what is still owed |
|---|---|---|
| `coldboot-reboot-confirmed` | a timestamp comparison distinguishes advanced from identical | run the real check against a guest that did NOT reboot |
| `emulated-unplugged` | the predicate rejects a list still carrying the emulated NIC | run the real check on a guest where the emulated adapter is still present |
| `eligibility-never-had-vif` | the predicate rejects non-zero device/ghost counts | run the real check on a guest that HAS seen a vif |

## Partially proven — cite as PASS-UNPROVEN until completed

| check id | status |
|---|---|
| `upgrade_mode` assertion | partially validated 2026-08-11 (wrong package fed). Not a full two-sided control. |

## Owed — these checks CANNOT emit plain PASS

Everything not listed above. Explicitly including, because they were exercised in this campaign and
their results are reported as `PASS-UNPROVEN`:

- `pv_disk_bound`, `pv_console_bound`, `idd_device_bound`, `desktop_on_idd`, `idd_modes_published`,
  `user_data_on_private`, `pnp_no_unexpected_errors`, `boot_events_clean`, `updates_dom0_owned`
  (the `health-check.ps1` battery — no defect-present run on record for any of them)
- `REINSTALL=ALL on the msiexec line`, `no-pv-gate-refusal`, `inbox_disk_rearm:done`,
  `one-precondition-no-mid-reboot`
- `zero-reboots` (LastBootUpTime unchanged), `emulated-unplugged`, `transfer-crossed-pv-nic`,
  `one-boot-per-command`
- `autologon-armed`, `autologoncount-absent`, `no-plaintext-password`, `reassert-task-registered`
  — **RESOLVED 2026-08-31**: SG6's fail-proof is EARNED (see the table above). The shipped selftest
  still cannot construct its negative, but `mgmt/harness/sg6-failproof.sh` does, by disarming
  `AutoAdminLogon` and the guard task and cold-booting. These five checks now emit plain `PASS`.
- `SG1` Mode-1 phase gate — the attended diag-build arm (phase test removed + captioned fullscreen
  window pre-explorer) has not been run
- `SG7` toasts-survive-filter — positive is owner-observed; the naive-cloak-filter diag build is owed
- `clean install path` marker, `branch matches the cell's claim` — the branch-vs-claim comparison is
  new in this campaign and has no defect-present run
- `BENCH-1 scroll` — stability was established (3 runs, one unchanged build) but no seen-to-fail

## Retractions

None yet. Per H5, a wrong verdict is suffixed `RETRACTED:<reason>` in place, never deleted.
