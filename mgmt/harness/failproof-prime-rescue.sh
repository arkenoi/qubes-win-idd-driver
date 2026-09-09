#!/bin/bash
# failproof-prime-rescue.sh - proves the prime-run RESCUE gate fix on the REAL recorded telemetry
# of the 2026-09-09 win11-clean DEADLINE failure, and proves the check can FAIL (defect
# re-introduced = never rescues), pass (fixed = rescues), and not over-fire (healthy trace).
#
#   ./mgmt/harness/failproof-prime-rescue.sh
#
# No VM is touched: the rescue decision is pure arithmetic over the (cpu, screen) signal the poll
# loop observed, so the exact observed traces are replayed through the SAME functions prime-run.sh
# calls (mgmt/harness/prime-rescue-lib.sh).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 2
source mgmt/harness/prime-rescue-lib.sh

RESCUE_AFTER=420; RESCUE_QUIET=8; RESCUE_NOSHOW=4
fail=0
say(){ echo "$*"; }

# --- the FAILING run's observed trace (from qwt-matrix/20260909-103232/WIN11-clean-prime.log) ----
# One entry per poll: "el cpu screen".  cpu "NA" = libxl stats were unreadable that poll (logged as
# an empty cpu= field).  screen "-" = not probed this poll.  This is the trace verbatim.
FAIL_TRACE='
20 169 -
51 233 -
81 207 DESKTOP
115 287 -
145 288 DESKTOP
179 NA -
208 268 DESKTOP
241 190 DESKTOP
275 231 -
305 212 DESKTOP
338 159 -
414 4 SHOTFAIL
491 NA SHOTFAIL
569 NA SHOTFAIL
647 NA SHOTFAIL
724 NA SHOTFAIL
802 NA SHOTFAIL
880 NA SHOTFAIL
958 NA SHOTFAIL
1036 NA SHOTFAIL
1114 NA SHOTFAIL
1500 NA SHOTFAIL
3604 NA SHOTFAIL
'

# --- a HEALTHY warm-reboot PASS trace (from qwt-matrix/20260908-210957) up to qrexec ------------
# Must NOT trigger a rescue: it reaches qrexec at t+370 and every screen is DESKTOP/BLACK.
OK_TRACE='
20 251 -
50 208 -
81 223 DESKTOP
114 264 -
144 285 DESKTOP
178 277 -
208 NA BLACK
242 296 DESKTOP
276 189 -
306 155 DESKTOP
340 180 -
'

# replay <trace> <mode: fixed|legacy>  -> echoes "FIRED <el>" or "NEVER"
replay(){
  local trace="$1" mode="$2" q=0 ns=0 el cpu sv since
  while read -r el cpu sv; do
    [ -n "${el:-}" ] || continue
    [ "$sv" = "-" ] && sv=""
    since=$el   # no restart in these traces, so since_start == elapsed
    if [ "$mode" = legacy ]; then
      # DEFECT RE-INTRODUCED, verbatim old logic: NA/empty scored as the busy sentinel 9999
      # (resets the streak), and no screen trigger.
      local lc="$cpu"; [ "$lc" = NA ] && lc=9999
      if [ "${lc:-9999}" -lt 15 ] 2>/dev/null; then q=$((q+1)); else q=0; fi
      if [ "$since" -ge "$RESCUE_AFTER" ] && [ "$q" -ge "$RESCUE_QUIET" ]; then echo "FIRED $el"; return; fi
    else
      q=$(rescue_quiet_step "$q" "$cpu")
      ns=$(rescue_noshow_step "$ns" "$sv")
      if rescue_should_fire 0 "$since" "$RESCUE_AFTER" "$q" "$RESCUE_QUIET" "$ns" "$RESCUE_NOSHOW"; then
        echo "FIRED $el"; return
      fi
    fi
  done <<<"$trace"
  echo NEVER
}

check(){ # $1=label $2=got $3=expected-pattern
  if [[ "$2" == $3 ]]; then say "PASS  $1: $2"; else say "FAIL  $1: got '$2', wanted '$3'"; fail=1; fi
}

say "=== fail-proof: prime-run rescue gate (real 2026-09-09 telemetry) ==="

# 1. DEFECT PRESENT: on the failing trace the old logic NEVER fires -> the observed DEADLINE.
check "defect re-introduced never rescues the stuck guest" "$(replay "$FAIL_TRACE" legacy)" "NEVER"

# 2. FIXED: on the same trace the rescue fires once past the floor (screen-stall path leads).
got=$(replay "$FAIL_TRACE" fixed)
check "fixed logic rescues the stuck guest" "$got" "FIRED *"
if [[ "$got" == FIRED* ]]; then
  el=${got#FIRED }
  if [ "$el" -lt 3600 ]; then say "PASS  fixed rescues at t+${el}s, far inside the 3600s deadline"; else say "FAIL  rescue at t+${el}s is not inside the deadline"; fail=1; fi
fi

# 3. NO OVER-FIRE: the fix must not rescue a healthy warm-reboot run that is about to reach qrexec.
check "fixed logic does NOT fire on a healthy warm-reboot trace" "$(replay "$OK_TRACE" fixed)" "NEVER"

# 4. Unit edges of the pieces.
check "NA counts toward quiescence (was: reset)" "$(rescue_quiet_step 5 NA)" "6"
check "busy cpu resets quiescence"               "$(rescue_quiet_step 5 200)" "0"
check "low cpu counts toward quiescence"         "$(rescue_quiet_step 5 3)" "6"
check "SHOTFAIL builds the no-window streak"     "$(rescue_noshow_step 3 SHOTFAIL)" "4"
check "a DESKTOP verdict resets no-window"       "$(rescue_noshow_step 3 VERDICT=DESKTOP)" "0"
check "an unprobed poll leaves no-window as-is"  "$(rescue_noshow_step 3 '')" "3"
check "floor blocks an early rescue"             "$(rescue_should_fire 0 300 420 20 8 20 4 && echo FIRE || echo HOLD)" "HOLD"
check "already-rescued never fires again"        "$(rescue_should_fire 1 999 420 20 8 20 4 && echo FIRE || echo HOLD)" "HOLD"

say "==============================================================="
[ "$fail" = 0 ] && say "ALL PASS" || say "FAILURES ABOVE"
exit $fail
