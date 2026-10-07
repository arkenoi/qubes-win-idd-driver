#!/usr/bin/env bash
# wu-prevpass-gate-selftest.sh - offline proof matrix for qubes-windows-update.ps1's start gate on a cut-off earlier pass (the owner's
# D3 decision, 2026-10-02): the clean leg must PASS, and each knob must FAIL on its own target and only within its own scenarios.
#   oldgate     the pre-decision gate (every cut-off pass refuses forever)  -> scan-cut and prev-boot fail
#   nothisboot  a pass cut off in this boot does not refuse                 -> this-boot / again / unreadable-ts fail
#   noreboot    the restart request is not recorded                         -> this-boot's record check fails
#   noscanreadonly  a scheduled SCAN refuses under a cut-off install pass   -> scan-under-cutoff fails
#               (that refusal is what made a fresh qube greet its user with "The Windows Update scan
#                task failed" - exit 1 from a read-only operation, measured 2026-10-07)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PWSH="${PWSH:-/home/user/bin/pwsh7/pwsh}"
SUITE="$ROOT/tools/tests/wu-prevpass-gate-test.ps1"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/wuprevpass-selftest-XXXXXX")"
[ -x "$PWSH" ] || { echo "FAIL  pwsh not found at $PWSH - nothing ran"; exit 2; }
bad=0
"$PWSH" -NoProfile -File "$SUITE" > "$OUT/clean.out" 2>&1; rc=$?
n=$(grep -c '^ok' "$OUT/clean.out"); f=$(grep -c '^FAIL' "$OUT/clean.out")
if [ $rc -eq 0 ] && [ "$f" -eq 0 ] && [ "$n" -ge 12 ]; then echo "PASS  clean: rc=0 ok=$n"; else echo "FAIL  clean: rc=$rc ok=$n fail=$f ($(grep -m1 '^FAIL' "$OUT/clean.out" | cut -c1-140))"; bad=1; fi
leg(){ # $1 knob $2 target check (prefix) $3 allowed-failures regex
  "$PWSH" -NoProfile -File "$SUITE" -Defect "$1" > "$OUT/$1.out" 2>&1; local r=$? st
  st=$(grep '^FAIL' "$OUT/$1.out" | grep -vE "$3" | head -2 | cut -c6-120)
  if [ $r -ne 0 ] && grep -q "^FAIL $2" "$OUT/$1.out" && [ -z "$st" ]; then echo "PASS  $1: failed on its target only ($(grep -c '^FAIL' "$OUT/$1.out") checks)"
  else echo "FAIL  $1: rc=$r target=$(grep -c "^FAIL $2" "$OUT/$1.out") stray=[$st]"; bad=1; fi
}
leg oldgate    'scan-cut: a scan cut off'                 '^FAIL (scan-cut|prev-boot)'
leg nothisboot 'this-boot: a full pass cut off in THIS'   '^FAIL (this-boot|again|unreadable-ts|contract)'
leg noreboot   "this-boot: the cut-off pass's record"     "^FAIL (this-boot: the cut-off pass's record|unreadable-ts: the refusal records|scan-under-cutoff: the restart)"   # ONE write carries all three: the refusal's record, the unreadable-ts record, and the restart a proceeding SCAN still has to request
leg noscanreadonly 'scan-under-cutoff: a SCAN under an install pass' '^FAIL scan-under-cutoff'
leg norefusedboot 'unreadable-after-restart: refused in an earlier boot' '^FAIL unreadable-after-restart'
echo "--- outputs in $OUT"
exit $bad
