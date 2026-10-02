#!/bin/bash
# wu-e2e.sh - drive REPEATED full Windows Update passes on a guest and judge every one.
#
#   mgmt/harness/wu-e2e.sh <vm> [rounds] [outdir]
#
# WHY THIS EXISTS. The register's bar for the GWeck update path is explicit: DONE requires either
# repeated full passes on the German 25H2 template that complete without a stall, or the stall
# found and fixed. Every previous run of that kind was ad-hoc - driven by hand, judged by reading
# logs - which is exactly why "tested end to end" kept not sticking. This is the repeatable form.
#
# HOW A PASS IS DRIVEN: tools/replay-dom0-update.py, which replays dom0's OWN qubes-vm-update
# command sequence over the same qrexec services dom0 uses (qubes.VMExec for commands,
# qubes.VMShell for the agent tarball) - i.e. the Qube Manager path, not a shortcut that calls the
# updater directly. dom0's contract: exit 0 = success, 100 = no updates, anything else = error.
#
# WHAT IS JUDGED, per round, by code and by Jev rather than by eye:
#   * dom0's updates-available BEFORE and AFTER, so a pass that leaves dom0 stale is caught. This
#     is the field failure the whole line exists for: the guest throws, never reports, and dom0
#     keeps the previous number while Qube Manager shows the qube as up to date.
#   * the guest's own wu\agent.log, through tools/wu-pass-judge.py --dom0-reported <after>, which
#     FAILS on a SILENT pass (errored and never reported) and on a guest/dom0 disagreement.
#   * update-status.json, kept as evidence for each round.
#
# STALL DETECTION IS PART OF THE TEST, not a nuisance: the open P1 wedge (two vCPUs spinning on a
# held lock while two idle) presents as Running + qrexec dead + no windows, and it can kill a pass.
# A round that ends that way is recorded as STALLED and the run stops - a stalled guest must be
# interrogated, never silently restarted (see findings/issues.md).
#
# PASS LIVENESS IS PART OF THE TEST TOO: a pass that dies (its task no longer Running, its status frozen unfinished) is
# recorded as DEAD by the harness's own probe (mgmt/harness/wu-liveness.sh), never waited out - see the round loop.
#
# Exit 0 every round PASSED, 3 a round FAILED, STALLED or DEAD, 2 instrument error.
set -u

VM="${1:?usage: $0 <vm> [rounds] [outdir]}"
ROUNDS="${2:-3}"

# SERIAL, ALWAYS. This drives a guest for hours across reboots; a second job on the same guest
# would interleave its probes with these rounds and fabricate a verdict. Taking the lock is not
# optional here - tools/lint-harness.py refuses a harness that touches a guest without it, which
# is how this omission was caught before the first run rather than after a ruined campaign.
source mgmt/harness/vmlock.sh
vm_lock "$VM"
source mgmt/harness/wu-liveness.sh

OUT="${3:-scratchpad/wu-e2e-$VM-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"
export QTEST_VM="$VM"
: "${QTEST_INCOMING:=C:\\Users\\gerd-test\\Documents\\QubesIncoming\\win-idd-mgmt}"
export QTEST_INCOMING

log(){ echo "$(date -u +%H:%M:%S) wu-e2e[$VM]: $*" | tee -a "$OUT/run.log"; }
# RETRY, and never let a failed CALL look like a STATE. `qvm-ls` can fail transiently (qubesd
# busy, a call racing a domain transition) and then this returned the empty string, which every
# caller reads as "not Halted" or "not Running" - so a shutdown loop, a reboot ledger and a stall
# test all take their verdict from a call that never answered. Jev flagged it no-retry 0.67-0.69
# with load_bearing 0.60-0.66 (tools/probe-review.py, 2026-09-21). Three attempts; if the toolstack
# still will not answer, say UNKNOWN out loud rather than returning something that reads as a state.
# TWO AGREEING READS, not one: re-judged after the first fix, Jev called a single successful
# sample single-sample 0.55 with load_bearing 0.68 - a state read that races a domain
# transition can return a value that was true for an instant and is not the state.
qstate(){ local i a b
  for i in 1 2 3; do
    a=$(timeout 30 qvm-ls --raw-data --fields state "$VM" 2>/dev/null | tr -d ' \r\n')
    b=$(timeout 30 qvm-ls --raw-data --fields state "$VM" 2>/dev/null | tr -d ' \r\n')
    [ -n "$a" ] && [ "$a" = "$b" ] && { printf '%s' "$a"; return 0; }
    sleep 3
  done
  printf 'UNKNOWN'; return 1; }
