#!/bin/bash
# Release e2e for agent build 83b69f62 on win10-clean then win11-24h2 (serial, bounded).
cd /home/user/qubes-win-idd-driver || exit 1
source .claude/skills/win-guest-e2e/e2e-lib.sh
S=/home/user/qubes-win-idd-driver/scratchpad/e2e
mkdir -p "$S"
R=$S/results.log; : > "$R"
log(){ echo "[$(date +%H:%M:%S)] $*" >>"$R"; }
INC='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
WANT_SHA='83B69F62E532944A548F46C3B3D5DC17738A774FEACBE86E798B1A5A83C99619'

deploy_and_check(){ # $1=vmlabel
  local vm=$1
  timeout -k 8 90 ./tools/qtest push artifacts-fix5/gui-agent.exe guest/swap-agent.ps1 guest/defect-evidence.ps1 guest/fire-toast.ps1 guest/open-start.ps1 guest/toastcrop-debug.ps1 guest/drag-measure.ps1 guest/reset-census.ps1 >/dev/null 2>&1 || { log "$vm push FAIL"; return 1; }
  timeout -k 8 150 ./tools/qtest ps "& '$INC\\swap-agent.ps1' -NewAgent '$INC\\gui-agent.exe'" > "$S/$vm-swap.txt" 2>&1
  grep -q '"ok":  true' "$S/$vm-swap.txt" && log "$vm swap OK" || { log "$vm swap FAIL (see $vm-swap.txt)"; return 1; }
  # crash-loop check: two health probes 80 s apart, same PID, hash matches
  timeout -k 8 150 ./tools/qtest ps "& '$INC\\defect-evidence.ps1'" > "$S/$vm-h1.txt" 2>&1
  sleep 80
  timeout -k 8 150 ./tools/qtest ps "& '$INC\\defect-evidence.ps1'" > "$S/$vm-h2.txt" 2>&1
  local p1 p2 sha lc1 lc2
  p1=$(grep -oE '"agent_pid":  [0-9]+' "$S/$vm-h1.txt" | grep -oE '[0-9]+')
  p2=$(grep -oE '"agent_pid":  [0-9]+' "$S/$vm-h2.txt" | grep -oE '[0-9]+')
  sha=$(grep -oE '"bin_sha256":  "[A-F0-9]+"' "$S/$vm-h2.txt" | grep -oE '[A-F0-9]{64}')
  lc1=$(grep -oE '"log_count":  [0-9]+' "$S/$vm-h1.txt" | grep -oE '[0-9]+')
  lc2=$(grep -oE '"log_count":  [0-9]+' "$S/$vm-h2.txt" | grep -oE '[0-9]+')
  log "$vm pid1=$p1 pid2=$p2 sha=${sha:0:8} logs=$lc1/$lc2"
  [ -n "$p1" ] && [ "$p1" = "$p2" ] && [ "$sha" = "$WANT_SHA" ] && [ "$lc1" = "$lc2" ] \
    && log "$vm CRASH-LOOP CHECK PASS" || { log "$vm CRASH-LOOP CHECK FAIL"; return 1; }
}

surface_checks(){ # $1=vmlabel
  local vm=$1
  timeout -k 8 150 ./tools/qtest ps "& '$INC\\fire-toast.ps1'" > "$S/$vm-toast.txt" 2>&1
  sleep 6
  timeout -k 8 150 ./tools/qtest ps "& '$INC\\open-start.ps1'" > /dev/null 2>&1
  sleep 5
  timeout -k 8 90 ./tools/qtest fullshot "$S/$vm-full.tar" >/dev/null 2>&1
  rm -rf "$S/$vm-full"; mkdir -p "$S/$vm-full"; tar xf "$S/$vm-full.tar" -C "$S/$vm-full" 2>/dev/null
  cp "$S/$vm-full/geometry.txt" "$S/$vm-geometry.txt" 2>/dev/null
  log "$vm geometry: $(grep -c . "$S/$vm-geometry.txt" 2>/dev/null) lines (READ $vm-geometry.txt + $vm-full/screen.png)"
  timeout -k 8 150 ./tools/qtest ps "& '$INC\\toastcrop-debug.ps1'" > "$S/$vm-tc.txt" 2>&1
  grep -c 'toast card in' "$S/$vm-tc.txt" >> /dev/null && log "$vm toastcrop lines: $(grep -c 'toast card in' "$S/$vm-tc.txt")"
}

