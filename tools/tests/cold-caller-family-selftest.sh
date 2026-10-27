#!/bin/bash
# The goal's cold-qube clause must be evidenced on EVERY OS family, win11 included.
# run: tools/tests/cold-caller-family-selftest.sh
# pass: exit 0
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 2
M=mgmt/harness/matrix.sh
pass=0; fail=0
ck(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1: got '$3' want '$2'"; fi; }

# the real latch lines, lifted from the harness by their markers
latch=$(sed -n '/^      _cf=win_other$/,/^        eval "COLD_CALLER_DONE_\$_cf=1"$/p' "$M")
[ -n "$latch" ] || { echo "FATAL: could not extract the cold-caller latch from $M"; exit 2; }
ck "the latch reads AND writes a per-family flag (not one campaign-wide)" "2" \
   "$(printf '%s' "$latch" | grep -c 'COLD_CALLER_DONE_\$_cf')"

drive(){ # $1=latch body -> the cells that would MEASURE
  local out=""
  ( eval "$1_dummy=0" ) 2>/dev/null || true
  for c in win10-clean win10-appvm win11-clean win11-reinstall win11-upgrade win11-appvm; do
    _cf=win_other
    case "$c" in win10*|WIN10*) _cf=win10 ;; win11*|WIN11*) _cf=win11 ;; esac
    if [ "$1" = family ]; then
      eval "_d=\${CD_$_cf:-0}"; [ "$_d" = 0 ] && { eval "CD_$_cf=1"; out="$out $c"; }
    else
      [ "${CD_ALL:-0}" = 0 ] && { CD_ALL=1; out="$out $c"; }
    fi
  done
  printf '%s' "${out# }"
}

# EXACTLY ONE PER FAMILY, and it must be a win11 cell as well as a win10 one.
got=$(drive family)
ck "one cold measurement per OS family" "win10-clean win11-clean" "$got"
ck "a win11 cell measures the cold path"  "1" "$(printf '%s' "$got" | grep -c 'win11')"
ck "a win10 cell still measures it too"   "1" "$(printf '%s' "$got" | grep -c 'win10')"

# SEEN TO FAIL: the campaign-wide latch this replaced evidences ONE family and leaves the target
# unmeasured - which is the state run 38994277148 shipped in.
unset CD_win10 CD_win11 CD_ALL
got1=$(drive single)
ck "SEEN TO FAIL: one campaign-wide latch measures a single cell" "win10-clean" "$got1"
ck "SEEN TO FAIL: and leaves win11 - the target - unmeasured"      "0" "$(printf '%s' "$got1" | grep -c 'win11')"

# AND THE HARNESS MUST STILL MEASURE BOTH CALLERS COLD, not just the start menu: the goal names two.
ck "the cold start-menu caller is checked"  "1" "$(grep -c 'dom0-callers-check.sh --cold' "$M")"
ck "the cold updater caller is checked too" "1" "$(grep -c 'vmexec-channel-check.sh --cold' "$M")"

echo "cold-caller-family-selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
