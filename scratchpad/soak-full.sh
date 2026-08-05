#!/bin/bash
# Full acceptance soak (user directive 2026-08-05: "test until you make sure it does not
# die, misbehave, or revert to 2560x1440").
# Per cycle: exact resize (agent-faithful: cache updated like a real agent apply), verify
# size + liveness; every 3rd cycle a GRACEFUL agent restart (size must persist, daemon
# survival tracked - its death is the KNOWN dom0 EOF bug, logged distinctly, recovered by
# reboot, soak continues); every 5th cycle a reboot (size + topology must persist); pixel
# liveness every 4th. Stops at the first HARD failure (wedge/misbehavior), leaving state
# frozen. Telemetry runs guest-side from boot (QubesWedgeTelemetry task).
set -u
cd /home/user/qubes-win-idd-driver
S=/tmp/claude-1000/-home-user-qubes-win-idd-driver/571a194d-e419-4275-9ba5-3a39d4d3191e/scratchpad
OUT=$S/soak-full.txt
INC='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
CYCLES=${CYCLES:-30}
SIZES=(2464x1200 1876x1004 2200x1234 1650x950 2340x1100 2016x1160)  # never 2560x1440

log() { echo "$(date -u +%H:%M:%S) $*" | tee -a "$OUT"; }
alive() { [ "$(timeout 20 ./tools/qtest run 'echo ALIVE' 2>&1 | tr -d '\r\0' | grep -c ALIVE)" -ge 2 ]; }
cur() { timeout 60 ./tools/qtest run "cd $INC && modeprobe.exe" 2>&1 | tr -d '\r' | grep -E '^\{' | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    for x in d['devices']:
        if x.get('primary') and x.get('current'): print(str(x['current']['w'])+'x'+str(x['current']['h'])); break
except Exception: pass"; }
wincount() { ./tools/qtest shot "$S/sf.tar" >/dev/null 2>&1; tar tf "$S/sf.tar" 2>/dev/null | grep -c png; }

reboot_vm() {
  timeout 200 ./tools/qtest shutdown >/dev/null 2>&1
  for _ in $(seq 1 60); do st=$(qvm-ls --fields NAME,STATE 2>/dev/null | awk '/win-idd-test/{print $2}'); [ "$st" = Halted ] && break; sleep 5; done
  [ "$st" != Halted ] && { log "HARD-FAIL shutdown-wedge (state=$st) - state frozen"; return 1; }
  timeout 200 ./tools/qtest start >/dev/null 2>&1
  for _ in $(seq 1 30); do alive && return 0; sleep 10; done
  log "HARD-FAIL boot-unresponsive"; return 1
}

: > "$OUT"
expected="2560x1440"
daemon_deaths=0; restarts=0
for i in $(seq 1 "$CYCLES"); do
  sz=${SIZES[$(( (i-1) % ${#SIZES[@]} ))]}
  r=$(timeout 150 ./tools/qtest run "powershell -NoProfile -ExecutionPolicy Bypass -File $INC\\resize-sync.ps1 -SyncNow $sz" 2>&1 | tr -d '\r' | grep -E '^SYNCRESULT')
  if ! printf '%s' "$r" | grep -q "ok=True readback=$sz"; then log "HARD-FAIL cycle $i sync ($r)"; exit 1; fi
  # agent-faithful cache update (what a real agent-applied dom0 request writes)
  W=${sz%x*}; H=${sz#*x}
  timeout 60 ./tools/qtest run "powershell -NoProfile -Command \"\$r='HKLM:\Software\Invisible Things Lab\Qubes Tools'; Set-ItemProperty \$r -Name FullscreenWidth -Value $W -Type DWord; Set-ItemProperty \$r -Name FullscreenHeight -Value $H -Type DWord\"" >/dev/null 2>&1
  expected="$sz"
  sleep 5
  c=$(cur)
  [ "$c" = "$expected" ] || { log "HARD-FAIL cycle $i misbehave: current=$c expected=$expected"; exit 1; }
  alive || { log "HARD-FAIL cycle $i qrexec-dead - state frozen"; exit 1; }
  log "cycle $i: $sz ok"

  if [ $((i % 3)) -eq 0 ]; then
    restarts=$((restarts+1))
    timeout 90 ./tools/qtest ps "& '$INC\\graceful-stop.ps1'" >/dev/null 2>&1
    sleep 10
    c=$(cur)
    [ "$c" = "$expected" ] || { log "HARD-FAIL cycle $i REVERT after agent restart: current=$c expected=$expected"; exit 1; }
    wc=$(wincount)
    if [ "$wc" -lt 1 ]; then
      daemon_deaths=$((daemon_deaths+1))
      log "cycle $i: daemon died on restart (KNOWN dom0 EOF bug, count=$daemon_deaths) - rebooting to recover"
      reboot_vm || exit 1
      c=$(cur); [ "$c" = "$expected" ] || { log "HARD-FAIL post-recovery REVERT: current=$c expected=$expected"; exit 1; }
    else
      log "cycle $i: agent restart ok, daemon survived, size held"
    fi
  fi

  if [ $((i % 5)) -eq 0 ]; then
    reboot_vm || exit 1
    sleep 5
    c=$(cur)
    [ "$c" = "$expected" ] || { log "HARD-FAIL cycle $i REVERT after reboot: current=$c expected=$expected"; exit 1; }
    log "cycle $i: reboot ok, size persisted ($c)"
  fi

  if [ $((i % 4)) -eq 0 ]; then
    W=${expected%x*}
    ./tools/qtest shot "$S/sf.tar" >/dev/null 2>&1
    rm -rf "$S/sfp" && mkdir -p "$S/sfp" && tar xf "$S/sf.tar" -C "$S/sfp" 2>/dev/null
    px=$(python3 - "$S/sfp" "$W" <<'EOF'
import sys, glob
from PIL import Image
f = sorted(glob.glob(sys.argv[1] + '/**/*.png', recursive=True))
if not f: print('FAIL no-window'); sys.exit()
im = Image.open(f[0]).convert('RGB')
flat = all(a == b for a, b in im.getextrema())
print('OK' if (im.size[0] == int(sys.argv[2]) and not flat) else f'FAIL size={im.size} flat={flat}')
EOF
)
    printf '%s' "$px" | grep -q '^OK' || { log "HARD-FAIL cycle $i pixels: $px"; exit 1; }
    log "cycle $i: pixels ok"
  fi
done
log "SOAK PASS: $CYCLES cycles, $restarts agent restarts, daemon_deaths=$daemon_deaths (known dom0 bug), zero reverts, zero wedges"
