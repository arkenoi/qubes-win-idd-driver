#!/bin/bash
# committed-procedure-gate.sh — PreToolUse hook (Bash|Workflow|Agent)
# Blocks heavy rig mutations unless a recent Jev call explicitly quotes the committed procedure.
# Exception: recreate-goldens sequence when no golden exists (docs/PROCEDURE-recreate-goldens.md).
set -u
WINDOW_MIN="${COMMITTED_PROC_WINDOW_MIN:-15}"
ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
WIRE="${JEV_WIRE_LOG:-$ROOT/scratchpad/jev-wire.jsonl}"
HEAVY='prime-run\.sh|reprovision-usb\.sh|matrix\.sh|seal-qwt-golden|build-media\.sh|clone-to-template'

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
recent=$(awk -v frag="$frag" '
  line ~ /committed_procedure|use_committed|procedure_delta/ && (index(line, substr(frag,1,20))>0 || index(line,"quick-upgrade")>0) {print NR}
' "$WIRE" | tail -1)

# Exception: recreate-goldens sequence (no short-cycle alternative exists)
if [ -z "${recent:-}" ]; then
  recent=$(awk '
    line ~ /recreate_goldens|PROCEDURE-recreate-goldens/ {print NR}
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
