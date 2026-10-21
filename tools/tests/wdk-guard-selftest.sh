#!/bin/bash
# THE WDK INSTALL MUST BE CONDITIONAL IN EVERY WORKFLOW, NOT IN THE ONE SOMEONE REMEMBERED.
#
# `choco install windowsdriverkit11` reaches chocolatey on every run. On 2026-10-03 it HUNG for 90
# minutes in release-package run 37147382401; a 15-minute timeout bounds that now, but the attempt
# was still made unconditionally in build.yml, release-package.yml, pv-xencons.yml and pv-xenvif.yml
# - four workflows making every build depend on an external service that usually has nothing to do.
#
# qwt-full.yml had the guard all along (`if (-not (Test-Path ...\km\ntifs.h))`, commented
# "Idempotent: choco is a no-op if already present"), which is why this is a sweep and not a fix to
# one file: the correct shape existed in the repo and four copies did not have it. The register
# entry named four sites; there were five. Grepping the one emitter someone remembered is how four
# wrong-tag false negatives happened in a single morning.
#
# The guard can never silently skip a MISSING kit: each site's own `if (-not $vsix) { throw ... }`
# runs after it either way, and this suite asserts that too.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "ok   $1"; }
no(){ FAIL=$((FAIL+1)); echo "FAIL $1"; }

# $1 = a directory holding workflow yml files -> prints "<file>:<line>" per UNGUARDED call
unguarded(){ python3 - "$1" <<'PYWDK'
import glob, os, sys
BACK = 16          # how far above the call a guard may sit
bad = []
for p in sorted(glob.glob(os.path.join(sys.argv[1], "*.yml"))):
    lines = open(p, encoding="utf-8", errors="replace").read().split("\n")
    for i, l in enumerate(lines):
        if "choco install windowsdriverkit11" not in l:
            continue
        if l.lstrip().startswith("#"):
            continue
        window = "\n".join(lines[max(0, i - BACK):i])
        # a guard is an `if (` above it that tests for the kit already being on the image
        guarded = ("if (" in window
                   and ("Test-Path" in window or "$have" in window)
                   and ("Windows Kits" in window or "$kitVsix" in window or "$have" in window))
        if not guarded:
            bad.append("%s:%d" % (os.path.basename(p), i + 1))
print("\n".join(bad))
PYWDK
}

# ---------------------------------------------------------------- the shipped workflows
out=$(unguarded "$ROOT/.github/workflows")
n=$(printf '%s' "$out" | command grep -c . || true)
if [ "${n:-0}" = 0 ]; then
  ok "every choco windowsdriverkit11 call in .github/workflows is behind a presence check"
else
  no "$n unguarded WDK install(s): $(printf '%s' "$out" | tr '\n' ' ')"
fi

# every site that installs it must still ASSERT it afterwards, or a skip could proceed without it
missing=""
for f in "$ROOT"/.github/workflows/*.yml; do
  command grep -qa 'choco install windowsdriverkit11' "$f" || continue
  command grep -qa 'WDK.vsix not found' "$f" || missing="$missing $(basename "$f")"
done
[ -z "$missing" ] && ok "every site that installs the WDK still throws if the kit is absent" \
                  || no "no post-install assertion in:$missing"

# the count is reported, so a site added later without a guard is visible rather than averaged away
sites=$(command grep -rla 'choco install windowsdriverkit11' "$ROOT/.github/workflows" | wc -l)
echo "note $sites workflow(s) install the WDK; the register entry named 4, qwt-full.yml made 5"

# ---------------------------------------------------------------- NEGATIVE CONTROL
# Strip the guard from a copy and the sweep must fire. A check never seen to fail is not evidence.
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/wf"
cp "$ROOT"/.github/workflows/build.yml "$T/wf/build.yml"
python3 - "$T/wf/build.yml" <<'PYCTL'
import re, sys
p = sys.argv[1]
t = open(p, encoding="utf-8").read()
# put back the pre-fix shape: a bare call with no presence check
t = re.sub(r'          # THE WDK MAY ALREADY BE ON THE RUNNER IMAGE.*?\n          \}\n',
           '          choco install windowsdriverkit11 --no-progress -y\n', t, flags=re.S)
open(p, "w", encoding="utf-8").write(t)
PYCTL
cout=$(unguarded "$T/wf")
cn=$(printf '%s' "$cout" | command grep -c . || true)
[ "${cn:-0}" -ge 1 ] && ok "negative control: the pre-fix shape IS reported unguarded ($cout)" \
                     || no "negative control did not reproduce - the sweep cannot see an unguarded call"

# and a guarded call must NOT be reported, or the sweep would fire on everything
mkdir -p "$T/ok"
cat > "$T/ok/x.yml" <<'YML'
jobs:
  j:
    steps:
      - run: |
          if (-not (Test-Path "${env:ProgramFiles(x86)}\Windows Kits\10\Include\*\km\ntifs.h")) {
            choco install windowsdriverkit11 --no-progress -y
          }
YML
gout=$(unguarded "$T/ok")
[ -z "$gout" ] && ok "a guarded call is not reported (no false positive)" \
               || no "the sweep fires on a correctly guarded call: $gout"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
