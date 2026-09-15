#!/usr/bin/env bash
# updmutex-selftest.sh - offline proof matrix for the Global\QubesWindowsUpdate wait in
# guest/install-updater-agent.ps1 (installer audit item 16: "15 min = hung" vs a PT2H pass limit).
#
# Runs on this dev qube with the linux pwsh; no rig, no guest. The suite is
# tools/tests/updmutex-test.ps1, which extracts the marked region of the shipped script and drives
# it with a mocked task-limit reader and a mocked (then a real, second-thread) mutex.
#
#   no env            full matrix: the clean leg must PASS, and each defect knob must make the suite
#                     FAIL on the check it targets (a guard never seen to fail is decoration).
#                     Exit 0 only if every leg came out as required.
#   UPDMUTEX_DEFECT=x run ONLY that knob (fixed15min | proceed) and exit with the suite's own code -
#                     i.e. the knob makes this test FAIL, by design.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PWSH="${PWSH:-/home/user/bin/pwsh7/pwsh}"
OUT="${UPDMUTEX_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/updmutex-selftest-XXXXXX")}"
SUITE="$ROOT/tools/tests/updmutex-test.ps1"
mkdir -p "$OUT"
say() { printf '%s\n' "$*"; }

if [ ! -x "$PWSH" ]; then say "FAIL  pwsh not found at $PWSH - nothing ran"; exit 2; fi

# The check each knob must break - the failure has to land on the intended case, not just anywhere.
target_of() {
    case "$1" in
        fixed15min) printf '%s' "wait: the bounded wait asks for (7200+300)*1000 ms" ;;
        proceed)    printf '%s' "failloud: held past the bound -> throws" ;;
        *)          return 1 ;;
    esac
}

if [ -n "${UPDMUTEX_DEFECT:-}" ]; then
    target_of "$UPDMUTEX_DEFECT" >/dev/null || { say "FAIL  unknown UPDMUTEX_DEFECT='$UPDMUTEX_DEFECT' (fixed15min | proceed)"; exit 2; }
    "$PWSH" -NoProfile -File "$SUITE" -Defect "$UPDMUTEX_DEFECT"; rc=$?
    say "--- defect knob $UPDMUTEX_DEFECT: suite rc=$rc (non-zero is the required outcome)"
    exit $rc
fi

bad=0
"$PWSH" -NoProfile -File "$SUITE" >"$OUT/clean.out" 2>&1; rc=$?
n=$(grep -c '^ok' "$OUT/clean.out"); f=$(grep -c '^FAIL' "$OUT/clean.out")
if [ $rc -eq 0 ] && [ "$f" -eq 0 ] && [ "$n" -gt 50 ]; then say "PASS  clean: rc=0 ok=$n fail=0"
else say "FAIL  clean: rc=$rc ok=$n fail=$f ($(grep -m1 -E '^FAIL' "$OUT/clean.out" || grep -m1 -iE 'exception|error' "$OUT/clean.out" | cut -c1-140))"; bad=1; fi

for d in fixed15min proceed; do
    "$PWSH" -NoProfile -File "$SUITE" -Defect "$d" >"$OUT/defect-$d.out" 2>&1; rc=$?
    f=$(grep -c '^FAIL' "$OUT/defect-$d.out")
    want="$(target_of "$d")"
    if [ $rc -ne 0 ] && [ "$f" -gt 0 ] && grep -qF "FAIL $want" "$OUT/defect-$d.out"; then
        say "PASS  defect $d: suite FAILED as required on its target (rc=$rc, $f failing checks: $(grep '^FAIL' "$OUT/defect-$d.out" | head -1 | cut -c6-110))"
    elif [ $rc -ne 0 ] && [ "$f" -gt 0 ]; then
        say "FAIL  defect $d: suite failed (rc=$rc) but NOT on its target check '$want' - the knob broke something else"; bad=1
    else
        say "FAIL  defect $d: suite did NOT fail (rc=$rc) - that guard is decoration"; bad=1
    fi
done

say "--- outputs in $OUT"
exit $bad
