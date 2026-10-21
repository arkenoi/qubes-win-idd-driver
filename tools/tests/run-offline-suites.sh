#!/bin/bash
# run-offline-suites.sh - run every suite in offline-suites.txt, serially, and fail on any red.
#
#   tools/tests/run-offline-suites.sh
#
# This is the producer SELFTESTSUNRUNINCI was missing: 117 offline suites existed and CI named them
# only in comments, so a green `test` said nothing about any of them and every receipt in
# findings/issues.md held only as long as someone kept running them by hand.
#
# SERIAL BY DESIGN. Two suites that both bind and delete loop devices produced a false red when run
# in one command (BLOCKCLAIMSELFTESTRACES): loop numbers are global, so each can observe the other's
# device. Parallelism here would buy a minute and cost a believable red.
#
# THE FLOOR IS THE POINT. A runner that iterates a list cannot tell "all 37 passed" from "the list
# was emptied" - and a gate suite losing its producer is this project's most repeated failure
# (count-the-producers, the selftest whose RESULT line was deduped away, the gate that required 18
# suites where 12 had a producer). So the count is asserted against a floor that only moves in a
# commit, and a suite that reports zero assertions is a failure even at exit 0.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2

# OFFLINE_SUITES_LIST/_DIR point this at a fixture list, for tools/tests/offline-runner-selftest.sh.
# A runner whose own floor and EMPTY rule have never been seen to FIRE is the thing it exists to
# stop, so they are proven against planted suites rather than asserted in this comment.
LIST=${OFFLINE_SUITES_LIST:-tools/tests/offline-suites.txt}
SUITEDIR=${OFFLINE_SUITES_DIR:-tools/tests}
# 36 since 2026-10-15: clock-convention-selftest.sh was DELETED with the decision block it tested.
# 56 since 2026-10-17: notifbridge-pid-selftest.sh ADDED, after the agent reported a
# predecessor's bridge exiting as its own bridge crashing.
# 55 since 2026-10-17: desktop-stuck-lock-selftest.sh ADDED, after an ACTION notification told
# the user to sign in to a guest that signed itself in 8 s later.
# 54 since 2026-10-17: wrapper-one-line-selftest.sh ADDED, holding one truncated transfer to
# ONE error line after a single event reported three times on a campaign cell.
# 53 since 2026-10-17: window-measure-selftest.sh ADDED, holding GetRealWindowRect to the
# discriminator between a vanished window and a monitor-topology fault.
# 52 since 2026-10-17: wait-bound-selftest.sh ADDED, after a probe bounded below the boot it waited
# for abandoned a request on every boot and the guest logged a dropped request for each one.
# 56 -> 57 on 2026-10-17: cold-caller-family-selftest.sh, which pins the release goal's cold-qube
# clause to EVERY OS family rather than to whichever cell ran first (it was evidenced on win10 only
# in run 38994277148, with win11 - the target - unmeasured).
# 57 -> 59 on 2026-10-19: relay-judge-timenorm-selftest.sh and wu-judge-timenorm-selftest.sh ADDED,
# after both update judges were found correlating two log sources by TIME OF DAY - no date, no zone.
# Measured: a relay line and a WU failure 24 h apart gave `gaps=0 violations=0` exit 0, and a WU
# window over a two-date decode graded `ended=True verdict: PASS` on a day whose pass never ran a
# search. Each suite carries the pre-fix comparison frozen beside the fixed one, so every case is
# seen to fail.
# The floor only ever moves in a commit, and this is that commit - a suite that loses its subject is
# removed deliberately, not left to rot green.
# 59 -> 60 on 2026-10-19: toasthold-grade-clock-selftest.sh ADDED, the same defect class in the
# toast-hold grader: bridge.log carries a time of day and NO date, and the date was put on it by
# comparing it against THIS qube's clock, three hours out of phase with the guest's on the very
# evidence it grades. Measured: a record stamped 61 s BEFORE its own toast read PASS OK-BRIDGED.
# 60 -> 61 on 2026-10-19: harness-clock-selftest.sh ADDED, the host-side half of the same class: one
# campaign matrix.log carried three clocks (its own `date` local, accept-clean's `date -u` quoted on
# the same line, arm-module-bases' UTC), and a guest-local stick file 42 s OLDER than its bind was
# read as three hours newer. Every host stamp is now `date -u` and each campaign log declares its
# zone first; the suite's negatives are frozen fixtures, so they cannot rot when the fix is committed.
FLOOR=${OFFLINE_SUITES_FLOOR:-71}
# Each suite's own temp files: /tmp is a 1 GB tmpfs on the dev qube and 40 suites' fixtures do not
# belong in RAM. On a CI runner TMPDIR is already real disk, so this only ever makes it safer.
export TMPDIR="${TMPDIR_OVERRIDE:-${RUNNER_TEMP:-/home/user/tmp}}"
mkdir -p "$TMPDIR" 2>/dev/null

