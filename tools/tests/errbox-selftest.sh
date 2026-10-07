#!/usr/bin/env bash
# errbox-selftest.sh - offline proof matrix for THE ERROR WINDOW (docs/ADR-supervision.md section 6): when dom0 cannot
# be told of a loud error, the route shows it as a system message box on the console session (agent/gui-agent/errbox.h,
# WTSSendMessage); the agent accepts that box explicitly (main.c ErrBoxIsSystemBox, QGAERRBOX) and a restarted agent
# announces it FIRST (agent/gui-agent/errbox-order.h). The route's own half - when the window is shown, under the same
# dedupe and cap as the dom0 notification - is tools/tests/notifyerr-selftest.sh (knobs NOBOX and BOXSTORM in C, errbox
# and errboxdedupe in PowerShell).
#
# Runs on this dev qube with gcc alone (no rig, no guest):
#   clean build of gui-agent/errbox_order_test.c   MUST pass (the box first, bottom-first among boxes, the rest bottom-first)
#   ERRBOX_DEFECT_NOFIRST                           MUST fail (plain bottom-first: the box is announced wherever it sits)
#   UNCOMPILED SHAPE CHECKS of main.c and notifhost.cpp, each also run against a copy with the guarded line removed and
#   required to FAIL then: the predicate is explicit (class, title prefix, owning image) and logs QGAERRBOX; it is
#   consulted in ShouldAcceptWindow before any dropping rule; AddAllWindows announces through ErrBoxAnnounceOrder; the
#   title prefix is ONE constant; notifhost's own report shows the box when gated or when its transport fails.
#   AGENT_DIR=<path>   the agent checkout (default: the agent submodule)   ERRBOX_OUT=<dir>   outputs (default: mktemp)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AGENT="${AGENT_DIR:-$ROOT/agent}"
OUT="${ERRBOX_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/errbox-selftest-XXXXXX")}"
mkdir -p "$OUT"
bad=0
say() { printf '%s\n' "$*"; }
MAIN="$AGENT/gui-agent/main.c"; NH="$ROOT/tools/notifhost/notifhost.cpp"; EB="$AGENT/gui-agent/errbox.h"
for need in "$AGENT/gui-agent/errbox-order.h" "$AGENT/gui-agent/errbox_order_test.c" "$MAIN" "$NH" "$EB"; do
    if [ ! -f "$need" ]; then say "FAIL  missing $need - nothing ran (missing data fails)"; exit 2; fi
done

build() { gcc -std=c99 -Wall -Wextra -Werror -I"$AGENT/gui-agent" ${2:-} "$AGENT/gui-agent/errbox_order_test.c" -o "$OUT/$1" 2>"$OUT/$1.build.err"; }
if build clean ""; then
    "$OUT/clean" >"$OUT/clean.out" 2>&1; rc=$?
    n=$(grep -c '^ok' "$OUT/clean.out"); f=$(grep -c '^FAIL' "$OUT/clean.out")
    if [ "$rc" -eq 0 ] && [ "$f" -eq 0 ] && [ "$n" -ge 6 ]; then say "PASS  order clean: rc=0 ok=$n fail=0"
    else say "FAIL  order clean: rc=$rc ok=$n fail=$f"; grep '^FAIL' "$OUT/clean.out" | head -3; bad=1; fi
else say "FAIL  order clean build: $(head -3 "$OUT/clean.build.err")"; bad=1; fi
if build defect-NOFIRST "-DERRBOX_DEFECT_NOFIRST"; then
    "$OUT/defect-NOFIRST" >"$OUT/defect-NOFIRST.out" 2>&1; rc=$?
    f=$(grep -c '^FAIL' "$OUT/defect-NOFIRST.out")
    if [ "$rc" -ne 0 ] && [ "$f" -gt 0 ]; then say "PASS  defect NOFIRST: suite FAILED as required (rc=$rc, $f failing: $(grep '^FAIL' "$OUT/defect-NOFIRST.out" | head -1 | cut -c6-100))"
    else say "FAIL  defect NOFIRST: suite did NOT fail (rc=$rc) - the ordering guard is decoration"; bad=1; fi
else say "FAIL  defect NOFIRST build: $(head -3 "$OUT/defect-NOFIRST.build.err")"; bad=1; fi

