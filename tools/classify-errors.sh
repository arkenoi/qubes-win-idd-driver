#!/bin/bash
# classify-errors.sh - have JEV classify each unaccounted declared error, with the EMITTING CODE in
# evidence, instead of a model writing a plausible reason into the ledger.
#
#   tools/classify-errors.sh <sweep-gate output> [max]
#
# WHY. The first ledger was written in one batch by pattern-matching explanations onto 18 messages
# without reading the code that emits any of them. The largest entry was wrong: x102 "inverted DWM
# bounds - rejecting" was called correct-but-over-logged, while agent/gui-agent/main.c:1583 logs it
# at WARNING precisely because it is the NON-routine case and the window is REJECTED. Jev scored the
# hiding risk 0.65 for that batch. Deciding whether a logged condition is handled or is a defect is
# a classification, and this project's rule is that a classification belongs to Jev.
#
# Output is a ledger-shaped line per message that Jev classed HANDLED, each carrying the file:line
# the classification was made from. A DEFECT or an UNDECIDED message gets no line, so it keeps
# surfacing. Nothing here writes the ledger - a human pastes what they accept.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
SW="${1:?usage: $0 <sweep-gate output> [max]}"
MAX="${2:-8}"
[ -s "$SW" ] || { echo "classify: $SW is empty - nothing to classify" >&2; exit 2; }

RUB=$(mktemp); OUTD=$(mktemp -d); trap 'rm -rf "$RUB" "$OUTD"' EXIT
cat > "$RUB" <<'J'
{"questions":{"klass":{"type":"choice",
 "instructions":{"judge":"A Windows guest agent logged this line at Error or Warning. The emitting code is quoted. Decide what the line IS, from the code and not from how the message reads."},
 "criteria":{
  "handled":"the site detects a condition it is designed to detect and handles it - a retry, a documented default, a normal teardown, a deliberate rejection of input that cannot be used - so the line is a report, not a failure of the product",
  "defect":"the line reports the product failing to do its job, or a fallback firing, or state being lost; it must keep surfacing until fixed",
  "overlogged":"the condition is genuinely routine and handled, but logging it at Error/Warning is itself wrong - it belongs at Info or Debug, and the fix is the log level",
  "undecided":"the quoted code is not enough to tell"}}}}
J

n=0
grep -aE '^  UNACCOUNTED x[0-9]+' "$SW" | while IFS= read -r row; do
  [ "$n" -ge "$MAX" ] && break
  cnt=$(printf '%s' "$row" | sed -E 's/^  UNACCOUNTED x([0-9]+).*/\1/')
  msg=$(printf '%s' "$row" | sed -E 's/^  UNACCOUNTED x[0-9]+ +//')
  fn=${msg%%:*}
  # the emitter: first file that names the function, and the lines around the matching log call
  src=$(grep -rln --include=*.c --include=*.cpp --include=*.h -- "$fn" agent core-agent 2>/dev/null | head -1)
  [ -n "$src" ] || { echo "SKIP x$cnt $fn - emitter not in our source"; continue; }
  # THE KEY IS THE LONGEST LITERAL RUN OF WORDS IN THE MESSAGE, taken from the message as logged.
  # Two earlier attempts failed on the same line: cutting at the first placeholder gave an EMPTY key
  # for "GetRealWindowRect: <HEX>: inverted DWM bounds ...", and dropping words shorter than four
  # characters built "GetRealWindowRect inverted bounds usable", which matches nothing because the
  # source says "inverted DWM bounds (%d,%d)... and no usable GetWindowRect". Both times the lookup
  # fell back to the function name, matched line 1, and Jev was handed a file header - answering
  # "undecided" about nothing, which is the worst outcome available: a judgement that looks real.
  key=$(KMSG="$msg" python3 - <<'PYK'
import os, re
m = os.environ["KMSG"]
m = re.sub(r'<[A-Z]+>', ' ', m)                      # placeholders the normaliser put in
m = re.sub(r'\([0-9N,\- ]*\)', ' ', m)               # (N,N)-(N,N) coordinate groups
runs = [r.strip() for r in re.split(r'[^A-Za-z ]+|\s{2,}', m)]
runs = [r for r in runs if len(r.split()) >= 2 and len(r) >= 12]
print(max(runs, key=len) if runs else "")
PYK
)
  ln=""
  [ -n "$key" ] && ln=$(grep -nF -- "$key" "$src" 2>/dev/null | head -1 | cut -d: -f1)
  [ -n "$ln" ] || ln=$(grep -nE "Log(Error|Warning).*$fn|$fn.*Log(Error|Warning)" "$src" 2>/dev/null | head -1 | cut -d: -f1)
  [ -n "$ln" ] || { echo "SKIP x$cnt $fn - cannot locate the emitting line in $src (key='$key'), so there is no evidence to judge"; continue; }
  st="$OUTD/state.txt"
  { echo "THE LOGGED LINE, seen $cnt time(s) across one campaign's guest logs:"
    echo "  $msg"
    echo
    echo "THE EMITTING CODE, $src around line $ln (comments included - they often state the intent):"
    sed -n "$((ln>20?ln-20:1)),$((ln+12))p" "$src"
  } > "$st"
  v=$(python3 tools/jev.py "$RUB" "$st" 2>&1 | tail -1)
  echo "x$cnt  $fn  ($src:$ln)  -> $v"
  n=$((n+1))
done
