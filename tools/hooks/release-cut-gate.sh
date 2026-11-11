#!/bin/bash
# release-cut-gate.sh - Claude Code PreToolUse hook (matcher: Bash). A RELEASE IS NOT CUT UNTIL THE
# GATE'S COVERAGE OF THAT BUILD INCLUDES WHAT ITS DIFF REQUIRES.
#
# The owner replaced "full acceptance before every release" with a change-scoped gate on 2026-10-07
# (docs/ADR-acceptance.md). Scoping is only safe while something refuses a cut that skipped a
# required suite - and in this project the rules that got walked past were the ones written down,
# which is why the serial-rig gate, the lint rules and the claim-receipt gate exist as code. This is
# the same shape, at the one moment that matters: the cut.
#
# WHAT TRIPS IT: a command that CUTS - `tools/cut-release.sh --run <id>` (the sanctioned cut), a
# `git tag` of a v-name, `gh release create`, or a push of a v-tag. Nothing else. Reading, building,
# running the acceptance and pushing branches all pass.
#
# WHAT SATISFIES IT: the cut NAMES A BUILD. Owner, 2026-11-11: «we are not accepting "head", we accept
# a precise build». The run id in `--run <id>` resolves - OFFLINE, from the local tags' annotations -
# to the build tag `build-<version>.<run number>` the acceptance created before its first suite
# (tools/build-tag.sh, docs/ADR-acceptance.md section 7). The receipt is scratchpad/gate-coverage-<that
# tag>.json; `tools/gate-scope.py check` must exit 0 for it over <the release tag before the build
# commit>..<the build commit>, and tools/ci-state.py must be green for the BUILD commit. Until this
# date all three read HEAD - the harness checkout, which a documentation commit moves - so the receipt
# a multi-hour run had written was invisible to the cut one commit later. A hand-typed cut names no
# build and is refused with the sanctioned command. The gate runs the checks itself, so a stale or
# hand-written receipt that does not actually satisfy the requirement is refused like any other.
#
# stdin: the hook JSON. exit 0 = allow, 2 = block (stderr goes back to the model).
set -u
cd "${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}" || exit 0
input=$(cat)   # drain first, always: exiting early leaves the writer with a closed pipe

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
    # The sanctioned cut: the script INVOKED with --run. A command that merely names the file (a grep, a
    # bash -n, a diff) is a read and passes - measured on this hook's first minute, when it refused
    # `grep ... tools/cut-release.sh`.
    (re.compile(r'\bcut-release\.sh\b[^|;&\n]*\s--run[=\s]'), 'tools/cut-release.sh --run'),
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


def block(msg):
    print(msg, file=sys.stderr)
    sys.exit(2)


# THE IDENTITY IS THE BUILD, NEVER HEAD. The cut names the release-package run that built the package.
m = re.search(r'--run[=\s]+(\d+)\b', cmd)
if not m:
    block(f"""BLOCKED by tools/hooks/release-cut-gate.sh: this cut names no build.
  A release is cut from a PRECISE BUILD, never from HEAD (owner 2026-11-11: «we are not accepting "head",
  we accept a precise build»; docs/ADR-acceptance.md section 7). The sanctioned cut names the
  release-package run that built the package:
      tools/cut-release.sh --run <release-package-run-id>
  This hook then resolves its build tag (tools/build-tag.sh resolve <id>), reads
  scratchpad/gate-coverage-<build tag>.json, and checks it over <previous release>..<build commit>.
  The command refused was: {why}.""")
run = m.group(1)
p = subprocess.run(['tools/build-tag.sh', 'resolve', run], capture_output=True, text=True)
tag = p.stdout.strip()
if p.returncode != 0 or not tag:
    block(f"""BLOCKED by tools/hooks/release-cut-gate.sh: no build tag names release-package run {run}.
{(p.stderr or p.stdout).strip()}
  The acceptance creates the tag before its first suite (tools/build-tag.sh create {run}) and names every
  receipt by it, so a run with no tag has no acceptance on record. Run the committed gate:
      BUILD=<tag> FI=<fault-injection run> mgmt/harness/campaign-full.sh
  The command refused was: {why}.""")
build = git('rev-parse', '--verify', '--quiet', f'refs/tags/{tag}^{{commit}}')
if not build:
    block(f"BLOCKED by tools/hooks/release-cut-gate.sh: tag {tag} does not resolve to a commit here. The command refused was: {why}.")
# The range: the newest release tag that is an ancestor of the BUILD commit, to the build commit - the
# PACKAGE's diff, the same range tools/cut-release.sh and the acceptance compute. With no such tag the
# whole history is the diff, which maps to the full set - the right answer for a first release.
base = git('describe', '--tags', '--abbrev=0', '--match', 'v[0-9]*', f'{build}^') or git('rev-list', '--max-parents=0', build)
rng = f'{base}..{build}'
receipt = Path('scratchpad') / f'gate-coverage-{tag}.json'

if not receipt.exists():
    block(f"""BLOCKED by tools/hooks/release-cut-gate.sh: no gate-coverage receipt for {tag} (run {run}, built from {build[:12]}).
  A release is cut only when the gate's coverage of that build includes what its diff requires
  (docs/ADR-acceptance.md; the owner replaced 'full acceptance every time' with this on 2026-10-07).
  What is required, and why, for {rng}:
      tools/gate-scope.py required {rng}
  The acceptance writes {receipt} as it runs (tools/coverage-receipt.py, a verdict per module); to record
  a run made another way, go through that tool with --build {tag} and --module <suite>=<class> words,
  naming only suites that ACTUALLY ran, then:
      tools/gate-scope.py check {receipt} {rng}
  The command refused was: {why}.""")

p = subprocess.run([sys.executable, 'tools/gate-scope.py', 'check', str(receipt), rng],
                   capture_output=True, text=True)
if p.returncode != 0:
    block(f"""BLOCKED by tools/hooks/release-cut-gate.sh: the gate's coverage of {tag} does not satisfy its diff.
{p.stdout.strip()}
{p.stderr.strip()}
  Run the suites named above and record them in {receipt}, or run the full gate.
  The command refused was: {why}.""")

# AND CI MUST BE GREEN FOR THE BUILD COMMIT. Added 2026-10-11, after build.yml had been red for 14 runs
# and ~15 h while every receipt and status cited a release-package run's conclusion. Coverage says the
# right SUITES ran on a guest; it says nothing about whether the code compiles and the offline
# batteries pass. Nothing else in the cut path asked.
c = subprocess.run([sys.executable, 'tools/ci-state.py', build], capture_output=True, text=True)
if c.returncode != 0:
    block(f"""BLOCKED by tools/hooks/release-cut-gate.sh: CI is not green for the build commit {build[:12]} ({tag}).
{c.stdout.strip()}
{c.stderr.strip()}
  rc 1 = a required workflow is RED or has no run where one was due; rc 2 = one is unfinished or gh
  could not be read, which is 'no verdict', never a pass. One workflow's conclusion is not the sha's:
  on 2026-10-11 release-package was green while build.yml had been red for 14 runs (CIREDUNREAD).
      tools/ci-state.py {build[:12]}
  The command refused was: {why}.""")
sys.exit(0)
PY
rc=$?
exit $rc
