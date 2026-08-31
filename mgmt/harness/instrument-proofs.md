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
| `monitor-redisabled-after-msi` | 2026-08-31 | every `[after msiexec` monitor line stripped | -> red. The MSI re-registers xenbus_monitor, so disarming it once before the install is not enough |
| `stock-pv-boot-disk` | 2026-08-31 | `pv_boot_disk` flipped to false on a log whose entry state shows a prior QWT | -> red. Self-consistency invariant (true IFF a prior QWT was installed), so the real C1/C3/C4/C6 logs are each other's negative |
| `no-failure-marker` | 2026-08-31 | a `QubesPvNic-FAILED.txt` line injected | -> red |
| `idd_modes_published` | 2026-08-31 | the `HKLM\SOFTWARE\QubesIDD` `Modes` value removed | -> `failed=[idd_modes_published]`; restored to `5120x1440,1024x768` -> green. Disabling the IDD DEVICE does NOT turn it red - it reads the registry value the agent writes, not the device, which is why the device plant left it green |
| `offline-baseline` | 2026-08-31 | a winhttp proxy set to 127.0.0.1:9999 | `netsh winhttp show proxy` flips from `Direct access (no proxy server)` to `Proxy Server(s)`; reset restores it |
| `standalone-skipped` / `standalone-no-relay` / `template-arm` | 2026-08-31 | the SAME shipped script run on the other VM class | StandaloneVM: 'the qubes proxy updater is template-only ... Doing nothing', RELAY=0; TemplateVM: full path, scan offers 1 update, relay listening |
| `user-data-on-private` | 2026-08-31 | the same predicate on `C:\Windows`, which legitimately is not a reparse point | `C:\Users` -> ReparsePoint True, Target `Q:\Users`; `C:\Windows` -> False. No mutation |
| `armed-monitor-precondition` | 2026-08-31 | the SHIPPING state is the negative | xenbus_monitor `Stopped/Disabled` -> armed to `Running/Auto` -> restored to `Stopped/Disabled`, all verified |
| `pv-nic-bound-live` / `eligibility-never-had-vif` / `stimulus-existed` | 2026-08-31 | the same queries on `win10-p46`, which has `netvm=''` | `win10-app` (netvm=fw-net): XENVIF device err=0 svc=xennet, ENUM True, 1 PV adapter Up, IP 10.137.0.64. Control: 0 devices, ENUM False, 0 adapters. *stimulus-existed measured ACROSS TWO GUESTS, not across an attach* |
| `transfer-crossed-pv-nic` / `fw-net-confirmed` | 2026-08-31 | the same fetch through 127.0.0.1:8082, where no relay runs on an AppVM | direct fetch: DNS resolved, 80,736 bytes, PV adapter ReceivedBytes +102,881. Proxy attempt: 'Unable to connect', RX_DELTA 0. Asserted by TRANSFER, never by ping - a Qubes netvm does not answer ICMP |
| `ensure-proxy-phase` / `scan-phase` / `available-populated` / `updates-available-to-dom0` / `backend-egress-proven` / `sync-revocation-3of3` | 2026-08-31 | `-RelayExe` pointed at a path that does not exist - NOTHING mutated on the guest | negative: *'ERROR: relay not found'*, then *'proxy removed, relay stopped (offline baseline restored)'* - no scan, no offer, no dom0 report, standing tinyproxy log **+0**. Positive, same guest minutes later: Sync-Revocation 3/3, `scan: 1 update(s) offered`, `reported 1 update(s) to dom0 ... (exit 0)`, tinyproxy **+31** |
| `coldboot-classification` / `qdbdaemon-race-fix-exercised` | 2026-08-31 | the boot pass suppressed by the 30-min scan debounce, on the SAME TemplateVM | red: `class_lines:0, class_correct:false, qdb_retry_evidence:false, new_log_bytes:0`; green after clearing it: `class_lines:1, classes_seen:'TemplateVM', class_correct:true, qdb_retry_evidence:true, new_log_bytes:322`. Two proven cold boots |
| `appvm-skipped` / `appvm-proxy-unchanged` | 2026-08-31 | the same script on a TemplateVM, which does NOT skip | AppVM: *'not a template; updates are the template's business. Exiting before any proxy activity.'*, RELAY_AFTER 0, ProxyEnable absent |
| `vacuity-stimulus-existed` | 2026-08-31 | chromerepro not running | shipped `guest/enumwin.ps1` reports `CHROMEREPRO_HWNDS 0`; with it running, `5` |
| `cold-boot-session` | 2026-08-31 | the samples taken while the guest was still booting | liveness probe FALSE during boot, TRUE once qrexec came up, on a boot proven by LastBootUpTime advancing |
| `zero-reboots` / `zero-reboots-standalone` / `one-boot-per-command` / `coldboot-reboot-confirmed` | 2026-08-31 | a real non-rebooting operation on a live StandaloneVM | LastBootUpTime byte-identical (`04:45:43.7192010` twice); across ONE real reboot it advances to `04:47:02.8275610` and is stable on re-read. Both directions measured on the guest, not simulated |
| `stage-redetected` | 2026-08-31 | every `testsigning_active` flipped true in a two-stage log | -> red. Scoped to genuine two-stage runs (the 1-stage path starts with testsigning on, so requiring the transition there failed 7 of 10 good logs) |
| `no-intermediate-reboot` | 2026-08-31 | an `uninstalling ...` line added to an upgrade log that claims no uninstall | -> red |
| `veto-key-seeded-not-a-vif` | 2026-08-31 | `win10-app`, where XENVIF is NOT empty | shipped `guest/pvnic-latch-readback.ps1`: `win10-p46` (netvm='') has `vif_enum_key=True` with `XENVIF_DEVICES=0` - the veto key seeded while genuinely not a vif; `win10-app` has `XENVIF_DEVICES=1`, so the 'enum empty' half is false there |
| `three-boot-soak` | 2026-08-31 | `win10-p46` (netvm=''), where the same query finds 0 adapters and no IP | three REAL cold boots of win10-app with distinct LastBootUpTimes (04:52:36 / 04:55:05 / 04:57:40), all `pv_up=1 emulated_left=0 ip=10.137.0.64 apipa=0` |
| `relay-transport-clean` | 2026-08-31 | a truncated response — using the relay's OWN shipped self-test | `qubes-updates-relay.exe --selftest` on win11-tpl: `PASS short: reported incomplete`, `PASS chunked: truncated reads incomplete`, `PASS GET: headers-only still reads INCOMPLETE`, alongside `PASS large: reported complete`. 13/13 assertions. The fail-proof was already in the product — it only needed running |
| `borderless-fullscreen-gated` (SG2) | 2026-08-31 | **DIAG BUILD** — the Mode-2 `return FALSE` disabled (`diag/sg2-mode2-gate-removed`) | the cell FLIPPED under one harness: release `sha 20cab4c5` -> mapped=no, PASS; diag `sha c507ed21` -> the same 1024x768 borderless probe mapped=YES in 6/6 samples, FAIL 'the gate leaked'. SG4/SG3/SG9 unchanged on the diag build, so the effect was specific. Release restored, running image hash verified. PROVENANCE AUDITED after the concurrency incident later the same day: both sides are single-instance — the red run has exactly one banner per cell, and the green run's directory holds three runs 30 min apart with no overlap, the surviving rows being the last one's. Neither carries the doubled-banner signature. D-9 CLOSED: after restoring the release binary, a clean single-instance P5 re-run scored SG2 `mapped=no` with the deny logged at the same 1024x768 — so the restore is proven twice over, by hash and by re-measurement |
| `vmlock` (the concurrency control itself) | 2026-08-31 | started a second `p5-run.sh` against a guest already under test | it printed `REFUSING TO START`, named the holder (`pid=3955579 cmd=p5-run.sh`), created no output directory, and did NOT disturb the run in flight. The control was also seen to be NEEDED: without it, two P5 runs interleaved and fabricated an SG2 FAIL |
| `NET-7 applier present` | 2026-08-29 | a guest with no applier (pre-`cace671` package) — the PnP problem-14 state | FINDINGS 2026-08-29 |

