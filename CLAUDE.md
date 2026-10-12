# CLAUDE.md — Binding rules only

Rules. Reasons live in findings/rules.md. Procedures live in .claude/skills/. Measured state lives in findings/*.md CURRENT STATE heads.

## Mission
Improve Windows-guest desktop fidelity and responsiveness in QWT seamless mode. Zero security-model changes.
- Track A: agent/ (window tracking, capture, wgcbroker)
- Track B: driver/ (QubesIDD IddCx)
- Track C: dom0-owned Windows update path (guest/ scripts). Auto-update OFF. Dom0 drives every install.

## Rig (binding)
- Control every qube tagged win-idd-testbed. Create + tag immediately. Pre-authorised: qvm-prefs/tags/firewall/volume, power, qtest.
- Off-limits: dom0 shell, sudo, qrexec policy edits, untagged qubes.
- **Never invent a procedure.** Short cycle = mgmt/harness/quick-upgrade.sh over golden (or clone-guest.sh for GWeck). Heavier paths (prime-run, reprovision, full matrix) require a recent Jev call whose state quotes the exact command + the rejected short-cycle alternative. Enforced by tools/hooks/committed-procedure-gate.sh.
- If no golden exists (win10-base / win11-base / win10-qwt / win11-qwt missing or seals fail), follow docs/PROCEDURE-recreate-goldens.md exactly. A Jev state with recreate_goldens satisfies the gate for that sequence.
- **Never invent evidence.** A claim about a snapshot, revision, seal, or pre-damage state is false unless the exact command output that shows it is in the turn. During any install/boot >5 min, take `tools/qtest shot` at least every 15 min. Zero screenshots on a long run fails the procedure.
- Before any install/boot/reboot job: read .claude/skills/rig-cycle/SKILL.md.
- VM-mutating jobs are serial (mgmt/harness/vmlock.sh).
- Never write a limitation until you have grepped the repo and run the cheapest disproving probe. See .claude/skills/rig-capabilities/SKILL.md.

## Networking (binding)
- Templates stay netvm=''. AppVMs/StandaloneVMs that test PV networking get a netvm.
- Second boot is a failure for PV-network acceptance.

## Public repo
- Captures, evidence, raw benchmarks → scratchpad/ or private memory. Never tracked. Never git add -A. .githooks enforces.

## Working rules (binding)
- Operator intervention is Jev-bound (tools/hooks/ask-operator-gate.sh). Ask Jev whether to interrupt; act on the verdict.
- Do not stop to report. End a turn when the goal is met or a real external blocker is hit.
- Escalate to owner only for: dom0/sudo/policy, upstream contact, acceptance stuck after ~3 iterations, guest reinstall, or isolation-weakening tradeoff.

## Capabilities decided at start
Latched once at Init. A working component that stops is a failure, not a capability change.

## Fullscreen modes (never conflate)
- Mode 1 (boot/logon/shutdown): unconditionally off.
- Mode 2 (borderless app): only with service.gui-fullscreen 1.

See .claude/skills/ for procedures. See findings/rules.md for incident history.
