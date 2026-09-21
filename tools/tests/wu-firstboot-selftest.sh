#!/usr/bin/env bash
# wu-firstboot-selftest.sh - offline proof matrix for GUARD:firstboot in
# guest/qubes-windows-update.ps1: a Windows Update pass must REFUSE, and say a restart is required,
# while the guest has not started once since the updater agent was installed.
#
# Measured on GWeck's environment 2026-09-21: in that state the search dies ~2 s in at 0x8024402C
# (WU_E_PT_WINHTTP_NAME_NOT_RESOLVED) and dom0 is told nothing at all; one deliberate restart cures
# it, and restarting every update service does not. The default tools install leaves the guest
# running, so this is the state a user is in when they click Update right after installing QWT.
#
# Runs on this dev qube with the linux pwsh; no rig, no guest. The suite is
# tools/tests/wu-firstboot-test.ps1, which EXTRACTS the shipped WU-FIRSTBOOT-DECIDE region and
# replays it in a child pwsh, so what is tested is the code that ships - including the `exit` on
# the refusal path, because a refusal that fell through would raise the proxy and search anyway.
#
#   no env          full matrix: the clean leg must PASS and each defect knob must make the suite
#                   FAIL on the check it targets. Exit 0 only if every leg came out as required.
#   WUFB_DEFECT=x   run ONLY that knob and exit with the suite's own code - i.e. the knob makes
#                   this test FAIL, by design. (nogate | equality | nostampblocks | nostampsilent | noreboot | silent)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PWSH="${PWSH:-/home/user/bin/pwsh7/pwsh}"
SUITE="$ROOT/tools/tests/wu-firstboot-test.ps1"
say() { printf '%s\n' "$*"; }

[ -x "$PWSH" ] || { say "FAIL  pwsh not found at $PWSH - nothing ran"; exit 2; }
[ -f "$SUITE" ] || { say "FAIL  suite not found at $SUITE"; exit 2; }

# The check each knob must break - the failure has to land on the replayed case, not just anywhere.
target_of() {
    case "$1" in
        nogate)        printf '%s' "refuses the pass (never reaches the proxy)" ;;
        equality)      printf '%s' "refuses the pass (never reaches the proxy)" ;;
        nostampblocks) printf '%s' "proceeds rather than blocking a guest it cannot judge" ;;
        nostampsilent) printf '%s' "and SAYS the gate is inactive" ;;
        noreboot)      printf '%s' "asks for the restart (reboot_needed=True)" ;;
        silent)        printf '%s' "says RESTART REQUIRED, in the words the judge keys on" ;;
        *)             printf '%s' "" ;;
    esac
}
KNOBS="nogate equality nostampblocks nostampsilent noreboot silent"

if [ -n "${WUFB_DEFECT:-}" ]; then
    "$PWSH" -NoProfile -File "$SUITE" -Defect "$WUFB_DEFECT"
    exit $?
fi

rc=0
say "== clean leg (the shipped code) =="
out="$("$PWSH" -NoProfile -File "$SUITE" 2>&1)"; cleanrc=$?
printf '%s\n' "$out"
if [ $cleanrc -ne 0 ]; then say "FAIL  the shipped code does not pass its own suite"; rc=1; fi

for k in $KNOBS; do
    say ""
    say "== defect knob: $k =="
    out="$("$PWSH" -NoProfile -File "$SUITE" -Defect "$k" 2>&1)"; krc=$?
    target="$(target_of "$k")"
    if [ $krc -eq 0 ]; then
        say "FAIL  knob '$k' did not make the suite fail - the guard it targets is decoration"
        printf '%s\n' "$out"; rc=1; continue
    fi
    if [ $krc -eq 2 ]; then
        say "FAIL  knob '$k' broke the INSTRUMENT (exit 2), which proves nothing about the guard"
        printf '%s\n' "$out"; rc=1; continue
    fi
    if printf '%s' "$out" | grep -qF "FAIL $target"; then
        say "ok    knob '$k' fails on its own check: $target"
    else
        # A knob that fails somewhere else has not demonstrated the check is load-bearing.
        say "FAIL  knob '$k' made the suite fail, but NOT on '$target' - it proves nothing"
        printf '%s\n' "$out"; rc=1
    fi
done

say ""
if [ $rc -eq 0 ]; then say "PASS  clean leg green, every knob seen to fail on its own check"; else say "FAIL  matrix incomplete - see above"; fi
exit $rc
