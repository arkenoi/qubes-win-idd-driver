#!/usr/bin/env bash
# the installer ENDS our update tasks before msiexec, so no death toast blames our own install.
# run: tools/tests/upd-task-prestop-selftest.sh
# pass: exit 0
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUITE="$ROOT/tools/tests/upd-task-prestop-test.ps1"
# pwsh FROM THE PATH FIRST, dev-qube paths as fallbacks - the same resolution
# tools/tests/death-reporter-selftest.sh uses, so this behaves identically on a CI runner (where
# the workflow already uses `shell: pwsh`) and on this qube.
PWSH="$("$(dirname "$0")/pwsh-path.sh" || true)"
say() { printf '%s\n' "$*"; }
[ -x "$PWSH" ] || { say "FAIL  pwsh not found at $PWSH - nothing ran"; exit 2; }
[ -f "$SUITE" ] || { say "FAIL  $SUITE is missing - nothing ran"; exit 2; }

out=$("$PWSH" -NoProfile -File "$SUITE" 2>&1); rc=$?
printf '%s\n' "$out"
n=$(printf '%s\n' "$out" | command grep -c '^ok  ')
f=$(printf '%s\n' "$out" | command grep -c '^FAIL')
if [ "$rc" -eq 0 ] && [ "$f" -eq 0 ] && [ "$n" -ge 9 ]; then
  say "PASS  clean: rc=0 ok=$n fail=0"
else
  say "FAIL  clean: rc=$rc ok=$n fail=$f"
  exit 1
fi
