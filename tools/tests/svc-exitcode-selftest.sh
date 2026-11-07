#!/usr/bin/env bash
# SvcMainLoop ends the service with the WORKER'S error, so the SCM logs 7023 and recovery fires.
# Reads the source we SHIP: winutils/ (the submodule), not a mirror and not a patch.
# run: tools/tests/svc-exitcode-selftest.sh
# pass: exit 0
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WU="${WINDOWS_UTILS_SRC:-$ROOT/winutils}"
STUB="$ROOT/tools/tests/win32stub"
TEST="$ROOT/tools/tests/svc-exitcode-test.c"
OUT="${SVCEXIT_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/svc-exitcode-selftest-XXXXXX")}"
mkdir -p "$OUT"
bad=0
say() { printf '%s\n' "$*"; }

SVC="$WU/src/service.c"
for need in "$SVC" "$WU/include/service.h" "$WU/include/log.h"; do
    if [ ! -f "$need" ]; then say "FAIL  $need is missing (is the winutils submodule checked out? set WINDOWS_UTILS_SRC) - nothing ran (missing data fails)"; exit 2; fi
done

# ---- UNCOMPILED: the shipped file parses against the stubs + the real headers ----------------------------------
gcc -std=c99 -fsyntax-only -Wall -Wextra -D_DEFAULT_SOURCE -I"$STUB" -I"$WU/include" "$SVC" >"$OUT/syntax.out" 2>&1
errs=$(grep -c 'error:' "$OUT/syntax.out")
if [ "$errs" -eq 0 ]; then say "PASS  syntax: winutils service.c parses with gcc -fsyntax-only (UNCOMPILED here; CI builds windows-utils.dll)"
else say "FAIL  syntax: $errs error(s): $(grep -m1 'error:' "$OUT/syntax.out")"; bad=1; fi

# ---- the behaviour: the shipped service.c must report the worker's error --------------------------------------
build() { # $1 label, $2 service.c to include
    mkdir -p "$OUT/$1" && cp "$2" "$OUT/$1/service.c" &&
    gcc -std=c99 -Wall -Wextra -Werror -D_DEFAULT_SOURCE -I"$OUT/$1" -I"$STUB" -I"$WU/include" "$TEST" -o "$OUT/$1/run" 2>"$OUT/$1/build.err"
}
if build clean "$SVC"; then
    "$OUT/clean/run" >"$OUT/clean.out" 2>&1; rc=$?
    n=$(grep -c '^ok' "$OUT/clean.out"); f=$(grep -c '^FAIL' "$OUT/clean.out")
    if [ "$rc" -eq 0 ] && [ "$f" -eq 0 ] && [ "$n" -ge 14 ]; then say "PASS  clean: winutils service.c reports the worker's error to the SCM (rc=0 ok=$n fail=0)"
    else say "FAIL  clean: rc=$rc ok=$n fail=$f"; grep '^FAIL' "$OUT/clean.out" | head -5; bad=1; fi
else say "FAIL  clean build: $(head -3 "$OUT/clean/build.err")"; bad=1; fi

# ---- the knob for the REQUESTED-STOP exemption (docs/ADR-supervision.md 5) ------------------------------------
# service.c has two halves: forward the worker's error (above), and never report it for a stop the SCM ASKED for.
# A check never seen to fail is decoration, so the knob is the shipped file with only the exemption taken out:
# case 7 must then fail.
python3 - "$SVC" "$OUT/service.noexempt.c" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
m = re.search(r"\n        if \(InterlockedCompareExchange\(&g_StopRequested, 0, 0\) != 0\)\n        \{.*?\n        \}\n        else\n        \{\n(.*?)\n        \}\n", s, re.S)
if not m:
    sys.exit("the exemption branch was not found - the knob cannot be built")
open(sys.argv[2], "w").write(s[:m.start()] + "\n" + m.group(1) + "\n" + s[m.end():])
PY
if [ -f "$OUT/service.noexempt.c" ] && build noexempt "$OUT/service.noexempt.c"; then
    "$OUT/noexempt/run" >"$OUT/noexempt.out" 2>&1; rc=$?
    if [ "$rc" -ne 0 ] && grep -q '^FAIL requested stop: STOPPED carries exit code 0' "$OUT/noexempt.out"; then
        say "PASS  knob requested-exemption: with the exemption removed the suite FAILED as required (rc=$rc: $(grep -m1 '^FAIL' "$OUT/noexempt.out" | cut -c6-95))"
    else say "FAIL  knob requested-exemption: the suite did NOT fail on a requested stop reporting the worker's error (rc=$rc)"; bad=1; fi
else say "FAIL  knob requested-exemption: could not build the knob ($(head -2 "$OUT/noexempt/build.err" 2>/dev/null))"; bad=1; fi

say "--- outputs in $OUT"
exit $bad
