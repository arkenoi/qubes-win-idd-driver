#!/usr/bin/env bash
# toasthold-selftest.sh - offline proof matrix for the toast-banner hold (docs/ADR-toasts.md 10).
#
# Runs on this dev qube with gcc/g++ alone (no rig, no guest):
#   agent suite  (agent/gui-agent/toasthold_test.c, C)            clean MUST pass; every defect build MUST fail
#   bridge suite (tools/notifhost/toasthold_bridge_test.cpp, C++) clean MUST pass; every defect build MUST fail
# A guard never seen to fail is decoration (CLAUDE.md). CI runs the same two suites with msbuild
# (.github/workflows/build.yml: "Toast-hold unit suite", "Toast-hold bridge suite").
#
# The defects are the near-miss designs this fix could plausibly have shipped as:
#   TOASTIDENT_DEFECT_NOFOLD           no whitespace folding: the bridge's "a\nb" and the banner's "a b" differ
#                                      (every multi-line toast doubles)
#   TOASTIDENT_DEFECT_ORDERONLY        match by arrival order alone (a bannerless notification desyncs it)
#   TOASTIDENT_DEFECT_VERDICTOVERRIDE  the classifier overrides a route the listing settled
#   TOASTHOLD_DEFECT_NOBOUND           a hold never fails open (a lost toast instead of a late one)
#   TOASTHOLD_DEFECT_FAILCLOSED        doubt suppresses instead of showing
#   TOASTHOLD_DEFECT_NOPREEMPT         a queued bridge-bound toast no longer pre-empts the mapped banner
#   TOASTHOLD_DEFECT_PREEMPT_IDENTGATE pre-emption ends while an identity read is in flight (the in-place swap maps
#                                      the window while the bridged toast paints - review blocker #1)
#   TOASTHOLD_DEFECT_SUPPRESS_FINAL    a suppressed banner ignores its record turning window / the bridge dying
#                                      before dom0's ack (a LOSS - review blocker #2)
#   TOASTHOLD_DEFECT_NORECLAIM         a banner whose identity merely completed loses its consumed record (review #5)
#   TOASTHOLD_DEFECT_NOIDENT_IGNORES_BRIDGE the no-identity hold waits out 3 s with the bridge down (review #13)
#   TOASTHOLD_DEFECT_NOFORWARDBOUND    a suppression awaiting dom0's ack never reopens (second review #4)
#   TOASTHOLD_DEFECT_NOCARD_UNPACED    an unpaced second card-less read classes a banner mid-grow as a flyout (N2)
#   TOASTHOLD_DEFECT_SIZE60            the absolute 60 % size ceiling that never held a 573 px banner at 768 px (N3)
#   TOASTHOLD_DEFECT_DEADRECORDS       a dead bridge's records stay authoritative and keep pre-empting (N6)
#   TOASTHOLD_DEFECT_NOBACKOFF         a refused identity request is retried without back-off (N7)
#   TOASTIDENT_DEFECT_TIE_SLOTORDER    equal arrival ticks broken by ring slot, not sequence - reorders across a wrap (#12)
#   TOASTHOLD_DEFECT_RECLAIM_ANY       the own consumed record re-claimable for any new content, not only a completion (N5)
#   TOASTIDENT_DEFECT_MARK_BY_SLOT     the agent's shown mark is a flag in the slot, not the sequence it marks: a store
#                                      racing the bridge's republish of the slot reads as the NEW toast's banner shown
#                                      (ADR-toasts 11: its failed dom0 action goes unreported)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${TOASTHOLD_OUT:-$(mktemp -d /tmp/toasthold-selftest-XXXXXX)}"
mkdir -p "$OUT"
bad=0
say() { printf '%s\n' "$*"; }

run_suite() {   # name  build-cmd-prefix  source  minimum-ok  defects...
    local name="$1" cc="$2" src="$3" minok="$4"; shift 4
    if $cc -I"$ROOT/agent/gui-agent" "$src" -o "$OUT/$name-clean" 2>"$OUT/$name-clean.build.err"; then
        "$OUT/$name-clean" >"$OUT/$name-clean.out" 2>&1; rc=$?
        n=$(grep -c '^ok' "$OUT/$name-clean.out"); f=$(grep -c '^FAIL' "$OUT/$name-clean.out")
        if [ "$rc" -eq 0 ] && [ "$f" -eq 0 ] && [ "$n" -ge "$minok" ]; then
            say "PASS  $name clean: rc=0 ok=$n fail=0"
        else
            say "FAIL  $name clean: rc=$rc ok=$n fail=$f (min ok $minok)"; grep '^FAIL' "$OUT/$name-clean.out" | head -5; bad=1
        fi
    else
        say "FAIL  $name clean build: $(head -3 "$OUT/$name-clean.build.err")"; bad=1
    fi
    for d in "$@"; do
        if $cc -D"$d" -I"$ROOT/agent/gui-agent" "$src" -o "$OUT/$name-$d" 2>"$OUT/$name-$d.build.err"; then
            "$OUT/$name-$d" >"$OUT/$name-$d.out" 2>&1; rc=$?
            f=$(grep -c '^FAIL' "$OUT/$name-$d.out")
            if [ "$rc" -ne 0 ] && [ "$f" -gt 0 ]; then
                say "PASS  $name defect $d: suite FAILED as required (rc=$rc, $f failing: $(grep '^FAIL' "$OUT/$name-$d.out" | head -1 | cut -c6-90))"
            else
                say "FAIL  $name defect $d: suite did NOT fail (rc=$rc) - that guard is decoration"; bad=1
            fi
        else
            say "FAIL  $name defect $d build: $(head -3 "$OUT/$name-$d.build.err")"; bad=1
        fi
    done
}

run_suite agent  "gcc -std=c99 -Wall -Wextra -Werror" "$ROOT/agent/gui-agent/toasthold_test.c" 120 \
    TOASTIDENT_DEFECT_NOFOLD TOASTIDENT_DEFECT_ORDERONLY TOASTIDENT_DEFECT_VERDICTOVERRIDE \
    TOASTHOLD_DEFECT_NOBOUND TOASTHOLD_DEFECT_FAILCLOSED TOASTHOLD_DEFECT_NOPREEMPT \
    TOASTHOLD_DEFECT_PREEMPT_IDENTGATE TOASTHOLD_DEFECT_SUPPRESS_FINAL TOASTHOLD_DEFECT_NORECLAIM \
    TOASTHOLD_DEFECT_NOIDENT_IGNORES_BRIDGE TOASTHOLD_DEFECT_NOFORWARDBOUND TOASTHOLD_DEFECT_NOCARD_UNPACED \
    TOASTHOLD_DEFECT_SIZE60 TOASTHOLD_DEFECT_DEADRECORDS TOASTHOLD_DEFECT_NOBACKOFF \
    TOASTIDENT_DEFECT_TIE_SLOTORDER TOASTHOLD_DEFECT_RECLAIM_ANY TOASTIDENT_DEFECT_MARK_BY_SLOT
# The agent suite's headers must also compile as C++ (notifhost includes toastident.h that way).
run_suite agent-as-cpp "g++ -std=c++17 -Wall -Wextra -Werror -x c++" "$ROOT/agent/gui-agent/toasthold_test.c" 90
run_suite bridge "g++ -std=c++17 -Wall -Wextra -Werror" "$ROOT/tools/notifhost/toasthold_bridge_test.cpp" 15 \
    TOASTIDENT_DEFECT_NOFOLD TOASTIDENT_DEFECT_VERDICTOVERRIDE TOASTIDENT_DEFECT_MARK_BY_SLOT

say "--- outputs in $OUT"
exit $bad
