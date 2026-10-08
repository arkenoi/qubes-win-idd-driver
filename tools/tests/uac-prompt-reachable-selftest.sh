#!/usr/bin/env bash
# uac-prompt-reachable-selftest.sh - A PROMPT NOBODY CAN REACH IS NOT A PROMPT.
#
# The decisions are docs/ADR-uac.md; this holds the code to them. Owner, 2026-10-08: "if UAC emits
# a dialog, it should be presented as dialog, a normal dialog window, not some hidden bullshit" and
# "we were supposed to fix this months ago, if it regressed we need tests". It had not regressed -
# findings/issues.md has carried "a pending UAC elevation is invisible in seamless; UAC visibility
# is declared future work" as an open P2 since 2026-08-28 (Jev never-closed 1.00) - and there was no
# test for ANY of the UAC handling, which is the gap this file closes.
#
# WHAT IT GUARDS, and why each one is a defect somebody could reintroduce in an afternoon:
#   1. the prompt is REACHED by its own process, not by the taskbar (ADR-uac section 7). The taskbar
#      remedy is `if (g_TaskbarWindow)` and before the shell is up that handle is NULL, so the hide
#      of the stand-in had no remedy at all during startup;
#   2. the stand-in window STAYS hidden (section 6, Jev 0.92): it carries no prompt and often no
#      pixels, so mapping it gives dom0 an empty box. "Fixing" visibility by mapping it is the
#      wrong fix and this refuses it;
#   3. the consent window goes through the ORDINARY gate. Bypassing ShouldAcceptWindow to force a
#      prompt out would also force out a fullscreen dimming backdrop, which IS the field-reported
#      unclosable black window (root-caused 2026-08-27);
#   4. NOTHING IS ACTIVATED OR ANSWERED (section 8). An agent that can answer its own elevation
#      prompts makes the prompt worthless;
#   5. PromptOnSecureDesktop=0 is still asserted on the normal start path (section 1). Everything
#      above assumes the prompt is on the Default desktop at all.
#
# NOT CLAIMED HERE: that the fix works on a guest. It has not been compiled (no Windows SDK on this
# host) and no guest in our possession has ever been observed with a consent window. Jev, asked
# whether calling this FIXED would be sound on today's evidence: 0.03. The live cell - a real
# non-foreground elevation at startup, graded on what dom0 is shown - is owed and named in
# ADR-uac section 7.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="${UACSRC:-$ROOT/agent/gui-agent}"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }
[ -d "$SRC" ] || { echo "FAIL  $SRC missing - nothing ran (missing data fails)"; exit 2; }
M="$SRC/main.c"; N="$SRC/notifytexts.h"
for f in "$M" "$N"; do [ -f "$f" ] || { echo "FAIL  $f missing"; exit 2; }; done

# CODE ONLY. Every comment here deliberately quotes the behaviour being replaced - the convention
# this repo already uses - so a whole-file grep passes on the prose that documents the defect. Three
# checks were written that way before and each one passed the broken code.
code(){ sed -E 's@//.*$@@' "$1"; }
CODE="$(code "$M")"
NCODE="$(code "$N")"

# ---- 1. the prompt is reached by its PROCESS, and the check is armed where the hide happens -----
echo "$CODE" | command grep -q 'ProcessPidByName' \
  && ok "pid_lookup_exists: a process can be located by name, pid and all (the fact alone is not enough)" \
  || bad "pid_lookup_exists: no ProcessPidByName - the consent windows cannot be found"
echo "$CODE" | command grep -q 'ProcessPidByName(L"consent\.exe")' \
  && ok "consent_located: consent.exe's own windows are what we go to" \
  || bad "consent_located: nothing looks up consent.exe"
# DEFINED as well as USED: a call with no definition does not compile, and that mistake was made
# on 2026-10-08 with ProcessRunningByName.
for fn in ProcessPidByName UacPendingPromptEnsureVisible UacConsentScanProc; do
  d=$(echo "$CODE" | command grep -cE "^(static )?(BOOL CALLBACK |void |DWORD |BOOL )?$fn\(")
  u=$(echo "$CODE" | command grep -c "$fn")
  if [ "$d" -ge 1 ] && [ "$u" -ge 2 ]; then ok "defined_and_used: $fn is defined and called"
  else bad "defined_and_used: $fn definitions=$d references=$u - a call without a definition does not compile"; fi
