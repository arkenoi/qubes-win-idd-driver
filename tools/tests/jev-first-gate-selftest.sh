#!/usr/bin/env bash
# jev-first-gate-selftest.sh - the gate must check WHICH decision was asked, not the clock.
#
# It allowed any launch with a Jev call in the last 60 min. Unrelated calls kept the window warm, so
# a workflow whose own fork was never asked went through: ~1.1M subagent tokens over three passes,
# 2026-10-17, answered afterwards in one call that invalidated the result.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
G="$ROOT/tools/hooks/jev-first-gate.sh"
[ -x "$G" ] || [ -f "$G" ] || { echo "FAIL  $G missing - nothing ran"; exit 2; }
D=$(mktemp -d); trap 'rm -rf -- "$D"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }

ANS='{"answers":{"fork":{"choice":"a","confidence":0.9}}}'
printf '%s' "$ANS" > "$D/fresh.json"
printf '%s' "$ANS" > "$D/stale.json"; touch -d '3 hours ago' "$D/stale.json"
printf 'not json'  > "$D/bogus.json"

rc(){ printf '%s' "$1" | CLAUDE_PROJECT_DIR="$ROOT" bash "$G" >/dev/null 2>"$D/err"; echo $?; }
wf(){ printf '{"tool_name":"Workflow","tool_input":{"script":"%s"}}' "$1"; }

# THE CASE THAT SLIPPED. A Jev call made seconds ago must NOT license a launch that names nothing.
printf '%s' "$ANS" > "$ROOT/scratchpad/jev-selftest-warm-out.json"
r=$(rc "$(wf 'export const meta={}')")
rm -f "$ROOT/scratchpad/jev-selftest-warm-out.json"
if [ "$r" = 2 ] && command grep -q 'names no Jev fork receipt' "$D/err"; then
    ok "unnamed: a warm window does not license a launch"
else bad "unnamed: rc=$r - the window-only hole is back"; fi

r=$(rc "$(wf "// JEV-FORK: $D/fresh.json")")
if [ "$r" = 0 ]; then ok "named+fresh: allowed"
else bad "named+fresh: rc=$r, $(head -1 "$D/err" | cut -c1-80)"; fi

r=$(rc "$(wf "// JEV-FORK: $D/absent.json")")
if [ "$r" = 2 ]; then ok "absent: a named receipt that does not exist is refused"
else bad "absent: rc=$r"; fi

r=$(rc "$(wf "// JEV-FORK: $D/bogus.json")")
if [ "$r" = 2 ]; then ok "bogus: a file with no answers map is refused"
else bad "bogus: rc=$r - any file would do"; fi

r=$(rc "$(wf "// JEV-FORK: $D/stale.json")")
if [ "$r" = 2 ]; then ok "stale: a receipt older than the window is refused"
else bad "stale: rc=$r"; fi

r=$(rc "$(printf '{"tool_name":"Agent","tool_input":{"model":"fable","prompt":"JEV-FORK: %s\\nwork"}}' "$D/fresh.json")")
if [ "$r" = 0 ]; then ok "fable agent: a named receipt in the prompt is allowed"
else bad "fable agent: rc=$r, $(head -1 "$D/err" | cut -c1-80)"; fi

r=$(rc '{"tool_name":"Agent","tool_input":{"model":"fable","prompt":"work"}}')
if [ "$r" = 2 ]; then ok "fable agent: unnamed is refused"
else bad "fable agent: rc=$r - Fable is gated too"; fi

r=$(rc '{"tool_name":"Agent","tool_input":{"model":"sonnet","prompt":"work"}}')
if [ "$r" = 0 ]; then ok "non-fable agent: not gated"
else bad "non-fable agent: rc=$r - the gate is for Workflow and Fable only"; fi

echo "jev-first-gate: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
