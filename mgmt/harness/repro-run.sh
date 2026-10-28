#!/usr/bin/env bash
# repro-run.sh - REPLICATION driver: run the SAME clean-install flow N times and classify each.
#
# THIS IS NOT AN A/B, AND THAT IS THE WHOLE REASON IT EXISTS. paced-ab.sh already loops prime-run
# with classification and drop-core, so the obvious shortcut is to call it with the same setup tree
# in both arms. Jev scored that 0.51 (2026-10-28): it writes an `arm` column and ends by printing a
# one-sided Fisher p comparing two identical arms, so whatever the pre-registration says, the
# ARTIFACT left in runs.tsv/RESULT.txt reads as an A/B to the next person. A replication is a
# different claim from a comparison and gets a different artifact. No arms column, no p-value.
#
# WHY A REPLICATION AT ALL (2026-10-28): the synthetic churn instrument stopped reproducing the
# guest stall - burst-quiet-ab.sh returned SOAK 0/4, LOCAL 0/3 with both arms genuinely dosed,
# where the same SOAK dose gave 4/10 and 10/15 on 2026-09-28. Jev: synthetic_fails_to_reproduce
# 0.83, faithful_flow_is_next 0.88, reproduction_not_ab 0.91, and the property that must not be
# substituted is CONCURRENCY 0.98 - installer stage-2 device work (IDD devcon, emulated VGA
# disable, updater-agent install, PV NIC latch) overlapping gui-agent startup, the boot clock pull
# at +15 s and the updater scan at +2 min, in the first ~150 s after qvm-start, which is where
# every recorded onset sits. Only a real clean-install flow makes that overlap.
#
#   mgmt/harness/repro-run.sh <setup-tree> <runs> <base> <subject>     (no defaults - name every guest)
#   env: DEADLINE (1800)  STOP_ON_STALL (1 - stop at the first reproduction, the point of the run)
#
# Per run, straight from prime-run's own exit codes - no new classifier:
#   OK     exit 0
#   STALL  exit 2 with DEADLINE: in the log (FLAT / MOVING / UNREADABLE kept apart)
#   OTHER  anything else - reported, never counted as OK
# A stall's memory image is reduced to its small state (drop-core.sh) so the next one has room.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
TREE="${1:?usage: repro-run.sh <setup-tree> <runs> <base> <subject>}"
N="${2:?runs}"; BASE="${3:?base golden - named explicitly}"; SUBJ="${4:?subject - named explicitly}"
[ -f "$TREE/install.cmd" ] || { echo "FATAL: $TREE has no install.cmd - not a setup tree"; exit 2; }
OUT="scratchpad/repro-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$OUT"
say(){ echo "$(date -u +%H:%M:%SZ) repro: $*" | tee -a "$OUT/run.log"; }
printf 'run\tstart_utc\tsecs\texit\tverdict\tclass\tevidence\n' > "$OUT/runs.tsv"
say "tree $TREE ($(grep -aoE '"package_version"[^,]*' "$TREE/MANIFEST.json" 2>/dev/null | head -1))"
say "base $BASE -> subject $SUBJ, $N runs, deadline ${DEADLINE:-1800}s, stop_on_stall=${STOP_ON_STALL:-1}"

ok=0; stall=0; other=0
for i in $(seq 1 "$N"); do
  log="$OUT/run-$i.log"; t0=$(date +%s); st=$(date -u +%H:%M:%SZ)
  say "run $i/$N: prime-run $BASE -> $SUBJ"
  ./mgmt/harness/prime-run.sh "$BASE" "$SUBJ" ours --payload "$TREE" --deadline "${DEADLINE:-1800}" > "$log" 2>&1
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
  if [ -n "$ev" ] && [ -f "$ev/guest.core" ]; then
    bash mgmt/harness/drop-core.sh "$ev/guest.core" >> "$OUT/run.log" 2>&1 \
      || say "  WARNING: drop-core refused on $ev/guest.core - check space before the next run"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$i" "$st" "$secs" "$rc" "$verdict" "$cls" "${ev:--}" >> "$OUT/runs.tsv"
  case "$verdict" in OK) ok=$((ok+1));; STALL) stall=$((stall+1));; *) other=$((other+1));; esac
  say "  run $i: $verdict${cls:+ ($cls)} rc=$rc in ${secs}s${ev:+ evidence $ev}"
  say "  tally: OK $ok STALL $stall OTHER $other"
  if [ "$verdict" = STALL ] && [ "${STOP_ON_STALL:-1}" = 1 ]; then
    say "REPRODUCED on run $i - stopping so the specimen is examined while it is fresh"
    break
  fi
done
{ echo "REPLICATION (not an A/B): $ok OK, $stall STALL, $other OTHER out of $((ok+stall+other)) graded runs"
  echo "tree: $TREE"; echo "base: $BASE  subject: $SUBJ"
  [ "$stall" -gt 0 ] && echo "REPRODUCED - see runs.tsv for the evidence dir" \
                     || echo "NOT REPRODUCED in $((ok+stall+other)) runs - a result about this build and this n, nothing more"
} > "$OUT/RESULT.txt"
cat "$OUT/RESULT.txt" | tee -a "$OUT/run.log"