done
# The section-5 classifier must survive: it is a different question (WHICH secure desktop).
echo "$CODE" | command grep -q 'ProcessRunningByName' \
  && ok "classifier_kept: the secure-desktop classification still has its helper (ADR-uac section 5)" \
  || bad "classifier_kept: ProcessRunningByName is gone - section 5's classification went with it"

# ---- 1b. armed from the stand-in, which is the only thing that sets g_ShowTaskbar ---------------
armed=$(python3 - "$M" <<'PYF'
import sys, io, re
s = re.sub(r'(?m)//.*$', '', io.open(sys.argv[1], encoding='utf-8', errors='replace').read())
i = s.find('static ULONG AddAllWindows(')
if i < 0: print('NO-ADDALL'); raise SystemExit
seg = s[i:]
call = seg.find('UacPendingPromptEnsureVisible()')
tb = seg.find('if (g_TaskbarWindow)')
if call < 0: print('NOT-CALLED')
elif tb < 0: print('NO-TASKBAR-BLOCK')
elif call > tb: print('AFTER-TASKBAR-BLOCK')     # the block's `goto end` would skip it
else:
    # it must be gated on the flag the stand-in sets, not run unconditionally
    before = seg[max(0, call-200):call]
    print('GATED-BEFORE' if 'g_ShowTaskbar' in before else 'UNGATED-BEFORE')
PYF
)
case "$armed" in
  GATED-BEFORE) ok "armed_at_the_hide: the check runs on g_ShowTaskbar, before the taskbar block whose goto would skip it" ;;
  AFTER-TASKBAR-BLOCK) bad "armed_at_the_hide: the call sits AFTER the taskbar block - its 'goto end' on an already-tracked taskbar skips it" ;;
  UNGATED-BEFORE) bad "armed_at_the_hide: the check is not gated on g_ShowTaskbar - it would run (and snapshot processes) at rest" ;;
  *) bad "armed_at_the_hide: $armed" ;;
esac

# ---- 2. the stand-in STAYS hidden, and is excluded from the scan --------------------------------
hide=$(python3 - "$M" <<'PYF'
import sys, io, re
s = re.sub(r'(?m)//.*$', '', io.open(sys.argv[1], encoding='utf-8', errors='replace').read())
i = s.find('wcscmp(entry->Class, UAC_DUMMY_WINDOW_CLASS)')
print('NO-HIDE' if i < 0 else ('HIDDEN' if 'entry->IsVisible = FALSE' in s[i:i+400] else 'NOT-HIDDEN'))
PYF
)
[ "$hide" = HIDDEN ] \
  && ok "standin_stays_hidden: the contentless stand-in is not mapped (ADR-uac section 6, Jev 0.92)" \
  || bad "standin_stays_hidden: $hide - mapping the stand-in gives dom0 an empty box, not a prompt"
echo "$CODE" | command grep -q 'wcscmp(cls, UAC_DUMMY_WINDOW_CLASS)' \
  && ok "standin_excluded_from_scan: the scan skips the stand-in instead of counting it as the prompt" \
  || bad "standin_excluded_from_scan: the stand-in would be counted as an announceable prompt"

# ---- 3. the ORDINARY gate decides. Forcing a window out would also force out the black backdrop -
gate=$(python3 - "$M" <<'PYF'
import sys, io, re
s = re.sub(r'(?m)//.*$', '', io.open(sys.argv[1], encoding='utf-8', errors='replace').read())
i = s.find('UacConsentScanProc')
if i < 0: print('NO-SCAN'); raise SystemExit
j = s.find('static void UacPendingPromptEnsureVisible', i)
seg = s[i:j if j > i else i+4000]
a, g = seg.find('AddWindow('), seg.find('ShouldAcceptWindow(')
if a < 0: print('NO-ADD')
elif g < 0: print('GATE-BYPASSED')
elif g > a: print('GATE-AFTER-ADD')
else: print('GATED')
PYF
)
[ "$gate" = GATED ] \
  && ok "ordinary_gate_decides: ShouldAcceptWindow runs before the window is announced" \
  || bad "ordinary_gate_decides: $gate - bypassing the gate would also map the fullscreen dimming backdrop (the field black window)"
