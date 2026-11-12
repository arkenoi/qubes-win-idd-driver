#!/usr/bin/env bash
# uac-on-test.sh - GWeck's UAC-ON FIXES, GRADED ON HIS GOLDEN WITH UAC TURNED ON.
#
# WHY THIS EXISTS (owner, 2026-11-12): "but when we implemented fixes for gweck, did we check properly? it is just
# we do not have regression tests for that yet" and "make a reasonably minimalistic regression testing part of the
# main suite ... use all the same conventions as other test components follow". The reporter runs Windows 11 25H2
# German with UAC ON. Every guest this rig provisions has UAC OFF (each mgmt/autounattend*.xml sets EnableLUA 0), so
# the 4.3.41 acceptance never met the condition that triggers most of the fixes it shipped for him, and an audit of
# those fixes the same day found no committed check that would go red if one of them were reverted. Their only UAC-on
# measurements were hand-run smokes on neighbouring builds. This is that hand sequence, committed and graded.
#
# THE CHECKS, one JSON row each in $OUT/checks.jsonl (matrix.sh's row schema plus "check"), the run's result in
# $OUT/result.json (matrix-result.json's fields):
#   reporter-env           precondition: env-assert passes on the subject (his environment, not just his image)
#   uac-effective          precondition: EnableLUA=1 AND the session user's token at the default run level reads
#                          Medium, where the same probe read High before the switch - the token is split
#   bridge-first-uac-boot  58c0529b (agent 05bf54a) and 0ab5ecd2 (agent a215ed4): on the first boot with UAC on, the
#                          heartbeat and stop file the UAC-off run left cannot be replaced by the filtered bridge -
#                          the agent must retire them, the bridge must publish its pid and still run 65 s later
#   helper-priority        0ab5ecd2 (agent a9b7034): the Qubes-NotifBridge task runs at priority 4, not 7
#   system-notice-once     140e457b: a SYSTEM notice handed to the session is read AND deleted by the filtered reader,
#                          so it is sent once - the field had 33 of 33 sent twice
#   system-notice-info     7ae96e3b: sent with --severity info, it arrives as [INFO], not as an error
#   elevated-notice        245756e8: a notice from the user's ELEVATED token takes the handoff and is delivered, not
#                          queued for the next bridge start after "relay never connected"
#   bridge-next-uac-boot   0ab5ecd2 (agent a215ed4): the next boot, where the stop file was written with UAC on - the
#                          field lost the bridge on every boot after the first
# NOT COVERED, by choice of scope: a1c83b44's restart notice needs an installer run by hand (elevated-notice is its
# delivery route, not its text); the Catalog, gone-window, capture-helper, ETW-grace and queued-toast fixes do not
# depend on UAC, and the queued toast has toast-hold-test.
#
# A PASS IS ONLY A PASS UNDER THE TRIGGER. Each check that grades a UAC-on fix asserts its trigger on the signal the
# code consults - the token's integrity label, the leftover file - and with the trigger absent it is INVALID, never
# PASS: a pass on a guest where the defect cannot occur says nothing about the fix.
#
# Exit 0 PASS, 1 FAIL (the product), 2 INSTRUMENT (no verdict was produced - never a pass).
set -uo pipefail
# the root from this script's own location, as updater-component-test.sh does
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 2

FAMILY="${FAMILY:-win11de}"              # the golden is <FAMILY>-qwt: GWeck's sealed German 25H2 TemplateVM
REPORTER="${REPORTER:-gweck}"            # mgmt/reporters/<name>.json
GOLDEN="$FAMILY-qwt"
VM="${VM:?set VM to the subject to create - there is no default target}"
PKG="${PKG:?set PKG to the release setup tree or ISO under test}"
LOG="${LOG:-/home/user/qwt-accept/uac-on-$VM.log}"
OUT="${OUT:-${LOG%.log}.d}"
PROBE=mgmt/harness/uac-on-probe.ps1
mkdir -p "$OUT" 2>/dev/null || { echo "FATAL: cannot create $OUT"; exit 2; }
say(){ echo "[$(date -u +%H:%M:%S)] uac-on[$VM]: $*" | tee -a "$LOG"; }

