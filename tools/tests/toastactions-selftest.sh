#!/usr/bin/env bash
# toastactions-selftest.sh - offline proof matrix for the actionable-buttons route (docs/ADR-toasts.md 11).
#
# Runs on this dev qube with g++ alone (no rig, no guest): tools/notifhost/toastactions_test.cpp over
# toastactions.h (+ toastclassify.h). The clean build MUST pass; every defect build MUST fail - a guard never
# seen to fail is decoration (CLAUDE.md). CI runs the same suite with msbuild (.github/workflows/build.yml,
# "Toast actions suite").
#
# The defects are the near-miss designs this route could plausibly have shipped as:
#   TOASTACT_DEFECT_BACKGROUND_CARRIED  background activations carried (out of scope by decision)
#   TOASTACT_DEFECT_PARTIAL_FORWARD     a toast with an uncarriable button forwards the carriable subset (half-way)
#   TOASTACT_DEFECT_PACKAGED_COM        a packaged sender's foreground activation treated as a COM activator's
#   TOASTACT_DEFECT_BADKEY              generated keys the proxy refuses (the whole notification would be rejected)
#   TOASTACT_DEFECT_NONOTICE            a failed click whose banner is gone is never reported (silent loss)
#   TOASTACT_DEFECT_UNBOUNDED_TABLE     the per-notification table never evicts
#   TOASTACT_DEFECT_KEY_BY_SEQ          the table is looked up by our sequence, not the proxy's id (wrong id space)
#   TOASTACT_DEFECT_NOCLICKBOUND        a click whose child never exits is never resolved (no outcome, cap taken)
#   TOASTACT_DEFECT_NOKILL              the bound reports the failure but leaves the hung child process alive
#   TOASTACT_DEFECT_DOUBLE_OUTCOME      a click already reported gets a second outcome
#   TOASTACT_DEFECT_NOLOOKUPBOUND       the activator lookup is waited for without a bound
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${TOASTACT_OUT:-$(mktemp -d /tmp/toastactions-selftest-XXXXXX)}"
mkdir -p "$OUT"
bad=0
say() { printf '%s\n' "$*"; }
CC="g++ -std=c++17 -Wall -Wextra -Werror -pthread"
SRC="$ROOT/tools/notifhost/toastactions_test.cpp"

if $CC "$SRC" -o "$OUT/clean" 2>"$OUT/clean.build.err"; then
    "$OUT/clean" >"$OUT/clean.out" 2>&1; rc=$?
    n=$(grep -c '^ok' "$OUT/clean.out"); f=$(grep -c '^FAIL' "$OUT/clean.out")
    if [ "$rc" -eq 0 ] && [ "$f" -eq 0 ] && [ "$n" -ge 100 ]; then
        say "PASS  toastactions clean: rc=0 ok=$n fail=0"
    else
        say "FAIL  toastactions clean: rc=$rc ok=$n fail=$f (min ok 100)"; grep '^FAIL' "$OUT/clean.out" | head -5; bad=1
    fi
else
    say "FAIL  toastactions clean build: $(head -3 "$OUT/clean.build.err")"; bad=1
fi
for d in TOASTACT_DEFECT_BACKGROUND_CARRIED TOASTACT_DEFECT_PARTIAL_FORWARD TOASTACT_DEFECT_PACKAGED_COM \
         TOASTACT_DEFECT_KEY_BY_SEQ TOASTACT_DEFECT_NOCLICKBOUND TOASTACT_DEFECT_NOKILL TOASTACT_DEFECT_DOUBLE_OUTCOME TOASTACT_DEFECT_NOLOOKUPBOUND \
         TOASTACT_DEFECT_BADKEY TOASTACT_DEFECT_NONOTICE TOASTACT_DEFECT_UNBOUNDED_TABLE; do
    if $CC -D"$d" "$SRC" -o "$OUT/$d" 2>"$OUT/$d.build.err"; then
        "$OUT/$d" >"$OUT/$d.out" 2>&1; rc=$?
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
