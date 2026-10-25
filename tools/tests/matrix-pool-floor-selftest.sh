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
# THE NEEDLE, NOT THE WARNING, WAS MISSING. This greped 'POOL WARNING' while the gate emits
# "[WARN] POOL  75 GB free on vm-pool (warn below 90) - enough to start, tight to finish": the
# every-line-declares-its-level work moved the word to a prefix, and a position-anchored consumer
# went blind - the same shape as the four consumers a FRONT-inserted prefix blinded before. Matched
# on the stable part of the sentence instead of on a word whose place in the line can move.
if [ "$rc" = 0 ] && printf '%s' "$out" | command grep -q 'warn below .* - enough to start, tight to finish'; then
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
# ANCHOR ON THE GATE, NOT ON "THE LAST LOOP". matrix.sh has THREE `for c in $CELLS; do` loops
# (lines 2823, 2843, 3102); the gated one is the SECOND, so rindex picked a loop 253 lines PAST the
# gate, found nothing, and reported the per-cell gating missing while it was present and correct.
# A fixed 1400-byte window was the other half of the same mistake: it measures distance in bytes
# from an anchor that was already wrong, so adding a comment above the call could break it too.
# Find the gate, then prove it is INSIDE a cell loop by looking BACKWARDS for the nearest header.
g = s.find('pool_gate "cell $c"')
if g < 0: print('NOT-IN-LOOP'); raise SystemExit
i = s.rfind('for c in $CELLS; do', 0, g)
if i < 0: print('NOT-IN-LOOP'); raise SystemExit
c = s.find('case $c in', g)
if c < 0: print('NOT-IN-LOOP'); raise SystemExit
body = s[g:c]
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
  # THE PROPERTY, NOT THE SPELLING. This greped 'mapped_any=1; ok ' - a statement pair that no longer
  # exists: the mapped verdict is recorded by a case arm on the verdict code, `0) mapped_any=1 ;;`,
  # and the ok() call moved. The property is that the mapped-a-window verdict SETS the flag and the
  # exoneration arm READS it; both hold (matrix.sh:2626 and :2632). The suite's own mutation for this
  # clause matched the same dead text, so the control was inert as well - both are fixed together.
  command grep -qE '^[[:space:]]*0\)[[:space:]]*mapped_any=1' "$f" || { echo "a boot that DID map a window is not recorded, so nothing can exonerate the others"; return; }
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
sed -E 's/^([[:space:]]*)0\)[[:space:]]*mapped_any=1[[:space:]]*;;/\1 0) ;;/' "$M" > "$T/nomapped.sh"
# THE MUTATION MUST MATCH THE CODE AS IT IS. This targeted a bare `      ii_boots=$((ii_boots+1))`
# assignment; the counter moved into a case arm - `2) ii_boots=$((ii_boots+1)) ;;` - so the sed
# matched nothing, the "defect" copy was identical to the real file, and this control reported `ok`
# for a mutation it never applied. Same cause as the mapped_any clause above: both were plain
# statements and both became case arms.
sed -E 's/^([[:space:]]*)2\)[[:space:]]*ii_boots=\$\(\(ii_boots\+1\)\)[[:space:]]*;;/\1 2) no "$3-appvm boot $b: INVALID-INSTRUMENT - graded on the spot" ;;/' "$M" > "$T/perboot.sh"
v1=$(ii_shape "$T/noguard.sh"); v2=$(ii_shape "$T/nomapped.sh"); v3=$(ii_shape "$T/perboot.sh")
[ "$v1" != ok ] && [ "$v2" != ok ] && [ "$v3" != ok ] \
  && ok "desktop_switch_not_graded SEEN TO FAIL: without the verdict '$v1'; without the mapped record '$v2'; graded per boot '$v3'" \
  || bad "desktop_switch_not_graded: a defect copy passed (noguard='$v1' nomapped='$v2' perboot='$v3') - the check proves nothing"

# ---- the space RECORDER: what it must never write, and what it must ----------------------------
# Jev set the campaign space gate at measured-peak-first 0.91 - the preflight refuses below a
# MEASURED peak and says UNVERIFIED until one exists - so matrix.sh records the draw of every
# campaign. It took three attempts to make that recorder safe, and each failure was a suite writing
# a TRACKED rig record from stubbed values: first `peak_used_gb: 425` (from this suite's 500/75
# legs), which would have made the preflight refuse every campaign thereafter; then a guard on the
# stub, which one leg bypasses by driving an EMPTY stub; then a guard on $M, which THIS SUITE uses
# as the path to matrix.sh, so it wrote a record keyed "matrix.sh". Hence these legs.
_rec_src(){ sed -n '/^POOL_SPACE_RECORD=/,/^}$/p' "$M"; }
_rec_run(){ # <identity> <stub> <record> <free...>
  local id="$1" stub="$2" rec="$3"; shift 3
  ( POOL_SPACE_RUN="$id" POOL_FREE_GB_STUB="$stub" POOL_SPACE_RECORD="$rec" \
    bash -c "source <(cd '$ROOT' && sed -n '/^POOL_SPACE_RECORD=/,/^}\$/p' '$M'); for f in $*; do pool_space_record \$f; done" ) 2>/dev/null
}
_R="$T/space.json" 2>/dev/null || _R="${TMPDIR:-/tmp}/space-$$.json"
rm -f "$_R"
_rec_run "" "" "$_R" 64
[ ! -f "$_R" ] && ok "the recorder writes NOTHING without a campaign identity - a suite cannot create the record" \
               || bad "the recorder wrote a record with no campaign identity: $(cat "$_R" 2>/dev/null | tr -d '\n')"
