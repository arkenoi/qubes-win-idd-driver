#!/usr/bin/env bash
# The actionable-buttons route: the clean build passes and every near-miss defect build FAILS.
# run: tools/tests/toastactions-selftest.sh
# pass: exit 0
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# RAM-BACKED /tmp, AND THIS LEAKED A DIRECTORY PER RUN. /tmp here is a 1 GB tmpfs on a 4 GB
# machine, and tools/release-acceptance.sh refuses to start with under 200 MB free - a floor it
# has because a full /tmp OOM-killed two campaigns, one of them after it had already passed.
# Fifteen of these dirs (89 MB total) were found left behind on 2026-10-15. So: honour TMPDIR,
# and clean up only what WE created - a directory the caller NAMED belongs to the caller. The
# dir is KEPT when the suite fails, because a preserved failure is the thing worth having.
OUT="${TOASTACT_OUT:-}"
if [ -z "$OUT" ]; then
  OUT=$(mktemp -d "${TMPDIR:-/tmp}/toastactions-selftest-XXXXXX")
  trap 'rc=$?; if [ "$rc" -eq 0 ]; then rm -rf "$OUT"; else printf "kept %s for inspection (rc=%s)\n" "$OUT" "$rc" >&2; fi' EXIT
fi
mkdir -p "$OUT"
bad=0
say() { printf '%s\n' "$*"; }
CC="g++ -std=c++17 -Wall -Wextra -Werror -pthread"
# NOTHING HERE MAY WAIT FOREVER (2026-10-07). A run of this suite was found alive after 6.5 HOURS, holding the
# subagent that had started it. CAUSE, corrected after measuring it: not stdin, as the first version of this comment
# said - it is the knob TOASTACT_DEFECT_NOLOOKUPBOUND. Its defect IS an unbounded wait, so the defect build waits for
# a condition nobody will signal, and this loop had no bound to cut it short. The clean leg and every other knob
# finish in seconds.
#
# So: every child runs under a bound, with stdin closed for good measure. And for the one knob whose defect is "waits
# without a bound", TIMING OUT IS THE REQUIRED OUTCOME - a hang there is the defect being visible, and demanding FAIL
# lines from a process that can never print them is a check that cannot pass. Every other knob must fail with lines.
# 60 s: the clean leg and every non-hanging knob finish in seconds, so this is a failure detector, not a
# pace - and it bounds what the one hanging knob costs the suite.
RUNB="timeout --kill-after=5 60"
# the knobs whose DEFECT is an unbounded wait: for these the bound's expiry is the required outcome
HANGING_KNOBS=" TOASTACT_DEFECT_NOLOOKUPBOUND "
SRC="$ROOT/tools/notifhost/toastactions_test.cpp"

if $CC "$SRC" -o "$OUT/clean" 2>"$OUT/clean.build.err"; then
    $RUNB "$OUT/clean" >"$OUT/clean.out" 2>&1 </dev/null; rc=$?
    [ "$rc" = 124 ] || [ "$rc" = 137 ] && { say "FAIL  toastactions clean: the test did not finish within the bound (rc=$rc) - it HUNG"; bad=1; }
    n=$(grep -c '^ok' "$OUT/clean.out"); f=$(grep -c '^FAIL' "$OUT/clean.out")
    if [ "$rc" -eq 0 ] && [ "$f" -eq 0 ] && [ "$n" -ge 120 ]; then
        say "PASS  toastactions clean: rc=0 ok=$n fail=0"
    else
        say "FAIL  toastactions clean: rc=$rc ok=$n fail=$f (min ok 120)"; grep '^FAIL' "$OUT/clean.out" | head -5; bad=1
    fi
else
    say "FAIL  toastactions clean build: $(head -3 "$OUT/clean.build.err")"; bad=1
fi
for d in TOASTACT_DEFECT_BACKGROUND_CARRIED TOASTACT_DEFECT_PARTIAL_FORWARD TOASTACT_DEFECT_PACKAGED_COM \
         TOASTACT_DEFECT_KEY_BY_SEQ TOASTACT_DEFECT_NOCLICKBOUND TOASTACT_DEFECT_NOKILL TOASTACT_DEFECT_DOUBLE_OUTCOME TOASTACT_DEFECT_NOLOOKUPBOUND \
         TOASTACT_DEFECT_AWAIT_FOR_INFO TOASTACT_DEFECT_UNKNOWN_REFUSES TOASTACT_DEFECT_UNKNOWN_AS_KNOWN \
         TOASTACT_DEFECT_SCAN_PER_SENDER TOASTACT_DEFECT_SCAN_NORMAL_PRIORITY \
         TOASTACT_DEFECT_ALLOWLIST_BLIND \
         TOASTACT_DEFECT_BADKEY TOASTACT_DEFECT_NONOTICE TOASTACT_DEFECT_UNBOUNDED_TABLE; do
    if $CC -D"$d" "$SRC" -o "$OUT/$d" 2>"$OUT/$d.build.err"; then
        $RUNB "$OUT/$d" >"$OUT/$d.out" 2>&1 </dev/null; rc=$?
        if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
            case "$HANGING_KNOBS" in
                *" $d "*) say "PASS  toastactions defect $d: the test HUNG at the bound (rc=$rc) - which is what an unbounded wait does, so the defect IS visible"; continue ;;
                *) say "FAIL  toastactions defect $d: the test HUNG (rc=$rc) instead of failing - a defect that hangs says nothing"; bad=1; continue ;;
            esac
        fi
        f=$(grep -c '^FAIL' "$OUT/$d.out")
        if [ "$rc" -ne 0 ] && [ "$f" -gt 0 ]; then
            say "PASS  toastactions defect $d: suite FAILED as required (rc=$rc, $f failing: $(grep '^FAIL' "$OUT/$d.out" | head -1 | cut -c6-90))"
        else
            say "FAIL  toastactions defect $d: suite did NOT fail (rc=$rc) - that guard is decoration"; bad=1
        fi
    else
        say "FAIL  toastactions defect $d build: $(head -3 "$OUT/$d.build.err")"; bad=1
    fi
done
say "--- outputs in $OUT"
exit $bad
