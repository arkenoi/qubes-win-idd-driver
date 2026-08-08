#!/bin/bash
# Typing-only workload + QGAPERF on one guest, to measure the ENUMERATION FALLBACK RATE.
#
# Hypothesis under test: our agent's Win11 typing penalty comes from falling back to full
# window enumeration more often than on Win10 - not from being uniformly more expensive.
# On win11 (ours, BDA) 23.1% of frames had iwn>0 and cost ~16x an event-driven frame.
#
# Typing is the right workload: each keystroke is a tiny damage event, so a fallback frame
# stands out. Drag repaints large areas and hides it - which is exactly why drag showed our
# agent at parity with stock while typing showed 3x.
#
# One guest at a time: benchmark.sh refuses to measure with another Windows qube running, and
# a contaminated timing is worse than none.
set -u
cd /home/user/qubes-win-idd-driver
VM="${1:?usage: $0 <vm> <label>}"
LABEL="${2:?}"
SECS="${3:-20}"
S=/tmp/claude-1000/-home-user-qubes-win-idd-driver/596ce65c-62cf-4820-af62-c943df501f00/scratchpad
INC='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
log(){ echo "$(date -u +%H:%M:%S) enum[$LABEL]: $*"; }
qq(){ QTEST_VM="$VM" timeout "${QT:-180}" ./tools/qtest "$@"; }
state(){ qvm-ls --fields NAME,STATE 2>/dev/null | awk -v v="$1" '$1==v{print $2}'; }

for v in win10-clean win10-e2e win11-fresh win11-idd-test win10-stock win-idd-test; do
  [ "$v" = "$VM" ] && continue
  [ "$(state $v)" = Running ] && { log "stopping $v"; timeout 240 qvm-shutdown --wait "$v" >/dev/null 2>&1 || timeout 60 qvm-kill "$v" >/dev/null 2>&1; }
done
[ "$(state $VM)" = Running ] || { log "starting $VM"; timeout 150 qvm-start "$VM" >/dev/null 2>&1; }
t0=$(date +%s)
while [ $(( $(date +%s)-t0 )) -lt 900 ]; do
  qq run 'echo UP' 2>&1 | tr -d '\r\0' | grep -q UP && break; sleep 20
done
qq run 'echo UP' 2>&1 | tr -d '\r\0' | grep -q UP || { log "ABORT: $VM not answering"; exit 1; }
sleep 25

# Record what this guest actually is, so the comparison cannot silently mix configurations.
log "config:"
qq pushrun "$S/iddstate.ps1" 2>&1 | tr -d '\r' | grep -aE "^VC |^SCREEN " | sed 's/^/    /'
h=$(qq pushrun ./scratchpad/agent-hash.ps1 2>/dev/null | tr -d '\r' | grep -oE '^AGENTHASH=[0-9A-F]{16}' | cut -d= -f2)
log "agent=$h"

log "pushing harness + collector"
qq push instrumentation/drag-harness.ps1 >/dev/null 2>&1
qq push instrumentation/collect-perf.ps1 >/dev/null 2>&1
qq ps 'Start-Process notepad' >/dev/null 2>&1; sleep 5

log "typing-only workload, ${SECS}s"
# Keep the FULL harness output: the phase markers are the window boundaries, and tailing it
# threw away PHASE-START, which is why the first comparison had to reconstruct the window by
# subtracting 20 s.
qq run "powershell -NoProfile -ExecutionPolicy Bypass -File $INC\\drag-harness.ps1 -DragSeconds 0 -ScrollSeconds 0 -TypeSeconds $SECS -IdleSeconds 0" 2>&1 | tr -d '\r' > "$S/harness-$LABEL.txt"
grep -aE "PHASE-(START|END) +type" "$S/harness-$LABEL.txt" | sed 's/^/    /'

# Window the collection to the typing phase. Collecting the whole log compares two guests'
# ENTIRE histories - on one of them that included three prior benchmark reps - which reported
# a 32.5%-vs-1.6% enumeration gap that inverted to 2.3%-vs-4.6% once bounded correctly.
SINCE=$(grep -aE "PHASE-START +type" "$S/harness-$LABEL.txt" | tail -1 | awk '{print $NF}')
UNTIL=$(grep -aE "PHASE-END +type"   "$S/harness-$LABEL.txt" | tail -1 | awk '{print $NF}')
if [ -z "$SINCE" ] || [ -z "$UNTIL" ]; then
    log "ABORT: could not read the typing phase boundaries - refusing to collect an unbounded log"
    exit 1
fi
log "typing phase: $SINCE .. $UNTIL"

log "collecting QGAPERF (windowed)"
qq run "powershell -NoProfile -ExecutionPolicy Bypass -File $INC\\collect-perf.ps1 -Since $SINCE -Until $UNTIL" 2>&1 | tr -d '\r\0' \
  | sed -n '/===PERFSTART===/,/===PERFEND===/p' > "$S/enum-$LABEL.txt"
grep -aE "PERFSTART|PERFCOUNT" "$S/enum-$LABEL.txt" | sed 's/^/    /' 
grep -c 'QGAPERF,' "$S/enum-$LABEL.txt" | sed "s/^/    records: /"
grep -m1 'PERFSTART' "$S/enum-$LABEL.txt" | sed 's/^/    /'
