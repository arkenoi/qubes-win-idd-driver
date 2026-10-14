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

WRITE=""; VERIFY=0; CENSUS=0; SILENT=0
if [ "${1:-}" = "--write-ledger" ]; then WRITE="${2:?--write-ledger needs an output path}"; shift 2; fi
if [ "${1:-}" = "--verify" ]; then VERIFY=1; shift; fi
if [ "${1:-}" = "--census" ]; then CENSUS=1; shift; fi
if [ "${1:-}" = "--silent-failures" ]; then SILENT=1; shift; fi
[ $# -ge 1 ] || [ "$VERIFY" = 1 ] || { echo "usage: $0 [--verify] [--census] [--write-ledger <out>] <log> [...]" >&2; exit 2; }
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
#
# TWO THINGS ARE DELIBERATELY KEPT, because normalising them merges distinct failures:
#
#   the ESCALATION COUNT. "died within 10000 ms of starting, 1 time(s) in a row" and "... 2
#   time(s) in a row" were ONE message, so a crash loop escalating was invisible. Measured on 257
#   declared lines from a real campaign: this splits exactly 1 message, 27 -> 28. Small and real.
#
#   the ERROR CODE in an error-code position - after "error", "with error", "status", "rc=". A bare
#   hex is NOT a code: 0x1009a in "GetRealWindowRect: 0x1009a: inverted DWM bounds" is a window
#   HANDLE, and 82 windows hitting one condition is one message, not 82. Keeping every hex took 27
#   messages to 183 and would bury the real findings under handles - which is how the FIRST design
#   of this tool failed. Keeping only codes had NO measured effect on these logs (27 -> 27); it is
#   insurance so that "failed with error 0x6d" and "failed with error 0x5aa" can never merge, not
#   a fix for anything observed here. Said plainly rather than claimed as a win.
#
# The placeholders are LETTER-indexed. A digit-indexed one gets eaten by the \b[0-9]+\b rule below,
# which silently dropped the kept values and made the first measurement of this read "no change".
message() {
    # Python, not sed: the two kept fields need placeholders, and \x01 in a sed REPLACEMENT is not
    # portable - both substitutions silently did nothing, the handles merged correctly and the
    # escalation count and error codes did not, which looked like a working change.
    python3 -c '
import re, sys, string
LET = string.ascii_uppercase + string.ascii_lowercase
CODE = re.compile(r"((?:failed with error|with error|with code|exit(?:ed)? code|error|status|code|rc)[ =:]+)(0x[0-9A-Fa-f]+|\d+)", re.I)   # an EXIT code is as diagnostic as an error code:
#   "Process (PID N) exited with code <HEX>" showed 3 distinct values merged into one message
ESC  = re.compile(r"(\d+)(\s*time\(s\) in a row)")
for line in sys.stdin:
    l, holes = line.rstrip("\n"), []
    # LOCALE INDEPENDENCE. win_perror2 renders a Win32 code through FormatMessage, which uses the
    # SYSTEM locale, so the same error reads "Die Pipe wurde beendet." on a German guest and "The
    # pipe has been ended." on an English one. Keying a ledger on that sentence makes the
    # disposition locale-dependent - it would simply miss on the other guest, and the error would
    # come back unaccounted with its reason orphaned. The CODE is the locale-independent identity
    # and is kept above, so the rendered sentence is replaced. (The product itself does not MATCH on
    # localised text - checked - and making win_perror2 emit English regardless of locale is not
    # possible from this tree: it lives in windows-utils, which this repository does not contain.)
    l = re.sub(r"((?:error|code|status)[ =:]+(?:0x[0-9A-Fa-f]+|\d+): ).*$", r"\1<OSMSG>", l)
    # ^ runs BEFORE the code is protected: once CODE.sub has replaced it with a placeholder there is
    #   no literal hex left for this rule to anchor on, so it silently did nothing and orphaned a
    #   ledger row. The orphaned-row report is what caught that.
    def mk(v):
        holes.append(v)
        return "\x00" + LET[(len(holes) - 1) % len(LET)] + "\x00"
    l = CODE.sub(lambda m: m.group(1) + mk(m.group(2)), l)
    l = ESC.sub(lambda m: mk(m.group(1)) + m.group(2), l)
    l = re.sub(r"0x[0-9A-Fa-f]+", "<HEX>", l)
    l = re.sub(r"^\[\d{8}\.\d{6}\.\d{3}-\d+(:\d+)?-[DIWE]\]\s*", "", l)
    l = re.sub(r"^\d{4}-\d{2}-\d{2}[ T][\d:.]+\s*", "", l)
    l = re.sub(r"^\[?\d{2}:\d{2}:\d{2}\]?\s*", "", l)
    l = re.sub(r"[A-Za-z]:\\[^ ,;)]+", "<PATH>", l)
    l = re.sub(r"/[A-Za-z0-9._/-]{8,}", "<PATH>", l)
    l = re.sub(r"\b(WIN|Win)[0-9]+[a-z]*-[a-z0-9]+", "<CELL>", l)
    l = re.sub(r"\bwin[0-9]+[a-z]*-[a-z0-9]+\b", "<VM>", l)
    l = re.sub(r"\b\d+\b", "N", l)
    l = re.sub(r"\s+", " ", l).strip()
    for i, v in enumerate(holes):
        l = l.replace("\x00" + LET[i % len(LET)] + "\x00", v)
    # second field: the line with only the timestamp prefix removed. Merging is correct for
    # counting, but it IS information loss, so the number of DISTINCT lines behind a message is
    # carried through and printed. 82 window handles collapsing to one message is the right
    # aggregation; "82 distinct" in the report is what stops that aggregation from hiding them.
    raw = re.sub(r"^\[\d{8}\.\d{6}\.\d{3}-\d+(:\d+)?-[DIWE]\]\s*", "", line.rstrip("\n"))
    print(l + "\t" + re.sub(r"\s+", " ", raw).strip())
'
}

# `|| true` on the grep: it returns 1 for a file with no matches, and under `set -o pipefail` that
# made the whole loop fail and this tool exit 2 with NO OUTPUT, depending only on whether the LAST
# file happened to contain one. 20 logs reported findings; 130 reported nothing. Measured 2026-10-14.
# <count> <message>, ledger-compatible. VARIANTS writes "<distinct> <message>" beside it when a
# path is given, so the report can say how many distinct lines a merged message stands for.
# IT MUST NOT READ ITS OWN REPORT. The report QUOTES the messages it found, so a bracketed one -
# "[ERROR] DISM rc=3010 state_after=Not Present" - is still a declared line when the report is
# swept, and comes back as "UNACCOUNTED x1 UNACCOUNTED x1 [ERROR] DISM ...". matrix.sh globs
# "$M"/*.out for the campaign sweep and writes its report to "$M"/sweep-gate.out, so on any re-run
# the campaign gained PHANTOM findings - in a gate that raises INVALID and blocks a release.
# Measured, not theorised: one real error became two. Detected by content, not filename, so it
# holds however a caller names the file.
_is_own_report() { head -c 4000 "$1" 2>/dev/null | grep -qa 'SWEEP-GATE-\(RESULT\|COVERAGE\|CENSUS\|SILENT\|LEDGER\|VERIFY\)'; }

declared() { local vfile="${SWEEP_GATE_VARIANTS:-}" skipped=0
             for l in "$@"; do [ -f "$l" ] || { echo "sweep-gate: $l does not exist" >&2; return 2; }
               _is_own_report "$l" && { skipped=$((skipped+1)); continue; }
               grep -ahE "$LEVELS" "$l" 2>/dev/null || true; done | message \
             | VFILE="$vfile" DUMPFILE="${SWEEP_GATE_DUMP:-}" python3 -c '
import collections, os, sys
occ, var = collections.Counter(), collections.defaultdict(set)
for line in sys.stdin:
    parts = line.rstrip("\n").split("\t", 1)
    msg = parts[0]
    occ[msg] += 1
    if len(parts) > 1: var[msg].add(parts[1])
for m in sorted(occ):
    print("%d %s" % (occ[m], m))
vf = os.environ.get("VFILE") or ""
if vf:
    with open(vf, "w", encoding="utf-8") as fh:
        for m in sorted(occ): fh.write("%d %s\n" % (len(var[m]), m))
# GROUPING MUST NOT BE LOSSY. Merging 82 window handles into one message is the right aggregation
# for a report, but the distinct lines behind it are evidence and were being discarded. With
# SWEEP_GATE_DUMP set, every distinct raw line is written under its message, so nothing the tool
# grouped is unrecoverable - the aggregation becomes presentation, not loss.
dmp = os.environ.get("DUMPFILE") or ""
if dmp:
    with open(dmp, "w", encoding="utf-8") as fh:
        for m in sorted(occ):
            fh.write("=== x%d, %d distinct :: %s\n" % (occ[m], len(var[m]), m))
            for raw in sorted(var[m]): fh.write("    %s\n" % raw)
'; }

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
# --census: AN INDEPENDENT SECOND IMPLEMENTATION, because a corpus the author curated can only ever
# measure the author's judgement. This extracts the population in AWK, from the LOG LINE FORMAT
# itself - [YYYYMMDD.HHMMSS.mmm-PID[:TID]-L] with L in D/I/W/E, which is the writers' format and not
# anything this tool invented - and requires the tool's own dump to account for exactly those lines.
# Two implementations in two languages agreeing on a real corpus is evidence; the earlier --verify
# that compared this tool's regex with itself was not, and printed EXHAUSTIVE over a real miss.
# --silent-failures: THE BLIND SPOT THIS DETECTOR CANNOT SEE FROM LOG TEXT ALONE, measured.
#
# Reading declared severity finds every failure our code DECLARES. It is structurally blind to a
# failure that declares nothing - and that is the case this whole tool exists for, so the size of
# the blind spot has to be a number, not a caveat. There is an independent witness: a verdict
# ledger. A row classed FAIL or INVALID is a failure somebody recorded, so its run's log must
# contain at least one declared error or warning. A failed verdict with a SILENT log is exactly a
# failure this detector would have missed, and counting them bounds the blind spot from outside.
#
#   tools/sweep-gate.sh --silent-failures <verdict-ledger> <log> [...]
if [ "${SILENT:-}" = 1 ]; then
    vled="${1:?--silent-failures needs a verdict ledger then the logs}"; shift
    [ -f "$vled" ] || { echo "sweep-gate: no verdict ledger at $vled" >&2; exit 2; }
    [ $# -ge 1 ] || { echo "sweep-gate: --silent-failures needs at least one log" >&2; exit 2; }
    nfail=0; silent=0; covered=0; unmeas=0
    while IFS= read -r row; do
        case "$row" in *'|'*) ;; *) continue ;; esac
        label="${row%%|*}"; text="${row#*|}"
        case "$text" in
          PASS*|SUPERSEDED*|RETRACTED*) continue ;;
        esac
        nfail=$((nfail+1))
        # THREE BUCKETS, because two of them were one and the number was wrong. A label with NO log
        # of its own is NOT MEASURABLE - it is not evidence of a silent failure. The first version
        # matched a log by filename containing the label; in a real campaign dir the logs are named
        # agent-etwproxysup.log and bridge-full.log, so nothing ever matched and it reported 14 of
        # 14 failures "silent", which is not a measurement, it is a broken join.
        own=""; hit=0
        for l in "$@"; do
            [ -f "$l" ] || continue
            case "$l" in *"$label"*) own="$l"; grep -qaE "$LEVELS" "$l" 2>/dev/null && hit=1; break ;; esac
        done
        if [ -z "$own" ]; then
            unmeas=$((unmeas+1))
        elif [ "$hit" = 1 ]; then
            covered=$((covered+1))
        else
            silent=$((silent+1)); printf '  SILENT FAILURE  %-20s %s\n' "$label" "$(printf '%s' "$text" | cut -c1-84)"
        fi
    done < "$vled"
    echo "SWEEP-GATE-SILENT graded_failures=$nfail measured=$((covered+silent)) left_a_declared_error=$covered silent=$silent no_log_of_their_own=$unmeas"
    if [ "$nfail" -eq 0 ]; then echo "  INCONCLUSIVE: the ledger records no failure, so the blind spot was not measured."; exit 2; fi
    if [ "$((covered+silent))" -eq 0 ]; then
        echo "  INCONCLUSIVE: none of the $nfail recorded failures has a log named after it, so NOTHING was measured here - this is a limit of joining a verdict label to a file, not a result."
        exit 2
    fi
    [ "$silent" -eq 0 ] && echo "  BOUNDED on what could be measured: all $covered of them left a declared error behind."
    exit 0
