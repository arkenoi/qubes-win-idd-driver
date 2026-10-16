#!/bin/bash
# committed-procedure-gate.sh — PreToolUse hook (Bash|Workflow|Agent)
# Blocks heavy rig mutations unless a recent Jev call explicitly quotes the committed procedure.
# Exception: recreate-goldens sequence when no golden exists (docs/PROCEDURE-recreate-goldens.md).
set -u
WINDOW_MIN="${COMMITTED_PROC_WINDOW_MIN:-15}"
ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
WIRE="${JEV_WIRE_LOG:-$ROOT/scratchpad/jev-wire.jsonl}"
# EVERY ENTRY POINT, NOT JUST THE INNERMOST ONE. This listed matrix.sh but none of the wrappers
# that CALL it, and the gate reads the command IT is asked to allow - not the processes that
# command later spawns. MEASURED 2026-10-16: a full 8-cell acceptance campaign - the heaviest path
# on this rig, four hours of exclusive time and the operator's screen - was launched through
# release-acceptance.sh inside a wrapper script, and this gate never fired, so the heaviest action
# available went without the committed-procedure Jev call that its own inner step requires. One
# level of indirection defeated it. Driven by tools/tests/committed-procedure-gate-selftest.sh.
HEAVY='prime-run\.sh|reprovision-usb\.sh|matrix\.sh|seal-qwt-golden|build-media\.sh|clone-to-template'
HEAVY="$HEAVY|release-acceptance\.sh|campaign-run\.sh|gate-remainder\.sh"

input=$(cat)
cmd=$(printf '%s' "$input" | python3 -c '
import json,sys
try: o=json.loads(sys.stdin.read() or "{}")
except Exception: print(""); sys.exit(0)
tool=o.get("tool_name","")
ti=o.get("tool_input") or {}
if tool=="Bash": print(ti.get("command",""))
elif tool in ("Workflow","Agent"): print(str(ti.get("prompt") or ti.get("description") or ""))
else: print("")
')

if ! echo "$cmd" | grep -qE "$HEAVY"; then exit 0; fi

frag=$(echo "$cmd" | head -c 80 | tr -d "\"'\\n" | sed 's/  */ /g')

if [ ! -s "$WIRE" ]; then
  cat >&2 <<EOM
BLOCKED by committed-procedure-gate.sh: no Jev wire log.
Heavy path: $frag
Ask Jev with state containing "committed_procedure", the exact command, and the rejected short-cycle alternative.
If no golden exists, use the recreate-goldens sequence (docs/PROCEDURE-recreate-goldens.md) and include the marker recreate_goldens.
EOM
  exit 2
fi

# Normal case: command fragment + committed-procedure marker (or quick-upgrade mention)
# THE PERMIT MUST NAME THIS COMMAND. It used to accept a line that named the command OR merely
# mentioned "quick-upgrade" - and since a well-formed permit is REQUIRED to state the rejected
# short-cycle alternative, which is quick-upgrade, that clause was satisfied by EVERY valid permit.
# So the command binding was inert: a permit obtained for prime-run authorised a full 8-cell
# campaign, measured 2026-10-16 by tools/tests/committed-procedure-gate-selftest.sh. The mention of
# the alternative is evidence it was considered; it is not a substitute for naming the command.
recent=$(awk -v frag="$frag" '
  $0 ~ /committed_procedure|use_committed|procedure_delta/ && index($0, substr(frag,1,20))>0 {print NR}
' "$WIRE" | tail -1)

# Exception: recreate-goldens sequence (no short-cycle alternative exists)
if [ -z "${recent:-}" ]; then
  recent=$(awk '
    $0 ~ /recreate_goldens|PROCEDURE-recreate-goldens/ {print NR}
  ' "$WIRE" | tail -1)
fi

if [ -z "${recent:-}" ]; then
  cat >&2 <<EOM
BLOCKED by committed-procedure-gate.sh: no recent Jev call quoting both the command and the committed alternative.
Heavy path: $frag
If no golden exists, ask Jev with state containing recreate_goldens and the commands from docs/PROCEDURE-recreate-goldens.md.
EOM
  exit 2
fi
exit 0
