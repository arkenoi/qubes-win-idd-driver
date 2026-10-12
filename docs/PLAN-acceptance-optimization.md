# PLAN — acceptance optimization (Claude-loadable)

Load this when implementing or running acceptance changes. Binding rules stay in CLAUDE.md; this is the executable plan.

## Goal
Cut wall-clock time and Claude tokens. Mechanize first. Jev evaluates every error. Expensive model only for novel or insufficient-evidence cases. Logs from any failed or wedged run must be complete and readable without a live guest.

## 1. Single entry point
`tools/acceptance-plan.py` reads `tools/gate-scope.py required` + `mgmt/gate-ledger.json` and writes `acceptance-plan.json`.

Plan lists: exact harness invocations, expected exits, cheapest probes, whether a secondary log volume is required.

Claude executes the plan and feeds results to the verdict wrapper. It never chooses cells or invents procedures.

Unplanned `matrix.sh` / `prime-run.sh` is blocked by `tools/hooks/committed-procedure-gate.sh`.

## 2. Short cycle default
Non-install-path changes: `mgmt/harness/quick-upgrade.sh` over sealed golden + log-sweep.

Clean-install / full-matrix cells appear only when gate-scope or a floor condition demands them.

Reuse goldens and campaign fixtures; fast-verify seal + critical hashes before re-provision.

## 3. Recoverable logs (test runs only)
Harness-driven cells only. Never user guests or sealed goldens.

At cell start: attach small secondary volume (`logvol` or campaign-shared `logs-<id>.img`).

Junction/bind the QWT log directory (`C:\ProgramData\Qubes\logs` or one-log-per-module path) onto that volume.

ADR-logging contract unchanged (one file per module per day, append-only, single WriteFile, pid:tid prefix). Destination moves only for the test.

Campaign manifest records the volume path.

Failure collector prefers the secondary volume (loop-mount or qvm-volume even if guest wedged/Halted/qrexec-dead). Normal path is secondary source.

## 4. Failure package always exists
`mgmt/harness/collect-failure.sh <vm> <outdir> <reason>` on every non-PASS exit.

- Pull secondary log volume first, then `log-sweep.sh`.
- On wedge or unresponsive > N s: `fetch-wedge-core.sh` after reclaim logic. Specimen stays alive until package verifies.
- Write `activity-snapshot.json`: last 20 lines per module log, last qrexec pair, last window/focus, clock skew, power-state timeline, exact harness command.
- Verified tarball + manifest. Run not marked collected until manifest exists.

## 5. Every error is evaluated
No pre-filter by known failure class. Every new/rose/breach signature and every suspicious line is emitted.

Known-class hints optional context only; never suppress an item.

Sole exemption: explicit `--declare-error` (or plan equivalent) that matches and names the stimulus. Declaration matching nothing fails the run.

`tools/verdict-jev.py` receives the complete set + activity snapshot.

Fixed rubric: known-class / novel / insufficient-evidence per item; overall "any item needs further analysis?".

Claude invoked only when Jev returns novel or insufficient-evidence on at least one item.

## 6. Instrument vs product
Coverage receipt: `product-fail` or `instrument-fail`.

Instrument-fail (sweep DATA, core refused after reclaim, secondary volume missing) does not count as product regression. Plan treats suite as uncovered; gate refuses the cut.

## 7. Three-tier analysis
- Routine: hash, signature, exit code → pure code.
- Semantic: known-class or novel? → Jev on the full set.
- Complex: multi-boot causal chain or security-model question Jev cannot classify → expensive model with Jev state attached.

Documented in `.claude/skills/acceptance/SKILL.md`. Claude loads only the plan + this skill unless the plan says "consult protocol Part II".

## 8. Implementation order Claude executes
1. Add `tools/acceptance-plan.py`, `tools/verdict-jev.py`, `mgmt/harness/collect-failure.sh`.
2. Extend harness start-up (matrix.sh, quick-upgrade.sh, prime-run.sh) with secondary-volume attach + junction; record path in manifest.
3. Update `tools/release-acceptance.sh` and coverage receipt for instrument-fail.
4. PreToolUse check: test cell without log-volume entry in the plan is refused.
5. Self-tests: scoped vs full-floor plan; injected known + novel ERROR both reach Jev; deliberately wedged subject yields complete package from secondary volume.

## Expected effect
Most changes: minutes (quick-upgrade + recoverable logs + one Jev call).

Full gate still forced by existing floor (10 releases / 21 days / previous failure / map change / unmapped path).

No error dropped for failing to match a catalogued pattern.

Wedged specimen no longer makes logs unreachable.

Claude token use stays low: executes generated plan, escalates only minority of cases.

All prior safety properties (scoped gate, reverse-dependency closure, committed-procedure enforcement, one-log-per-module, "any error is a defect") remain intact and are backed by recoverable artefacts.
