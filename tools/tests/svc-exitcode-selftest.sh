#!/usr/bin/env bash
# svc-exitcode-selftest.sh - offline proof matrix for patches/windows-utils-service-exit-code.patch (docs/ADR-supervision.md
# 2): windows-utils' SvcMainLoop - the service wrapper of BOTH QrexecAgent (core-agent qrexec-agent.c) and QdbDaemon
# (core-qubesdb db-daemon.c) - must end the service with the worker thread's error, so the SCM logs event 7023 and the
# recovery actions the installer arms (Set-QubesServiceRecovery, failureflag) actually fire. Before the patch SvcSetState
# ignored its exit-code argument and every stop was exit 0 - the standing finding behind health-check.ps1 section 2b.
#
# Runs on this dev qube with gcc + the read-only windows-utils mirror (no rig, no guest, no Windows toolchain):
#   apply     the patch applies to the EXACT ref CI clones (WINDOWS_UTILS_REF in .github/workflows/build.yml), checked with
#             git apply --check on that ref's tree, and the markers the workflow step asserts are present afterwards
#   clean     tools/tests/svc-exitcode-test.c against the PATCHED service.c MUST pass
#   defect    the same suite against the UNPATCHED service.c (the defect present) MUST fail - a guard never seen to fail
#             is decoration
#   syntax    the patched service.c parses with gcc -fsyntax-only against the stubs + the REAL headers (UNCOMPILED: CI
#             builds windows-utils.dll from it)
#
#   WINDOWS_UTILS_SRC=<path>   the mirror checkout (default: $ROOT/upstream/ro/qubes-windows-utils; missing = FAIL, never a skip)
#   SVCEXIT_OUT=<dir>          where the builds and outputs go (default: a mktemp dir)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MIRROR="${WINDOWS_UTILS_SRC:-$ROOT/upstream/ro/qubes-windows-utils}"
PATCH="$ROOT/patches/windows-utils-service-exit-code.patch"
STUB="$ROOT/tools/tests/win32stub"
TEST="$ROOT/tools/tests/svc-exitcode-test.c"
OUT="${SVCEXIT_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/svc-exitcode-selftest-XXXXXX")}"
mkdir -p "$OUT"
bad=0
say() { printf '%s\n' "$*"; }

if [ ! -d "$MIRROR/.git" ] && [ ! -f "$MIRROR/src/service.c" ]; then say "FAIL  windows-utils mirror not at $MIRROR (set WINDOWS_UTILS_SRC) - nothing ran (missing data fails)"; exit 2; fi
if [ ! -f "$PATCH" ]; then say "FAIL  $PATCH missing"; exit 2; fi

# ---- the ref CI builds, and the patch against it --------------------------------------------------------------
REF=$(grep -m1 -oE 'WINDOWS_UTILS_REF:\s*\S+' "$ROOT/.github/workflows/build.yml" | awk '{print $2}')
if [ -z "$REF" ]; then say "FAIL  WINDOWS_UTILS_REF not found in .github/workflows/build.yml"; exit 2; fi
rm -rf "$OUT/tree" && mkdir -p "$OUT/tree"
if git -C "$MIRROR" archive "$REF" src/service.c include/service.h include/log.h 2>/dev/null | tar -x -C "$OUT/tree"; then
    say "ok    the mirror holds $REF (the ref CI clones); service.c and the headers extracted from it"
else
    say "FAIL  cannot extract src/service.c at $REF from the mirror at $MIRROR"; exit 2
fi
cp "$OUT/tree/src/service.c" "$OUT/service.orig.c"
if (cd "$OUT/tree" && git apply --check "$PATCH" >"$OUT/apply-check.out" 2>&1 && git apply "$PATCH" >"$OUT/apply.out" 2>&1); then
    say "PASS  apply: the patch applies to windows-utils $REF (git apply --check + apply)"
