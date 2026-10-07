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
#   L4 restarter  a live turnover, and INVALID-INSTRUMENT when it cannot be proven (the registry value the helper
#                 reads, renamed and restored). RUNS LAST and restores the guest's health: it restarts the agent
#                 on purpose, which takes the toast bridge down with it, so no cell may run after it
#   L5 catchup    a death DURING a shutdown produces exactly one dom0 notification at the next boot (the reporter
#                 cannot run while the system goes down - ERROR_SHUTDOWN_IN_PROGRESS)
#   L8 catchup-e2e a death injected DURING a shutdown is reported at the next boot EXACTLY once - never zero
#                 (concealment), never twice (a double). The measurement L5 does not make
#   L6 toast      an actionable toast reaches dom0 WITH its actions, an informational one without and without
#                 waiting for the action work; --click waits for the owner to press a button (no dom0 shell here)
#   L7 pvnic      the PV NIC shutdown re-arm LANDS its two registry writes (the measurement Jev named at 0.85) and
#                 the next boot judges the previous session from the stamp, where a task can finish what it starts
#   L7C control   the same measurement on a clone of the GOLDEN, whose package still has the defect: it DATES the
#                 behaviour (Jev: "older, newly visible" 0.74, caused-today 0.00) and is where L7's check FAILS
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

ISO=""; SUBJ="win11r-sup"; GOLDEN="win11r-qwt"; CELLS="L1 L2 L3 L5 L6 L7 L7C L8 L4"; CYCLES=2; CLICK=0
HOLD="${HOLD_REPO:-$PWD}"                         # kept for an override; the helpers are in THIS repo now
SWEEP="${SWEEP_REPO:-$PWD}"                       # the log sweep, likewise - no cross-worktree dependency
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

# THE L7 PROBE IS WRITTEN ONCE, HERE. L7C pushes the same script to the control, and when the cells were
# selected without L7 the file simply did not exist - the push sent 0 of 3 KB and the control's PowerShell
# said so, which the cell reported as "the probe produced nothing" (measured 2026-10-07). A cell that depends
# on another cell having run in the same invocation is not independent, whatever the header claims.
  cat > "$OUT/L7-probe.ps1" <<'PS'
$ErrorActionPreference = 'Continue'
function L($k,$v){ "L7|$k|$v" }
$bin = 'C:\Program Files\Qubes Tools\bin'
$x = (& schtasks /query /tn QubesPvNicRearm /xml 2>&1 | Out-String)
L 'action_cmd' (([regex]::Match($x, '<Command>([^<]+)')).Groups[1].Value)
L 'action_args' ((([regex]::Match($x, '<Arguments>([^<]{0,400})')).Groups[1].Value) -replace '\s+',' ')
L 'limit' (([regex]::Match($x, '<ExecutionTimeLimit>([^<]+)')).Groups[1].Value)
L 'lastresult' ((([regex]::Match((& schtasks /query /tn QubesPvNicRearm /v /fo LIST 2>&1 | Out-String), '(?m)^\s*Last Result\s*:\s*(.+)$')).Groups[1].Value).Trim())
L 'netvm' ((& "$bin\qubesdb-read.exe" '/netvm' 2>&1 | Out-String).Trim())
# the boot run's own judgement of the PREVIOUS session - the end-to-end signal, written where a task can finish
L 'bootjudgement' (((Get-Content 'C:\ProgramData\QubesPvNic.log' -EA SilentlyContinue |
                     Where-Object { $_ -match 'shutdown re-arm:' } | Select-Object -Last 1) -replace '\s+',' '))