# and the entry must not be read after AddWindow takes ownership of it
owned=$(python3 - "$M" <<'PYF'
import sys, io, re
s = re.sub(r'(?m)//.*$', '', io.open(sys.argv[1], encoding='utf-8', errors='replace').read())
i = s.find('UacConsentScanProc')
if i < 0: print('NO-SCAN'); raise SystemExit
j = s.find('static void UacPendingPromptEnsureVisible', i)
seg = s[i:j if j > i else i+4000]
a = seg.find('AddWindow(data)')
print('NO-ADD' if a < 0 else ('READS-FREED' if 'data->' in seg[a:] else 'CLEAN'))
PYF
)
[ "$owned" = CLEAN ] \
  && ok "no_use_after_add: nothing reads the entry after AddWindow takes ownership of it" \
  || bad "no_use_after_add: $owned - AddWindow owns the entry and some paths free it"

# ---- 4. NOTHING IS ACTIVATED OR ANSWERED (ADR-uac section 8) ------------------------------------
act=$(python3 - "$M" <<'PYF'
import sys, io, re
s = re.sub(r'(?m)//.*$', '', io.open(sys.argv[1], encoding='utf-8', errors='replace').read())
i = s.find('UacConsentScanProc')
if i < 0: print('NO-SCAN'); raise SystemExit
j = s.find('static ULONG AddAllWindows(', i)
seg = s[i:j if j > i else i+8000]
banned = [w for w in ('SetForegroundWindow', 'SendInput', 'keybd_event', 'mouse_event',
                      'SW_RESTORE', 'SetActiveWindow', 'BringWindowToTop', 'PostMessage',
                      'SendMessage') if w in seg]
print('CLEAN' if not banned else 'ACTIVATES:' + ','.join(banned))
PYF
)
[ "$act" = CLEAN ] \
  && ok "never_answers: the UAC path activates nothing and sends no input - the user decides" \
  || bad "never_answers: $act - an agent that can answer its own elevation prompt makes the prompt worthless"

# ---- 5. the unreachable case is LOUD, and dom0 is told ------------------------------------------
echo "$CODE" | command grep -q 'LogError("QGAUACPENDING' \
  && ok "unreachable_is_an_error: a prompt dom0 can be shown no window for is an ERROR, not a debug line" \
  || bad "unreachable_is_an_error: nothing reports at ERROR that a prompt is unreachable"
echo "$CODE" | command grep -q 'QerrTextFind("uac-pending")' \
  && ok "dom0_is_told: the unreachable prompt takes the dom0 notification route" \
  || bad "dom0_is_told: only the guest log would know, and nobody reads it in time"
echo "$NCODE" | command grep -q '"uac-pending"' \
  && ok "row_exists: notifytexts.h carries the row the call site asks for" \
  || bad "row_exists: the call site asks for a row that does not exist (QerrReportText logs a NULL)"
# the report must not fire on the first sighting: consent.exe may still be creating its window
g=$(echo "$CODE" | command grep -oE '#define UAC_PENDING_GRACE_MS [0-9]+' | awk '{print $3}')
if [ -n "${g:-}" ] && [ "$g" -ge 2000 ] && [ "$g" -le 30000 ]; then
  ok "grace_is_bounded: a prompt is called unreachable only after ${g} ms, and the bound is small"
else
  bad "grace_is_bounded: UAC_PENDING_GRACE_MS is '${g:-unset}' - either it fires on a prompt still being created, or it is a timeout pretending to be a fix"
fi

# ---- 6. section 1 still holds: the prompt is on the DEFAULT desktop at all ----------------------
echo "$CODE" | command grep -q 'PromptOnSecureDesktop' \
  && ok "policy_still_written: PromptOnSecureDesktop is still asserted by the agent (ADR-uac section 1)" \
  || bad "policy_still_written: the agent no longer moves the prompt off the secure desktop - everything above is moot"
pol=$(python3 - "$M" <<'PYF'
import sys, io, re
s = re.sub(r'(?m)//.*$', '', io.open(sys.argv[1], encoding='utf-8', errors='replace').read())
n = len(re.findall(r'ApplyUacPromptPolicy\(\)\s*;', s))
print('CALLED' if n >= 1 else 'DEFINED-NOT-CALLED')
PYF
)
[ "$pol" = CALLED ] \
  && ok "policy_on_the_start_path: ApplyUacPromptPolicy is actually called, not merely defined" \
  || bad "policy_on_the_start_path: $pol - a policy nothing calls is not a policy"

echo
echo "uac-prompt-reachable-selftest: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
