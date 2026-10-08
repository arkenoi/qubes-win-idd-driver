#!/usr/bin/env bash
# log-policy-selftest.sh - ROUTINE PER-WINDOW DETAIL MUST NOT BE AT INFO.
#
# Owner, 2026-10-08: "are you fucking crazy to log every open window when its normal? ok for debug
# but not for regular operation."
#
# The MSI ships LogLevel 3, which is INFO, so every LogInfo is in regular operation. Opening a
# window wrote several of them - the broker slot it was given (QGABROKERREG), that slot being kept
# (QGABROKERKEEP), its slice-fed map (QGASLICEMAP), a deferred map (QGAHELDDEFER) and a caption
# helper - so an ordinary desktop session logged per window per event. They are at DEBUG now.
#
# WHAT THIS CHECKS, and why it is a grep and not a run: a per-window LogInfo is either an ANOMALY
# (which keeps its level - a fallback firing is logged loudly and diagnosed) or it is routine, in
# which case it belongs at DEBUG or behind a trace gate. The protocol stream (QGAPROTO msg=MOTION,
# BUTTON, DAMAGE, CONFIGURE ...) is already gated behind g_ProtoTrace / ProtoDragOn(), which is how
# it should be, and this check confirms that stays true.
#
# NOTHING HERE IS ABOUT ERRORS. LogError and LogWarning are untouched and out of scope: the goal is
# no NOISE in normal operation, never a quieter failure.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="${LOGPOLICY_SRC:-$ROOT/agent/gui-agent}"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }
[ -d "$SRC" ] || { echo "FAIL  $SRC is missing - nothing ran (missing data fails)"; exit 2; }

# THE DISCRIMINATOR, so this list cannot just grow until the check passes: a line may keep INFO if
# it fires once per CONDITION, and must go to DEBUG if it fires once per window OPEN or CLOSE. The
# second kind happens for every window in every session and is what the owner objected to; the first
# kind is an event worth exactly one line.
#
#   broker death / hang / reap / back, BROKERDIMS feed-loss  - a failure or a recovery
#   QGAZERORECT, QGATOASTGAP, ZORDERINVALID                  - something was rejected or repaired
#   QGAHELPERSDISARM/REARM, QGAHELPERTASK, QGACAPSTRIP       - a one-shot state change
#   QGAFSFLASH, QGASTARTDISMISS, QGAUAC, QGADESKSTUCK        - a mode or policy event, not a window
#   QGADIRECTSUPPRESS, QGARAISE, QGAPLACEKEEP                - dom0 and the guest disagreeing
#   QGATOASTHOLD / QGATOASTIDENT / QGATOASTPREEMPT           - per TOAST, a few an hour, and the
#                                                              evidence for the no-double/no-lost
#                                                              notification P1; losing it in the
#                                                              field would cost more than it saves
#   QGADRAGSLICE / QGADRAGFREEZE ev=settle                   - one line per drag, user-initiated
#   QGADDAMOVE                                               - DDA ownership changing hands on a
#                                                              move, which is a transition, not a
#                                                              window appearing
#   popup damage                                             - already once per popup by construction
#   QGADRAGSIM                                               - a simulation facility, off unless asked
#   QGAERRBOX                                                - an error DIALOG was detected
#   QGASLICEBLACK                                            - the black-window case, and already
#                                                              once per window (PwSliceBlackLogged)
#   QGAPWECHO                                                - rate-limited in code (n<=4 || n%256)
#   QGAPROTO                                                 - gated behind g_ProtoTrace anyway
ALLOW='QGABROKERDIED|QGABROKERHUNG|QGABROKERREAP|QGABROKERBACK|BROKERDIMS|QGAZERORECT|QGATOASTGAP|ZORDERINVALID|QGAHELPERSDISARM|QGAHELPERSREARM|QGAHELPERTASK|QGADIRECTSUPPRESS|QGACAPSTRIP|QGAFSFLASH|QGASTARTDISMISS|QGAUAC|QGALOGPOLICY|QGARAISE|QGADESKSTUCK|QGAPROTO|QGATOASTHOLD|QGATOASTIDENT|QGATOASTPREEMPT|QGAPLACEKEEP|QGADRAGSLICE|QGADRAGFREEZE|QGADDAMOVE|popup damage|QGADRAGSIM|QGAERRBOX|QGASLICEBLACK|QGAPWECHO'

