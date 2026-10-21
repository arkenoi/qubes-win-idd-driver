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
- If no golden exists (win10-base / win11r-base / win11r-qwt / win11de-qwt missing or seals fail), follow docs/PROCEDURE-recreate-goldens.md exactly. A Jev state with recreate_goldens satisfies the gate for that sequence. (This named win11-base and win11-qwt until 2026-10-21. Both were retired deliberately - win11-base's seal deleted with five others in d5781e55 because the image was gone, win11-qwt in b1fb0cea as the eval-based 4.3.17 golden replaced by retail win11r-qwt - and win10-qwt never had a seal record at all. Read literally, the old list made today's rig fail this test and sent the heavy recreate procedure at a pool that is intact.)
- **Never invent evidence.** A claim about a snapshot, revision, seal, or pre-damage state is false unless the exact command output that shows it is in the turn. During any install/boot >5 min, take `tools/qtest shot` at least every 15 min. Zero screenshots on a long run fails the procedure.
- **A golden is CLONED, never STARTED**, and a re-seal that abandons a state you can no longer reach must say why. Both are enforced, not prose: `tools/hooks/golden-boot-gate.sh` refuses to start a sealed golden (`GOLDEN_UNSEAL=<vm>` authorises one guest deliberately), and `golden.sh seal` refuses to overwrite a seal whose revisions are already gone (`GOLDEN_RESEAL_REASON=...` records the decision). `revisions_to_keep` is 2, so the recovery window is TWO shutdowns wide - that is how win10-base was lost on 2026-10-11. Self-test: `tools/tests/golden-guard-selftest.sh`.
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
- **Check the clock before asking.** Between 01:00 and 06:00 local, do not ask a scope question - pick the option that keeps working, state the assumption, and leave the question for the morning. A lengthy task is a reason to START. Enforced by the same hook.
- Do not stop to report. End a turn when the goal is met or a real external blocker is hit.
- Escalate to owner only for: dom0/sudo/policy, upstream contact, acceptance stuck after ~3 iterations, guest reinstall, or isolation-weakening tradeoff.

## Capabilities decided at start
Latched once at Init. A working component that stops is a failure, not a capability change.

## Fullscreen modes (never conflate)
- Mode 1 (boot/logon/shutdown): unconditionally off.
- Mode 2 (borderless app): only with service.gui-fullscreen 1.

See .claude/skills/ for procedures. See findings/rules.md for incident history.
