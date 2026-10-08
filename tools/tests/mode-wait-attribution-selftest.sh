#!/usr/bin/env bash
# mode-wait-attribution-selftest.sh - A DEADLINE IS NOT A STATEMENT ABOUT THE FUTURE, AND OUR OWN
# LATE MODE IS NOT SOMEBODY ELSE'S OPEN DEFECT.
#
# MEASURED, win11r-logvol 2026-10-08, one guest, one boot, one clock (the control cycle's own log):
#   10:00:12.141  SetVideoMode: RESREQ 5120x1440 src=lastapplied
#   10:00:12.311  SetVideoModeExact: QIDD ioctl-reload ok
#   10:00:24.509  SetVideoModeExact: RESKEEP 5120x1440-unavailable keeping 0x0 reason=mode-never-appeared   [W]
#   10:00:25.927  RecreateDuplication: A6REGRANT resolution changed during recovery (1920x1080 -> 5120x1440)
#   10:00:25.927  RecreateDuplication: duplication recreated in place ... BUT THE GEOMETRY CHANGED          [E]
# Three defects in four lines, and all three are fixable without knowing why the wait expired:
#   1. the wait declared the mode would NEVER appear, and it was live 1.4 s later;
#   2. it printed "keeping 0x0" - at agent start there is no current mode to keep;
#   3. the geometry change it caused was logged at ERROR with text attributing it to the OPEN P2
#      (win11-24H2 resolution-change capture freeze), sending a maintainer after a capture freeze
#      for an event we caused ourselves. On an IDD guest the host resolution is applied at EVERY
#      agent start (src=lastapplied), so this fired per agent instance.
#
# WHAT IS *NOT* CLAIMED HERE. Why the wait expired is UNRESOLVED - Jev, given the counter-evidence
# (the code's own measurement of a probe that worked in 281 ms, n=1, and a 5120x1440 topology change
# on a cold guest being plausibly slower than a 12 s bound): root_cause insufficient-evidence 0.70,
# chain_established 0.24. Three candidates remain live: a device-less probe asking the primary
# display, a bound shorter than the driver took, and a DEVMODE too under-specified to pass CDS_TEST.
# Jev on the one thing that IS settled: misattribution_is_a_real_harm 0.86.
# So this guards the message and the attribution, and the bound is NOT raised - raising a bound is
# never a fix here.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="${MODEWAIT_SRC:-$ROOT/agent/gui-agent}"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }
[ -d "$SRC" ] || { echo "FAIL  $SRC missing - nothing ran (missing data fails)"; exit 2; }
R="$SRC/resolution.c"; C="$SRC/capture.c"
for f in "$R" "$C"; do [ -f "$f" ] || { echo "FAIL  $f missing"; exit 2; }; done

# ---- 1. the deadline says it is a deadline, and claims nothing about the future ----------------
# CODE ONLY. Both comments explaining the change QUOTE the old reason by name, deliberately - the
# same convention updmutex-contract.ps1 uses - so a whole-file grep failed the fixed code for being
# documented. Third time this shape of mistake today; the lesson is the grep, not the comment.
code_only(){ sed -E 's@//.*$@@' "$1"; }
if code_only "$R" | command grep -q 'mode-never-appeared'; then
  bad "deadline_is_not_a_prophecy: the give-up still EMITS 'mode-never-appeared' - a claim about the future that was measured false"
else
  ok "deadline_is_not_a_prophecy: no emitted line claims the mode will never appear"
fi
command grep -q 'not offered within %u ms (deadline' "$R" \
  && ok "deadline_names_the_exit: it says which exit fired and the bound it used" \
  || bad "deadline_names_the_exit: the wait does not name the deadline exit"

