# Shared E2E helpers with STUCK-DETECTION and TERMINAL-STATE DETECTION. Sourced by run scripts.
#
# REWRITTEN 2026-08-29 after the WIN10 matrix was voided. The defects fixed here are not stylistic;
# each one produced a wrong verdict that was acted on. See FINDINGS 2026-08-29.

# 1. NO DEFAULT TARGET. This used to be `export QTEST_VM="${QTEST_VM:-win11-fresh}"`. A default
#    silently routes a whole run at whatever qube the default names - and the dom0 services refuse
#    an unknown/untagged target by exiting non-zero having written NOTHING, so the caller gets an
#    empty capture that reads exactly like "the guest has no windows". A forgotten export must be a
#    hard stop, not a redirected install.
: "${QTEST_VM:?e2e-lib.sh: set QTEST_VM explicitly - there is deliberately no default target}"
export QTEST_VM

# 2. Keep stderr and the RETURN CODE. `2>/dev/null` made "the call failed" indistinguishable from
#    "the guest answered with nothing", which is the same conflation that turned an empty tar into
#    "no windows". stdout is unchanged for callers; the rc lands in QRC and stderr in QERR.
QRC=0; QERR=''
_q(){ local to=$1; shift
  QERR=$(mktemp); local out rc
  out=$(timeout -k 8 "$to" "$@" 2>"$QERR"); rc=$?
  QRC=$rc
  printf '%s' "$out" | tr -d '\r\0'
  return $rc; }
qstate(){ _q 25 ./tools/qtest state | grep -aoE 'power_state=[A-Za-z]+' | head -1; }
qrun(){   _q 55 ./tools/qtest run "$1"; }
qpr(){    _q 90 ./tools/qtest pushrun "$1"; }
alive(){  qrun 'cmd /c "echo ALIVE"' | grep -aoE ALIVE | head -1; }

