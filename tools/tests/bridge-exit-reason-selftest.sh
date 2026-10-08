#!/usr/bin/env bash
# bridge-exit-reason-selftest.sh - AN EXIT WE ASKED FOR IS NOT A DEATH, AND SILENCE IS NOT A FIX.
#
# FIELD-REPORTED. GWeck, forum 42717 post 175, on our released 4.3.35, screenshot: six dom0
# notifications on one VM start, FOUR of them "The notification bridge exited unexpectedly ... Cause:
# a clean exit nobody asked for - exit code 0" for notifhost pids 8772, 6796, 10168 and 1232 -
# deaths 1, 2, 4 and 6 of ONE boot. Three ran 0:00:00; the FIRST ran 0:00:20, which the
# already-running case cannot produce.
#
# Exit 0 covered FOUR departures: singleton held, agent gone, session changed, stop requested. The
# first was split out earlier today (QTB_EXIT_ALREADY_RUNNING). This guards the other three.
#
# WHY THEY KEEP EXIT 0, and why this test refuses distinct codes: Task Scheduler restarts a non-zero
# exit (3 times, a minute apart) and leaves zero alone. Giving these their own codes would relaunch a
# bridge somebody deliberately stopped, or push one into a session that is gone - and since
# 2026-10-07 nothing else relaunches it. Jev: noise 0.90, relaunch hazard real 0.90,
# keep-zero-and-record-the-reason 0.92 against distinct-codes 0.00.
#
# AND THE HALF THAT IS EASY TO GET WRONG. Dropping the notification alone WOULD be a silencing if
# nothing else changed: no bridge runs in the new session afterwards (Jev 0.90). A first draft
# therefore armed one launch for the new session - and the owner reverted it the same hour:
# "normally we dont do this at all: our session is single builtin user ... we are NOT doing it now.
# now we make sure session stays." On these guests one built-in user and autologon mean the console
# session is not supposed to change AT ALL, so accommodating a change would hide the anomaly. The
# shipped answer is to REPORT it (QGANOTIFSESSION, WARNING) and relaunch nothing; decoupling
# session-level from system-level is an ADR he will write, not something to improvise here.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NH="${NH_SRC:-$ROOT/tools/notifhost}"
AG="${AG_SRC:-$ROOT/agent/gui-agent}"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }
for f in "$NH/notifhost.cpp" "$NH/qtb_shared.h" "$AG/main.c"; do
  [ -f "$f" ] || { echo "FAIL  $f missing - nothing ran (missing data fails)"; exit 2; }
done
# Comments quote the behaviour being replaced, deliberately - the convention this repo uses - so a
# whole-file grep passes on the prose that documents the defect. Strip them.
code(){ sed -E 's@//.*$@@' "$1"; }
CPP="$(code "$NH/notifhost.cpp")"
HDR="$(code "$NH/qtb_shared.h")"
MAIN="$(code "$AG/main.c")"

# ---- 1. the contract exists, and names all three intended departures --------------------------
echo "$HDR" | command grep -q 'QTB_EXITREASON_FILE' \
  && ok "contract_file: the exit-reason file is part of the shared contract, not a private path" \
  || bad "contract_file: no QTB_EXITREASON_FILE - the two sides cannot agree on where the reason lives"
for r in QTB_REASON_AGENT_GONE QTB_REASON_SESSION_CHANGED QTB_REASON_STOP_REQUESTED; do
  echo "$HDR" | command grep -q "$r" \
    && ok "contract_reason: $r is defined" \
    || bad "contract_reason: $r is missing - that departure has no name to record"
done

# ---- 2. every intended break records its reason ------------------------------------------------
# Each of the three must WRITE before it breaks. Checked per-line so a single call elsewhere cannot
# stand in for three.
miss=0
while IFS= read -r line; do
  case "$line" in
    *'break;'*) ;;
    *) continue ;;
  esac
  case "$line" in
    *'agent gone'*|*'session changed'*|*'stop requested'*)
      case "$line" in *WriteExitReason*) ;; *) miss=$((miss+1)); echo "      unrecorded departure: $(echo "$line" | cut -c1-90)" ;; esac ;;
  esac
done <<EOF
$CPP
EOF
[ "$miss" = 0 ] \
  && ok "every_departure_recorded: each intended break writes its reason before leaving" \
  || bad "every_departure_recorded: $miss intended break(s) leave without recording why - the agent will call them deaths"

# ---- 3. a stale reason may not excuse a later death --------------------------------------------
echo "$CPP" | command grep -q 'DeleteFileW((StateDir() + QTB_EXITREASON_FILE)' \
  && ok "stale_cleared_at_start: the reason is deleted at startup, so an earlier instance cannot excuse this one" \
  || bad "stale_cleared_at_start: a reason left by a previous bridge would be read as this one's"
echo "$CPP" | command grep -q 'GetCurrentProcessId(), reason' \
  && ok "reason_carries_pid: the reason names the process that wrote it" \
  || bad "reason_carries_pid: without a pid the agent cannot tell whose reason it is reading"
