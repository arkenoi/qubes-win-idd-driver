#!/usr/bin/env bash
# paced-ab.sh - pre-registered clean-install A/B: does SERIALIZING the guest's first-minutes work lower the stall rate?
#
# WHY (owner-approved 2026-10-04; findings/wedge.md "REVERSE CODE QUALITY IS EXPOSURE"): the stall is QEMU in the stub domain no
# longer completing the guest's requests, in a fresh domain's first minutes under concentrated activity. Rule (Jev 0.93): serialize
# and pace everything that reaches QEMU/Xen there. Two changes, tested together against today's behaviour:
#   CONTROL  the current release package + prime-run as the gate runs it (QUIET_AFTER_FIRST=0)
#   PACED    the same release built with QWT's services started ONE AT A TIME after msiexec + prime-run QUIET_AFTER_FIRST=1
#            (no guest call between a boot's first qrexec answer and the stage end / quiet window)
# Everything else identical: base win10-base (sealed), subject win10-acc recreated by prime-run every run, the gate's own prime-run
# invocation (`prime-run.sh <base> <subject> ours --payload <tree>`), arms INTERLEAVED so background drift hits both.
#
#   mgmt/harness/paced-ab.sh <control-setup-tree> <paced-setup-tree> <runs-per-arm> <base> <subject>   (no defaults - name every guest)
#
# Per run: OK (prime-run exit 0) / STALL (exit 2 = its deadline with qrexec dead, the guest left Running and captured - FLAT or
# MOVING) / OTHER (anything else; reported, never counted as OK). A stall's memory image is reduced to its small state and dropped
# (mgmt/harness/drop-core.sh) so the next stall has room - the 2026-10-04 lesson. Results: $OUT/runs.tsv, $OUT/RESULT.txt.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
CTRL="${1:?usage: paced-ab.sh <control-setup-tree> <paced-setup-tree> <runs-per-arm> <base> <subject>}"
PACED="${2:?paced setup tree}"
N="${3:?runs per arm}"; BASE="${4:?base golden - named explicitly}"; SUBJ="${5:?subject - named explicitly}"
for t in "$CTRL" "$PACED"; do [ -f "$t/install.cmd" ] || { echo "FATAL: $t has no install.cmd - not a setup tree"; exit 2; }; done
OUT="scratchpad/paced-ab-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$OUT"
say(){ echo "$(date -u +%H:%M:%SZ) paced-ab: $*" | tee -a "$OUT/run.log"; }
pkgid(){ grep -aoE '"package_version"[^,]*' "$1/MANIFEST.json" 2>/dev/null | head -1; }
printf 'run\tarm\tstart_utc\tsecs\texit\tverdict\tclass\tevidence\n' > "$OUT/runs.tsv"
say "arms: CONTROL=$CTRL ($(pkgid "$CTRL")) QUIET_AFTER_FIRST=0 | PACED=$PACED ($(pkgid "$PACED")) QUIET_AFTER_FIRST=1; $N per arm, interleaved"
say "base $BASE, subject $SUBJ; the pre-registration is $OUT/../$(basename "$0" .sh)-PREREG.txt (written before the first run)"

c_stall=0; p_stall=0; c_ok=0; p_ok=0; c_other=0; p_other=0
for i in $(seq 1 "$N"); do
  for arm in CONTROL PACED; do
    tree="$CTRL"; q=0; [ "$arm" = PACED ] && { tree="$PACED"; q=1; }
    log="$OUT/run-$i-$arm.log"; t0=$(date +%s); st=$(date -u +%H:%M:%SZ)
    say "run $i/$N $arm: prime-run $BASE -> $SUBJ (QUIET_AFTER_FIRST=$q)"
    QUIET_AFTER_FIRST=$q QUIET_WINDOW=300 \
      ./mgmt/harness/prime-run.sh "$BASE" "$SUBJ" ours --payload "$tree" --deadline "${AB_DEADLINE:-1800}" > "$log" 2>&1
    rc=$?; secs=$(( $(date +%s) - t0 ))
    ev=$(grep -aoE 'evidence/prime-[a-z]+-[a-z0-9-]+-[0-9]{8}-[0-9]{6}' "$log" | head -1)
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
    # the stall's memory image: keep its small state, free the space for the next one
    if [ -n "$ev" ] && [ -f "$ev/guest.core" ]; then
      bash mgmt/harness/drop-core.sh "$ev/guest.core" >> "$OUT/run.log" 2>&1 || say "  WARNING: drop-core refused on $ev/guest.core - check space before the next run"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$i" "$arm" "$st" "$secs" "$rc" "$verdict" "$cls" "${ev:--}" >> "$OUT/runs.tsv"
    say "  run $i $arm: $verdict${cls:+ ($cls)} rc=$rc in ${secs}s${ev:+ evidence $ev}"
    case "$arm:$verdict" in
      CONTROL:STALL) c_stall=$((c_stall+1)) ;; PACED:STALL) p_stall=$((p_stall+1)) ;;
      CONTROL:OK) c_ok=$((c_ok+1)) ;; PACED:OK) p_ok=$((p_ok+1)) ;;
      CONTROL:OTHER) c_other=$((c_other+1)) ;; PACED:OTHER) p_other=$((p_other+1)) ;;
    esac
    say "  tally: CONTROL stall $c_stall ok $c_ok other $c_other | PACED stall $p_stall ok $p_ok other $p_other"
  done
done
python3 - "$c_stall" "$c_ok" "$p_stall" "$p_ok" > "$OUT/RESULT.txt" <<'PY'
import sys
from math import comb
cs, co, ps, po = map(int, sys.argv[1:5]); cn, pn = cs + co, ps + po
# one-sided Fisher: P(PACED stalls <= observed | margins), i.e. evidence that PACED < CONTROL
k = cs + ps; tot = comb(cn + pn, k)
p = sum(comb(pn, x) * comb(cn, k - x) for x in range(0, ps + 1)) / tot if tot else float('nan')
print(f"STALL among graded runs: CONTROL {cs}/{cn}  PACED {ps}/{pn}; one-sided Fisher p = {p:.4f}")
print("pre-registered bar: p <= 0.05 -> PACED lowers the clean-install stall rate; otherwise NOT SHOWN (a result, not a retry)")
PY
cat "$OUT/RESULT.txt" | tee -a "$OUT/run.log"
say "OTHER (not graded, reported): CONTROL $c_other, PACED $p_other - see runs.tsv"