fi

if [ "${CENSUS:-}" = 1 ]; then
    [ $# -ge 1 ] || { echo "usage: $0 --census <log> [...]" >&2; exit 2; }
    cfile=$(mktemp); dfile=$(mktemp)
    awk '
      # a declared ERROR or WARNING, recognised from the format, independently of $LEVELS
      /^\[[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]\.[0-9][0-9][0-9][0-9][0-9][0-9]\.[0-9][0-9][0-9]-[0-9]+(:[0-9]+)?-[WE]\]/ { n++; next }
      /\[ERROR\]|\[WARN\]|\[WARNING\]/ { n++; next }
      END { print n+0 }
    ' "$@" > "$cfile"
    # a real EMPTY file, not /dev/null: `[ -f /dev/null ]` is FALSE (character device), so the inner
    # run refused, wrote no dump, and this check reported a 185-line disagreement that did not exist.
    el=$(mktemp); printf '# empty ledger for --census\n' > "$el"
    SWEEP_GATE_DUMP="$dfile" SWEEP_GATE_LEDGER="$el" "$0" "$@" >/dev/null 2>&1
    rm -f "$el"
    # the dump carries one line per DISTINCT declared line; duplicates are the difference
    indep=$(cat "$cfile")
    dumped=$(grep -ac '^    ' "$dfile" 2>/dev/null || true); dumped=${dumped:-0}
    uniq_indep=$(awk '
      /^\[[0-9]{8}\.[0-9]{6}\.[0-9]{3}-[0-9]+(:[0-9]+)?-[WE]\]/ || /\[ERROR\]|\[WARN\]|\[WARNING\]/ {
        line=$0; sub(/^\[[0-9]{8}\.[0-9]{6}\.[0-9]{3}-[0-9]+(:[0-9]+)?-[DIWE]\][ \t]*/, "", line)
        gsub(/[ \t]+/, " ", line); seen[line]=1
      } END { print length(seen) }
    ' "$@")
    rm -f "$cfile" "$dfile"
    echo "SWEEP-GATE-CENSUS awk_declared_lines=$indep awk_distinct=$uniq_indep tool_distinct_in_dump=$dumped"
    if [ "${indep:-0}" -eq 0 ]; then
        echo "  INCONCLUSIVE: the independent pass found no declared line, so nothing was compared."; exit 2
    fi
    if [ "${dumped:-0}" -ne "${uniq_indep:-0}" ]; then
        echo "  DISAGREE: two implementations of the same population differ by $(( uniq_indep - dumped )) line(s) - one of them is wrong."; exit 1
    fi
    echo "  AGREE: an awk pass over the log FORMAT and this tool account for the same $uniq_indep distinct declared line(s)."
    exit 0
fi

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
NOW=$(mktemp); VAR=$(mktemp)
SWEEP_GATE_VARIANTS="$VAR" declared "$@" > "$NOW" || { rm -f "$NOW" "$VAR"; exit 2; }
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
    # how many DISTINCT lines this one message stands for
    nv=$(grep -aF -- " $msg" "$VAR" 2>/dev/null | head -1 | sed -E 's/^([0-9]+) .*/\1/')
    vtag=""; [ -n "${nv:-}" ] && [ "${nv:-1}" -gt 1 ] && vtag=" [${nv} distinct]"
    # A RISE RE-SURFACES A DISPOSITIONED MESSAGE, and the threshold must SCALE with the count. A
    # flat "double it" is right at a count of 1 and nonsense at 102: the inverted-DWM-bounds message
    # is dispositioned at x102, so doubling would let it reach 205 - a 100% regression - unreported.
    # A reason written in the ledger can also simply be WRONG, and a rising count is the only signal
    # that contradicts it from outside, which is why this is the tight one.
    #   base < 10  : needs > base*2, and at least > base+3   (1 -> 2 is not news)
    #   base >= 10 : needs > base + (base+3)/4               (a quarter more of a busy message is)
    if [ -n "${base:-}" ]; then
        if [ "$base" -lt 10 ]; then
            rose_at=$(( base * 2 )); [ "$rose_at" -lt $(( base + 3 )) ] && rose_at=$(( base + 3 ))
        else
            rose_at=$(( base + (base + 3) / 4 ))
        fi
    else rose_at=0; fi
    if [ -z "$base" ] || [ -z "$note" ]; then
        [ "$newn" = 0 ] && [ "$rose" = 0 ] && echo "SWEEP-GATE: declared error/warning not accounted for:"
        newn=$((newn+1))
        if [ -n "$base" ] && [ -z "$note" ]; then
            printf '  UNACCOUNTED x%-4s %s\n     (a ledger row exists but records no reason - that is not an account)\n' "$cnt" "$(printf '%s' "$msg" | cut -c1-140)"
        else
            printf '  UNACCOUNTED x%-4s%s %s\n' "$cnt" "$vtag" "$(printf '%s' "$msg" | cut -c1-132)"
        fi
    elif [ "$cnt" -gt "$rose_at" ]; then
        [ "$newn" = 0 ] && [ "$rose" = 0 ] && echo "SWEEP-GATE: declared error/warning not accounted for:"
        rose=$((rose+1)); printf '  ROSE        x%-4s (ledger x%s, surfaces above x%s) %s\n' "$cnt" "$base" "$rose_at" "$(printf '%s' "$msg" | cut -c1-104)"
    else
        acc=$((acc+1)); printf '  ACCOUNTED   x%-4s%s %s\n     -> %s\n' "$cnt" "$vtag" "$(printf '%s' "$msg" | cut -c1-104)" "$(printf '%s' "$note" | cut -c1-110)" >> "$ACCLIST"
    fi
done < "$NOW"
# printed ALWAYS, pass or fail, so a recurring known error stays visible instead of becoming silence
if [ "$acc" -gt 0 ]; then
    echo "SWEEP-GATE: $acc declared error/warning message(s) accounted for by $LEDGER (shown, not hidden):"
    cat "$ACCLIST"
fi
rm -f "$ACCLIST"

# ORPHANED LEDGER ROWS. A row that matched nothing in this run is either a condition that did not
# occur (fine, and common) or a row whose text no longer matches what the normaliser produces (a
# LOST disposition - the error will come back as unaccounted and the reason is gone). The two are
# indistinguishable from one run, so this reports the count rather than guessing, and --verify-ledger
# is the check that fails when a row cannot be produced by the current normaliser at all.
orph=0
while IFS= read -r lrow; do
    [ -n "$lrow" ] || continue
    lmsg=${lrow#* }; lmsg=${lmsg%%   #*}
    grep -aqF -- " $lmsg" "$NOW" 2>/dev/null || orph=$((orph+1))
done < "$LD"
[ "${orph:-0}" -gt 0 ] && echo "SWEEP-GATE-LEDGER $orph of $(grep -c . "$LD") row(s) matched nothing this run (a condition that did not occur, or a row whose text has drifted - check with --verify-ledger)"

rm -f "$NOW" "$LD" "$VAR"
read -r nolevel total < <(unlevelled "$@")
echo "SWEEP-GATE-COVERAGE lines=$total with_declared_level=$((total - nolevel)) without=$nolevel"
[ "${nolevel:-0}" -gt 0 ] && echo "  $nolevel line(s) carry NO declared level, so this tool cannot judge them. That is the gap, named."

if [ "$newn" -gt 0 ] || [ "$rose" -gt 0 ]; then
    echo "SWEEP-GATE-RESULT unaccounted=$newn risen=$rose accounted=$acc"
[ -z "${SWEEP_GATE_DUMP:-}" ] && echo "  every distinct line behind these messages: re-run with SWEEP_GATE_DUMP=<path> - grouping is presentation, nothing is discarded"
    echo "  Each is a real error our code declared. It is a defect to fix, or an entry for $LEDGER"
    echo "  recording what it means. Reading it and moving on is not one of the options."
    exit 1
fi
echo "SWEEP-GATE-RESULT unaccounted=0 risen=0 accounted=$acc"
