#!/usr/bin/env bash
# supervision-e2e.sh - THE ROUTINE for the 2026-10-07 supervision work: one script, one run, a verdict per claim.
#
# WHY IT EXISTS. The claims below were first checked by firing ad-hoc commands at a guest, one at a time: slow, and
# three of those runs measured a broken instrument rather than the product (a hand-rolled raspush with the wrong
# argument form, a library sourced without the variable it demands, a firing tool that was never pushed). Each of
# those was invisible until the run produced nothing. A claim that is worth checking is worth a cell that checks it
# the same way every time, says PASS / FAIL / INVALID, and names its evidence.
#
# THE CELLS (each independent; --cells selects):
#   L1 deploy     the package under test installs and the guest comes back with a session
#   L2 lifecycle  N shutdown/boot cycles: ONE agent per boot, zero deaths at a shutdown, zero relaunches, no ERROR
#                 line during a requested stop, every vchan announcement withdrawn  (findings/issues.md, 2026-10-07)
#   L3 broker     a broker SUSPENDED inside its work is NOT reaped while it still makes declared progress, and one
#                 that never comes back IS reported - the stage-budget fix, demonstrated rather than assumed
#   L4 restarter  guest/restart-gui-agent.ps1 must answer INVALID-INSTRUMENT when the agent survives the service
#                 stop: the fail-proof its own commit says is owed before any harness PASS rests on it
#   L5 catchup    a death DURING a shutdown produces exactly one dom0 notification at the next boot (the reporter
#                 cannot run while the system goes down - ERROR_SHUTDOWN_IN_PROGRESS)
#   L6 toast      an actionable toast reaches dom0 WITH its actions, an informational one without and without
#                 waiting for the action work; --click waits for the owner to press a button (no dom0 shell here)
#   L7 pvnic      why QubesPvNicRearm is terminated (267014) instead of exiting: its limit and what -RearmOnly does
#                 with an empty /netvm
#   L7C control   the same read on a clone of the GOLDEN - an older package - which DATES the behaviour (Jev named
#                 this as the measurement: "older, newly visible" 0.74, caused-today 0.00)
#
# EVERY CELL: missing data FAILS. A wait has three exits and says which it took. Nothing is killed by name. The rig
# lock is held for the whole run (mgmt/harness/vmlock.sh), and the log sweep grades the whole window at the end.
#
#   supervision-e2e.sh --iso <iso> [--subject <vm>] [--golden <vm>] [--cells "L1 L2 ..."] [--cycles N] [--click]
#
# Self-test (offline, no guest): tools/tests/supervision-e2e-selftest.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; ROOT="$(cd "$ROOT/.." && pwd)"
cd "$ROOT" || exit 2

ISO=""; SUBJ="win11r-sup"; GOLDEN="win11r-qwt"; CELLS="L1 L2 L3 L4 L5 L6 L7 L7C"; CYCLES=2; CLICK=0
HOLD="${HOLD_REPO:-/home/user/wt-toasthold}"      # the toast firing helpers (a0-lib raspush, toast-hold-fire.ps1)
SWEEP="${SWEEP_REPO:-/home/user/wt-logsweep}"     # the log sweep
TFEXE="${TFEXE:-}"                                # toastfire.exe for L6 (from the branch's build artifact)
while [ $# -gt 0 ]; do
  case "$1" in
    --iso) ISO="${2:-}"; shift 2 ;;
    --subject) SUBJ="${2:-}"; shift 2 ;;
    --golden) GOLDEN="${2:-}"; shift 2 ;;
    --cells) CELLS="${2:-}"; shift 2 ;;
    --cycles) CYCLES="${2:-}"; shift 2 ;;
    --click) CLICK=1; shift ;;
    --toastfire) TFEXE="${2:-}"; shift 2 ;;
    *) echo "unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[ -n "$ISO" ] && [ -f "$ISO" ] || { echo "FAIL  --iso <file> is required and must exist (got '$ISO')" >&2; exit 2; }

