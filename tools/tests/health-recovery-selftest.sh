#!/usr/bin/env bash
# health-recovery-selftest.sh - offline proof for guest/health-check.ps1 section 2b (region SVC-RECOVERY-CHECK): the recovery
# docs/ADR-supervision.md 4 promises is asserted on every service of ours - QdbDaemon, QrexecAgent, QubesGuiWatchdog and
# (where it exists) QwtngNetSetup. Runs on this dev qube with the linux pwsh over a fake registry; no rig, no guest.
#   clean leg      tools/tests/health-recovery-test.ps1 must PASS
#   recovfour      the region with its list reverted to the two control-channel services must make the suite FAIL on the
#                  QubesGuiWatchdog-unarmed and QwtngNetSetup-unarmed cases (a guard never seen to fail is decoration)
#   HEALTHRECOV_DEFECT=recovfour   run only the knob and exit with the suite's own code
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PWSH="${PWSH:-/home/user/pwsh/pwsh}"
[ -x "$PWSH" ] || PWSH=/home/user/bin/pwsh7/pwsh
OUT="${HEALTHRECOV_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/health-recovery-selftest-XXXXXX")}"
SUITE="$ROOT/tools/tests/health-recovery-test.ps1"
mkdir -p "$OUT"
say() { printf '%s\n' "$*"; }
if [ ! -x "$PWSH" ]; then say "FAIL  pwsh not found at $PWSH - nothing ran"; exit 2; fi
if [ -n "${HEALTHRECOV_DEFECT:-}" ]; then
    "$PWSH" -NoProfile -File "$SUITE" -Defect "$HEALTHRECOV_DEFECT"; rc=$?
    say "--- defect knob $HEALTHRECOV_DEFECT: suite rc=$rc (non-zero is the required outcome)"; exit $rc
fi
bad=0
"$PWSH" -NoProfile -File "$SUITE" >"$OUT/clean.out" 2>&1; rc=$?
n=$(grep -c '^ok' "$OUT/clean.out"); f=$(grep -c '^FAIL' "$OUT/clean.out")
if [ $rc -eq 0 ] && [ "$f" -eq 0 ] && [ "$n" -ge 10 ]; then say "PASS  clean: rc=0 ok=$n fail=0"
else say "FAIL  clean: rc=$rc ok=$n fail=$f ($(grep -m1 -E '^FAIL' "$OUT/clean.out" || grep -m1 -iE 'exception|error' "$OUT/clean.out" | cut -c1-200))"; bad=1; fi
"$PWSH" -NoProfile -File "$SUITE" -Defect recovfour >"$OUT/defect-recovfour.out" 2>&1; rc=$?
if [ $rc -ne 0 ] && grep -qF 'FAIL QubesGuiWatchdog unarmed (the pre-2026-10-03 state of the MSI): FAIL' "$OUT/defect-recovfour.out" && grep -qF 'FAIL QwtngNetSetup present but unarmed' "$OUT/defect-recovfour.out"; then
    say "PASS  defect recovfour: suite FAILED as required on the watchdog and applier cases (rc=$rc, $(grep -c '^FAIL' "$OUT/defect-recovfour.out") failing checks)"
else
    say "FAIL  defect recovfour: rc=$rc first=[$(grep -m1 '^FAIL' "$OUT/defect-recovfour.out" | cut -c1-160)]"; bad=1
fi
say "--- outputs in $OUT"
exit $bad
