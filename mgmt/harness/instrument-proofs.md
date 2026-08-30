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
| `NET-7 applier present` | 2026-08-29 | a guest with no applier (pre-`cace671` package) — the PnP problem-14 state | FINDINGS 2026-08-29 |

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
  — **SG6's fail-proof is INCONCLUSIVE**: the selftest builds its negative by deleting a registry
  `DefaultPassword` that our design deliberately never writes, so it skips. Breaking the LSA secret
  instead is the owed fix.
- `SG1` Mode-1 phase gate — the attended diag-build arm (phase test removed + captioned fullscreen
  window pre-explorer) has not been run
- `SG7` toasts-survive-filter — positive is owner-observed; the naive-cloak-filter diag build is owed
- `clean install path` marker, `branch matches the cell's claim` — the branch-vs-claim comparison is
  new in this campaign and has no defect-present run
- `BENCH-1 scroll` — stability was established (3 runs, one unchanged build) but no seen-to-fail

## Retractions

None yet. Per H5, a wrong verdict is suffixed `RETRACTED:<reason>` in place, never deleted.
