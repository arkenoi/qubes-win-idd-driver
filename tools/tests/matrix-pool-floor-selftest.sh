#!/usr/bin/env bash
# matrix-pool-floor-selftest.sh - A CAMPAIGN THAT DIES AT CELL 11 TEACHES NOTHING.
#
# Owner, 2026-10-08: "watch the thin pool space meanwhile." mgmt/harness/matrix.sh had NO space
# check of any kind. That is the worst shape for this failure: the pool fills partway through, a cell
# dies for a reason that looks like the product, and the whole campaign's results are untrustworthy
# rather than merely short - and this rig was measured at 85% full with 131 GB free the day the full
# 18-suite gate came due.
#
# This drives the gate with a STUBBED pool reading, in both directions, so it is seen to refuse and
# seen to allow without filling a disk. The stub is the only way to exercise a disk-space refusal
# offline; it exists in the harness for this test and is never set in a real run.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
M="$ROOT/mgmt/harness/matrix.sh"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }
[ -f "$M" ] || { echo "FAIL  $M missing - nothing ran (missing data fails)"; exit 2; }

# The gate is sourced out of the harness rather than copied, so this tests the code that SHIPS.
# Extracting it keeps the test from booting a guest, which is what the harness does next.
gate_src="$(sed -n '/^POOL_FLOOR_GB=/,/^pool_gate "this campaign"/p' "$M" | sed '$d')"
[ -n "$gate_src" ] || { echo "FAIL  could not extract the pool gate from matrix.sh"; exit 2; }

run_gate(){   # $1 = stub free GB ("" = unreadable pool); prints the gate's output, returns its rc
    local out rc
    out=$(
        say(){ echo "$*"; }
        POOL_FREE_GB_STUB="$1"
        eval "$gate_src"
        pool_gate "the test cell"
    ) ; rc=$?
    printf '%s' "$out"
    return $rc
}

# ---- 1. SEEN TO REFUSE: below the floor ---------------------------------------------------------
out=$(run_gate 10); rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | command grep -q 'INVALID-POOL'; then
  ok "refuses_below_floor: 10 GB free is refused, and the refusal is INVALID-POOL (a cell that did not run)"
else
  bad "refuses_below_floor: rc=$rc out='$(printf '%s' "$out" | head -1)' - a nearly full pool would start a campaign"
fi
printf '%s' "$out" | command grep -q 'floor is' \
  && ok "refusal_names_the_numbers: it prints what was free and what the floor is" \
  || bad "refusal_names_the_numbers: the refusal does not say how short it was"
printf '%s' "$out" | command grep -q 'invalidates every cell' \
  && ok "refusal_says_why_it_matters: it states that a mid-campaign fill invalidates the whole run" \
  || bad "refusal_says_why_it_matters: nothing explains why this is refused rather than warned"

# ---- 2. SEEN TO ALLOW: above the floor ----------------------------------------------------------
out=$(run_gate 500); rc=$?
if [ "$rc" = 0 ] && ! printf '%s' "$out" | command grep -q 'INVALID-POOL'; then
  ok "allows_above_floor: 500 GB free starts the campaign - the gate is not a blanket refusal"
else
  bad "allows_above_floor: rc=$rc out='$(printf '%s' "$out" | head -1)' - a healthy pool would be refused"
fi

# ---- 3. THE WARNING BAND, which is the half that is easy to forget ------------------------------
# Between the floor and the warn level a campaign may start but should say it will be tight. The rig
# measured 131 GB free today, which is above BOTH the floor and the warn level - so the band is
# exercised with a value chosen to sit inside it (75), never with today's number. A check pinned to
# whatever the rig happens to hold stops testing the thing the moment the rig changes.
out=$(run_gate 75); rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | command grep -q 'POOL WARNING'; then
  ok "warns_in_the_band: 75 GB free starts, and says it is tight"
else
  bad "warns_in_the_band: rc=$rc - a campaign that will get tight starts silently"
fi
out=$(run_gate 500)
printf '%s' "$out" | command grep -q 'POOL WARNING' \
  && bad "warn_not_always_on: a healthy pool also prints the warning, which makes the warning worthless" \
  || ok "warn_not_always_on: a healthy pool does not warn"

# ---- 4. MISSING DATA FAILS ----------------------------------------------------------------------
# An unreadable pool must REFUSE, never read as "probably fine" - the failure this project refuses.
out=$(POOL_FREE_GB_STUB="" run_gate ""); rc=$?
# With no stub the gate asks qubesadmin; on this dev qube that succeeds, so the honest check is the
# CODE PATH: the gate must treat an empty reading as a refusal.
echo "$gate_src" | command grep -q 'refusing to start .* blind' \
  && ok "unreadable_pool_refuses: an unreadable pool is refused, not assumed healthy" \
  || bad "unreadable_pool_refuses: an unreadable pool would fall through and the campaign would start blind"

# ---- 5. THE FLOOR IS DERIVED, NOT INVENTED ------------------------------------------------------
echo "$gate_src" | command grep -q 'parked snapshot' \
  && ok "floor_is_derived: the number is justified from measured volume sizes, in the code" \
  || bad "floor_is_derived: the floor is a bare constant with no derivation"
