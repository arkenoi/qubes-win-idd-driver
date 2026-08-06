#!/bin/bash
# Snap-regression battery (user directive 2026-08-06: watch RESSNAP15 for regressions).
# Run after any agent deploy. Uses the real dom0 path (local.WinResize). Checks:
#   1. near-bordered-half (within 15px)  -> MUST snap to the bordered half
#   2. 20px off the half                 -> MUST NOT snap (exact apply of the request)
#   3. arbitrary mid-size                -> MUST NOT snap
#   4. position preservation             -> GEOM x/y unchanged across a snap
# Requires the work-area feed live (bordered half = (waW/2 - fl - fr) x (waH - ft - fb)).
set -u
cd /home/user/qubes-win-idd-driver
S=${SNAP_OUT:-/tmp/claude-1000/-home-user-qubes-win-idd-driver/571a194d-e419-4275-9ba5-3a39d4d3191e/scratchpad}
OUT=$S/snap-regress.txt
INC='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'

log() { echo "$(date -u +%H:%M:%S) $*" | tee -a "$OUT"; }
fail=0

feed=$(timeout 60 ./tools/qtest run "\"C:\Program Files\Qubes Tools\bin\qubesdb-cmd.exe\" -c read /qubes-workarea" 2>&1 | tr -d '\r' | grep -E '^[0-9]+ ' | head -1)
read -r _ _ waW waH fl fr ft fb <<< "$feed"
if [ -z "${waH:-}" ] || [ "${ft:-0}" -eq 0 ]; then
  log "SKIP: work-area feed not live/complete ($feed) - battery needs real extents"
  exit 2
fi
halfW=$((waW / 2 - fl - fr)); bordH=$((waH - ft - fb))
log "feed: $feed -> bordered half = ${halfW}x${bordH}"

guest() { timeout 60 ./tools/qtest run "cd $INC && modeprobe.exe" 2>&1 | tr -d '\r' | grep -E '^\{' | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    for x in d['devices']:
        if x.get('primary') and x.get('current'): print(str(x['current']['w'])+'x'+str(x['current']['h'])); break
except Exception: pass"; }
geomxy() { ./tools/qtest resize query 2>/dev/null | grep -oE 'x=[0-9-]+ y=[0-9-]+' | head -1; }

# --- test 1: near-half must snap
req="$((halfW - 6))x$((bordH - 4))"
pos0=$(geomxy)
./tools/qtest resize "$req" >/dev/null 2>&1; sleep 7
g=$(guest)
if [ "$g" = "${halfW}x${bordH}" ]; then log "T1 near-half snap: PASS ($req -> $g)"; else log "T1 near-half snap: FAIL ($req -> $g, want ${halfW}x${bordH})"; fail=1; fi
pos1=$(geomxy)
[ "$pos0" = "$pos1" ] && log "T4 position preserved: PASS ($pos1)" || log "T4 position: CHANGED $pos0 -> $pos1 (investigate: WM may legitimately clamp)"

# --- test 2: 20px off must NOT snap
req="$((halfW - 20))x$((bordH - 20))"
./tools/qtest resize "$req" >/dev/null 2>&1; sleep 7
g=$(guest)
if [ "$g" = "$req" ]; then log "T2 20px-off no-snap: PASS ($g exact)"; else log "T2 20px-off no-snap: FAIL (want $req, got $g)"; fail=1; fi

# --- test 3: arbitrary mid-size must NOT snap
req="1803x957"
./tools/qtest resize "$req" >/dev/null 2>&1; sleep 7
g=$(guest)
if [ "$g" = "$req" ]; then log "T3 arbitrary no-snap: PASS ($g exact)"; else log "T3 arbitrary no-snap: FAIL (want $req, got $g)"; fail=1; fi

if [ "$fail" -eq 0 ]; then log "SNAP-REGRESS PASS"; else log "SNAP-REGRESS FAIL"; exit 1; fi