RUN="$(date -u +%Y%m%dT%H%M%SZ)-$$"; T0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ROWS="$OUT/checks.jsonl"; RESULT="$OUT/result.json"
NP=0; NF=0; NI=0; NROWS=0; NLOST=0; FINISHED=0; ABORT=""
: > "$ROWS"   # this run's rows only: a file cannot scope a run, and every row names its run as well

uo_row(){ # <PASS|FAIL|INVALID> <kind> <check> <text> -> one line of checks.jsonl. A row that cannot be written is
  # counted, never raised: an emitter must not be able to fail what it reports on.
  case $1 in PASS) NP=$((NP+1)) ;; FAIL) NF=$((NF+1)) ;; *) NI=$((NI+1)) ;; esac
  NROWS=$((NROWS+1))
  say "$1  [$3] $4"
  python3 -c 'import json,sys,time; a=sys.argv; open(a[1],"a",encoding="utf-8").write(json.dumps({"schema":1,"run":a[2],"attempt":"","seq":int(a[3]),"utc":time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime()),"cell":"uac-on","class":a[4],"kind":a[5],"check":a[6],"text":a[7]})+"\n")' \
    "$ROWS" "$RUN" "$NROWS" "$1" "$2" "$3" "$4" 2>/dev/null || NLOST=$((NLOST+1))
  return 0
}
uo_result(){ # <running|ended> [exit code] -> result.json, whole and atomically; never fails the run
  python3 - "$RESULT" "$1" "${2:-}" "$RUN" "$T0" "$NP" "$NF" "$NI" "$NROWS" "$NLOST" "$FINISHED" "$ABORT" "$VM" "$PKG" <<'PYRES' 2>/dev/null
import json, os, sys, time
a = sys.argv
ended, finished = a[2] == "ended", a[11] == "1"
doc = {"schema": 1, "test": "uac-on", "state": a[2], "exit_code": int(a[3]) if a[3] else None, "run": a[4],
       "started_utc": a[5], "written_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
       "counts": {"PASS": int(a[6]), "FAIL": int(a[7]), "INVALID": int(a[8])},
       "rows_written": int(a[9]) - int(a[10]), "rows_lost": int(a[10]),
       "finished": finished, "abort_line": a[12] or None, "complete": ended and finished and not a[12],
       "subject": a[13], "package": a[14], "rows_file": "checks.jsonl"}
with open(a[1] + ".tmp", "w", encoding="utf-8") as f:
    json.dump(doc, f, indent=1)
    f.write("\n")
os.replace(a[1] + ".tmp", a[1])
PYRES
  return 0
}
uo_get(){ sed -n "s/^$1=//p" "$2" | tail -1; }   # <key> <probe output> -> its last KEY= value, '' when absent
uo_step(){ # <step> <output file> <timeout s> -> the probe's KEY=VALUE lines; 0 only when it printed END=<step>
  QTEST_VM=$VM timeout -k 10 "$3" ./tools/qtest pushrun "$PROBE" -Step "$1" -Tag "$RUN" 2>&1 | tr -d '\r' > "$2"
  grep -qa "^END=$1\$" "$2"
}
uo_boot(){ # <label> -> a proven cold reboot, the user session, a screen, then the boot probe into $OUT/<label>.out
  local lbl=$1 rb wr
  if ! rb=$(g_reboot_proven "$VM" "$lbl" 2>&1); then ABORT="$lbl: the cold reboot was not proven ($rb)"; return 1; fi
  say "  $lbl: rebooted $rb"
  w_usersession "$VM" 600 "$lbl" "$OUT" say; wr=$?
  [ "$wr" = 0 ] || { ABORT="$lbl: no user session (w_usersession rc=$wr: 1 terminal, 2 deadline)"; return 1; }
  say "  $lbl: screen $(w_screen "$VM" "$lbl" "$OUT")"
  uo_step boot "$OUT/$lbl.out" 600 || { ABORT="$lbl: the boot probe did not finish (see $OUT/$lbl.out)"; return 1; }
}
uo_bridge(){ # <check> <boot probe output> <trigger present 1|0> <what the trigger was> -> one row
  local c=$1 f=$2 pre=$3 why=$4 nr rp al rt
  nr=$(uo_get NOTREADY "$f"); rp=$(uo_get READYPID "$f"); al=$(uo_get ALIVE "$f"); rt=$(uo_get RETIRED "$f")
  if [ -z "$nr" ] || [ "$(uo_get AGENTLINES "$f")" = 0 ]; then
    uo_row INVALID check "$c" "no lines from the running gui-agent were read - nothing to grade"
  elif [ "$nr" != 0 ]; then
    uo_row FAIL check "$c" "the agent reported QGANOTIFNOTREADY x$nr: no bridge published its pid (retired at start: ${rt:-none})"
  elif [ -z "$rp" ]; then
    uo_row INVALID check "$c" "the agent logged neither a ready bridge nor QGANOTIFNOTREADY within $(uo_get WAITED "$f") s"
  elif [ "$al" != 1 ]; then
    uo_row FAIL check "$c" "bridge pid $rp was reported ready and did not survive 65 s (retired at start: ${rt:-none})"
  elif [ "$pre" != 1 ]; then
    uo_row INVALID check "$c" "bridge pid $rp ready and alive, but $why - this boot cannot tell a fixed build from a broken one"
  else
    uo_row PASS check "$c" "bridge pid $rp ready and the same process 65 s later; $why"
  fi
}

