#!/bin/bash
# Win10 phase retry. PRECONDITION: the user has set EnableLUA=0 in win10-clean and rebooted
# (its original HIGHEST-task elevation was closed by a Windows update; run-elevated.ps1 also
# fails on this build - its own schtasks is denied). With EnableLUA=0 the qrexec token is
# unfiltered like the Win11 rigs, so plain swap-agent deploys. Aborts fast if still filtered.
cd /home/user/qubes-win-idd-driver || exit 1
source .claude/skills/win-guest-e2e/e2e-lib.sh
S=/home/user/qubes-win-idd-driver/scratchpad/e2e
R=$S/results.log
log(){ echo "[$(date +%H:%M:%S)] $*" >>"$R"; }
INC='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
WANT_SHA='83B69F62E532944A548F46C3B3D5DC17738A774FEACBE86E798B1A5A83C99619'
export QTEST_VM=win10-clean
log "=== PHASE win10-clean RETRY (direct swap; assumes EnableLUA=0 applied by user) ==="
bootwait 15 log || { log "win10 BOOT FAIL"; exit 1; }
./tools/qtest synctime >/dev/null 2>&1; log "win10 up + clock synced"
# PRE-FLIGHT: is the qrexec token now UNFILTERED? EnableLUA=0 + reboot removes UAC token
# filtering, so the qtest shell lands as full admin (like the Win11 rigs). Uses a marker-
# delimited probe (elev-check.ps1) parsed ONLY after "=== RESULT ===" - a plain grep is
# fooled by the qrexec command echo, which contains any literal we search for (verified
# 2026-08-12: the earlier whoami|findstr gate false-matched its own echoed command line).
timeout -k 8 120 ./tools/qtest push guest/elev-check.ps1 >/dev/null 2>&1
tok=$(timeout -k 8 60 ./tools/qtest ps "& '$INC\\elev-check.ps1'" 2>/dev/null | tr -d '\r' | sed -n '/=== RESULT ===/,$p' | grep -oE 'TOKEN=(ELEVATED|FILTERED)' | head -1)
if [ "$tok" != "TOKEN=ELEVATED" ]; then
  log "win10 STILL FILTERED ($tok) - EnableLUA=0 not in effect (apply it + REBOOT the guest, then re-run). Aborting."
  exit 3
fi
log "win10 token is now elevated ($tok)"
# Deploy exactly like the Win11 rigs: plain swap-agent, no run-elevated shim (that path's own
# schtasks is denied on this build - it was the earlier failure).
timeout -k 8 120 ./tools/qtest push artifacts-fix5/gui-agent.exe guest/swap-agent.ps1 guest/defect-evidence.ps1 guest/fire-toast.ps1 guest/open-start.ps1 guest/toastcrop-debug.ps1 guest/drag-measure.ps1 guest/reset-census.ps1 >/dev/null 2>&1 || { log "win10 push FAIL"; exit 1; }
timeout -k 8 200 ./tools/qtest ps "& '$INC\\swap-agent.ps1' -NewAgent '$INC\\gui-agent.exe'" > "$S/win10-swap2.txt" 2>&1
grep -q '"ok":  true' "$S/win10-swap2.txt" && log "win10 swap OK" || { log "win10 swap STILL FAIL (see win10-swap2.txt)"; exit 1; }
timeout -k 8 150 ./tools/qtest ps "& '$INC\\defect-evidence.ps1'" > "$S/win10-h1.txt" 2>&1
sleep 80
timeout -k 8 150 ./tools/qtest ps "& '$INC\\defect-evidence.ps1'" > "$S/win10-h2.txt" 2>&1
p1=$(grep -oE '"agent_pid":  [0-9]+' "$S/win10-h1.txt" | grep -oE '[0-9]+')
p2=$(grep -oE '"agent_pid":  [0-9]+' "$S/win10-h2.txt" | grep -oE '[0-9]+')
sha=$(grep -oE '"bin_sha256":  "[A-F0-9]+"' "$S/win10-h2.txt" | grep -oE '[A-F0-9]{64}')
lc1=$(grep -oE '"log_count":  [0-9]+' "$S/win10-h1.txt" | grep -oE '[0-9]+')
lc2=$(grep -oE '"log_count":  [0-9]+' "$S/win10-h2.txt" | grep -oE '[0-9]+')
log "win10 pid1=$p1 pid2=$p2 sha=${sha:0:8} logs=$lc1/$lc2"
if [ -n "$p1" ] && [ "$p1" = "$p2" ] && [ "$sha" = "$WANT_SHA" ] && [ "$lc1" = "$lc2" ]; then
  log "win10 CRASH-LOOP CHECK PASS"