python3 - "$SRC" "$ALLOW" <<'PY' > /tmp/logpolicy.$$ 2>&1
import re, sys, pathlib
src, allow = pathlib.Path(sys.argv[1]), re.compile(sys.argv[2])
GATE = re.compile(r'\b(g_ProtoTrace|ProtoDragOn\(\)|g_ProtoTraceWobble|g_ProtoTraceDrag)\b')
WINDOWY = re.compile(r'hwnd[ =]0x%x|hwnd=0x%x|window 0x%x')
offenders = []
for f in sorted(src.glob('*.c')):
    lines = f.read_text(encoding='utf-8', errors='replace').splitlines()
    for i, ln in enumerate(lines):
        if 'LogInfo(' not in ln or not WINDOWY.search(ln):
            continue
        if allow.search(ln):
            continue
        # a gate within the preceding 8 code lines makes it diagnostic, not routine
        window = [x for x in lines[max(0, i - 8):i] if x.strip() and not x.strip().startswith('//')]
        if any(GATE.search(x) for x in window):
            continue
        offenders.append("%s:%d %s" % (f.name, i + 1, ln.strip()[:88]))
print("OFFENDERS %d" % len(offenders))
for o in offenders:
    print("   " + o)
PY
r=$(cat /tmp/logpolicy.$$); rm -f /tmp/logpolicy.$$
n=$(printf '%s' "$r" | head -1 | awk '{print $2}')
if [ "${n:-1}" = 0 ]; then
  ok "no_routine_per_window_info: every per-window LogInfo is a named anomaly or behind a trace gate"
else
  bad "no_routine_per_window_info: $n per-window LogInfo line(s) are routine and at INFO:"
  printf '%s\n' "$r" | tail -n +2
fi

# ---- the five that were demoted must stay demoted ----------------------------------------------
miss=""
# THE DELIMITER IS PART OF THE TOKEN. "QGALEDGER" alone also matches QGALEDGERSUM, which is an
# aggregate logged at most once a minute and rightly stays at INFO - without the delimiter this
# check reported the summary line as a per-window line that had crept back.
for t in 'QGABROKERREG hwnd=' 'QGABROKERKEEP hwnd=' 'QGASLICEMAP hwnd=' 'QGAHELDDEFER hwnd=' \
         'QGADIRECTWAIT hwnd' 'QGAHELDMAP hwnd=' 'QGASLICECONTENT hwnd=' 'QGALEDGER\t'; do
  command grep -qF "LogDebug(\"$t" "$SRC/main.c" || miss="$miss [$t]"
  command grep -qF "LogInfo(\"$t"  "$SRC/main.c" && miss="$miss [$t back at INFO]"
done
command grep -qF 'LogDebug("0x%x: caption %s helper launched' "$SRC/main.c" || miss="$miss [caption helper]"
[ -z "$miss" ] && ok "demoted_stay_demoted: every routine per-window line is at DEBUG" \
               || bad "demoted_stay_demoted:$miss"

# ---- the policy is ANNOUNCED once, so the detail is not just missing ---------------------------
command grep -qF 'QGALOGPOLICY routine per-window detail is at DEBUG' "$SRC/main.c" \
  && ok "policy_announced: one INFO line says where the per-window detail went" \
  || bad "policy_announced: the detail is gone with nothing saying so"