# ---- 1b. THE REAL FIX: A FAILED PRE-FLIGHT MUST NOT VETO THE APPLY ---------------------------
# The deadline branch used to `return ERROR_SUCCESS` BEFORE SetVideoModeInternal, which is the
# actual apply - so a CDS_TEST that said "no" meant the requested mode was never attempted at all.
# Twelve seconds of polling, nothing applied, and on 2026-10-08 the mode went live 1.4 s later, so
# the guest got its resolution by luck. CDS_TEST is a query, not an oracle, and it is a query we may
# be putting to the wrong adapter. Attempting the apply costs one call and either works or returns a
# SPECIFIC status, which the apply-failed path logs. This is the check that this is a FIX and not a
# message change.
flow=$(python3 - "$R" <<'PYF'
import sys, io, re
s = io.open(sys.argv[1], encoding='utf-8', errors='replace').read()
i = s.index('if (!offered)')
j = s.index('ULONG status = SetVideoModeInternal(width, height);', i)
seg = re.sub(r'(?m)^\s*//.*$', '', s[i:j])     # comments quote the old behaviour deliberately
print('RETURNS' if re.search(r'\breturn\b', seg) else 'FALLS-THROUGH')
PYF
)
if [ "$flow" = FALLS-THROUGH ]; then
  ok "preflight_does_not_veto_the_apply: the deadline falls through and the mode is actually attempted"
else
  bad "preflight_does_not_veto_the_apply: the deadline still returns before SetVideoModeInternal - the requested mode is never applied"
fi

# ---- 2. no "keeping 0x0" - there is nothing to keep before a mode is recorded ------------------
if command grep -q 'g_ScreenWidth == 0 || g_ScreenHeight == 0' "$R"; then
  ok "no_phantom_kept_mode: the unset case is reported as such instead of printing 0x0"
else
  bad "no_phantom_kept_mode: it would still print 'keeping 0x0' when no mode is recorded"
fi

# ---- 3. OUR late mode is not attributed to the open P2 ----------------------------------------
command grep -q 'ResolutionWaitExpiredFor(ctx->width, ctx->height' "$C" \
  && ok "own_cause_checked_first: the geometry-changed branch asks whether WE were the ones waiting" \
  || bad "own_cause_checked_first: a mode we gave up on is still reported as the P2's trigger"
command grep -q 'NOT the P2 resolution-change trigger' "$C" \
  && ok "own_cause_says_so: the line states plainly that this change is ours" \
  || bad "own_cause_says_so: nothing distinguishes our own late mode in the log"
# AND THE REAL P2 ERROR MUST SURVIVE. This is the guard against the fix becoming a suppression:
# a genuine resolution change, with no expired wait of ours, must still be an ERROR naming the P2.
command grep -q 'BUT THE GEOMETRY CHANGED' "$C" \
  && ok "real_p2_error_survives: a genuine resolution change is still an ERROR naming the open P2" \
  || bad "real_p2_error_survives: the P2 trigger stopped being reported at all - that is a suppression"
# the credit window must be bounded, or an expiry from minutes ago would excuse a later real change
command grep -q 'EXACT_WAIT_EXPIRY_CREDIT_MS' "$R" \
  && ok "credit_window_bounded: the expiry only excuses a change that follows it closely" \
  || bad "credit_window_bounded: an old expiry could excuse any later geometry change"

# ---- 4. the probe names the device, and still has a fallback ----------------------------------
# "Guest desktop is on DISPLAY2 - name the device explicitly" is a rule this repo already carries,
# and a device-less ChangeDisplaySettings asks the PRIMARY display. Correct regardless of which of
# the three candidate causes is true - which is exactly why it is safe to do without the answer.
command grep -q 'ChangeDisplaySettingsEx(deviceName' "$R" \
  && ok "probe_names_the_device: availability is asked of a named device when one is known" \
  || bad "probe_names_the_device: the probe still asks only the primary display"
command grep -q 'return DISP_CHANGE_SUCCESSFUL == ChangeDisplaySettings(&devMode, CDS_TEST);' "$R" \
  && ok "probe_has_a_fallback: with no device name it falls back rather than answering 'unavailable'" \
  || bad "probe_has_a_fallback: an unknown device name would read as an unavailable mode"

# ---- 5. THE BOUND IS NOT RAISED. Raising a bound is never a fix in this project ---------------
b=$(command grep -oE '#define EXACT_MODE_WAIT_TIMEOUT_MS [0-9]+' "$R" | awk '{print $3}')
[ "${b:-0}" = 12000 ] \
  && ok "bound_unchanged: EXACT_MODE_WAIT_TIMEOUT_MS is still 12000 - the cause is unresolved, so the bound stays" \
  || bad "bound_unchanged: the bound moved to ${b:-?}; a bound is not a fix while the cause is unknown"

echo
echo "mode-wait-attribution-selftest: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
