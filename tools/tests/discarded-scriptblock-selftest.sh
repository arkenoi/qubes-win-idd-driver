#!/usr/bin/env bash
# discarded-scriptblock-selftest.sh - a bare `{ ... }` statement is dead code, and no grep sees it.
#
# WHY. guest/install-updater-agent.ps1 wrapped its relay compile/move in a bare brace pair. In
# PowerShell that is a ScriptBlock LITERAL - built, discarded, never executed - so the script logged
# "updater agent deployed" while the relay on disk stayed the one built 2026-09-16. Measured on
# win11de-tup: five passes each bound their OWN PID as the listen port (8228, 6688, 8892, 2540,
# 5956) with no `parent=` field, WinHTTP pointed at 8082, nothing served it, every pass went silent.
# The fix had been reported READY on offline legs and Jev scores alone - and those read source TEXT,
# which was entirely correct. `{ $ran = $true }` leaves $ran False.
#
# This is an AST check, not a pattern: a leading `{` is also every if/foreach/try body, every
# hashtable and every -ScriptBlock argument, so only the parser knows which braces form a statement
# whose value is thrown away. The first draft tested for a standalone ScriptBlockExpressionAst and
# reported every file clean while MISSING the shape just removed (a bare block is a PipelineAst
# wrapping a CommandExpressionAst) - the same class of error one level up. Hence the control: the
# suite FAILS unless the real shipped shape is detected, and unless 14 legitimate scriptblock uses
# stay clean, because a brace-counter would be turned off within a week.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUITE="$ROOT/tools/tests/discarded-scriptblock-test.ps1"
PWSH="$("$(dirname "$0")/pwsh-path.sh" || true)"
say() { printf '%s\n' "$*"; }
[ -x "$PWSH" ] || { say "FAIL  pwsh not found at $PWSH - nothing ran"; exit 2; }
[ -f "$SUITE" ] || { say "FAIL  $SUITE is missing - nothing ran"; exit 2; }
out=$("$PWSH" -NoProfile -File "$SUITE" 2>&1); rc=$?
printf '%s\n' "$out"
n=$(printf '%s\n' "$out" | command grep -c '^ok  ')
f=$(printf '%s\n' "$out" | command grep -c '^FAIL')
if [ "$rc" -eq 0 ] && [ "$f" -eq 0 ] && [ "$n" -ge 6 ]; then
  say "PASS  clean: rc=0 ok=$n fail=0"
else
  say "FAIL  clean: rc=$rc ok=$n fail=$f"; exit 1
fi
