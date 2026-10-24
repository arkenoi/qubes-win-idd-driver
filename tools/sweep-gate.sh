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

WRITE=""; VERIFY=0; CENSUS=0; SILENT=0; VLED=0
if [ "${1:-}" = "--write-ledger" ]; then WRITE="${2:?--write-ledger needs an output path}"; shift 2; fi
if [ "${1:-}" = "--verify" ]; then VERIFY=1; shift; fi
if [ "${1:-}" = "--census" ]; then CENSUS=1; shift; fi
if [ "${1:-}" = "--verify-ledger" ]; then VLED=1; shift; fi
if [ "${1:-}" = "--silent-failures" ]; then SILENT=1; shift; fi
# A CAUSED DECLARATION COMES FROM THE RUN THAT CAUSED THE CONDITION, and that is what separates it
# from a ledger row. The per-cell sweep has had this for a while (log-sweep's --tolerate-error, which
# matrix.sh already uses for exactly the line below) and it is why the cells sweep CLEAN while this
# gate failed on the same lines. Jev: declare-as-caused 0.72 for that mechanism; no_concealment 0.67
# for giving this gate the same input; and "stop chasing the probe, declare it" 0.94 after four
# measured attempts to remove the cause (x9 baseline, x8, x9, then x15 with the attempt that was
# reverted).
#
# IT CANNOT ROT INTO A SILENCER, because a declaration that matches NOTHING is a failure of its own -
# the run claimed to cause something it did not, which means the claim is stale. That is the property
# a ledger row lacks, and the reason inventing a ledger row kind for this scored only 0.46.
#
# TWO KINDS, because one rule was wrong for rare conditions and a run measured it. A declaration for
# something the campaign causes EVERY time must match or it is stale. A declaration for something it
# CAN cause but usually does not - a task that happens to be mid-run when a guest is halted, seen in
# 1 of 6 campaigns - is legitimately unmatched most runs, and failing those runs is wrong. Campaign
# 20261018-153728 printed "DECLARED-CAUSED NEVER MATCHED" with unaccounted=0 for exactly that.
# A rare declaration is REPORTED when unmatched, never silent, so one that has not matched for a long
# time is visible to a reader. Jev: two_kinds 0.89 (always_fail 0.11).
DECL_RX=(); DECL_WHY=(); DECL_RARE=()
# --build: THE BUILD UNDER TEST, and a GATE VERDICT IS A STATEMENT ABOUT ONE BUILD. Without it this
# gate can only self-calibrate ("the newest version present is the candidate"), which is right for
# an upgrade and wrong for a downgrade - and, worse, cannot tell "the candidate wrote nothing here"
# from "the candidate wrote nothing wrong here". Its only caller, mgmt/harness/matrix.sh, has
# computed $PV from the package MANIFEST since long before this option existed and passed it to the
# PER-CELL sweep only; the campaign-level gate was handed file lists alone.
# Parsed in the same loop as the declarations so a caller's argument ORDER cannot matter.
BUILD=""; SINCE=""
while :; do
    case "${1:-}" in
        --declare-caused|--declare-caused-rare)
            [ $# -ge 3 ] || { echo "sweep-gate: $1 needs REGEX and REASON" >&2; exit 2; }
            case "$1" in --declare-caused-rare) DECL_RARE+=(1) ;; *) DECL_RARE+=(0) ;; esac
            DECL_RX+=("$2"); DECL_WHY+=("$3"); shift 3 ;;
        --build)
            [ $# -ge 2 ] || { echo "sweep-gate: --build needs <package_version>" >&2; exit 2; }
            BUILD="$2"; shift 2 ;;
        --since)
            # THIS RUN'S WINDOW. A per-day guest log is APPENDED to, so a previous campaign's lines
            # sit in the same file carrying the SAME candidate build - no build scope can tell them
            # apart. MEASURED on acceptance run 40037710497: all eight cells carry lines predating
            # their own window, 503 in total. Without this the gate counts a previous run's declared
            # errors against this one. The timestamps are NOT parsed here: the attributor already
            # reads every log format this gate accepts, and a second timestamp parser in bash is the
            # duplication this whole change removed.
            [ $# -ge 2 ] || { echo "sweep-gate: --since needs <utc iso>" >&2; exit 2; }
            SINCE="$2"; shift 2 ;;
        *) break ;;
    esac
done
[ $# -ge 1 ] || [ "$VERIFY" = 1 ] || [ "$VLED" = 1 ] || { echo "usage: $0 [--verify] [--verify-ledger] [--census] [--write-ledger <out>] <log> [...]" >&2; exit 2; }
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
    # A BOM IS ENCODING, NOT MESSAGE. Some guest logs arrive UTF-8-BOM, and the mark sat in front
    # of the timestamp so the prefix rules below could not anchor - the same message then reported
    # twice, once as "\ufeffN-N-N N:N:N [ERROR] DEATH #N ...". It also split the independent
    # census from this tool by one line. Stripped here, where both the key and the raw variant see it.
    line = line.lstrip("\ufeff")
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
    # A POINTER WITHOUT AN 0x IS STILL A POINTER. This matched only the 0x-prefixed form, and
    # win_perror2/VchanWaitForSendSpace print raw handles: "(000001B810D49540, output data): vchan
    # buffer full, blocking write" came out as THREE separate unaccounted messages in run
    # 38994277148 - x27, x12 and x4 - one per address, i.e. one message that can never be
    # dispositioned because every run mints new addresses. The same unledgerable shape as the
    # duration bug below, by a different route.
    # 12+ HEX DIGITS, so an identity is safe: a KB number is 7 digits (T21c holds that line), a
    # version is dotted, and a timestamp has been stripped by the prefix rules above.
    l = re.sub(r"\b[0-9A-Fa-f]{12,}\b", "<HEX>", l)
    l = re.sub(r"0x[0-9A-Fa-f]+", "<HEX>", l)
    l = re.sub(r"^\[\d{8}\.\d{6}\.\d{3}-\d+(:\d+)?-[DIWE]\]\s*", "", l)
    l = re.sub(r"^\d{4}-\d{2}-\d{2}[ T][\d:.]+\s*", "", l)
    l = re.sub(r"^\[?\d{2}:\d{2}:\d{2}\]?\s*", "", l)
    l = re.sub(r"[A-Za-z]:\\[^ ,;)]+", "<PATH>", l)
    l = re.sub(r"/[A-Za-z0-9._/-]{8,}", "<PATH>", l)
    l = re.sub(r"\b(WIN|Win)[0-9]+[a-z]*-[a-z0-9]+", "<CELL>", l)
    l = re.sub(r"\bwin[0-9]+[a-z]*-[a-z0-9]+\b", "<VM>", l)
    # A NUMBER WITH ITS UNIT GLUED ON IS STILL A NUMBER. \b\d+\b needs a word boundary AFTER the
    # digits, and in "108s" there is none - so durations survived normalisation, every run minted a
    # brand-new message, and a ledger row written today missed the next run BY CONSTRUCTION. That is
    # not a noisy message, it is an UNLEDGERABLE one: the single shape that can never be cleared, so
    # once the gate began to block (SWEEPGATEADVISORY) it failed every clean run for ever. It failed
    # the first one it judged. The lookahead keeps the boundary requirement at the FRONT, so
    # "KB5007651" and "1920x1080" are untouched - an identity glued to digits is not a duration, and
    # tools/tests/sweep-gate-selftest.sh T21c holds that line.
    # NO APOSTROPHES IN THIS BLOCK: it is python3 -c inside single quotes, so one closes the string
    # and bash parses the regex. "the next run" above was "tomorrow" + apostrophe + "s run" first.
    l = re.sub(r"\b\d+(?=[a-zA-Z]*\b)", "N", l)   # GUARD:unitnum DEFECT: l = re.sub(r"\b\d+\b", "N", l)
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
# UTF-16 IS INVISIBLE TO EVERY REGEX IN THIS FILE, AND A WINDOWS GUEST WRITES IT BY DEFAULT.
# PowerShell 5.1's `>` redirection produces UTF-16LE, so a log a harness pulls that way reads as
# binary here: each character is followed by a NUL and no pattern matches. Measured on the
# 2026-10-14 campaign, 3 of 86 preserved files were UTF-16 (msiexec's verbose log at 1526 lines,
# and bind-dirs.log, which is OURS). None happened to carry a declared error that run - so this was
# a hole with nothing in it yet, which is the only kind worth closing before it has something.
# The analyzer path is unaffected: mgmt/harness/log-sweep-collect.ps1 reads guest files through
# PowerShell, which honours the BOM, so the collected copies arrive as UTF-8 already.
# Decided by the BOM, never by the file's name or extension.
_text() { # <file> -> its text as UTF-8 on stdout
    case "$(head -c2 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" in
        fffe|feff) iconv -f UTF-16 -t UTF-8 "$1" 2>/dev/null || cat -- "$1" 2>/dev/null ;;
        *)         cat -- "$1" 2>/dev/null ;;
    esac
}

