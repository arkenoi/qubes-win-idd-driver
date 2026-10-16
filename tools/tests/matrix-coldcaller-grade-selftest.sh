#!/bin/bash
# matrix-coldcaller-grade-selftest.sh - a campaign that never measured the cold caller path must not pass.
#
# WHAT WAS WRONG. "qrexec behavior is aligned with dom0 callers: updaters and start menu, FROM COLD
# QUBE AS WELL" is a clause of the release goal, and matrix.sh measures the cold half ONCE per
# campaign, guarded on that cell's subject still answering. When the guard failed it printed
# "[WARN] ... the cold caller path went unmeasured for this cell" and the campaign carried on.
# COLD_CALLER_DONE was SET and never READ, so zero measurements of a release-goal clause passed in
# silence - and matrix.sh's own notes record it happening twice: "Run 8's matrix log contains ZERO
# lines matching VMEXEC; run 9 measured three win11 cells and reported 'guest not answering' for
# every win10 one."
#
# HOW IT IS DRIVEN. The block is EXTRACTED FROM THE REAL matrix.sh by its marker and executed with
# no()/ok() stubbed, so this tests the shipped code rather than a copy of it. Delete the block,
# reword its marker, or stop grading the absence, and these checks fail.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 2
T="$(mktemp -d "${TMPDIR:-/tmp}/matrix-coldcaller-XXXXXX")"
trap 'rc=$?; if [ "$rc" -eq 0 ]; then rm -rf "$T"; else printf "kept %s (rc=%s)\n" "$T" "$rc" >&2; fi' EXIT
pass=0; fail=0
ok_(){  printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no_(){ printf '  FAIL  %s\n     -> %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

M="mgmt/harness/matrix.sh"
MARK='if \[ "\${COLD_CALLER_DONE:-0}" = 0 \]; then'

# ---- extract the shipped block ----------------------------------------------------------------
python3 - "$M" "$T/block.sh" <<'PY'
import re, sys
src, out = sys.argv[1], sys.argv[2]
L = open(src, encoding="utf-8").read().splitlines()
starts = [i for i, l in enumerate(L) if l.strip().startswith('if [ "${COLD_CALLER_DONE:-0}" = 0 ]; then')]
# the LAST one is the post-loop grade; the first is the once-per-campaign guard inside the loop
if not starts:
    sys.exit("no COLD_CALLER_DONE block in %s" % src)
i = starts[-1]
j = next(k for k in range(i, len(L)) if L[k].strip() == "fi")
open(out, "w", encoding="utf-8").write("\n".join(L[i:j+1]) + "\n")
print("extracted %d line(s) from %s:%d" % (j - i + 1, src, i + 1))
PY
[ -s "$T/block.sh" ] || { echo "FATAL: nothing extracted"; exit 2; }

drive(){ # $1 = value for COLD_CALLER_DONE ("" = unset) -> writes $T/out
  (
    no(){ printf 'NO %s\n' "$*"; }
    ok(){ printf 'OK %s\n' "$*"; }
    if [ -n "$1" ]; then COLD_CALLER_DONE="$1"; fi
    # shellcheck disable=SC1090
    . "$T/block.sh"
  ) > "$T/out" 2>&1
}

# ---- 1. never measured -> graded, not a WARN --------------------------------------------------
drive ""
if grep -qa '^NO INVALID-COLDCALLER' "$T/out"; then ok_ "unmeasured (unset) is GRADED as INVALID-COLDCALLER, not warned"
else no_ "unmeasured (unset) is GRADED" "$(cat "$T/out")"; fi
if grep -qa "release-goal clause" "$T/out"; then ok_ "and it says WHY: a release-goal clause went unmeasured"
else no_ "it says why" "$(cat "$T/out")"; fi

drive "0"
if grep -qa '^NO INVALID-COLDCALLER' "$T/out"; then ok_ "explicitly 0 is graded too"
else no_ "explicitly 0 is graded too" "$(cat "$T/out")"; fi

# ---- 2. measured -> passes, or the check above would pass by failing everything ----------------
drive "1"
if grep -qa '^OK ' "$T/out" && ! grep -qa '^NO ' "$T/out"; then ok_ "measured once is a PASS and grades nothing"
else no_ "measured once is a PASS" "$(cat "$T/out")"; fi

# ---- 3. it is the INVALID class, never product FAIL -------------------------------------------
# An unmeasured path is missing instrument data, not a demonstrated product defect, and verdict-lib's
# invariant is that INVALID-* is never folded into FAIL.
drive ""
if grep -qa '^NO INVALID-' "$T/out"; then ok_ "classed INVALID-*, so it blocks without claiming a product defect"
else no_ "classed INVALID-*" "$(cat "$T/out")"; fi

# ---- 4. SEEN TO FAIL: the shipped shape, which read the variable nowhere -----------------------
# Before this, COLD_CALLER_DONE was assigned and never tested after the loop. Reproduced by asking
# the real file how many times it is READ outside an assignment.
reads=$(grep -c '\${COLD_CALLER_DONE' "$M" || true)
if [ "${reads:-0}" -ge 2 ]; then ok_ "SEEN TO FAIL: the variable is now READ ($reads sites), not only assigned"
else no_ "SEEN TO FAIL: the variable is read after the loop" "only $reads read site(s) - the absence would pass again"; fi

# and the WARN that used to be the whole response is still there, because the per-cell note is
# information; what changed is that the campaign no longer ENDS on it quietly.
if grep -qa 'cold caller path went unmeasured for this cell' "$M"; then ok_ "the per-cell WARN is kept - it is information, not a verdict"
else no_ "the per-cell WARN is kept" "the explanatory line was removed"; fi

printf 'matrix-coldcaller-grade-selftest: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
