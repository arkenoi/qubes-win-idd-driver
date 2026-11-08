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
- Templates are CREATED and MANAGED with netvm='' - provisioning, priming, upgrading and sealing
  keep a route completely out of the path. That is rig hygiene and it is the whole of it: attaching
  a netvm to an EXISTING template later, to test something with it, is not prohibited. Owner
  2026-11-08: «the rig hygiene says that when creating or managing a template, this should be
  completely out of the path, that's it. there is no prohibition to test something with it later»,
  and, on why the product may never depend on one, «it is not approved path for ourselves -- we
  should not rely on its availability». AppVMs/StandaloneVMs that test PV networking get a netvm.
- Second boot is a failure for PV-network acceptance.
- **The netvm is `fw-net`. There is no `sys-net` and no `sys-firewall` on this rig** - never type
  either name, in a command, a plan, or as a throwaway probe argument. Owner 2026-11-08: «you have
  your qubes rules to follow! explicitly told to forget about sys-net and sys-firewall!» `qvm-check
  fw-net` answers `non-existent!` because enumeration is policied - a FILTERED VIEW, not truth, and
  never a licence to substitute a name from stock Qubes. `core-update` is the torified updates proxy
  (owner-designated, `mgmt/10-win-idd-all.policy`); this qube's own tinyproxy on 127.0.0.1:8082
  serves the non-Tor download path. A qube name is a FACT about the rig, to be recalled, not
  guessed: `qvm-prefs <vm> netvm <name>` WRITES TO DOM0 whether the name exists or not. This rule
  lived in three places and two of my own commits removed it (3b07a85c stripped it from
  updates-proxy-bisect as "archeology" while claiming every rule was kept; 8ccbdee7 stripped
  rig-capabilities' superseding text) - it is here because this file is the one always in context.

## Public repo
- Captures, evidence, raw benchmarks → scratchpad/ or private memory. Never tracked. Never git add -A. .githooks enforces.

## Working rules (binding)
- Operator intervention is Jev-bound (tools/hooks/ask-operator-gate.sh). Ask Jev whether to interrupt; act on the verdict.
- **Check the clock before asking.** Between 01:00 and 06:00 local, do not ask a scope question - pick the option that keeps working, state the assumption, and leave the question for the morning. A lengthy task is a reason to START. Enforced by the same hook.
- Do not stop to report. End a turn when the goal is met or a real external blocker is hit.
- **A selftest that fails and needs a quick fix is DELETED, not fixed.** Owner 2026-10-26: «i do not like you writing endless selftests ... if any of those fail and need a "quick fix", DROP THE FUCKING THING COMPLETELY». No new suites. Product defects and the log sweep are the work; a suite is not. Drop it, lower the floor in the same commit, and say what still enforces the property (usually the build throwing on a failed patch apply).
- **P1 means a user can see it.** Severity grades USER IMPACT, never how much a thing blocks me. Our own gates, sweeps, fixtures, selftests, harness classifiers and evidence plumbing are the measuring apparatus and **cannot be P1** (owner 2026-10-30), however urgent - they take P2 or below, keeping their class suffix (`P2 instrument`, `P2 gate`, `P2 rig custody`).
- Escalate to owner only for: dom0/sudo/policy, upstream contact, acceptance stuck after ~3 iterations, guest reinstall, or isolation-weakening tradeoff.

## Capabilities decided at start
Latched once at Init. A working component that stops is a failure, not a capability change.

## Fullscreen modes (never conflate)
- Mode 1 (boot/logon/shutdown): unconditionally off.
- Mode 2 (borderless app): only with service.gui-fullscreen 1.

See .claude/skills/ for procedures. See findings/rules.md for incident history.