## Predicate validated, DEPLOYED CHECK NOT — these do NOT count (added 2026-08-31)

A test that re-implements a check's predicate with literal values shows the *logic* distinguishes
good from bad. It does **not** show the shipped instrument does, which is what H5 asks. Keeping this
tier separate is the difference between measuring the product and measuring my own re-write of it.

| check | what was validated | what is still owed |
|---|---|---|
| `emulated-unplugged` / `standalone-pvnic-seeded` / `template-pvnic-seeded` | positive REAL; negative **proven unreachable by measurement** | two attempts to unseed `XEN\Unplug NICS=0` and reboot - the second with BOTH latch tasks disabled - came back `NICS=1, EMULATED_LEFT 0` every time. The PV stack re-seeds below the task layer on every boot, so the defect cannot be planted; it would need a guest with the PV drivers removed |
| `appvm-private-reformatted` | positive REAL (Q:\Users present on a 40 GiB private) | the 2 GiB defect state is not creatable here: an AppVM's private follows its template's (20 GiB) and qvm-volume only extends |
| `pv-disk-bound` | positive REAL (`DEV_VBD err=CM_PROB_NONE svc=xenvbd`, nothing on emulated IDE) | negative **proven impossible**: `Disable-PnpDevice` on the VBD left it `OK CM_PROB_NONE` — Windows refuses to disable the boot device. Attempted on the disposable clone so a bugcheck would have cost nothing |
| `standalone-pvnic-seeded` / `template-pvnic-seeded` | positive REAL (nics=1 disks=1, both tasks registered, no failure marker) | every guest on this rig carries the latch, so an unseeded guest does not exist to point the check at |
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

