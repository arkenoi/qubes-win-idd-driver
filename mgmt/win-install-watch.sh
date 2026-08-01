#!/bin/bash
# Screenshot+telemetry watcher for an unattended Windows install in a Qubes HVM.
# Emits ONE line per meaningful change: console geometry change (boot phase), halt,
# restart, qrexec-up, or a stall (no cpu/disk/geometry movement for N samples).
# Needs feature gui-emulated=1 on the VM, else there is no console to look at.
set -u
VM="${1:-win-idd-test}"; D="${2:-/tmp/wininstall}"; mkdir -p "$D"
BUDGET=$((90*60)); t0=$(date +%s); n=0; stall=0; prevgeo=""; prevcpu=0; prevuse=0
st() { qvm-ls --raw-data --fields STATE "$VM" 2>/dev/null; }
cpu() { cd /home/user/qubes-win-idd-driver && QTEST_VM="$VM" tools/qtest state 2>/dev/null | grep -oP 'cputime=\K[0-9]+'; }
use() { qvm-volume info "$VM:root" 2>/dev/null | grep -oP 'usage\s+\K[0-9]+'; }
while :; do
  [ $(( $(date +%s) - t0 )) -gt $BUDGET ] && { echo "FAIL: budget exceeded"; exit 1; }
  s=$(st)
  if [ "$s" = "Halted" ]; then
     echo "HALT (phase boundary) - restarting without cdrom"
     qvm-start "$VM" >/dev/null 2>&1 || { echo "FAIL: qvm-start rc=$?"; exit 1; }
     stall=0; prevcpu=0; sleep 30; continue
  fi
  if timeout 20 bash -c "printf 'echo QREXEC_OK\n' | qrexec-client-vm $VM qubes.VMShell" 2>/dev/null | grep -q QREXEC_OK; then
     echo "QREXEC UP - install finished"; exit 0
  fi
  n=$((n+1)); t="$D/shot-$(printf '%03d' $n).tar"
  geo=""
  if (cd /home/user/qubes-win-idd-driver && QTEST_VM="$VM" tools/qtest fullshot "$t" >/dev/null 2>&1); then
     geo=$(tar xfO "$t" geometry.txt 2>/dev/null | awk '$1!="#"{print $4"x"$5}' | head -1)
  fi
  c=$(cpu); u=$(use)
  moved=0
  [ -n "$geo" ] && [ "$geo" != "$prevgeo" ] && { echo "CONSOLE $prevgeo -> $geo (shot $n, cpu=$((${c:-0}/1000000000))s)"; moved=1; }
  [ -n "${c:-}" ] && [ $(( (c - prevcpu) / 1000000000 )) -ge 3 ] && moved=1
  [ -n "${u:-}" ] && [ "$u" != "$prevuse" ] && moved=1
  if [ $moved -eq 0 ]; then stall=$((stall+1)); [ $stall -eq 6 ] && echo "STALL: no cpu/disk/console change ~9min (shot $n, geo=$geo)"; else stall=0; fi
  prevgeo="$geo"; prevcpu=${c:-0}; prevuse=${u:-0}
  sleep 90
done
