#!/usr/bin/env bash
# relay-svcmap-selftest.sh - offline proof matrix for the relay's service-PID map
# (guest/qubes-updates-relay.cs, ServicePidMap): the peer-allowlist decision that denied Windows
# Update's own svchost at the start of a pass (GWeck #146/#153, reproduced 2026-09-16 on win11-gwt).
#
# Runs on this dev qube with the linux pwsh; no rig, no guest, no Windows. The suite is
# tools/tests/relay-svcmap-test.ps1, which compiles the SHIPPED source file with Add-Type and
# drives the policy class with a scripted SCM under de-DE culture.
#
#   no env                  full matrix: the clean leg must PASS, and the defect knob must make the
#                           suite FAIL on the check it targets (a guard never seen to fail is
#                           decoration). Exit 0 only if every leg came out as required.
#   RELAYSVCMAP_DEFECT=x    run ONLY that knob (stalemiss) and exit with the suite's own code -
#                           i.e. the knob makes this test FAIL, by design.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PWSH="${PWSH:-/home/user/bin/pwsh7/pwsh}"
OUT="${RELAYSVCMAP_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/relay-svcmap-selftest-XXXXXX")}"
SUITE="$ROOT/tools/tests/relay-svcmap-test.ps1"
mkdir -p "$OUT"
say() { printf '%s\n' "$*"; }

if [ ! -x "$PWSH" ]; then say "FAIL  pwsh not found at $PWSH - nothing ran"; exit 2; fi

# The check each knob must break - the failure has to land on the intended case, not just anywhere.
target_of() {
    case "$1" in
        stalemiss) printf '%s' "stale-map miss: wuauserv started after the map was built is admitted 3.7 s later" ;;
        *)         return 1 ;;
    esac
}

if [ -n "${RELAYSVCMAP_DEFECT:-}" ]; then
    target_of "$RELAYSVCMAP_DEFECT" >/dev/null || { say "FAIL  unknown RELAYSVCMAP_DEFECT='$RELAYSVCMAP_DEFECT' (stalemiss)"; exit 2; }
    "$PWSH" -NoProfile -File "$SUITE" -Defect "$RELAYSVCMAP_DEFECT"; rc=$?
    say "--- defect knob $RELAYSVCMAP_DEFECT: suite rc=$rc (non-zero is the required outcome)"
    exit $rc
fi

bad=0
"$PWSH" -NoProfile -File "$SUITE" >"$OUT/clean.out" 2>&1; rc=$?
n=$(grep -c '^ok' "$OUT/clean.out"); f=$(grep -c '^FAIL' "$OUT/clean.out")
if [ $rc -eq 0 ] && [ "$f" -eq 0 ] && [ "$n" -ge 12 ]; then say "PASS  clean: rc=0 ok=$n fail=0"
else say "FAIL  clean: rc=$rc ok=$n fail=$f ($(grep -m1 -E '^FAIL' "$OUT/clean.out" || grep -m1 -iE 'exception|error' "$OUT/clean.out" | cut -c1-140))"; bad=1; fi

for d in stalemiss; do
    "$PWSH" -NoProfile -File "$SUITE" -Defect "$d" >"$OUT/defect-$d.out" 2>&1; rc=$?
    f=$(grep -c '^FAIL' "$OUT/defect-$d.out")
    want="$(target_of "$d")"
    if [ $rc -ne 0 ] && [ "$f" -gt 0 ] && grep -qF "FAIL $want" "$OUT/defect-$d.out"; then
        say "PASS  defect $d: suite FAILED as required on its target (rc=$rc, $f failing checks: $(grep '^FAIL' "$OUT/defect-$d.out" | head -1 | cut -c6-120))"
    elif [ $rc -ne 0 ] && [ "$f" -gt 0 ]; then
        say "FAIL  defect $d: suite failed (rc=$rc) but NOT on its target check '$want' - the knob broke something else"; bad=1
    else
        say "FAIL  defect $d: suite did NOT fail (rc=$rc) - that guard is decoration"; bad=1
    fi
done

say "--- outputs in $OUT"
exit $bad