drag_check(){ # $1=vmlabel
  local vm=$1
  timeout -k 8 260 ./tools/qtest ps "& '$INC\\drag-measure.ps1'" > "$S/$vm-drag.txt" 2>&1
  local n; n=$(grep -c QGAPERF "$S/$vm-drag.txt")
  timeout -k 8 200 ./tools/qtest ps "& '$INC\\reset-census.ps1'" > "$S/$vm-census.txt" 2>&1
  local ct; ct=$(grep -A1 'cap_timeout' "$S/$vm-census.txt" | grep -oE '= [0-9]+' | grep -oE '[0-9]+' | head -1)
  log "$vm drag frames=$n cap_timeouts=${ct:-?}"
  [ "${ct:-1}" = "0" ] && [ "${n:-0}" -gt 100 ] && log "$vm DRAG CHECK PASS" || log "$vm DRAG CHECK WEAK (frames=$n timeouts=$ct)"
}

phase(){ # $1=vm $2=extra-pre (function name or :)
  local vm=$1 pre=$2
  export QTEST_VM=$vm
  log "=== PHASE $vm ==="
  bootwait 15 log || { log "$vm BOOT FAIL"; return 1; }
  ./tools/qtest synctime >/dev/null 2>&1; log "$vm up + clock synced"
  $pre
  deploy_and_check "$vm" || return 1
  surface_checks "$vm"
  drag_check "$vm"
  # cold boot acceptance
  log "$vm cold boot..."
  timeout -k 8 90 ./tools/qtest shutdown >/dev/null 2>&1
  for i in $(seq 1 24); do echo "$(qstate)" | grep -qi Halted && break; sleep 10; done
  timeout -k 8 90 ./tools/qtest start >/dev/null 2>&1
  bootwait 15 log || { log "$vm COLD BOOT FAIL"; return 1; }
  ./tools/qtest synctime >/dev/null 2>&1
  sleep 30
  timeout -k 8 150 ./tools/qtest ps "& '$INC\\defect-evidence.ps1'" > "$S/$vm-cold.txt" 2>&1
  local sha; sha=$(grep -oE '"bin_sha256":  "[A-F0-9]+"' "$S/$vm-cold.txt" | grep -oE '[A-F0-9]{64}')
  local pid; pid=$(grep -oE '"agent_pid":  [0-9]+' "$S/$vm-cold.txt" | grep -oE '[0-9]+')
  [ "$sha" = "$WANT_SHA" ] && [ -n "$pid" ] && log "$vm COLD BOOT PASS (pid=$pid)" || log "$vm COLD BOOT CHECK FAIL"
  timeout -k 8 90 ./tools/qtest fullshot "$S/$vm-cold.tar" >/dev/null 2>&1
  rm -rf "$S/$vm-coldex"; mkdir -p "$S/$vm-coldex"; tar xf "$S/$vm-cold.tar" -C "$S/$vm-coldex" 2>/dev/null
  # leave halted so guests never overlap
  timeout -k 8 90 ./tools/qtest shutdown >/dev/null 2>&1
  for i in $(seq 1 24); do echo "$(qstate)" | grep -qi Halted && break; sleep 10; done
  log "$vm phase done (left Halted)"
}

pre24h2(){
  timeout -k 8 60 ./tools/qtest run 'reg delete "HKLM\SOFTWARE\Invisible Things Lab\Qubes Tools\gui-agent" /v ToastCropDisable /f' >/dev/null 2>&1
  log "win11-24h2 ToastCropDisable removed"
}

phase win10-clean : || log "WIN10 PHASE FAILED"
phase win11-24h2 pre24h2 || log "24H2 PHASE FAILED"
log "=== E2E RUN COMPLETE ==="
