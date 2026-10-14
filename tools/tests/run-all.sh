#!/bin/bash
# run-all.sh - run the offline self-tests without taking this qube's GUI down.
#
#   tools/tests/run-all.sh [-o OUTDIR] [-t SECS] [PATTERN]
#
# WHY THIS EXISTS. `/tmp` on this qube is a 1 GB tmpfs, so a temp dir is RAM, not disk. The tests
# `mktemp -d` and most do not clean up. Running all 108 in a bare loop on 2026-10-14 left 96 dirs
# and 505 MB pinned, took /tmp to 75%, dropped free memory to ~380 MB, and the owner's xfce-terminal
# in THIS qube went non-responsive. That was the third GUI outage here from the same cause.
#
# So: TMPDIR on real disk, a bounded scope, and a sweep after EVERY test rather than at the end.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 2

OUT="scratchpad/selftest-run"; PER=90; PAT='*'
while [ $# -gt 0 ]; do case "$1" in
  -o) OUT="${2:?-o needs a dir}"; shift 2 ;;
  -t) PER="${2:?-t needs seconds}"; shift 2 ;;
  -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
  *) PAT="$1"; shift ;;
esac; done

# TMPDIR on REAL DISK. Without this every test allocates into the RAM-backed /tmp.
export TMPDIR="${QWT_TEST_TMPDIR:-$HOME/.cache/qwt-selftest-tmp}"
mkdir -p "$TMPDIR" "$OUT" || exit 2
case "$(df -P "$TMPDIR" | awk 'NR==2{print $1}')" in
  tmpfs) echo "run-all: REFUSING - TMPDIR $TMPDIR is on tmpfs; point QWT_TEST_TMPDIR at real disk" >&2; exit 2 ;;
esac

free_mb(){ free -m | awk 'NR==2{print $7}'; }
tmp_pct(){ df -P /tmp | awk 'NR==2{gsub("%","",$5); print $5}'; }

# A run that starts with /tmp already tight finishes by OOM-killing the session, not the test.
if [ "$(tmp_pct)" -ge 70 ]; then
  echo "run-all: REFUSING - /tmp is $(tmp_pct)% full before the first test. Clear it first:" >&2
  du -sm /tmp/* 2>/dev/null | sort -rn | head -5 >&2
  exit 2
fi

# Bound the blast radius. systemd-run gives a task and memory ceiling; without it the loop still
# runs, but it says so, because an unbounded run here is what broke the GUI three times.
SCOPE=()
if command -v systemd-run >/dev/null 2>&1 && systemd-run --user --scope --collect -q true 2>/dev/null; then
  SCOPE=(systemd-run --user --scope --collect -q -p TasksMax="${QWT_TEST_TASKS:-200}" -p MemoryMax="${QWT_TEST_MEM:-900M}")
else
  echo "run-all: no user scope available - running UNBOUNDED, watch free memory"
fi

# Leaked temp dirs are leaked MEMORY. Swept after every test so the peak never accumulates; only
# names the tests create are touched, and only under TMPDIR or the two known /tmp prefixes.
sweep(){ local n=0 d
  for d in "$TMPDIR"/tmp.* "$TMPDIR"/*selftest* /tmp/*selftest* /tmp/qwt-test.*; do
    case "$d" in *'*'*) continue ;; esac
    [ -e "$d" ] || continue
    rm -rf -- "$d" && n=$((n+1))
  done
  return 0
}

mapfile -t TESTS < <(ls tools/tests/${PAT}.sh 2>/dev/null | grep -v '/run-all\.sh$')
[ "${#TESTS[@]}" -gt 0 ] || { echo "run-all: no test matches '$PAT'" >&2; exit 2; }
echo "run-all: ${#TESTS[@]} test(s), TMPDIR=$TMPDIR, /tmp $(tmp_pct)%, ${$(free_mb):-?} MB available"
: > "$OUT/_rcs.txt"
pass=0; fail=0
for t in "${TESTS[@]}"; do
  b=$(basename "$t" .sh)
  "${SCOPE[@]}" timeout "$PER" bash "$t" > "$OUT/$b.log" 2>&1; rc=$?
  echo "$rc $b" >> "$OUT/_rcs.txt"
  [ "$rc" -eq 0 ] && pass=$((pass+1)) || fail=$((fail+1))
  sweep
  # A run that eats the qube's memory is stopped here, not after the GUI has gone.
  if [ "$(free_mb)" -lt 400 ] || [ "$(tmp_pct)" -ge 80 ]; then
    echo "run-all: STOPPING at $b - available ${$(free_mb):-?} MB, /tmp $(tmp_pct)%. $pass passed, $fail failed so far."
    exit 3
  fi
done
echo "run-all: $pass passed, $fail failed; logs in $OUT, /tmp $(tmp_pct)%, $(free_mb) MB available"
[ "$fail" -eq 0 ]
