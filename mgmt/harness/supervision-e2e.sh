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
#   L9 receipts   THE INSTALL'S SUPERVISION RECEIPTS, read-only, and the two items of
#                 docs/ADR-supervision.md's "still owed on a guest" list that had NO runner at all
#                 (audited 2026-10-23): our Application-log event source is registered with a message
#                 file that exists (ADR 2 - without it every 4001..4004 record renders as
#                 "description not found"), the ONE reporter QwtDeathReporter exists with an
#                 <EventTrigger> subscription naming our ids and running as SYSTEM (ADR 3), and
#                 Microsoft-Windows-TaskScheduler/Operational is ENABLED - client Windows ships it
#                 disabled and 201/203 are never written otherwise, so the installer turns it on
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
#   L10 qdbtimeout a forced WaitForQdb timeout (QubesDB stopped with its SCM recovery disarmed) is
#                 recorded by the SCM as System 7023 naming ERROR_TIMEOUT 1460, with 7031 and the
#                 restart, and the guest comes back. ADR-supervision item 3, which had RUNNER: none.
#                 Its CONTROL arm runs FIRST and must see NO 7023. It runs LAST of all cells and
#                 shuts the subject down after itself, because it takes the guest's own qrexec down
#                 for the six minutes QDB_WAIT_TIMEOUT_MS specifies
#   L11 crash-up  a death with the guest UP, TWICE: exactly one dom0 notification each, and the second
#                 numbered HIGHER for the same component. ADR-supervision item 2's other half - L8
#                 covers the death during a SHUTDOWN and the ADR records what it does not: "A forced
#                 crash WHILE THE GUEST IS UP, and the death-1/death-2 numbering across two crashes".
#                 The increment is the property, not the literal 1 and 2: L8 has already put
#                 wgcbroker deaths in the same per-day log, so the counter is not at zero here
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

ISO=""; SUBJ="win11r-sup"; GOLDEN="win11r-qwt"; CELLS="L1 L9 L2 L3 L5 L6 L7 L7C L8 L11 L4 L10"; CYCLES=2; CLICK=0
BUILD="${BUILD:-}"                                # package_version of the build under test, for the sweep's attribution
HOLD="${HOLD_REPO:-$PWD}"                         # kept for an override; the helpers are in THIS repo now
SWEEP="${SWEEP_REPO:-$PWD}"                       # the log sweep, likewise - no cross-worktree dependency
TFEXE="${TFEXE:-}"                                # toastfire.exe for L6 (from the branch's build artifact)
while [ $# -gt 0 ]; do
  case "$1" in
    --iso) ISO="${2:-}"; shift 2 ;;
    # PASS THE BUILD. Without it the analyzer has to guess which build wrote a line, and on a cell
    # that upgrades a golden - which L1 always does - it guesses wrong in the one direction that
    # matters, billing the GOLDEN's errors to the candidate. It also leaves candidate_build_absent
    # unevaluated (None), so a pull holding nothing the candidate wrote cannot be detected.
    --build) BUILD="${2:-}"; shift 2 ;;
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
    grep -q UP <<< "$(q run 'cmd /c echo UP' 2>/dev/null)" && { echo "up"; return 0; }
    sleep 10
  done; echo "deadline"; return 1; }
guest_ps(){ q pushrun "$1" 2>&1 | tr -d '\r'; }   # a guest-side probe script, output verbatim
# THE INCOMING PATH, ONCE, FOR EVERY CELL. It used to be defined inside L6's block, so any cell that
# ran without L6 hit it unset under `set -u` - which is how a library sourced without what it demands
# has killed a run here three times. ASKED OF THE GUEST, never hard-coded: the path is under the
# guest's own account, and the planted `C:\Users\user\...` value silently addressed a profile that
# does not exist on a guest whose account is not `user` (the German golden's gerd-test), so files
# landed in the real profile while every command looked in the wrong one. The hard-coded value stays
# only as the fallback for a guest that cannot answer yet.
# DISCOVERED LAZILY, after the guest can answer. An eager read at script start would run against a
# guest L1 has not deployed yet, get nothing, and plant the fallback - which is the wrong-profile
# hazard this exists to avoid, in the one case it matters.
incoming(){
  [ -n "${INCOMING:-}" ] && { printf '%s' "$INCOMING"; return 0; }
  INCOMING=$(q incoming 2>/dev/null | tr -d '\r' | grep -a '^[A-Za-z]:' | head -1)
  [ -n "$INCOMING" ] || INCOMING='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
  printf '%s' "$INCOMING"
}

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

# ---- L9 the install's supervision receipts (ADR-supervision 1 and 5: no runner before 2026-10-23) ----------------
if has L9; then
  log "L9: supervision receipts - our event source, the ONE reporter's subscription, the TaskScheduler operational log"
  cat > "$OUT/L9-probe.ps1" <<'PS'
