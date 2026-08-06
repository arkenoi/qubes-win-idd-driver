#!/bin/bash
# Churn-storm soak: the deliberate reproduction of the wedge trigger, used as the
# ACCEPTANCE test for guest-side churn mitigations (M7). Fires resize storms far
# heavier than real use and checks the guest survives; on a wedge it STOPS with
# state frozen and prints the dom0 forensics command for the user.
#
# Metric that matters: replugs per storm (from the agent log) vs sizes requested -
# the LRU should make repeats free, the limiter should space the rest >= 2.5 s.
set -u
cd /home/user/qubes-win-idd-driver
S=/tmp/claude-1000/-home-user-qubes-win-idd-driver/571a194d-e419-4275-9ba5-3a39d4d3191e/scratchpad
OUT=$S/storm-soak.txt
INC='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
STORMS=${STORMS:-6}

log() { echo "$(date -u +%H:%M:%S) $*" | tee -a "$OUT"; }
alive() { [ "$(timeout 20 ./tools/qtest run 'echo ALIVE' 2>&1 | tr -d '\r\0' | grep -c ALIVE)" -ge 2 ]; }
slope() {
  local c1 c2
  c1=$(timeout 25 ./tools/qtest state 2>&1 | tr -d '\0' | grep -oE 'cputime=[0-9]+' | cut -d= -f2); sleep 12
  c2=$(timeout 25 ./tools/qtest state 2>&1 | tr -d '\0' | grep -oE 'cputime=[0-9]+' | cut -d= -f2)
  echo $(( (c2 - c1) / 1000000000 / 12 ))
}
replugs() { timeout 90 ./tools/qtest run "powershell -NoProfile -Command \"\$log = Get-ChildItem 'C:\Program Files\Qubes Tools\log' -Filter 'gui-agent-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1; (Select-String -Path \$log.FullName -Pattern 'replug=1').Count\"" 2>&1 | tr -d '\r' | grep -E '^[0-9]+$' | head -1; }

: > "$OUT"
# A pool with DELIBERATE REPEATS: the LRU should serve repeats replug-free.
POOL=(1911x1007 2033x1061 1777x933 2155x1121 1911x1007 2033x1061 1855x977 1777x933)
for s in $(seq 1 "$STORMS"); do
  r0=$(replugs)
  log "storm $s: firing ${#POOL[@]} resizes back-to-back (no settle)"
  for sz in "${POOL[@]}"; do
    ./tools/qtest resize "$sz" >/dev/null 2>&1
    sleep 1.2   # far faster than any human drag settle
  done
  sleep 12
  if ! alive; then
    sl=$(slope)
    log "storm $s: WEDGED (slope=${sl} vcpu-s/s). STATE FROZEN."
    log "  dom0 now:  sudo ~/wedge-forensics.sh --nmi"
    exit 1
  fi
  r1=$(replugs)
  log "storm $s: alive; replugs this storm = $(( ${r1:-0} - ${r0:-0} )) for ${#POOL[@]} requests"
done
log "STORM SOAK PASS: $STORMS storms x ${#POOL[@]} rapid resizes, no wedge"