# Capture what is ALREADY on screen (the install's cmd window, an error dialog) into per-window
# PNGs, then Read them. Do NOT open a competing window first - that just buries what you want to
# read (real miss: cap opened notepad OVER the failing cmd window). Only if nothing is mapped,
# open notepad so the shot is not empty.
#
# 3. CAPTURE-FAILED, EMPTY and CAPTURED are three different states and are no longer collapsed.
#    "0 PNGs" was being read as "nothing on screen" when it frequently meant the service refused.
_snap(){ # $1=dir $2=label -> echoes "<n>" and sets SNAP_STATE
  local tar="$1/e2e-$2.tar"
  _q 70 ./tools/qtest shot "$tar" >/dev/null
  if [ "$QRC" -ne 0 ] || [ ! -s "$tar" ]; then SNAP_STATE=CAPTURE-FAILED; echo 0; return; fi
  rm -rf "$1/e2e-$2-ex"; mkdir -p "$1/e2e-$2-ex"
  tar xf "$tar" -C "$1/e2e-$2-ex" 2>/dev/null
  local n; n=$(ls "$1/e2e-$2-ex"/*.png 2>/dev/null | wc -l)
  if [ "$n" -eq 0 ]; then SNAP_STATE=EMPTY; else SNAP_STATE=CAPTURED; fi
  echo "$n"; }

cap(){ local S=$1 lbl=$2 R=$3 n
  n=$(_snap "$S" "$lbl")
  if [ "$SNAP_STATE" = EMPTY ]; then
    _q 25 ./tools/qtest run 'cmd /c start "" notepad.exe' >/dev/null; sleep 4
    n=$(_snap "$S" "$lbl"); _q 20 ./tools/qtest run 'cmd /c "taskkill /im notepad.exe /f"' >/dev/null
  fi
  local d; d=$(ls "$S/e2e-$lbl-ex"/*.png 2>/dev/null|head -1|xargs -r file|grep -oE '[0-9]+ x [0-9]+'|head -1)
  echo "[$(date +%H:%M:%S)] [shot] $lbl: $SNAP_STATE $n png ${d}  (READ e2e-$lbl-ex/*.png)" >> "$R"; }

# Classify what is on the guest's largest window: RECOVERY | BLACK | DESKTOP | UNKNOWN | NOSHOT.
# Uses the PER-WINDOW capture, never a whole-desktop one.
# NOTE: the classifier's colour thresholds are validated on synthetic inputs only; fixtures from
# real captures are still owed (plan T2.14). Treat DESKTOP as "something is rendering", not as
# "the install succeeded".
screenverdict(){ # $1=scratchdir $2=label
  local n; n=$(_snap "$1" "$2")
  if [ "$SNAP_STATE" != CAPTURED ]; then echo NOSHOT; return; fi
  local big; big=$(ls -S "$1/e2e-$2-ex"/*.png 2>/dev/null | head -1)
  [ -n "$big" ] || { echo NOSHOT; return; }
  ./tools/winshot.py --png "$big" 2>/dev/null | grep -oE 'VERDICT=[A-Z]+' | cut -d= -f2; }

# 4. Start a run: clear the accumulating install log, VERIFY it is gone, and drop a run marker.
#    clearlog used to fire and discard its result, so a failed delete left a stale log that
#    wait_install then judged - a previous run's FATAL reported as this run's failure.
#    Returns 1 if the log could not be cleared: that is an instrument failure, not a test result.
E2E_RUN_MARKER=''
startrun(){ # $1=logfn
  local logfn=${1:-:}
  E2E_RUN_MARKER="E2ERUN-$(date -u +%Y%m%d%H%M%S)-$$"
  qrun 'cmd /c "del /q /f C:\qwt-improved-install.log 2>nul & echo DELDONE"' | grep -qa DELDONE
  local left; left=$(qrun 'cmd /c "if exist C:\qwt-improved-install.log (echo STILLTHERE) else (echo GONE)"')
  case "$left" in
    *GONE*) ;;
    *) $logfn "  INSTRUMENT FAILURE: install log still present after delete - refusing to run"
       return 1 ;;
  esac
  qrun "cmd /c \"echo $E2E_RUN_MARKER >> C:\\qwt-improved-install.log\"" >/dev/null
  $logfn "  run marker: $E2E_RUN_MARKER"
  return 0; }

# Read only THIS run's portion of the install log.
_logtail(){ qrun 'cmd /c type C:\qwt-improved-install.log 2>nul' | grep -av 'system32>' \
            | { if [ -n "$E2E_RUN_MARKER" ]; then sed -n "/$E2E_RUN_MARKER/,\$p"; else cat; fi; }; }

# 5. STUCK-AWARE boot wait with a RESTART BUDGET and terminal-state detection.
#    It used to kill+restart a Running-but-VMShell-dead guest every ~5 min, forever. That is the
#    prime suspect for turning one interrupted install into an Automatic Repair loop, and it
#    destroys the evidence: a dead guest's state is the only thing that can explain the death.
#    Now: a guest sitting at RECOVERY, or persistently BLACK, is TERMINAL - stop, capture, and
#    leave it alone. At most E2E_RESTART_BUDGET restarts (default 2), then stop regardless.
#    Returns 0 alive, 3 terminal (guest preserved), 1 timed out.
bootwait(){ local m=${1:-15} logfn=${2:-:} S=${3:-.} i dead=0 restarts=0 blackrun=0
  local budget=${E2E_RESTART_BUDGET:-2}
  for i in $(seq 1 $((m*3))); do
    local st; st=$(qstate)
    if echo "$st"|grep -qi Halted; then
      if [ "$restarts" -ge "$budget" ]; then
        $logfn "  TERMINAL: Halted and restart budget ($budget) spent - preserving guest"; return 3; fi
      restarts=$((restarts+1)); $logfn "  halted->start (restart $restarts/$budget)"
      _q 90 ./tools/qtest start >/dev/null; sleep 45; dead=0; continue
    fi
    [ "$(alive)" = ALIVE ] && return 0
    dead=$((dead+1))
    if [ $dead -ge 9 ]; then
      local v; v=$(screenverdict "$S" "bootwait-$i")
      $logfn "  Running+VMShell dead; screen=$v"
      case "$v" in
        RECOVERY) $logfn "  TERMINAL: recovery/repair screen - NOT restarting, guest preserved for diagnosis"
                  return 3 ;;
        BLACK)    blackrun=$((blackrun+1))
                  if [ "$blackrun" -ge 3 ]; then
                    $logfn "  TERMINAL: black for 3 consecutive checks - preserving guest"; return 3; fi ;;
        *)        blackrun=0 ;;
      esac
      if [ "$restarts" -ge "$budget" ]; then
        $logfn "  TERMINAL: restart budget ($budget) spent, still not alive - preserving guest"; return 3; fi
      restarts=$((restarts+1)); $logfn "  STUCK -> kill+restart (restart $restarts/$budget)"
      _q 40 ./tools/qtest kill >/dev/null; sleep 6; _q 90 ./tools/qtest start >/dev/null; sleep 45; dead=0
    fi
    sleep 20
  done; return 1; }

# 6. Wait for the install to END - three explicit exits, never a fall-through.
#    0 = ended (reboot or completed in place), 2 = failed, 1 = STALLED/timed out.
#    PRECONDITION: call startrun BEFORE launching the install.
#
# "Completed in place" is not an edge case any more: since the single-reboot change the installer
# does NOT reboot at the end, so waiting only for Halted would sit here until the timeout on every
# successful install and report it as a hang.
#
# Two traps found 2026-08-25, both in the old guest-side findstr pipeline:
# (1) VMShell ECHOES the command line, whose /C: arguments contain every marker - so the raw
#     transcript ALWAYS matched itself (a run with NO log reported "install FAILED");
# (2) with the echo filtered out it matches NOTHING, because the \"-escaped patterns never survive
#     cmd's parsing inside the piped construction.
# So: no guest-side filtering at all. Pull the whole log and judge HERE.
wait_install(){ local m=${1:-20} logfn=${2:-:} i
  if [ -z "$E2E_RUN_MARKER" ]; then
    $logfn "  INSTRUMENT FAILURE: wait_install called without startrun - a stale log would be judged"
    return 1
  fi
  for i in $(seq 1 $((m*3))); do
    if echo "$(qstate)"|grep -qi Halted; then
      # Halted is ambiguous: a mid-install reboot and a completed install look the same from
      # dom0. Disambiguate by what the log last said before it went down.
      local t; t=$(_logtail)
      if echo "$t" | grep -qiE 'INSTALL COMPLETE|STAGE 2 COMPLETE'; then
        $logfn "  halted after completion"; return 0; fi
      $logfn "  halted (reboot mid-install)"; return 0
    fi
    local tail; tail=$(_logtail)
    if echo "$tail" | grep -qiE 'FATAL|FAILED with|boot disk is on the Xen PV'; then
      $logfn "  install FAILED (detected fast)"; return 2; fi
    if echo "$tail" | grep -qiE 'INSTALL COMPLETE|STAGE 2 COMPLETE'; then
      $logfn "  install completed in place (no final reboot)"; return 0; fi
    sleep 20
  done
  $logfn "  STALLED: no terminal state in ${m}m - this FAILS the phase, it does not fall through"
  return 1; }