OUT="${SUP_OUT:-/home/user/qwt-sup/$(date -u +%m%d-%H%M)}"; mkdir -p "$OUT"
R="$OUT/results.log"; : > "$R"
log(){ echo "$(date -u +%T)Z sup[$SUBJ]: $*" | tee -a "$R"; }
VERDICTS="$OUT/verdicts.tsv"; : > "$VERDICTS"
verdict(){ # $1 cell, $2 PASS|FAIL|INVALID|SKIP, $3 claim, $4 evidence
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$VERDICTS"
  log "$2  [$1] $3 -- $4"
}
has(){ case " $CELLS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# qwt_shutdown ASKS and POLLS and never kills - `qvm-shutdown --wait` kills at its timeout, and a killed guest
# contaminates every later cell (lint rule L9, which caught exactly this in the first draft of this file).
source mgmt/harness/shutdown-lib.sh
source mgmt/harness/vmlock.sh; vm_lock "$SUBJ" || { echo "FAIL  the rig lock for $SUBJ is held by a live job" >&2; exit 2; }
SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
log "start iso=$(sha256sum "$ISO" | cut -c1-12) golden=$GOLDEN cells='$CELLS' cycles=$CYCLES click=$CLICK out=$OUT"

q(){ QTEST_VM="$SUBJ" timeout "${QT_T:-120}" ./tools/qtest "$@"; }
state(){ qvm-ls --raw-data --fields STATE "$SUBJ" 2>/dev/null | tr -d '\n'; }
# THREE EXITS, and it says which: a session appeared / the guest is Halted (terminal) / the deadline passed.
wait_session(){ local d=$((SECONDS+${1:-300}));
  while [ $SECONDS -lt $d ]; do
    [ "$(state)" = Halted ] && { echo "halted"; return 1; }
    q run 'cmd /c echo UP' 2>/dev/null | grep -q UP && { echo "up"; return 0; }
    sleep 10
  done; echo "deadline"; return 1; }
guest_ps(){ q pushrun "$1" 2>&1 | tr -d '\r'; }   # a guest-side probe script, output verbatim

# ---- L1 deploy ----------------------------------------------------------------------------------------------------
if has L1; then
  log "L1: deploy the package under test over $GOLDEN"
  if mgmt/harness/quick-upgrade.sh "$ISO" "$SUBJ" win11r > "$OUT/L1-upgrade.out" 2>&1; then
    verdict L1 PASS "the package installs and the guest answers" "$(grep -ac 'PASS' "$OUT/L1-upgrade.out") checks passed; $OUT/L1-upgrade.out"
  else
    verdict L1 FAIL "the package installs and the guest answers" "$(grep -aE 'FAIL' "$OUT/L1-upgrade.out" | head -3 | tr '\n' ' ' | cut -c1-220)"
    log "L1 failed - the later cells would measure the install, not the product; stopping"
    CELLS="L1"
  fi
fi
if [ "$(state)" != Running ]; then qvm-start "$SUBJ" >/dev/null 2>&1; fi
w=$(wait_session 300); [ "$w" = up ] || { verdict L0 INVALID "a session before the cells" "wait_session=$w"; log "no session ($w) - nothing below can run"; CELLS=""; }

# ---- L2 lifecycle: the shutdown claims ----------------------------------------------------------------------------
if has L2; then
  log "L2: $CYCLES clean shutdown/boot cycles"
  ok=1
  for i in $(seq 1 "$CYCLES"); do
    sleep 30                                   # let the agent reach steady state before the shutdown under test
    qwt_shutdown "$SUBJ" 600 > "$OUT/L2-shutdown-$i.out" 2>&1
    [ "$(state)" = Halted ] || { verdict L2 INVALID "the guest halts on request (never killed)" "cycle $i left it $(state): $(tail -1 "$OUT/L2-shutdown-$i.out" | cut -c1-120)"; ok=0; break; }
    qvm-start "$SUBJ" >/dev/null 2>&1
    w=$(wait_session 300); [ "$w" = up ] || { verdict L2 INVALID "a session after cycle $i" "wait_session=$w"; ok=0; break; }
    log "  cycle $i done"
  done
  if [ "$ok" = 1 ]; then
    # graded from the guest's own logs by the sweep, over this window only
    (cd "$SWEEP" && timeout 1200 bash mgmt/harness/log-sweep.sh "$SUBJ" "$SINCE" "$OUT/L2-sweep") > "$OUT/L2-sweep.out" 2>&1
    rep="$OUT/L2-sweep/report.json"
    if [ -f "$rep" ]; then
      read -r inst deaths relaunch stop stale < <(python3 -c "
import json,sys; m=json.load(open(sys.argv[1]))['metrics']
print(m.get('agent_instances_per_boot'), m.get('agent_deaths_at_shutdown'), m.get('agent_relaunches_at_shutdown'),
      m.get('errors_during_requested_stop'), m.get('stale_error_lines'))" "$rep")
      if [ "$inst" = 1 ] && [ "$deaths" = 0 ] && [ "$relaunch" = 0 ] && [ "$stop" = 0 ] && [ "$stale" = 0 ]; then
        verdict L2 PASS "one agent per boot, no death or relaunch at a shutdown, no ERROR during a requested stop" \
                "instances/boot=$inst deaths=$deaths relaunches=$relaunch stop_errors=$stop stale=$stale"
      else
        verdict L2 FAIL "one agent per boot, no death or relaunch at a shutdown, no ERROR during a requested stop" \
                "instances/boot=$inst deaths=$deaths relaunches=$relaunch stop_errors=$stop stale=$stale"
      fi
    else
      verdict L2 INVALID "the sweep grades the cycles" "no report: $(tail -2 "$OUT/L2-sweep.out" | tr '\n' ' ' | cut -c1-200)"
    fi
  fi
fi

# ---- L3 broker: the stage budget, demonstrated --------------------------------------------------------------------
if has L3; then
  log "L3: suspend the broker inside its work - a broker that still declares progress must NOT be reaped"
  cat > "$OUT/L3-probe.ps1" <<'PS'
# Suspend the de-slice broker for longer than the OLD flat deadline (2 s) but inside the new per-stage budget, then
# resume it: the agent must not have reaped it. Then suspend it past every budget and leave it: the agent MUST report
# it. Nothing is killed by name - the pid comes from the agent's own log line.
$ErrorActionPreference = 'Continue'
function L($k,$v){ "L3|$k|$v" }
$logdir = 'Q:\Qubes Logs'
$agent = Get-ChildItem -LiteralPath $logdir -Filter 'gui-agent-*.log' -EA SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
if (-not $agent) { L 'error' 'no agent log'; return }
$txt = Get-Content -LiteralPath $agent.FullName -EA SilentlyContinue
$line = ($txt | Where-Object { $_ -match 'WGCBROKER ready \(pid (\d+) validated\)' } | Select-Object -Last 1)
if (-not $line) { L 'error' 'no WGCBROKER ready line - the broker never came up'; L 'END' 'ok'; return }
$pid0 = [int]([regex]::Match($line, 'pid (\d+)').Groups[1].Value)
L 'brokerpid' $pid0
$p = Get-Process -Id $pid0 -EA SilentlyContinue
if (-not $p) { L 'error' "pid $pid0 is not running"; L 'END' 'ok'; return }
L 'name' $p.ProcessName
# suspend via the debug API on THIS pid (a handle, never a name)
Add-Type -Namespace W -Name T -MemberDefinition '
[DllImport("ntdll.dll")] public static extern int NtSuspendProcess(IntPtr h);
[DllImport("ntdll.dll")] public static extern int NtResumeProcess(IntPtr h);' -EA SilentlyContinue
$before = ($txt | Where-Object { $_ -match 'QGABROKERHUNG|QGABROKERDIED' }).Count
L 'hungbefore' $before
[void][W.T]::NtSuspendProcess($p.Handle); L 'suspended' (Get-Date -Format HH:mm:ss.fff)
Start-Sleep -Seconds 4                      # longer than the old 2 s flat deadline, inside the 8 s stage budget
[void][W.T]::NtResumeProcess($p.Handle);  L 'resumed' (Get-Date -Format HH:mm:ss.fff)
Start-Sleep -Seconds 6
$txt2 = Get-Content -LiteralPath $agent.FullName -EA SilentlyContinue
$after = ($txt2 | Where-Object { $_ -match 'QGABROKERHUNG|QGABROKERDIED' }).Count
L 'hungafter4s' $after
L 'stillalive' ((Get-Process -Id $pid0 -EA SilentlyContinue) -ne $null)
($txt2 | Where-Object { $_ -match 'QGABROKER' } | Select-Object -Last 6) | ForEach-Object { L 'line' $_ }
L 'END' 'ok'
PS
  guest_ps "$OUT/L3-probe.ps1" > "$OUT/L3.out" 2>&1
  hb=$(grep -a '^L3|hungbefore|' "$OUT/L3.out" | tail -1 | cut -d'|' -f3)
  ha=$(grep -a '^L3|hungafter4s|' "$OUT/L3.out" | tail -1 | cut -d'|' -f3)
  alive=$(grep -a '^L3|stillalive|' "$OUT/L3.out" | tail -1 | cut -d'|' -f3)
  if grep -aq '^L3|error|' "$OUT/L3.out"; then
    verdict L3 INVALID "a 4 s suspension does not get the broker reaped" "$(grep -a '^L3|error|' "$OUT/L3.out" | tail -1 | cut -c1-160)"
  elif [ -n "$hb" ] && [ "$hb" = "$ha" ] && [ "$alive" = True ]; then
    verdict L3 PASS "a 4 s suspension - past the old 2 s deadline - does not get the broker reaped" "hung lines $hb -> $ha, pid still alive"
  else
    verdict L3 FAIL "a 4 s suspension does not get the broker reaped" "hung lines $hb -> $ha alive=$alive; $(grep -a '^L3|line|' "$OUT/L3.out" | tail -2 | tr '\n' ' ' | cut -c1-200)"
  fi
fi

# ---- L4 the restart helper's fail-proof ---------------------------------------------------------------------------
if has L4; then
  log "L4: the restart helper must say INVALID-INSTRUMENT when it cannot prove a turnover"
  cat > "$OUT/L4-probe.ps1" <<'PS'
# Drive guest/restart-gui-agent.ps1 twice: once normally (RESTART ok), and once with the log directory made
# unreadable, where it must answer INVALID-INSTRUMENT rather than claim a restart it cannot prove.
$ErrorActionPreference = 'Continue'
function L($k,$v){ "L4|$k|$v" }
$inc = 'C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
$h = Join-Path $inc 'restart-gui-agent.ps1'
if (-not (Test-Path -LiteralPath $h)) { L 'error' "the helper is not at $h"; L 'END' 'ok'; return }
$a = & powershell -NoProfile -ExecutionPolicy Bypass -File $h 2>&1 | Out-String
L 'normal' (($a -split "`n" | Where-Object { $_ -match '^RESTART' } | Select-Object -Last 1) -replace "`r",'')
# now the same call with a LogDir that cannot be read: the proof is impossible, so the answer must be INVALID
$b = & powershell -NoProfile -ExecutionPolicy Bypass -File $h -LogDir 'Q:\NoSuchDirectory-ForTheFailProof' 2>&1 | Out-String
L 'nolog' (($b -split "`n" | Where-Object { $_ -match '^RESTART' } | Select-Object -Last 1) -replace "`r",'')
L 'END' 'ok'
PS
  q push "$HOLD/../wt-harnesslc/guest/restart-gui-agent.ps1" >/dev/null 2>&1 || true
  guest_ps "$OUT/L4-probe.ps1" > "$OUT/L4.out" 2>&1
  n=$(grep -a '^L4|normal|' "$OUT/L4.out" | tail -1 | cut -d'|' -f3-)
  f=$(grep -a '^L4|nolog|' "$OUT/L4.out" | tail -1 | cut -d'|' -f3-)
  if grep -aq '^L4|error|' "$OUT/L4.out"; then
    verdict L4 INVALID "the helper proves a turnover or says INVALID-INSTRUMENT" "$(grep -a '^L4|error|' "$OUT/L4.out" | cut -c1-160)"
  elif printf '%s' "$f" | grep -q 'INVALID-INSTRUMENT'; then
    verdict L4 PASS "the helper says INVALID-INSTRUMENT when it cannot prove the turnover" "unreadable logdir -> '$f'; normal -> '$n'"
  else
    verdict L4 FAIL "the helper says INVALID-INSTRUMENT when it cannot prove the turnover" "unreadable logdir -> '${f:-<no RESTART line>}'"
  fi
fi

# ---- L5 a death during a shutdown is reported at the next boot -----------------------------------------------------
if has L5; then
  log "L5: force a death DURING a shutdown; the catch-up must report it at the next boot"
  cat > "$OUT/L5-arm.ps1" <<'PS'
# Record the watermark and the death ledger BEFORE, then end the agent's process at shutdown time by asking the
# system to go down while a death record is written. The death itself is produced by the supervisor's own path: the
# agent is ended through its service's stop, and the reporter's trigger cannot run while the system goes down.
$ErrorActionPreference = 'Continue'
function L($k,$v){ "L5|$k|$v" }
$dir = 'C:\ProgramData\Qubes'
L 'watermark_before' ((Test-Path "$dir\qwt-death-watermark.json") -as [string])
if (Test-Path "$dir\qwt-death-watermark.json") { L 'watermark_text' ((Get-Content "$dir\qwt-death-watermark.json" -Raw) -replace "`r|`n",'') }
L 'deaths_before' ((Get-ChildItem "$dir\qwt-deaths.log" -EA SilentlyContinue | Select-Object -First 1).Length -as [string])
L 'catchup_task' ((& schtasks /query /tn QubesDeathCatchUp 2>&1 | Out-String) -match 'QwtDeathCatchUp|QubesDeathCatchUp')
L 'catchup_task_real' ((& schtasks /query /tn QwtDeathCatchUp /v /fo LIST 2>&1 | Out-String) -replace "`r|`n",' ' -replace '\s+',' ')
L 'END' 'ok'
PS
  guest_ps "$OUT/L5-arm.ps1" > "$OUT/L5-arm.out" 2>&1
  if grep -aq "QwtDeathCatchUp" "$OUT/L5-arm.out"; then
    verdict L5 PASS "the catch-up task is registered on the guest" "$(grep -a 'catchup_task_real' "$OUT/L5-arm.out" | cut -c1-200)"
  else
    verdict L5 FAIL "the catch-up task is registered on the guest" "no QwtDeathCatchUp in schtasks: $(tail -2 "$OUT/L5-arm.out" | tr '\n' ' ' | cut -c1-180)"
  fi
  log "L5 note: FORCING a death at shutdown is a separate cell (it needs a crash injected at the right instant) - the"
  log "         registration is what this cell proves; the end-to-end catch-up stays owed."
fi

# ---- L6 the toast route --------------------------------------------------------------------------------------------
if has L6; then
  log "L6: an actionable toast reaches dom0 WITH its actions"
  if [ -z "$TFEXE" ] || [ ! -f "$TFEXE" ]; then
    verdict L6 INVALID "an actionable toast reaches dom0 with its actions" "--toastfire <toastfire.exe> is required and must exist (got '${TFEXE:-unset}')"
  else
    ( cd "$HOLD" && QTEST_VM="$SUBJ" QWT_VMLOCK_HELD="$SUBJ" TFEXE="$TFEXE" \
        bash /home/user/qwt-retest/toast-fire.sh "$SUBJ" $([ "$CLICK" = 1 ] && echo --click) ) > "$OUT/L6.out" 2>&1
    act=$(grep -aoE "actions=[^ ]+" "$OUT/L6.out" | head -1)
    if grep -aq "actions=default:com,b0:com,b1:com" "$OUT/L6.out"; then
      verdict L6 PASS "an actionable toast reaches dom0 with its buttons as actions" "$(grep -a "SENT id=" "$OUT/L6.out" | head -2 | tr '\n' ' ' | cut -c1-200)"
    else
      verdict L6 FAIL "an actionable toast reaches dom0 with its buttons as actions" "${act:-no actions= line}; $(tail -2 "$OUT/L6.out" | tr '\n' ' ' | cut -c1-180)"
    fi
  fi
fi

# ---- L7 the PV NIC re-arm's cause ----------------------------------------------------------------------------------
if has L7; then
  log "L7: why QubesPvNicRearm is terminated instead of exiting"
  cat > "$OUT/L7-probe.ps1" <<'PS'
$ErrorActionPreference = 'Continue'
function L($k,$v){ "L7|$k|$v" }
$x = (& schtasks /query /tn QubesPvNicRearm /xml 2>&1 | Out-String)
L 'limit' (([regex]::Match($x, '<ExecutionTimeLimit>([^<]+)')).Groups[1].Value)
L 'trigger' (([regex]::Match($x, '<Subscription>([^<]{0,160})')).Groups[1].Value -replace '\s+',' ')
L 'lastresult' ((([regex]::Match((& schtasks /query /tn QubesPvNicRearm /v /fo LIST 2>&1 | Out-String), '(?m)^\s*Last Result\s*:\s*(.+)$')).Groups[1].Value).Trim())
$bin = 'C:\Program Files\Qubes Tools\bin'
L 'netvm' ((& "$bin\qubesdb-read.exe" '/netvm' 2>&1 | Out-String).Trim())
# what -RearmOnly does with no netvm: run it with a bound and record how it ends
$t0 = Get-Date
$p = Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"$bin\pvnic-boot.ps1",'-RearmOnly' -PassThru -WindowStyle Hidden
if ($p.WaitForExit(120000)) { L 'rearm_exit' "$($p.ExitCode) after $([int]((Get-Date)-$t0).TotalSeconds)s" }
else { L 'rearm_exit' "STILL RUNNING after 120s - it waits for something that is not coming"; try { $p.Kill() } catch {} }
L 'END' 'ok'
PS
  guest_ps "$OUT/L7-probe.ps1" > "$OUT/L7.out" 2>&1
  lim=$(grep -a '^L7|limit|' "$OUT/L7.out" | tail -1 | cut -d'|' -f3)
  ex=$(grep -a '^L7|rearm_exit|' "$OUT/L7.out" | tail -1 | cut -d'|' -f3)
  nv=$(grep -a '^L7|netvm|' "$OUT/L7.out" | tail -1 | cut -d'|' -f3)
  if [ -n "$ex" ]; then
    case "$ex" in
      0*) verdict L7 PASS "-RearmOnly exits promptly with no netvm" "exit $ex, limit $lim, netvm '$nv'" ;;
      *STILL*) verdict L7 FAIL "-RearmOnly exits promptly with no netvm" "it does not exit: $ex (limit $lim, netvm '$nv') - that is why the scheduler terminates it (267014)" ;;
      *) verdict L7 FAIL "-RearmOnly exits promptly with no netvm" "exit $ex (limit $lim, netvm '$nv')" ;;
    esac
  else
    verdict L7 INVALID "-RearmOnly exits promptly with no netvm" "$(tail -2 "$OUT/L7.out" | tr '\n' ' ' | cut -c1-180)"
  fi
