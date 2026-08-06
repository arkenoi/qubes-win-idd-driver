#!/bin/bash
# THE acceptance soak, at last on the REAL path: dom0 WM resizes via local.WinResize drive
# genuine MSG_CONFIGURE streams through gui-daemon into the agent-native exact-follow.
# Mixes single jumps and drag-like streams (incremental resizes 150 ms apart). Verifies the
# goal's core invariant after every gesture: requested == dom0 window == guest resolution.
# Agent restart every 4th cycle, reboot every 7th. Stops at first failure, state frozen.
set -u
cd /home/user/qubes-win-idd-driver
S=/tmp/claude-1000/-home-user-qubes-win-idd-driver/571a194d-e419-4275-9ba5-3a39d4d3191e/scratchpad
OUT=$S/soak-drag.txt
INC='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
CYCLES=${CYCLES:-28}

log() { echo "$(date -u +%H:%M:%S) $*" | tee -a "$OUT"; }
alive() { [ "$(timeout 20 ./tools/qtest run 'echo ALIVE' 2>&1 | tr -d '\r\0' | grep -c ALIVE)" -ge 2 ]; }
guestres() { timeout 60 ./tools/qtest run "cd $INC && modeprobe.exe" 2>&1 | tr -d '\r' | grep -E '^\{' | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    for x in d['devices']:
        if x.get('primary') and x.get('current'): print(str(x['current']['w'])+'x'+str(x['current']['h'])); break
except Exception: pass"; }
domwin() { ./tools/qtest resize query 2>/dev/null | grep -oE 'w=[0-9]+ h=[0-9]+' | tr -d 'wh=' | tr ' ' 'x'; }

verify() { # $1 = expected WxH, $2 = label
  local exp=$1 lbl=$2 tries g gu
  for tries in 1 2 3 4 5 6; do
    sleep 3
    g=$(domwin); gu=$(guestres)
    [ "$g" = "$exp" ] && [ "$gu" = "$exp" ] && { log "$lbl: CONVERGED $exp"; return 0; }
  done
  log "$lbl: FAIL not converged (want $exp, dom0=$g guest=$gu)"
  return 1
}

: > "$OUT"
expected=""
for i in $(seq 1 "$CYCLES"); do
  W=$((1500 + RANDOM % 1100)); H=$((800 + RANDOM % 500))
  if [ $((i % 2)) -eq 0 ]; then
    # drag-like stream: 8 increments 150 ms apart ending at WxH
    kind=drag
    sw=$((W - 400)); sh=$((H - 200))
    for s in 0 1 2 3 4 5 6 7; do
      ./tools/qtest resize "$((sw + s * 50))x$((sh + s * 25))" >/dev/null 2>&1
      sleep 0.15
    done
    ./tools/qtest resize "${W}x${H}" >/dev/null 2>&1
  else
    kind=jump
    ./tools/qtest resize "${W}x${H}" >/dev/null 2>&1
  fi
  expected="${W}x${H}"
  verify "$expected" "cycle $i ($kind)" || { log "STATE FROZEN"; exit 1; }
  alive || { log "cycle $i: FAIL qrexec-dead"; exit 1; }

  if [ $((i % 4)) -eq 0 ]; then
    timeout 90 ./tools/qtest ps "& '$INC\\graceful-stop.ps1'" >/dev/null 2>&1
    sleep 10
    # After an agent restart the daemon RECREATES its window and the WM may place
    # it at a remembered geometry - dom0 then legitimately requests that size and
    # the agent must follow it (user rule: dom0 is the source of truth). So the
    # invariant here is guest == CURRENT dom0 window, never guest == pre-restart
    # size (measured 2026-08-06: the WM restored a tile size; asserting the old
    # size reported a false REVERT).
    # poll for the recreated dom0 window to settle (an empty/partial read right
    # after the restart is the harness racing the daemon, not a failure)
    dw=""; for _ in 1 2 3 4 5 6; do dw=$(domwin); [ -n "$dw" ] && break; sleep 3; done
    if [ -z "$dw" ]; then
        # No dom0 window at all = gui-daemon died on the agent restart: the KNOWN
        # dom0 EOF bug (DESIGN-gui-daemon-restart-survival.md SS3), not a guest
        # defect. Count it, recover by reboot, continue - same handling the old
        # soak used, which this harness dropped by mistake.
        log "cycle $i: daemon died on restart (KNOWN dom0 EOF bug) - rebooting to recover"
        timeout 200 ./tools/qtest shutdown >/dev/null 2>&1
        for _ in $(seq 1 60); do st=$(qvm-ls --fields NAME,STATE 2>/dev/null | awk '/win-idd-test/{print $2}'); [ "$st" = Halted ] && break; sleep 5; done
        [ "$st" != Halted ] && { log "cycle $i: FAIL shutdown-wedge"; exit 1; }
        timeout 200 ./tools/qtest start >/dev/null 2>&1
        for _ in $(seq 1 30); do alive && break; sleep 10; done
        alive || { log "cycle $i: FAIL boot after daemon death"; exit 1; }
        for _ in 1 2 3 4 5 6; do dw=$(domwin); [ -n "$dw" ] && break; sleep 5; done
        [ -n "$dw" ] || { log "cycle $i: FAIL no dom0 window even after reboot"; exit 1; }
    fi
    gu=""; for _ in 1 2 3 4 5 6; do gu=$(guestres); [ "$gu" = "$dw" ] && break; sleep 3; done
    [ "$gu" = "$dw" ] || { log "cycle $i: FAIL after agent restart: guest=$gu dom0-window=$dw"; exit 1; }
    expected="$dw"
    wc=$(./tools/qtest shot "$S/sd.tar" >/dev/null 2>&1; tar tf "$S/sd.tar" 2>/dev/null | grep -c png)
    if [ "$wc" -lt 1 ]; then
      log "cycle $i: daemon died on restart (KNOWN dom0 bug) - rebooting"
      timeout 200 ./tools/qtest shutdown >/dev/null 2>&1
      for _ in $(seq 1 60); do st=$(qvm-ls --fields NAME,STATE 2>/dev/null | awk '/win-idd-test/{print $2}'); [ "$st" = Halted ] && break; sleep 5; done
      [ "$st" != Halted ] && { log "FAIL shutdown-wedge"; exit 1; }
      timeout 200 ./tools/qtest start >/dev/null 2>&1
      for _ in $(seq 1 30); do alive && break; sleep 10; done
      alive || { log "FAIL boot"; exit 1; }
    else
      log "cycle $i: agent restart ok, daemon survived"
    fi
  fi

  if [ $((i % 7)) -eq 0 ]; then
    timeout 200 ./tools/qtest shutdown >/dev/null 2>&1
    for _ in $(seq 1 60); do st=$(qvm-ls --fields NAME,STATE 2>/dev/null | awk '/win-idd-test/{print $2}'); [ "$st" = Halted ] && break; sleep 5; done
    [ "$st" != Halted ] && { log "cycle $i: FAIL shutdown-wedge (state=$st)"; exit 1; }
    timeout 200 ./tools/qtest start >/dev/null 2>&1
    for _ in $(seq 1 30); do alive && break; sleep 10; done
    alive || { log "cycle $i: FAIL boot"; exit 1; }
    gu=$(guestres)
    log "cycle $i: reboot ok (guest at $gu)"
  fi
done
log "DRAG SOAK PASS: $CYCLES cycles (real MSG_CONFIGURE path, drag streams + jumps + restarts + reboots)"
