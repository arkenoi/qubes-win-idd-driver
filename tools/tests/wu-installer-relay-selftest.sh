#!/usr/bin/env bash
# wu-installer-relay-selftest.sh - offline proof matrix for the relay-replacement step of
# guest/install-updater-agent.ps1: the installer kills nothing (docs/ADR-updater.md 12.4). It waits,
# bounded, for 8082's listener to leave by its own parent watchdog; a survivor is not killed - the compile
# is skipped, the previous exe kept, the pid named.
#
# Runs on this dev qube with the linux pwsh; no rig, no guest. The suite is
# tools/tests/wu-installer-relay-test.ps1, which extracts the marked WU-INSTALLER-RELAY-WAIT region.
#
#   no env                      full matrix: the clean leg must PASS, and each defect knob must make the suite
#                               FAIL on the check it targets, and only within its cases. Exit 0 only if every
#                               leg came out as required.
#   WUINSTRELAY_DEFECT=N        run ONLY that knob and exit with the suite's own code.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PWSH="${PWSH:-/home/user/bin/pwsh7/pwsh}"
[ -x "$PWSH" ] || PWSH=/home/user/pwsh/pwsh
OUT="${WUINSTRELAY_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/wuinstrelay-selftest-XXXXXX")}"
SUITE="$ROOT/tools/tests/wu-installer-relay-test.ps1"
mkdir -p "$OUT"
say() { printf '%s\n' "$*"; }

if [ ! -x "$PWSH" ]; then say "FAIL  pwsh not found at $PWSH - nothing ran"; exit 2; fi

if [ -n "${WUINSTRELAY_DEFECT:-}" ]; then
    case "$WUINSTRELAY_DEFECT" in 1|2) ;; *) say "FAIL  unknown WUINSTRELAY_DEFECT='$WUINSTRELAY_DEFECT' (1|2)"; exit 2 ;; esac
    "$PWSH" -NoProfile -File "$SUITE" -Defect "$WUINSTRELAY_DEFECT"; rc=$?
    say "--- defect knob $WUINSTRELAY_DEFECT: suite rc=$rc (non-zero is the required outcome)"
    exit $rc
fi

bad=0
"$PWSH" -NoProfile -File "$SUITE" >"$OUT/clean.out" 2>&1; rc=$?
n=$(grep -c '^ok' "$OUT/clean.out"); f=$(grep -c '^FAIL' "$OUT/clean.out")
if [ $rc -eq 0 ] && [ "$f" -eq 0 ] && [ "$n" -ge 14 ]; then say "PASS  clean: rc=0 ok=$n fail=0"
else say "FAIL  clean: rc=$rc ok=$n fail=$f ($(grep -m1 -E '^FAIL' "$OUT/clean.out" || grep -m1 -iE 'exception|error' "$OUT/clean.out" | cut -c1-140))"; bad=1; fi

leg(){ # $1 knob, $2 target check (literal prefix), $3 allowed-failures regex
    "$PWSH" -NoProfile -File "$SUITE" -Defect "$1" >"$OUT/defect-$1.out" 2>&1; local r=$? ff st
    ff=$(grep -c '^FAIL' "$OUT/defect-$1.out")
    st=$(grep '^FAIL' "$OUT/defect-$1.out" | grep -vE "$3" | head -3 | cut -c6-120)
    if [ $r -ne 0 ] && grep -qF "FAIL $2" "$OUT/defect-$1.out" && [ -z "$st" ]; then
        say "PASS  defect $1: suite FAILED as required on its target and only within its cases (rc=$r, $ff failing checks)"
    else
        say "FAIL  defect $1: rc=$r target-failed=$(grep -cF "FAIL $2" "$OUT/defect-$1.out") stray=[$st]"; bad=1
    fi
}
# knob 1 kills by name on EVERY run (as the installer did), so every scenario's "nothing killed" check fails with it; knob 2 drops the
# wait, so the survivor's lookup count collapses too
leg 1 'survivor: a listener still on 8082 after the bound is NOT killed: compile skipped, previous exe kept' '^FAIL (survivor|survivor-noexe|unknown|exits-on-own: nothing was killed|free:)'
leg 2 'exits-on-own: the installer waits for 8082' '^FAIL (exits-on-own|survivor: the wait ran)'

say "--- outputs in $OUT"
exit $bad
