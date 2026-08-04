#!/bin/bash
# Cold-boot the test qube, failing LOUDLY at each step.
#
# Written after diagnosing the 2026-08-04 Transient wedges: the ad-hoc inline version of this
# had a wait loop with no failure branch, so when a shutdown request did not reach the guest it
# fell through and issued `start` against a still-running VM, with output discarded. The whole
# thing then produced no output at all and looked like a guest fault. It was not: the guest's
# event log shows no 1074/6006/13 for that cycle, i.e. Windows never got the request, and
# normal shutdowns here take 10-16 s.
#
# Usage: scratchpad/vmcycle.sh   (exit 0 = qube is up and qrexec answers)
set -u
cd /home/user/qubes-win-idd-driver
VM=win-idd-test

state() { qvm-ls --fields NAME,STATE 2>/dev/null | awk -v v="$VM" '$1==v{print $2}'; }

timeout 200 ./tools/qtest shutdown >/dev/null 2>&1

for _ in $(seq 1 60); do [ "$(state)" = Halted ] && break; sleep 5; done
if [ "$(state)" != Halted ]; then
  echo "vmcycle: FAIL - not Halted after 300s (state=$(state)). Shutdown request likely never" >&2
  echo "vmcycle: reached the guest. Capture state + xenagent BEFORE recovering; do NOT start." >&2
  exit 1
fi

timeout 200 ./tools/qtest start >/dev/null 2>&1
for _ in $(seq 1 60); do [ "$(state)" = Running ] && break; sleep 5; done
if [ "$(state)" != Running ]; then
  echo "vmcycle: FAIL - not Running after start (state=$(state))" >&2
  exit 1
fi

for _ in $(seq 1 30); do
  [ "$(timeout 25 ./tools/qtest run 'echo BOOT_OK' 2>&1 | tr -d '\r' | grep -c BOOT_OK)" -ge 2 ] && { echo "vmcycle: up"; exit 0; }
  sleep 10
done
echo "vmcycle: FAIL - qrexec never answered though state=Running" >&2
exit 1
