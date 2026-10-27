#!/usr/bin/env bash
# The rebuild content carry-over: the clean build passes and EVERY near-miss defect build FAILS.
# run: tools/tests/pwcarry-selftest.sh
# pass: exit 0
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# RAM-BACKED /tmp, AND THIS LEAKED A DIRECTORY PER RUN. /tmp here is a 1 GB tmpfs on a 4 GB
# machine, and tools/release-acceptance.sh refuses to start with under 200 MB free - a floor it
# has because a full /tmp OOM-killed two campaigns, one of them after it had already passed.
# Fifteen of these dirs (89 MB total) were found left behind on 2026-10-15. So: honour TMPDIR,
# and clean up only what WE created - a directory the caller NAMED belongs to the caller. The
# dir is KEPT when the suite fails, because a preserved failure is the thing worth having.
OUT="${PWCARRY_OUT:-}"
if [ -z "$OUT" ]; then
  OUT=$(mktemp -d "${TMPDIR:-/tmp}/pwcarry-selftest-XXXXXX")
  trap 'rc=$?; if [ "$rc" -eq 0 ]; then rm -rf "$OUT"; else printf "kept %s for inspection (rc=%s)\n" "$OUT" "$rc" >&2; fi' EXIT
fi
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

for d in ZEROOFFSET NOINTERSECT SAMEBUFFER NOFILL; do
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
