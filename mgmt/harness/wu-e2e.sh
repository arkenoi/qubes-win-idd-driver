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
  timeout -k 5 180 tools/qtest run "cmd /c type \"$1\"" 2>/dev/null | tr -d '\r' \
    | sed -e '/^Microsoft Windows \[/d' -e '/^(c) Microsoft/d' -e '/^$/d' -e '/^C:\\Windows\\System32>/d'
}

wait_qrexec(){ local d=$(( $(date +%s) + ${1:-900} ))
  while [ "$(date +%s)" -lt "$d" ]; do
    o=$(timeout -k 5 45 tools/qtest run "cmd /c echo UP" 2>/dev/null | tr -d '\r\n')
    case "$o" in *UP*) return 0;; esac
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
pcode=$(timeout 40 curl -sS -o /dev/null -w '%{http_code}' -x http://127.0.0.1:8082 \
        http://download.windowsupdate.com/ 2>/dev/null)
[ "$pcode" = 200 ] || { echo "INSTRUMENT: updates proxy is listening but does not reach Windows Update (http=$pcode) - a run now would blame the guest for a network failure"; exit 2; }
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
  timeout -k 20 3600 python3 tools/replay-dom0-update.py "$VM" --with-entrypoint \
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
  timeout -k 10 900 tools/qtest run 'cmd /c schtasks /run /tn QubesWindowsUpdateScan' >/dev/null 2>&1
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
log "DONE: rounds=$ROUNDS fails=$fails out=$OUT"
[ "$fails" = 0 ] && exit 0 || exit 3
