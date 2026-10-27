#!/usr/bin/env bash
# WaitForQdb's timeout must cover the CALL, not just the gaps between calls.
# run: tools/tests/qdbwait-bound-selftest.sh
# pass: exit 0
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/core-agent/src/qrexec-agent/qrexec-agent.c"
STUB="$ROOT/tools/tests/win32stub"
SHIM="$ROOT/tools/tests/win32shim/win32shim.c"
TEST="$ROOT/tools/tests/qdbwait-bound-test.c"
OUT="${QDBWAIT_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/qdbwait-selftest-XXXXXX")}"
mkdir -p "$OUT"
bad=0
say(){ printf '%s\n' "$*"; }

for f in "$SRC" "$SHIM" "$TEST" "$STUB/windows.h"; do
    [ -f "$f" ] || { say "FAIL  missing $f - nothing ran (missing data fails)"; exit 2; }
done
command -v gcc >/dev/null || { say "FAIL  no gcc, so nothing was compiled - this is not a pass"; exit 2; }

# ---- extract the three pieces from the shipped source ------------------------------------------
extract() { # <file> <outfile>
    {
        # A small timeout, because a test that took six minutes to prove a six-minute bound would
        # never be run. The SHAPE under test is which wait carries the budget, not the number.
        echo '#define QDB_WAIT_TIMEOUT_MS 1500'
        awk '/^struct QDB_OPEN_CALL/,/^};$/'                      "$1"
        awk '/^static DWORD WINAPI QdbOpenThread/,/^}$/'           "$1"
        awk '/^static DWORD WaitForQdb\(HANDLE stopEvent\)/,/^}$/' "$1"
    } > "$2"
    # The waiter must be there; the struct and thread proc exist only in the fixed version.
    command grep -q 'static DWORD WaitForQdb' "$2"
}

extract "$SRC" "$OUT/qdbwait-extracted.inc" || { say "FAIL  could not extract WaitForQdb from $SRC"; exit 2; }
lines=$(command grep -cvE '^\s*(//|$)' "$OUT/qdbwait-extracted.inc")
say "ok    extracted the shipped WaitForQdb ($lines code lines) from core-agent"

# ---- syntax, with the repo's win32 stub --------------------------------------------------------
gcc -std=gnu99 -fsyntax-only -Wall -Wextra -D_DEFAULT_SOURCE -I"$STUB" -I"$OUT" "$TEST" \
    >"$OUT/syntax.out" 2>&1
if [ -s "$OUT/syntax.out" ]; then
    say "FAIL  syntax: the shipped code does not parse clean against the stub:"
    head -12 "$OUT/syntax.out" | sed 's/^/        /'
    bad=1
else
    say "PASS  syntax: the shipped WaitForQdb parses with -Wall -Wextra (UNCOMPILED for Windows here)"
fi

# ---- clean: the shipped function, all four cases -----------------------------------------------
if gcc -std=gnu99 -Wall -Wextra -D_DEFAULT_SOURCE -I"$STUB" -I"$OUT" \
       "$TEST" "$SHIM" -o "$OUT/clean" -lpthread 2>"$OUT/clean.build"; then
    if timeout 60 "$OUT/clean" >"$OUT/clean.run" 2>&1; then
        sed 's/^/      /' "$OUT/clean.run"
        say "PASS  clean: the shipped function bounds all four cases"
    else
        rc=$?
        sed 's/^/      /' "$OUT/clean.run"
        if [ "$rc" = 124 ]; then
            say "FAIL  clean: the SHIPPED function HUNG - the bound does not cover the call"
            say "      why it matters: that is the defect this suite exists for, present in what ships"
        else
            say "FAIL  clean: the shipped function came out wrong (rc=$rc)"
        fi
        bad=1
    fi
else
    say "FAIL  clean: build failed"; sed 's/^/        /' "$OUT/clean.build" | head -12; bad=1
fi

# ---- defect: the PRE-FIX function must hang on the never-returns case --------------------------
# Reconstructed rather than kept as a fixture: this is exactly the loop that shipped before, with
# the bound tested only BETWEEN calls.
cat > "$OUT/qdbwait-prefix.inc" <<'PREFIX'
#define QDB_WAIT_TIMEOUT_MS 1500
static DWORD WaitForQdb(HANDLE stopEvent)
{
    qdb_handle_t qdb = NULL;
    ULONGLONG start = GetTickCount64();
    ULONGLONG tick = start;

    LogDebug("start");
    while (qdb == NULL && (tick - start) < QDB_WAIT_TIMEOUT_MS)
    {
        qdb = qdb_open(NULL);
        if (qdb == NULL)
        {
            if (WaitForSingleObject(stopEvent, 1000) == WAIT_OBJECT_0)
            {
                LogDebug("stop requested while waiting for qdb");
                return ERROR_CANCELLED;
            }
        }
        tick = GetTickCount64();
    }
    if (qdb == NULL)
    {
        LogError("timed out after %u ms: connect to qdb server", QDB_WAIT_TIMEOUT_MS);
        return ERROR_TIMEOUT;
    }
    qdb_close(qdb);
    LogDebug("qdb is running after %I64u ms", tick - start);
    return ERROR_SUCCESS;
}
PREFIX
mkdir -p "$OUT/pre" && cp "$OUT/qdbwait-prefix.inc" "$OUT/pre/qdbwait-extracted.inc"
if gcc -std=gnu99 -Wall -Wextra -D_DEFAULT_SOURCE -I"$STUB" -I"$OUT/pre" \
       "$TEST" "$SHIM" -o "$OUT/pre/run" -lpthread 2>"$OUT/pre/build"; then
    timeout 25 "$OUT/pre/run" >"$OUT/pre/run.out" 2>&1
    rc=$?
    if [ "$rc" = 124 ]; then
        say "PASS  defect: the PRE-FIX function hangs on 'qdb_open never returns' (killed at 25 s)"
        say "      so the clean run above is measuring something that can fail"
    else
        say "FAIL  defect: the PRE-FIX function did NOT hang (rc=$rc) - this suite proves nothing"
        say "      why it matters: a harness that passes on the broken version cannot detect the fix"
        tail -6 "$OUT/pre/run.out" | sed 's/^/        /'
        bad=1
    fi
else
    say "FAIL  defect: the pre-fix build failed"; head -8 "$OUT/pre/build" | sed 's/^/        /'; bad=1
fi

[ "$bad" = 0 ] && { say "--- qdbwait-bound: all legs passed"; exit 0; }
say "--- qdbwait-bound: FAILURES"; exit 1