# THE NUMBER EVERY VERDICT RESTS ON. dom0's updates-available marker is what the whole bar is
# about, and an EMPTY answer here is indistinguishable from the marker legitimately being empty -
# which is the "up to date" verdict. A transient qvm-features failure would therefore manufacture a
# clean result, or a fake oscillation. Jev: no-retry 0.88, load_bearing 0.65, the worst of the ten
# probes reviewed. So: read it three times and require two reads to AGREE before believing either.
dom0_avail(){ local i a b
  for i in 1 2 3; do
    a=$(timeout 30 qvm-features "$VM" updates-available 2>/dev/null | tr -d ' \r\n')
    b=$(timeout 30 qvm-features "$VM" updates-available 2>/dev/null | tr -d ' \r\n')
    [ "$a" = "$b" ] && { printf '%s' "$a"; return 0; }
    sleep 2
  done
  log "WARNING: dom0's updates-available never read the same twice - reporting the last value '$a'"
  printf '%s' "$a"; }

guest_file(){  # $1 = windows path -> stdout, without the cmd banner
  # RETRY ON EMPTY. `type` fails outright when the guest holds the file open, and the updater
  # rewrites its status file constantly while a pass runs. Measured 2026-09-21 on win11de-ctlb: the
  # round-1 capture came back 0 BYTES, which made reboot_needed read 'unknown' and left the
  # oscillation check waiting the full 15 minutes for a scan it could not see - a whole run spent
  # failing on the harness's own inability to collect its evidence. An empty read is MISSING DATA,
  # and missing data gets retried before it is believed.
  local i out
  for i in 1 2 3 4 5 6; do
    out=$(timeout -k 5 180 tools/qtest run "cmd /c type \"$1\"" 2>/dev/null | tr -d '\r' \
      | sed -e '/^Microsoft Windows \[/d' -e '/^(c) Microsoft/d' -e '/^$/d' -e '/^C:\\Windows\\System32>/d')
    if [ -n "$out" ]; then printf '%s\n' "$out"; return 0; fi
    sleep 5
  done
  return 1
}

# STABLY up, not just up. A single successful probe proves the agent answered ONCE. Measured
# 2026-09-21 on win11de-ctld: 60 s after a reboot that applied a cumulative, one probe succeeded -
# so the reboot counted and the next pass was driven - and that pass then got rc=46 on nearly every
# step, because the agent was still coming and going while Windows finished its boot-time
# servicing. The harness refused to call it a result, correctly, but it should never have driven a
# pass into a booting guest. Three consecutive answers, and any failure resets the count.
wait_qrexec(){ local d=$(( $(date +%s) + ${1:-900} )) ok=0
  while [ "$(date +%s)" -lt "$d" ]; do
    o=$(timeout -k 5 45 tools/qtest run "cmd /c echo UP" 2>/dev/null | tr -d '\r\n')
    case "$o" in
      *UP*) ok=$((ok+1)); [ "$ok" -ge 3 ] && return 0; sleep 15; continue;;
      *)    [ "$ok" -gt 0 ] && log "qrexec answered $ok time(s) then stopped - the guest is not settled yet"; ok=0;;
    esac
    [ "$(qstate)" = Halted ] && return 1
    sleep 15
  done; return 2; }

