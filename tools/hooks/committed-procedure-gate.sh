#!/bin/bash
# committed-procedure-gate.sh — PreToolUse hook (Bash|Workflow|Agent)
# Blocks heavy rig mutations unless a recent Jev call explicitly quotes the committed procedure.
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
now=$(date +%s)

if [ ! -s "$WIRE" ]; then
  cat >&2 <<EOM
BLOCKED by committed-procedure-gate.sh: no Jev wire log.
Heavy path: $frag
Ask Jev with state containing "committed_procedure", the exact command, and the rejected short-cycle alternative.
EOM
  exit 2
fi

recent=$(awk -v frag="$frag" '
  line ~ /committed_procedure|use_committed|procedure_delta/ && (index(line, substr(frag,1,20))>0 || index(line,"quick-upgrade")>0) {print NR}
' "$WIRE" | tail -1)

if [ -z "${recent:-}" ]; then
  cat >&2 <<EOM
BLOCKED by committed-procedure-gate.sh: no recent Jev call quoting both the command and the committed alternative.
Heavy path: $frag
EOM
  exit 2
fi
exit 0