rm -f "$_R"
_rec_run "camp-1" "75" "$_R" 75
[ ! -f "$_R" ] && ok "a STUBBED reading is never recorded - 500/75 test values cannot become the rig's requirement" \
               || bad "the recorder wrote a stubbed reading: $(cat "$_R" 2>/dev/null | tr -d '\n')"
rm -f "$_R"
_rec_run "camp-1" "" "$_R" 100 82 91
_peak=$(python3 -c "import json;print(json.load(open('$_R'))['peak_used_gb'])" 2>/dev/null)
[ "$_peak" = 18 ] && ok "a real campaign's DRAW is recorded: 100 -> 82 -> 91 gives peak_used_gb=18" \
                  || bad "peak_used_gb=$_peak, expected 18"
_rec_run "camp-2" "" "$_R" 200 195
_peak=$(python3 -c "import json;print(json.load(open('$_R'))['peak_used_gb'])" 2>/dev/null)
_runs=$(python3 -c "import json;print(len(json.load(open('$_R'))['measured_runs']))" 2>/dev/null)
{ [ "$_peak" = 18 ] && [ "$_runs" = 2 ]; } \
  && ok "a LUCKIER campaign does not shrink the floor: camp-2 drew 5 and the peak stays 18, both runs recorded" \
  || bad "peak=$_peak runs=$_runs - a later run that drew less must not lower the rig's requirement"
rm -f "$_R"

# ---- THE CAMPAIGN IDENTITY ITSELF, taken from matrix.sh's own lines ----------------------------
# Every leg above drives the recorder with an identity this suite invents, so none of them can see
# the identity matrix.sh actually derives. tools/release-acceptance.sh:285 passes
# MATRIX_OUT="$CAMP/matrix" where CAMP="$WORK/campaign", so NO part of that path differs between
# campaigns: `basename "$M"` is `matrix` every time (recorded as `"run": "matrix"` by attempt
# 1024-2333) and `<parent>-<leaf>` is `campaign-matrix` every time. The expressions are EXTRACTED
# here rather than retyped, because a retyped copy keeps passing after the real one changes.
_MATRIX_SH="$M"   # in this suite $M is the PATH TO matrix.sh; inside matrix.sh it is the output dir
_id_of(){ # <matrix-out> [inherited-attempt] -> the identity matrix.sh would use
  ( unset POOL_SPACE_RUN; M="$1"; MATRIX_ATTEMPT="${2:-}"
    [ -n "$MATRIX_ATTEMPT" ] || unset MATRIX_ATTEMPT
    eval "$(sed -n '/^MATRIX_ATTEMPT="\${MATRIX_ATTEMPT/p;/^POOL_SPACE_RUN=/p' "$_MATRIX_SH")"
    echo "$POOL_SPACE_RUN" ) 2>/dev/null
}
_CAMPOUT=/home/user/qwt-accept/w/campaign/matrix     # the real shape, both campaigns identical
_idA=$(_id_of "$_CAMPOUT" 20261024T233300Z)
_idB=$(_id_of "$_CAMPOUT" 20261025T010000Z)
if [ -n "$_idA" ] && [ "$_idA" != "$_idB" ]; then
  ok "two campaigns with the SAME MATRIX_OUT get DIFFERENT identities ($_idA vs $_idB) - the attempt id, not the path"
else bad "the identity does not distinguish two campaigns: A='$_idA' B='$_idB' - with MATRIX_OUT identical for every campaign, that is the 1024-2333 defect"; fi
case "$_idA" in
  matrix|campaign-matrix) bad "the identity is a PATH form ('$_idA') - both collide for every campaign on this rig" ;;
  20261024T233300Z) ok "...and it IS the inherited attempt id, the one string release-acceptance and matrix.sh already share" ;;
  *) bad "unexpected identity '$_idA'" ;;
esac
# A STANDALONE matrix run has no campaign above it and must still be unique: matrix.sh defaults the
# attempt id to a UTC stamp, so the fallback is a timestamp rather than a path.
_idS=$(_id_of /home/user/qwt-matrix/20261025-010203)
case "$_idS" in
  ""|matrix|*campaign*) bad "a standalone run got no usable identity: '$_idS'" ;;
  *) ok "a standalone matrix run still gets a unique identity ($_idS) from its own attempt default" ;;
esac

# WHY IT MATTERS, driven: with the identity SHARED the recorder never re-bases, so campaign 2's draw
# is computed against campaign 1's start - 200 free minus 82 free = 118 GB that no campaign drew,
# and the peak only grows, so the preflight would refuse real campaigns against it forever.
rm -f "$_R"
_rec_run "shared" "" "$_R" 100 82
_rec_run "shared" "" "$_R" 200 195
_peak=$(python3 -c "import json;print(json.load(open('$_R'))['peak_used_gb'])" 2>/dev/null)
[ "$_peak" = 118 ] \
  && ok "SEEN TO FAIL: one identity for two campaigns invents a 118 GB peak from two runs' numbers - that is what '\"run\": \"matrix\"' would have done on the second campaign" \
  || bad "the shared-identity contamination did not reproduce (peak=$_peak, expected 118) - then this leg is not measuring why the identity must differ"
rm -f "$_R"

echo
echo "matrix-pool-floor-selftest: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