# DEPTH GUARD. offline-runner-selftest.sh is itself in the list and it RUNS this script against a
# fixture list, so the nesting is one deep by construction - but a self-test that re-entered its own
# producer once fork-bombed this qube, and the fix then was a depth guard. One level, no exceptions.
if [ "${OFFLINE_SUITES_DEPTH:-0}" -ge 1 ]; then
  echo "ERROR: run-offline-suites.sh re-entered itself (depth ${OFFLINE_SUITES_DEPTH}) - a suite must not run the whole suite"
  exit 2
fi
export OFFLINE_SUITES_DEPTH=$(( ${OFFLINE_SUITES_DEPTH:-0} + 1 ))

[ -r "$LIST" ] || { echo "ERROR: $LIST is missing - the curated list IS the gate"; exit 2; }
mapfile -t suites < <(sed 's/#.*//' "$LIST" | awk 'NF')
n=${#suites[@]}
if [ "$n" -lt "$FLOOR" ]; then
  echo "ERROR: $LIST names $n suite(s), floor is $FLOOR - the list shrank; move the floor in a commit or restore the suites"
  exit 2
fi
echo "--- $n offline suite(s), serially (floor $FLOOR, TMPDIR $TMPDIR)"

red=0; green=0; empty=0; total_assertions=0
for s in "${suites[@]}"; do
  f="$SUITEDIR/$s"
  if [ ! -x "$f" ] && [ ! -r "$f" ]; then
    printf 'MISSING  %-52s named in the list, not in the tree\n' "$s"; red=$((red+1)); continue
  fi
  out=$(timeout 300 bash "$f" 2>&1); rc=$?
  # A run that reports NO assertion at all has been gutted, whatever its exit code - that is exactly
  # how a deduped RESULT line turned a suite into a no-op. Two spellings count, because both are in
  # use here: a tally ("N passed", "N check(s)") and a bare verdict line. The defect-knob suites
  # print their planted failures as FAIL lines and end with one PASS, so counting only tallies
  # called four green suites empty.
  passed=$(printf '%s' "$out" | command grep -oaE '[0-9]+ (passed|check\(s\))' | command grep -oaE '^[0-9]+' | tail -1)
  : "${passed:=0}"
  if [ "$passed" -eq 0 ]; then
    passed=$(printf '%s' "$out" | command grep -caE '^[[:space:]]*(PASS|ok)[[:space:]]|^RESULT: PASS')
    : "${passed:=0}"
  fi
  total_assertions=$((total_assertions + passed))
  if [ "$rc" -ne 0 ]; then
    printf 'FAIL     %-52s rc=%s  %s\n' "$s" "$rc" "$(printf '%s' "$out" | tail -1 | cut -c1-80)"
    printf '%s\n' "$out" | command grep -aiE '^\s*(FAIL|BROKE|ERROR)' | sed 's/^/           /' | head -6
    red=$((red+1))
  elif [ "$passed" -eq 0 ]; then
    printf 'EMPTY    %-52s exited 0 and reported no assertions\n' "$s"
    empty=$((empty+1))
  else
    printf 'ok       %-52s %s assertion(s)\n' "$s" "$passed"
    green=$((green+1))
  fi
done

echo "--- $green green, $red red, $empty reporting nothing; $total_assertions assertions over $n suite(s)"
if [ "$red" -gt 0 ] || [ "$empty" -gt 0 ]; then
  echo "RESULT: FAIL"
  exit 1
fi
echo "RESULT: PASS"
