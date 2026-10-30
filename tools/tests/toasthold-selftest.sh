#!/usr/bin/env bash
# The toast-banner hold: the clean build passes and EVERY near-miss defect build FAILS.
# run: tools/tests/toasthold-selftest.sh
# pass: exit 0
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# RAM-BACKED /tmp, AND THIS LEAKED A DIRECTORY PER RUN. /tmp here is a 1 GB tmpfs on a 4 GB
# machine, and tools/release-acceptance.sh refuses to start with under 200 MB free - a floor it
# has because a full /tmp OOM-killed two campaigns, one of them after it had already passed.
# Fifteen of these dirs (89 MB total) were found left behind on 2026-10-15. So: honour TMPDIR,
# and clean up only what WE created - a directory the caller NAMED belongs to the caller. The
# dir is KEPT when the suite fails, because a preserved failure is the thing worth having.
OUT="${TOASTHOLD_OUT:-}"
if [ -z "$OUT" ]; then
  OUT=$(mktemp -d "${TMPDIR:-/tmp}/toasthold-selftest-XXXXXX")
  trap 'rc=$?; if [ "$rc" -eq 0 ]; then rm -rf "$OUT"; else printf "kept %s for inspection (rc=%s)\n" "$OUT" "$rc" >&2; fi' EXIT
fi
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
    TOASTHOLD_DEFECT_PREEMPT_IDENTGATE TOASTHOLD_DEFECT_PREEMPT_UNMAPS \
    TOASTHOLD_DEFECT_SUPPRESS_FINAL TOASTHOLD_DEFECT_NORECLAIM \
    TOASTHOLD_DEFECT_NOIDENT_IGNORES_BRIDGE TOASTHOLD_DEFECT_NOFORWARDBOUND TOASTHOLD_DEFECT_NOCARD_UNPACED \
    TOASTHOLD_DEFECT_SIZE60 TOASTHOLD_DEFECT_DEADRECORDS TOASTHOLD_DEFECT_NOBACKOFF \
    TOASTIDENT_DEFECT_TIE_SLOTORDER TOASTHOLD_DEFECT_RECLAIM_ANY TOASTIDENT_DEFECT_MARK_BY_SLOT
# The agent suite's headers must also compile as C++ (notifhost includes toastident.h that way).
run_suite agent-as-cpp "g++ -std=c++17 -Wall -Wextra -Werror -x c++" "$ROOT/agent/gui-agent/toasthold_test.c" 90
run_suite bridge "g++ -std=c++17 -Wall -Wextra -Werror" "$ROOT/tools/notifhost/toasthold_bridge_test.cpp" 15 \
    TOASTIDENT_DEFECT_NOFOLD TOASTIDENT_DEFECT_VERDICTOVERRIDE TOASTIDENT_DEFECT_MARK_BY_SLOT

say "--- outputs in $OUT"
exit $bad
