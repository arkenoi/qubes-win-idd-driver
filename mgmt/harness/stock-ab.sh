#!/usr/bin/env bash
# stock-ab.sh - pre-registered clean-install A/B: does OUR release stall more than STOCK QWT under the identical install harness?
#
# WHY (owner, 2026-10-04: "it could not be THAT unstable"; Jev: this experiment next 0.85, over a product-only pacing A/B 0.08 and a
# host reboot first 0.07): our clean installs stall ~18% under the gate's harness, and the only stock control on record is a SOAK
# (STOCK 3/6 vs OURS 4/6 under 6 serial VMShell loops) - a load no user produces. This compares the two PRODUCTS through the same
# install flow: same sealed base, same subject recreated every run, the same prime-run harness with NO quiet window in either arm
# (the owner rejected the 420 s hands-off window, 2026-10-04), arms interleaved in ABBA order so drift and order hit both.
#   STOCK  prime-run job stock-422 (genuine QWT 4.2.2, its own install flow)
#   OURS   prime-run job ours --payload <release setup tree>
#
#   mgmt/harness/stock-ab.sh <ours-setup-tree> <runs-per-arm> <base> <subject>   (no defaults - name every guest)
#
# Per run: OK (prime-run exit 0) / STALL (exit 2 = its deadline with qrexec dead, the guest left Running and captured - FLAT or
# MOVING) / OTHER (anything else; reported, never counted as OK). A stall's memory image is reduced to its small state and dropped
# (drop-core.sh). STOP: `touch $OUT/STOP` ends the A/B at the next run boundary - no process is ever killed to stop it.
# PRIME_RUN overrides the harness path for the stub self-test only. Results: $OUT/runs.tsv, $OUT/RESULT.txt.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
OURS="${1:?usage: stock-ab.sh <ours-setup-tree> <runs-per-arm> <base> <subject>}"
N="${2:?runs per arm}"; BASE="${3:?base golden - named explicitly}"; SUBJ="${4:?subject - named explicitly}"
PR="${PRIME_RUN:-./mgmt/harness/prime-run.sh}"
[ -f "$OURS/install.cmd" ] || { echo "FATAL: $OURS has no install.cmd - not a setup tree"; exit 2; }
[ -f mgmt/prime-jobs/stock-422/qubes-tools-4.2.2.exe ] || { echo "FATAL: the stock-422 job has no qubes-tools-4.2.2.exe"; exit 2; }
OUT="${STOCK_AB_OUT:-scratchpad/stock-ab-$(date -u +%Y%m%dT%H%M%SZ)}"; mkdir -p "$OUT"
say(){ echo "$(date -u +%H:%M:%SZ) stock-ab: $*" | tee -a "$OUT/run.log"; }
pkgid(){ grep -aoE '"package_version"[^,]*' "$1/MANIFEST.json" 2>/dev/null | head -1; }
printf 'run\tarm\tstart_utc\tsecs\texit\tverdict\tclass\tevidence\n' > "$OUT/runs.tsv"
say "arms: STOCK=stock-422 (QWT 4.2.2) | OURS=$OURS ($(pkgid "$OURS")); both QUIET_BOOT_SECS=0 QUIET_AFTER_FIRST=0; $N per arm, ABBA"
say "base $BASE, subject $SUBJ; harness $PR; stop with: touch $OUT/STOP"

