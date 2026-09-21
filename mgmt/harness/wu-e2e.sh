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
# Exit 0 every round PASSED, 3 a round FAILED or STALLED, 2 instrument error.
set -u

VM="${1:?usage: $0 <vm> [rounds] [outdir]}"
ROUNDS="${2:-3}"

# SERIAL, ALWAYS. This drives a guest for hours across reboots; a second job on the same guest
# would interleave its probes with these rounds and fabricate a verdict. Taking the lock is not
# optional here - tools/lint-harness.py refuses a harness that touches a guest without it, which
# is how this omission was caught before the first run rather than after a ruined campaign.
source mgmt/harness/vmlock.sh
vm_lock "$VM"

OUT="${3:-scratchpad/wu-e2e-$VM-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"
export QTEST_VM="$VM"
: "${QTEST_INCOMING:=C:\\Users\\gerd-test\\Documents\\QubesIncoming\\win-idd-mgmt}"
export QTEST_INCOMING

log(){ echo "$(date -u +%H:%M:%S) wu-e2e[$VM]: $*" | tee -a "$OUT/run.log"; }
qstate(){ qvm-ls --raw-data --fields state "$VM" 2>/dev/null; }
dom0_avail(){ qvm-features "$VM" updates-available 2>/dev/null | tr -d '\r\n'; }

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
  timeout -k 20 "${WU_REPLAY_TIMEOUT:-10800}" python3 tools/replay-dom0-update.py "$VM" --with-entrypoint \
      > "$RD/replay.out" 2>&1
  rc=$?
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
  if python3 tools/wu-pass-judge.py "${jargs[@]}" > "$RD/judge.out" 2>&1; then
    log "round $r: JUDGE PASS"
  else
    log "round $r: JUDGE FAIL"; sed 's/^/    /' "$RD/judge.out" | head -12 | tee -a "$OUT/run.log"; fails=1
  fi

  # OSCILLATION CHECK. An install pass settling dom0 is not enough: the very next SCAN must not
  # re-inflate the count. Measured 2026-09-20 - a pass drove dom0 to EMPTY and the following boot
  # scan reported 3 again, so the admin was told there was work when there was none. This is the
  # bar the reporter actually lives at, because a scan runs at every boot and on a timer.
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
if [ -n "$excl" ]; then
  log "EXCLUDED ITEMS dom0 was never told about ($(printf '%s\n' "$excl" | wc -l)):"
  printf '%s\n' "$excl" | sed 's/^/    /' | tee -a "$OUT/run.log"
  log "NOT GREEN YET: run  tools/wu-exclusion-audit.py $OUT  and judge each one. An exclusion that"
  log "               has not been judged against evidence OUTSIDE the updater is an open question,"
  log "               not a pass - see docs/ADR-updater.md section 2."
  printf '%s\n' "$excl" > "$OUT/excluded-items.tsv"
else
  log "no excluded items in any round - dom0 was told about everything the guest saw"
fi

log "DONE: rounds=$ROUNDS fails=$fails out=$OUT"
[ "$fails" = 0 ] && exit 0 || exit 3
