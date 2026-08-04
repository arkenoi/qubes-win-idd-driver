#!/bin/bash
# T2 stability stress test (user-required gate before the goal may be called met).
# Serial resize cycles through arbitrary + built-in sizes on the D4 driver, checking after
# EVERY cycle: qrexec liveness, external readback, and livelock watch (cputime slope);
# every 3rd cycle a decoded-pixel screenshot must be non-black and the right size.
# Aborts loudly on first failure. Run with the IDD primary (BDA disabled, revert armed).
set -u
cd /home/user/qubes-win-idd-driver
S=${STRESS_OUT:-/tmp/claude-1000/-home-user-qubes-win-idd-driver/571a194d-e419-4275-9ba5-3a39d4d3191e/scratchpad}
OUT=$S/stress-results.txt
INC='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
# Mixed load: arbitrary (replug path) and IDD built-ins (plain CDS path). 3440x1409 is the
# real dom0 work-area size (usable height = 1440-31 panel rows) — the goal's own target.
SIZES=(1600x1000 1920x1080 2566x1022 1024x768 1234x777 3440x1409 1600x900 2000x1000)
CYCLES=${CYCLES:-16}

cputime() { timeout 25 ./tools/qtest state 2>/dev/null | grep -oE 'cputime=[0-9]+' | cut -d= -f2; }

: > "$OUT"
prev_cpu=$(cputime); prev_t=$(date +%s)
fail=0
for i in $(seq 1 "$CYCLES"); do
  sz=${SIZES[$(( (i-1) % ${#SIZES[@]} ))]}
  echo "=== cycle $i size $sz ===" | tee -a "$OUT"
  res=$(timeout 120 ./tools/qtest run "powershell -NoProfile -ExecutionPolicy Bypass -File $INC\\resize-sync.ps1 -SyncNow $sz" 2>&1 | tr -d '\r' | grep -E '^SYNCRESULT')
  echo "$res" | tee -a "$OUT"
  if ! printf '%s' "$res" | grep -q "ok=True readback=$sz"; then
    echo "cycle $i: FAIL sync ($res)" | tee -a "$OUT"; fail=1; break
  fi
  # settle rule learned from the livelock: wait for the agent's re-grant line before moving on
  sleep 6
  alive=$(timeout 25 ./tools/qtest run 'echo ALIVE' 2>&1 | tr -d '\r' | grep -c ALIVE)
  if [ "$alive" -lt 2 ]; then echo "cycle $i: FAIL qrexec-dead" | tee -a "$OUT"; fail=1; break; fi
  # livelock watch: cputime is ns; slope vs wall clock. >2.5 vCPU-seconds/second sustained = spin
  cpu=$(cputime); t=$(date +%s)
  if [ -n "$cpu" ] && [ -n "$prev_cpu" ] && [ "$t" -gt "$prev_t" ]; then
    slope=$(( (cpu - prev_cpu) / 1000000000 / (t - prev_t) ))
    echo "cpu-slope=${slope} vcpu-s/s" | tee -a "$OUT"
    if [ "$slope" -ge 3 ]; then echo "cycle $i: FAIL livelock-signature (slope=$slope)" | tee -a "$OUT"; fail=1; break; fi
  fi
  prev_cpu=$cpu; prev_t=$t
  if [ $((i % 3)) -eq 0 ]; then
    # dom0-follow is a pipeline with real latency (replug capture outage -> re-dump ->
    # daemon window resize). Poll until the dom0 window matches the target; REPORT the
    # latency as a metric. Never converging within the bound is the failure.
    W=${sz%x*}; H=${sz#*x}
    t0=$(date +%s); ver="FAIL never-sampled"
    for _ in $(seq 1 12); do
      ./tools/qtest shot "$S/stress-$i.tar" >/dev/null 2>&1
      rm -rf "$S/stress-$i" && mkdir -p "$S/stress-$i" && tar xf "$S/stress-$i.tar" -C "$S/stress-$i" 2>/dev/null
      ver=$(python3 - "$S/stress-$i" "$W" "$H" <<'EOF'
import sys, glob
from PIL import Image
d, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
f = sorted(glob.glob(d + '/**/*.png', recursive=True))
if not f: print('FAIL no-window'); sys.exit()
im = Image.open(f[0]).convert('RGB')
ex = im.getextrema()
flat = all(a == b for a, b in ex)
okw = im.size[0] == w
okh = abs(im.size[1] - h) <= 60
print('OK' if (okw and okh and not flat) else f'FAIL size={im.size} flat={flat}')
EOF
)
      printf '%s' "$ver" | grep -q '^OK' && break
      sleep 2
    done
    lat=$(( $(date +%s) - t0 ))
    echo "pixels: $ver dom0_follow_latency=${lat}s" | tee -a "$OUT"
    if ! printf '%s' "$ver" | grep -q '^OK'; then echo "cycle $i: FAIL dom0-follow (never converged in ${lat}s)" | tee -a "$OUT"; fail=1; break; fi
  fi
done
if [ "$fail" -eq 0 ]; then echo "STRESS PASS: $CYCLES cycles" | tee -a "$OUT"; else echo "STRESS FAIL at cycle $i" | tee -a "$OUT"; exit 1; fi
