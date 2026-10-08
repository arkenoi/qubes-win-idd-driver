#!/usr/bin/env bash
# broker-down-anchor-selftest.sh - "NOT RUNNING FOR 30 s" MUST MEASURE A WINDOW IN WHICH IT COULD
# HAVE BEEN RUNNING.
#
# MEASURED 2026-10-08 on a clone matching the reporter's environment (env-assert OK on every asserted
# fact), one cold boot, all four lines from the agent's own log in the same boot delta:
#     18:04:24  Init: WGCBROKER gate enabled
#     18:04:51  WgcLaunch: launched via Task Scheduler (user session 1)   <- 27 s after Init
#     18:04:55  QGADESLICEDOWN "not running for 30 s"                     <- the complaint
#     18:04:56  BrokerSupervise: WGCBROKER ready (pid 3248 validated)     <- ready 1 s later
# The broker was healthy. The launch is gated on GetShellWindow() because the broker runs in the
# user's session; the shell took 27 s to appear, so the 30 s deadline - started at Init - left it
# about three seconds. A dom0 ACTION notification went out about a helper that was fine, which is
# precisely the user-facing error noise this project is trying to remove. The same delta carries the
# contrast: an instance whose session already existed launched 1 s after Init and was ready at +2 s,
# and said nothing.
#
# This is ALSO one of the four notifications the reporter photographed, so the shadow-of-the-sign-in
# fix made earlier the same day was necessary but not sufficient: the other producer is this timing.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
M="${AG_SRC:-$ROOT/agent/gui-agent}/main.c"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }
[ -f "$M" ] || { echo "FAIL  $M missing - nothing ran (missing data fails)"; exit 2; }
code(){ sed -E 's@//.*$@@' "$1"; }
CODE="$(code "$M")"

# ---- 1. the clock does not run while the launch is impossible ----------------------------------
echo "$CODE" | command grep -q 'GetShellWindow() && !g_WgcLaunched' \
  && ok "held_without_a_shell: the down-clock is held while no shell exists, because the broker runs in the user's session" \
  || bad "held_without_a_shell: the deadline still runs before the broker can be launched at all"

# ---- 2. and once it CAN be launched, the deadline measures from the launch ----------------------
echo "$CODE" | command grep -q 'g_WgcLaunched && g_WgcLastLaunch) ? g_WgcLastLaunch : now' \
  && ok "anchored_at_launch: the 30 s is measured from the launch, which is what the message claims" \
  || bad "anchored_at_launch: the deadline is still anchored on the first supervision pass"

# ---- 3. THE ANCHOR MUST NOT SLIDE, or the report could never fire ------------------------------
# BrokerState's own comment records that an older version measured from g_WgcLastLaunch while
# BrokerSupervise refreshed it every ~8 s, so the state could never expire. Anchoring here is only
# safe while that value is assigned exactly once, under the one-launch-per-life guard.
# EXCLUDE THE DECLARATION. `static ULONGLONG g_WgcLastLaunch = 0;` also matches "g_WgcLastLaunch = ",
# which made this count 2 and the next check land on the declaration instead of the assignment - the
# test failed its own correct code twice before this line was right.
n=$(echo "$CODE" | command grep -v 'static .*g_WgcLastLaunch' | command grep -c 'g_WgcLastLaunch = ')
[ "$n" = 1 ] \
  && ok "anchor_does_not_slide: g_WgcLastLaunch is assigned exactly once (one launch per agent life)" \
  || bad "anchor_does_not_slide: g_WgcLastLaunch is assigned $n times - a sliding anchor means this report can never fire"
guarded=$(python3 - "$M" <<'PYF'
import sys, io, re
s = re.sub(r'(?m)//.*$', '', io.open(sys.argv[1], encoding='utf-8', errors='replace').read())
m = [x for x in re.finditer(r'g_WgcLastLaunch\s*=\s*', s) if 'static' not in s[max(0,x.start()-60):x.start()]]
if not m: print('ABSENT'); raise SystemExit
i = m[0].start()
print('GUARDED' if 'if (!g_WgcLaunched' in s[max(0, i-400):i] else 'UNGUARDED')
PYF
)
[ "$guarded" = GUARDED ] \
  && ok "anchor_is_the_one_launch: it is set inside the one-launch guard, not on every retry" \
  || bad "anchor_is_the_one_launch: $guarded"

# ---- 4. A BROKER THAT NEVER COMES UP IS STILL REPORTED -----------------------------------------
# The fix must not become a mute: once launched, a broker that never becomes ready must still be
# reported, with its true duration.
echo "$CODE" | command grep -q 'QGADESLICEDOWN de-slice broker EXPECTED but not running' \
  && ok "real_failure_survives: a broker that never becomes ready is still reported" \
  || bad "real_failure_survives: the report is gone entirely, which is a silencing"
echo "$CODE" | command grep -q 'QerrTextFind(binPresent ? "deslice-down-present" : "deslice-down-missing")' \
  && ok "dom0_still_told: the dom0 notification route is intact for a genuine outage" \
  || bad "dom0_still_told: dom0 would no longer hear about a genuinely dead broker"

# ---- 5. AND THE SIGN-IN SHADOW FIX IS NOT UNDONE ------------------------------------------------
echo "$CODE" | command grep -q 'QGADESLICEDOWN not reported' \
  && ok "shadow_fix_intact: it still yields to QGADESKSTUCK while the input desktop is secure" \
  || bad "shadow_fix_intact: the secure-desktop yield was lost - the double notification returns"

echo
echo "broker-down-anchor-selftest: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