# A guest that is Running but answers nothing is the P1 stall signature, not a slow guest.
stalled(){ [ "$(qstate)" != Halted ] && ! wait_qrexec 120; }

[ -x tools/wu-pass-judge.py ] || { echo "INSTRUMENT: tools/wu-pass-judge.py missing"; exit 2; }
[ -f tools/replay-dom0-update.py ] || { echo "INSTRUMENT: tools/replay-dom0-update.py missing"; exit 2; }

# PREFLIGHT: the updates proxy. A netvm-less guest reaches Windows Update ONLY through
# qubes.UpdatesProxy, which on this rig is a symlink to 127.0.0.1:8082 in THIS qube. Found dead on
# 2026-09-20, down since this qube's session died two days earlier, with the symlink and config
# still in place - so every pass would have failed on network and the failures would have read as
# guest defects. Nothing restarts it, so check it here and PROVE egress rather than assume it.
if ! ss -ltn 2>/dev/null | grep -q ':8082'; then
  log "updates proxy is DOWN - starting tinyproxy"
  rm -f /home/user/updates-tinyproxy.pid
  tinyproxy -c /home/user/updates-tinyproxy.conf >/dev/null 2>&1
  sleep 2
fi
ss -ltn 2>/dev/null | grep -q ':8082' || { echo "INSTRUMENT: no updates proxy on 127.0.0.1:8082 and it would not start"; exit 2; }
# RETRY: the FIRST request through this proxy after it has been idle regularly hangs the whole
# timeout and returns nothing, while the next one answers instantly. Measured 2026-09-21: probe 1
# empty after 40 s, probes 2 and 3 http=200 in under a second - and the single-shot version of this
# check aborted two runs in a row on a rig whose egress was fine. An empty result is NO ANSWER, not
# proof of no egress; only a real non-200, or three no-answers, is a reason to refuse.
pcode=''
for _pt in 1 2 3; do
  pcode=$(timeout 40 curl -sS -o /dev/null -w '%{http_code}' -x http://127.0.0.1:8082 \
          http://download.windowsupdate.com/ 2>/dev/null)
  [ "$pcode" = 200 ] && break
  [ "$_pt" -lt 3 ] && sleep 3
done
[ "$pcode" = 200 ] || { echo "INSTRUMENT: updates proxy is listening but does not reach Windows Update after 3 attempts (last http=$pcode) - a run now would blame the guest for a network failure"; exit 2; }
log "updates proxy OK (egress proven, http=$pcode)"

fails=0
# REBOOT ACCOUNTING (owner, 2026-09-20: "there should be no forced reboots in 'hope to settle'.
# amount of reboots performed must match amount of reboots requested").
# A harness that reboots speculatively is unfalsifiable - reboot often enough and something
# settles - and every state that needed an unrequested reboot is a defect it just hid. So every
# power cycle here must trace to a REQUEST: either the guest powered itself off (an /auto stage
# transition, which IS the guest asking), or update-status.json said reboot_needed=true. The two
# counters are compared at the end and a mismatch FAILS the run.
reboots_requested=0
reboots_performed=0
note_request(){ reboots_requested=$((reboots_requested+1)); log "REBOOT REQUESTED (#$reboots_requested): $*"; }
note_performed(){ reboots_performed=$((reboots_performed+1)); log "reboot performed (#$reboots_performed)"; }

for r in $(seq 1 "$ROUNDS"); do
  RD="$OUT/round$r"; mkdir -p "$RD"
  # Rounds are independent passes, not a burst. Fired back to back they hammer qrexec - measured
  # 2026-09-20, round 3 started 5 s after round 2 and EVERY replay step came back rc=46, i.e. no
  # pass ran at all. This is a settle between independent passes, not a timeout standing in for a
  # fix: nothing in the field runs two update passes five seconds apart.
  if [ "$r" -gt 1 ]; then log "settling ${SETTLE:-60}s before round $r"; sleep "${SETTLE:-60}"; fi
  before=$(dom0_avail); log "round $r: dom0 updates-available BEFORE='${before:-<empty>}'"

  if ! wait_qrexec 900; then
    if stalled; then log "round $r: STALLED (Running, qrexec dead) - stopping, the guest must be interrogated"; fails=1; break; fi
    # The guest powered ITSELF off - that is the guest requesting the cycle, not us forcing one.
    note_request "the guest powered itself off before round $r"
    log "round $r: guest is Halted - starting it"
    timeout 240 qvm-start "$VM" >/dev/null 2>&1
    note_performed
    wait_qrexec 900 || { log "round $r: guest never came up"; fails=1; break; }
  fi

  # agent.log is CUMULATIVE - it carries every pass this image has ever run, including the
  # golden's history. Judging the whole file each round re-judges the past and lets an old pass
  # decide this round's verdict. Snapshot it BEFORE, and judge only what this round appended.
  guest_file 'C:\ProgramData\Qubes\wu\agent.log' > "$RD/agent-before.log"

  log "round $r: driving a pass the Qube Manager way (replay-dom0-update.py --with-entrypoint)"
  # A FIRST PASS ON AN UN-UPDATED TEMPLATE IS NOT AN HOUR'S WORK. Measured 2026-09-21 on
  # win11de-ctld: this returned rc=124 - killed, not finished - while the guest was still
  # installing a 4.4 GB cumulative it had already downloaded. The guest-side task survives the
  # kill, so the harness then graded a pass that was still running and ran its oscillation scan
  # against a busy guest, where the updater's mutex makes a scan exit at once. Default raised,
  # and overridable per run.
  #
  # PASS LIVENESS, independent of the product (mgmt/harness/wu-liveness.sh). Measured 2026-09-17: a pass the Task Scheduler
  # ended 90 s in left this wait tailing a corpse for its full bound, because nothing here looked at the pass itself. The
  # product's handler now reports a dead pass on its own, but the harness must not need the product's detector to see the
  # product fail - so while the replay runs, the guest's update task and status file are probed, and a pass that is not Running
  # while its status has stood still, unfinished, for WU_LIVE_HOLD_S ends the round as DEAD. The guest is left exactly as it
  # is, to be interrogated, like a stall.
  timeout -k 20 "${WU_REPLAY_TIMEOUT:-10800}" python3 -u tools/replay-dom0-update.py "$VM" --with-entrypoint \
      > "$RD/replay.out" 2>&1 &
  rpid=$!
  # A probe that gets NO answer is missing data, never a verdict - but three in a row while the replay still runs is how the P1
  # stall looks from here (Running, qrexec dead), and the replay's own step bound would sit it out for an hour. So the stall test
  # runs then, and a stalled guest ends the round at once - a stall is examined WHILE it is live, before anything kills it.
  wu_live_reset; dead=""; noans=0; stall=0
  while kill -0 "$rpid" 2>/dev/null; do
    sleep 30
    kill -0 "$rpid" 2>/dev/null || break
    grep -q '\[entrypoint\] running' "$RD/replay.out" || continue   # not before the pass exists
    pl=$(wu_probe)
    printf '%s %s\n' "$(date -u +%H:%M:%S)" "${pl:-<no answer>}" >> "$RD/liveness.txt"
    if [ -z "$pl" ]; then
      noans=$((noans+1))
      if [ "$noans" -ge 3 ] && stalled; then stall=1; break; fi
      continue
    fi
    noans=0
    if wu_pass_dead "$pl"; then dead=$WU_LIVE_WHY; break; fi
  done
  if [ "$stall" = 1 ]; then
    log "round $r: STALLED during the pass (Running, qrexec dead) - the host replay is stopped; INTERROGATE the guest now (tools/qtest wedge), never restart it"
    wu_killtree "$rpid"; wait "$rpid" 2>/dev/null
    fails=1; break
  fi
  if [ -n "$dead" ]; then
    log "round $r: PASS DEAD (harness liveness, not the product's own report): $dead"
    wu_killtree "$rpid"; wait "$rpid" 2>/dev/null
    log "round $r: the host replay was stopped; the guest is left as it is - interrogate it, never restart it blind"
    fails=1; break
  fi
  wait "$rpid"; rc=$?
  # ...and a pass the PRODUCT reported dead is just as dead. The handler's own verdict (guest/wu-update.ps1 GUARD:deadpass) ends
  # the replay with rc=1 - which the replay counts as an expected protocol outcome ("a KB failed") - long before the probe's hold
  # can elapse, so without this the round went on to judge and scan a guest whose pass had died (Jev review 2026-10-02: a likely
  # miss, 0.68).
  if grep -q 'update pass DIED' "$RD/replay.out"; then
    log "round $r: PASS DEAD (the product's own report): $(grep -m1 'update pass DIED' "$RD/replay.out" | sed 's/^ *err: //')"
    grep -m1 'leftovers:' "$RD/replay.out" | sed 's/^ *err: /    /' | tee -a "$OUT/run.log"
    log "round $r: the guest is left as it is - interrogate it, never restart it blind"
    fails=1; break
  fi
  # A REFUSAL IS THE PRODUCT'S OWN REPORT TOO (2026-10-02, the owner's D3 decision). The updater refused to start - dom0 printed
  # "update refused by the qube: ..." - before it owned anything, typically over a pass cut off in this boot (QWTUPDSTATEUNKNOWN), and
  # requested a restart on that cut-off record. The record stays non-terminal ON PURPOSE, so the post-replay picture below would call
  # the round DEAD - measured on rz34: the round was cut short there, the requested restart never performed, the next round never run.
  # A refused round is not a pass (fails=1); it is judged REFUSED - no pass judge and no oscillation scan, no pass ran - and the
  # restart it requested is honoured below, so the next round tests what comes after it.
  refused=''
  if grep -q 'update refused by the qube:' "$RD/replay.out"; then
    refused=$(grep -m1 'update refused by the qube:' "$RD/replay.out" | sed 's/^ *err: //')
    log "round $r: REFUSED by the qube (the product's own report): $(printf '%s' "$refused" | cut -c1-300)"
    fails=1
  fi
  # ...and a pass can also die with NO report: the replay ends (its own step bound, a handler that crashed) while the pass's last
  # picture is unfinished and its task no longer runs (Jev 2026-10-02, the second likeliest miss, 0.27). Nothing waits on the
  # pass once the replay has ended, so the picture is judged now, with no hold. A guest that does not answer is not judged here
  # (a pass that committed its reboot is legitimately going down).
  pl=$(wu_probe); printf '%s %s (after the replay)\n' "$(date -u +%H:%M:%S)" "${pl:-<no answer>}" >> "$RD/liveness.txt"
  if [ -z "$refused" ] && wu_pass_unfinished "$pl"; then
    log "round $r: PASS DEAD (found after the replay ended, with no report from the product): task/status $WU_LIVE_PIC"
    log "round $r: the guest is left as it is - interrogate it, never restart it blind"
    fails=1; break
  fi
  # replay-dom0-update.py reports each STEP's rc in its output but exits 0 regardless, so its
  # exit code is not a verdict. Measured 2026-09-20: every step returned rc=46 and the driver
  # still logged "replay rc=0" and judged a round in which no pass had run at all.
  if grep -q -- '<-- UNEXPECTED' "$RD/replay.out"; then
    log "round $r: INSTRUMENT - the dom0 replay's own steps failed, so NO pass ran; not a result"
    grep -- '<-- UNEXPECTED' "$RD/replay.out" | sed 's/^/    /' | head -6 | tee -a "$OUT/run.log"
    fails=1; break
  fi
  log "round $r: replay rc=$rc (dom0 contract: 0 ok, 100 no updates, else error)"

  guest_file 'C:\ProgramData\Qubes\wu\agent.log'        > "$RD/agent-after.log"
  # The delta is what this round did. comm needs sorted input, so use the line count instead:
  # the log only ever grows, so everything past the before-snapshot's length is this round's.
  bl=$(wc -l < "$RD/agent-before.log" 2>/dev/null || echo 0)
  tail -n +$((bl + 1)) "$RD/agent-after.log" > "$RD/agent.log"
  log "round $r: agent.log grew by $(wc -l < "$RD/agent.log") line(s)"
  guest_file 'C:\ProgramData\Qubes\update-status.json'  > "$RD/update-status.json"
  guest_file 'C:\ProgramData\Qubes\vmupdate-shim.log'   > "$RD/vmupdate-shim.log" 2>/dev/null

  after=$(dom0_avail); log "round $r: dom0 updates-available AFTER='${after:-<empty>}'"
  echo "${after:-}" > "$RD/dom0-updates-available.txt"

  jargs=(--agent-log "$RD/agent.log" --json "$RD/verdict.json")
  case "$after" in ''|*[!0-9]*) : ;; *) jargs+=(--dom0-reported "$after") ;; esac
  if [ -n "$refused" ]; then
    log "round $r: JUDGE REFUSED (no pass ran - the refusal above is this round's outcome)"
  elif python3 tools/wu-pass-judge.py "${jargs[@]}" > "$RD/judge.out" 2>&1; then
    log "round $r: JUDGE PASS"
  else
    log "round $r: JUDGE FAIL"; sed 's/^/    /' "$RD/judge.out" | head -12 | tee -a "$OUT/run.log"; fails=1
  fi

  # OSCILLATION CHECK. An install pass settling dom0 is not enough: the very next SCAN must not
  # re-inflate the count. Measured 2026-09-20 - a pass drove dom0 to EMPTY and the following boot
  # scan reported 3 again, so the admin was told there was work when there was none. This is the
  # bar the reporter actually lives at, because a scan runs at every boot and on a timer.
  if [ -n "$refused" ]; then
    log "round $r: oscillation check skipped - no pass ran, so there is no report for a scan to contradict"
  else
    log "round $r: oscillation check - running a SCAN-only pass, dom0 must not change"
    dom0_before_scan="$after"
    # Run the scan WITHOUT -Scheduled. The scheduled-scan debounce legitimately skips any -Scheduled
    # scan whose previous completed pass is younger than 30 minutes, and it exits BEFORE logging - so
    # firing the task here tests the debounce, not the scan, and leaves no trace either way.
    # Measured 2026-09-20: the check waited 15 minutes for a scan that had correctly declined to run.
    timeout -k 10 900 tools/qtest run 'powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\Qubes Tools\bin\qubes-windows-update.ps1" -Action scan -RelayExe "C:\Program Files\Qubes Tools\bin\qubes-updates-relay.exe"' >/dev/null 2>&1
    _sc=$(( $(date +%s) + 900 )); scan_seen=0
    while [ "$(date +%s)" -lt "$_sc" ]; do
      sleep 30
      st_now=$(guest_file 'C:\ProgramData\Qubes\update-status.json' | tr -d '\r')
      case "$st_now" in *'"action"'*'scan'*) scan_seen=1; break;; esac
    done
    dom0_after_scan=$(dom0_avail)
    if [ "$scan_seen" = 0 ]; then
      log "round $r: FAIL - the scan never ran, so the oscillation check did not happen (missing data fails)"
      fails=1
    elif [ "${dom0_before_scan:-}" != "${dom0_after_scan:-}" ]; then
      log "round $r: FAIL OSCILLATION - dom0 was '${dom0_before_scan:-<empty>}' after the pass and '${dom0_after_scan:-<empty>}' after the scan"
      fails=1
    else
      log "round $r: oscillation OK - dom0 stayed '${dom0_after_scan:-<empty>}' across the pass and the scan"
    fi
  fi

  reboot_needed=$(python3 - "$RD/update-status.json" <<'PY' 2>/dev/null
import json,sys
# The guest writes update-status.json with a UTF-8 BOM; plain utf-8 raises and reboot_needed
# then read 'unknown' every round (measured 2026-09-20).
try: print(str(json.load(open(sys.argv[1], encoding='utf-8-sig')).get('reboot_needed', False)).lower())
except Exception: print('unknown')
PY
)
  log "round $r: reboot_needed=$reboot_needed"
  if [ "$reboot_needed" = true ]; then
    note_request "update-status.json says reboot_needed=true after round $r"
    # A REBOOT IS A COMPLETED CYCLE, not an issued command. Counting it at the shutdown was the
    # same accounting dishonesty this rule exists to stop, in my own implementation of the rule:
    # a shutdown that FAILED still incremented the counter, and a guest left powered off had only
    # half a cycle. Measured 2026-09-20: the ledger said "1 performed" while the guest was Running.
    log "round $r: shutting the guest down so the next round starts from the applied state"
    # NEVER `qvm-shutdown --wait`. Its --timeout is "timeout after which domains are KILLED"
    # (default 60 s), so --wait is a hard-kill on a timer - and a guest applying a staged
    # cumulative on shutdown legitimately takes many minutes. That is how this harness came to
    # hold a latent guest-killer aimed at the exact moment a guest is least safe to kill: mid
    # servicing apply. Measured 2026-09-20: it returned at 61 s with the guest still Running and
    # qrexec still answering - not a stall, an impatient harness with a kill attached.
    # Request the shutdown, then WATCH. A guest that will not halt is reported, never killed.
    log "round $r: requested shutdown; waiting for the guest to power off on its own (no kill)"
    timeout 120 qvm-shutdown "$VM" >/dev/null 2>&1
    _sd=$(( $(date +%s) + 1800 ))
    while [ "$(date +%s)" -lt "$_sd" ] && [ "$(qstate)" != Halted ]; do sleep 20; done
    if [ "$(qstate)" != Halted ]; then
      if stalled; then log "round $r: STALLED during shutdown"; else log "round $r: FAIL - the guest did not power off, so the requested reboot did NOT happen"; fi
      fails=1; break
    fi
    log "round $r: guest is down; bringing it back to complete the requested cycle"
    timeout 300 qvm-start "$VM" >/dev/null 2>&1
    if wait_qrexec 900; then
      note_performed
    else
      log "round $r: FAIL - the guest did not come back, so the requested reboot is INCOMPLETE"
      fails=1; break
    fi
  elif [ "$reboot_needed" = unknown ]; then
    # Unreadable status is missing data, and missing data fails - it must never be treated as
    # "no reboot needed", because that silently turns a requested cycle into none.
    log "round $r: FAIL - update-status.json unreadable, so reboot_needed is UNKNOWN (missing data fails)"
    fails=1
  fi
