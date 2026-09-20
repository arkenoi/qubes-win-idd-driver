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

fails=0
for r in $(seq 1 "$ROUNDS"); do
  RD="$OUT/round$r"; mkdir -p "$RD"
  before=$(dom0_avail); log "round $r: dom0 updates-available BEFORE='${before:-<empty>}'"

  if ! wait_qrexec 900; then
    if stalled; then log "round $r: STALLED (Running, qrexec dead) - stopping, the guest must be interrogated"; fails=1; break; fi
    log "round $r: guest is Halted - starting it"
    timeout 240 qvm-start "$VM" >/dev/null 2>&1
    wait_qrexec 900 || { log "round $r: guest never came up"; fails=1; break; }
  fi

  log "round $r: driving a pass the Qube Manager way (replay-dom0-update.py --with-entrypoint)"
  timeout -k 20 3600 python3 tools/replay-dom0-update.py "$VM" --with-entrypoint \
      > "$RD/replay.out" 2>&1
  rc=$?
  log "round $r: replay rc=$rc (dom0 contract: 0 ok, 100 no updates, else error)"

  guest_file 'C:\ProgramData\Qubes\wu\agent.log'        > "$RD/agent.log"
  guest_file 'C:\ProgramData\Qubes\wu\update-status.json' > "$RD/update-status.json"
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

  reboot_needed=$(python3 - "$RD/update-status.json" <<'PY' 2>/dev/null
import json,sys
try: print(str(json.load(open(sys.argv[1])).get('reboot_needed', False)).lower())
except Exception: print('unknown')
PY
)
  log "round $r: reboot_needed=$reboot_needed"
  if [ "$reboot_needed" = true ]; then
    log "round $r: shutting the guest down so the next round starts from the applied state"
    timeout 600 qvm-shutdown --wait "$VM" >/dev/null 2>&1 || { if stalled; then log "round $r: STALLED during shutdown"; fails=1; break; fi; }
  fi
done

log "DONE: rounds=$ROUNDS fails=$fails out=$OUT"
[ "$fails" = 0 ] && exit 0 || exit 3
