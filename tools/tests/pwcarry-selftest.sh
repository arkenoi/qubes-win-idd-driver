#!/usr/bin/env bash
# pwcarry-selftest.sh - offline proof matrix for the rebuild content carry-over (the black-blink fix).
#
# Runs on this dev qube with gcc alone (no rig, no guest):
#   clean build            MUST pass
#   PWCARRY_DEFECT_* build MUST fail - a guard never seen to fail is decoration.
#
# The defects are the near-miss versions this fix could plausibly have shipped as:
#   ZEROOFFSET   copy from the old buffer's (0,0) instead of the screen-space overlap - the
#                obvious implementation, which lands a crop-snapped toast shifted by its shadow
#                inset (a jittering flash instead of a black one)
#   NOINTERSECT  copy min(w) x min(h) from (0,0) with no intersection at all
#   SAMEBUFFER   drop the src==dst guard, so a slab handed straight back shreds its own pixels
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${PWCARRY_OUT:-$(mktemp -d /tmp/pwcarry-selftest-XXXXXX)}"
mkdir -p "$OUT"
bad=0
say() { printf '%s\n' "$*"; }

cd "$ROOT/agent/gui-agent" || exit 2
build() { gcc -std=c99 -Wall -Wextra -Werror ${2:-} -I. pwcarry_test.c -o "$OUT/$1" 2>"$OUT/$1.build.err"; }

if build clean ""; then
    "$OUT/clean" >"$OUT/clean.out" 2>&1; rc=$?
    n=$(grep -c '^ok' "$OUT/clean.out"); f=$(grep -c '^FAIL' "$OUT/clean.out")
    if [ "$rc" -eq 0 ] && [ "$f" -eq 0 ] && [ "$n" -gt 30 ]; then
        say "PASS  clean: rc=0 ok=$n fail=0"
    else
        say "FAIL  clean: rc=$rc ok=$n fail=$f"; grep '^FAIL' "$OUT/clean.out" | head -5; bad=1
    fi
else
    say "FAIL  clean build: $(head -3 "$OUT/clean.build.err")"; bad=1
fi

for d in ZEROOFFSET NOINTERSECT SAMEBUFFER; do
    if build "defect-$d" "-DPWCARRY_DEFECT_$d"; then
        "$OUT/defect-$d" >"$OUT/defect-$d.out" 2>&1; rc=$?
        f=$(grep -c '^FAIL' "$OUT/defect-$d.out")
        if [ "$rc" -ne 0 ] && [ "$f" -gt 0 ]; then
            say "PASS  defect $d: suite FAILED as required (rc=$rc, $f failing: $(grep '^FAIL' "$OUT/defect-$d.out" | head -1 | cut -c7-80))"
        else
            say "FAIL  defect $d: suite did NOT fail (rc=$rc) - that guard is decoration"; bad=1
        fi
    else
        say "FAIL  defect $d build: $(head -3 "$OUT/defect-$d.build.err")"; bad=1
    fi
done

say "--- outputs in $OUT"
exit $bad
