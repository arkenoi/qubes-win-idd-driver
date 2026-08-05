#!/bin/bash
# Soak reproduction of the churn livelock (task #12, user priority). Alternates rapid
# sequential and concurrent display churn until the guest wedges (qrexec dead), then STOPS
# WITHOUT recovering — telemetry is already on disk in the guest, and the frozen state is
# the forensic artifact. Exit 0 = wedged (success for this harness), exit 1 = survived cap.
set -u
cd /home/user/qubes-win-idd-driver
S=/tmp/claude-1000/-home-user-qubes-win-idd-driver/571a194d-e419-4275-9ba5-3a39d4d3191e/scratchpad
OUT=$S/soak-results.txt
INC='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
CAP=${CAP:-40}

alive() { [ "$(timeout 20 ./tools/qtest run 'echo ALIVE' 2>&1 | tr -d '\r\0' | grep -c ALIVE)" -ge 2 ]; }
slope() {
  local c1 c2; c1=$(timeout 25 ./tools/qtest state 2>&1 | tr -d '\0' | grep -oE 'cputime=[0-9]+' | cut -d= -f2)
  sleep 15
  c2=$(timeout 25 ./tools/qtest state 2>&1 | tr -d '\0' | grep -oE 'cputime=[0-9]+' | cut -d= -f2)
  echo $(( (c2-c1) / 1000000000 / 15 ))
}

: > "$OUT"
for i in $(seq 1 "$CAP"); do
  w1=$((1500 + RANDOM % 900)); h1=$((900 + RANDOM % 400))
  w2=$((1500 + RANDOM % 900)); h2=$((900 + RANDOM % 400))
  w3=$((1500 + RANDOM % 900)); h3=$((900 + RANDOM % 400))
  if [ $((i % 2)) -eq 1 ]; then
    kind=seq
    timeout 100 ./tools/qtest run "powershell -NoProfile -ExecutionPolicy Bypass -File $INC\\resize-sync.ps1 -SyncNow ${w1}x${h1}" >/dev/null 2>&1
    timeout 100 ./tools/qtest run "powershell -NoProfile -ExecutionPolicy Bypass -File $INC\\resize-sync.ps1 -SyncNow ${w2}x${h2}" >/dev/null 2>&1
  else
    kind=conc
    timeout 60 ./tools/qtest run "start /b powershell -NoProfile -ExecutionPolicy Bypass -File $INC\\resize-sync.ps1 -SyncNow ${w1}x${h1} & start /b powershell -NoProfile -ExecutionPolicy Bypass -File $INC\\resize-sync.ps1 -SyncNow ${w2}x${h2} & start /b powershell -NoProfile -ExecutionPolicy Bypass -File $INC\\resize-sync.ps1 -SyncNow ${w3}x${h3}" >/dev/null 2>&1
    sleep 25
  fi
  if alive; then
    echo "batch $i ($kind): alive" | tee -a "$OUT"
  else
    sl=$(slope)
    echo "batch $i ($kind): WEDGED slope=${sl} at $(date -u +%H:%M:%S)" | tee -a "$OUT"
    ./tools/qtest shot "$S/soak-wedge.tar" >/dev/null 2>&1
    echo "state frozen - do NOT recover before forensics" | tee -a "$OUT"
    exit 0
  fi
done
echo "survived $CAP batches - no wedge" | tee -a "$OUT"
exit 1