# A TOOL'S REPORT IS NOT AN EMITTER'S LOG. This matched only sweep-gate's own output, so the
# analysers' reports counted against coverage: measured on run 38787325142, the four
# <cell>-logsweep.out files contributed 1443 of 2142 "undeclared OURS" lines. They are
# log-sweep.py's rendered findings - prose about other logs - and asking them to declare a severity
# per line would be asking a report to pretend it is a log. Both markers are the tools' own result
# lines, which no emitter writes.
# THE WHOLE FILE, not its first 4 KB. A tool writes its result line at the END: measured, the
# <cell>-logsweep.out files carry LOGSWEEP-RESULT at byte 38576 of 38959, so a head-bounded probe
# could never see it and four analyser reports counted 1443 lines against coverage.
# BUILD SCOPING: A GATE VERDICT IS A STATEMENT ABOUT THE BUILD UNDER TEST.
# On an upgrade cell one log directory holds BOTH builds - the predecessor writes its last lines,
# the installer swaps the binaries, the new build starts minutes later - and no timestamp separates
# them. This gate aggregates by MESSAGE and discards the file, so the predecessor's warnings arrived
# as the new release's. MEASURED on run 20261018-083319: of the 17 unaccounted messages, four were
# emitted ONLY by 4.3.35.795 while the build under test was 4.3.36.1020, and two of those four our
# own source already logs at Info (ApplyGuestShadows main.c:5980, PlatLogInfo notifyerr.c:315) - so
# the gate was blocking on lines the shipped build cannot write.
#
# WHY SCOPING AND NOT A LEDGER ROW (Jev: build_scope 0.90, ledger_entry 0.01): a ledger row matches
# on MESSAGE TEXT, so it would account for the line whatever build emitted it - if a later build
# REGRESSED and reinstated the warning, the row would match and hide it. Scoping keys on the version
# the log itself declares, so a regression carries the CURRENT version and surfaces immediately.
#
# THIS GATE DOES NOT READ VERSIONS ANY MORE; IT ASKS THE ONE ATTRIBUTOR.
#
# IT HAD ITS OWN PARSER AND ITS OWN RULE, AND BOTH WERE A BUILD BEHIND. The parser grepped
# "LogInit: Log started, module name: <m>" and "LogInit: Module version: <v>" - the two lines
# patches/windows-utils-loginit-banner-debug DEMOTED TO DEBUG (owner 2026-10-20, "it is NOT normal
# to have thousands of lines of log during the brief normal run"), replaced by ONE InfoLevel line,
# `LogInit: QWTBIRTH module=<m> ver=<a.b.c.d> pid=... session=... uptime=...`, from
# patches/windows-utils-single-birth-line. This file already knew that: :747 names the patch and
# :778 greps BOTH spellings for its birth-line census. The extractor here knew only the dead one.
#
# MEASURED 2026-10-24 on a real two-build capture, scratchpad/dedup-test/logs/files, with the old
# extractor run verbatim (receipt: scratchpad/sgmodver-blindness.sh, output under
# scratchpad/attributor-receipt/): the candidate's own gui-agent-20261023.log carries
# `QWTBIRTH module=gui-agent ver=4.3.37.1066` and ZERO legacy banner lines, so the extractor
# returned EMPTY on it - 27 of 71 files blind - while the 4.3.35.795 entry fixture, an image
# predating the demotion, read fine. The index therefore came out as seven modules with ONE version
# each, every one of them the PREDECESSOR'S, on a capture that provably holds both builds, and the
# `>= 2 versions` rule below could exclude NOTHING. That is why a campaign gate reported 26
# unaccounted messages it could not attribute, why "nothing declares 4.3.37.x anywhere" was recorded
# as a property of the corpus, and why adding a capture-wide superseded set here moved
# `unaccounted` 26 -> 26: the candidate was invisible to this file, not absent from the logs. The
# same attributor now reads 41 of those 71 files as the predecessor's.
#
# SO THE RULE AND THE PARSE BOTH LIVE IN ONE PLACE (tools/log-sweep.py version_is_prior /
# cmd_attribute). Owner, 2026-10-24: "you claimed to fix predecessor lines from being erroneously
# ingested AT LEAST FOUR TIMES ... AND YOU DO IT OVER AND OVER" - there were three implementations
# sharing no code, so each fix reached one consumer and the next surfaced.
# tools/tests/attributor-unique-selftest.sh asserts there is exactly one.
#
# ONE PYTHON PROCESS PER RUN, not one per file: 847 inputs on a full campaign.
declare -A _SG_VERDICT=()     # path -> prior|candidate|unattributable|mixed|unknown
declare -A _SG_PRIORLN=()     # path -> comma-separated line numbers, or * for the whole file
declare -A _SG_STALELN=()     # path -> line numbers written BEFORE this run's window (--since)
declare -A _SG_MODVER=()      # path -> "<module><TAB><version(s)><TAB><module's newest>"
SG_CAND_ABSENT="-"            # 0/1 once --build is given, "-" when it is not
SG_ATTR_TRAILER=""            # the attributor's own ATTRIBUTE-RESULT line, kept for the report
_sg_build_index() { # $@=files -> fills the three maps above from the one attributor
    local out rc path mod vers verdict prior _una newest
    out=$(mktemp) || return 2
    python3 tools/log-sweep.py attribute ${BUILD:+--build "$BUILD"} ${SINCE:+--since "$SINCE"} -- "$@" > "$out" 2>"$out.err"
    rc=$?
    # rc 1 is "the named build declared itself nowhere", which is a VERDICT, not a failure to read -
    # the caller below refuses to grade on it. rc 2 means nothing could be parsed at all.
    if [ "$rc" = 2 ]; then
        echo "sweep-gate: the attributor could not read this input set:" >&2
        sed 's/^/  /' "$out.err" >&2
        rm -f "$out" "$out.err"; return 2
    fi
    while IFS=$'\t' read -r path mod vers verdict prior _una newest stale; do
        case "$path" in ATTRIBUTE-RESULT*) continue ;; esac
        [ -n "$path" ] || continue
        _SG_VERDICT["$path"]="$verdict"
        _SG_PRIORLN["$path"]="$prior"
        _SG_STALELN["$path"]="${stale:--}"
        _SG_MODVER["$path"]="$mod	$vers	$newest"
    done < "$out"
    # THE WINDOW EXCLUSION IS REPORTED, because this gate cannot check the clock it rests on. The
    # analyzer can - it raises a `clockskew` DATA problem and refuses to apply the window when the
    # guest's clock is too far from the host's - and this gate has no second clock to compare. So
    # what the window dropped is printed as a figure: a --since that is wrong, or a guest whose clock
    # shifted, shows up HERE as an implausible count rather than as a quietly clean verdict. Nothing
    # is excluded silently; the per-cell sweep is where the clock itself is judged.
    SG_STALE_N=0; SG_STALE_F=0
    for _p in "${!_SG_STALELN[@]}"; do
        case "${_SG_STALELN[$_p]}" in
            -|"") : ;;
            *) SG_STALE_F=$((SG_STALE_F+1))
               SG_STALE_N=$((SG_STALE_N + $(printf '%s' "${_SG_STALELN[$_p]}" | tr ',' '\n' | grep -ac .))) ;;
        esac
    done
    SG_ATTR_TRAILER=$(grep -a '^ATTRIBUTE-RESULT' "$out" | tail -1)
    SG_CAND_ABSENT=$(printf '%s' "$SG_ATTR_TRAILER" | sed -n 's/.*candidate_build_absent=\([^ ]*\).*/\1/p')
    SG_CAND_ABSENT="${SG_CAND_ABSENT:--}"
    rm -f "$out" "$out.err"
    return 0
}
_is_prior_build() { # $1=file -> 0 when the attributor says this file is wholly the predecessor's
    [ "${_SG_VERDICT[$1]:-}" = "prior" ]
}
_prior_lines_of() { # $1=file -> the line numbers inside a MIXED file that the predecessor wrote
    case "${_SG_VERDICT[$1]:-}" in
        mixed) printf '%s' "${_SG_PRIORLN[$1]:--}" ;;
        *)     printf '-' ;;
    esac
}
# THE ONE TEXT PRODUCER FOR THE GRADED POPULATION, so there is a single extraction pipeline below
# rather than one per case. A FILE THAT HOLDS BOTH BUILDS LOSES ONLY THE PREDECESSOR'S LINES: a
# per-FILE verdict was all the old extractor could manage, and it is wrong whenever one log spans
# the turnover - the ordinary case now that a module writes ONE per-day file
# (patches/windows-utils-one-log-per-module) instead of one per process, so an upgrade appends both
# builds to the same file. Dropping it whole would hide the candidate's own errors; keeping it whole
# bills the predecessor's errors to the candidate, which is the defect being cured.
_sg_text_scoped() { # $1=file -> its text, minus every line the attributor excluded
    # TWO EXCLUSIONS, ONE PRODUCER: the predecessor's lines inside a MIXED file, and the lines any
    # file carries from BEFORE this run's window. They are separate facts with separate causes and
    # both leave the graded set; combining them here keeps ONE extraction pipeline below, which is
    # what stopped this gate having two.
    local mx st drop
    mx=$(_prior_lines_of "$1"); st="${_SG_STALELN[$1]:--}"
    drop=""
    [ "$mx" != "-" ] && drop="$mx"
    [ "$st" != "-" ] && drop="${drop:+$drop,}$st"
    if [ -z "$drop" ]; then _text "$1"
    else _text "$1" | awk -v drop="$drop" 'BEGIN{n=split(drop,a,",");for(i=1;i<=n;i++)d[a[i]]=1} !(FNR in d)'
    fi
}

