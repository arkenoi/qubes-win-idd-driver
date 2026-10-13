---
name: acceptance
description: How a release is accepted now - the generated plan is executed, every non-PASS exit becomes a failure package, every error goes to Jev, and an expensive model is invoked only for what Jev could not classify. Load this with docs/PLAN-acceptance-optimization.md before running or analysing any acceptance; nothing else is needed unless the plan says "consult protocol Part II".
---

# Acceptance — three tiers, one plan, no invented procedure

Binding. The plan is `docs/PLAN-acceptance-optimization.md`; the rules are CLAUDE.md. This skill is the
executable shape. Load ONLY this and the plan. `docs/ACCEPTANCE-PROTOCOL.md` Part II (Reference, from
"# Part II") is consulted only when the plan says so.

## The loop

| step | command | you do |
|---|---|---|
| 1 plan | `tools/acceptance-plan.py --range <base>..<head> --package-run <id> [--fi-run <id>] --vm10 --vm11 --os11 --g10 --g11 --b10 --b11 --f11 --out acceptance-plan.json` | read `ready`; a `blocked` entry is a missing TARGET, never a reason to default one |
| 2 probe | each cell's `cheapest_probes` | run them first; a failing probe is an instrument fact knowable at minute 0 |
| 3 execute | each cell's `command`, in `order`, under `mgmt/harness/vmlock.sh` | verbatim; never a cell the plan did not list; `matrix.sh`/`prime-run.sh` outside the plan are refused by `tools/hooks/committed-procedure-gate.sh` |
| 4 collect | on ANY non-PASS exit: `mgmt/harness/collect-failure.sh <vm> <outdir> "<reason>" --since <start> --logvol <image>\|none --harness-cmd "<command>"` | the run is COLLECTED only when `manifest.json` exists; `complete=false` lists the gaps - say them |
| 5 judge | `tools/verdict-jev.py --sweep <report.json>... --snapshot <outdir>/activity-snapshot.json --errors <FAIL lines> [--declare-error <re> <why>]` | exit 0 done; 1 analyse the items it names; 2 the instrument did not run (never a pass); 3 a declaration matched nothing (the run fails) |
| 6 receipt | written by `tools/release-acceptance.sh` through `tools/coverage-receipt.py` | `suites` = ran and measured; `instrument_fail` is UNCOVERED and the cut is refused; `product_fail` is covered and the acceptance RECORD refuses the cut |

## Three tiers of analysis

**Routine — pure code, never a model.** Hashes, signatures, exit codes, counts, timestamp joins, which
suite ran, which cell is INVALID-* (instrument) and which named the product. `tools/log-sweep.py`,
`tools/coverage-receipt.py`, `tools/activity-snapshot.py`, `record-acceptance.sh`. If a step here is done by
reading and summarising, it is being done wrong (jev-classifier skill: forbid-when-computable).

**Semantic — Jev, on the full set.** `tools/verdict-jev.py` sends EVERY breach, NEW/ROSE/out-of-context
item, every E/W signature whatever the baseline says, every harness error line, plus the activity snapshot,
under one fixed rubric: per item known-class / novel / insufficient-evidence against the catalogue
(`findings/issues.md` tags + the sweep baseline's known defects — hints, never filters), and one overall
"any item needs further analysis?". The sole exemption is `--declare-error` naming the stimulus; a
declaration that matches nothing fails the run. Low confidence is a finding: a known-class under the floor
(0.6) needs analysis. The wire log is the receipt; quote verdicts as `jev.py` prints them.

**Complex — the expensive model, with Jev's state attached.** Only when verdict-jev exits 1: a multi-boot
causal chain, a security-model question, a novel class. Start from `verdict.json` (`items_needing_analysis`),
the package's `activity-snapshot.json` and the sweep reports — never from a re-read of the guest. Name the
mechanism, the measurement that would disprove it, and record the class in `findings/issues.md` so the next
run's catalogue has it. A model never re-does a routine or semantic step.

## The failure package (section 4) — what "collected" means

`collect-failure.sh` reads the SECONDARY VOLUME FIRST on the host with mtools (`mgmt/harness/logvol-lib.sh`
`logvol_pull` + `logvol_salvage`), asking nothing of the guest and detaching nothing — a wedged specimen is
read WHILE WEDGED and left alive. Then one bounded liveness probe: alive → `log-sweep.sh` + one per-window
capture (`w_screen`); unresponsive → `wedge_classify`, SPIN/BLOCKED → `fetch-wedge-core.sh` (a space refusal
is an instrument-fail gap and THE SPECIMEN STAYS ALIVE); Halted → the volume's copy analysed OFFLINE by the
same analyzer. `activity-snapshot.json` carries the six fields (per-module tails, last qrexec pair, last
window/focus, clock skew, power timeline, exact harness command); a missing field is a gap, never blank
success. Tarball verified, THEN `manifest.json`. Exit 0 complete / 1 gaps named / 2 not collected.

## The secondary log volume (section 3) — the wedge instrument

Owner 2026-10-13: its purpose is to catch WEDGES and find where vchan load must be eased, so the LAST lines
before a hang are the whole point. `logvol-lib.sh`: FAT image on a loop in this qube, `--required` at
xvdj read-only=false, a second removable usb-storage device on the existing xhci controller (compose, never
overwrite `qemu-extra-args`), `cache=writethrough`; the guest binder sets root `LogDir` → the volume and
`LogSafeFlush=1` (FILE_FLAG_WRITE_THROUGH at every module's next LogInit) and copies the old directory across.
What survives a wedge and what does not is in the library header — do not claim more. No harness attaches
one yet (section 8 step 2): call the collector with `--logvol none` and the package records the gap.
`mgmt/harness/logvol-winpe-copy.cmd` is the (nice-to-have) WinPE copier: synchronous, never non-zero.

## Instrument vs product (section 6)

A suite that could not measure (INVALID-*, exit 2, sweep DATA/INCOMPLETE, core refused, volume missing) is
INSTRUMENT: uncovered, reported on its own channel, never a product regression, and the gate refuses the cut
until it is re-run. A FAIL line that names the product is PRODUCT: covered, result fail, the record refuses the
cut. `verdict-lib.sh`'s three classes are the vocabulary; a check never seen to fail with its defect present
is decoration (every tool here has `# GUARD:<knob> DEFECT:` lines and a self-test under `tools/tests/`).

## Never

- choose a cell, a subject, a golden or a procedure the plan did not name; a default target does not exist;
- read "no windows", "no answer" or an empty tar as a verdict - classify, capture, then say which exit fired;
- treat Jev exit 2, a DATA sweep or a missing manifest as a pass, or summarise a log a script could parse;
- start, stop, kill or detach a specimen to make collection easier; a wedge is evidence;
- put a capture or raw run output on a tracked path (packages go to `scratchpad/` or an evidence dir).