# ---------------------------------------------------------------------------------------------
# Serial, locked, and over a CLONE of the sealed golden - a golden is never started.
# ---------------------------------------------------------------------------------------------
source mgmt/harness/vmlock.sh
vm_lock "$VM" || exit 2
source mgmt/harness/e2e-wait.sh
trap 'uo_result ended "$?"' EXIT
uo_result running
say "UAC-on component test, package $PKG, over golden $GOLDEN (reporter $REPORTER), run $RUN"

say "step 1/6: quick-upgrade over $GOLDEN"
QU_OUT="$OUT/qu" ./mgmt/harness/quick-upgrade.sh "$PKG" "$VM" "$FAMILY" >"$OUT/upgrade.out" 2>&1; urc=$?
# rc=4 is an install that passed every check with an unclean error sweep: the package IS on the subject
if [ "$urc" != 0 ] && [ "$urc" != 4 ]; then
  ABORT="the package install over $GOLDEN did not pass (quick-upgrade rc=$urc)"
  uo_row INVALID subject-unusable install "$ABORT - nothing below was reached"
  grep -aE '\[ERROR\]|UNACCOUNTED|REFUSED' "$OUT/upgrade.out" | tail -5 | sed 's/^/    /' | tee -a "$LOG"
  exit 2
fi
[ "$urc" = 4 ] && say "  the install passed every check and the error sweep was not clean (rc=4) - the findings are in $OUT/upgrade.out"
say "  install: $(grep -aE 'summary:' "$OUT/upgrade.out" | tail -1)"

say "step 2/6: reporter-env-build then env-assert against reporter $REPORTER"
./mgmt/harness/reporter-env-build.sh "$VM" "$REPORTER" >"$OUT/reporter-env-build.out" 2>&1 \
  || say "  [WARN] reporter-env-build did not complete - see $OUT/reporter-env-build.out"
if ./mgmt/harness/env-assert.sh "$VM" "$REPORTER" >"$OUT/env-assert.out" 2>&1; then
  uo_row PASS precondition reporter-env "env-assert $VM $REPORTER passed"
else
  uo_row INVALID precondition reporter-env "env-assert $VM $REPORTER did not pass (see $OUT/env-assert.out) - the subject is not the reporter's environment"
fi

say "step 3/6: UAC on - EnableLUA=1 while the UAC-off bridge's leftovers are still there"
# The agent writes EnableLUA=0 at boot when service.uac-disable is "1" (docs/QVM-FEATURES.md), which would undo the switch.
f=$(qvm-features "$VM" service.uac-disable 2>/dev/null)
if [ -n "$f" ]; then
  say "  $VM carries service.uac-disable=$f - unsetting it"
  qvm-features --unset "$VM" service.uac-disable >/dev/null 2>&1
