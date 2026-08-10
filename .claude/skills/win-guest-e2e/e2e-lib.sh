# Shared E2E helpers with STUCK-DETECTION and SHOOT-ON-DOUBT. Sourced by run scripts.
export QTEST_VM=win11-fresh
qstate(){ timeout -k 8 25 ./tools/qtest state 2>/dev/null | tr -d '\r\0' | grep -aoE 'power_state=[A-Za-z]+' | head -1; }
qrun(){ timeout -k 8 55 ./tools/qtest run "$1" 2>/dev/null | tr -d '\r\0'; }
qpr(){ timeout -k 8 90 ./tools/qtest pushrun "$1" 2>/dev/null | tr -d '\r\0'; }
alive(){ qrun 'cmd /c "echo ALIVE"' | grep -aoE ALIVE | head -1; }
# capture a labelled screenshot (open notepad so there's a window; log dims; close it)
cap(){ local S=$1 lbl=$2 R=$3
  timeout -k 8 25 ./tools/qtest run 'cmd /c start "" notepad.exe' >/dev/null 2>&1; sleep 5
  timeout -k 8 70 ./tools/qtest shot "$S/e2e-$lbl.tar" >/dev/null 2>&1
  rm -rf "$S/e2e-$lbl-ex"; mkdir -p "$S/e2e-$lbl-ex"; tar xf "$S/e2e-$lbl.tar" -C "$S/e2e-$lbl-ex" 2>/dev/null
  local n d; n=$(ls "$S/e2e-$lbl-ex"/*.png 2>/dev/null|wc -l); d=$(ls "$S/e2e-$lbl-ex"/*.png 2>/dev/null|head -1|xargs -r file|grep -oE '[0-9]+ x [0-9]+'|head -1)
  echo "[$(date +%H:%M:%S)] [shot] $lbl: $n png $d" >> "$R"
  timeout -k 8 20 ./tools/qtest run 'cmd /c "taskkill /im notepad.exe /f"' >/dev/null 2>&1; }
# STUCK-AWARE boot wait: restart on Halted; and if Running-but-VMShell-dead for ~5min
# (lock screen / hung finalize), force kill+restart to unstick it. $1=minutes $2=logfn
bootwait(){ local m=${1:-15} logfn=${2:-:} i dead=0
  for i in $(seq 1 $((m*3))); do
    local st; st=$(qstate)
    if echo "$st"|grep -qi Halted; then $logfn "  halted->start"; timeout -k 8 90 ./tools/qtest start >/dev/null 2>&1; sleep 45; dead=0; continue; fi
    [ "$(alive)" = ALIVE ] && return 0
    dead=$((dead+1))
    if [ $dead -ge 15 ]; then $logfn "  STUCK (Running+VMShell dead ~5m) -> kill+restart"; timeout -k 8 40 ./tools/qtest kill >/dev/null 2>&1; sleep 6; timeout -k 8 90 ./tools/qtest start >/dev/null 2>&1; sleep 45; dead=0; fi
    sleep 20
  done; return 1; }
# wait for a reboot OR a completed-but-failed install (fresh FATAL/Fail in the log, no reboot),
# so a failed install is caught in minutes not after a 30m halt timeout. $1=minutes $2=logfn
wait_install(){ local m=${1:-20} logfn=${2:-:} i
  for i in $(seq 1 $((m*3))); do
    echo "$(qstate)"|grep -qi Halted && { $logfn "  halted (reboot)"; return 0; }
    local tail; tail=$(qrun 'cmd /c "type C:\qwt-improved-install.log 2>nul | findstr /C:\"FATAL\" /C:\"FAILED with\" /C:\"the C: boot disk is on the Xen PV\""')
    if echo "$tail" | grep -qiE 'FATAL|FAILED with|boot disk is on the Xen PV'; then $logfn "  install FAILED (no reboot) - detected fast"; return 2; fi
    sleep 20
  done; return 1; }
