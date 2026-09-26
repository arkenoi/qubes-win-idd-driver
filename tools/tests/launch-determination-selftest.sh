#!/bin/bash
# Drives quick-upgrade.sh's OWN launch-determination predicate, offline, both ways.
#
# WHY. On 2026-09-26 the install launch call timed out because the guest wedged during it, and the
# harness logged "NOTHING about whether the installer ran is inferable from here". A whole cycle
# produced no information. The fix makes that inferable - lines in the installer log AFTER this
# run's marker - and this test exists because the project rule is that a check counts as evidence
# only once it has been SEEN TO FAIL with the defect present (--prove does that).
#
# The predicate is EXTRACTED FROM THE SHIPPED SCRIPT, never copied here: a test against a copy
# passes forever while the real one rots.
set -u
cd "$(git rev-parse --show-toplevel)" || exit 2
SRC=mgmt/harness/quick-upgrade.sh
PROVE=0; [ "${1:-}" = "--prove" ] && PROVE=1

fn=$(grep -m1 '^log_has_progress_after(){' "$SRC") || { echo "FAIL: predicate not found in $SRC"; exit 1; }
if [ "$PROVE" = 1 ]; then
    # THE DEFECT, re-introduced: drop the marker window and look at the whole file. That is the
    # stale-log trap - a previous run's output then reads as this run's progress.
    fn="log_has_progress_after(){ grep -qaE '^[0-9]{4}-[0-9]{2}-[0-9]{2}|^=== RESULT ==='; }"
    echo "--prove: predicate replaced with the marker-blind version"
fi
eval "$fn"

MARK=E2EMARK-20260926122318-578561
pass=0; fail=0
check(){ # name expected body
    local name="$1" want="$2" body="$3" got
    printf '%s\n' "$body" | log_has_progress_after "$MARK" && got=0 || got=1
    if [ "$got" = "$want" ]; then pass=$((pass+1)); echo "  ok   $name (want $want)"
    else fail=$((fail+1)); echo "  FAIL $name: want $want got $got"; fi
}

echo "launch-determination selftest"
check "installer wrote dated lines after the marker" 0 \
"2026-09-26 12:20:00 previous run
$MARK
2026-09-26 12:25:11 Stage 1 preflight"
check "installer reached a RESULT trailer" 0 \
"$MARK
=== RESULT === {\"ok\":true}"
check "marker present, nothing after it -> NOT started" 1 \
"2026-09-26 12:20:00 previous run line
2026-09-26 12:20:01 another previous line
$MARK"
# THE ONE THAT MATTERS: a log full of a PREVIOUS run's dated lines, marker at the end. A
# marker-blind predicate calls this "running" and the harness then waits out its whole deadline
# on an installer that never started.
check "STALE previous-run output only -> NOT started" 1 \
"2026-09-26 11:00:00 Stage 1 preflight
2026-09-26 11:04:00 === RESULT === {\"ok\":true}
$MARK"
check "empty log -> NOT started" 1 ""
check "no marker at all -> NOT started" 1 \
"2026-09-26 12:25:11 Stage 1 preflight"

echo "$pass passed, $fail failed"
if [ "$PROVE" = 1 ]; then
    [ "$fail" -gt 0 ] && { echo "PROVEN: the marker-blind defect is caught ($fail check(s) failed)"; exit 0; }
    echo "NOT PROVEN: the defect was re-introduced and every check still passed - this test is decoration"; exit 1
fi
[ "$fail" = 0 ] || exit 1