# ---- NO ERROR OR WARNING WAS TOUCHED ----------------------------------------------------------
# The goal is no noise in normal operation, never a quieter failure. This is the guard against
# this very check being used to justify demoting a failure.
# COUNTED AGAINST THE REVISION BEFORE THE DEMOTION, not against a number chosen here. My first
# version of this check used >= 100 / >= 40, which I had invented: the real counts are 52 and 79, so
# it failed the change for code it had not touched. A bar you pick is not a measurement.
base=$(cd "$ROOT/agent" && git log --format=%H -1 --skip=1 -- gui-agent/main.c 2>/dev/null)
for f in main.c send.c toasthold.c vchan-handlers.c; do
  now_e=$(command grep -c 'LogError(' "$SRC/$f" 2>/dev/null || echo 0)
  now_w=$(command grep -c 'LogWarning(' "$SRC/$f" 2>/dev/null || echo 0)
  was_e=$(cd "$ROOT/agent" && git show "$base:gui-agent/$f" 2>/dev/null | command grep -c 'LogError(')
  was_w=$(cd "$ROOT/agent" && git show "$base:gui-agent/$f" 2>/dev/null | command grep -c 'LogWarning(')
  if [ -z "$base" ]; then
    bad "failures_untouched_$f: no earlier revision to compare against (missing data fails)"
  elif [ "$now_e" -ge "$was_e" ] && [ "$now_w" -ge "$was_w" ]; then
    ok "failures_untouched_$f: LogError $was_e->$now_e, LogWarning $was_w->$now_w - none removed"
  else
    bad "failures_untouched_$f: LogError $was_e->$now_e, LogWarning $was_w->$now_w - a failure path was demoted or deleted"
  fi
done

# ---- A RATE IS REPORTED AS A COUNT, NOT AS ONE LINE PER OCCURRENCE ---------------------------
# Owner, 2026-10-08: "how many of those 'duplication recreated' are there? and should we count and
# report on threshold instead of reporting every line?" MEASURED first: 10 in a whole day's agent
# log, 9 benign and 1 geometry-changed, never more than 2 in one agent process.
# The benign in-place recovery from an input-desktop switch is the system working, so it says so
# ONCE at INFO and then goes to DEBUG; what earns a warning is the RATE crossing a stated
# threshold. That preserves exactly the signal the old per-occurrence WARNING existed for - the
# note at that site said Info "would have put it below the level anything watches, so a RISE ...
# would have become invisible" - without the noise. The geometry-changed branch is NOT in scope: it
# is the trigger of an open P2 and stays an ERROR per occurrence.
CAP="$SRC/capture.c"
if [ ! -f "$CAP" ]; then bad "recreate_rate: capture.c is missing"; else
  if command grep -q 'LogWarning("duplication recreated in place' "$CAP"; then
    bad "recreate_rate: the benign recovery is still a WARNING on every occurrence"
  else
    ok "recreate_rate: the benign recovery no longer warns per occurrence"
  fi
  command grep -q 'QGA_DUP_RECREATE_WARN_AT' "$CAP" \
    && ok "recreate_rate_threshold: a named threshold exists rather than a bare number in the branch" \
    || bad "recreate_rate_threshold: no threshold - a rise would be invisible, which is what the old warning was for"
  command grep -q 'LogWarning("QGADDARECREATERATE' "$CAP" \
    && ok "recreate_rate_warns: crossing the threshold still raises a WARNING naming the count" \
    || bad "recreate_rate_warns: nothing warns on a rise - that IS a loss of signal"
  command grep -q 'LogError("duplication recreated in place after %u attempt(s) - windows kept - BUT THE GEOMETRY CHANGED' "$CAP" \
    && ok "geometry_changed_still_error: the open-P2 trigger is untouched and still an ERROR per occurrence" \
    || bad "geometry_changed_still_error: the geometry-changed branch was demoted or renamed"
  # the threshold must be justified in the file, not just present
  # ONE LINE, because the justification is a wrapped comment: my first version grepped for a
  # phrase that straddles two lines and failed the code for having it.
  command grep -q 'never more than 2 in any one agent process' "$CAP" \
    && ok "recreate_rate_justified: the number is tied to a measurement in the comment" \
    || bad "recreate_rate_justified: the threshold has no stated basis"
fi

