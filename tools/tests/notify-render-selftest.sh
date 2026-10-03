#!/usr/bin/env bash
# notify-render-selftest.sh - the render proof matrix for EVERY dom0 error notification of Qubes Windows Tools (rz39):
# each one is produced offline, exactly as dom0 receives it, and held to the text rules (agent notifyerr.h; docs/DESIGN-error-notify.md
# section 8) - header <= 60 characters with no code, file name, count or product prefix; a body of 2 to 4 lines; the technical line
# present; the code's meaning from its own source's table; the route's redaction accepting it. A rule never seen to fail is
# decoration, so every rule is also broken on purpose and the suite must then FAIL.
#
#   C   agent/gui-agent/notifyrender_test.c renders every row of notifytexts.h (the agent's own faults, notifhost's own) with gcc:
#         clean MUST pass; each knob MUST fail -
#         NOTIFYTEXT_DEFECT_HEADER (the old header style)   NOTIFYERR_DEFECT_FLATBODY (one body line)   NOTIFYERR_DEFECT_NOTECH
#         NOTIFYTEXT_DEFECT_WRONGSOURCE (an exit code phrased by the Win32 table)   NOTIFYTEXT_DEFECT_SECRETWORD (a refused word)
#       plus a shape check: every row key main.c and notifhost.cpp ask for exists in notifytexts.h
#   PS  tools/tests/notify-render-test.ps1 renders every death (all record kinds, the hang included) through the shipped reporter
#       and route, and every Send-QwtError call in guest/*.ps1: clean MUST pass; a copy of the reporter or the route with one
#       `# GUARD:<name>` line replaced by its defect MUST fail on that guard's check -
#         hdrplain   the old header (product prefix, exe, code, count)       techline       no technical line
#         codetable  the process table for every source (rz39 defect 3)     redactfallback a .NET type the route refuses is sent
#         hang       a hang rendered as an exit (rz39 defect 2)              taskid         the old task ids (rz39 defect 6)
#         scmwords   "time 1 per the SCM" (rz39 defect 4)                    bodylines      the body collapses into one line (route)
#
#   AGENT_DIR=<path>   the agent checkout (default: the agent submodule)      NOTIFYRENDER_OUT=<dir>   outputs (default: mktemp)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AGENT="${AGENT_DIR:-$ROOT/agent}"
PWSH="${PWSH:-/home/user/pwsh/pwsh}"
[ -x "$PWSH" ] || PWSH=/home/user/bin/pwsh7/pwsh
OUT="${NOTIFYRENDER_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/notify-render-selftest-XXXXXX")}"
mkdir -p "$OUT"
bad=0
say() { printf '%s\n' "$*"; }

# ---- C: the agent's and notifhost's rows ---------------------------------------------------------------------
if [ ! -f "$AGENT/gui-agent/notifyrender_test.c" ]; then say "FAIL  $AGENT/gui-agent/notifyrender_test.c missing (set AGENT_DIR) - nothing ran"; exit 2; fi
cbuild() { gcc -std=c99 -Wall -Wextra -Werror -I"$AGENT/gui-agent" $2 "$AGENT/gui-agent/notifyrender_test.c" -o "$OUT/$1" 2>"$OUT/$1.build.err"; }
if cbuild c-clean ""; then
    "$OUT/c-clean" >"$OUT/c-clean.out" 2>&1; rc=$?
    n=$(grep -c '^ok' "$OUT/c-clean.out"); f=$(grep -c '^FAIL' "$OUT/c-clean.out")
    if [ $rc -eq 0 ] && [ "$f" -eq 0 ] && [ "$n" -ge 100 ]; then say "PASS  C clean: rc=0 ok=$n fail=0 (every row of notifytexts.h rendered: $OUT/c-clean.out)"
    else say "FAIL  C clean: rc=$rc ok=$n fail=$f ($(grep -m1 '^FAIL' "$OUT/c-clean.out"))"; bad=1; fi