$ErrorActionPreference = 'Continue'
function L($k,$v){ "L9|$k|$v" }
# ADR 2: our event source. The installer registers it (Register-QwtEventSource); the message file is
# the .NET EventLogMessages.dll, present on every Win10/11, because every id in it renders %1.
$src = 'HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application\Qubes Windows Tools'
L 'source_key' ((Test-Path $src) -as [string])
if (Test-Path $src) {
  $p = Get-ItemProperty $src -EA SilentlyContinue
  $mf = [string]$p.EventMessageFile
  L 'source_msgfile' $mf
  L 'source_msgfile_exists' ((Test-Path ([Environment]::ExpandEnvironmentVariables($mf))) -as [string])
}
# ADR 3: ONE reporter, event-triggered, SYSTEM, subscribed to our death ids.
$xml = (& schtasks.exe /query /tn QwtDeathReporter /xml 2>&1 | Out-String)
L 'task_present' (([bool]($xml -match '<Task')) -as [string])
L 'task_has_eventtrigger' (([bool]($xml -match '<EventTrigger')) -as [string])
L 'task_has_subscription' (([bool]($xml -match 'Subscription')) -as [string])
L 'task_runs_as' ([regex]::Match($xml, '<UserId>([^<]*)</UserId>').Groups[1].Value)
L 'task_names_4001' (([bool]($xml -match '4001')) -as [string])
# ADR 3, install step: the TaskScheduler operational log must be ENABLED or 201/203 never appear.
$gl = (& wevtutil.exe gl Microsoft-Windows-TaskScheduler/Operational 2>&1 | Out-String)
L 'tasksched_oplog' ([regex]::Match($gl, 'enabled:\s*(\w+)').Groups[1].Value)
PS
  guest_ps "$OUT/L9-probe.ps1" > "$OUT/L9.out" 2>&1
  g9(){ grep -a "^L9|$1|" "$OUT/L9.out" | tail -1 | cut -d'|' -f3-; }
  sk=$(g9 source_key); mf=$(g9 source_msgfile_exists); tp=$(g9 task_present)
  et=$(g9 task_has_eventtrigger); ua=$(g9 task_runs_as); n1=$(g9 task_names_4001); ol=$(g9 tasksched_oplog)
  claim="the install's supervision receipts: event source, the ONE reporter's subscription, the TaskScheduler operational log"
  # MISSING DATA FAILS (this harness's rule): no reading at all is INVALID, never a pass.
  if [ -z "$sk" ] && [ -z "$tp" ] && [ -z "$ol" ]; then
    verdict L9 INVALID "$claim" "the probe produced no reading: $(tail -2 "$OUT/L9.out" | tr '\n' ' ' | cut -c1-180)"
  elif [ "$sk" != True ]; then
    verdict L9 FAIL "our event source is registered" \
            "the Application-log source key is absent - every 4001..4004 death record would render as 'description not found'"
  elif [ "$mf" != True ]; then
    verdict L9 FAIL "our event source has a message file that exists" \
            "EventMessageFile='$(g9 source_msgfile)' does not exist on this guest"
  elif [ "$tp" != True ]; then
    verdict L9 FAIL "the ONE reporter is installed" \
            "schtasks /query /tn QwtDeathReporter returned no task XML - nothing turns a death record into a dom0 notification"
  elif [ "$et" != True ]; then
    verdict L9 FAIL "the ONE reporter is EVENT-triggered" \
            "QwtDeathReporter carries no <EventTrigger>: it exists but nothing fires it on a death record"
  elif [ "$n1" != True ]; then
    verdict L9 FAIL "the subscription names our death ids" \
            "the task XML does not mention 4001 - the subscription cannot be ours (runs_as=$ua)"
  elif ! printf '%s' "$ua" | grep -qiE '(^|[^0-9])S-1-5-18($|[^0-9])|system'; then
    # S-1-5-18 IS THE WELL-KNOWN SYSTEM SID, and it is what schtasks /xml actually writes. MEASURED
    # 2026-10-23: the first cut of this leg matched only the word "system" and FAILED a correctly
    # installed reporter whose UserId read S-1-5-18 - a predicate that checked a SPELLING instead of
    # the identity. Both forms are accepted because the XML carries the SID while some installs and
    # localisations write a name.
    verdict L9 FAIL "the ONE reporter runs as SYSTEM" "UserId='$ua' - neither the SYSTEM SID (S-1-5-18) nor a SYSTEM name; the notify route needs SYSTEM"
  elif ! printf '%s' "$ol" | grep -qiE '^true$'; then
    verdict L9 FAIL "the TaskScheduler operational log is enabled" \
            "wevtutil gl reports enabled: '${ol:-<nothing>}' - client Windows ships it disabled and 201/203 are never written, so a helper task's death is unreported"
  else
    verdict L9 PASS "$claim" "source=$sk msgfile=$mf task=$tp eventtrigger=$et runs_as=$ua names_4001=$n1 oplog=$ol"
  fi