s_stall=0; o_stall=0; s_ok=0; o_ok=0; s_other=0; o_other=0
for i in $(seq 1 "$N"); do
  order="STOCK OURS"; [ $((i % 2)) -eq 0 ] && order="OURS STOCK"
  for arm in $order; do
    [ -e "$OUT/STOP" ] && { say "STOP file present - ending at the run boundary before run $i $arm"; break 2; }
    log="$OUT/run-$i-$arm.log"; t0=$(date +%s); st=$(date -u +%H:%M:%SZ)
    say "run $i/$N $arm: prime-run $BASE -> $SUBJ"
    if [ "$arm" = STOCK ]; then
      QUIET_BOOT_SECS=0 QUIET_AFTER_FIRST=0 "$PR" "$BASE" "$SUBJ" stock-422 --deadline "${AB_DEADLINE:-1800}" > "$log" 2>&1
    else
      QUIET_BOOT_SECS=0 QUIET_AFTER_FIRST=0 "$PR" "$BASE" "$SUBJ" ours --payload "$OURS" --deadline "${AB_DEADLINE:-1800}" > "$log" 2>&1
    fi
    rc=$?; secs=$(( $(date +%s) - t0 ))
    ev=$(grep -aoE 'evidence/prime-[a-z]+(-[a-z0-9]+)*-[0-9]{8}-[0-9]{6}' "$log" | head -1)
    cls=-
    case "$rc" in
      0) verdict=OK ;;
      2) if grep -aq 'DEADLINE:' "$log"; then
           verdict=STALL
           grep -aq 'FROZEN stall' "$log" && cls=FLAT
           grep -aq 'EXECUTING-BUT-UNREACHABLE' "$log" && cls=MOVING
           grep -aq 'cpu_time UNREADABLE' "$log" && { cls=UNREADABLE; verdict=OTHER; }
         else verdict=OTHER; fi ;;
      *) verdict=OTHER ;;
    esac
    if [ -n "$ev" ] && [ -f "$ev/guest.core" ]; then
      bash mgmt/harness/drop-core.sh "$ev/guest.core" >> "$OUT/run.log" 2>&1 || say "  WARNING: drop-core refused on $ev/guest.core - check space before the next run"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$i" "$arm" "$st" "$secs" "$rc" "$verdict" "$cls" "${ev:--}" >> "$OUT/runs.tsv"
    say "  run $i $arm: $verdict${cls:+ ($cls)} rc=$rc in ${secs}s${ev:+ evidence $ev}"
    case "$arm:$verdict" in
      STOCK:STALL) s_stall=$((s_stall+1)) ;; OURS:STALL) o_stall=$((o_stall+1)) ;;
      STOCK:OK) s_ok=$((s_ok+1)) ;; OURS:OK) o_ok=$((o_ok+1)) ;;
      STOCK:OTHER) s_other=$((s_other+1)) ;; OURS:OTHER) o_other=$((o_other+1)) ;;
    esac
    say "  tally: STOCK stall $s_stall ok $s_ok other $s_other | OURS stall $o_stall ok $o_ok other $o_other"
  done
done
python3 - "$s_stall" "$s_ok" "$o_stall" "$o_ok" > "$OUT/RESULT.txt" <<'PY'
import sys
from math import comb
ss, so, os_, oo = map(int, sys.argv[1:5]); sn, on = ss + so, os_ + oo
def ci(k, n):
    # exact (Clopper-Pearson) 95% interval by bisection on the binomial tail
    if n == 0: return (float('nan'), float('nan'))
    tail_ge = lambda p: sum(comb(n, j) * p**j * (1-p)**(n-j) for j in range(k, n + 1))
    tail_le = lambda p: sum(comb(n, j) * p**j * (1-p)**(n-j) for j in range(0, k + 1))
    def solve(f, target, increasing):
        lo, hi = 0.0, 1.0
        for _ in range(60):
            mid = (lo + hi) / 2
            if (f(mid) < target) == increasing: lo = mid
            else: hi = mid
        return (lo + hi) / 2
    lower = 0.0 if k == 0 else solve(tail_ge, 0.025, True)
    upper = 1.0 if k == n else solve(tail_le, 0.025, False)
    return (lower, upper)
k = ss + os_; tot = comb(sn + on, k)
# one-sided Fisher, the pre-registered direction: P(OURS stalls >= observed | margins) - evidence that OURS > STOCK
p_ours_more = sum(comb(on, x) * comb(sn, k - x) for x in range(os_, min(on, k) + 1)) / tot if tot else float('nan')
# the other direction, reported, not the test
p_ours_less = sum(comb(on, x) * comb(sn, k - x) for x in range(max(0, k - sn), os_ + 1)) / tot if tot else float('nan')
sl, sh = ci(ss, sn); ol, oh = ci(os_, on)
print(f"STALL among graded runs: STOCK {ss}/{sn} (95% {sl:.2f}-{sh:.2f})  OURS {os_}/{on} (95% {ol:.2f}-{oh:.2f})")
print(f"one-sided Fisher, OURS stalls MORE than STOCK: p = {p_ours_more:.4f}   (other direction, reported only: p = {p_ours_less:.4f})")
print("pre-registered bar: p <= 0.05 -> OUR release stalls more than stock under the same install flow (our change is the cause);")
print("otherwise NOT SHOWN - read with the CIs (a result, not a reason to re-run the same design)")
PY
cat "$OUT/RESULT.txt" | tee -a "$OUT/run.log"
say "OTHER (not graded, reported): STOCK $s_other, OURS $o_other - see runs.tsv"
