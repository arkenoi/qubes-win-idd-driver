#!/usr/bin/env bash
# the updater deploy must PROVE what it built - source, exe and image vouches refuse a stale relay.
# run: tools/tests/relay-vouch-selftest.sh
# pass: exit 0
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUITE="$ROOT/tools/tests/relay-vouch-test.ps1"
PWSH="$("$(dirname "$0")/pwsh-path.sh" || true)"
say() { printf '%s\n' "$*"; }
[ -x "$PWSH" ] || { say "FAIL  pwsh not found at $PWSH - nothing ran"; exit 2; }
[ -f "$SUITE" ] || { say "FAIL  $SUITE is missing - nothing ran"; exit 2; }
out=$("$PWSH" -NoProfile -File "$SUITE" 2>&1); rc=$?
printf '%s\n' "$out"
n=$(printf '%s\n' "$out" | command grep -c '^ok  ')
f=$(printf '%s\n' "$out" | command grep -c '^FAIL')
if [ "$rc" -eq 0 ] && [ "$f" -eq 0 ] && [ "$n" -ge 21 ]; then
  say "PASS  clean: rc=0 ok=$n fail=0"
else
  say "FAIL  clean: rc=$rc ok=$n fail=$f"; exit 1
fi
