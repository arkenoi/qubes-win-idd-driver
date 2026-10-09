#!/bin/bash
# release-cut-gate.sh - Claude Code PreToolUse hook (matcher: Bash). A RELEASE IS NOT CUT UNTIL THE
# GATE'S COVERAGE INCLUDES WHAT THE DIFF REQUIRES.
#
# The owner replaced "full acceptance before every release" with a change-scoped gate on 2026-10-07
# (docs/ADR-acceptance.md). Scoping is only safe while something refuses a cut that skipped a
# required suite - and in this project the rules that got walked past were the ones written down,
# which is why the serial-rig gate, the lint rules and the claim-receipt gate exist as code. This is
# the same shape, at the one moment that matters: the tag or the GitHub release.
#
# WHAT TRIPS IT: a command that CUTS - `git tag` of a v-name, `gh release create`, or a push of a
# v-tag. Nothing else. Reading, building, running the acceptance and pushing branches all pass.
#
# WHAT SATISFIES IT: a receipt for THIS HEAD - scratchpad/gate-coverage-<sha>.json, the coverage file
# the acceptance wrote - for which `tools/gate-scope.py check` exits 0 against the range from the last
# release tag to HEAD. The gate runs that check itself, so a stale or hand-written receipt that does
# not actually satisfy the requirement is refused like any other.
#
# stdin: the hook JSON. exit 0 = allow, 2 = block (stderr goes back to the model).
# Self-test: tools/tests/release-cut-gate-selftest.sh. RELEASE_CUT_GATE_DEFECT=1 re-introduces the
# original state (nothing refuses) and the self-test must then FAIL.
set -u
cd "${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}" || exit 0
input=$(cat)   # drain first, always: exiting early leaves the writer with a closed pipe
if [ "${RELEASE_CUT_GATE_DEFECT:-}" = "1" ]; then exit 0; fi   # GUARD:releasecut

python3 - "$input" <<'PY'
import json, re, subprocess, sys
from pathlib import Path

try:
    hook = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)                      # not our JSON - never block on a parse problem of our own
cmd = (hook.get('tool_input') or {}).get('command') or ''
if not cmd:
    sys.exit(0)

# THE CUT, and only the cut. A v-name is what this project tags (v4.3.35-agent<sha>).
CUT = [
    # `git tag` CREATES only when handed a tagname. The read-only forms (--list/-l, --sort,
    # --contains, --points-at, --merged, -n, --format) were being refused as cuts - measured twice
    # on 2026-10-09, where a read-only listing was blocked because its GLOB contains a release
    # number, and the second time it would have broken a release chain at its gate-scope step.
    # Deletion (-d/--delete) was already excluded for the same reason.
    (re.compile(r'\bgit\s+tag\b'
                r'(?!.*\s(?:-d|--delete|-l|--list|--sort|--contains|--no-contains|--points-at'
                r'|--merged|--no-merged|-n[0-9]*|--format)\b)'
                r'(?=.*\bv[0-9])'), 'git tag of a release name'),
    (re.compile(r'\bgh\s+release\s+create\b'), 'gh release create'),
    (re.compile(r'\bgit\s+push\b.*\bv[0-9][^\s]*\b'), 'a push of a release tag'),
    (re.compile(r'\bgit\s+push\b.*--tags\b'), 'a push of tags'),
]
why = next((w for rx, w in CUT if rx.search(cmd)), None)
if not why:
    sys.exit(0)


def git(*a):
    p = subprocess.run(['git', *a], capture_output=True, text=True)
    return p.stdout.strip() if p.returncode == 0 else ''


head = git('rev-parse', 'HEAD')
if not head:
    sys.exit(0)
# The range: the newest release tag that is an ancestor of HEAD, to HEAD. With no such tag the whole
# history is the diff, which maps to the full set - the right answer for a first release.
base = git('describe', '--tags', '--abbrev=0', '--match', 'v[0-9]*', 'HEAD^') or git('rev-list', '--max-parents=0', 'HEAD')
rng = f'{base}..{head}'
receipt = Path('scratchpad') / f'gate-coverage-{head[:12]}.json'


def block(msg):
    print(msg, file=sys.stderr)
    sys.exit(2)


if not receipt.exists():
    block(f"""BLOCKED by tools/hooks/release-cut-gate.sh: no gate-coverage receipt for this HEAD ({head[:12]}).
  A release is cut only when the gate's coverage includes what this diff requires
  (docs/ADR-acceptance.md; the owner replaced 'full acceptance every time' with this on 2026-10-07).
  What is required, and why, for {rng}:
      tools/gate-scope.py required {rng}
  The acceptance writes {receipt} when it finishes; to record a run made another way, write that file
  as {{"suites": [...], "range": "{rng}"}} naming only suites that ACTUALLY ran, then:
      tools/gate-scope.py check {receipt} {rng}
  The command refused was: {why}.""")

p = subprocess.run([sys.executable, 'tools/gate-scope.py', 'check', str(receipt), rng],
                   capture_output=True, text=True)
if p.returncode != 0:
    block(f"""BLOCKED by tools/hooks/release-cut-gate.sh: the gate's coverage does not satisfy this diff.
{p.stdout.strip()}
{p.stderr.strip()}
  Run the suites named above and record them in {receipt}, or run the full gate.
  The command refused was: {why}.""")
sys.exit(0)
PY
rc=$?
exit $rc