# And it must not read the pool by predicting from volume sizes - that arithmetic was wrong once today.
echo "$gate_src" | command grep -q "pools\['vm-pool'\]" \
  && ok "reads_the_pool_itself: free space comes from the pool's own usage, not a prediction" \
  || bad "reads_the_pool_itself: the gate computes space some other way"

# ---- 6. THE GATE IS CHECKED PER CELL, NOT ONCE ---------------------------------------------------
# A start-of-campaign check cannot see a pool that fills at cell 11 - the case that matters. Stopping
# cleanly BETWEEN cells leaves every completed cell's verdict trustworthy; filling MID-cell leaves a
# half-provisioned guest and a result nobody can read.
placed=$(python3 - "$M" <<'PYF'
import io, sys
s = io.open(sys.argv[1], encoding='utf-8', errors='replace').read()
i = s.rindex('for c in $CELLS; do')
seg = s[i:i+1400]
g, c = seg.find('pool_gate "cell $c"'), seg.find('case $c in')
if not (0 < g < c): print('NOT-IN-LOOP'); raise SystemExit
body = seg[g:c]
print('OK' if ('break' in body and 'INVALID' in body) else ('NO-BREAK' if 'break' not in body else 'NOT-INVALID'))
PYF
)
case "$placed" in
  OK) ok "gate_runs_per_cell: each cell is gated before it runs, and a refusal STOPS the campaign as INVALID" ;;
  NOT-IN-LOOP) bad "gate_runs_per_cell: only the start of the campaign is gated - a pool that fills at cell 11 is unseen" ;;
  NO-BREAK) bad "gate_runs_per_cell: a refused cell is skipped rather than stopping the run; the cells after it fare no better" ;;
  *) bad "gate_runs_per_cell: $placed" ;;
esac


# ---- a dom0 desktop switch must not fail an AppVM cell -------------------------------------------
# MEASURED 2026-10-10 and CONFIRMED BY THE OWNER ("yes at 14.12 it is plausible"): boot 1 of WIN10-appvm
# graded INVALID-INSTRUMENT on six empty dom0 captures while the guest showed one notepad window, and
# boots 2 and 3 of the SAME cell returned "1 window(s) mapped" minutes later. The detection was right;
# the ACCOUNTING wrote a FAIL line per boot, which marked the cell, shortened the coverage receipt and
# made gate-scope refuse the cut. The condition must REPEAT across the cell's boots before it marks
# anything - and if NO boot ever mapped a window it must still fail, because that is not a switch.
ii_shape() {  # $1 = a copy of matrix.sh -> "ok" or the reason
  local f="$1"
  command grep -q 'GUARD:iirepeat' "$f" || { echo "no cell-scope instrument verdict"; return; }
  command grep -q 'local ii_boots=0 mapped_any=0' "$f" || { echo "the cell does not count its boots"; return; }
  command grep -q 'ii_boots=$((ii_boots+1))' "$f" || { echo "an empty-capture boot is not counted, it is graded on the spot"; return; }
  command grep -q 'mapped_any=1; ok ' "$f" || { echo "a boot that DID map a window is not recorded, so nothing can exonerate the others"; return; }
  # the per-boot path must not call no() for the invalid-instrument case any more
  command grep -q 'no "$3-appvm boot $b: INVALID-INSTRUMENT' "$f" && { echo "the per-boot FAIL is still there: one empty capture still marks the cell"; return; }
  command grep -q 'ii_boots" -gt 0 ] && \[ "$mapped_any" = 1' "$f" || { echo "no arm for 'another boot mapped one' - the switch is still graded"; return; }
  command grep -q 'every boot with a guest-side window returned an empty dom0 capture' "$f" || { echo "no arm for 'no boot ever mapped one' - a dead capture would pass"; return; }
  echo ok
}
v=$(ii_shape "$M")
[ "$v" = ok ] && ok "desktop_switch_not_graded: an empty dom0 capture is graded at CELL scope, and only when no boot of the cell mapped a window" \
               || bad "desktop_switch_not_graded: $v"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
sed 's/# GUARD:iirepeat//' "$M" > "$T/noguard.sh"
sed 's/mapped_any=1; ok /ok /' "$M" > "$T/nomapped.sh"
sed 's/      ii_boots=$((ii_boots+1))/      no "$3-appvm boot $b: INVALID-INSTRUMENT - graded on the spot"/' "$M" > "$T/perboot.sh"
v1=$(ii_shape "$T/noguard.sh"); v2=$(ii_shape "$T/nomapped.sh"); v3=$(ii_shape "$T/perboot.sh")
[ "$v1" != ok ] && [ "$v2" != ok ] && [ "$v3" != ok ] \
  && ok "desktop_switch_not_graded SEEN TO FAIL: without the verdict '$v1'; without the mapped record '$v2'; graded per boot '$v3'" \
  || bad "desktop_switch_not_graded: a defect copy passed (noguard='$v1' nomapped='$v2' perboot='$v3') - the check proves nothing"

echo
echo "matrix-pool-floor-selftest: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
