#!/usr/bin/env bash
# health-logfresh-selftest.sh - offline proof that agent_log_healthy decides "is this the RUNNING
# agent's log?" from the log's CONTENT (the agent's own pid in every line prefix) and not from the
# file's metadata (tools/tests/health-logfresh-test.ps1 drives the marked region of the shipped
# guest/health-check.ps1). The clean leg must pass; the defect leg must FAIL on its own checks:
#   LOGFRESH_DEFECT=mtime  the metadata logic as it shipped in 4.3.36 - trust LastBootUpTime when
#                          it looks sane, else take the newest file by mtime that has an Init line.
#                          Measured 2026-10-09, it produces BOTH errors at once: it selects the
#                          PREVIOUS boot's file (the false pass that made five gate cells green)
#                          and it claims an instance for an agent that wrote nothing at all.
# Exit 0 only if both legs hold.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PWSH="${PWSH:-/home/user/bin/pwsh7/pwsh}"
[ -x "$PWSH" ] || { echo "FAIL  pwsh not found at $PWSH - nothing ran (missing data fails)"; exit 2; }
S="$ROOT/guest/health-check.ps1"
T="$ROOT/tools/tests/health-logfresh-test.ps1"
for f in "$S" "$T"; do [ -f "$f" ] || { echo "FAIL  $f missing - nothing ran"; exit 2; }; done

echo "== clean"
out=$("$PWSH" -NoProfile -File "$T" -Script "$S" 2>&1); rc=$?
printf '%s\n' "$out"
bad=0
[ "$rc" = 0 ] || { echo "FAIL  the clean leg failed (rc=$rc)"; bad=1; }
# A gutted suite must not read as a pass.
n=$(printf '%s\n' "$out" | command grep -c '^  ok  ')
[ "$n" -ge 12 ] || { echo "FAIL  the clean leg reported only $n assertions - it has been gutted, not passed"; bad=1; }

leg(){ # $1 knob, $2.. the checks that must be among the failures
  local knob="$1"; shift
  local o r; o=$(LOGFRESH_DEFECT="$knob" "$PWSH" -NoProfile -File "$T" -Script "$S" 2>&1); r=$?
  echo "== LOGFRESH_DEFECT=$knob (must FAIL)"
  printf '%s\n' "$o" | command grep -E 'FAIL|INSTRUMENT|passed,'
  if [ "$r" != 1 ]; then echo "  NOT CAUGHT (rc=$r - the defect did not fail the suite)"; bad=1; return; fi
  local want
  for want in "$@"; do
    if printf '%s\n' "$o" | command grep -qF "FAIL $want"; then echo "  caught: $want"
    else echo "  NOT CAUGHT: expected a failure of '$want'"; bad=1; fi
  done
}
leg mtime \
  "the previous boot's file is NOT selected" \
  "a running agent with no line of its own anywhere"

if [ "$bad" = 0 ]; then
  echo "PASS  the content anchor holds, and the metadata logic is caught selecting a previous boot's"
  echo "      log AND claiming an instance for a silent agent"
  exit 0
fi
echo "FAIL  see above"; exit 1