shape() { # $1 label, $2 check fn, $3 file, $4 marker of the guarded line
    local mut="$OUT/mut-$2.txt"
    if "$2" "$3"; then
        grep -v -F -- "$4" "$3" > "$mut"
        if "$2" "$mut"; then say "FAIL  shape: $1 - the check still passes with the guarded line removed (it cannot fail)"; bad=1
        else say "PASS  shape: $1 (and FAILS with the guarded line removed)"; fi
    else say "FAIL  shape: $1"; bad=1; fi
}
# the predicate: dialog class, our title prefix, the system's own box-drawing process; one QGAERRBOX line per hwnd either way
pred() { grep -q 'wcscmp(data->Class, L"#32770") != 0' "$1" && grep -q 'wcsncmp(data->Caption, ERRBOX_TITLE_PREFIX' "$1" && grep -q 'wcscmp(image, L"csrss.exe") == 0 || wcscmp(image, L"winlogon.exe") == 0' "$1" && grep -q 'LogInfo("QGAERRBOX error window' "$1"; }
shape "main.c: ErrBoxIsSystemBox is explicit (class #32770, the title prefix, csrss.exe/winlogon.exe as the owner) and logs QGAERRBOX" pred "$MAIN" 'LogInfo("QGAERRBOX error window'
# accepted in ShouldAcceptWindow before any dropping rule (right after the visibility/pending checks)
accept() { awk '/^BOOL ShouldAcceptWindow\(IN const WINDOW_DATA \*data\)/{s=NR} s&&/if \(ErrBoxIsSystemBox\(data\)\)/{a=NR} s&&/data->Handle == GetShellWindow\(\)/{b=NR} END{exit !(s && a && b && a<b)}' "$1"; }
shape "main.c: ShouldAcceptWindow accepts the box before the shell-window rule and every rule that drops" accept "$MAIN" 'if (ErrBoxIsSystemBox(data))'
# the start enumeration announces through the pure order
order() { grep -q 'orderCount = ErrBoxAnnounceOrder(isBox, context.PendingCount, order);' "$1" && grep -q 'HWND w = context.Pending\[order\[k\]\];' "$1"; }
shape "main.c: AddAllWindows announces in ErrBoxAnnounceOrder (the error window first)" order "$MAIN" 'orderCount = ErrBoxAnnounceOrder(isBox, context.PendingCount, order);'
# ONE title prefix
prefix() { grep -q '#define ERRBOX_TITLE_PREFIX QERR_BOX_TITLE_PREFIX' "$1"; }
shape "main.c: the title prefix the agent recognizes IS the one the route puts in the title (QERR_BOX_TITLE_PREFIX)" prefix "$MAIN" '#define ERRBOX_TITLE_PREFIX QERR_BOX_TITLE_PREFIX'
# errbox.h: the box is non-blocking, no timeout, an error icon, on the console session
box() { grep -q 'WTSSendMessageW(WTS_CURRENT_SERVER_HANDLE, session, title' "$1" && grep -q 'MB_OK | MB_ICONERROR, 0, &response, FALSE)' "$1" && grep -q 'WTSGetActiveConsoleSessionId()' "$1"; }
shape "errbox.h: WTSSendMessage on the console session, MB_OK|MB_ICONERROR, no timeout, bWait FALSE" box "$EB" 'MB_OK | MB_ICONERROR, 0, &response, FALSE)'
# notifhost's own report (ReportErrorSelf bypasses the agent's glue): the box when gated or when its transport fails
nh() { grep -q '#include "../../agent/gui-agent/errbox.h"' "$1" && grep -q 'ShowErrorBoxSelf(QERR_GATED, id, header, text, L"gated")' "$1" && [ "$(grep -c 'ShowErrorBoxSelf(QERR_FAIL_TRANSPORT, id, header, text' "$1")" -ge 3 ] && grep -q 'if (!QerrWindowWanted(d)) return;' "$1" && grep -q 'QerrShowErrorBox(header, text, &err)' "$1"; }
shape "notifhost.cpp: ReportErrorSelf shows the box when gated and on every transport failure (the same pure rule, QerrWindowWanted)" nh "$NH" 'ShowErrorBoxSelf(QERR_GATED, id, header, text, L"gated");'

say "--- outputs in $OUT"
exit $bad
