#!/bin/bash
# matrix-logsweep-grade-selftest.sh - one condition, one tally entry; every number off the disk.
#
# WHY. matrix.sh grades each cell's guest-log sweep by its exit code. The first version read that
# code as a BOOLEAN and said "collection FAILED ... the campaign sweep has no guest logs for this
# cell" for any non-zero rc. The first cell it ran on returned rc=3 - its documented code for
# "collected, but something was empty or unparseable" - over ONE empty rotation placeholder, while
# 37 files and 2631 QWT-format lines sat in the output directory. The message asserted the opposite
# of what had happened, about the very cell that had never preserved anything before.
#
# These checks drive the real function (extracted from the shipped file, not a copy) through every
# documented exit code with a stub sweep, and assert two properties the eye cannot verify:
#   * a single condition adds EXACTLY ONE entry to the campaign tally, never two;
#   * every count in every message is the count of files actually on disk.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 2

T=$(mktemp -d "${TMPDIR:-/tmp}/matrix-logsweep-grade.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT INT TERM

M=$(ls mgmt/harness/matri*.sh | head -1)
# THE SHIPPED FUNCTION, not a transcription of it: a copy here would pass while the file rotted.
eval "$(sed -n '/^grade_cell_logsweep(){/,/^}$/p' "$M")"
declare -f grade_cell_logsweep >/dev/null || { echo "FAIL could not extract grade_cell_logsweep from $M"; exit 1; }
# ITS HELPER TOO. grade_cell_logsweep calls _matrix_logvol_state when a cell has zero QWT lines.
# Extracted and NOT stubbed: without it the zero-line path ran here with the helper simply absent -
# the command substitution failed, the message lost its clause, and every assertion still passed.
# A test that exercises a path whose helper is missing is testing the other half of the function.
eval "$(sed -n '/^_matrix_logvol_state(){/,/^}$/p' "$M")"
declare -f _matrix_logvol_state >/dev/null || { echo "FAIL could not extract _matrix_logvol_state from $M"; exit 1; }

CAMPAIGN_SINCE="2026-10-14T12:00:00Z"
pass=0; fail=0
ck(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1: expected '$2', got '$3'"; fi; }

# The campaign's own reporting functions, instrumented so the tally is observable.
LINES=""
say(){ LINES="$LINES$*"$'\n'; }
no(){ FAIL=$((FAIL+1)); case "$*" in *INVALID*) INVALID=$((INVALID+1)) ;; esac; say "[GRADED] $*"; }

# <rc> <files> <qwt-lines> -> sets FAIL/INVALID/LINES for one cell
run_case(){ local rc="$1" nf="$2" nq="$3"
  # Separate statement: bash expands every argument of `local` BEFORE assigning any of them, so
  # referring to nf/nq in the same declaration reads them unbound under set -u.
  local c="cell$rc-$nf-$nq"
  FAIL=0; INVALID=0; LINES=""
  mkdir -p "$T/$c-guestlogs/logs/files"
  local i=0
  while [ "$i" -lt "$nf" ]; do printf 'filler\n' > "$T/$c-guestlogs/logs/files/f$i.log"; i=$((i+1)); done
  if [ "$nq" -gt 0 ]; then
    : > "$T/$c-guestlogs/logs/files/agent.log"
    local j=0
    while [ "$j" -lt "$nq" ]; do printf '[20261014.150607.12%d-1234-E] a declared guest error\n' "$j" >> "$T/$c-guestlogs/logs/files/agent.log"; j=$((j+1)); done
  fi
  LOGSWEEP_CMD="$T/stub-$rc.sh" grade_cell_logsweep "$c" "someguest" "$T"
  CELL="$c"
}
# The stubs stand in for log-sweep.sh: its stdout is what the grader quotes, so the rc=3 stub
# prints the real shape of a missing-data line (taken from the 2026-10-14 campaign's own output).
for rc in 0 1 2 3 4; do
  printf '#!/bin/bash\n' > "$T/stub-$rc.sh"
  [ "$rc" = 3 ] && printf '%s\n' 'echo "log-sweep[win10-acc]: FAIL  missing or unparseable data - the sweep is not complete:   empty      Q:\\Qubes Logs\\etw-proxy.log.old: the collector found this log empty (0 lines)"' >> "$T/stub-$rc.sh"
  printf 'exit %d\n' "$rc" >> "$T/stub-$rc.sh"
  chmod +x "$T/stub-$rc.sh"
done

# rc=0 with real content: nothing raised.
run_case 0 3 2;  ck "rc=0 with guest lines raises nothing"        "0" "$FAIL"
                 ck "rc=0 reports the files it found"             "1" "$(printf '%s' "$LINES" | grep -c 'swept CLEAN (4 file(s), 2 QWT line(s))')"
# rc=0 with NOTHING to read: the dangerous false green, raised exactly once.
run_case 0 2 0;  ck "rc=0 with no QWT line raises BLIND once"     "1" "$FAIL"
                 ck "and it is classed INVALID"                   "1" "$INVALID"
# a finding must reach the tally as a product FAIL, not an INVALID.
run_case 1 3 2;  ck "rc=1 raises exactly one entry"               "1" "$FAIL"
                 ck "rc=1 is NOT classed INVALID"                 "0" "$INVALID"
# rc=3: one entry, and the detail is quoted from the sweep's own output.
run_case 3 3 2;  ck "rc=3 raises exactly one entry"               "1" "$FAIL"
                 ck "rc=3 quotes what was incomplete"             "1" "$(printf '%s' "$LINES" | grep -c 'etw-proxy.log.old')"
# rc=3 having collected NOTHING: still ONE entry, not one per symptom.
run_case 3 0 0;  ck "rc=3 with nothing collected raises ONE"      "1" "$FAIL"
# rc=4 and an undocumented rc: one entry each, and no claim about collection.
run_case 4 3 2;  ck "rc=4 raises exactly one entry"               "1" "$FAIL"
run_case 2 5 1;  ck "an undocumented rc raises exactly one entry" "1" "$FAIL"
                 ck "and does not claim collection failed"        "0" "$(printf '%s' "$LINES" | grep -ci 'collection failed')"
                 ck "and still states what is on disk"            "1" "$(printf '%s' "$LINES" | grep -c '6 file(s), 1 QWT line(s)')"

# EVERY COUNT MUST MATCH THE DISK, for every arm - the property the shipped message violated.
bad=0
for spec in "0 3 2" "1 4 1" "3 2 0" "4 6 3" "2 1 1"; do
  set -- $spec; run_case "$1" "$2" "$3"
  real_f=$(find "$T/$CELL-guestlogs" -type f | wc -l)
  real_q=$(grep -rhoaE '^\[[0-9]{8}\.[0-9]{6}\.[0-9]{3}-[0-9]+' "$T/$CELL-guestlogs/logs" 2>/dev/null | wc -l)
  printf '%s' "$LINES" | grep -q "$real_f file(s), $real_q QWT line(s)" || { bad=$((bad+1)); echo "   rc=$1: message does not state $real_f/$real_q"; }
done
ck "no arm's counts contradict the disk" "0" "$bad"

# ---- ZERO QWT LINES MUST NAME THE INSTRUMENT'S STATE -------------------------------------------
# On 2026-10-14 all four cells reported "guest logs incomplete (1 file(s), 0 QWT line(s))" and I
# went looking at the guest. The cause was the instrument every time: no volume attached on the
# clean path, and on the ISO path a clone with no QWT. A verdict that cannot tell "the guest wrote
# nothing" from "there was nothing to write to" is a verdict about nothing.
state_is(){ # <label> <expected fragment> ; uses M (the pull dir root) and LOGVOL_IMG as set by caller
  local got; got=$(_matrix_logvol_state "statecell")
  case "$got" in
    *"$2"*) pass=$((pass+1)); echo "ok   $1" ;;
    *)      fail=$((fail+1)); echo "FAIL $1: expected to contain '$2', got '$got'" ;;
  esac
}
SAVED_M="$M"; M="$T/state"; mkdir -p "$M"

LOGVOL_IMG=""
state_is "no volume attached is said plainly"      "no log volume was attached"

LOGVOL_IMG="$T/state/img"
state_is "a volume that was never pulled is said" "never pulled"

mkdir -p "$M/logvol-statecell/files"
state_is "attached but never bound is said"       "attached, never bound"

mkdir -p "$M/logvol-statecell/files/qwt-logs"
state_is "an EMPTY qwt-logs is said"              "qwt-logs is EMPTY"

printf 'not a qwt line\n' > "$M/logvol-statecell/files/qwt-logs/something.log"
state_is "files with no QWT shape are said"       "none in QWT's line shape"

M="$SAVED_M"

echo "matrix-logsweep-grade-selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
