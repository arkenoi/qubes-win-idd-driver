#!/usr/bin/env bash
# wu-reason-selftest.sh - offline proof matrix for GUARD:reasonmeasured: when a pass dies at
# 0x8024402C, dom0 must be told WHY, and the why must be what this pass MEASURED.
#
#   no env          full matrix: the clean leg passes and each knob makes the suite fail on its
#                   own check. Exit 0 only if every leg came out as required.
#   WUR_DEFECT=x    run only that knob (rawerror | assertwithoutprobe | claimtimer | rebootloop | noremedy)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PWSH="${PWSH:-/home/user/bin/pwsh7/pwsh}"
SUITE="$ROOT/tools/tests/wu-reason-test.ps1"
say() { printf '%s\n' "$*"; }
[ -x "$PWSH" ] || { say "FAIL  pwsh not found at $PWSH - nothing ran"; exit 2; }
[ -f "$SUITE" ] || { say "FAIL  suite not found at $SUITE"; exit 2; }
target_of() {
    case "$1" in
        rawerror)            printf '%s' "names Windows Update as not having used the proxy" ;;
        assertwithoutprobe)  printf '%s' "does NOT blame Windows Update" ;;
        claimtimer)          printf '%s' "claims NO duration - three subjects do not support one" ;;
        rebootloop)          printf '%s' "does NOT ask again" ;;
        noremedy)            printf '%s' "and sets reboot_needed so the existing accounting performs it" ;;
        *)                   printf '%s' "" ;;
    esac
}
KNOBS="rawerror assertwithoutprobe claimtimer rebootloop noremedy"
if [ -n "${WUR_DEFECT:-}" ]; then "$PWSH" -NoProfile -File "$SUITE" -Defect "$WUR_DEFECT"; exit $?; fi
rc=0
say "== clean leg (the shipped code) =="
out="$("$PWSH" -NoProfile -File "$SUITE" 2>&1)"; cleanrc=$?
printf '%s\n' "$out"
[ $cleanrc -eq 0 ] || { say "FAIL  the shipped code does not pass its own suite"; rc=1; }
for k in $KNOBS; do
    say ""; say "== defect knob: $k =="
    out="$("$PWSH" -NoProfile -File "$SUITE" -Defect "$k" 2>&1)"; krc=$?
    t="$(target_of "$k")"
    if [ $krc -eq 0 ]; then say "FAIL  knob '$k' did not make the suite fail - the check it targets is decoration"; printf '%s\n' "$out"; rc=1; continue; fi
    if [ $krc -eq 2 ]; then say "FAIL  knob '$k' broke the INSTRUMENT (exit 2), which proves nothing"; printf '%s\n' "$out"; rc=1; continue; fi
    if printf '%s' "$out" | grep -qF "FAIL $t"; then say "ok    knob '$k' fails on its own check: $t"
    else say "FAIL  knob '$k' failed, but NOT on '$t' - it proves nothing"; printf '%s\n' "$out"; rc=1; fi
done
say ""
if [ $rc -eq 0 ]; then say "PASS  clean leg green, every knob seen to fail on its own check"; else say "FAIL  matrix incomplete"; fi
exit $rc