else say "FAIL  C clean build: $(head -3 "$OUT/c-clean.build.err")"; bad=1; fi
for d in NOTIFYTEXT_DEFECT_HEADER NOTIFYERR_DEFECT_FLATBODY NOTIFYERR_DEFECT_NOTECH NOTIFYTEXT_DEFECT_WRONGSOURCE NOTIFYTEXT_DEFECT_SECRETWORD; do
    if cbuild "c-$d" "-D$d"; then
        "$OUT/c-$d" >"$OUT/c-$d.out" 2>&1; rc=$?
        f=$(grep -c '^FAIL' "$OUT/c-$d.out")
        if [ $rc -ne 0 ] && [ "$f" -gt 0 ]; then say "PASS  C defect $d: suite FAILED as required (rc=$rc, $f failing checks: $(grep -m1 '^FAIL' "$OUT/c-$d.out" | cut -c6-110))"
        else say "FAIL  C defect $d: suite did NOT fail (rc=$rc) - that rule is decoration"; bad=1; fi
    else say "FAIL  C defect $d build: $(head -3 "$OUT/c-$d.build.err")"; bad=1; fi
done
# every key a call site asks for is a row
for src in "$AGENT/gui-agent/main.c" "$ROOT/tools/notifhost/notifhost.cpp"; do
    [ -f "$src" ] || { say "FAIL  $src missing"; bad=1; continue; }
    for key in $(grep -oE 'QerrTextFind\("[a-z-]+"\)|ReportErrorSelf\("[a-z-]+"\)' "$src" | grep -oE '"[a-z-]+"' | tr -d '"' | sort -u); do
        if grep -qE "^\s*\{ \"$key\"," "$AGENT/gui-agent/notifytexts.h"; then say "PASS  shape: $(basename "$src") asks for row '$key' and notifytexts.h has it"
        else say "FAIL  shape: $(basename "$src") asks for row '$key' which notifytexts.h does not have"; bad=1; fi
    done
