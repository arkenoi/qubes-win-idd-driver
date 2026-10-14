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
# THE FLOOR IS THE POINT. A runner that iterates a list cannot tell "all 41 passed" from "the list
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
FLOOR=${OFFLINE_SUITES_FLOOR:-41}
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
