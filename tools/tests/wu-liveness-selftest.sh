#!/usr/bin/env bash
# wu-liveness-selftest.sh - offline proof for mgmt/harness/wu-liveness.sh's dead-pass verdict (findings/issues.md P1 "A KILLED
# UPDATE PASS COSTS dom0 TWO SILENT HOURS": the harness must see a dead pass by itself, not through the product's handler).
#
# No rig, no guest: scripted WUPROBE lines on a scripted clock (WU_LIVE_NOW) through the shipped wu_pass_dead.
#   no env              every scenario must come out as stated, AND the defect knob must make the killed-pass scenario FAIL
#                       (a verdict never seen to fail is decoration). Exit 0 only if both hold.
#   WU_LIVE_DEFECT=1    run the scenarios with both verdicts disabled (wu_pass_dead never fires, wu_pass_unfinished never says
#                       "unfinished") and exit with their result - i.e. this test FAILS, by design.
# The probe itself (the PowerShell half) cannot run here - it needs the guest's Task Scheduler - and is validated on the rig:
# every probe line is kept in the run's evidence.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 2

run_scenarios(){ (
  set -u
  # shellcheck source=../../mgmt/harness/wu-liveness.sh
  source mgmt/harness/wu-liveness.sh
  WU_LIVE_HOLD_S=90
  fails=0
  L(){ printf 'WUPROBE|task=%s|last=%s|status=%s|action=%s|phase=%s|ts=%s|relay=none|gt=x' "$1" "$2" "$3" "$4" "$5" "$6"; }
  # feed <expect: dead-at-T | never> <name> then "T line" pairs on stdin. NEVER pipe into it: a pipeline runs feed in a
  # subshell, its fails+=1 is lost with it, and a failing scenario would not fail the test (the first draft did exactly that).
  feed(){ local expect=$1 name=$2 t line got=never
    wu_live_reset
    while read -r t line; do
      if WU_LIVE_NOW=$t wu_pass_dead "$line"; then got=$t; break; fi
    done
    if [ "$got" = "$expect" ]; then echo "ok    $name (dead at $got)"; else echo "FAIL  $name: expected $expect, got $got"; fails=$((fails+1)); fi
  }
  # 1. THE FIELD CASE: Running in scan, then the scheduler ends it - Ready, 0x41306, status frozen at phase scan.
  feed 110 killed <<EOF
0 $(L Running 0x41301 ok full scan 2026-09-17T20:46:24)
20 $(L Ready 0x41306 ok full scan 2026-09-17T20:46:24)
60 $(L Ready 0x41306 ok full scan 2026-09-17T20:46:24)
100 $(L Ready 0x41306 ok full scan 2026-09-17T20:46:24)
110 $(L Ready 0x41306 ok full scan 2026-09-17T20:46:24)
EOF
  # 2. a long, live pass: Running with an unchanged status for an hour is SLOW, not dead
  feed never alive-slow < <(for t in 0 600 1200 1800 2400 3000 3600; do echo "$t $(L Running 0x41301 ok full install 2026-10-02T10:00:00)"; done)
  # 3. a finished pass, and an earlier scan's status, are not dead whatever the task says
  feed never finished < <(for t in 0 100 200 300; do echo "$t $(L Ready 0x0 ok full done 2026-10-02T10:00:00)"; done)
  feed never scan-status < <(for t in 0 100 200 300; do echo "$t $(L Ready 0x0 ok scan scan 2026-10-02T10:00:00)"; done)
  for ph in error scan-failed skipped-debounce; do
    feed never "terminal-$ph" < <(for t in 0 100 200; do echo "$t $(L Ready 0x0 ok full $ph 2026-10-02T10:00:00)"; done)
  done
  # 4. a status that keeps changing is being written - the hold restarts on every new picture
  feed never moving < <(for t in 0 50 100 150 200 250; do echo "$t $(L Ready 0x41306 ok full download 2026-10-02T10:00:$((t/10)))"; done)
  # 5. missing data neither advances nor resets: unreadable probes in between, the same frozen picture at both ends
  feed 200 missing-data <<EOF
0 $(L Ready 0x41306 ok full scan 2026-10-02T10:00:00)
40 $(L UNREADABLE '' ok full scan 2026-10-02T10:00:00)
80 $(L Ready 0x41306 unreadable '' '' '')
120 $(L Ready 0x41306 unparseable '' '' '')
200 $(L Ready 0x41306 ok full scan 2026-10-02T10:00:00)
EOF
  # ...and unreadable probes alone never make a verdict
  feed never unreadable-only < <(for t in 0 100 200 300; do echo "$t $(L UNREADABLE '' unreadable '' '' '')"; done)
  # 6. a pass that never wrote: the task is not running and no status exists
  feed 95 never-wrote < <(for t in 0 30 60 95; do echo "$t $(L Ready 0x1 absent '' '' '')"; done)
  # 7. Queued is on its way, not dead; Disabled with a frozen pass status is dead
  feed never queued < <(for t in 0 100 200; do echo "$t $(L Queued 0x41325 ok full scan 2026-10-02T10:00:00)"; done)
  feed 90 disabled < <(for t in 0 50 90; do echo "$t $(L Disabled 0x41306 ok full scan 2026-10-02T10:00:00)"; done)
  # 8. the hold is a hold: Running in between restarts it
  feed 260 running-resets <<EOF
0 $(L Ready 0x41306 ok full scan 2026-10-02T10:00:00)
80 $(L Running 0x41301 ok full scan 2026-10-02T10:00:00)
170 $(L Ready 0x41306 ok full scan 2026-10-02T10:00:00)
200 $(L Ready 0x41306 ok full scan 2026-10-02T10:00:00)
260 $(L Ready 0x41306 ok full scan 2026-10-02T10:00:00)
EOF
  # 9. A SCAN WRITTEN OVER A DEAD PASS does not hide it (Jev 2026-10-02, the likeliest miss): the hold runs on the pass's own
  #    last picture from the moment it stopped, whatever the scan writes after - and a scan after a FINISHED pass stays harmless
  feed 110 scan-over-dead <<EOF
0 $(L Running 0x41301 ok full scan 2026-10-02T10:00:00)
20 $(L Ready 0x41306 ok full scan 2026-10-02T10:00:00)
60 $(L Ready 0x41306 ok scan scan 2026-10-02T10:01:00)
90 $(L Ready 0x41306 ok scan done 2026-10-02T10:01:30)
110 $(L Ready 0x41306 ok scan done 2026-10-02T10:01:30)
EOF
  feed never scan-after-finished <<EOF
0 $(L Running 0x41301 ok full install 2026-10-02T10:00:00)
20 $(L Ready 0x0 ok full done 2026-10-02T10:05:00)
60 $(L Ready 0x0 ok scan scan 2026-10-02T10:06:00)
200 $(L Ready 0x0 ok scan done 2026-10-02T10:06:30)
EOF
  # 10. the no-hold picture, for the check made after the replay has ended: 0 unfinished, 1 running/finished, 2 unread
  chk(){ local want=$1 name=$2 line=$3 got; wu_pass_unfinished "$line"; got=$?
    if [ "$got" = "$want" ]; then echo "ok    unfinished/$name (rc $got)"; else echo "FAIL  unfinished/$name: expected rc $want, got $got"; fails=$((fails+1)); fi; }
  wu_live_reset
  chk 0 frozen   "$(L Ready 0x41306 ok full download 2026-10-02T10:00:00)"
  chk 1 running  "$(L Running 0x41301 ok full download 2026-10-02T10:00:00)"
  chk 1 finished "$(L Ready 0x0 ok full done 2026-10-02T10:00:00)"
  chk 2 unread   "$(L UNREADABLE '' ok full download 2026-10-02T10:00:00)"
  wu_live_reset
  chk 1 scan-only      "$(L Ready 0x0 ok scan scan 2026-10-02T10:00:00)"
  chk 0 pass-then-scan "$(L Ready 0x41306 ok full scan 2026-10-02T10:00:00)"
  chk 0 scan-over-it   "$(L Ready 0x41306 ok scan done 2026-10-02T10:02:00)"
  # 11. the reason names the code and the phase
  wu_live_reset
  WU_LIVE_NOW=0 wu_pass_dead "$(L Ready 0x41306 ok full scan 2026-09-17T20:46:24)"
  if WU_LIVE_NOW=95 wu_pass_dead "$(L Ready 0x41306 ok full scan 2026-09-17T20:46:24)" \
     && printf '%s' "$WU_LIVE_WHY" | grep -q "last result 0x41306" && printf '%s' "$WU_LIVE_WHY" | grep -q "phase 'scan'"; then
    echo "ok    reason: $WU_LIVE_WHY"
  else echo "FAIL  reason: '${WU_LIVE_WHY:-}'"; fails=$((fails+1)); fi
  echo "scenarios failed: $fails"
  [ "$fails" = 0 ]
) }

if [ -n "${WU_LIVE_DEFECT:-}" ]; then run_scenarios; exit $?; fi
echo "== clean"
run_scenarios; clean=$?
echo "== WU_LIVE_DEFECT=1 (must FAIL on the killed scenario)"
dout=$(WU_LIVE_DEFECT=1 run_scenarios); drc=$?
printf '%s\n' "$dout"
if [ "$clean" = 0 ] && [ "$drc" != 0 ] && printf '%s\n' "$dout" | grep -q '^FAIL  killed:' \
   && printf '%s\n' "$dout" | grep -q '^FAIL  scan-over-dead:' && printf '%s\n' "$dout" | grep -q '^FAIL  unfinished/frozen:'; then
  echo "PASS  clean leg passes, the defect knob fails the killed-pass, scan-over-dead and no-hold scenarios"; exit 0
fi
echo "FAIL  clean=$clean defect_rc=$drc"; exit 1