_is_own_report() { _text "$1" | grep -qa 'SWEEP-GATE-\(RESULT\|COVERAGE\|CENSUS\|SILENT\|LEDGER\|VERIFY\)\|LOGSWEEP-RESULT'; }

declared() { local vfile="${SWEEP_GATE_VARIANTS:-}" skipped=0 pfile="${SWEEP_GATE_PRIOR:-}"
             local ufile="${SWEEP_GATE_UPSTREAM_OUT:-}" ulist="${SWEEP_GATE_UPSTREAM:-mgmt/harness/upstream-emitters.txt}"
             # Scoped for EVERY caller, --write-ledger included: seeding the ledger from the
             # predecessor's messages would write the mis-attribution in permanently, under the new
             # build's name. Excluded files are NAMED in $pfile, never dropped quietly.
             _sg_build_index "$@" || return 2
             for l in "$@"; do [ -f "$l" ] || { echo "sweep-gate: $l does not exist" >&2; return 2; }
               _is_own_report "$l" && { skipped=$((skipped+1)); continue; }
               if _is_prior_build "$l"; then
                   [ -n "$pfile" ] && printf '%s\t%s\n' "${_SG_MODVER[$l]:-?	?	?}" "$l" >> "$pfile"
                   continue
               fi
               # A FILE THAT HOLDS BOTH BUILDS LOSES ONLY THE PREDECESSOR'S LINES - see
               # _sg_text_scoped. It is NAMED in $pfile like a whole exclusion, with the count.
               _mx=$(_prior_lines_of "$l")
               if [ "$_mx" != "-" ] && [ -n "$pfile" ]; then
                   printf '%s\t%s (MIXED: %s predecessor line(s) dropped, the rest kept)\n' \
                        "${_SG_MODVER[$l]:-?	?	?}" "$l" "$(printf '%s' "$_mx" | tr ',' '\n' | grep -ac .)" >> "$pfile"
               fi
               # THE GATE MUST NOT EAT ITS OWN TAIL. matrix.log carries the harness's QUOTATION of
               # this gate's verdict ("FAIL INVALID-SWEEP N unaccounted...") and its class footer
               # ("classes: product-FAIL=N INVALID-*..."), both stamped [WARN] by the failure logger.
               # Those are this gate's OWN RESULT read back, not a condition in the run: once the
               # gate failed, its failure text became a permanently unaccounted warning, so the gate
               # could never clear again. _is_own_report already skips files carrying the gate's
               # markers; a verdict quoted into another file needs the same exclusion at line level.
               # NARROWED, BECAUSE THE BLANKET VERSION CONCEALED A REAL ERROR AND THE CORPUS CAUGHT
               # IT. Excluding every 'classes: product-FAIL=' line also hid
               # "[ERROR] classes: product-FAIL=2 INVALID-*=1" - a footer reporting TWO product
               # failures, which mgmt/harness/error-corpus.txt carries as a MUST-surface line
               # (recall fell 20/20 -> 18/20), and narrowing to product-FAIL=0 still hid
               # MATRIXUNGRADED - "product-FAIL=0 INVALID-*=1", a footer reporting a cell that never
               # ran. So ONLY an ALL-ZERO footer is bookkeeping; anything it actually reports stays.
               # Likewise only this gate's own
               # result sentence is excluded - INVALID-SWEEP-DATA/-CAPPED/-UNJUDGED report missing
               # data and stay.
               _sg_text_scoped "$l" | grep -ahE "$LEVELS" \
                 | grep -avE 'INVALID-SWEEP +[0-9]+ unaccounted \+ [0-9]+ risen|classes: product-FAIL=0 INVALID-\*\(cell did not run, ungraded\)=0' || true; done | message \
             | VFILE="$vfile" DUMPFILE="${SWEEP_GATE_DUMP:-}" UPSTREAMFILE="$ulist" UPSTREAMOUT="$ufile" python3 -c '
import collections, os, sys
occ, var = collections.Counter(), collections.defaultdict(set)
for line in sys.stdin:
    parts = line.rstrip("\n").split("\t", 1)
    msg = parts[0]
    occ[msg] += 1
    if len(parts) > 1: var[msg].add(parts[1])
# UPSTREAM EMITTERS ARE DIAGNOSIS, NOT ACCEPTANCE (owner 2026-10-18: "if emitter is noisy
# upstream, you exclude it from gate, using to augment the diagnosis, not as acceptance criteria").
# The list is GENERATED from the vendored sources by tools/upstream-emitters.py, so each exclusion
# carries the file it came from and nobody hand-writes a receipt for code we cannot change.
up = {}
upf = os.environ.get("UPSTREAMFILE") or ""
if upf and os.path.exists(upf):
    for row in open(upf, encoding="utf-8"):
        if row.startswith("#") or not row.strip():
            continue
        fn, _, src = row.rstrip("\n").partition("\t")
        up[fn] = src
def _upstream_of(msg):
    fn = msg.split(":", 1)[0].strip()
    return up.get(fn)
graded, foreign = [], []
for m in sorted(occ):
    (foreign if _upstream_of(m) else graded).append(m)
for m in graded:
    print("%d %s" % (occ[m], m))
ufile = os.environ.get("UPSTREAMOUT") or ""
if ufile and foreign:
    with open(ufile, "w", encoding="utf-8") as fh:
        for m in foreign:
            fh.write("%d\t%s\t%s\n" % (occ[m], _upstream_of(m), m))
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

# A THIRD-PARTY LOG HAS NO SEVERITY TO READ, AND SAYING SO IS NOT THE SAME AS EXCUSING OURS.
# A campaign preserves msiexec's verbose log for forensics - 3047 of the 3547 unlevelled lines on
# the 2026-10-14 run, 86% of them. Reported as one number, "that is the gap, named" reads as 3558
# lines of our own undisciplined logging, when the actionable share is ~500. A gap we can close and
# a gap Microsoft owns are different facts and the report now separates them.
# Recognised from the file's OWN header, the way the QWT format is recognised - not from vocabulary,
# and not from the file's name, which the harness chooses.
_is_msi_verbose() { local _h; _h=$(_text "$1" | head -c 400); grep -qa 'Verbose logging started:.*Calling process:.*msiexec\.exe' <<<"$_h"; }

unlevelled() { local n=0 t=0 m=0 a b
    for l in "$@"; do
        # NOT ITS OWN REPORT. The report is swept alongside the logs on a re-run (matrix globs
        # "$M"/*.out and writes "$M"/sweep-gate.out into it), and its own narration carries no
        # level - so counting it made the gate block on its own output. The message census already
        # skips it for exactly this reason; the coverage census must agree.
        _is_own_report "$l" && continue
        a=$(_text "$l" | grep -ac . || true)
        # BOTH counts over the same population - non-empty lines. Counting `without` over every line
        # including blanks made with_declared_level go NEGATIVE (-20) on a real set of logs.
        # OURS means a line one of OUR BASH LOGGERS wrote, not every line in every file. The
        # campaign's directory also holds CAPTURES of other programs - msiexec's log, the guest's
        # installer console, the output of a command under test - and asking a capture to declare a
        # severity is asking it to pretend it is a log. Measured on run 38787325142: of 699 lines
        # left after excluding the analysers' own reports, 320 were matrix's narration and 80
        # prime-run's (both now declare), while *-final.log, *-msi.log and *-callers.out are
        # captures. Our loggers have one of two shapes, and only those are held to the rule.
        b=$(_text "$l" | grep -a . | grep -aE '^[0-9]{2}:[0-9]{2}:[0-9]{2} [a-z0-9-]+\[[^]]*\]: |^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\] ' | grep -avcE "$ANYLEVEL" || true)
        t=$((t + ${a:-0})); n=$((n + ${b:-0}))
        _is_msi_verbose "$l" && m=$((m + ${b:-0}))
    done
    echo "${n:-0} ${t:-0} ${m:-0}"; }

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
            # a label must be long enough to be a label. A one-character one ("a") matches almost
            # any path - including the temp directory holding the fixture - and joined a verdict to
            # a log that has nothing to do with it.
            [ "${#label}" -ge 2 ] || continue
            case "$(basename "$l")" in *"$label"*) own="$l"; [ "$(_text "$l" | grep -acE "$LEVELS")" -gt 0 ] && hit=1; break ;; esac
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
        # NO PER-LABEL JOIN, so fall back to the SUITE-LEVEL question, which is still answerable and
        # still the one that matters: this run recorded N failures - do its logs carry ANY declared
        # error at all? Measured on a real September run: 14 non-PASS verdicts, 7 log files, ZERO
        # declared error or warning lines. A detector reading declared severity would have seen
        # NOTHING on a run with 14 recorded failures. That is the blind spot, with a number on it.
        anyerr=0
        for l in "$@"; do
            [ -f "$l" ] || continue
            _is_own_report "$l" && continue
            n=$(_text "$l" | grep -acE "$LEVELS" || true); anyerr=$((anyerr + ${n:-0}))
        done
        echo "  no verdict label joins a log, so measured at SUITE level instead: $nfail recorded failure(s), $anyerr declared error/warning line(s) in the logs"
        if [ "$anyerr" -eq 0 ]; then
            echo "  SILENT RUN: a detector reading declared severity would have seen NOTHING here. Every one of those $nfail failures is invisible to it."
            exit 1
        fi
        echo "  NOT SILENT: the run declared something, though which failure each line belongs to is not determinable from these names."
        exit 0
    fi
    [ "$silent" -eq 0 ] && echo "  BOUNDED on what could be measured: all $covered of them left a declared error behind."
    exit 0
