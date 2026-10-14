#!/bin/bash
# sweep-gate.sh - EVERY ERROR OUR OWN CODE DECLARES MUST BE ACCOUNTED FOR.
#
#   tools/sweep-gate.sh <log> [...]                       gate: fail on any unaccounted error/warning
#   tools/sweep-gate.sh --write-ledger <out> <log> [...]   seed the ledger from runs reviewed as clean
#
# Exit: 0 everything accounted for; 1 something is not; 2 nothing could be read.
#
# NO PATTERN GUESSING. Two earlier versions of this tool tried to recognise an error by its WORDS -
# a list of ERROR|FAIL|cannot|timeout|... that grew every time it missed something. It missed
#   "gui-agent.exe died within 10000 ms of starting, 2 time(s) in a row ... The guest has NO GUI
#    while this lasts ... (grant-table exhaustion, 0x5aa, needs a reboot)"
# because no word in that line was on the list, and it buried ten real findings under ~200 lines of a
# per-driver inventory because the hex pattern matched kernel load addresses. Jev scored that
# approach 0.07 for soundness. The owner: "NO FUCKING SHAPES. ALL error messages should be handled."
#
# OUR CODE ALREADY DECLARES SEVERITY, so there is nothing to guess. Every QWT log line is
#   [YYYYMMDD.HHMMSS.mmm-PID[:TID]-L] message
# with L one of D(ebug) I(nfo) W(arning) E(rror); the PowerShell and installer logs use
# [ERROR]/[WARN]/[WARNING]. On one update run that is exactly 886 I, 248 W and 9 E lines - the set
# the writers themselves classified, not a set I pattern-matched into existence.
#
# THE RULE: every declared E and W line is extracted, reduced to its MESSAGE (the volatile prefix,
# hex and numbers are not part of a message), and must appear in a committed ledger. A message with
# no entry is surfaced. An entry means someone read that error and recorded what it means; it is a
# disposition for ONE message, not a silencer for a class. A message that is a real defect does not
# belong in the ledger - it gets fixed, stays out, and surfaces again next run until it is gone.
#
# LINES WITH NO DECLARED LEVEL ARE COUNTED AND NAMED, never ignored. Bash harnesses do not emit a
# level yet, so that count is the honest size of what this tool cannot judge - and the lever for
# making them emit one.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 2

WRITE=""; VERIFY=0
if [ "${1:-}" = "--write-ledger" ]; then WRITE="${2:?--write-ledger needs an output path}"; shift 2; fi
if [ "${1:-}" = "--verify" ]; then VERIFY=1; shift; fi
[ $# -ge 1 ] || [ "$VERIFY" = 1 ] || { echo "usage: $0 [--verify] [--write-ledger <out>] <log> [...]" >&2; exit 2; }
LEDGER="${SWEEP_GATE_LEDGER:-mgmt/harness/error-ledger.txt}"

QWT='^\[[0-9]{8}\.[0-9]{6}\.[0-9]{3}-[0-9]+(:[0-9]+)?-'
# SWEEP_GATE_DEFECT drops the W class, so the self-test can show that reading only E misses the
# gui-agent crash loop - which is a W line. That is the failure this design exists to prevent.
if [ "${SWEEP_GATE_DEFECT:-}" = "1" ]; then                     # GUARD:levels
  LEVELS="${QWT}E\\]|\\[ERROR\\]"
else
  LEVELS="${QWT}[WE]\\]|\\[(ERROR|WARN|WARNING)\\]"
fi
ANYLEVEL="${QWT}[DIWE]\\]|\\[(ERROR|WARN|WARNING|INFO|DEBUG)\\]"

# Reduce a line to its message. Hex FIRST, so 0x887a0026 does not become NxNaN.
message() {
    sed -E \
        -e 's/0x[0-9A-Fa-f]+/<HEX>/g' \
        -e 's/^\[[0-9]{8}\.[0-9]{6}\.[0-9]{3}-[0-9]+(:[0-9]+)?-[DIWE]\][[:space:]]*//' \
        -e 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9:.]+[[:space:]]*//' \
        -e 's/^\[?[0-9]{2}:[0-9]{2}:[0-9]{2}\]?[[:space:]]*//' \
        -e 's#[A-Za-z]:\\[^ ,;)]+#<PATH>#g' \
        -e 's#/[A-Za-z0-9._/-]{8,}#<PATH>#g' \
        -e 's/\b(WIN|Win)[0-9]+[a-z]*-[a-z0-9]+/<CELL>/g' \
        -e 's/\bwin[0-9]+[a-z]*-[a-z0-9]+\b/<VM>/g' \
        -e 's/\b[0-9]+\b/N/g' \
        -e 's/[[:space:]]+/ /g' -e 's/^ //; s/ $//'
}