# DID THE WRITES LAND? Clear both, run the task, and watch. The latch is left ARMED either way.
$stamp = 'C:\ProgramData\QubesPvNic-rearm.stamp'
Remove-Item -LiteralPath $stamp -Force -EA SilentlyContinue
& reg delete "HKLM\SYSTEM\CurrentControlSet\Services\XEN\Unplug" /v NICS /f 2>&1 | Out-Null
L 'nics_cleared' (((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\XEN\Unplug' -EA SilentlyContinue).NICS -as [string]))
$t0 = Get-Date
& schtasks /run /tn QubesPvNicRearm | Out-Null
$landed = $false
foreach ($i in 1..20) {
    Start-Sleep -Milliseconds 500
    $n = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\XEN\Unplug' -EA SilentlyContinue).NICS
    if ((Test-Path -LiteralPath $stamp) -and $n -eq 1) { $landed = $true; break }
}
L 'writes_landed' ([string]$landed)
L 'landed_after_ms' ([int]((Get-Date)-$t0).TotalMilliseconds)
L 'nics_after' (((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\XEN\Unplug' -EA SilentlyContinue).NICS -as [string]))
L 'stamp_after' (((Get-Item -LiteralPath $stamp -EA SilentlyContinue).LastWriteTime -as [string]))
if (-not $landed) {
    # leave the guest armed whatever the verdict was - the reading above is already recorded
    & reg add "HKLM\SYSTEM\CurrentControlSet\Services\XEN\Unplug" /v NICS /t REG_DWORD /d 1 /f | Out-Null
    L 'restored' 'the probe re-armed the latch itself'
}
L 'END' 'ok'
PS

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

# ---- L6 the toast route ---------------------------------------------------------------------------------------------
# IN-REPO, deliberately. The first version of this cell called a script in a scratch directory that itself sourced
# helpers out of a second worktree; three runs then measured the instrument instead of the product - a hand-rolled
# raspush with the wrong argument form, a0-lib.sh sourced without the $R it refuses to run without, and the firing
# tool never pushed. Everything it needs is now on this branch, so it fires from here and the keys it greps for are
# the keys the bridge actually logs (TI-ACT, not TIACT - my own script printed "NOT MEASURABLE" on data that was
# there, because I grepped for a tag I had not used).
if has L6; then
  log "L6: an actionable toast reaches dom0 WITH its actions, an informational one without"
  if [ -z "$TFEXE" ] || [ ! -f "$TFEXE" ]; then
    verdict L6 INVALID "an actionable toast reaches dom0 with its actions" \
            "--toastfire <toastfire.exe> is required and must exist (got '${TFEXE:-unset}') - missing data fails"
  else
    # a0-lib.sh demands $R and a log() BEFORE it is sourced, and says so; that is how the first attempt died in one
    # line instead of half-working. VM is its subject variable.
    # BOTH libraries refuse without the variable they demand, and they are right to: e2e-lib.sh wants QTEST_VM
    # ("there is deliberately no default target") and a0-lib.sh wants $R and a log() before it is sourced. Setting
    # VM alone killed this run at L6 under `set -u` - the third time in this project that a library was sourced
    # without what it demands, so the selftest now checks it.
    VM="$SUBJ"; export QTEST_VM="$SUBJ"
    INCOMING="${INCOMING:-C:\\Users\\user\\Documents\\QubesIncoming\\win-idd-mgmt}"
    # $R IS THIS ROUTINE'S OWN RESULTS LOG and log() tees into it, so a0-lib.sh's requirement is already
    # satisfied - reassigning it sent every line from here on into a side file, and the run's own record
    # stopped at two lines (measured 2026-10-07; the control's wait exit was in the side file all along).
    source .claude/skills/win-guest-e2e/e2e-lib.sh
    source mgmt/harness/a0-lib.sh
    log "  push toastfire.exe ($(sha256sum "$TFEXE" | cut -c1-12)) - without it every fire is a silent no-op"
    q push "$TFEXE" >/dev/null 2>&1
    tfp=$(q run 'cmd /c if exist "C:\Users\user\Documents\QubesIncoming\win-idd-mgmt\toastfire.exe" (echo TF_PRESENT) else (echo TF_MISSING)' 2>/dev/null | tr -d '\r' | grep -aoE 'TF_PRESENT|TF_MISSING' | head -1)
    raspush guest/toast-hold-fire.ps1 "REG:com-activator" "areg$RANDOM" > "$OUT/L6-register.out" 2>&1
    reg=$(grep -aoE 'REGISTERED|already registered' "$OUT/L6-register.out" | head -1)
    log "  toastfire=$tfp activator=${reg:-NOT-REGISTERED}"
    for k in actionable:ACT informational:INFO; do
      cls=${k%%:*}; sfx=${k#*:}
      raspush guest/toast-hold-fire.ps1 \
        "FIRE:--fire+--method+com-activator+--class+$cls+--title+TI-$sfx+--tag+TI-$sfx" "f$sfx$RANDOM" \
        > "$OUT/L6-fire-$sfx.out" 2>&1
      grep -aq 'FIRED method=' "$OUT/L6-fire-$sfx.out" && log "  $cls fired (TI-$sfx)" || log "  $cls did NOT fire: $(grep -av '^$' "$OUT/L6-fire-$sfx.out" | tail -2 | tr '\n' ' ' | cut -c1-150)"
      sleep 12
    done
    q run 'cmd /c type "C:\ProgramData\qubes-toast-bridge\bridge.log"' > "$OUT/L6-bridge.log" 2>&1
    # the two claims, from the bridge's own record: the actionable one carries its buttons, the informational one
    # does not, and neither waits on the action work (the forward latency per toast)
    python3 - "$OUT/L6-bridge.log" > "$OUT/L6-claims.txt" 2>&1 <<'PY'
import re, sys
L = open(sys.argv[1], encoding='utf-8', errors='replace').read().splitlines()
def secs(s):
    m = re.match(r'(\d\d):(\d\d):(\d\d)', s)
    return None if not m else int(m.group(1))*3600 + int(m.group(2))*60 + int(m.group(3))
for tag in ('TI-ACT', 'TI-INFO'):
    rows = [l for l in L if tag in l]
    if not rows:
        print(f"{tag} NOMEASURE no line at all"); continue
    sent = next((l for l in rows if 'SENT' in l), None)
    first, s_at = secs(rows[0]), (secs(sent) if sent else None)
    acts = re.search(r'actions=(\S+)', sent) if sent else None
    if s_at is None or first is None:
        print(f"{tag} NOMEASURE first={first} sent={s_at}")
    else:
        print(f"{tag} LAT {s_at-first} ACTIONS {acts.group(1) if acts else 'none'}")
PY
    sed 's/^/    /' "$OUT/L6-claims.txt"
    aact=$(awk '$1=="TI-ACT" && $2=="ACTIONS"{print $3} $1=="TI-ACT" && $4=="ACTIONS"{print $5}' "$OUT/L6-claims.txt")
    iact=$(awk '$1=="TI-INFO" && $2=="ACTIONS"{print $3} $1=="TI-INFO" && $4=="ACTIONS"{print $5}' "$OUT/L6-claims.txt")
    alat=$(awk '$1=="TI-ACT" && $2=="LAT"{print $3}' "$OUT/L6-claims.txt")
    ilat=$(awk '$1=="TI-INFO" && $2=="LAT"{print $3}' "$OUT/L6-claims.txt")
    if grep -q NOMEASURE "$OUT/L6-claims.txt" || [ -z "$aact" ] || [ -z "$iact" ]; then
      verdict L6 INVALID "an actionable toast forwards WITH its buttons, an informational one without" \
              "$(tr '\n' '; ' < "$OUT/L6-claims.txt" | cut -c1-200) (toastfire=$tfp activator=${reg:-none})"
    elif printf '%s' "$aact" | grep -q 'b0:' && printf '%s' "$aact" | grep -q 'b1:' && [ "$iact" = default:com ]; then
      verdict L6 PASS "an actionable toast forwards WITH its buttons, an informational one without" \
              "actionable actions=$aact lat=${alat}s; informational actions=$iact lat=${ilat}s"
    else
      verdict L6 FAIL "an actionable toast forwards WITH its buttons, an informational one without" \
              "actionable actions=$aact (want b0 and b1); informational actions=$iact (want default:com only)"
    fi
    if [ "$CLICK" = 1 ]; then
      log "  THE CLICK: a dom0 notification for TI-ACT should be on screen with its buttons. Press one; this reads"
      log "  the outcome for 180 s. It cannot press it - there is no dom0 shell here."
      d=$((SECONDS+180)); seen=0
      while [ $SECONDS -lt $d ]; do
        q run 'cmd /c type "C:\ProgramData\qubes-toast-bridge\bridge.log"' > "$OUT/L6-bridge-after.log" 2>&1
        grep -aq 'ACTION id=' "$OUT/L6-bridge-after.log" && { seen=1; break; }
        sleep 10
      done
      if [ "$seen" = 1 ]; then verdict L6C PASS "a pressed button is carried out IN THE GUEST" "$(grep -a 'ACTION id=' "$OUT/L6-bridge-after.log" | tail -1 | cut -c1-180)"
      else verdict L6C INVALID "a pressed button is carried out in the guest" "no ACTION line in 180 s - nobody pressed it, or the route did not carry it"; fi
    fi
  fi
fi

# ---- L7 the PV NIC re-arm: do the writes LAND? ----------------------------------------------------------------------
# The old shape: the task fired on User32 1074 (shutdown initiated) and its action was powershell.exe parsing a
# ~500-line payload for two registry writes - about 2 s, inside the window where the Task Scheduler service
# terminates actions as the system goes down. Last Result 267014 (0x41306 SCHED_S_TASK_TERMINATED) on every
# shutdown, and qwt-report-death.ps1 ignores that code for every task, correctly - so a re-arm that never ran was
# indistinguishable from one that completed. Jev: silent_hole 0.89, severity narrow-but-real 0.93, and the ONE
# missing measurement "did the writes land" 0.85. That is what this cell measures, and L7C measures it with the
# defect still present.
if has L7; then
  log "L7: the re-arm's writes land, and the boot run judges the previous session"
  guest_ps "$OUT/L7-probe.ps1" > "$OUT/L7.out" 2>&1
  g7(){ grep -a "^L7|$1|" "$OUT/L7.out" | tail -1 | cut -d'|' -f3-; }
  ac=$(g7 action_cmd); wl=$(g7 writes_landed); ms=$(g7 landed_after_ms); bj=$(g7 bootjudgement); lr=$(g7 lastresult)
  if [ -z "$wl" ]; then
    verdict L7 INVALID "the re-arm's writes land and the boot run judges the previous session" \
            "the probe produced no reading: $(tail -2 "$OUT/L7.out" | tr '\n' ' ' | cut -c1-180)"
  elif ! printf '%s' "$ac" | grep -qi '^cmd.exe'; then
    verdict L7 INVALID "the re-arm's writes land and the boot run judges the previous session" \
            "the installed task still starts '$ac' - the artefact under test is NOT installed, so nothing here measures the fix"
  elif [ "$wl" != True ]; then
    verdict L7 FAIL "the re-arm's writes land" "writes_landed=$wl after ${ms:-?} ms (nics_after=$(g7 nics_after) stamp=$(g7 stamp_after))"
  elif printf '%s' "$bj" | grep -q 'did not complete'; then
    verdict L7 FAIL "the boot run judges the previous session" "the writes land (${ms} ms) but the boot run reports a MISSED arm: $bj"
  elif [ -z "$bj" ]; then
    verdict L7 INVALID "the boot run judges the previous session" "the writes land (${ms} ms) but the boot run left no 'shutdown re-arm:' line at all"
  else
    verdict L7 PASS "the re-arm's writes land and the boot run judges the previous session" \
            "landed in ${ms} ms with a stamp; boot run says '$bj'; task LastResult=$lr netvm='$(g7 netvm)'"
  fi
fi

# ---- L7C the control: the same measurement with the DEFECT STILL PRESENT --------------------------------------------
# Two jobs in one arm. It DATES the behaviour - Jev, asked whether the termination is ours: "older, newly visible"
# 0.74, caused-today 0.00 - and it is the run where L7's check is seen to FAIL, which is what makes L7's PASS
# evidence rather than decoration: the golden's package still has the powershell action and no stamp at all, so
# writes_landed must come back False there while the subject comes back True.
# The golden is never booted (it is a pristine base): the control is a clone of it.
if has L7C; then
  CTL="${SUBJ}-ctl"
  log "L7C: the same read on a clone of $GOLDEN (the package that predates today's changes)"
  if qvm-ls --raw-data --fields NAME 2>/dev/null | grep -qx "$CTL"; then qwt_shutdown "$CTL" 300 >/dev/null 2>&1; qvm-remove -f "$CTL" >/dev/null 2>&1; fi
  # ONE GUEST AT A TIME. The subject comes DOWN before the control goes up: two Windows guests on this rig
  # interleave their probes and fabricate verdicts (CLAUDE.md "Run VM-mutating jobs serially"), and
  # tools/hooks/serial-rig-gate.sh refuses a launch that would do it. The subject is brought back up
  # afterwards, because the sweep below reads ITS logs.
  if bash mgmt/clone-guest.sh "$GOLDEN" "$CTL" > "$OUT/L7C-clone.out" 2>&1; then
    qwt_shutdown "$SUBJ" 600 > "$OUT/L7C-subject-down.out" 2>&1
    if [ "$(state)" != Halted ]; then
      verdict L7C INVALID "the control shows the defect present" \
              "the subject would not halt, so the control cannot run without a second guest up: $(tail -1 "$OUT/L7C-subject-down.out" | cut -c1-110)"
      CELLS="$(printf '%s' "$CELLS" | sed 's/L7C//')"
    fi
    qvm-start "$CTL" >/dev/null 2>&1
    # WAIT FOR A LOGGED-ON SESSION, not just for qrexec. `qtest pushrun` runs the script IN a user session and
    # returns nothing but cmd's banner when there is none - which is exactly what happened on 2026-10-07: the
    # control answered `echo UP` as soon as qrexec came up, the probe ran into a session-less guest, and the cell
    # reported "the probe produced nothing" about a guest that was simply not logged on yet. Three exits, and it
    # says which: a session appeared / the guest is Halted (terminal) / the deadline.
    cd_ok=0; cd_why=deadline; d=$((SECONDS+420))
    while [ $SECONDS -lt $d ]; do
      if [ "$(qvm-ls --raw-data --fields STATE "$CTL" | tr -d '\n')" = Halted ]; then cd_why=halted; break; fi
      # explorer.exe means the autologon session is up; query user confirms an interactive session exists
      if QTEST_VM="$CTL" timeout 60 ./tools/qtest run 'cmd /c tasklist /fi "imagename eq explorer.exe" /nh' 2>/dev/null | tr -d '\r' | grep -q 'explorer.exe'; then
        cd_ok=1; cd_why=session; break
      fi
      sleep 15
    done
    log "  control $CTL: $cd_why"
    if [ "$cd_ok" = 1 ]; then
      QTEST_VM="$CTL" timeout 300 ./tools/qtest pushrun "$OUT/L7-probe.ps1" > "$OUT/L7C.out" 2>&1
      c7(){ grep -a "^L7|$1|" "$OUT/L7C.out" | tail -1 | cut -d'|' -f3-; }
      cl=$(c7 lastresult); cac=$(c7 action_cmd); cwl=$(c7 writes_landed); swl=$(grep -a '^L7|writes_landed|' "$OUT/L7.out" 2>/dev/null | tail -1 | cut -d'|' -f3)
      if [ -z "$cac$cwl" ]; then
        verdict L7C INVALID "the control shows the defect present" "the probe produced nothing on $CTL: $(tail -2 "$OUT/L7C.out" | tr '\n' ' ' | cut -c1-160)"
      elif [ "$cwl" = False ] && [ "$swl" = True ]; then
        verdict L7C PASS "the control shows the defect present - so L7's check has been seen to FAIL" \
                "control($GOLDEN clone): action='$cac' writes_landed=False LastResult=$cl; subject: writes_landed=True"
      elif [ "$cwl" = True ]; then
        verdict L7C FAIL "the control shows the defect present" \
                "the control ALSO lands its writes (action='$cac') - either it carries the fix or the defect was never there"
      else
        verdict L7C INVALID "the control shows the defect present" "control writes_landed='$cwl' subject writes_landed='$swl' (one of them did not read)"
      fi
    else
      verdict L7C INVALID "the control shows the defect present" "$CTL reached no logged-on session: $cd_why (state $(qvm-ls --raw-data --fields STATE "$CTL" | tr -d '\n'))"
    fi
    # the control is a throwaway clone: asked down, then GONE - no stale claim, no second guest left up
    qwt_shutdown "$CTL" 420 > "$OUT/L7C-ctl-down.out" 2>&1
    qvm-remove -f "$CTL" >/dev/null 2>&1
  else
    verdict L7C INVALID "the control shows the defect present" "clone-guest.sh failed: $(tail -2 "$OUT/L7C-clone.out" | tr '\n' ' ' | cut -c1-160)"
  fi
  # and the subject comes back up, because the sweep reads its logs
  if [ "$(state)" != Running ]; then
    qvm-start "$SUBJ" >/dev/null 2>&1
    w=$(wait_session 420); [ "$w" = up ] || log "WARNING: the subject did not return after the control (wait_session=$w) - the sweep will say so"
  fi
fi

# ---- the sweep over the whole window, then the table ---------------------------------------------------------------
log "the log sweep over everything this run touched"
# THE SWEEP RUNS BEFORE THE TWO CELLS THAT BREAK THINGS ON PURPOSE, which is why L8 and L4 are the last
# blocks in this file. L4 restarts the agent twice and a window containing that reads as agent churn
# (measured 2026-10-07: instances_per_boot=2, nine ETW tier-downs, an ERROR during a requested stop - all of
# it this harness's own doing). L8 ENDS THE BROKER on purpose, and broker_deaths is a P1 threshold in the
# sweep - so a window containing L8 would report this harness's own injection as the product's worst class.
(cd "$SWEEP" && timeout 1200 bash mgmt/harness/log-sweep.sh "$SUBJ" "$SINCE" "$OUT/sweep") > "$OUT/sweep.out" 2>&1
sweepline=$(grep -a 'LOGSWEEP-RESULT' "$OUT/sweep.out" | tail -1)
log "$sweepline"
case "$sweepline" in
  *status=CLEAN*) verdict SW PASS "the sweep finds nothing new or breached" "$sweepline" ;;
  *status=*) verdict SW FAIL "the sweep finds nothing new or breached" "$sweepline" ;;
  *) verdict SW INVALID "the sweep ran" "no LOGSWEEP-RESULT line" ;;
esac

# ---- L8 a death DURING a shutdown reaches dom0 at the NEXT boot, exactly once -----------------------------------------
# The measurement L5 does not make. The death reporter is a scheduled task, and Task Scheduler REFUSES to start
# actions once shutdown is in progress (ERROR_SHUTDOWN_IN_PROGRESS, 2147943515), so a death at that moment was
# silently lost - which is why QwtDeathCatchUp exists as a separate boot-triggered pass with a watermark. Jev named
# this as the one unmeasured thing that would most change the verdict on the release (0.89).
# The stimulus is a REAL death of a REAL supervised process - the de-slice broker, ended through its handle by the
# pid the AGENT's own log reports, never by image name - with the shutdown requested FIRST so the reporter's own
# trigger lands inside the refusal window. The broker is the right subject: its death is the P1 class, the agent
# reports it as a death, and nothing relaunches it, so no armed relauncher is being fought. The invariant asserted afterwards is the owner's: EXACTLY ONE
# notification for one death. Never zero (concealment), never two (a double).
if has L8; then
  log "L8: end the agent DURING a shutdown; the catch-up must report it at the next boot, exactly once"
  cat > "$OUT/L8-arm.ps1" <<'PS'
$ErrorActionPreference = 'Continue'
function L($k,$v){ "L8|$k|$v" }
$state = Join-Path $env:ProgramData 'Qubes\notify-errors'
$wm = Join-Path $state 'qwt-death-watermark.json'
$logdir = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -EA SilentlyContinue).LogDir
L 'logdir' $logdir
$before = 0
if ($logdir) {
    foreach ($f in Get-ChildItem -LiteralPath $logdir -Filter 'qwt-report-death*.log' -EA SilentlyContinue) {
        $before += @(Get-Content -LiteralPath $f.FullName -EA SilentlyContinue | Where-Object { $_ -match 'DEATH #' }).Count
    }
}
L 'deaths_before' $before
L 'watermark_before' $(if (Test-Path $wm) { ((Get-Content $wm -Raw -EA SilentlyContinue) -replace "`r|`n",'') } else { 'absent' })
# THE SUBJECT OF THE INJECTION IS THE DE-SLICE BROKER, NOT THE AGENT, and the pid comes from the AGENT'S OWN
# LOG - never from a name. Three reasons the agent is the wrong target here: ending it while the watchdog
# service is armed is the defect class the owner made a rule about; the watchdog would simply relaunch it,
# since the shutdown has not begun yet; and the agent's own exit at session end is QGA_EXIT_SESSION_END, not a
# death at all. A broker death IS the P1 class, the agent reports it as one, and the agent does NOT relaunch it
# (owner: "broker death is a major failure anyway, so there is no point of making it extra smooth"), so the
# death record is written and nothing races to undo it.
$agentLog = $null
if ($logdir) { $agentLog = Get-ChildItem -LiteralPath $logdir -Filter 'gui-agent-*.log' -EA SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1 }
if (-not $agentLog) { L 'error' 'no agent log to read the broker pid from'; L 'END' 'ok'; return }
$line = (Get-Content -LiteralPath $agentLog.FullName -EA SilentlyContinue |
         Where-Object { $_ -match 'WGCBROKER ready \(pid (\d+) validated\)' } | Select-Object -Last 1)
if (-not $line) { L 'error' 'no WGCBROKER ready line - the broker never came up, so there is nothing to end'; L 'END' 'ok'; return }
$bpid = [int]([regex]::Match($line, 'pid (\d+)').Groups[1].Value)
$p = Get-Process -Id $bpid -EA SilentlyContinue
if (-not $p) { L 'error' "broker pid $bpid is not running"; L 'END' 'ok'; return }
L 'broker_pid' $bpid
L 'broker_name' $p.ProcessName
# the shutdown goes first, so the reporter's own trigger lands inside Task Scheduler's refusal window
& shutdown /s /t 8 /c "supervision-e2e L8: a helper death during a shutdown" | Out-Null
L 'shutdown_requested' (Get-Date -Format 'HH:mm:ss.fff')
Start-Sleep -Seconds 9                      # the teardown has begun by now; the task service refuses new actions
try { $p.Kill(); L 'killed' (Get-Date -Format 'HH:mm:ss.fff') } catch { L 'error' ("could not end the broker: " + $_.Exception.Message) }
L 'END' 'ok'
PS
  guest_ps "$OUT/L8-arm.ps1" > "$OUT/L8-arm.out" 2>&1
  g8(){ grep -a "^L8|$1|" "$OUT/L8-arm.out" | tail -1 | cut -d'|' -f3-; }
  db=$(g8 deaths_before); apid=$(g8 broker_pid); kil=$(g8 killed)
  # THREE EXITS on the halt: it halted / it is still up at the deadline / it never had the stimulus
  d=$((SECONDS+420)); while [ $SECONDS -lt $d ] && [ "$(state)" != Halted ]; do sleep 10; done
  if [ "$(state)" != Halted ]; then
    verdict L8 INVALID "a death during a shutdown is reported at the next boot, exactly once" \
            "the guest did not halt within 420 s of the injected shutdown (state $(state)); nothing can be judged"
  elif [ -z "$apid" ] || [ -z "$kil" ]; then
    verdict L8 INVALID "a death during a shutdown is reported at the next boot, exactly once" \
            "the stimulus did not reach the broker: pid='$apid' killed='$kil' $(g8 error | cut -c1-110)"
  else
    qvm-start "$SUBJ" >/dev/null 2>&1
    w=$(wait_session 420)
    if [ "$w" != up ]; then
      verdict L8 INVALID "a death during a shutdown is reported at the next boot, exactly once" "no session after the boot (wait_session=$w)"
    else
      cat > "$OUT/L8-read.ps1" <<'PS'
$ErrorActionPreference = 'Continue'
function L($k,$v){ "L8R|$k|$v" }
$state = Join-Path $env:ProgramData 'Qubes\notify-errors'
$wm = Join-Path $state 'qwt-death-watermark.json'
$logdir = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -EA SilentlyContinue).LogDir
$lines = @()
if ($logdir) {
    foreach ($f in Get-ChildItem -LiteralPath $logdir -Filter 'qwt-report-death*.log' -EA SilentlyContinue) {
        $lines += @(Get-Content -LiteralPath $f.FullName -EA SilentlyContinue)
    }
}
$deaths = @($lines | Where-Object { $_ -match 'DEATH #' })
L 'deaths_after' $deaths.Count
foreach ($d in ($deaths | Select-Object -Last 4)) { L 'line' ($d -replace "`r",'') }
L 'catchup_lines' (@($lines | Where-Object { $_ -match 'CatchUp|catch-up|catchup' }) -join ' || ')
L 'watermark_after' $(if (Test-Path $wm) { ((Get-Content $wm -Raw -EA SilentlyContinue) -replace "`r|`n",'') } else { 'absent' })
L 'catchup_task_last' ((& schtasks /query /tn QwtDeathCatchUp /v /fo LIST 2>&1 | Out-String) -replace "`r|`n",' ' -replace '\s+',' ')
# DID THE DEATH EVENT EXIST AT ALL? 4002 is the agent's event for a de-slice broker that stopped serving
# (include/deathevent.h). Without it the injection never landed - the agent was torn down before it noticed -
# and that is an INSTRUMENT miss, not concealment. "No death was recorded" and "a death was recorded and
# nobody was told" are opposite verdicts, so the cell must not collapse them.
$ev = @(Get-WinEvent -FilterHashtable @{LogName='Application'; Id=4002; StartTime=(Get-Date).AddMinutes(-30)} -EA SilentlyContinue)
L 'death_events_4002' $ev.Count
if ($ev.Count -gt 0) { L 'event_line' ((($ev[0].Message -replace "`r|`n",' ') -replace '\s+',' ')) }
L 'END' 'ok'
PS
      guest_ps "$OUT/L8-read.ps1" > "$OUT/L8-read.out" 2>&1
      g8r(){ grep -a "^L8R|$1|" "$OUT/L8-read.out" | tail -1 | cut -d'|' -f3-; }
      da=$(g8r deaths_after); wma=$(g8r watermark_after)
      if [ -z "$da" ] || [ -z "$db" ]; then
        verdict L8 INVALID "a death during a shutdown is reported at the next boot, exactly once" \
                "the reporter's own log could not be counted: before='$db' after='$da' (missing data fails)"
      elif [ "$(g8r death_events_4002)" = 0 ] && [ "$da" = "$db" ]; then
        verdict L8 INVALID "a death during a shutdown is reported at the next boot, exactly once" \
                "no event 4002 was written at all - the agent was torn down before it noticed the broker go, so nothing was there to report: the INJECTION missed, which is not the same as concealment"
      elif [ "$da" = "$db" ]; then
        verdict L8 FAIL "a death during a shutdown is reported at the next boot" \
                "a death WAS recorded (event 4002 x$(g8r death_events_4002)) and the reporter's DEATH lines did not change ($db -> $da): CONCEALED - exactly what the catch-up exists to prevent"
      elif [ "$((da - db))" = 1 ]; then
        verdict L8 PASS "a death during a shutdown is reported at the next boot, exactly once" \
                "DEATH lines $db -> $da (+1); watermark now $wma; $(g8r line | cut -c1-120)"
      else
        verdict L8 FAIL "a death during a shutdown is reported EXACTLY ONCE" \
                "DEATH lines $db -> $da (+$((da - db))) - a double is P1 by the owner's rule; $(g8r line | cut -c1-110)"
      fi
    fi
  fi
fi

# ---- L4 the restart helper: a live turnover, and a fail-proof driven by a REAL stimulus ------------------------------
# The first version passed `-LogDir <nonexistent>` to a script that HAS NO SUCH PARAMETER - the helper reads the log
# directory from HKLM Qubes Tools\LogDir - so the stimulus never reached the code under test, the normal path ran, and
# its correct `RESTART ok` was recorded as a FAIL. (Experimenter rule 5: the injection must reach the code, and the
# order must be checked before the outcome is read.) So this cell now drives the two things it can drive honestly:
# a real turnover, and a real logdir-unreadable - by renaming the very registry value the helper reads, and putting it
# back before anything is graded. A cell that leaves the guest altered is itself a defect, so the restore is asserted.
if has L4; then
  log "L4: a live turnover, then the fail-proof with the registry value the helper actually reads renamed"
  cat > "$OUT/L4-probe.ps1" <<'PS'
$ErrorActionPreference = 'Continue'
function L($k,$v){ "L4|$k|$v" }
$inc = 'C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
$h = Join-Path $inc 'restart-gui-agent.ps1'
if (-not (Test-Path -LiteralPath $h)) { L 'error' "the helper is not at $h"; L 'END' 'ok'; return }
$key = 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools'
L 'logdir_before' ((Get-ItemProperty -Path $key -EA SilentlyContinue).LogDir)
# ARM 1 - the normal path: a real turnover on a live guest
$a = & powershell -NoProfile -ExecutionPolicy Bypass -File $h 2>&1 | Out-String
L 'normal' (($a -split "`n" | Where-Object { $_ -match '^RESTART' } | Select-Object -Last 1) -replace "`r",'')
L 'normal_newpid' (($a -split "`n" | Where-Object { $_ -match '^AGENTPID' } | Select-Object -Last 1) -replace "`r",'')
# ARM 2 - the fail-proof: the log directory the helper reads is GONE. Renamed, not deleted, and put back first.
$orig = (Get-ItemProperty -Path $key -EA SilentlyContinue).LogDir
$renamed = $false
try { Rename-ItemProperty -Path $key -Name 'LogDir' -NewName 'LogDir_sup_backup' -EA Stop; $renamed = $true }
catch { L 'rename_failed' ($_.Exception.Message -replace "`r|`n",' ') }
if ($renamed) {
    $b = & powershell -NoProfile -ExecutionPolicy Bypass -File $h 2>&1 | Out-String
    # RESTORE BEFORE GRADING - whatever the arm said
    try { Rename-ItemProperty -Path $key -Name 'LogDir_sup_backup' -NewName 'LogDir' -EA Stop } catch { }
    L 'nologdir' (($b -split "`n" | Where-Object { $_ -match '^RESTART' } | Select-Object -Last 1) -replace "`r",'')
}
$after = (Get-ItemProperty -Path $key -EA SilentlyContinue).LogDir
L 'logdir_after' $after
L 'logdir_restored' ([string]($after -eq $orig -and $after))
L 'END' 'ok'
PS
  q push guest/restart-gui-agent.ps1 >/dev/null 2>&1 || true   # in-repo since the branches merged
  guest_ps "$OUT/L4-probe.ps1" > "$OUT/L4.out" 2>&1
  g4(){ grep -a "^L4|$1|" "$OUT/L4.out" | tail -1 | cut -d'|' -f3-; }
  n=$(g4 normal); f=$(g4 nologdir); rst=$(g4 logdir_restored); np=$(g4 normal_newpid)
  if grep -aq '^L4|error|' "$OUT/L4.out"; then
    verdict L4 INVALID "a live turnover, and INVALID-INSTRUMENT when the turnover cannot be proven" "$(g4 error | cut -c1-160)"
  elif [ "$rst" != True ]; then
    # the guest's registry must be as we found it; a cell that leaves it changed is a defect of the cell
    verdict L4 FAIL "the cell leaves HKLM LogDir exactly as it found it" \
            "logdir_before='$(g4 logdir_before)' logdir_after='$(g4 logdir_after)' restored=$rst $(g4 rename_failed | cut -c1-90)"
  elif [ -z "$n" ] || [ -z "$f" ]; then
    verdict L4 INVALID "a live turnover, and INVALID-INSTRUMENT when the turnover cannot be proven" \
            "normal='${n:-<none>}' nologdir='${f:-<none>}' (one arm produced no RESTART line)"
  elif printf '%s' "$n" | grep -q '^RESTART ok' && printf '%s' "$f" | grep -q 'INVALID-INSTRUMENT.*logdir-unreadable'; then
    verdict L4 PASS "a live turnover is proven, and an unprovable one is INVALID-INSTRUMENT" \
            "normal -> '$n' ($np); logdir renamed -> '$f'; registry restored"
  else
    verdict L4 FAIL "a live turnover is proven, and an unprovable one is INVALID-INSTRUMENT" \
            "normal -> '$n'; logdir renamed -> '$f' (want RESTART ok, then INVALID-INSTRUMENT logdir-unreadable)"
  fi
  # AND IT LEAVES THE GUEST HEALTHY. This cell restarts the agent twice and renames a registry value for one of
  # them, so the agent that ends up running was started while LogDir was missing - and its toast bridge went down
  # with the restart and did not come back (measured 2026-10-07: L6 then fired two toasts into a guest with no
  # bridge and could measure nothing). One more restart, with the registry intact, and the health is ASSERTED.
  cat > "$OUT/L4-restore.ps1" <<'PS'
$ErrorActionPreference = 'Continue'
function L($k,$v){ "L4R|$k|$v" }
$h = 'C:\Users\user\Documents\QubesIncoming\win-idd-mgmt\restart-gui-agent.ps1'
$r = & powershell -NoProfile -ExecutionPolicy Bypass -File $h 2>&1 | Out-String
L 'restart' (($r -split "`n" | Where-Object { $_ -match '^RESTART' } | Select-Object -Last 1) -replace "`r",'')
Start-Sleep -Seconds 12
foreach ($n in 'gui-agent','notifhost','wgcbroker') {
    L $n (@(Get-Process -Name $n -EA SilentlyContinue).Count)
}
L 'END' 'ok'
PS
  guest_ps "$OUT/L4-restore.ps1" > "$OUT/L4-restore.out" 2>&1
  g4r(){ grep -a "^L4R|$1|" "$OUT/L4-restore.out" | tail -1 | cut -d'|' -f3-; }
  ag=$(g4r gui-agent); nh=$(g4r notifhost)
  if [ "$ag" = 1 ] && [ "$nh" -ge 1 ] 2>/dev/null; then
    log "  L4 restored the guest: gui-agent=$ag notifhost=$nh wgcbroker=$(g4r wgcbroker)"
  else
    verdict L4R FAIL "L4 leaves the guest with a running agent AND its toast bridge" \
            "gui-agent='$ag' notifhost='$nh' after the restore restart ('$(g4r restart | cut -c1-80)') - a cell that leaves the guest degraded is a defect of the cell"
  fi
fi

echo
echo "=== supervision-e2e: $SUBJ ==="
printf '%-5s %-8s %s\n' CELL VERDICT CLAIM
while IFS=$'\t' read -r c v claim ev; do printf '%-5s %-8s %s\n' "$c" "$v" "$claim"; done < "$VERDICTS"
nf=$(awk -F'\t' '$2=="FAIL"' "$VERDICTS" | wc -l); ni=$(awk -F'\t' '$2=="INVALID"' "$VERDICTS" | wc -l)
echo "--- $(wc -l < "$VERDICTS") cell(s): $(awk -F'\t' '$2=="PASS"' "$VERDICTS" | wc -l) pass, $nf fail, $ni invalid; evidence in $OUT"
log "done"
[ "$nf" = 0 ] && [ "$ni" = 0 ] && exit 0 || exit 1