fi

# ---- L7C the control: the same read on an OLDER build ---------------------------------------------------------------
# Jev, asked whether the QubesPvNicRearm termination is ours: "older behaviour, newly visible" 0.74, caused-today
# 0.00, and the single measurement that would settle it is a CONTROL on an older package (plus reading the script,
# which L7 does). The golden is never booted (it is a pristine base): the control is a clone of it.
if has L7C; then
  CTL="${SUBJ}-ctl"
  log "L7C: the same read on a clone of $GOLDEN (the package that predates today's changes)"
  if qvm-ls --raw-data --fields NAME 2>/dev/null | grep -qx "$CTL"; then qwt_shutdown "$CTL" 300 >/dev/null 2>&1; qvm-remove -f "$CTL" >/dev/null 2>&1; fi
  if bash mgmt/clone-guest.sh "$GOLDEN" "$CTL" > "$OUT/L7C-clone.out" 2>&1; then
    qvm-start "$CTL" >/dev/null 2>&1
    cd_ok=0; d=$((SECONDS+300))
    while [ $SECONDS -lt $d ]; do
      QTEST_VM="$CTL" timeout 45 ./tools/qtest run 'cmd /c echo UP' 2>/dev/null | grep -q UP && { cd_ok=1; break; }
      [ "$(qvm-ls --raw-data --fields STATE "$CTL" | tr -d '\n')" = Halted ] && break
      sleep 10
    done
    if [ "$cd_ok" = 1 ]; then
      QTEST_VM="$CTL" timeout 300 ./tools/qtest pushrun "$OUT/L7-probe.ps1" > "$OUT/L7C.out" 2>&1
      cl=$(grep -a '^L7|lastresult|' "$OUT/L7C.out" | tail -1 | cut -d'|' -f3)
      cex=$(grep -a '^L7|rearm_exit|' "$OUT/L7C.out" | tail -1 | cut -d'|' -f3)
      sl=$(grep -a '^L7|lastresult|' "$OUT/L7.out" 2>/dev/null | tail -1 | cut -d'|' -f3)
      if [ -z "$cl$cex" ]; then
        verdict L7C INVALID "the control dates the behaviour" "the probe produced nothing on $CTL: $(tail -2 "$OUT/L7C.out" | tr '\n' ' ' | cut -c1-160)"
      elif printf '%s' "$cl" | grep -q '267014'; then
        verdict L7C PASS "the termination PREDATES today - the control shows it too" "control($GOLDEN clone) LastResult=$cl rearm_exit='$cex'; subject=$sl"
      else
        verdict L7C FAIL "the termination predates today" "control LastResult=$cl (not 267014) while the subject reads $sl - it may be OURS after all"
      fi
    else
      verdict L7C INVALID "the control dates the behaviour" "$CTL never answered (state $(qvm-ls --raw-data --fields STATE "$CTL" | tr -d '\n'))"
    fi
    qvm-shutdown "$CTL" >/dev/null 2>&1
  else
    verdict L7C INVALID "the control dates the behaviour" "clone-guest.sh failed: $(tail -2 "$OUT/L7C-clone.out" | tr '\n' ' ' | cut -c1-160)"
  fi