# `|| true` on the grep: it returns 1 for a file with no matches, and under `set -o pipefail` that
# made the whole loop fail and this tool exit 2 with NO OUTPUT, depending only on whether the LAST
# file happened to contain one. 20 logs reported findings; 130 reported nothing. Measured 2026-10-14.
declared() { for l in "$@"; do [ -f "$l" ] || { echo "sweep-gate: $l does not exist" >&2; return 2; }
               grep -ahE "$LEVELS" "$l" 2>/dev/null || true; done | message | sort | uniq -c \
             | sed -E 's/^[[:space:]]*([0-9]+)[[:space:]]+/\1 /'; }

unlevelled() { local n=0 t=0 a b
    for l in "$@"; do
        a=$(grep -ac . "$l" 2>/dev/null || true)
        # BOTH counts over the same population - non-empty lines. Counting `without` over every line
        # including blanks made with_declared_level go NEGATIVE (-20) on a real set of logs.
        b=$(grep -a . "$l" 2>/dev/null | grep -avcE "$ANYLEVEL" || true)
        t=$((t + ${a:-0})); n=$((n + ${b:-0}))
    done
    echo "${n:-0} ${t:-0}"; }

if [ -n "$WRITE" ]; then
    { echo "# error-ledger.txt - every ERROR and WARNING our code DECLARED on runs reviewed as clean,"
      echo "# with the count seen. Seeded $(date -u +%Y-%m-%dT%H:%M:%SZ) from: $*"
      echo "#"
      echo "# sweep-gate.sh surfaces any declared error or warning NOT listed here. An entry means"
      echo "# someone READ that error and recorded what it means - a disposition for one message, not"
      echo "# a silencer for a class. A message that is a real defect does NOT belong here: it gets"
      echo "# fixed and stays out, so every run surfaces it until it is gone."
      declared "$@" | sed -E 's/$/   # TODO: why is this not a defect? an empty note does NOT account for it/' 
    } > "$WRITE" || exit 2
    echo "SWEEP-GATE-LEDGER wrote $(grep -vc '^#' "$WRITE") declared message(s) to $WRITE"
    exit 0
fi

