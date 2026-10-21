#!/bin/bash
# matrix-coldcaller-grade-selftest.sh - a campaign that never measured the cold caller path must not pass.
#
# WHAT WAS WRONG. "qrexec behavior is aligned with dom0 callers: updaters and start menu, FROM COLD
# QUBE AS WELL" is a clause of the release goal, and matrix.sh measures the cold half once per OS
# FAMILY. The first version printed "[WARN] ... the cold caller path went unmeasured for this cell"
# and carried on; the latch was SET and never READ, so zero measurements of a release-goal clause
# passed in silence - and matrix.sh's own notes record it happening twice.
#
# THEN THE GRADE ITSELF MOVED and this suite did not. The latch became per family
# (COLD_CALLER_DONE_win10 / _win11) and the post-loop grade stopped reading a variable at all: it
# asks the per-cell `*-coldcallers.out` files, per family, whether a COLD alignment was recorded.
# This suite still extracted `if [ "${COLD_CALLER_DONE:-0}" = 0 ]; then`, found nothing, and exited
# 2 - a suite reporting an environment failure where the code had improved. It now drives the
# shipped grade over FIXTURE EVIDENCE DIRECTORIES, which is the input the grade actually reads.
#
# HOW IT IS DRIVEN. The block is EXTRACTED FROM THE REAL matrix.sh by its marker and executed with
# no()/ok() stubbed and $M pointed at a fixture dir, so this tests the shipped code rather than a
# copy of it. Delete the block, stop grading the absence, or go back to one latch for both
# families, and these checks fail.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 2
T="$(mktemp -d "${TMPDIR:-/tmp}/matrix-coldcaller-XXXXXX")"
trap 'rc=$?; if [ "$rc" -eq 0 ]; then rm -rf "$T"; else printf "kept %s (rc=%s)\n" "$T" "$rc" >&2; fi' EXIT
pass=0; fail=0
ok_(){  printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no_(){ printf '  FAIL  %s\n     -> %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

M_SRC="mgmt/harness/matrix.sh"

# ---- extract the shipped post-loop grade ------------------------------------------------------
python3 - "$M_SRC" "$T/block.sh" <<'PY'
import sys
src, out = sys.argv[1], sys.argv[2]
L = open(src, encoding="utf-8").read().splitlines()
starts = [i for i, l in enumerate(L) if l.strip() == "_cold_missing="]
if not starts:
    sys.exit("no cold-caller grade block in %s (marker '_cold_missing=')" % src)
i = starts[-1]
# the block ends at the `fi` that closes the verdict if/else - the first `fi` at column zero
# after the loop's own indented `fi`s.
j = next(k for k in range(i + 1, len(L)) if L[k] == "fi")
open(out, "w", encoding="utf-8").write("\n".join(L[i:j+1]) + "\n")
print("extracted %d line(s) from %s:%d" % (j - i + 1, src, i + 1))
PY
[ -s "$T/block.sh" ] || { echo "FATAL: nothing extracted"; exit 2; }
command grep -qa 'coldcallers.out' "$T/block.sh" || { echo "FATAL: the extracted block does not read the per-cell evidence"; exit 2; }

ALIGNED='[OK] the start-menu caller is aligned on win11-acc (cold start, dom0 parsed the answer)'

drive(){ # $1=cells  $2..=evidence files to create, each "<name>:<aligned|silent>"
  local cells="$1"; shift
  rm -rf "$T/m"; mkdir -p "$T/m"
  local spec
  for spec in "$@"; do
    case "${spec#*:}" in
      aligned) printf '%s\n' "$ALIGNED" > "$T/m/${spec%%:*}-coldcallers.out" ;;
      *)       printf 'halting the subject to measure the COLD caller path\n' > "$T/m/${spec%%:*}-coldcallers.out" ;;
    esac
  done
  (
    no(){ printf 'NO %s\n' "$*"; }
    ok(){ printf 'OK %s\n' "$*"; }
    M="$T/m"; CELLS="$cells"
    # shellcheck disable=SC1090
    . "$T/block.sh"
  ) > "$T/out" 2>&1
}

