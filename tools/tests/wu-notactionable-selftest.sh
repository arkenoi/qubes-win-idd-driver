#!/usr/bin/env bash
# wu-notactionable-selftest.sh - offline proof matrix for the NOT-ACTIONABLE classification in
# guest/qubes-windows-update.ps1, i.e. the second half of the field failure: after the September
# cumulative was fully applied on the German 25H2 template, three offers were re-offered on every
# pass and all counted actionable, so dom0's updates-available could never clear and Qube Manager
# could never show the template as up to date. That is dom0 misreporting the template's update
# state - the same fault class as the original report, in the opposite direction.
#
# Runs on this dev qube with the linux pwsh; no rig, no guest. The suite is
# tools/tests/wu-notactionable-test.ps1, which EXTRACTS the marked regions of the shipped script
# (WU-EXE-EFFECT-*, WU-INFO-EXCLUDE-*) and replays them, so what is tested is the code that ships.
#
#   no env                   full matrix: the clean leg must PASS and each defect knob must make the
#                            suite FAIL on the check it targets. Exit 0 only if every leg came out
#                            as required.
#   WUNA_DEFECT=x            run ONLY that knob and exit with the suite's own code - i.e. the knob
#                            makes this test FAIL, by design. (rcalone | noticeonly | kbonly | rcinfers | trustzero | shapeskip | infoonly | scanall | infobenign | satignore | satdrop | failall)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PWSH="${PWSH:-/home/user/bin/pwsh7/pwsh}"
SUITE="$ROOT/tools/tests/wu-notactionable-test.ps1"
say() { printf '%s\n' "$*"; }

[ -x "$PWSH" ] || { say "FAIL  pwsh not found at $PWSH - nothing ran"; exit 2; }
[ -f "$SUITE" ] || { say "FAIL  suite not found at $SUITE"; exit 2; }

# The check each knob must break - the failure has to land on the replayed case, not just anywhere.
target_of() {
    case "$1" in
        rcalone)    printf '%s' "ok FALSE (nothing landed, so nothing succeeded)" ;;
        infobenign) printf '%s' "NOT informational (a silent failure)" ;;
        satignore)  printf '%s' "the SAME offer identity a pass resolved is excluded" ;;
        satdrop)    printf '%s' "the identities are CARRIED FORWARD" ;;
        failall)    printf '%s' "probe cannot establish the offered version -> informational" ;;
        noticeonly) printf '%s' "no ESU notice -> dom0 hears 0" ;;
        kbonly)     printf '%s' "no ESU notice -> dom0 hears 0" ;;
        rcinfers)   printf '%s' "CONTAINS update.mum -> NOT informational (corrupt download)" ;;
        trustzero)  printf '%s' "EMPTY body -> UNRESOLVED" ;;
        shapeskip)  printf '%s' "HAS a direct URL on an install action -> INSTALLED" ;;
        infoonly)   printf '%s' "dom0 reaches 0 (up to date)" ;;
        scanall)    printf '%s' "proved NOT ACTIONABLE is excluded" ;;
        *)          return 1 ;;
    esac
}

if [ -n "${WUNA_DEFECT:-}" ]; then
    target_of "$WUNA_DEFECT" >/dev/null || { say "FAIL  unknown WUNA_DEFECT='$WUNA_DEFECT' (rcalone | noticeonly | kbonly | rcinfers | trustzero | shapeskip | infoonly | scanall | infobenign | satignore | satdrop | failall)"; exit 2; }
    "$PWSH" -NoProfile -File "$SUITE" -Defect "$WUNA_DEFECT"; rc=$?
    say "--- defect knob $WUNA_DEFECT: suite rc=$rc (non-zero is the required outcome)"
    exit $rc
fi

bad=0
out=$("$PWSH" -NoProfile -File "$SUITE" 2>&1); rc=$?
printf '%s\n' "$out" | sed 's/^/  /'
if [ "$rc" != 0 ]; then say "FAIL  clean leg did not pass (rc=$rc)"; bad=1; else say "OK    clean leg passed"; fi

for knob in rcalone noticeonly kbonly rcinfers trustzero shapeskip infoonly scanall infobenign satignore satdrop failall; do
    want=$(target_of "$knob")
    out=$("$PWSH" -NoProfile -File "$SUITE" -Defect "$knob" 2>&1); rc=$?
    if [ "$rc" = 0 ]; then
        say "FAIL  defect '$knob' did NOT break the suite - the guard it targets is decoration"; bad=1
    elif ! printf '%s' "$out" | grep -q "FAIL.*$want"; then
        say "FAIL  defect '$knob' broke the suite, but not on its target check ('$want')"
        printf '%s\n' "$out" | grep '^FAIL' | sed 's/^/      /'; bad=1
    else
        say "OK    defect '$knob' -> suite FAILS on its target check"
    fi
done

[ "$bad" = 0 ] && { say "MATRIX OK: clean passes, every guard seen to fail"; exit 0; }
say "MATRIX FAILED"; exit 1