# --verify: MEASURED AGAINST AN EXTERNAL CORPUS, NOT AGAINST ITSELF.
#
# The first version of this mode counted the lines its own $LEVELS regex matched and compared that
# to the lines its reporting path emitted. Both sides used the same regex, so it could only ever
# prove the tool does not drop what it already matched. Run on the incident that this whole tool
# exists to prevent - `WARNING log-volume bind failed` - it printed EXHAUSTIVE while MISSING that
# line, because the line carries no bracketed level. A self-consistent green over the motivating
# defect. Deleted 2026-10-14.
#
# Ground truth now comes from mgmt/harness/error-corpus.txt: lines quoted from defect entries that
# were filed BEFORE this tool existed. RECALL below 100% fails - a gate that misses a real error is
# not a gate. Precision is reported too, because the version before last flagged explanatory prose
# and buried ten real findings under it.
if [ "$VERIFY" = 1 ]; then
    CORPUS="${SWEEP_GATE_CORPUS:-mgmt/harness/error-corpus.txt}"
    [ -f "$CORPUS" ] || { echo "sweep-gate: REFUSING - no corpus at $CORPUS; there is nothing to measure against" >&2; exit 2; }
    el=$(mktemp); printf '# empty ledger\n' > "$el"
    tl=$(mktemp); miss=$(mktemp); fp=$(mktemp)
    nmust=0; nben=0; ok=0; okb=0
    while IFS=$'\t' read -r verdict tag line; do
        case "$verdict" in MUST|BENIGN) ;; *) continue ;; esac
        printf '%s\n' "$line" > "$tl"
        # NO PIPE INTO grep -q HERE. Under `set -o pipefail` grep -q exits on the first match,
        # SIGPIPEs the producer, and the PIPELINE returns 141 - never grep's status. That made this
        # very check report recall 0/13 including lines it does in fact catch. Documented
        # 2026-08-31, hit again 2026-10-14 on a live guest, and again here. Capture, then match.
        out=$(SWEEP_GATE_LEDGER="$el" "$0" "$tl" 2>/dev/null)
        case "$out" in *"  UNACCOUNTED"*) surfaced=1 ;; *) surfaced=0 ;; esac
        if [ "$verdict" = MUST ]; then
            nmust=$((nmust+1))
            if [ "$surfaced" = 1 ]; then ok=$((ok+1)); else printf '  MISSED  [%s] %s\n' "$tag" "$(printf '%s' "$line" | cut -c1-104)" >> "$miss"; fi
        else
            nben=$((nben+1))
            if [ "$surfaced" = 0 ]; then okb=$((okb+1)); else printf '  FLAGGED [%s] %s\n' "$tag" "$(printf '%s' "$line" | cut -c1-104)" >> "$fp"; fi
        fi
    done < <(grep -av '^#' "$CORPUS")
    rm -f "$el" "$tl"
    # A corpus that did not load compares 0 with 0 and looks perfect. It is INCONCLUSIVE, never a pass:
    # the first hand-run of this check printed EXHAUSTIVE on two empty counts because bc was missing.
    if [ "$nmust" -eq 0 ]; then
        echo "SWEEP-GATE-VERIFY INCONCLUSIVE: the corpus yielded no MUST line - nothing was measured."
        rm -f "$miss" "$fp"; exit 2
    fi
    rec=$(awk -v a="$ok" -v b="$nmust" 'BEGIN{printf "%.0f", 100*a/b}')
    pre=$(awk -v a="$okb" -v b="$nben" 'BEGIN{if(b==0){print "n/a"}else{printf "%.0f", 100*a/b}}')
    echo "SWEEP-GATE-VERIFY recall=${ok}/${nmust} (${rec}%) precision=${okb}/${nben} (${pre}%) corpus=$CORPUS"
    [ -s "$miss" ] && { echo "REAL ERRORS THIS GATE WOULD NOT HAVE SURFACED:"; cat "$miss"; }
    [ -s "$fp" ] && { echo "BENIGN LINES IT WOULD HAVE RAISED (noise that buries the real ones):"; cat "$fp"; }
    r=0; [ "$ok" -lt "$nmust" ] && r=1; [ -s "$fp" ] && r=1
    rm -f "$miss" "$fp"
    [ "$r" = 0 ] && echo "  SOUND: every filed defect's own log line is surfaced, no benign line is."
    exit $r
fi

[ -f "$LEDGER" ] || { echo "sweep-gate: REFUSING - no ledger at $LEDGER (seed it with --write-ledger)" >&2; exit 2; }
NOW=$(mktemp); declared "$@" > "$NOW" || { rm -f "$NOW"; exit 2; }
LD=$(mktemp); grep -vE '^\s*(#|$)' "$LEDGER" > "$LD" || true