# ---- THE AGENT NEVER ORIGINATES A GLOBAL KEYSTROKE ------------------------------------------
# Owner, 2026-10-08: "the reproduction is never source of truth ... go do real RCA and real fix".
# The Start dismissal shipped in 4.3.35 used SendInput(VK_ESCAPE), which injects into the SYSTEM
# input queue: the foreground is read BEFORE the call and the key is delivered to whatever holds
# the foreground when it is DEQUEUED, so the guard constrains the check and not the delivery. On
# the very key press that opens Start, the process competing for the foreground is a third-party
# menu - which is the configuration the defect was reported from. Jev on the mechanism alone,
# independent of any field report: race_is_real 0.96. It posts to the Start surface's own queue now.
# InjectInput in vchan-handlers.c is NOT in scope: that is real user input arriving from dom0,
# which is the product's job. What is banned is a keystroke the AGENT originated going out globally.
DSM=$(python3 - "$SRC/main.c" <<'PYD'
import sys, io
s = io.open(sys.argv[1], encoding='utf-8', errors='replace').read()
i = s.index('static void DismissHiddenStartSurface')
d = 0; j = s.index('{', i)
for k in range(j, len(s)):
    if s[k] == '{': d += 1
    elif s[k] == '}':
        d -= 1
        if d == 0: break
body = s[i:k+1]
# COMMENTS STRIPPED. The comment explaining what this replaced names SendInput, and the first
# version of the check grepped the raw body and failed the fixed code for describing the bug.
import re as _re
body = _re.sub(r'/\*.*?\*/', ' ', body, flags=_re.S)
body = _re.sub(r'(?m)^\s*//.*$', '', body)
print(body)
PYD
)
if [ -z "$DSM" ]; then bad "start_dismiss_targeted: DismissHiddenStartSurface could not be isolated"; else
  if printf '%s' "$DSM" | command grep -q 'SendInput'; then
    bad "start_dismiss_targeted: it still injects GLOBALLY - our Escape can close another process's menu"
  else
    ok "start_dismiss_targeted: no global inject in the dismissal"
  fi
  printf '%s' "$DSM" | command grep -q 'PostMessage(start, WM_KEYDOWN, VK_ESCAPE' \
    && ok "start_dismiss_posts_to_the_window: the key goes to the Start surface's own queue" \
    || bad "start_dismiss_posts_to_the_window: the dismissal does not post to that window"
  # AND NO FALLBACK. A fallback to a global inject would reintroduce the whole defect.
  printf '%s' "$DSM" | command grep -qE 'else[^}]*SendInput' \
    && bad "start_dismiss_no_global_fallback: it falls back to a global inject when posting fails" \
    || ok "start_dismiss_no_global_fallback: a failed post is reported, never retried globally"
fi

# ---- ONE SITUATION, ONE NOTIFICATION: the broker-down report yields to QGADESKSTUCK ----------
# FIELD-REPORTED by GWeck on 4.3.35 (forum 42717 post 175, screenshot): his VM start showed BOTH
# "The guest is waiting at the sign-in or lock screen" AND "The notification and menu capture helper
# is not running - wgcbroker.exe is installed but has not been running for over 30 s", in the same
# stack, on the same guest, about the same 30 seconds. While the input desktop is secure nothing can
# be captured - the agent freezes the frame path for exactly that reason - so a broker that is not
# running is the CONSEQUENCE of the sign-in screen, not a second fault. Only one of the two is
# actionable. Jev: i1-i2-helpers-not-running is the item to work first (0.72), and the pair reports a
# real fault (0.66) - the real one being the one QGADESKSTUCK names.
BS=$(python3 - "$SRC/main.c" <<'PYB'
import sys, io, re
s = io.open(sys.argv[1], encoding='utf-8', errors='replace').read()
i = s.index('static void BrokerSupervise(void)')
d = 0; j = s.index('{', i)
for k in range(j, len(s)):
    if s[k] == '{': d += 1
    elif s[k] == '}':
        d -= 1
        if d == 0: break
body = s[i:k+1]
body = re.sub(r'(?m)^\s*//.*$', '', body)      # the comment explains the old behaviour deliberately
print(body)
PYB
)
if [ -z "$BS" ]; then bad "broker_down_yields: BrokerSupervise could not be isolated"; else
  printf '%s' "$BS" | command grep -q 'g_OnSecureDesktop' \
    && ok "broker_down_yields: the broker-down report checks the secure desktop before reporting" \
    || bad "broker_down_yields: it still reports a down broker while the guest is at the sign-in screen"
  # and it must NOT return early - the launch block after it has its own guard and must keep running
  printf '%s' "$BS" | command grep -qE 'g_OnSecureDesktop\)[^}]*\{[^}]*return;' \
    && bad "broker_down_keeps_launching: an early return also skips the broker launch below" \
    || ok "broker_down_keeps_launching: only the report is skipped; the launch path still runs"
  # the down-clock must not be reset, or a genuinely down broker reports a fresh short duration
  printf '%s' "$BS" | command grep -qE 'g_OnSecureDesktop[^}]*g_BrokerDownSince = 0' \
    && bad "broker_down_clock_kept: the down-clock is reset while the desktop is secure" \
    || ok "broker_down_clock_kept: the down-clock keeps running, so the true duration is reported later"