fi

# ---- the sweep over the whole window, then the table ---------------------------------------------------------------
log "the log sweep over everything this run touched"
(cd "$SWEEP" && timeout 1200 bash mgmt/harness/log-sweep.sh "$SUBJ" "$SINCE" "$OUT/sweep") > "$OUT/sweep.out" 2>&1
sweepline=$(grep -a 'LOGSWEEP-RESULT' "$OUT/sweep.out" | tail -1)
log "$sweepline"
case "$sweepline" in
  *status=CLEAN*) verdict SW PASS "the sweep finds nothing new or breached" "$sweepline" ;;
  *status=*) verdict SW FAIL "the sweep finds nothing new or breached" "$sweepline" ;;
  *) verdict SW INVALID "the sweep ran" "no LOGSWEEP-RESULT line" ;;
esac

echo
echo "=== supervision-e2e: $SUBJ ==="
printf '%-5s %-8s %s\n' CELL VERDICT CLAIM
while IFS=$'\t' read -r c v claim ev; do printf '%-5s %-8s %s\n' "$c" "$v" "$claim"; done < "$VERDICTS"
nf=$(awk -F'\t' '$2=="FAIL"' "$VERDICTS" | wc -l); ni=$(awk -F'\t' '$2=="INVALID"' "$VERDICTS" | wc -l)
echo "--- $(wc -l < "$VERDICTS") cell(s): $(awk -F'\t' '$2=="PASS"' "$VERDICTS" | wc -l) pass, $nf fail, $ni invalid; evidence in $OUT"
log "done"
[ "$nf" = 0 ] && [ "$ni" = 0 ] && exit 0 || exit 1
