---
name: rig-cycle
description: MANDATORY before starting ANY job that installs, boots or reboots a Windows guest. Picks the right harness (quick-upgrade vs clean install vs full acceptance) and states the standing rig rules. Load this BEFORE writing or launching any guest-touching script - not after it fails.
---

# rig-cycle — pick the cycle before you burn the rig

Read this **before** launching anything that touches a guest. Every rule is short because every rule
is absolute.

## 1. WHICH HARNESS — this is the rule that keeps getting broken

| what you are doing | use | why |
|---|---|---|
| testing a feature, a fix, a script, one behaviour | `mgmt/harness/quick-upgrade.sh` over the `win10-qwt` / `win11-qwt` golden | minutes, not 12+; the guest already has QWT and qrexec |
| RELEASE acceptance, all 6 cell-groups | `mgmt/harness/matrix.sh` (via the campaign runner) | that is what it is for |
| the CLEAN-INSTALL PATH ITSELF is the thing under test (stage-1 transition, first-boot behaviour, install ordering) | clean install from `win{10,11}-base` via `prime-run.sh` | and ONLY then |

**A clean install from base for a short test cycle is a mistake, not a preference.** Owner,
2026-09-06 and again 2026-09-09: *"quick-upgrade over the golden for short test cycles; clean
install from base is FULL acceptance only."*

**A broken upgrade harness is a thing to FIX, not a licence to clean-install.** If quick-upgrade is
failing, that is the bug to work on.

Before you launch, answer in one line: *is the clean-install path the thing under test?* If no, you
are using quick-upgrade.

## 2. SERIAL, ALWAYS

One VM-mutating job at a time. Take the lock: `source mgmt/harness/vmlock.sh; vm_lock <vm>`.
Concurrent installs reboot the guest underneath each other and destroy hours of results.
Wait for `pgrep -f 'acceptance-races|mgmt/harness/matrix.sh|prime-run'` to be clear first.

## 3. PGREP PATTERNS MUST NOT MATCH THEMSELVES

`pgrep -f prime-run` matches your own shell and the monitor tailing your log, so "the rig is busy"
and "it is still running" both lie. Use a bracket class: `pgrep -f "[p]rime-run.sh"`. This has
produced a false BUSY and a false STILL-RUNNING in one session.

## 4. NEVER REUSE A KILLED SUBJECT

`qvm-kill` mid-run CONTAMINATES the guest. Remove it (`qvm-remove -f`) and re-create from the
golden. Never grade a run on a guest that was killed, and never chain a new run onto a killed one.
Stop jobs with SIGTERM to the leader pid so the teardown traps run.

## 5. CLEAN UP BEFORE YOU START, NOT AFTER YOU FAIL

`prime-run` refuses when ANY `win1*` guest is not Halted - including your own leftover. Self-clean up
front: kill + remove your subject, shut down leftovers, then start.

## 6. WHAT COUNTS AS A RESULT

- **Missing data FAILS.** An empty capture, an unreadable stat, an absent marker: fail it. Never let
  absence read as success. A stale artefact from a previous run is not this run's evidence — anchor
  on something that proves freshness.
- **A check that has never been seen to FAIL is not evidence.** Drive it with the defect present
  before you believe a PASS.
- **Judge the guest, not the log.** Pixels and file content over a tool's own report.

## 7. IF YOU ARE ABOUT TO SAY "IT IS PROBABLY FINE"

Stop and measure it instead. That sentence has preceded every entry in this file.
