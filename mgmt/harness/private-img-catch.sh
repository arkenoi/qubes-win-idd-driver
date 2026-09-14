#!/bin/bash
# private-img-catch.sh - repeat the clean-install cell until the private image FAILS to appear,
# and keep the install-time DISKPROBE from that run.
#
# WHY. The missing-Q: defect is intermittent: the stock prepare-private-img.ps1 prepares
# `Get-Disk -Number 1` and nothing else, and prime-run attaches an answer stick and a diag stick
# that add four disks a real guest never has - so whether disk #1 is the private volume is a
# lottery. Two fixes were written from inference about that lottery and BOTH had to be reverted
# (91aafb5/b6d7a4b, bd1af0f). The thing nobody has is the enumeration from a run that FAILED.
#
# The DISKPROBE diagnostic (2774243) now ships and logs every disk at the moment the MSI's action
# decides. So this does not guess: it runs the cell until the defect shows, then preserves the
# probe from the failing run. That output is what licenses a fix.
#
# A PASS IS NOT A RESULT HERE - it is a miss. The script keeps going until it catches a failure or
# runs out of attempts, and says which happened.
#
#   RUNID=<release-package run id> mgmt/harness/private-img-catch.sh [max-attempts]
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

RUNID="${RUNID:?set RUNID to the release-package run id carrying the DISKPROBE diagnostic}"
MAX="${1:-4}"
OUT="${PIC_OUT:-scratchpad/private-img-catch/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"
say(){ echo "[$(date -u +%H:%M:%S)] $*"; }

F="/home/user/qwt-accept/rel-$RUNID/campaign/matrix/WIN10-clean-final.log"

for n in $(seq 1 "$MAX"); do
  say "=== attempt $n/$MAX ==="
  rm -f "$F"
  ./tools/release-acceptance.sh --run "$RUNID" --cells win10-clean --skip-features \
      >"$OUT/attempt-$n.console" 2>&1
  rc=$?
  if [ ! -f "$F" ]; then
    say "attempt $n: no install log produced (rc=$rc) - VOID, not a miss"
    continue
  fi
  cp "$F" "$OUT/attempt-$n-install.log"
  probe=$(grep -aE 'DISKPROBE: Q:' "$F" | tail -1)
  say "attempt $n: $probe"
  if printf '%s' "$probe" | grep -qa 'present=False'; then
    say ""
    say "CAUGHT IT - the private image was ABSENT on this run. Enumeration at that moment:"
    grep -aE 'DISKPROBE:' "$F" | sed 's/^/    /'
    say ""
    say "evidence: $OUT/attempt-$n-install.log"
    say "=== private-img-catch: caught on attempt $n ==="
    exit 0
  fi
  say "attempt $n: Q: was present - a MISS, not a pass; continuing"
done

say "=== private-img-catch: $MAX attempts, never caught the failure ==="
say "    That is NOT evidence the defect is gone - it is an unlucky sample of a lottery."
say "    Raise the attempt count, or make the enumeration deterministic and test that instead."
exit 1