# NOTHING IS EVER HIDDEN. A ledger entry does NOT remove a message from the report; it only decides
# whether that message BLOCKS. Every declared error and warning in the run is printed, every time,
# under ACCOUNTED or UNACCOUNTED. The previous design dropped accounted messages from the output
# entirely, which is a standing silencer: a genuine error that recurs for months reads as silence,
# and that is the flaw that killed this instrument's two predecessors (judged 0.96 likely).
#
# AN ENTRY WITHOUT A RECORDED DISPOSITION DOES NOT ACCOUNT FOR ANYTHING. A ledger row is
#   <count> <message>   # <why this is not a defect>
# and a row with no `#` note is treated as UNACCOUNTED, so a message cannot be silenced by pasting
# it into the ledger - somebody has to write down what it means.
newn=0; rose=0; acc=0
ACCLIST=$(mktemp)
while IFS= read -r row; do
    [ -n "$row" ] || continue
    cnt=${row%% *}; msg=${row#* }
    led=$(grep -aF -- " $msg" "$LD" | head -1)
    base=$(printf '%s' "$led" | sed -E 's/^([0-9]+) .*/\1/')
    note=$(printf '%s' "$led" | sed -nE 's/.*#[[:space:]]*(.+)$/\1/p')
    # A TODO is not a reason. The seeder writes one into every row it creates, so without this the
    # act of seeding a ledger would account for every error in the run it was seeded from - which is
    # precisely the silencing this redesign removed, reintroduced through the back door.
    case "$note" in TODO*|todo*|XXX*|FIXME*) note="" ;; esac
    if [ -z "$base" ] || [ -z "$note" ]; then
        [ "$newn" = 0 ] && [ "$rose" = 0 ] && echo "SWEEP-GATE: declared error/warning not accounted for:"
        newn=$((newn+1))
        if [ -n "$base" ] && [ -z "$note" ]; then
            printf '  UNACCOUNTED x%-4s %s\n     (a ledger row exists but records no reason - that is not an account)\n' "$cnt" "$(printf '%s' "$msg" | cut -c1-140)"
        else
            printf '  UNACCOUNTED x%-4s %s\n' "$cnt" "$(printf '%s' "$msg" | cut -c1-140)"
        fi
    elif [ "$cnt" -gt "$((base * 2))" ] && [ "$cnt" -gt $((base + 3)) ]; then
        [ "$newn" = 0 ] && [ "$rose" = 0 ] && echo "SWEEP-GATE: declared error/warning not accounted for:"
        rose=$((rose+1)); printf '  ROSE        x%-4s (ledger x%s) %s\n' "$cnt" "$base" "$(printf '%s' "$msg" | cut -c1-120)"
    else
        acc=$((acc+1)); printf '  ACCOUNTED   x%-4s %s\n     -> %s\n' "$cnt" "$(printf '%s' "$msg" | cut -c1-110)" "$(printf '%s' "$note" | cut -c1-110)" >> "$ACCLIST"
    fi
done < "$NOW"
# printed ALWAYS, pass or fail, so a recurring known error stays visible instead of becoming silence
if [ "$acc" -gt 0 ]; then
    echo "SWEEP-GATE: $acc declared error/warning message(s) accounted for by $LEDGER (shown, not hidden):"
    cat "$ACCLIST"
fi
rm -f "$ACCLIST"
rm -f "$NOW" "$LD"

read -r nolevel total < <(unlevelled "$@")
echo "SWEEP-GATE-COVERAGE lines=$total with_declared_level=$((total - nolevel)) without=$nolevel"
[ "${nolevel:-0}" -gt 0 ] && echo "  $nolevel line(s) carry NO declared level, so this tool cannot judge them. That is the gap, named."

if [ "$newn" -gt 0 ] || [ "$rose" -gt 0 ]; then
    echo "SWEEP-GATE-RESULT unaccounted=$newn risen=$rose accounted=$acc"
    echo "  Each is a real error our code declared. It is a defect to fix, or an entry for $LEDGER"
    echo "  recording what it means. Reading it and moving on is not one of the options."
    exit 1
fi
echo "SWEEP-GATE-RESULT unaccounted=0 risen=0 accounted=$acc"