fi
EN=$OUT/enable.out
uo_step enable "$EN" 180 || { ABORT="the enable step did not finish (see $EN)"; uo_row INVALID subject-unusable uac-switch "$ABORT"; exit 2; }
HB0=$(uo_get HB "$EN"); LIM0=$(uo_get LIMITED "$EN")
say "  before: EnableLUA=$(uo_get LUA "$EN"), heartbeat=$HB0 (owner $(uo_get HBOWNER "$EN")), stop file=$(uo_get STOPFILE "$EN"), session token at the default run level=$LIM0"
[ "$(uo_get LUASET "$EN")" = 1 ] || { ABORT="EnableLUA could not be set to 1 ($(uo_get LUAERR "$EN"))"; uo_row INVALID subject-unusable uac-switch "$ABORT"; exit 2; }

say "step 4/6: the first boot with UAC on"
uo_boot uac-boot-1 || { uo_row INVALID subject-unusable uac-boot-1 "$ABORT"; exit 2; }
B=$OUT/uac-boot-1.out
LUA1=$(uo_get LUA "$B"); LIM1=$(uo_get LIMITED "$B"); RET1=$(uo_get RETIRED "$B")
if [ "$LUA1" = 1 ] && [ "$LIM1" = medium ] && [ "$LIM0" = high ]; then
  UAC1=1; uo_row PASS precondition uac-effective "EnableLUA=1 and the session user's token at the default run level reads Medium, High before the switch"
else
  UAC1=0; uo_row INVALID precondition uac-effective "UAC is not demonstrably on: EnableLUA=$LUA1, the session token read $LIM0 before the switch and $LIM1 after"
fi
pre=0; why="UAC was not in effect"
if [ "$UAC1" = 1 ]; then
  if [ "$HB0" = 1 ] || [ -n "$RET1" ] || [ "$(uo_get STOPFILE "$B")" = 1 ]; then
    pre=1; why="the UAC-off run left heartbeat=$HB0; the agent retired at start: ${RET1:-none}"
  else
    why="the UAC-off run left neither a heartbeat nor a stop file"
  fi
fi
uo_bridge bridge-first-uac-boot "$B" "$pre" "$why"
pr=$(uo_get PRIO_NOTIFBRIDGE "$B")
case "$pr" in
  4)  uo_row PASS check helper-priority "the Qubes-NotifBridge task runs at Task Scheduler priority 4" ;;
  '') uo_row INVALID check helper-priority "no priority was read for the Qubes-NotifBridge task" ;;
  *)  uo_row FAIL check helper-priority "the Qubes-NotifBridge task runs at priority $pr, not 4 (7 is the schema default)" ;;
esac

say "step 5/6: one notice sent as SYSTEM, one from the session user's elevated token"
S=$OUT/system.out
if ! uo_step system "$S" 240; then
  uo_row INVALID check system-notice-once "the system step did not finish (see $S)"
  uo_row INVALID check system-notice-info "the system step did not finish (see $S)"
else
  sent=$(uo_get SYS_SENT "$S"); never=$(uo_get SYS_NEVER "$S"); delf=$(uo_get SYS_DELFAIL "$S")
  lost=$(uo_get SYS_LOST "$S"); def=$(uo_get SYS_DEFERRED "$S"); src=$(uo_get SYS_RC "$S")
  facts="rc=$src sent=$sent never-read=$never delete-failed=$delf lost=$lost deferred=$def"
  if [ "$UAC1" != 1 ]; then
    uo_row INVALID check system-notice-once "UAC was not in effect: the reader held an unfiltered token ($facts)"
  elif [ "$sent" -gt 1 ] || [ "$never" != 0 ] || [ "$delf" != 0 ]; then
    uo_row FAIL check system-notice-once "sent more than once, or the handoff was not acknowledged: $facts"
  elif [ "$sent" = 1 ] && [ "$src" = 0 ] && [ "$lost" = 0 ] && [ "$def" = 0 ]; then
    uo_row PASS check system-notice-once "handed to the session, read, deleted and sent once: $facts"
  elif [ "$sent" = 0 ] && [ "$src" = 0 ] && [ "$lost" = 0 ] && [ "$def" = 0 ]; then
    uo_row INVALID check system-notice-once "no outcome line for this notice reached the bridge log: $facts"
  else
    uo_row FAIL check system-notice-once "not delivered exactly once: $facts"
  fi
  lvl=$(uo_get SYS_LEVEL "$S")
  if [ "$sent" != 1 ]; then
    uo_row INVALID check system-notice-info "no single delivered line to read the kind from ($facts)"
  elif [ "$lvl" = INFO ]; then
    uo_row PASS check system-notice-info "sent with --severity info, delivered as [INFO]"
  else
    uo_row FAIL check system-notice-info "sent with --severity info, delivered as [$lvl]"
  fi