fi

# --verify-ledger: CAN EACH ROW STILL BE PRODUCED AT ALL?
#
# THE FLAG THIS IMPLEMENTS WAS ADVERTISED AND ABSENT. The orphan report below has told the reader
# for weeks to "check with --verify-ledger" - a flag the parser never accepted - so the one
# diagnosis the gate prescribes for a drifted row could not be run, and drift stayed
# indistinguishable from a condition that did not occur. Run 38994277148 said "5 of 7 row(s)
# matched nothing this run" and nobody could tell which kind they were.
#
# ONE OF THEM WAS REAL. The ledger carries
#     ApplyGuestShadows: no usable interactive session yet (token<PATH>); cannot disable guest ...
# while the emitter (agent/gui-agent/main.c:5610) now says
#     no usable interactive session yet, cannot %s guest shadows (will retry)
# The message was reworded, the row stopped matching, and that error came back UNACCOUNTED x18 in
# the same run with its reason orphaned on disk - the exact loss this report was written to warn
# about, undetectable for want of its own check.
#
# TWO INDEPENDENT FAILURES, because a row can be unmatchable for two different reasons:
#   NOT-A-FIXED-POINT  the normaliser does not reproduce the row from itself, so it cannot ever
#                      equal a message this tool emits. Pure arithmetic, no tree needed.
#   TEXT-GONE          no literal run of >= 20 characters from the row appears anywhere in the
#                      source tree, so whatever used to emit it does not say that any more.
# CONSERVATIVE ON PURPOSE: a row passes if ANY of its long runs is found, because a run may
# straddle a %s the emitter fills in, and a false LOST would send someone chasing a row that is
# merely dormant. It reports, it does not guess.
if [ "${VLED:-}" = 1 ]; then
    [ -f "$LEDGER" ] || { echo "sweep-gate: REFUSING - no ledger at $LEDGER" >&2; exit 2; }
    # THE SEARCH CORPUS IS THE EMITTERS, AND NOT THIS TOOL'S OWN BOOKKEEPING. The first version
    # searched mgmt/ and tools/ whole - which hold the ledger itself, log-sweep's baseline and this
    # script's comments quoting these very rows - so every row matched ITSELF and the check could
    # only ever say OK. It reported the one row already KNOWN to be drifted as fine.
    # (And every --exclude must precede the `--`, or grep reads it as a file to search: written
    # after it, all five exclusions were inert and the self-matching came straight back.)
    SRC=$(mktemp)
    grep -ra --exclude-dir=.git --exclude=error-ledger.txt --exclude=error-corpus.txt \
         --exclude=log-sweep-baseline.json --exclude='sweep-gate*' -h '' \
         agent core-agent guest mgmt/harness mgmt/prime-jobs tools 2>/dev/null > "$SRC"
    python3 tools/sweep-gate-verify-ledger.py "$LEDGER" "$SRC"
    _vrc=$?
    rm -f "$SRC"
    exit $_vrc
fi

