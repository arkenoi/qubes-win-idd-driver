# Shared E2E helpers with STUCK-DETECTION and SHOOT-ON-DOUBT. Sourced by run scripts.
export QTEST_VM=win11-fresh
qstate(){ timeout -k 8 25 ./tools/qtest state 2>/dev/null | tr -d '\r\0' | grep -aoE 'power_state=[A-Za-z]+' | head -1; }
qrun(){ timeout -k 8 55 ./tools/qtest run "$1" 2>/dev/null | tr -d '\r\0'; }
qpr(){ timeout -k 8 90 ./tools/qtest pushrun "$1" 2>/dev/null | tr -d '\r\0'; }
alive(){ qrun 'cmd /c "echo ALIVE"' | grep -aoE ALIVE | head -1; }
# Capture what is ALREADY on screen (the install's cmd window, an error dialog) into per-window
# PNGs, then Read them. Do NOT open a competing window first - that just buries what you want to
# read (real miss: cap opened notepad OVER the failing cmd window). Only if nothing is mapped,
# open notepad so the shot is not empty.
_snap(){ timeout -k 8 70 ./tools/qtest shot "$1/e2e-$2.tar" >/dev/null 2>&1
  rm -rf "$1/e2e-$2-ex"; mkdir -p "$1/e2e-$2-ex"; tar xf "$1/e2e-$2.tar" -C "$1/e2e-$2-ex" 2>/dev/null
  ls "$1/e2e-$2-ex"/*.png 2>/dev/null | wc -l; }
cap(){ local S=$1 lbl=$2 R=$3 n; n=$(_snap "$S" "$lbl")
  if [ "$n" -eq 0 ]; then
    timeout -k 8 25 ./tools/qtest run 'cmd /c start "" notepad.exe' >/dev/null 2>&1; sleep 4
    n=$(_snap "$S" "$lbl"); timeout -k 8 20 ./tools/qtest run 'cmd /c "taskkill /im notepad.exe /f"' >/dev/null 2>&1
  fi
  local d; d=$(ls "$S/e2e-$lbl-ex"/*.png 2>/dev/null|head -1|xargs -r file|grep -oE '[0-9]+ x [0-9]+'|head -1)
  echo "[$(date +%H:%M:%S)] [shot] $lbl: $n png ${d}  (READ e2e-$lbl-ex/*.png)" >> "$R"; }
# Delete the ACCUMULATING install log before each install so wait_install / RESULT reads see only
# THIS run - a stale log makes fast-fail fire on the previous run's error (rule 8).
clearlog(){ timeout -k 8 25 ./tools/qtest run 'cmd /c "del /q /f C:\qwt-improved-install.log 2>nul"' >/dev/null 2>&1; }
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
# wait for the install to END - by a reboot, by finishing in place, or by failing.
# $1=minutes $2=logfn.  0 = ended (reboot or completed), 2 = failed, 1 = timed out.
# PRECONDITION: call clearlog BEFORE launching the install, or this fires on a PRIOR run's error.
#
# "Completed in place" is not an edge case any more: since the single-reboot change the
# installer does NOT reboot at the end, so waiting only for Halted would sit here until the
# timeout on every successful install and report it as a hang.
wait_install(){ local m=${1:-20} logfn=${2:-:} i
  for i in $(seq 1 $((m*3))); do
    echo "$(qstate)"|grep -qi Halted && { $logfn "  halted (reboot)"; return 0; }
    # VMShell ECHOES the command line into the transcript, and the findstr arguments contain
    # every marker being searched for - so the raw output ALWAYS matches its own echo (found
    # 2026-08-25: a run with NO install log at all reported "install FAILED"). Strip the echoed
    # command (the only line containing 'findstr') before judging.
    local tail; tail=$(qrun 'cmd /c "type C:\qwt-improved-install.log 2>nul | findstr /C:\"FATAL\" /C:\"FAILED with\" /C:\"the C: boot disk is on the Xen PV\" /C:\"INSTALL COMPLETE\" /C:\"STAGE 2 COMPLETE\""' | grep -av findstr)
    if echo "$tail" | grep -qiE 'FATAL|FAILED with|boot disk is on the Xen PV'; then $logfn "  install FAILED (no reboot) - detected fast"; return 2; fi
    if echo "$tail" | grep -qiE 'INSTALL COMPLETE|STAGE 2 COMPLETE'; then $logfn "  install completed in place (no final reboot)"; return 0; fi
    sleep 20
  done; return 1; }