else
  log "win10 CRASH-LOOP CHECK FAIL"; exit 1
fi
timeout -k 8 150 ./tools/qtest ps "& '$INC\\fire-toast.ps1'" > "$S/win10-toast.txt" 2>&1
sleep 6
timeout -k 8 150 ./tools/qtest ps "& '$INC\\open-start.ps1'" >/dev/null 2>&1
sleep 5
timeout -k 8 90 ./tools/qtest fullshot "$S/win10-full.tar" >/dev/null 2>&1
rm -rf "$S/win10-full"; mkdir -p "$S/win10-full"; tar xf "$S/win10-full.tar" -C "$S/win10-full" 2>/dev/null
cp "$S/win10-full/geometry.txt" "$S/win10-geometry.txt" 2>/dev/null
log "win10 geometry captured"
timeout -k 8 150 ./tools/qtest ps "& '$INC\\toastcrop-debug.ps1'" > "$S/win10-tc.txt" 2>&1
log "win10 toastcrop lines: $(grep -c 'toast card in' "$S/win10-tc.txt")"
timeout -k 8 260 ./tools/qtest ps "& '$INC\\drag-measure.ps1'" > "$S/win10-drag.txt" 2>&1
n=$(grep -c QGAPERF "$S/win10-drag.txt")
timeout -k 8 200 ./tools/qtest ps "& '$INC\\reset-census.ps1'" > "$S/win10-census.txt" 2>&1
ct=$(grep -A1 'cap_timeout' "$S/win10-census.txt" | grep -oE '= [0-9]+' | grep -oE '[0-9]+' | head -1)
log "win10 drag frames=$n cap_timeouts=${ct:-?}"
[ "${ct:-1}" = "0" ] && [ "${n:-0}" -gt 100 ] && log "win10 DRAG CHECK PASS" || log "win10 DRAG CHECK WEAK"
log "win10 cold boot..."
timeout -k 8 90 ./tools/qtest shutdown >/dev/null 2>&1
for i in $(seq 1 24); do echo "$(qstate)" | grep -qi Halted && break; sleep 10; done
timeout -k 8 90 ./tools/qtest start >/dev/null 2>&1
bootwait 15 log || { log "win10 COLD BOOT FAIL"; exit 1; }
./tools/qtest synctime >/dev/null 2>&1
sleep 30
timeout -k 8 150 ./tools/qtest ps "& '$INC\\defect-evidence.ps1'" > "$S/win10-cold.txt" 2>&1
sha=$(grep -oE '"bin_sha256":  "[A-F0-9]+"' "$S/win10-cold.txt" | grep -oE '[A-F0-9]{64}')
pid=$(grep -oE '"agent_pid":  [0-9]+' "$S/win10-cold.txt" | grep -oE '[0-9]+')
[ "$sha" = "$WANT_SHA" ] && [ -n "$pid" ] && log "win10 COLD BOOT PASS (pid=$pid)" || log "win10 COLD BOOT CHECK FAIL"
timeout -k 8 90 ./tools/qtest fullshot "$S/win10-cold.tar" >/dev/null 2>&1
rm -rf "$S/win10-coldex"; mkdir -p "$S/win10-coldex"; tar xf "$S/win10-cold.tar" -C "$S/win10-coldex" 2>/dev/null
timeout -k 8 90 ./tools/qtest shutdown >/dev/null 2>&1
for i in $(seq 1 24); do echo "$(qstate)" | grep -qi Halted && break; sleep 10; done
log "win10 RETRY phase done (left Halted)"
