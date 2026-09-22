#!/bin/bash
# stall-ab.sh - the ONE experiment the stall hypothesis deserves, run enough times to mean something.
#
# HYPOTHESIS (Jev, 2026-09-22: `medium-pulled-from-reader` 0.56, runner-up `upcall-not-serviced`
# 0.33): the installer executes install.cmd FROM THE CD while the install replaces the guest's PV
# storage path, so the I/O it depends on can never complete and a kernel thread spins. The stalled
# specimen's CD backend sat in InitWait, waiting for a frontend that never came back.
#
# VARIABLE, and it is the only one: WHERE install.cmd RUNS FROM.
#   arm DISC   - install.cmd launched from the CD (today's behaviour, the control)
#   arm STAGED - the tree is copied to C:\qwtstage first and install.cmd runs from THERE, so no
#                live medium is needed while the storage path is replaced
# Everything else is identical: same golden, same package, same disc present in both arms (the CD
# stays attached in STAGED too, so "the disc is there" is not the difference - only who reads it).
#
# WHY IT MUST BE REPEATED: Jev puts `reproducible_on_demand` at 0.22. This cannot be summoned, so a
# 3-per-arm run proves nothing. Arms are INTERLEAVED so anything drifting in the background (pool
# fill, dom0 state, time of night) hits both equally.
#
#   mgmt/harness/stall-ab.sh <setup-tree-or-iso> [runs-per-arm]
#
# Each run is one quick-upgrade of a fresh clone; a STALL leaves the guest up, is captured with
# dom0 forensics (RIPs, vcpu states) and the guest is then released so the next run can start.
# Module bases are armed by quick-upgrade itself since 2026-09-22, so a stall RESOLVES to a driver.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
PKG="${1:?usage: stall-ab.sh <setup-tree-or-iso> [runs-per-arm]}"
N="${2:-8}"
OUT="scratchpad/stall-ab-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$OUT"
say(){ echo "$(date -u +%H:%M:%SZ) stall-ab: $*" | tee -a "$OUT/run.log"; }

say "hypothesis: the installer's own medium is pulled while the PV storage path is replaced"
say "arms: DISC (control) vs STAGED (install.cmd from C:); $N runs each, interleaved"
say "package: $PKG"

capture_stall(){ # $1=vm $2=tag - the specimen, before anything is released
  local vm="$1" tag="$2" d="$OUT/stall-$tag"
  mkdir -p "$d"
  timeout 300 qrexec-client-vm dom0 "local.WinWedgeForensics+$vm" </dev/null > "$d/forensics.tar" 2>/dev/null \
    && say "  $tag: forensics captured"
  local arch; arch=$(ls -t ~/QubesIncoming/dom0/wedge-*.tar.gz 2>/dev/null | head -1)
  [ -n "$arch" ] && cp "$arch" "$d/" 2>/dev/null
  timeout 120 bash tools/loopback-health.sh > "$d/loopback.txt" 2>&1
  # The RIPs are only worth anything against the module bases quick-upgrade recorded this run.
  local mb; mb=$(ls -t "$OUT"/../qwt-quick-upgrade/*/modbases* 2>/dev/null | head -1)
  [ -n "$mb" ] && cp "$mb" "$d/" 2>/dev/null
}

run_one(){ # $1=arm $2=index -> prints RESULT|STALLED|OTHER
  local arm="$1" i="$2" vm="win11-sab" tag="$arm-$i"
  qvm-check "$vm" >/dev/null 2>&1 && { timeout 120 qvm-kill "$vm" >/dev/null 2>&1; timeout 300 qvm-remove -f "$vm" >/dev/null 2>&1; }
  local extra=()
  [ "$arm" = STAGED ] && extra=(--stage-to-c)
  timeout 3000 bash mgmt/harness/quick-upgrade.sh "$PKG" "$vm" win11 "${extra[@]}" \
      > "$OUT/$tag.log" 2>&1
  local rc=$?
  # Classify on the harness's OWN terminal verdict, not on the word appearing anywhere in the log,
  # and never let an outer timeout masquerade as a clean run.
  if [ $rc = 124 ]; then say "  $tag: the outer timeout fired - neither arm gets credit"; echo OTHER; return; fi
  if grep -qE "TERMINAL: install STALLED|STALLED \(SPINNING\)|STALLED \(FROZEN\)" "$OUT/$tag.log"; then
    say "  $tag: STALLED (rc=$rc) - capturing the specimen"
    capture_stall "$vm" "$tag"
    echo STALLED
  elif [ $rc = 0 ]; then echo RESULT
  else say "  $tag: rc=$rc without a STALLED line - read $OUT/$tag.log"; echo OTHER; fi
}

declare -A tally
for i in $(seq 1 "$N"); do
  for arm in DISC STAGED; do
    say "run $i/$N arm $arm"
    r=$(run_one "$arm" "$i")
    tally[$arm-$r]=$(( ${tally[$arm-$r]:-0} + 1 ))
    say "  -> $arm run $i: $r   (running tally: DISC stalled=${tally[DISC-STALLED]:-0}/ok=${tally[DISC-RESULT]:-0}  STAGED stalled=${tally[STAGED-STALLED]:-0}/ok=${tally[STAGED-RESULT]:-0})"
  done
done
say "FINAL: DISC stalled=${tally[DISC-STALLED]:-0} ok=${tally[DISC-RESULT]:-0} other=${tally[DISC-OTHER]:-0}"
say "FINAL: STAGED stalled=${tally[STAGED-STALLED]:-0} ok=${tally[STAGED-RESULT]:-0} other=${tally[STAGED-OTHER]:-0}"
say "evidence in $OUT"
