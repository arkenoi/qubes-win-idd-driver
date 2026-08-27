#!/bin/bash
# Per-phase p50s from a bench-agent.sh run: derives each phase's time window from the
# "### PHASE-START/END <name> <agent-log-timestamp>" lines in <label>.txt.harness and
# runs analyze-perf.py restricted to that window. Companion to tools/bench-agent.sh.
set -uo pipefail
LABEL="${1:?usage: $0 <label>}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HERE/instrumentation/bench-$LABEL.txt"
[[ -f "$OUT" && -f "$OUT.harness" ]] || { echo "missing $OUT(.harness)"; exit 1; }
grep -oE '### PHASE-(START|END) +[a-z0-9-]+ +[0-9.]+' "$OUT.harness" |
awk '{ if ($2=="PHASE-START") s[$3]=$4; else e[$3]=$4 }
     END { for (p in s) if (p in e) print p, s[p], e[p] }' |
while read -r phase since until_; do
    p50=$(python3 "$HERE/instrumentation/analyze-perf.py" --since "$since" --until "$until_" "$OUT" 2>/dev/null |
          awk '/^   tot /{print $3; exit}')
    n=$(python3 "$HERE/instrumentation/analyze-perf.py" --since "$since" --until "$until_" "$OUT" 2>/dev/null |
        grep -oE 'records=[0-9]+' | head -1 | cut -d= -f2)
    printf '%-10s tot_p50=%-8s records=%s\n' "$phase" "${p50:-?}us" "${n:-0}"
done | sort
