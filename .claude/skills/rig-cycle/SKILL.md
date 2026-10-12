---
name: rig-cycle
description: MANDATORY before any install/boot/reboot. Pick the harness. Do not invent procedures.
---

# rig-cycle — pick the cycle

Read before launching anything that touches a guest.

## Never invent a procedure
Short cycle = `mgmt/harness/quick-upgrade.sh` over a golden (or `mgmt/clone-guest.sh` for GWeck).
Heavier paths only when the clean-install path itself is under test, or after a recent Jev call that quotes the exact command and the rejected short-cycle alternative.
Enforced by `tools/hooks/committed-procedure-gate.sh`.

## Recreate goldens (exception)
If `win10-base`, `win11-base`, `win10-qwt` and `win11-qwt` are all missing or fail `mgmt/golden.sh verify`, follow `docs/PROCEDURE-recreate-goldens.md` exactly.
There is no short-cycle alternative in that case. A Jev state containing `recreate_goldens` and quoting that procedure satisfies the gate for the heavy steps in the sequence.

## Which harness
| Task | Use |
|------|-----|
| Feature / fix / single behaviour | quick-upgrade.sh over golden |
| GWeck report (German 25H2) | clone-guest.sh win11de-qwt <subject> + env-assert.sh |
| Full release acceptance | matrix.sh |
| Clean-install path under test | prime-run.sh from base |
| Goldens missing | docs/PROCEDURE-recreate-goldens.md |

A broken quick-upgrade is a bug to fix, not a reason to clean-install.
Answer before launch: is the clean-install path the thing under test? If no → quick-upgrade.
If no golden exists → recreate-goldens procedure.

## Serial always
One VM-mutating job. `source mgmt/harness/vmlock.sh; vm_lock <vm>`.

## Never reuse a killed subject
qvm-kill contaminates. Remove and recreate from golden.

## Results
Missing data fails. A check never seen to fail is not evidence. Judge pixels and files, not tool self-reports.
