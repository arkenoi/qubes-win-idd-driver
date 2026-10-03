#!/usr/bin/env bash
# wu-relay-own-selftest.sh - offline proof matrix for the relay lifecycle of guest/qubes-windows-update.ps1:
# the pass owns exactly the relay it started, by handle, and never kills or adopts a process by NAME
# (docs/ADR-updater.md 12.4; findings/issues.md P1 "OUR UPDATE CODE KILLS AND ADOPTS PROCESSES BY NAME",
# measured 2026-10-03: the boot scan adopted a foreign relay and killed it mid-transfer).
#
# Runs on this dev qube with the linux pwsh; no rig, no guest. The suite is tools/tests/wu-relay-own-test.ps1,
# which extracts the marked WU-RELAY and WU-RELAY-TEARDOWN regions of the shipped pass and drives them
# against fake processes and a scripted TCP table.
#
#   no env                 full matrix: the clean leg must PASS, and every defect knob must make the suite
#                          FAIL on the check it targets, and only within its own case (a guard never seen to
#                          fail is decoration). Exit 0 only if every leg came out as required.
#   WURELAYOWN_DEFECT=N    run ONLY that knob and exit with the suite's own code - i.e. the knob makes this
#                          test FAIL, by design.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PWSH="${PWSH:-/home/user/bin/pwsh7/pwsh}"
[ -x "$PWSH" ] || PWSH=/home/user/pwsh/pwsh
OUT="${WURELAYOWN_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/wurelayown-selftest-XXXXXX")}"
SUITE="$ROOT/tools/tests/wu-relay-own-test.ps1"
mkdir -p "$OUT"
say() { printf '%s\n' "$*"; }

if [ ! -x "$PWSH" ]; then say "FAIL  pwsh not found at $PWSH - nothing ran"; exit 2; fi

if [ -n "${WURELAYOWN_DEFECT:-}" ]; then
    case "$WURELAYOWN_DEFECT" in 1|2|3|4|5) ;; *) say "FAIL  unknown WURELAYOWN_DEFECT='$WURELAYOWN_DEFECT' (1-5)"; exit 2 ;; esac
    "$PWSH" -NoProfile -File "$SUITE" -Defect "$WURELAYOWN_DEFECT"; rc=$?
    say "--- defect knob $WURELAYOWN_DEFECT: suite rc=$rc (non-zero is the required outcome)"
    exit $rc
fi

bad=0
"$PWSH" -NoProfile -File "$SUITE" >"$OUT/clean.out" 2>&1; rc=$?
n=$(grep -c '^ok' "$OUT/clean.out"); f=$(grep -c '^FAIL' "$OUT/clean.out")
if [ $rc -eq 0 ] && [ "$f" -eq 0 ] && [ "$n" -ge 30 ]; then say "PASS  clean: rc=0 ok=$n fail=0"
else say "FAIL  clean: rc=$rc ok=$n fail=$f ($(grep -m1 -E '^FAIL' "$OUT/clean.out" || grep -m1 -iE 'exception|error' "$OUT/clean.out" | cut -c1-140))"; bad=1; fi

# Each knob must fail ITS target check, and only within the cases its pre-2026-10-03 behaviour touches.
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
# knob 1 is the whole pre-2026-10-03 Ensure-Proxy head: it looks processes up by name in EVERY pass, never reads the port table and
# returns as soon as anything listens - so besides its target (the foreign refusal) it fails the own and deaf cases' "no by-name
# lookup" checks, the race case's refusal and the unknown cases' refusals. Every guard in the region is new relative to it.
leg 1 'foreign: a listener this pass did not start on 8082 -> Ensure-Proxy REFUSES, naming pid 7777' '^FAIL (foreign|own|deaf|race|unknown)'
leg 2 'foreign: at the end of the pass Remove-Proxy leaves the foreign relay-named process alone' '^FAIL (foreign|deaf|own|race):'
leg 3 'deaf: the relay-named bystander (7777) is not touched by the respawn' '^FAIL deaf:'
leg 4 'own: the relay is started with -PassThru and held by handle' '^FAIL (own|deaf|race):'
leg 5 'race: a listener that took 8082 between the check and our start is not adopted' '^FAIL race:'

say "--- outputs in $OUT"
exit $bad