done
if grep -q 'ReportErrorSelf("' "$ROOT/tools/notifhost/notifhost.cpp" && [ "$(grep -c 'ReportErrorSelf("' "$ROOT/tools/notifhost/notifhost.cpp")" -eq 2 ]; then say "PASS  shape: notifhost.cpp's two FATAL exits each report their row (UNCOMPILED: CI builds notifhost)"
else say "FAIL  shape: notifhost.cpp should call ReportErrorSelf(\"<row>\") exactly twice"; bad=1; fi

# ---- PowerShell: the deaths and the scripts' calls --------------------------------------------------------------
SUITE="$ROOT/tools/tests/notify-render-test.ps1"
REPORTER="$ROOT/guest/qwt-report-death.ps1"
HELPER="$ROOT/guest/qwt-notify-error.ps1"
if [ ! -x "$PWSH" ]; then say "FAIL  pwsh not found at $PWSH - the PowerShell half DID NOT RUN"; bad=1
else
    "$PWSH" -NoProfile -File "$SUITE" >"$OUT/ps-clean.out" 2>&1; rc=$?
    n=$(grep -c '^ok' "$OUT/ps-clean.out"); f=$(grep -c '^FAIL' "$OUT/ps-clean.out")
    if [ $rc -eq 0 ] && [ "$f" -eq 0 ] && [ "$n" -ge 200 ]; then say "PASS  PS clean: rc=0 ok=$n fail=0 (every death and script notification rendered: $OUT/ps-clean.out)"
    else say "FAIL  PS clean: rc=$rc ok=$n fail=$f ($(grep -m1 -E '^FAIL' "$OUT/ps-clean.out" || grep -m1 -iE 'exception|error' "$OUT/ps-clean.out" | cut -c1-200))"; bad=1; fi

    # knob -> (which file, the defect line that replaces the GUARD line, the check it must fail)
    knob_file() { case "$1" in bodylines) printf '%s' "$HELPER" ;; *) printf '%s' "$REPORTER" ;; esac; }
    knob_line() {
        case "$1" in
            hdrplain)       printf '%s' '    $header = "Qubes Windows Tools, $($Death.component): DIED: $($Death.exe) $what; $codeText; death $Number this boot"   # DEFECT: the old header' ;;
            techline)       printf '%s' '    $tech = '"'"'see the log; reported once per boot'"'"'   # DEFECT: no technical line' ;;
            codetable)      printf '%s' '    $table = $script:QwtDeathCodeTables['"'"'process'"'"']   # DEFECT: the process table for every source' ;;
            redactfallback) printf '%s' '            if ($false) { }   # DEFECT: a type the route refuses is rendered anyway' ;;
            hang)           printf '%s' '            if ($false) { }   # DEFECT: a hang is an exit' ;;
            taskid)         printf '%s' '                $r.component = ($task.TrimStart('"'"'\'"'"').ToLowerInvariant() -replace '"'"'[^a-z0-9-]'"'"', '"'"''"'"')   # DEFECT: the old task ids' ;;
            scmwords)       printf '%s' '                    $cause = "Cause: terminated unexpectedly, time $($Death.svcCount) per the SCM."   # DEFECT: jargon' ;;
            bodylines)      printf '%s' '    return ($lines[0] + "`r`n" + (($lines | Select-Object -Skip 1) -join '"'"' '"'"'))   # DEFECT: the body collapses into one line' ;;
        esac
    }
    knob_target() {
        case "$1" in
            hdrplain)       printf '%s' 'header has no product prefix' ;;
            techline)       printf '%s' 'technical line says where the evidence is' ;;
            codetable)      printf '%s' 'cause is not phrased by another table or in jargon (no '"'"'TerminateProcess'"'"')' ;;
            redactfallback) printf '%s' 'the death is sent' ;;
            hang)           printf '%s' 'the hang is rendered as a hang' ;;
            taskid)         printf '%s' 'the component is the task'"'"'s or executable'"'"'s machine id' ;;
            scmwords)       printf '%s' 'cause is not phrased by another table or in jargon (no '"'"'per the SCM'"'"')' ;;
            bodylines)      printf '%s' 'body is 2 to 4 lines' ;;
        esac
    }
    for k in hdrplain techline codetable redactfallback hang taskid scmwords bodylines; do
        src=$(knob_file "$k"); copy="$OUT/defect-$k.ps1"
        hits=$(grep -c "# GUARD:$k\$" "$src")
        if [ "$hits" -ne 1 ]; then say "FAIL  PS knob $k: expected exactly 1 '# GUARD:$k' line in $(basename "$src"), found $hits"; bad=1; continue; fi
        REPL="$(knob_line "$k")" python3 - "$src" "$copy" "$k" <<'EOF'
import os, sys
src, dst, knob = sys.argv[1:4]
repl = os.environ['REPL']
out = [repl if line.endswith('# GUARD:' + knob) else line for line in open(src, encoding='utf-8').read().split('\n')]
open(dst, 'w', encoding='utf-8').write('\n'.join(out))
EOF
        if [ "$k" = bodylines ]; then "$PWSH" -NoProfile -File "$SUITE" -HelperPath "$copy" >"$OUT/ps-defect-$k.out" 2>&1; rc=$?
        else "$PWSH" -NoProfile -File "$SUITE" -ReporterPath "$copy" >"$OUT/ps-defect-$k.out" 2>&1; rc=$?; fi
        f=$(grep -c '^FAIL' "$OUT/ps-defect-$k.out")
        if [ $rc -ne 0 ] && grep -qF "FAIL $(knob_target "$k")" "$OUT/ps-defect-$k.out" 2>/dev/null || { [ $rc -ne 0 ] && grep -q "^FAIL .*$(knob_target "$k")" "$OUT/ps-defect-$k.out"; }; then
            say "PASS  PS defect $k: suite FAILED as required on its target (rc=$rc, $f failing checks)"
        else
            say "FAIL  PS defect $k: rc=$rc target-failed=$(grep -c "^FAIL .*$(knob_target "$k")" "$OUT/ps-defect-$k.out") first=[$(grep -m1 '^FAIL' "$OUT/ps-defect-$k.out" | cut -c1-160)]"; bad=1
        fi
    done
fi

say "--- outputs in $OUT"
exit $bad