fi

# ---- A SECURE DESKTOP IS CLASSIFIED, NOT JUST REPORTED ---------------------------------------
# Owner, 2026-10-08: "if it sits on the uac prompt we need to know what path brought us there and
# how to handle it properly." The desktop NAME is "Winlogon" for the sign-in screen, the lock screen
# AND a UAC prompt alike, so the name alone cannot say which - and the right answer differs:
#   sign-in screen  -> arm autologon (what the existing advice says)
#   lock screen     -> a user locked it
#   consent.exe up  -> A UAC PROMPT IS ON THE SECURE DESKTOP, which this agent prevents by writing
#                      PromptOnSecureDesktop=0. Being here with consent.exe up means that value was
#                      NOT honoured - OUR defect - and telling the user to "arm autologon" would be
#                      wrong advice for it.
command grep -q 'QGAUACSECURE' "$SRC/main.c" \
  && ok "secure_desktop_uac_is_its_own_error: a UAC prompt on the secure desktop is reported as our defect" \
  || bad "secure_desktop_uac_is_its_own_error: a UAC prompt here is reported as a sign-in screen"
command grep -q 'PATH: %s' "$SRC/main.c" \
  && ok "secure_desktop_names_the_path: QGADESKSTUCK says WHICH secure desktop it is stuck on" \
  || bad "secure_desktop_names_the_path: only the desktop name is logged, which cannot distinguish them"
# the classifier must be implemented, not invented: a call with no definition does not compile, and
# the first version of this change had exactly that.
defs=$(command grep -c 'static BOOL ProcessRunningByName' "$SRC/main.c")
uses=$(command grep -c 'ProcessRunningByName(L' "$SRC/main.c")
if [ "${defs:-0}" -ge 1 ] && [ "${uses:-0}" -ge 1 ]; then
  ok "secure_desktop_classifier_defined: ProcessRunningByName is defined ($defs) and used ($uses)"
else
  bad "secure_desktop_classifier_defined: defined=$defs used=$uses - an undefined call does not compile"
fi
# and the value it read is printed, so a reader never has to guess which case it was
command grep -q 'PromptOnSecureDesktop=%s' "$SRC/main.c" \
  && ok "secure_desktop_prints_the_policy: the PromptOnSecureDesktop value in force is reported" \
  || bad "secure_desktop_prints_the_policy: the policy value is not reported"

# ---- the harnesses that grade on the demoted lines must say they need the level ---------------
for h in toast-hold-test.sh crop-before-map.sh; do
  f="$ROOT/mgmt/harness/$h"
  if [ ! -f "$f" ]; then bad "dependent_declares_$h: missing"; continue; fi
  if command grep -q 'NEEDS LogLevel' "$f"; then
    ok "dependent_declares_$h: it states that it needs LogLevel >= 4, so a run at 3 is not read as clean"
  else
    bad "dependent_declares_$h: it grades on a DEBUG line without saying it needs the level raised"
  fi
done

echo
echo "log-policy-selftest: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