if [ "${CENSUS:-}" = 1 ]; then
    [ $# -ge 1 ] || { echo "usage: $0 --census <log> [...]" >&2; exit 2; }
    cfile=$(mktemp); dfile=$(mktemp)
    awk '
      # a declared ERROR or WARNING, recognised from the format, independently of $LEVELS
      /^\[[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]\.[0-9][0-9][0-9][0-9][0-9][0-9]\.[0-9][0-9][0-9]-[0-9]+(:[0-9]+)?-[WE]\]/ { n++; next }
      /\[ERROR\]|\[WARN\]|\[WARNING\]/ { n++; next }
      END { print n+0 }
    ' < <(for l in "$@"; do _text "$l"; done) > "$cfile"
    # a real EMPTY file, not /dev/null: `[ -f /dev/null ]` is FALSE (character device), so the inner
    # run refused, wrote no dump, and this check reported a 185-line disagreement that did not exist.
    el=$(mktemp); printf '# empty ledger for --census\n' > "$el"
    SWEEP_GATE_DUMP="$dfile" SWEEP_GATE_LEDGER="$el" "$0" "$@" >/dev/null 2>&1
    rm -f "$el"
    # the dump carries one line per DISTINCT declared line; duplicates are the difference
    indep=$(cat "$cfile")
    dumped=$(grep -ac '^    ' "$dfile" 2>/dev/null || true); dumped=${dumped:-0}
    # THE GUEST'S LOGS ARE CRLF, AND [ \t] IS NOT \s. This pass collapsed spaces and tabs but left
    # the carriage return on, so one message counted TWICE - once bare, once with \r - while the
    # tool's own normaliser uses \s+ and .strip() and counts it once. Measured 2026-10-14 over a
    # real campaign: awk 52 distinct vs the tool's 48, and all four of the difference were \r.
    # A cross-check that reports DISAGREE on every Windows log it reads is worse than none: it
    # would have masked a real disagreement. The fixture it passed on was mine, and had no CRLF.
    # The BOM strip is the same class: a UTF-8 BOM keeps the ^ anchor from matching the prefix,
    # which this pass needs and the tool's unanchored reader does not.
    uniq_indep=$(awk '
      { sub(/^\xef\xbb\xbf/, ""); gsub(/\r/, "") }
      /^\[[0-9]{8}\.[0-9]{6}\.[0-9]{3}-[0-9]+(:[0-9]+)?-[WE]\]/ || /\[ERROR\]|\[WARN\]|\[WARNING\]/ {
        line=$0; sub(/^\[[0-9]{8}\.[0-9]{6}\.[0-9]{3}-[0-9]+(:[0-9]+)?-[DIWE]\][ \t]*/, "", line)
        gsub(/[ \t]+/, " ", line); seen[line]=1
      } END { print length(seen) }
    ' < <(for l in "$@"; do _text "$l"; done))
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
        # _SG_CORPUS_LINE: this re-invocation grades ONE SYNTHETIC LINE to test the classifier,
        # not a capture from a guest, so the proof-of-life predicates below must not apply to
        # it. Without this they did: a winutils-shaped corpus line with no module birth line
        # returned INCONCLUSIVE, whose output carries no "UNACCOUNTED", so three MUST lines
        # read as MISSED and recall fell 21/21 -> 18/21. Measured by the offline estate going
        # red the same evening. It is set by this script ON ITSELF and by nothing else -
        # sweep-life-selftest.sh asserts no other file sets it.
        out=$(_SG_CORPUS_LINE=1 SWEEP_GATE_LEDGER="$el" "$0" "$tl" 2>/dev/null)
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
# NEVER READ ONE FILE TWICE. matrix.sh passes its own log explicitly AND finds it again when it
# walks its output directory (R=$M/matrix.log, and $M is the directory the find walks), so every
# message that log carried was counted TWICE. MEASURED in run 38994277148: "install STALLED" was
# reported x2 against a single occurrence on disk, and the run's own line census differed from a
# de-duplicated one by 249 lines. A doubled count is not cosmetic here - the ROSE threshold
# compares the count against the ledger's recorded base, so a file read twice can resurface a
# dispositioned message as a regression that never happened.
# Deduplicated HERE rather than in the caller: the gate takes arbitrary paths from several
# harnesses, and it should be impossible to inflate its counts by naming a file twice.
_args=(); _seen=$(mktemp)
for _a in "$@"; do
    _rp=$(readlink -f -- "$_a" 2>/dev/null || printf '%s' "$_a")
    grep -qxF -- "$_rp" "$_seen" 2>/dev/null && continue
    printf '%s\n' "$_rp" >> "$_seen"; _args+=("$_a")
done
_dupes=$(( $# - ${#_args[@]} )); rm -f "$_seen"
[ "$_dupes" -gt 0 ] && echo "SWEEP-GATE-INPUT $_dupes of $# path(s) named the same file twice - read once each (a doubled count can forge a ROSE)"
set -- "${_args[@]}"
declare -A DECL_HIT=(); caused=0
NOW=$(mktemp); VAR=$(mktemp); PRIOR=$(mktemp); UPS=$(mktemp)
SWEEP_GATE_VARIANTS="$VAR" SWEEP_GATE_PRIOR="$PRIOR" SWEEP_GATE_UPSTREAM_OUT="$UPS" declared "$@" > "$NOW" || { rm -f "$NOW" "$VAR" "$PRIOR" "$UPS"; exit 2; }
# A CORPUS THAT DOES NOT CONTAIN THE BUILD UNDER TEST CANNOT CARRY A VERDICT ABOUT IT, so this
# refuses to grade instead of reporting counts. Jev on the fork: refuse 0.60.
#
# WHAT IT WOULD HAVE CAUGHT. Run 40037710497 was graded over 847 inputs and reported
# `unaccounted=26 risen=8`; the gate's extractor could not read the candidate's banner at all (see
# _sg_build_index), so every one of those 26 messages was billed to a build that had not been shown
# to be in the corpus. A whole day went into deciding which of the 26 to ledger and which to fix.
# It is a HARD refusal and not a metric, because the output of a gate that cannot attribute is not
# "a number to interpret" - it is a run that has to happen again.
#
# ONLY WITH --build. Without it there is no claim to check, and inventing one would turn every
# ad-hoc invocation over a single log into a failure.
if [ "${SG_CAND_ABSENT:-"-"}" = 1 ]; then
    echo "SWEEP-GATE-RESULT INVALID-NOBUILD the build under test ($BUILD) declared itself in NONE of the $# input log(s)"
    echo "  Every module that names a version in this input names a DIFFERENT build, so no line here"
    echo "  can be attributed to $BUILD and no verdict about it can be read off this corpus."
    echo "  What to check, in this order:"
    echo "    1. did the cells actually install the candidate? (matrix.sh asserts the agent hash; gate-remainder's assert_candidate)"
    echo "    2. did the collector take the logs the candidate wrote, or only the entry fixture's?"
    echo "    3. is --build right? it is the package MANIFEST's package_version, joined on MAJOR.MINOR.PATCH."
    echo "  The attributor's own view of this input set:"
    printf '    %s\n' "${SG_ATTR_TRAILER:-(no trailer)}"
    rm -f "$NOW" "$VAR" "$PRIOR" "$UPS"
    exit 1
fi
# PRINTED, because it is diagnosis: the lines are here to help read a failure, they just do not
# decide one. Each row names the vendored file that emits it.
# A RISE IN AN UPSTREAM MESSAGE IS OURS, AND IT IS THE ONE CASE THE EXCLUSION MUST NOT EAT.
# Jev graded the bare exclusion PARTIAL 0.71 on exactly this risk: a genuine failure of ours that
# only ever surfaces through a vendored function's warning - our code hands the shared pipe server a
# bad buffer and the only line emitted is QpsWrite's. Routine vendored noise is not acceptance
# criteria; a vendored count that JUMPS is, because the vendored code did not change - we did.
# Same scaled threshold the ledger uses for a dispositioned message, so one file states the rule.
UPCOUNTS="${SWEEP_GATE_UPSTREAM_COUNTS:-mgmt/harness/upstream-counts.txt}"
# AN ABSOLUTE COUNT CANNOT SCOPE A WORKLOAD. The baseline is one count per message taken from ONE
# campaign; campaigns differ in size, so comparing a count to it compares campaign shapes, not the
# product. MEASURED 2026-10-19: the baseline was generated on 20261018-183821, a THREE-cell win11-only
# campaign, and release acceptance sweeps EIGHT cells. All five vendored messages were flagged ROSE
# and blocked the 4.3.37 cut. Per cell they had not risen at all:
#   message                            base(3 cells)  per cell  expect(8)  actual  actual/expect
#   QioWriteBuffer: WriteFile 0xe8          12          4.00      32.0       24       0.75x
#   QpsRead: client is disconnected         17          5.67      45.3       33       0.73x
#   QpsReaderThread: read failed            16          5.33      42.7       31       0.73x
#   pipe_thread_client: QpsRead failed     191         63.67     509.3      510       1.00x
#   send_command_to_daemon: write failed    12          4.00      32.0       24       0.75x
# Four FELL per unit of work and the fifth is 1.00x - these are per-cell constants (the same cell type
# gives the same count in both campaigns: win11-clean 72 and 72, win11-reinstall 85 and 85). So the
# denominator is CELLS. Jev, given the per-cell figures: cells 1.00 (over qrexec invocations 0.00 and
# swept lines 0.00 - I had proposed invocations first and the measurement refuted it: a clean cell
# yields ONE qrexec wrapper log and an upgrade cell ~40, so that number measures COLLECTION, not work),
# rise_after_fix 0.21, conceals_real_rise 0.39.
# NEVER SILENTLY UNSCOPED: if either side's cell count is missing the comparison stays absolute and
# the output says so, so a baseline written without one cannot pass as normalised.
_up_cells_now="${SWEEP_GATE_CELLS:-}"
_up_cells_base=""
[ -f "$UPCOUNTS" ] && _up_cells_base=$(grep -am1 '^# cells:' "$UPCOUNTS" 2>/dev/null | sed 's/^# cells: *//')
case "$_up_cells_now" in (''|*[!0-9]*) _up_cells_now="" ;; esac
case "$_up_cells_base" in (''|*[!0-9]*) _up_cells_base="" ;; esac
[ "${_up_cells_now:-0}" -gt 0 ] 2>/dev/null || _up_cells_now=""
[ "${_up_cells_base:-0}" -gt 0 ] 2>/dev/null || _up_cells_base=""
up_rose=0
if [ -s "$UPS" ]; then
    echo "SWEEP-GATE-UPSTREAM $(grep -ac . "$UPS") message(s) from code we vendor read-only - diagnosis, NOT acceptance criteria (a RISE still blocks):"
    while IFS=$'\t' read -r _c _src _m; do
        _base=""
        [ -f "$UPCOUNTS" ] && _base=$(grep -aF -- "	$_m" "$UPCOUNTS" 2>/dev/null | head -1 | cut -f1)
        _tag=""
        if [ -n "$_base" ] && [ "$_base" -ge 0 ] 2>/dev/null; then
            # SCALE THE BASELINE TO THIS CAMPAIGN'S SIZE before applying the tolerance (see above).
            _exp="$_base"; _scalenote=""
            if [ -z "$_up_cells_now" ] || [ -z "$_up_cells_base" ]; then
                # NAMED ON EVERY ROW, rise or not: an absolute comparison across campaign sizes is the
                # defect this scaling exists for, so it can never pass unmarked.
                _scalenote=" [compared ABSOLUTE: no cell count on $([ -z "$_up_cells_base" ] && echo 'the baseline' || echo 'this run') - a campaign of a different size can forge a ROSE]"
            elif [ "$_up_cells_now" != "$_up_cells_base" ]; then
                _exp=$(( (_base * _up_cells_now + _up_cells_base / 2) / _up_cells_base ))
                _scalenote=" (x$_base over $_up_cells_base cell(s), scaled to $_up_cells_now)"
            fi
            if [ "$_exp" -lt 10 ]; then
                _at=$(( _exp * 2 )); [ "$_at" -lt $(( _exp + 3 )) ] && _at=$(( _exp + 3 ))
            else
                _at=$(( _exp + (_exp + 3) / 4 ))
            fi
            if [ "$_c" -gt "$_at" ]; then
                up_rose=$((up_rose+1))
                _tag="  <== ROSE from x$_exp$_scalenote (surfaces above x$_at): the vendored code did not change, our use of it did"
            else
                _tag="$_scalenote"
            fi
        else
            _tag="  (no recorded count yet - run --write-upstream-counts on a known-good campaign)"
        fi
        printf '  x%-4s %s%s\n     <- %s\n' "$_c" "$(printf '%s' "$_m" | cut -c1-110)" "$_tag" "$_src"
    done < "$UPS"
    if [ "${SWEEP_GATE_WRITE_UPSTREAM_COUNTS:-}" = 1 ]; then
        { echo "# GENERATED: counts of vendored-emitter messages on a known-good campaign."
          echo "# tools/sweep-gate.sh surfaces a RISE past the ledger's scaled threshold; the"
          echo "# routine count itself is diagnosis, not acceptance criteria."
          # THE CAMPAIGN SIZE IS PART OF THE MEASUREMENT, not a footnote: without it these counts
          # can only be compared with a campaign of the same shape, and the comparison silently
          # becomes a test of campaign size. Written whenever the caller passes SWEEP_GATE_CELLS.
          if [ -n "$_up_cells_now" ]; then echo "# cells: $_up_cells_now"
          else echo "# cells: UNKNOWN - caller passed no SWEEP_GATE_CELLS; counts below are not comparable across campaign sizes"; fi
          while IFS=$'\t' read -r _c _src _m; do printf '%s\t%s\n' "$_c" "$_m"; done < "$UPS"
        } > "$UPCOUNTS"
        echo "SWEEP-GATE-UPSTREAM wrote $UPCOUNTS"
    fi
fi
rm -f "$UPS"
# REPORTED, NEVER SILENT - the window exclusion included. A previous campaign's lines sit in the
# same appended per-day log under the SAME candidate build, so no build scope can reach them; what
# the window dropped is therefore its own figure, and an implausible one is the signal that the
# window (or the guest's clock) is wrong.
if [ "${SG_STALE_N:-0}" -gt 0 ]; then
    echo "SWEEP-GATE-PRIOR-RUN SWEEP EXCLUSION: $SG_STALE_N line(s) in $SG_STALE_F file(s) were written BEFORE this run's window (--since $SINCE), so they are a PREVIOUS run's and not this campaign's observations. This gate has no second clock: the per-cell sweep is what judges the guest's clock and refuses the window when it cannot be trusted."
elif [ -n "${SINCE:-}" ]; then
    echo "SWEEP-GATE-PRIOR-RUN SWEEP EXCLUSION: none - no input line predates this run's window (--since $SINCE)"
fi
# REPORTED, NEVER SILENT. An excluded file is named with the version it declares and the version
# that superseded it, so a wrong exclusion is visible in the same output as the verdict.
if [ -s "$PRIOR" ]; then
    echo "SWEEP-GATE-PRIOR-BUILD SWEEP EXCLUSION: $(grep -ac . "$PRIOR") log(s) taken out of the graded set - the capture itself shows their build was SUPERSEDED, so their lines are not the build under test's. Named, never dropped quietly:"
    # The newest version comes from the attributor's own row (column 3), not from a table this file
    # keeps: ranking versions in bash was half of the implementation that had to go.
    while IFS=$'\t' read -r _m _v _n _p; do
        printf '  %s %s (superseded by %s)  %s\n' "$_m" "$_v" "${_n:-?}" "$_p"
    done < "$PRIOR"
fi
rm -f "$PRIOR"
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
# ---- PROOF OF LIFE: THIS GATE MUST NOT GRADE WHAT IT WAS NOT GIVEN -----------------------------
# MEASURED 2026-10-21: an empty log file produced
#     SWEEP-GATE-RESULT unaccounted=0 risen=0 accounted=0 caused=0 stale_declarations=0   exit 0
# - a CLEAN verdict over nothing. The classification half of this gate is closed and finite (13
# registered emitters, 36 classified corpus lines, an unregistered line exits 1); what was missing
# is any assertion that it was handed a capture at all. That one hole is the ancestor of the sweep
# reading CLEAN over a capture with no agent log, of the collector not searching the product's own
# default directory, and of the appvm cells being graded while logging nowhere - each patched
# somewhere else, none of them here.
#
# A WINDOWS-UTILS MODULE DECLARES ITSELF WHEN IT STARTS, and that declaration is the proof. Birth
# lines per campaign capture, measured over the last three: 2484, then 327, then ZERO. The zero is
# yesterday's campaign, which graded a capture that could not have held an agent record. Either
# spelling counts: QWTBIRTH (one line per module at INFO, patches/windows-utils-single-birth-line)
# or the legacy "Log started, module name:" banner, which is proof whenever the level was raised.
#
# The predicate is NOT a knob. An input with windows-utils lines and no birth line is unjudgeable,
# and INCONCLUSIVE (exit 2) is what the callers already treat as instrument-fail rather than a
# product verdict.
_sg_life() { # $@=files -> "<non_empty_sources> <winutils_lines> <birth_lines> <unreadable_sources>"
    # UNPARSEABLE INPUT CAN NEVER BE CLEAN, and leaving that out let the hole back in through the
    # back door: a guest log that failed to decode - mojibake from a wrong-endian conversion, which
    # this project hit for real - matches no windows-utils prefix, so a content-only test concluded
    # "not our logs", skipped the proof-of-life requirement and returned CLEAN over a capture nobody
    # could read. Measured on a file named gui-agent-mojibake.log: exit 0, unaccounted=0.
    # So a non-empty source that yields NEITHER a windows-utils line NOR a harness line is counted
    # unreadable, and an unreadable source is INCONCLUSIVE.
    # ONE BIRTH LINE PER MODULE THAT RAN, NOT ONE FOR THE WHOLE INPUT. bl was a TOTAL, so a capture
    # in which one module declared itself and eleven did not satisfied this - and the eleven silent
    # modules' silence is exactly what the requirement exists to make meaningless. windows-utils
    # writes ONE FILE PER MODULE PER DAY (ADR-logging), so "per module" is "per file" here: a file
    # carrying windows-utils records must carry its own module's birth.
    # THE ONE LEGITIMATE EXCEPTION, STATED RATHER THAN DISCOVERED LATER: a module that started
    # yesterday and is still running writes into a NEW day's file without a fresh LogInit, so that
    # file can carry records with no birth line. A campaign cell boots the guest, so every module
    # starts inside the cell and this cannot arise there; if it ever does, the refusal names the file
    # and is an INCONCLUSIVE, which no ledger entry can silence.
    local f t src=0 wl=0 bl=0 bad=0 n w h nobirth=""
    for f in "$@"; do
        [ -f "$f" ] && [ -s "$f" ] || continue
        src=$((src+1))
        t=$(_text "$f")
        w=$(printf '%s' "$t" | command grep -acE '\[[0-9]{8}\.[0-9]{6}\.[0-9]{3}-[0-9]+(:[0-9]+)?-[IWEDV]\]' || true)
        wl=$((wl + ${w:-0}))
        n=$(printf '%s' "$t" | command grep -acE 'QWTBIRTH module=|Log started, module name:' || true); bl=$((bl + ${n:-0}))
        # A POWERSHELL SCRIPT CANNOT DECLARE A BIRTH, so it is not held to the requirement. Our PS
        # helpers log in the SAME bracketed shape windows-utils uses, so `w` counts their lines - and
        # then the per-file birth rule asks them for a LogInit that no PowerShell script can ever
        # emit. MEASURED on run 39880114972: with birth_lines=896 the ONLY files left in `nobirth`
        # were VMExec.ps1, get-appmenus.ps1, set-time.ps1 and sync-clock-from-dom0.ps1, and the
        # matrix counted that INCONCLUSIVE as a campaign failure (INVALID-SWEEP-UNCLASSED). The same
        # verdict appeared on the previous campaign with birth_lines=207 and a nobirth list that
        # covered our own modules too, so this is the pre-existing remainder, not a new break.
        # The discriminator is the WRITER: guest/*.ps1 log as `<script>.ps1-<date>.log`, and
        # windows-utils composes `<module>-<date>.log` from a module name that never contains
        # `.ps1-`, so this can never exempt a module that ought to declare itself.
        case "$(basename "$f")" in
          *.ps1-*.log) : ;;
          *) [ "${w:-0}" -gt 0 ] && [ "${n:-0}" = 0 ] && nobirth="$nobirth $(basename "$f")" ;;
        esac
        # the harness's own shape: a bracketed clock, or a declared level anywhere on the line
        h=$(printf '%s' "$t" | command grep -acE '^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\]|\[(INFO|WARN|ERROR|FATAL)\]' || true)
        bad=$((bad + ${h:-0}))   # reused below as the HARNESS-line total, not a per-file verdict
    done
    # UNREADABLE MEANS THE TEXT DID NOT DECODE, NOT "no log lines in it". Two wrong versions came
    # before this one. Per-file "no recognisable line" refused a capture in which any single file
    # carried none; whole-input "nothing parsed" refused a CAPTURE OF ANOTHER PROGRAM'S OUTPUT -
    # `Microsoft Windows [Version ...]`, `C:\>install.cmd /auto` - which is legitimate input this
    # gate's own doctrine insists on: "a capture is not an emitter", and holding one to the emitter
    # rule once took a count from 2142 to 472. Both versions were caught by T19e and four siblings.
    # The real condition is a DECODE FAILURE: a UTF-16 file read as bytes is mostly NULs, and a
    # wrong-endian conversion is mostly multibyte garbage, while any real capture - including a
    # German guest's NT-AUTORITAET lines - is overwhelmingly printable ASCII. So: if under half of
    # the input's bytes are printable or whitespace, nobody can read it and it cannot be clean.
    local unreadable=0 printable total
    printable=0; total=0
    for f in "$@"; do
        [ -f "$f" ] && [ -s "$f" ] || continue
        total=$(( total + $(wc -c < "$f") ))
        printable=$(( printable + $(tr -dc '[:print:][:space:]' < "$f" 2>/dev/null | wc -c) ))
    done
    [ "$total" -gt 0 ] && [ $(( printable * 2 )) -lt "$total" ] && unreadable=1
    # the names come AFTER the four numbers, so `read -r a b c d rest` keeps working
    printf '%s %s %s %s%s' "$src" "$wl" "$bl" "$unreadable" "$nobirth"
}
# The seen-to-fail leg of tools/tests/sweep-life-selftest.sh deletes the block between the two
# markers below to prove that this predicate is what refuses an ungradeable capture. A line-count
# range broke the moment the block grew, and the first marker comment NAMED the closing marker, so
# the range closed on the comment and removed two lines. A marker must not appear in prose.
# SG-PARTIAL-A  (to the B marker: driven by tools/tests/sweep-life-selftest.sh; neither marker
# names the other)
# A TRUNCATED LOG IS NOT A COMPLETE ONE. mgmt/harness/log-sweep-collect.ps1 caps the bytes it
# pulls per file and, when it hits that cap, sends `partial=1` with the file's true line count -
# head plus W/E/suspicious lines plus tail, and NOTHING ELSE. tools/log-sweep.py reads that flag
# and turns it into a DATA problem; this gate never looked, so on the paths that sweep decoded
# guest logs WITHOUT running analyze (mgmt/harness/matrix.sh:2957 is one) a truncated capture was
# graded as a whole one, and the lines the cap dropped counted as absent. Found by the component
# re-grade, 2026-10-21; Jev put fixing it before the campaign at 0.60.
# WHERE THE FLAG LIVES: `log-sweep.py decode --out <dir>` writes the files under <dir>/files/ and
# a <dir>/meta.json whose files[] entries carry partial. So for an input at <dir>/files/<name> the
# flag is two directories up. An input with no such meta.json - a harness log, a hand-made
# fixture - is not covered, which is why this is silent when it finds nothing.
# AND IT IS DUPLICATION, SAID OUT LOUD: tools/log-sweep.py already reads this same flag at
# decode time and turns it into a DATA problem, so 'a truncated capture is not gradeable' now
# lives in two tools and can drift. Jev scored that objection 0.48 - it is real. The reason it
# stays is that this gate is run on paths which never invoke analyze at all, so a check living
# only there does not cover them. The drift's direction is a false RED (this refuses while
# analyze passes), which is visible rather than silent. It is recorded as debt on the same
# follow-up as collapsing sweep_gate_rc into this gate, which Jev deferred past the campaign
# at 0.36: both are 'one decision, two deciders' and both should be fixed in that pass.
_sg_partial() { # $@=files -> the basenames recorded partial=1, space-separated
    local f d out
    for f in "$@"; do
        [ -f "$f" ] || continue
        d=$(dirname "$(dirname "$f")")
        [ -r "$d/meta.json" ] || continue
        out=$(python3 tools/sweep-gate-partial.py "$d/meta.json" "$(basename "$f")" 2>/dev/null)   # the gate cd's to the repo root at the top
        [ -n "$out" ] && printf ' %s' "$out"
    done
}
_sg_trunc=$(_sg_partial "$@")
if [ -n "${_sg_trunc// /}" ]; then
    echo "SWEEP-GATE-RESULT INCONCLUSIVE truncated=$_sg_trunc"
    echo "  The collector hit its size cap on these file(s) and sent partial=1: what was pulled is"
    echo "  the head, the W/E/suspicious lines and the tail - not the file. An error between those"
    echo "  windows is absent from this input, so 'nothing unaccounted' would be a statement about"
    echo "  the truncation and not about the run. Re-pull with a higher cap before grading."
    exit 2
fi
# SG-PARTIAL-B
# SG-LIFE-BEGIN
read -r _sg_src _sg_wl _sg_bl _sg_bad _sg_nobirth < <(_sg_life "$@")
# NARROW ON PURPOSE: synthetic classifier input is exempt from the MODULE BIRTH requirement
# only. A hand-made corpus line has no birth line by construction, but it is still a readable
# non-empty source - so "nothing was swept" and "nothing readable" stay in force even for the
# suites. Suppressing all three would have been broader than the reason for suppressing any.
[ "${_SG_CORPUS_LINE:-0}" = 1 ] && { _sg_wl=0; _sg_nobirth=""; }
if [ "${_sg_src:-0}" = 0 ]; then
    echo "SWEEP-GATE-RESULT INCONCLUSIVE sources=0 - nothing was swept, so this gate has no verdict to give"
    echo "  $# path(s) were named and none of them is a readable non-empty file. A clean run has logs."
    exit 2
fi
if [ "${_sg_bad:-0}" -gt 0 ]; then
    echo "SWEEP-GATE-RESULT INCONCLUSIVE sources=$_sg_src unreadable=1 (nothing in the input parsed)"
    echo "  $_sg_src non-empty source(s) and NOT ONE recognisable log line between them - neither a"
    echo "  windows-utils record nor a harness line. A capture nobody can read cannot be clean:"
    echo "  check the collector's decode (a wrong-endian UTF-16 conversion produces exactly this)."
    exit 2
fi
if [ -n "${_sg_nobirth:-}" ] && [ "${_sg_bl:-0}" -gt 0 ]; then
    echo "SWEEP-GATE-RESULT INCONCLUSIVE sources=$_sg_src winutils_lines=$_sg_wl birth_lines=$_sg_bl nobirth=$_sg_nobirth"
    echo "  Some modules declared themselves and these did NOT:$_sg_nobirth"
    echo "  windows-utils writes one file per module, so a file with records but no birth line is a"
    echo "  module whose LogInit was never seen - and that module's SILENCE cannot be read as clean."
    echo "  One birth line somewhere in the capture says nothing about the others. Raise LogLevel for"
    echo "  this cell, or ship a package carrying patches/windows-utils-single-birth-line.patch."
    exit 2
fi
if [ "${_sg_wl:-0}" -gt 0 ] && [ "${_sg_bl:-0}" = 0 ]; then
    echo "SWEEP-GATE-RESULT INCONCLUSIVE sources=$_sg_src winutils_lines=$_sg_wl birth_lines=0"
    echo "  Windows-utils logs are present but NO module declared itself: no QWTBIRTH line and no"
    echo "  'Log started, module name:' banner. A capture with no module birth cannot hold that"
    echo "  module's errors either, so silence here means nothing. Raise LogLevel for this cell, or"
    echo "  ship a package carrying patches/windows-utils-single-birth-line.patch."
    exit 2
fi
# SG-LIFE-END

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
    # CAUSED, declared by this run: shown with its reason, not counted against acceptance.
    _caused=""
    if [ "${#DECL_RX[@]}" -gt 0 ]; then
        for _i in "${!DECL_RX[@]}"; do
            if printf '%s' "$msg" | grep -qaE -- "${DECL_RX[$_i]}"; then
                _caused="${DECL_WHY[$_i]}"; DECL_HIT[$_i]=1; break
            fi
        done
    fi
    if [ -n "$_caused" ]; then
        caused=$((caused+1))
        printf '  CAUSED      x%-4s%s %s\n     -> %s\n' "$cnt" "$vtag" "$(printf '%s' "$msg" | cut -c1-104)" "$(printf '%s' "$_caused" | cut -c1-150)" >> "$ACCLIST"
    elif [ -z "$base" ] || [ -z "$note" ]; then
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
# AN UNMATCHED DECLARATION IS A FAILURE OF ITS OWN. The run said it causes this and it did not, so
# the claim is stale and must not sit there excusing a line it no longer explains.
decl_unmatched=0
if [ "${#DECL_RX[@]}" -gt 0 ]; then
    for _i in "${!DECL_RX[@]}"; do
        if [ -z "${DECL_HIT[$_i]:-}" ]; then
            if [ "${DECL_RARE[$_i]:-0}" = 1 ]; then
                # Reported, never silent: a rare declaration that stops matching for good should be
                # noticed by a reader even though it does not fail the run.
                echo "SWEEP-GATE: declared-caused (rare) not seen this run: ${DECL_RX[$_i]}"
                echo "     the run can cause this and did not - expected for a rare condition, shown so it cannot rot unnoticed"
            else
                decl_unmatched=$((decl_unmatched+1))
                echo "SWEEP-GATE: DECLARED-CAUSED NEVER MATCHED: ${DECL_RX[$_i]}"
                echo "     the run claims to cause this EVERY time and nothing in its logs does - the declaration is stale"
            fi
        fi
    done
fi
if [ "$caused" -gt 0 ]; then
    echo "SWEEP-GATE: $caused message(s) DECLARED CAUSED by this run (shown, not acceptance criteria):"
fi
# printed ALWAYS, pass or fail, so a recurring known error stays visible instead of becoming silence
if [ "$acc" -gt 0 ] || [ "$caused" -gt 0 ]; then
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
read -r nolevel total msilevel < <(unlevelled "$@")
echo "SWEEP-GATE-COVERAGE lines=$total with_declared_level=$((total - nolevel)) without=$nolevel third_party=${msilevel:-0}"
# AND NOW IT COUNTS. Naming the gap and exiting 0 is what kept this instrument advisory: it
# reported `lines=65 with_declared_level=6 without=59 third_party=0` - 9% of its input judged - and
# passed, while quick-upgrade.sh:167 said it would only gate "when its coverage and its judge's
# score support it". The two halves locked each other, so a run could pass with real errors in its
# log. The emitters declare now (quick-upgrade.sh log(), matrix.sh say()), which takes coverage to
# 100% on our own logs, so a line of OURS without a level is an emitter REGRESSION and is treated
# as one. msiexec's verbose log is third-party and has no severity to read; it is excluded by count.
blind=0
if [ "${nolevel:-0}" -gt 0 ]; then
    echo "  $nolevel line(s) carry NO declared level, so this tool cannot judge them. That is the gap, named."
    if [ "${msilevel:-0}" -gt 0 ]; then
        echo "  of those, $msilevel are msiexec's own verbose log - a third-party format with no severity to read."
    fi
    blind=$(( nolevel - ${msilevel:-0} ))
    if [ "$blind" -gt 0 ]; then
        echo "  $blind of them are OURS. An emitter that does not declare makes this gate judge a FRACTION of the run,"
        echo "  which is how it came to read 6 lines in 65 and pass. Declare the level at the emitter; guessing it"
        echo "  from the words is not an option here (blog_level refuses vocabulary, and was right to)."
        echo "  To run anyway while an emitter is being fixed: SWEEP_GATE_ALLOW_UNDECLARED=1."
        [ "${SWEEP_GATE_ALLOW_UNDECLARED:-0}" = 1 ] && { echo "  (allowed by SWEEP_GATE_ALLOW_UNDECLARED=1 - recorded, not hidden)"; blind=0; }
    fi
fi

if [ "${blind:-0}" -gt 0 ]; then
    echo "SWEEP-GATE-RESULT undeclared_ours=$blind - this gate judged only part of the run, so its silence means nothing"
    exit 1
fi
if [ "$newn" -gt 0 ] || [ "$rose" -gt 0 ]; then
    echo "SWEEP-GATE-RESULT unaccounted=$newn risen=$((rose + up_rose)) accounted=$acc caused=$caused stale_declarations=$decl_unmatched"
[ -z "${SWEEP_GATE_DUMP:-}" ] && echo "  every distinct line behind these messages: re-run with SWEEP_GATE_DUMP=<path> - grouping is presentation, nothing is discarded"
    echo "  Each is a real error our code declared. It is a defect to fix, or an entry for $LEDGER"
    echo "  recording what it means. Reading it and moving on is not one of the options."
    exit 1
fi
if [ "${up_rose:-0}" -gt 0 ]; then
    echo "SWEEP-GATE-RESULT unaccounted=0 risen=$up_rose accounted=$acc"
    exit 1
fi
if [ "${decl_unmatched:-0}" -gt 0 ]; then
    echo "SWEEP-GATE-RESULT unaccounted=0 risen=0 accounted=$acc caused=$caused stale_declarations=$decl_unmatched"
    exit 1
fi
echo "SWEEP-GATE-RESULT unaccounted=0 risen=0 accounted=$acc caused=$caused stale_declarations=0"
