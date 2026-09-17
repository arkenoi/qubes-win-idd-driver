#!/usr/bin/env bash
# wu-update-render-selftest.sh - offline proof matrix for the dom0-facing outcome rendering in
# guest/wu-update.ps1 (the Qube Manager path told dom0 "FAILED KB5129195: DISM rejected every
# package file" + exit 1 for a cumulative the guest had DEFERRED, measured 2026-09-16 on win11de-gwt).
#
# Runs on this dev qube with the linux pwsh; no rig, no guest. The suite is
# tools/tests/wu-update-render-test.ps1, which extracts the marked WU-OUTCOME region of the shipped
# handler and replays the guest's captured update-status.json against it.
#
#   no env               full matrix: the clean leg must PASS, and each defect knob must make the suite
#                        FAIL on the check it targets and nowhere outside its own case (a guard never
#                        seen to fail is decoration; a knob that breaks unrelated checks proves nothing
#                        about the one it targets). Exit 0 only if every leg came out as required.
#   WURENDER_DEFECT=x    run ONLY that knob (1 | deferred | info | fallback) and exit with the suite's
#                        own code - i.e. the knob makes this test FAIL, by design.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PWSH="${PWSH:-/home/user/bin/pwsh7/pwsh}"
OUT="${WURENDER_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/wurender-selftest-XXXXXX")}"
SUITE="$ROOT/tools/tests/wu-update-render-test.ps1"
mkdir -p "$OUT"
say() { printf '%s\n' "$*"; }

if [ ! -x "$PWSH" ]; then say "FAIL  pwsh not found at $PWSH - nothing ran"; exit 2; fi

# The check each knob must break, and the check-name prefixes its failures are allowed to carry:
# the failure has to land on the replayed case, not just anywhere.
DEFERRED_TARGET="deferred: captured pass - KB5129195 is rendered deferred with its own why, not the DISM fallback"
target_of() {
    case "$1" in
        1)        printf '%s' "$DEFERRED_TARGET" ;;
        deferred) printf '%s' "$DEFERRED_TARGET" ;;
        info)     printf '%s' "informational: the info row is rendered informational with its own reason" ;;
        fallback) printf '%s' "dism-rc: the real file and DISM rc are rendered, not an invented cause" ;;
        *)        return 1 ;;
    esac
}
allowed_of() {
    case "$1" in
        1)        printf '%s' '^FAIL (deferred|informational|dism-rc)' ;;   # the whole pre-fix code: every ok=false row was a failure
        deferred) printf '%s' '^FAIL deferred' ;;                            # incl. deferred+failed / deferred+informational
        info)     printf '%s' '^FAIL (deferred\+)?informational' ;;
        fallback) printf '%s' '^FAIL dism-rc' ;;
    esac
}
# Under the pre-fix knob the captured pass must render the MEASURED text (verify/s1/entrypoint.err).
MEASURED_LINE='FAILED KB5129195: DISM rejected every package file'

if [ -n "${WURENDER_DEFECT:-}" ]; then
    target_of "$WURENDER_DEFECT" >/dev/null || { say "FAIL  unknown WURENDER_DEFECT='$WURENDER_DEFECT' (1 | deferred | info | fallback)"; exit 2; }
    "$PWSH" -NoProfile -File "$SUITE" -Defect "$WURENDER_DEFECT"; rc=$?
    say "--- defect knob $WURENDER_DEFECT: suite rc=$rc (non-zero is the required outcome)"
    exit $rc
fi

bad=0
"$PWSH" -NoProfile -File "$SUITE" >"$OUT/clean.out" 2>&1; rc=$?
n=$(grep -c '^ok' "$OUT/clean.out"); f=$(grep -c '^FAIL' "$OUT/clean.out")
if [ $rc -eq 0 ] && [ "$f" -eq 0 ] && [ "$n" -gt 30 ]; then say "PASS  clean: rc=0 ok=$n fail=0"
else say "FAIL  clean: rc=$rc ok=$n fail=$f ($(grep -m1 -E '^FAIL' "$OUT/clean.out" || grep -m1 -iE 'exception|error' "$OUT/clean.out" | cut -c1-140))"; bad=1; fi
# The suite echoes every rendered line as "> <line>"; the check names quote the text too, so grep the rendered form.
if grep -qF "> $MEASURED_LINE" "$OUT/clean.out"; then say "FAIL  clean: the measured pre-fix line is still rendered: $MEASURED_LINE"; bad=1; fi

for d in 1 deferred info fallback; do
    "$PWSH" -NoProfile -File "$SUITE" -Defect "$d" >"$OUT/defect-$d.out" 2>&1; rc=$?
    f=$(grep -c '^FAIL' "$OUT/defect-$d.out")
    want="$(target_of "$d")"; allow="$(allowed_of "$d")"
    stray=$(grep '^FAIL' "$OUT/defect-$d.out" | grep -vE "$allow" | head -3 | cut -c6-120)
    if [ $rc -ne 0 ] && [ "$f" -gt 0 ] && grep -qF "FAIL $want" "$OUT/defect-$d.out" && [ -z "$stray" ]; then
        say "PASS  defect $d: suite FAILED as required on its target and only within its case (rc=$rc, $f failing checks)"
    elif [ $rc -ne 0 ] && [ "$f" -gt 0 ] && grep -qF "FAIL $want" "$OUT/defect-$d.out"; then
        say "FAIL  defect $d: target failed but so did checks outside its case: $stray"; bad=1
    elif [ $rc -ne 0 ] && [ "$f" -gt 0 ]; then
        say "FAIL  defect $d: suite failed (rc=$rc) but NOT on its target check '$want' - the knob broke something else"; bad=1
    else
        say "FAIL  defect $d: suite did NOT fail (rc=$rc) - that guard is decoration"; bad=1
    fi
done
# The pre-fix knob is only faithful if it reproduces what the guest actually told dom0.
if grep -qF "> $MEASURED_LINE" "$OUT/defect-1.out"; then say "PASS  defect 1 reproduces the measured pre-fix text verbatim: $MEASURED_LINE"
else say "FAIL  defect 1 does not reproduce the measured pre-fix text '$MEASURED_LINE' - the knob is not the pre-fix code"; bad=1; fi

say "--- outputs in $OUT"
exit $bad