echo "$MAIN" | command grep -q 'reasonPid == g_NotifBridgePid' \
  && ok "pid_checked: the agent accepts a reason only from the instance that just exited" \
  || bad "pid_checked: any leftover reason would excuse a real death"
echo "$MAIN" | command grep -q 'DeleteFile(reasonPath)' \
  && ok "reason_consumed: the reason is deleted once used, so it cannot excuse the next exit too" \
  || bad "reason_consumed: one recorded reason would excuse every later exit"

# ---- 4. THE RELAUNCH HAZARD: these exits stay at 0 ---------------------------------------------
# A non-zero code here is restarted by Task Scheduler, which is the whole reason the reason-file
# exists. Refuse any new QTB_EXIT_* constant beyond the one that already shipped.
extra=$(echo "$HDR" | command grep -oE '#define QTB_EXIT_[A-Z_]+' | command grep -v 'QTB_EXIT_ALREADY_RUNNING' | wc -l)
[ "$extra" = 0 ] \
  && ok "no_new_exit_codes: the intended departures keep exit 0, so Task Scheduler does not restart them" \
  || bad "no_new_exit_codes: $extra new exit code(s) - a non-zero exit is restarted, which relaunches a bridge somebody stopped"

# ---- 5. the agent stops reporting them, and ONLY them ------------------------------------------
# The phrase spans two source lines ("...an intended " L"departure, not a death..."), so the
# needle is the half that lives on one line. A multi-line claim needs a multi-line matcher or a
# single-line needle; this check failed its own fixed code once by forgetting that.
echo "$MAIN" | command grep -q 'departure, not a death' \
  && ok "not_a_death: an exit with a matching recorded reason is not reported as a death" \
  || bad "not_a_death: the agent still reports every exit 0 as 'a clean exit nobody asked for'"
echo "$MAIN" | command grep -q 'QGANOTIFBRIDGEEXIT' \
  && ok "real_death_survives: an exit with NO reason is still an ERROR - the fix is not a blanket mute" \
  || bad "real_death_survives: the death report is gone entirely, which is a silencing"

# ---- 6. A SESSION CHANGE IS REPORTED, NOT ACCOMMODATED ----------------------------------------
# Owner, 2026-10-08: "normally we dont do this at all: our session is single builtin user. if we EVER
# want to handle it properly, i'd write an ADR on how to decouple system-level stuff from
# session-level, but we are NOT doing it now. now we make sure session stays." A draft that armed a
# launch for the new session was built and reverted the same hour on that instruction. These checks
# hold the reverted shape: the anomaly is VISIBLE, and nothing works around it.
echo "$MAIN" | command grep -q 'QGANOTIFSESSION' \
  && ok "session_change_is_reported: a console-session change is named at WARNING, not swallowed with the rest" \
  || bad "session_change_is_reported: a session change would be as silent as an ordinary intended exit - the anomaly disappears"
rearm=$(python3 - "$AG/main.c" <<'PYF'
import sys, io, re
s = re.sub(r'(?m)//.*$', '', io.open(sys.argv[1], encoding='utf-8', errors='replace').read())
i = s.find('reasonPid == g_NotifBridgePid')
if i < 0: print('NO-HANDLER'); raise SystemExit
seg = s[i:i+3000]
print('REARMS' if ('g_NotifLaunched = FALSE' in seg or 'g_NotifLaunched=FALSE' in seg) else 'NO-REARM')
PYF
)
[ "$rearm" = NO-REARM ] \
  && ok "nothing_accommodates_it: no launch is armed for a new session - that is the deferred ADR, not today's code" \
  || bad "nothing_accommodates_it: $rearm - this works around a session change the owner said must not happen"
# AND IT IS LOUD. Owner, 2026-10-08: "but if it happens, it needs to happen loud." It was briefly a
# WARNING here, on the reasoning that the window-path fallback makes it workable - but workable is
# not the test. The configuration says the session cannot change; a change means that premise is
# wrong, and a wrong premise is an ERROR and a dom0 notification, not a line in a log nobody opens.
lvl=$(echo "$MAIN" | command grep -o 'Log[A-Za-z]*("QGANOTIFSESSION' | head -1)
[ "$lvl" = 'LogError("QGANOTIFSESSION' ] \
  && ok "session_change_is_loud: reported at ERROR, not downgraded to a warning" \
  || bad "session_change_is_loud: reported as '${lvl:-nothing}' - the owner asked for loud"
echo "$MAIN" | command grep -q 'QerrTextFind("session-changed")' \
  && ok "session_change_reaches_dom0: it takes the dom0 notification route, not just the log" \
  || bad "session_change_reaches_dom0: only the guest log would know, and nobody opens it"
command grep -q '"session-changed"' "$AG/notifytexts.h" \
  && ok "session_change_row_exists: notifytexts.h carries the row the call site asks for" \
  || bad "session_change_row_exists: the call site asks for a row that does not exist"

echo
echo "bridge-exit-reason-selftest: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