fi

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
    (cd "$SWEEP" && timeout 1200 bash mgmt/harness/log-sweep.sh "$SUBJ" "$SINCE" "$OUT/L2-sweep" ${BUILD:+--build "$BUILD"} \
  --tolerate-error 'qrexec-wrapper.*(XcStoreRead: IOCTL_XENIFACE_STORE_READ failed: 0x5|libx?envchan_client_init)' 'this routine polls for a session with `qtest run` under a timeout while the guest boots; when that timeout fires the CLIENT goes away and its vchan ring-ref leaves xenstore, so the wrapper already running finds nothing. The lines are this run''s own stimulus, so they are TOLERATED - whether the poll times out at all depends on how fast this boot was, which is why a CAUSED declaration of it breached declared_errors_unmatched=1 on the first guest run even with the cell gate below. matrix.sh:485 records the same call for the same reason. The PRODUCT half - a departed peer reading as four ERRORs of ours - is filed as a P2 and is NOT excused by this' \
       --tolerate-error '(SetupNetwork: Failed to get qubes-ip|QioWriteBuffer: WriteFile failed with error 0xe8|send_command_to_daemon: write to daemon failed with error 0xe8|wmain: open agent pipe failed with error 0x2)' 'this subject has an EMPTY netvm (CLAUDE.md: only a guest that TESTS PV networking gets one), so /qubes-ip legitimately does not exist and netsetup''s writes to the daemon pipe fail as a consequence. matrix.sh:497 carries this identical declaration for every cell of the campaign (Jev 1.00) - TWO INSTRUMENTS GRADING ONE PRODUCT MUST CARRY THE SAME DISPOSITIONS, and without it this gate failed on error_lines_undeclared=12 for the installer lines every upgrade writes') > "$OUT/L2-sweep.out" 2>&1
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
    # RESOLVED, not hardcoded: bridge.log is in the common log directory (7e349bac), and
    # `type <missing file>` writes "The system cannot find the file specified" into the capture,
    # which the python below reads as NOMEASURE - so a stale path produced a permanent INVALID
    # rather than a result. a0-lib.sh is sourced above, so blog_resolve is in scope.
    if blog_resolve; then
        q run "cmd /c type \"$BLOGPATH\"" > "$OUT/L6-bridge.log" 2>&1
    else
        log "  INSTRUMENT: the bridge log location could not be resolved - the L6 claims are ungraded"
        : > "$OUT/L6-bridge.log"
    fi
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
        if blog_resolve; then
            q run "cmd /c type \"$BLOGPATH\"" > "$OUT/L6-bridge-after.log" 2>&1
        else
            : > "$OUT/L6-bridge-after.log"
        fi
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
# A DECLARATION FOR A STIMULUS THAT WILL NOT BE APPLIED MUST NOT BE MADE. The pattern below is
# excused because THIS routine polls for a session while a guest boots - which only happens in L1,
# L2 and L8. MEASURED 2026-10-23 running --cells "L9" alone: the declaration went unmatched and
# declared_errors_unmatched breached at P2, whose own `why` is "the stimulus the run claims to have
# applied did not happen" - correct, and about the cell selection rather than the product. So the
# declaration is now made only when a cell that produces the stimulus is actually selected.
DECL=()
if has L1 || has L2 || has L8; then
  DECL=(--tolerate-error 'qrexec-wrapper.*(XcStoreRead: IOCTL_XENIFACE_STORE_READ failed: 0x5|libx?envchan_client_init)' 'this routine polls for a session with `qtest run` under a timeout while the guest boots; when that timeout fires the CLIENT goes away and its vchan ring-ref leaves xenstore, so the wrapper already running finds nothing. The lines are this run''s own stimulus, so they are TOLERATED - whether the poll times out at all depends on how fast this boot was, which is why a CAUSED declaration of it breached declared_errors_unmatched=1 on the first guest run even with the cell gate below. matrix.sh:485 records the same call for the same reason. The PRODUCT half - a departed peer reading as four ERRORs of ours - is filed as a P2 and is NOT excused by this' \
       --tolerate-error '(SetupNetwork: Failed to get qubes-ip|QioWriteBuffer: WriteFile failed with error 0xe8|send_command_to_daemon: write to daemon failed with error 0xe8|wmain: open agent pipe failed with error 0x2)' 'this subject has an EMPTY netvm (CLAUDE.md: only a guest that TESTS PV networking gets one), so /qubes-ip legitimately does not exist and netsetup''s writes to the daemon pipe fail as a consequence. matrix.sh:497 carries this identical declaration for every cell of the campaign (Jev 1.00) - TWO INSTRUMENTS GRADING ONE PRODUCT MUST CARRY THE SAME DISPOSITIONS, and without it this gate failed on error_lines_undeclared=12 for the installer lines every upgrade writes')
fi
(cd "$SWEEP" && timeout 1200 bash mgmt/harness/log-sweep.sh "$SUBJ" "$SINCE" "$OUT/sweep" ${BUILD:+--build "$BUILD"} "${DECL[@]}") > "$OUT/sweep.out" 2>&1
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
  # the injection window starts NOW, so the sweep below reads the kill, the reports and the reboot
  L8_SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  cat > "$OUT/L8-arm.ps1" <<'PS'