else
    say "FAIL  apply: $(head -2 "$OUT/apply-check.out" "$OUT/apply.out" 2>/dev/null | tr '\n' ' ')"; bad=1
fi
cp "$OUT/tree/src/service.c" "$OUT/service.patched.c"
# the two markers the workflow step asserts after applying (a patch that no-ops would ship the bug with a new version)
if grep -q 'GetExitCodeThread(g_Service->WorkerThread' "$OUT/service.patched.c" && ! grep -q 'UNREFERENCED_PARAMETER(win32ExitCode)' "$OUT/service.patched.c"; then
    say "PASS  markers: the patched file carries the forwarding call and no longer the swallow"
else
    say "FAIL  markers: the patched service.c does not show the expected shape"; bad=1
fi

# ---- UNCOMPILED: the patched file parses against the stubs + the real headers --------------------------------
gcc -std=c99 -fsyntax-only -Wall -Wextra -D_DEFAULT_SOURCE -I"$STUB" -I"$OUT/tree/include" "$OUT/service.patched.c" >"$OUT/syntax.out" 2>&1
errs=$(grep -c 'error:' "$OUT/syntax.out")
if [ "$errs" -eq 0 ]; then say "PASS  syntax: patched service.c parses with gcc -fsyntax-only (UNCOMPILED here; CI builds windows-utils.dll)"
else say "FAIL  syntax: $errs error(s): $(grep -m1 'error:' "$OUT/syntax.out")"; bad=1; fi

# ---- the behaviour: clean must pass, the defect must fail ------------------------------------------------------
build() { # $1 label, $2 service.c to include
    mkdir -p "$OUT/$1" && cp "$2" "$OUT/$1/service.c" &&
    gcc -std=c99 -Wall -Wextra -Werror -D_DEFAULT_SOURCE -I"$OUT/$1" -I"$STUB" -I"$OUT/tree/include" "$TEST" -o "$OUT/$1/run" 2>"$OUT/$1/build.err"
}
if build clean "$OUT/service.patched.c"; then
    "$OUT/clean/run" >"$OUT/clean.out" 2>&1; rc=$?
    n=$(grep -c '^ok' "$OUT/clean.out"); f=$(grep -c '^FAIL' "$OUT/clean.out")
    if [ "$rc" -eq 0 ] && [ "$f" -eq 0 ] && [ "$n" -ge 14 ]; then say "PASS  clean: patched service.c reports the worker's error to the SCM (rc=0 ok=$n fail=0)"
    else say "FAIL  clean: rc=$rc ok=$n fail=$f"; grep '^FAIL' "$OUT/clean.out" | head -5; bad=1; fi
else say "FAIL  clean build: $(head -3 "$OUT/clean/build.err")"; bad=1; fi

if build defect "$OUT/service.orig.c"; then
    "$OUT/defect/run" >"$OUT/defect.out" 2>&1; rc=$?
    f=$(grep -c '^FAIL' "$OUT/defect.out")
    if [ "$rc" -ne 0 ] && [ "$f" -gt 0 ]; then say "PASS  defect: against the UNPATCHED service.c the suite FAILED as required (rc=$rc, $f failing checks: $(grep '^FAIL' "$OUT/defect.out" | head -1 | cut -c6-90))"
    else say "FAIL  defect: the suite did NOT fail against the unpatched file (rc=$rc) - the test cannot see the defect"; bad=1; fi
else say "FAIL  defect build: $(head -3 "$OUT/defect/build.err")"; bad=1; fi

# ---- the knob for the REQUESTED-STOP exemption (docs/ADR-supervision.md 5) ------------------------------------
# The patch has two halves: forward the worker's error (above), and never report it for a stop the SCM ASKED for.
# A check never seen to fail is decoration, and the unpatched file cannot drive this one (it reports 0 for every
# stop, asked or not), so the knob is the PATCHED file with only the exemption taken out: case 7 must then fail.
python3 - "$OUT/service.patched.c" "$OUT/service.noexempt.c" <<'PY'
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