## The 34 build-blocked checks: how to earn them (found 2026-08-31)

They are NOT one homogeneous set, and most do not need a hand-edited branch:

**~12 — the capture/render regression cluster** (`capture-thread-survives-resize`,
`keyed-mutex-recovered`, `pixels-change-after-resize-*`, `mode-followed-*`, `agent-idle-cpu`,
`scroll-p50-vs-canonical`, `metric-stability`, `drag-p50-record-only`). The project **already ships
the toggle**: `agent/gui-agent/faultinject.c`, built in via `QGA_FAULT_INJECTION=1`, exposed as the
`fault_injection` input of `.github/workflows/qwt-full.yml`. Its own header states the reason in
CLAUDE.md's words — *"a check counts as evidence only once it has been seen to FAIL on a build with
the defect deliberately re-introduced … This module is that toggle."* It offers ten registry-selected
faults: `FaultCaptureExit`, `FaultPrintWindowFail`, `FaultNegCreate`, `FaultNegCreateHwnd`,
`FaultDupCreate`, `FaultRawCreate`, `FaultPumpStallSec`, `FaultRingStallSec`, `FaultLegacySend`,
`FaultArmDelaySec`. **One dispatch produces a binary that re-introduces many defects on demand** —
no per-clause branch, no source edit:

    gh workflow run qwt-full.yml -f fault_injection=true

**~20 — the safeguard clauses** (`borderless-fullscreen-gated`, `or-fullscreen-never-mapped`,
`maximized-window-maps`, `toasts-survive-filter`, `shadow-strips-dropped`, `no-fullscreen-during-boot`,
`start-not-presented`, `menu-*`, `secure-desktop-*`, `uac-off-secure-desktop`, …). The injector does
NOT cover these — they need the specific `ShouldAcceptWindow` clause removed, one build per clause.
`diag/sg2-mode2-gate-removed` (agent) + `diag/sg2-failproof` (superproject) are staged for the Mode-2
gate as the worked example.

**Note for whoever picks this up:** the fault injector was found only after hand-editing a diag
branch. Check whether the product already ships the toggle before writing one — the relay's
`--selftest` turned out the same way, carrying the entire `relay-transport-clean` proof.