$ErrorActionPreference = 'Continue'
function L($k,$v){ "L8|$k|$v" }
$state = Join-Path $env:ProgramData 'Qubes\notify-errors'
$wm = Join-Path $state 'qwt-death-watermark.json'
$logdir = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -EA SilentlyContinue).LogDir
L 'logdir' $logdir
$before = 0
if ($logdir) {
    foreach ($f in Get-ChildItem -LiteralPath $logdir -Filter 'qwt-*death*.log' -EA SilentlyContinue) {
        $before += @(Get-Content -LiteralPath $f.FullName -EA SilentlyContinue | Where-Object { $_ -match 'DEATH #\d+ NEW' }).Count
    }
}
L 'deaths_before' $before
# A FILE CANNOT SCOPE A RUN. The reporter's log is per-day and accumulates across every injection,
# so a CUMULATIVE row count cannot answer "how many rows did THIS death produce" - measured
# 2026-10-24, where a correct single report read as 2 because an earlier run's row was in the same
# file. The counts are taken here, before the kill, and the verdict uses the DELTA.
$rowsBefore = 0; $desliceBefore = 0
if ($logdir) {
    foreach ($f in Get-ChildItem -LiteralPath $logdir -Filter 'qwt-*death*.log' -EA SilentlyContinue) {
        $rowsBefore += @(Get-Content -LiteralPath $f.FullName -EA SilentlyContinue |
                         Where-Object { $_ -match 'notified to dom0 as' }).Count
    }
    foreach ($f in Get-ChildItem -LiteralPath $logdir -Filter 'gui-agent-*.log' -EA SilentlyContinue) {
        $desliceBefore += @(Get-Content -LiteralPath $f.FullName -EA SilentlyContinue |
                            Where-Object { $_ -match 'NOTIFYERR gui-agent\.deslice-down sent to dom0' }).Count
    }
}
L 'dom0_death_rows_before' $rowsBefore
L 'dom0_deslice_rows_before' $desliceBefore
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
# THE KILL GOES FIRST AND THE SHUTDOWN FOLLOWS IMMEDIATELY. Two orderings were tried on a guest
# today and BOTH failed to apply the stimulus at all, which is why this one is deliberate:
#   1. `shutdown /s /t 8` then `Start-Sleep 9` in THIS session, then kill (1023-1646). Windows tore
#      the session down one second before the kill ran: the arm output ends at `shutdown_requested`
#      with no `killed` and no `END`.
#   2. a DETACHED `cmd /c ping ... & taskkill /PID <n> /F > receipt` armed before the shutdown, so
#      the wait did not belong to the dying session (1023-1754). The arm completed, but the receipt
#      came back EMPTY - created by the redirect, taskkill torn down before it wrote its SUCCESS
#      line - with death_events_4002=0 and the reporter's count unmoved. The teardown reaches the
#      killer before the killer reaches the broker.
# There is a second problem with killing inside the teardown: once it has begun the broker may be
# terminated BY THE SHUTDOWN rather than by us, and the agent then sees an orderly shutdown and not
# a death - so even a kill that lands need not produce a death to report.
# So: end the broker while the machine is still running, let the agent notice and write its 4002,
# and only then take the machine down with no countdown. The death is GUARANTEED to exist, and the
# question put to the next boot is unchanged - was it reported EXACTLY ONCE.
# WHAT THIS COSTS, stated rather than hidden: the reporter's task could in principle deliver in the
# moment before the shutdown, and then the catch-up is not what reported it. So this script RECORDS
# the reporter's count and the 4002 count as they stand after the kill and before the shutdown, and
# the verdict names which mechanism delivered. Jev: this ordering 0.75, and 0.21 that it weakens the
# clause (i.e. 0.79 that the essential property - exactly once across the reboot - is still proven).
# BY LITERAL PID, from the agent's own log, never by name: $p was resolved from $bpid above.
try { $p.Kill(); L 'killed' (Get-Date -Format 'HH:mm:ss.fff') }
catch { L 'error' ("could not end the broker: " + $_.Exception.Message); L 'END' 'ok'; return }
Start-Sleep -Seconds 4                      # the agent notices the broker go and writes its death event
$ev8 = @(Get-WinEvent -FilterHashtable @{LogName='Application'; Id=4002; StartTime=(Get-Date).AddMinutes(-5)} -EA SilentlyContinue)
L 'events_4002_after_kill' $ev8.Count
$mid = 0
if ($logdir) {
    foreach ($f in Get-ChildItem -LiteralPath $logdir -Filter 'qwt-*death*.log' -EA SilentlyContinue) {
        $mid += @(Get-Content -LiteralPath $f.FullName -EA SilentlyContinue | Where-Object { $_ -match 'DEATH #\d+ NEW' }).Count
    }
}
L 'deaths_after_kill' $mid
# EVERY FIELD IS FLUSHED BEFORE THE MACHINE GOES. `shutdown /t 0` can end this session at any moment
# after it is called, so nothing is printed after it - that is how ordering 1 lost its own evidence.
L 'shutdown_due' (Get-Date -Format 'HH:mm:ss.fff')
L 'END' 'ok'
& shutdown /s /t 0 /c "supervision-e2e L8: a helper death while the machine goes down" | Out-Null
PS
  guest_ps "$OUT/L8-arm.ps1" > "$OUT/L8-arm.out" 2>&1
  g8(){ grep -a "^L8|$1|" "$OUT/L8-arm.out" | tail -1 | cut -d'|' -f3-; }
  db=$(g8 deaths_before); apid=$(g8 broker_pid); kil=$(g8 killed); mid=$(g8 deaths_after_kill)
  # THREE EXITS on the halt: it halted / it is still up at the deadline / it never had the stimulus
  d=$((SECONDS+420)); while [ $SECONDS -lt $d ] && [ "$(state)" != Halted ]; do sleep 10; done
  if [ "$(state)" != Halted ]; then
    verdict L8 INVALID "a death during a shutdown is reported at the next boot, exactly once" \
            "the guest did not halt within 420 s of the injected shutdown (state $(state)); nothing can be judged"
  # THE ARM CANNOT KNOW WHETHER THE KILL LANDED - it is gone by then, by design - so this gate asks
  # only whether there was a broker to end at all. Whether the stimulus ACTUALLY landed is decided
  # after the boot, by the receipt the detached killer leaves and by event 4002, which is a stronger
  # discriminator than anything the arm could report: "no death was recorded" and "a death was
  # recorded and nobody was told" are opposite verdicts and the cell below keeps them apart.
  # MEASURED 2026-10-23: this gate used to require a `killed` field, and when the kill moved out of
  # the session to survive the shutdown that field stopped existing, so L8 reported INVALID on every
  # run regardless of what happened - a stale predicate outliving the thing it described.
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
    foreach ($f in Get-ChildItem -LiteralPath $logdir -Filter 'qwt-*death*.log' -EA SilentlyContinue) {
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
# DID THE CATCH-UP RUN IN *THIS* BOOT? Its Last Run Time against this boot's start is the marker the
# dom0-side wait needs: without it the cell cannot tell "the reporter was never asked" from "the
# reporter was asked and said nothing", which are opposite verdicts.
$bootUp = (Get-Date) - [TimeSpan]::FromMilliseconds([Environment]::TickCount64)
$lastRun = $null
try {
    $xml = [xml](& schtasks /query /tn QwtDeathCatchUp /xml ONE 2>$null)
    $info = (& schtasks /query /tn QwtDeathCatchUp /v /fo LIST 2>$null | Out-String)
    $m = [regex]::Match($info, 'Last Run Time:\s*(.+)')
    if ($m.Success) { $lastRun = [datetime]::Parse($m.Groups[1].Value.Trim()) }
} catch { }
L 'catchup_last_run' $(if ($lastRun) { $lastRun.ToString('yyyy-MM-dd HH:mm:ss') } else { 'unknown' })
L 'catchup_ran_this_boot' $(if ($lastRun -and $lastRun -gt $bootUp) { 1 } else { 0 })
# THE DOM0 ROWS THEMSELVES, which is what the user actually sees. One broker death must produce
# exactly ONE row. Measured 2026-10-23: it produced TWO - wgcbroker.death-1 from the death reporter
# AND gui-agent.deslice-down from the agent's complaint path, two seconds apart - and the owner saw
# both. Counted from the writers' own logs, not inferred.
$deathRows = 0; $desliceRows = 0
if ($logdir) {
    foreach ($f in Get-ChildItem -LiteralPath $logdir -Filter 'qwt-*death*.log' -EA SilentlyContinue) {
        $deathRows += @(Get-Content -LiteralPath $f.FullName -EA SilentlyContinue |
                        Where-Object { $_ -match 'notified to dom0 as' }).Count
    }
    foreach ($f in Get-ChildItem -LiteralPath $logdir -Filter 'gui-agent-*.log' -EA SilentlyContinue) {
        $desliceRows += @(Get-Content -LiteralPath $f.FullName -EA SilentlyContinue |
                          Where-Object { $_ -match 'NOTIFYERR gui-agent\.deslice-down sent to dom0' }).Count
    }
}
L 'dom0_death_rows' $deathRows
L 'dom0_deslice_rows' $desliceRows
# the detached killer's own words, so "the injection missed" is backed by taskkill's output rather
# than by the absence of a field

if ($ev.Count -gt 0) { L 'event_line' ((($ev[0].Message -replace "`r|`n",' ') -replace '\s+',' ')) }
L 'END' 'ok'
PS
      # A WAIT NEEDS A REAL MARKER AND THREE EXITS. The catch-up is a BOOT-TRIGGERED task, so it
      # does not run at the instant the session comes up - and reading the counts immediately judged
      # the product before its reporter had been given a chance. MEASURED 2026-10-24 on win11r-sup:
      # the read came back deaths_after=0 with `catchup_task_last ... Last Run Time 12:38:07 AM`,
      # which is the boot the KILL happened in, and `Next Run Time: N/A` - i.e. at read time the new
      # boot's pass had not run at all, so L8 reported "a death WAS recorded and nobody was told"
      # about a reporter that had not yet been asked. Three exits: the death is reported, or the
      # catch-up has demonstrably RUN in this boot and still reported nothing (which is the real
      # failure), or the bound expires and the cell says the wait itself was inconclusive.
      _l8d=$((SECONDS+240)); _l8why=bound
      while [ $SECONDS -lt $_l8d ]; do
        guest_ps "$OUT/L8-read.ps1" > "$OUT/L8-read.out" 2>&1
        _da=$(grep -a '^L8R|deaths_after|' "$OUT/L8-read.out" | tail -1 | cut -d'|' -f3-)
        _dr=$(grep -a '^L8R|dom0_death_rows|' "$OUT/L8-read.out" | tail -1 | cut -d'|' -f3-)
        # NOT the DEATH-record count: opening a record is not telling the user, and breaking on it
        # exits the wait while the notification is still to come. MEASURED 2026-10-24 in the campaign's
        # own supervision-gate run: this condition fired on records 0 -> 1, the wait stopped, and the
        # cell then correctly reported "a record was OPENED and NO dom0 row followed it" - about a
        # catch-up that had not been given the time to notify. Only a ROW counts as reported.
        if [ -n "$_dr" ] && [ "${_dr:-0}" -gt "$(g8 dom0_death_rows_before)" ]; then _l8why=reported; break; fi
        if grep -qa 'L8R|catchup_ran_this_boot|1' "$OUT/L8-read.out"; then _l8why=ran-and-silent; break; fi
        sleep 20
      done
      log "  L8: waited for the catch-up (${_l8why}); deaths_after=$(grep -a '^L8R|deaths_after|' "$OUT/L8-read.out" | tail -1 | cut -d'"'"'|'"'"' -f3-)"
      g8r(){ grep -a "^L8R|$1|" "$OUT/L8-read.out" | tail -1 | cut -d'|' -f3-; }
      da=$(g8r deaths_after); wma=$(g8r watermark_after)
      if [ -z "$da" ] || [ -z "$db" ]; then
        verdict L8 INVALID "a death during a shutdown is reported at the next boot, exactly once" \
                "the reporter's own log could not be counted: before='$db' after='$da' (missing data fails)"
      elif [ "$(g8r death_events_4002)" = 0 ] && [ "$da" = "$db" ]; then
        verdict L8 INVALID "a death during a shutdown is reported at the next boot, exactly once" \
                "no event 4002 was written at all - the agent was torn down before it noticed the broker go, so nothing was there to report: the INJECTION missed. 4002 after the kill: $(g8 events_4002_after_kill). the INJECTION missed, which is not the same as concealment"
      elif [ "$da" = "$db" ]; then
        verdict L8 FAIL "a death during a shutdown is reported at the next boot" \
                "a death WAS recorded (event 4002 x$(g8r death_events_4002)) and the reporter's DEATH lines did not change ($db -> $da): CONCEALED - exactly what the catch-up exists to prevent"
      elif { dr=$(( $(g8r dom0_deslice_rows) - $(g8 dom0_deslice_rows_before) )); [ "$dr" -gt 0 ]; }; then
        # ONE SITUATION, ONE DOM0 ROW (owner's standing rule; a double is P1). The death was
        # reported exactly once, but the agent ALSO sent its de-slice complaint for the same event -
        # which is the two toasts the owner saw on 2026-10-23.
        verdict L8 FAIL "a death during a shutdown is reported at the next boot, exactly once AND ONLY ONCE" \
                "DEATH lines $db -> $da (+1) but dom0 also received $dr de-slice row(s) for the same broker: $(g8r dom0_death_rows) death row(s) + $dr complaint row(s) = a DOUBLE for one event"
      elif { ddr=$(( $(g8r dom0_death_rows) - $(g8 dom0_death_rows_before) )); [ "$ddr" = 0 ]; } && [ "$((da - db))" -ge 1 ]; then
        # OPENED AND NEVER TOLD. The reporter created the record - `DEATH #n NEW <chan>/<id>#<rid>` -
        # and no `notified to dom0` line followed, so the user heard nothing. MEASURED 2026-10-24:
        # the live reporter opened it 7 s after the kill and the shutdown ended it before it could
        # notify, and the catch-up then skipped it because a dedupe keyed on the OPENING line read
        # "written up" as "told". This arm exists so that outcome is never reported as a double.
        verdict L8 FAIL "a death during a shutdown is reported at the next boot" \
                "a DEATH record was OPENED ($db -> $da) and NO dom0 row followed it (rows $(g8 dom0_death_rows_before) -> $(g8r dom0_death_rows)): the user was told NOTHING; $(g8r line | cut -c1-110)"
      elif { ddr=$(( $(g8r dom0_death_rows) - $(g8 dom0_death_rows_before) )); [ "$ddr" -gt 1 ]; }; then
        # MORE THAN ONE ROW FOR ONE DEATH. Judged on the ROWS THAT REACHED DOM0, which is the
        # property - "no doubles, nothing lost" is about what the user sees, not about how many
        # lines our log holds. MEASURED 2026-10-24: this cell used to count every line matching
        # `DEATH #`, and the reporter writes TWO per death (`DEATH #1 NEW ...` opening the record,
        # then `DEATH #1 notified to dom0 as ...`), so ONE correctly-reported death read as "+2 - a
        # double is P1" while dom0_death_rows was 1 and dom0_deslice_rows 0. The product was right
        # and the counter was not.
        verdict L8 FAIL "a death during a shutdown is reported EXACTLY ONCE" \
                "dom0 received $ddr death row(s) for ONE injected death - a double is P1 by the owner's rule; $(g8r line | cut -c1-110)"
      elif { ddr=$(( $(g8r dom0_death_rows) - $(g8 dom0_death_rows_before) )); [ "$ddr" = 1 ]; }; then
        # NAME THE MECHANISM. `mid` is the reporter's count taken after the kill and before the
        # shutdown: unchanged means the CATCH-UP at the next boot is what delivered (the clause's
        # own path), already +1 means the live reporter got it in before the machine went. Both are
        # "exactly once", and the record says which - so the evidence is never ambiguous about it.
        _by="the next boot's CATCH-UP"; [ "$mid" = "$da" ] && _by="the LIVE reporter, before the shutdown"
        verdict L8 PASS "a death during a shutdown is reported at the next boot, exactly once" \
                "dom0 received EXACTLY 1 death row and 0 de-slice rows; DEATH records $db -> $da, delivered by $_by (count after the kill: $mid); 4002 after the kill: $(g8 events_4002_after_kill); $(g8r line | cut -c1-100)"
      else
        verdict L8 FAIL "a death during a shutdown is reported EXACTLY ONCE" \
                "DEATH lines $db -> $da (+$((da - db))) - a double is P1 by the owner's rule; $(g8r line | cut -c1-110)"
      fi
    fi
  fi
fi

# ---- the injection window MUST be swept ------------------------------------------------------------------------------
# THE SW CELL ABOVE RUNS BEFORE L8, DELIBERATELY (L8 ends the broker and broker_deaths is a P1
# threshold), and the consequence is that nothing graded the window the injection happens in. Owner,
# 2026-10-23: "if the sweep was not run, it is same as no sweep". It is how a client-visible double
# toast and an ERROR on a graceful shutdown sat in a window the gate never read.
# IT IS NOT A PASS/FAIL CELL, and saying so is the point: the injected broker death IS a real death,
# so broker_deaths and death_events breach here BY CONSTRUCTION - only an FI BUILD excuses them
# (log-sweep.py:2822 tests e["fi"], which comes from the build, never from a declaration). So this
# sweep is EVIDENCE with a named expectation, and the properties that must hold are asserted by L8
# itself from the writers' own logs (dom0_death_rows / dom0_deslice_rows above).
if has L8; then
  log "the sweep over the INJECTION window (evidence; the injected death breaches by construction)"
  (cd "$SWEEP" && timeout 1200 bash mgmt/harness/log-sweep.sh "$SUBJ" "$L8_SINCE" "$OUT/L8-sweep" \
     ${BUILD:+--build "$BUILD"} "${DECL[@]}") > "$OUT/L8-sweep.out" 2>&1
  l8rep="$OUT/L8-sweep/report.json"
  if [ -f "$l8rep" ]; then
    read -r bd de dl su < <(python3 -c "
import json,sys; m=json.load(open(sys.argv[1]))['metrics']
print(m.get('broker_deaths'), m.get('death_events'), m.get('dom0_loud_failures'), m.get('signatures_unclassified'))" "$l8rep")
    log "  L8 window: broker_deaths=$bd death_events=$de dom0_loud_failures=$dl signatures_unclassified=$su (report $l8rep)"
    # The injection accounts for ONE broker death and ONE 4002. Anything beyond that in this window
    # is not ours and is named here rather than left in a report nobody reads.
    if [ "${bd:-0}" -gt 1 ] || [ "${de:-0}" -gt 1 ]; then
      verdict L8W FAIL "the injection window holds ONLY the injected death" \
              "broker_deaths=$bd death_events=$de for ONE injected kill - the surplus is not this harness's ($l8rep)"
    else
      verdict L8W PASS "the injection window holds ONLY the injected death" \
              "broker_deaths=$bd death_events=$de dom0_loud_failures=$dl unclassified=$su ($l8rep)"
    fi
  else
    verdict L8W INVALID "the injection window holds ONLY the injected death" "no report at $l8rep - the window went UNSWEPT, which is the same as no sweep"
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

# ---- L11 ADR-supervision item 2's OTHER HALF: a death with the guest UP, and the numbering --------
# L8 measures a death injected DURING a shutdown. The ADR records what it does not: "A forced crash
# WHILE THE GUEST IS UP, and the death-1/death-2 numbering across two crashes, are not measured by
# it." This is that half. The guest stays up, so the channel survives and the script runs through
# `guest_ps` - no detach, no reboot.
# THE NUMBERING IS ASSERTED AS AN INCREMENT, not as the literal 1 and 2 the ADR's prose names: L8 has
# already put wgcbroker deaths in the same per-day reporter log, so the counter is not at zero when
# this cell starts. What the product must do is give the SECOND death a distinct, higher number for
# the same component - that is the property; "it happens to be 1" is a property of a fresh guest.
if has L11; then
  log "L11: end gui-agent while the guest is UP, twice - exactly one report each, and the second numbered higher"
  q push guest/sup-crash-numbering.ps1 >/dev/null 2>&1
  _inc=$(incoming)
  QT_T=900 q run "powershell -NoProfile -ExecutionPolicy Bypass -File \"$_inc\\sup-crash-numbering.ps1\" -Out C:\\Windows\\Temp\\L11.txt" \
      > "$OUT/L11.out" 2>&1 || true
  q run 'cmd /c type C:\Windows\Temp\L11.txt' > "$OUT/L11-read.out" 2>&1 || true
  g11(){ grep -a "^L11|$1|" "$OUT/L11-read.out" "$OUT/L11.out" 2>/dev/null | tail -1 | cut -d'|' -f3- | tr -d '\r'; }
  _r1b=$(g11 round1_rows_before); _r1a=$(g11 round1_rows_after)
  _r2b=$(g11 round2_rows_before); _r2a=$(g11 round2_rows_after)
  _s1=$(g11 round1_suffix_added); _s2=$(g11 round2_suffix_added)
  _k1=$(g11 round1_killed); _k2=$(g11 round2_killed); _rel=$(g11 relaunched_pid)
  _e1=$(g11 round1_events_4001); _e2=$(g11 round2_events_4001)
  _term=$(g11 terminal)$(g11 round1_terminal)$(g11 round2_terminal)
  _d1=$(( ${_r1a:-0} - ${_r1b:-0} )); _d2=$(( ${_r2a:-0} - ${_r2b:-0} ))
  if [ -n "$_term" ]; then
    verdict L11 INVALID "the stimulus could not be applied, so nothing about the product was measured" \
            "$_term - no verdict is claimed either way"
  elif [ -z "$_k1" ] || [ -z "$_k2" ]; then
    verdict L11 INVALID "one of the two kills did not land, so a missing report is not the product's" \
            "killed1='$_k1' killed2='$_k2' relaunched='$_rel'; this cell NEVER reads a zero delta as a pass when its own stimulus is unproven"
  elif [ "$_d1" != 1 ] || [ "$_d2" != 1 ]; then
    # ZERO IS CONCEALMENT AND TWO IS A DOUBLE, and the owner's rule names both: exactly one
    # notification for one death, never zero, never two.
    verdict L11 FAIL "a death with the guest UP is not reported exactly once" \
            "round1 delta=$_d1 (rows $_r1b -> $_r1a, 4001 x$_e1), round2 delta=$_d2 (rows $_r2b -> $_r2a, 4001 x$_e2) - want 1 each; zero is concealment, two is a P1 double"
  elif [ -z "$_s1" ] || [ -z "$_s2" ] || [ "$_s1" = "$_s2" ]; then
    verdict L11 FAIL "the second death reuses the first one's number, so two deaths are indistinguishable in dom0" \
            "gui-agent.death suffix added by round1='$_s1', by round2='$_s2' - they must differ, and the ADR's death-1/death-2 is exactly this property"
  elif [ "${_s2:-0}" -le "${_s1:-0}" ]; then
    verdict L11 FAIL "the second death is numbered BELOW the first" \
            "round1 added suffix $_s1, round2 added $_s2 - the numbering must increase or the order of two deaths cannot be read"
  else
    verdict L11 PASS "a death with the guest UP is reported EXACTLY ONCE, and the second is numbered higher" \
            "round1 +1 row (suffix $_s1, 4001 x$_e1), round2 +1 row (suffix $_s2, 4001 x$_e2), agent relaunched as pid $_rel between them; WER 1000/1001 recorded not required - a Kill is a termination, not a fault"
  fi
fi

# ---- L10 ADR-supervision item 3, which had RUNNER: none ------------------------------------------
# "A forced WaitForQdb timeout (QrexecAgent) yields System 7023 with error 1460 and 7031 with the
# restart, and the SCM restart happens." Nothing fired that failure before; health-recovery-selftest
# only asserts the recovery is ARMED. Jev on the stimulus: live-stop-qubesdb 0.91, against a product
# FI knob at 0.00 and a no-injection receipt at 0.02; detached 0.84; own subject 0.68; and
# blocks_campaign 0.57, so this is a campaign precondition rather than an extra.
# IT RUNS LAST AND THE SUBJECT IS SHUT DOWN AFTER IT. That is how the "own subject" answer is
# honoured without a second 13-minute deploy: the injection disarms QubesDB's SCM recovery and takes
# the guest's own qrexec down for the six minutes QDB_WAIT_TIMEOUT_MS specifies, so the hazard is a
# LATER cell inheriting a half-restored guest - and nothing runs after this one. Both services are
# auto-start, so the shutdown is also the backstop if the script's own finally never ran.
# THE CONTROL ARM GOES FIRST (experimenter rule 4, and rule 3a): it exercises every line of the
# instrument on a healthy guest and its 7023 delta MUST be zero. A nonzero delta there is the
# instrument failing, not the product, and it would otherwise be read as the injection working.
if has L10; then
  _inc10=$(incoming)
  q push guest/sup-qdbtimeout.ps1 >/dev/null 2>&1
  for _arm in CONTROL INJECT; do
    case "$_arm" in
      CONTROL) _flag="-Control"; _tr='C:\Windows\Temp\L10c.txt'; _lbl=L10C ;;
      *)       _flag="";         _tr='C:\Windows\Temp\L10i.txt'; _lbl=L10  ;;
    esac
    log "$_lbl: $_arm - $([ "$_arm" = CONTROL ] && echo 'the same sequence WITHOUT stopping QubesDB' || echo 'stop QubesDB and let WaitForQdb burn its 6 minutes')"
    # DETACHED, via -EncodedCommand. The injected arm takes the channel down, so a command that
    # waits for the script would die with it - the same shape wu-e2e had to adopt for the
    # oscillation scan ("the channel was killing it", 5926ffdf). -EncodedCommand rather than quoting
    # inside -Command because lint L3 refuses the latter for failing SILENTLY, and this carries a
    # path with spaces. The base64 is built here, not hard-coded, because $_inc10 is DISCOVERED.
    _cmd="Start-Process -FilePath powershell -WindowStyle Hidden -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"$_inc10\\sup-qdbtimeout.ps1\" -Out $_tr $_flag'; 'LAUNCHED'"
    _b64=$(printf '%s' "$_cmd" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
    QT_T=120 q run "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $_b64" > "$OUT/$_lbl-launch.out" 2>&1
    _lrc=$?
    # KEEP THE LAUNCH'S OUTCOME. Discarding it is how wu-e2e could not tell "it never started" from
    # "it ran and was not seen" when the answer mattered (evidence_can_decide 0.22).
    grep -qa LAUNCHED "$OUT/$_lbl-launch.out" || log "  [WARN] $_lbl: the launch did not print LAUNCHED (rc=$_lrc) - see $OUT/$_lbl-launch.out"
    # THREE EXITS on the wait, and it says which: the transcript's own `done` marker appeared / the
    # guest is Halted (terminal - nothing will finish) / the deadline. The channel is EXPECTED to be
    # unavailable for part of the injected arm, so a failed read is not an exit: only `done`,
    # Halted, or time are.
    _why=""; _d=$((SECONDS+900))
    while [ $SECONDS -lt $_d ]; do
      [ "$(state)" = Halted ] && { _why="the guest halted"; break; }
      QT_T=60 q run "cmd /c type $_tr" > "$OUT/$_lbl-read.out" 2>&1 || true
      grep -qa "^L10|done|" "$OUT/$_lbl-read.out" && { _why="the transcript is complete"; break; }
      sleep 20
    done
    [ -n "$_why" ] || _why="the 900 s deadline expired"
    log "  $_lbl wait exit: $_why"
    g10(){ grep -a "^L10|$1|" "$OUT/$_lbl-read.out" 2>/dev/null | tail -1 | cut -d"|" -f3- | tr -d "\r"; }
    _b7023=$(g10 scm_7023_base); _w7023=$(g10 scm_7023_window); _w7031=$(g10 scm_7031_window)
    _has1460=$(g10 scm_7023_names_1460); _term=$(g10 terminal); _qend=$(g10 qubesdb_state_end)
    _qare=$(g10 qrexecagent_state_restored); _cfg=$(g10 qubesdb_failure_cfg_restored)
    _delta=$(( ${_w7023:-0} - ${_b7023:-0} ))
    if [ "$_arm" = CONTROL ]; then
      if [ -n "$_term" ]; then
        verdict L10C INVALID "the control could not run, so the instrument is unvalidated" "$_term"
      elif [ "${_w7023:-0}" -gt 0 ]; then
        verdict L10C FAIL "the control saw a 7023 without the injection, so a 7023 in the injected arm proves nothing" \
                "7023 in the control window: ${_w7023} (base ${_b7023:-0}) - this instrument cannot attribute its own stimulus"
      elif [ -z "$(g10 done)" ]; then
        verdict L10C INVALID "the control transcript never completed" "wait exit: $_why - no claim either way"
      else
        verdict L10C PASS "the instrument runs clean on a healthy guest and reports NO 7023" \
                "7023=${_w7023:-0} 7031=${_w7031:-0}; QrexecAgent restored=$_qare, QubesDB=$_qend"
      fi
      continue
    fi
    if [ -n "$_term" ]; then
      verdict L10 INVALID "the stimulus could not be held, so nothing about the SCM was measured" \
              "$_term - QubesDB=$_qend QrexecAgent=$_qare; no verdict is claimed either way"
    elif [ -z "$(g10 done)" ]; then
      verdict L10 INVALID "the injected transcript never completed" \
              "wait exit: $_why - the guest may have been mid-window; QubesDB=$_qend QrexecAgent=$_qare"
    elif [ "$_delta" -lt 1 ]; then
      verdict L10 FAIL "a forced WaitForQdb timeout produced NO System 7023" \
              "7023 ${_b7023:-0} -> ${_w7023:-0} (delta $_delta), 7031=${_w7031:-0} - either the service did not fail or the SCM did not record it, and the installer's restart actions rest on that record"
    elif [ "$_has1460" != "True" ]; then
      verdict L10 FAIL "the 7023 does not name ERROR_TIMEOUT (1460), so this is a different failure" \
              "7023 delta=$_delta but no 1460 in its text - WaitForQdb returns 1460 and svc-exitcode-test asserts SvcMainLoop carries it to the SCM; some other cause ended the service"
    elif [ "$_qare" != "RUNNING" ] || [ "$_qend" != "RUNNING" ]; then
      verdict L10 FAIL "the cell did not leave the guest healthy" \
              "QrexecAgent=$_qare QubesDB=$_qend recovery=$_cfg - a cell that leaves the subject degraded is a defect of the cell"
    else
      verdict L10 PASS "a forced WaitForQdb timeout is recorded by the SCM with 1460 and the guest comes back" \
              "7023 ${_b7023:-0} -> ${_w7023:-0} naming 1460, 7031=${_w7031:-0}; QrexecAgent=$_qare QubesDB=$_qend recovery restored=$_cfg"
    fi
  done
  # NOTHING INHERITS THIS SUBJECT. It asks and polls - never qvm-shutdown --wait, which kills at its
  # timeout and contaminates every later use of the guest (lint L9).
  qwt_shutdown "$SUBJ" 900 || log "  [WARN] L10: the subject did not shut down cleanly after the injection"
fi

echo
echo "=== supervision-e2e: $SUBJ ==="
printf '%-5s %-8s %s\n' CELL VERDICT CLAIM
while IFS=$'\t' read -r c v claim ev; do printf '%-5s %-8s %s\n' "$c" "$v" "$claim"; done < "$VERDICTS"
nf=$(awk -F'\t' '$2=="FAIL"' "$VERDICTS" | wc -l); ni=$(awk -F'\t' '$2=="INVALID"' "$VERDICTS" | wc -l)
echo "--- $(wc -l < "$VERDICTS") cell(s): $(awk -F'\t' '$2=="PASS"' "$VERDICTS" | wc -l) pass, $nf fail, $ni invalid; evidence in $OUT"
log "done"
[ "$nf" = 0 ] && [ "$ni" = 0 ] && exit 0 || exit 1
