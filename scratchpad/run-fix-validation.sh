#!/bin/bash
# Full chain for the coalescing fix on Windows 11, on ONE clean install:
#
#   1. clean install of the instrumented build, hash-gated (validate-coalesce.sh)
#   2. CPU vs the controlled baseline            -> did the fix reduce work?
#   3. hit rate, FocusRaise off vs on            -> did the fast path fire, and does
#                                                   z-order sync lift its ceiling?
#
# One install serves both because the instrumented build is a strict superset: same
# coalescing fix, plus the pwskip/pwcap counters, plus a FocusRaise switch that defaults
# to 0 = the historic behaviour. The only behavioural difference at FocusRaise=0 is two
# interlocked increments per per-window decision, which is noted rather than ignored.
set -u
cd /home/user/qubes-win-idd-driver
S=/tmp/claude-1000/-home-user-qubes-win-idd-driver/596ce65c-62cf-4820-af62-c943df501f00/scratchpad
log(){ echo "$(date -u +%H:%M:%S) chain: $*"; }

# Gate on the ARTIFACT's content, not on the commit having been pushed: a green build whose
# binary lacks the counters would produce an empty hit rate that reads like "never fired".
# The literals are UTF-16 in the PE (an earlier ASCII-only probe reported them absent and was
# simply looking at the wrong encoding).
F=$(find artifacts-hr -name gui-agent.exe 2>/dev/null | head -1)
if [ -n "$F" ]; then
    for probe in pwskip pwcap QGAFOCUSRAISE; do
        n=$(strings -a -e l "$F" | grep -c "$probe")
        [ "$n" -gt 0 ] || { log "ABORT: $F lacks '$probe' - wrong build"; exit 1; }
    done
    log "artifact carries pwskip/pwcap/QGAFOCUSRAISE"
fi

log "=== step 1+2: clean install + CPU vs baseline ==="
./scratchpad/validate-coalesce.sh 2>&1 | tee "$S/chain-validate.log"
rc=${PIPESTATUS[0]}
if [ "$rc" -ne 0 ]; then
    log "validate-coalesce failed (rc=$rc) - not proceeding to the hit rate, which would"
    log "otherwise be measured on a guest whose build was never confirmed"
    exit "$rc"
fi

log "=== step 3: hit rate, FocusRaise off vs on ==="
./scratchpad/hitrate-ab.sh win11-fresh win11 3 2>&1 | tee "$S/chain-hitrate.log"

log "=== chain complete ==="