# ---- 1. no evidence at all -> graded, not warned ----------------------------------------------
drive "win10-clean win11-clean"
if command grep -qa '^NO INVALID-COLDCALLER' "$T/out"; then ok_ "no evidence is GRADED as INVALID-COLDCALLER, not warned"
else no_ "no evidence is GRADED" "$(cat "$T/out")"; fi
if command grep -qa 'release-goal clause' "$T/out"; then ok_ "and it says WHY: a release-goal clause went unmeasured"
else no_ "it says why" "$(cat "$T/out")"; fi
if command grep -qa 'win10' "$T/out" && command grep -qa 'win11' "$T/out"; then ok_ "and it NAMES both unmeasured families"
else no_ "it names the families" "$(cat "$T/out")"; fi

# ---- 2. a file that exists but records no COLD alignment is still unmeasured -------------------
drive "win11-clean" "win11-clean:silent"
if command grep -qa '^NO INVALID-COLDCALLER' "$T/out"; then ok_ "an evidence file with no cold alignment does not count as measured"
else no_ "file-exists is not measured" "$(cat "$T/out")"; fi

# ---- 3. measured -> passes, or check 1 would pass by failing everything ------------------------
drive "win11-clean" "win11-clean:aligned"
if command grep -qa '^OK ' "$T/out" && ! command grep -qa '^NO ' "$T/out"; then ok_ "a recorded cold alignment is a PASS and grades nothing"
else no_ "a recorded cold alignment is a PASS" "$(cat "$T/out")"; fi

# ---- 4. THE PER-FAMILY PROPERTY, which is the 2026-10-18 fix ----------------------------------
# One latch for both families let whichever cell ran first consume it - win10 runs first, so the
# clause was evidenced on win10 and on no win11 cell at all, and win11 is the stated target.
drive "win10-clean win11-clean" "win10-clean:aligned"
if command grep -qa '^NO INVALID-COLDCALLER' "$T/out" && command grep -qa 'win11' "$T/out"; then
  ok_ "win10 measured does NOT satisfy win11 - the grade is per OS family"
else no_ "measuring one family does not satisfy the other" "$(cat "$T/out")"; fi
if ! printf '%s' "$(command grep -a '^NO ' "$T/out")" | command grep -qa 'win10'; then
  ok_ "and the family that WAS measured is not named as missing"
else no_ "the measured family is not named as missing" "$(cat "$T/out")"; fi

# ---- 5. it is the INVALID class, never product FAIL -------------------------------------------
drive "win10-clean win11-clean"
if command grep -qa '^NO INVALID-' "$T/out"; then ok_ "classed INVALID-*, so it blocks without claiming a product defect"
else no_ "classed INVALID-*" "$(cat "$T/out")"; fi

# ---- 6. SEEN TO FAIL: the per-family latch is really two latches -------------------------------
# Reproduced against the real file: the in-loop guard must read a SUFFIXED name. A single
# unsuffixed COLD_CALLER_DONE is the shape that let one family answer for both.
if command grep -qa 'COLD_CALLER_DONE_\$_cf' "$M_SRC"; then ok_ "SEEN TO FAIL: the in-loop latch is per family (COLD_CALLER_DONE_\$_cf)"
else no_ "the in-loop latch is per family" "an unsuffixed latch lets the first family answer for both"; fi
if ! command grep -qaE '\$\{COLD_CALLER_DONE:-' "$M_SRC"; then ok_ "and no unsuffixed read survives, which nothing in the file assigns"
else no_ "no unsuffixed read survives" "\${COLD_CALLER_DONE:-...} is pinned to 0 for ever - nothing assigns it"; fi

# the per-cell WARN stays, because the note is information; what changed is that the campaign no
# longer ENDS on it quietly.
if command grep -qa 'cold caller path went unmeasured for this cell' "$M_SRC"; then ok_ "the per-cell WARN is kept - it is information, not a verdict"
else no_ "the per-cell WARN is kept" "the explanatory line was removed"; fi

printf 'matrix-coldcaller-grade-selftest: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
