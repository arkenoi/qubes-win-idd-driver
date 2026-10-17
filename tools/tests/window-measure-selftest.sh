#!/usr/bin/env bash
# window-measure-selftest.sh - A WINDOW THAT VANISHED IS NOT A MONITOR FAULT.
#
# GetRealWindowRect needs monitor info to undo DPI scaling. A stale monitor handle is a
# display-change race, so it re-asks once; two refusals in a row are treated as the real topology
# fault and logged at ERROR with the window not measured, because dom0 then keeps stale geometry.
#
# BUT A DEAD HWND FAILS BOTH ASKS TOO. MonitorFromWindow on a window that has gone hands back a
# handle GetMonitorInfo refuses, so a window closing mid-pass produces exactly that signature - and
# the consequence the error asserts cannot apply to a window dom0 was never told about.
# MEASURED on win10-clean, campaign run 38971675274 (sha 8e0252e8): the ONE error line a clean
# install of that build produced was `0x40066: GetMonitorInfo failed twice (0x5b5, 0x5b5), not
# measured`, and 0x40066 appears EXACTLY ONCE in the whole agent log - only in that line. Never
# attached, never mapped, never destroyed, never mentioned again.
#
# This holds the code to the discriminator: ASK IsWindow. Its FALSE is conclusive, which is the only
# direction needed; a window still present with two refused lookups stays an ERROR per occurrence.
set -uo pipefail
cd "$(cd "$(dirname "$0")/../.." && pwd)" || exit 2
SRC=agent/gui-agent/main.c
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "ok   $*"; }
bad(){ fail=$((fail+1)); echo "FAIL $*"; }
[ -f "$SRC" ] || { echo "FAIL $SRC is missing - nothing ran (missing data fails)"; exit 2; }

# The block from the second GetMonitorSettings refusal to the ERROR line is what this grades.
# ANCHOR ON THE LogError CALL, NOT ON ITS TEXT: the code's own comment quotes the measured line
# ("`0x40066: GetMonitorInfo failed twice (0x5b5, 0x5b5), not measured`"), so a range ending at that
# phrase stopped inside the COMMENT and extracted a block with none of the code in it - this suite
# reported three false failures on a correct tree until the anchor moved.
blk(){ awk '/monitor = MonitorFromWindow\(window, MONITOR_DEFAULTTONEAREST\);/,/LogError\("0x%x: GetMonitorInfo failed twice/' "$1"; }
B=$(blk "$SRC")

command grep -q "IsWindow(window)" <<< "$B" \
  && ok "the twice-refused path ASKS whether the window still exists" \
  || bad "no IsWindow check between the second refusal and the ERROR - a vanished window is graded a monitor fault"
# GetLastError must be taken BEFORE IsWindow, which clobbers it: otherwise the ERROR reports the
# wrong code, which is the 2026-10-07 stale-GetLastError defect in another costume.
if command grep -q "secondError = GetLastError()" <<< "$B"; then
  el=$(command grep -n "secondError = GetLastError()" <<< "$B" | head -1 | cut -d: -f1)
  il=$(command grep -n "IsWindow(window)" <<< "$B" | head -1 | cut -d: -f1)
  [ "$el" -lt "$il" ] && ok "the second error code is captured BEFORE IsWindow clobbers GetLastError (line $el < $il)" \
                      || bad "GetLastError is read AFTER IsWindow (line $el > $il) - the ERROR would report the wrong code"
else
  bad "the second error is not captured into a local - GetLastError after IsWindow is not the monitor's error"
fi
command grep -q "QGAWNDGONE" <<< "$B" \
  && ok "a vanished window is reported on its own tag, bounded and counted (QGAWNDGONE)" \
  || bad "a vanished window has no reported tag - it would be silent, and a RATE of them is a finding"
# The vanished branch must NOT be an error line: that is the whole point.
gone_blk=$(awk '/if \(!IsWindow\(window\)\)/,/QGAWNDGONE/' "$SRC")
command grep -q "LogError" <<< "$gone_blk" \
  && bad "the vanished-window branch still logs at ERROR" \
  || ok "the vanished-window branch logs no ERROR"
# And a window that is STILL THERE keeps the error, per occurrence.
command grep -q 'LogError("0x%x: GetMonitorInfo failed twice' "$SRC" \
  && ok "a window still present after two refused lookups is still an ERROR" \
  || bad "the topology fault no longer reports at ERROR - that is the condition this line exists for"

# SEEN TO FAIL: with the discriminator removed, a vanished window is graded a monitor fault again.
D=$(mktemp -d "${TMPDIR:-/tmp}/wndmeasure-XXXXXX"); trap 'rm -rf "$D"' EXIT
python3 - "$SRC" "$D/regressed.c" <<'PY'
import re, sys
s = open(sys.argv[1], encoding="utf-8", errors="replace").read()
# drop the whole `if (!IsWindow(window)) { ... }` block from the twice-refused path
m = re.search(r"\n( +)const DWORD secondError = GetLastError\(\);\n.*?\n\1\}\n", s, re.S)
if m:
    s = s[:m.start()] + "\n" + m.group(1) + "const DWORD secondError = GetLastError();\n" + s[m.end():]
open(sys.argv[2], "w", encoding="utf-8").write(s)
PY
RB=$(awk '/monitor = MonitorFromWindow\(window, MONITOR_DEFAULTTONEAREST\);/,/LogError\("0x%x: GetMonitorInfo failed twice/' "$D/regressed.c")
command grep -q "IsWindow(window)" <<< "$RB" \
  && bad "the regression copy still carries the check - the case cannot be driven" \
  || ok "SEEN TO FAIL: without the check, two refused lookups grade a vanished window as a monitor fault"
echo "  ---- $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