fi
E=$OUT/elevated.out
if ! uo_step elevated "$E" 300; then
  uo_row INVALID check elevated-notice "the elevated step did not finish (see $E)"
else
  task=$(uo_get ELEV_TASK "$E"); lab=$(uo_get ELEV_LABEL "$E"); erc=$(uo_get ELEV_RC "$E")
  sent=$(uo_get ELEV_SENT "$E"); def=$(uo_get ELEV_DEFERRED "$E"); never=$(uo_get ELEV_NEVER "$E")
  nc=$(uo_get ELEV_NOCONN "$E"); lost=$(uo_get ELEV_LOST "$E")
  facts="rc=$erc sent=$sent deferred=$def relay-never-connected=$nc never-read=$never lost=$lost"
  if [ "$UAC1" != 1 ]; then
    uo_row INVALID check elevated-notice "UAC was not in effect: no token was split ($facts)"
  elif [ "$task" != done ]; then
    uo_row INVALID check elevated-notice "the elevated task did not complete: $task"
  elif [ "$lab" != high ]; then
    uo_row INVALID check elevated-notice "the sender did not hold the elevated token (integrity label $lab)"
  elif [ "$sent" = 1 ] && [ "$erc" = 0 ] && [ "$def" = 0 ] && [ "$never" = 0 ] && [ "$lost" = 0 ]; then
    uo_row PASS check elevated-notice "sent from a High-integrity token, handed to the session and delivered once: $facts"
  elif [ "$sent" = 0 ] && [ "$erc" = 0 ] && [ "$def" = 0 ] && [ "$nc" = 0 ] && [ "$lost" = 0 ]; then
    uo_row INVALID check elevated-notice "no outcome line for this notice reached the bridge log: $facts"
  else
    uo_row FAIL check elevated-notice "not delivered through the handoff: $facts"
  fi
fi

say "step 6/6: the next boot with UAC on, where the field lost the bridge every time"
uo_boot uac-boot-2 || { uo_row INVALID subject-unusable uac-boot-2 "$ABORT"; exit 2; }
C=$OUT/uac-boot-2.out
RET2=$(uo_get RETIRED "$C")
pre=0; why="UAC was not in effect (EnableLUA=$(uo_get LUA "$C"), session token $(uo_get LIMITED "$C"))"
if [ "$(uo_get LUA "$C")" = 1 ] && [ "$(uo_get LIMITED "$C")" = medium ]; then
  case ",$RET2," in
    *,stop,*) pre=1; why="the UAC-on shutdown left a stop file; the agent retired at start: $RET2" ;;
    *) if [ "$(uo_get STOPFILE "$C")" = 1 ]; then pre=1; why="the UAC-on shutdown left a stop file, still there"
       else why="the UAC-on shutdown left no stop file (retired at start: ${RET2:-none})"; fi ;;
  esac
fi
uo_bridge bridge-next-uac-boot "$C" "$pre" "$why"

FINISHED=1
if [ "$NF" -gt 0 ]; then rc=1
elif [ "$NI" -gt 0 ] || [ "$NP" -eq 0 ] || [ "$NLOST" -gt 0 ]; then rc=2
else rc=0; fi
say "rows: $NP PASS, $NF FAIL, $NI INVALID, $NLOST lost - $ROWS"
case $rc in
  0) say "VERDICT: PASS - GWeck's UAC-on fixes hold with UAC on" ;;
  1) say "VERDICT: FAIL - the product" ;;
  *) say "VERDICT: INSTRUMENT - no verdict; the product is not implicated" ;;
esac
say "evidence in $OUT"
exit $rc