done

if [ "$reboots_performed" != "$reboots_requested" ]; then
  log "FAIL REBOOT ACCOUNTING: $reboots_performed performed vs $reboots_requested requested - a power cycle happened that nobody asked for (or a requested one was skipped)"
  fails=1
else
  log "reboot accounting OK: $reboots_performed performed = $reboots_requested requested"
fi
# THE AGGREGATE FLAG IS NOT THE WHOLE ANSWER. Every round above judges what dom0 was TOLD. It
# cannot see WHICH items the guest stopped counting, or why - so an item excluded for the wrong
# reason still produces a correct-looking dom0 flag and a green run. Jev graded this design's
# ability to tell a correct exclusion from a concealed failure at 0.24 for exactly that reason
# (2026-09-20, confidence 0.93), and the very first run carrying the grade had such an item in it
# (KB5007651, findings/issues.md). So: COUNT them here in code, and refuse to call the run green
# while they are unjudged. The judging itself is tools/wu-exclusion-audit.py - deliberately NOT
# called from here, because a harness must not need an external API to finish.
excl=$(python3 - "$OUT" <<'PYEOF' 2>/dev/null
import sys
sys.path.insert(0, "tools")
from pathlib import Path
import importlib.util
spec = importlib.util.spec_from_file_location("a", "tools/wu-exclusion-audit.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
seen = {}
for rnd, r in m.rows(Path(sys.argv[1])):
    if m.excluded(r):
        seen.setdefault(m.key(r), []).append(rnd)
for k, v in seen.items():
    print(f"{k}\t{','.join(v)}")
PYEOF
)
unjudged=0
if [ -n "$excl" ]; then
  log "EXCLUDED ITEMS dom0 was never told about ($(printf '%s\n' "$excl" | wc -l)):"
  printf '%s\n' "$excl" | sed 's/^/    /' | tee -a "$OUT/run.log"
  printf '%s\n' "$excl" > "$OUT/excluded-items.tsv"
  # Until 2026-09-21 this printed "NOT GREEN YET" and then exited 0 anyway, so a run WITH unjudged
  # exclusions was indistinguishable from a clean one to every caller - the precise hole
  # docs/ADR-updater.md listed as open. The harness still does not call Jev (it must be able to
  # finish without an external API), but it no longer PRETENDS the question was settled:
  #   * WU_EXCLUSION_VERDICT=<answers.json>, produced by `tools/wu-exclusion-audit.py --out`, is
  #     replayed here through that tool's OWN gate function - pure local code, no API - and must
  #     cover EVERY item in excluded-items.tsv. Green only if the gate passes on all of them.
  #   * no verdict file => exit 4 UNJUDGED. Not a pass, not a defect: an open question.
  if [ -n "${WU_EXCLUSION_VERDICT:-}" ] && [ -f "$WU_EXCLUSION_VERDICT" ]; then
    gate_out=$(python3 - "$OUT/excluded-items.tsv" "$WU_EXCLUSION_VERDICT" <<'PYEOF'
import json, sys, importlib.util
spec = importlib.util.spec_from_file_location("a", "tools/wu-exclusion-audit.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
items = [l.split("\t")[0] for l in open(sys.argv[1], encoding="utf-8").read().splitlines() if l.strip()]
try:
    v = json.load(open(sys.argv[2], encoding="utf-8"))
except Exception as e:
    print("VERDICT FILE UNREADABLE: %s" % e); sys.exit(2)
missing = [k for k in items if k not in v]
if missing:
    # A verdict that does not cover an item says nothing about it. Never let coverage be implied.
    print("VERDICT DOES NOT COVER: " + ", ".join(missing)); sys.exit(2)
stale = [k for k in v if k not in items]
if stale:
    print("note: verdict also covers items not in this run: " + ", ".join(stale))
sys.exit(m.gate({k: v[k] for k in items}))
PYEOF
    ); grc=$?
    printf '%s\n' "$gate_out" | sed 's/^/    /' | tee -a "$OUT/run.log"
    if [ "$grc" = 0 ]; then
      log "exclusion audit REPLAYED from $WU_EXCLUSION_VERDICT: every excluded item positively judged"
    else
      log "FAIL EXCLUSION AUDIT (rc=$grc): an excluded item is a concealed failure, unproven, or uncovered"
      fails=1
    fi
  else
    unjudged=1
    log "UNJUDGED EXCLUSIONS: run  tools/wu-exclusion-audit.py $OUT --out <answers.json>  and judge each"
    log "               one, then re-run with WU_EXCLUSION_VERDICT=<answers.json> to grade this run."
    log "               An exclusion not judged against evidence OUTSIDE the updater is an open"
    log "               question, not a pass - see docs/ADR-updater.md section 2."
  fi
else
  log "no excluded items in any round - dom0 was told about everything the guest saw"
fi

log "DONE: rounds=$ROUNDS fails=$fails unjudged_exclusions=$unjudged out=$OUT"
[ "$fails" = 0 ] || exit 3
[ "$unjudged" = 0 ] || exit 4   # passed every round, but exclusions are unjudged: NOT green
exit 0
