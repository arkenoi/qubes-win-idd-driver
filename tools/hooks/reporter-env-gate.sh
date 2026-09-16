#!/bin/bash
# reporter-env-gate.sh - Claude Code PreToolUse hook (matcher: Workflow|Agent).
#
# THE RULE, ENFORCED HERE AND NOT IN PROSE: a launch that names a registered field reporter
# (mgmt/reporters/<key>.json) AND drives the rig must gate its guest work on
#   mgmt/harness/env-assert.sh <vm> <key>
# - the script that measures the guest against the reporter's recorded environment and exits
# non-zero on any mismatch. Without that call the launch is refused (exit 2; the message below is
# handed back to the model). Owner, 2026-09-16, after a reproduction ran a day on a 24H2 English
# stand-in for a 25H2 German report: "the prose is typically ignored and there is no structural
# rule to enforce it." This is the structural rule.
#
# Scope is deliberately narrow so it cannot be argued around: a read-only launch that merely
# mentions the reporter (fetch the forum posts, summarise) passes; only text that also touches the
# rig (qvm-*, qtest, prime-run, quick-upgrade, matrix.sh, reprovision-usb, checkpoint.sh, the
# guest services) must carry the assertion.
#
# stdin: the hook JSON ({"tool_name": ..., "tool_input": {...}}). Exit 0 = allow, 2 = block.
# Self-test: tools/tests/reporter-env-gate-selftest.sh. REPORTER_GATE_DEFECT=1 re-introduces the
# original state (nothing enforces) and the self-test must then FAIL.
set -u
cd "${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}" || exit 0
if [ "${REPORTER_GATE_DEFECT:-}" = "1" ]; then exit 0; fi   # GUARD:reporter-gate
input=$(cat)
python3 - "$input" <<'PY'
import glob, json, re, sys
try:
    hook = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)  # not our JSON - never block on a parse problem of our own
ti = hook.get('tool_input') or {}
text = json.dumps(ti, ensure_ascii=False)
rig = re.compile(r'qvm-(create|start|run|prefs|clone|remove|shutdown|kill|volume|features|tags)|qtest\b|prime-run|quick-upgrade|matrix\.sh|reprovision-usb|checkpoint\.sh|release-acceptance|qubes\.WindowsUpdate|qubes\.VMShell|qubes\.VMExec', re.I)
if not rig.search(text):
    sys.exit(0)
for spec_p in sorted(glob.glob('mgmt/reporters/*.json')):
    try:
        spec = json.load(open(spec_p, encoding='utf-8'))
    except Exception:
        continue
    key = spec_p.rsplit('/', 1)[-1][:-5]
    names = [spec.get('reporter', key)] + list(spec.get('aliases', []))
    named = any(re.search(r'(?<![\w])' + re.escape(n) + r'(?![\w])', text, re.I) for n in names if n)
    if not named:
        continue
    if re.search(r'env-assert\.sh\s+\S+\s+' + re.escape(key) + r'(?![\w-])', text):
        continue
    sys.stderr.write(
        f"BLOCKED by tools/hooks/reporter-env-gate.sh: this launch names field reporter '{spec.get('reporter', key)}' "
        f"({spec_p}) and drives the rig, but nowhere calls `mgmt/harness/env-assert.sh <vm> {key}`. "
        f"A reproduction on any other environment is discarded here (owner, 2026-09-16: never assume an environment "
        f"is 'diagnostically similar'). Add that call to every stage that touches a guest, make the stage STOP on its "
        f"non-zero exit, and relaunch. If the environment does not exist on the rig, building it is the first task.\n")
    sys.exit(2)
sys.exit(0)
PY
