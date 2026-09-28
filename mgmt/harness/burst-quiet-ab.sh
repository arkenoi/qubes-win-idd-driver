#!/bin/bash
# burst-quiet-ab.sh - which of OUR post-boot qrexec activity provokes the guest stall?
#
# HYPOTHESIS: the stall needs a burst of qrexec bridge processes (each maps grant pages into its
#   own user address space and unmaps them at exit) in the first minutes after a boot. Jev
#   2026-09-28, from every recorded occurrence and negative: implicated behaviour = qrexec bridge
#   churn 0.91; the product makes such a burst ITSELF on every boot - the updater's scan task fires
#   at boot+2 min and drives Windows Update through qubes-updates-relay, one qubes.UpdatesProxy
#   channel per tunnel (contributing 0.85); best first A/B = updater boot scan ON vs OFF with the
#   harness quiet in both arms (0.67). REFUTED for a variant if its two arms stall about equally.
#   UNSUPPORTED (not refuted) if neither arm stalls.
# BASELINE: 2026-09-27, census cold boots on win11de clones: 3 stalls in ~25 boots, two of them
#   ~20-25 s after the updater scan starts (v4 +145 s, v6 +150 s after qvm-start), all inside a
#   harness burst as well. No control without the burst, or without the scan, was ever run.
# VARIABLE: ONE per run, chosen with VARIANT:
#   scan    (default) SCANON = QubesWindowsUpdateScan enabled for this boot, SCANOFF = disabled. The
#           harness is QUIET in both arms: no qrexec call into the guest until the end-of-window
#           read. The state for boot N is set AND read back at the end of boot N-1 (or by a PREP
#           boot), and whether the scan RAN in boot N is measured from the task's own LastRunTime,
#           so an arm is a measurement, not an intention.
#   soak    SOAK = SOAKERS serial loops of trivial qubes.VMShell calls for the whole WINDOW from
#           session-up (the 2026-08-29 wedge-hunt dose: 6 loops, ~2,000 calls in 7 min) - a HEAVY dose, so
#           that a real effect shows in ~10 boots per arm (Jev 2026-09-28, complete record: first
#           experiment 0.90; no natural-rate A/B has the power in a day). QUIET = none. If no loop has had
#           an answer for 120 s the window ends early - the guest has stopped answering - and it is graded.
#   harness BURST = ROUNDS rounds of PUSHES concurrent file copies + CALLS concurrent short calls
#           right after the session appears; QUIET = none. The updater is left as installed.
#   The window starts when qvm-start RETURNS, which dom0 signals only once the guest's qrexec agent
#   has connected - no call into the guest. (Corrected 2026-09-28 by the VALIDATE run: the first
#   version waited for a rendered window in dom0's per-window capture, and a seamless guest with
#   nothing open maps NO window at all - it read NOWINDOW for 300 s on a healthy guest.) The
#   subject's qrexec_timeout is pinned to 6000 at start and after every restore (a park carries 60),
#   so dom0 never kills a slow boot mid-grade and only BOOT_DL decides. Same subject, same build,
#   same boot, same end-of-window read, same ACPI shutdown. Arms alternate so rig drift and time of
#   day are shared.
# INSTRUMENT: after WINDOW+SETTLE, qrexec liveness (two tries, 20 s apart) and the cpu delta; if it
#   answers, ONE read that counts the product's own qrexec calls this boot from the guest's qrexec
#   agent log and sets the next boot's scan state; then an ACPI shutdown with a 180 s halt deadline
#   plus a 120 s second window that re-probes qrexec (a slow halt must not read as a wedge). Classes:
#     OK / OK-SLOW-HALT    answered, halted (first / second window)
#     STALL                qrexec dead AND ACPI ignored            <- the primary endpoint
#     STALL-LATE           answered at the read, deaf by the shutdown, ACPI ignored - it wedged
#                          AFTER the read (e.g. at the relay teardown); counted in the endpoint
#     SHUTDOWN-HANG        still answers, but ACPI ignored         <- secondary (the 09-21 shape)
#     QREXEC-DEAD-ACPI-OK  dead but halted - the qrexec-not-started defect of findings/install.md,
#                          NOT the stall, counted apart
#     BOOT-*               qrexec not up within BOOT_DL of the start - graded, but kept apart
#   Validate before trusting it: VALIDATE=1 grades a healthy boot (must read OK: alive, halted) and a
#   boot whose domain is paused across the probes and the ACPI request (must read STALL: dead,
#   ignored) - each classifier input seen in both states.
# BUDGET: ~6.5 min a cycle for scan (boot ~100 s, window 240 s, settle 60 s, read + shutdown ~40 s),
#   ~5.5 min for harness; default 20 cycles per arm. A subject that will not halt is drained, killed
#   and RE-CLONED from its park - a killed subject is never reused. No memory image, no forensics
#   (owner, 2026-09-27).
#
#   VM=<subject> PARK=<ckpt-qube> [VARIANT=scan|harness|soak] mgmt/harness/burst-quiet-ab.sh
#   env: CYCLES (per arm, 20)  WINDOW (240 scan / 180 harness / 420 soak)  SETTLE (60)  BOOT_DL (300)  SOAKERS (6)
#        ROUNDS (4)  PUSHES (6)  CALLS (16)  VALIDATE=1  OUT=<evidence dir>
set -u
cd "$(dirname "$0")/../.." || exit 3
VM=${VM:?set VM - the subject; there is no default target}
PARK=${PARK:?set PARK - the parked qube the subject is re-cloned from after a stall}
VARIANT=${VARIANT:-scan}
case "$VARIANT" in
  scan)    ARMS=(SCANON SCANOFF); WINDOW=${WINDOW:-240} ;;
  harness) ARMS=(BURST QUIET);    WINDOW=${WINDOW:-180} ;;
  soak)    ARMS=(SOAK QUIET);     WINDOW=${WINDOW:-420} ;;
  *) echo "VARIANT must be scan, harness or soak" >&2; exit 3 ;;
esac
CYCLES=${CYCLES:-20}; SETTLE=${SETTLE:-60}; BOOT_DL=${BOOT_DL:-300}
ROUNDS=${ROUNDS:-4}; PUSHES=${PUSHES:-6}; CALLS=${CALLS:-16}; SOAKERS=${SOAKERS:-6}
OUT=${OUT:-$HOME/qwt-burst-quiet/$VM-$VARIANT-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT/push" "$OUT/shots" || exit 3
LOG="$OUT/ab.log"; TSV="$OUT/cycles.tsv"
log(){ echo "$(date +%H:%M:%S) bq[$VM]: $*" | tee -a "$LOG"; }
source mgmt/harness/e2e-wait.sh
source mgmt/harness/vmlock.sh
vm_lock "$VM" || { log "REFUSED: another job holds $VM"; exit 3; }
qvm-check --quiet "$PARK" 2>/dev/null || { log "REFUSED: park $PARK does not exist"; exit 3; }
[ "$(w_state "$PARK")" = Halted ] || { log "REFUSED: park $PARK is not Halted"; exit 3; }
head -c 1048576 /dev/urandom > "$OUT/push/base.bin"
QTO=6000   # the rig's standard; a park carries 60, and dom0 may kill a guest whose qrexec misses it
qvm-prefs "$VM" qrexec_timeout "$QTO" || { log "REFUSED: could not set qrexec_timeout on $VM"; exit 3; }

# One burst round: PUSHES copies + CALLS calls, all concurrent, each bounded. Echoes
# "ok=<n>/<total> max=<s>s" - a round whose calls start hanging dates the onset.
burst_round(){ # $1=cycle $2=round
  local c=$1 r=$2 i f pids=() ok=0 tot=0 mx=0 rc secs
  rm -f "$OUT/push"/res-*
  for i in $(seq 1 "$PUSHES"); do
    f="$OUT/push/bq-c$c-r$r-p$i.bin"; cp "$OUT/push/base.bin" "$f"
    ( s=$(date +%s); timeout -k 5 90 qvm-copy-to-vm "$VM" "$f" >/dev/null 2>&1
      echo "$? $(( $(date +%s) - s ))" > "$OUT/push/res-p$i" ) & pids+=($!)
  done
  for i in $(seq 1 "$CALLS"); do
    ( s=$(date +%s); QTEST_VM="$VM" timeout -k 5 90 ./tools/qtest run "cmd /c echo BQ$c.$r.$i" 2>/dev/null \
        | grep -qa "BQ$c\.$r\.$i"
      echo "$? $(( $(date +%s) - s ))" > "$OUT/push/res-c$i" ) & pids+=($!)
  done
  wait "${pids[@]}"
  for f in "$OUT/push"/res-*; do
    read -r rc secs < "$f" || continue
    tot=$((tot + 1)); [ "$rc" = 0 ] && ok=$((ok + 1)); [ "$secs" -gt "$mx" ] && mx=$secs
  done
  # A result file that never got written is a call that was lost, not one that passed.
  tot=$((PUSHES + CALLS))
  rm -f "$OUT/push"/bq-c"$c"-r"$r"-*.bin
  echo "ok=$ok/$tot max=${mx}s"
}

# The SOAK arm: SOAKERS serial loops of trivial qubes.VMShell calls until t0+WINDOW, each call a bridge
# process that maps its grant region and exits. Echoes "calls=<n> ok=<n> lastok=+<s>s early=<0|1>". Ends the window
# early when no loop has had an answer for 120 s (after the first 60 s): the guest has stopped answering, and the
# remaining minutes would only burn the budget. Every call is bounded; a lost one counts as a call, not an answer.
soak_window(){ # $1=cycle label; uses t0
  local c=$1 i pids=() stop="$OUT/push/.soakstop" t_end=$(( t0 + WINDOW )) early=0 f n ok lo newest calls=0 oks=0
  rm -f "$stop" "$OUT/push"/soak-*
  for i in $(seq 1 "$SOAKERS"); do
    ( n=0; ok=0; lastok=0
      while [ ! -f "$stop" ] && [ "$(date +%s)" -lt "$t_end" ]; do
        n=$((n + 1))
        if QTEST_VM="$VM" timeout -k 5 45 ./tools/qtest run "echo BQS$i.$n" 2>/dev/null | tr -d '\r' | grep -qx "BQS$i\.$n"; then
          ok=$((ok + 1)); lastok=$(date +%s)
        fi
        echo "$n $ok $lastok" > "$OUT/push/soak-$i"
      done ) & pids+=($!)
  done
  while [ "$(date +%s)" -lt "$t_end" ]; do
    sleep 15
    newest=0
    for f in "$OUT/push"/soak-*; do read -r n ok lo < "$f" 2>/dev/null || continue; [ "${lo:-0}" -gt "$newest" ] && newest=$lo; done
    if [ $(( $(date +%s) - t0 )) -gt 60 ] && [ $(( $(date +%s) - (newest > 0 ? newest : t0) )) -gt 120 ]; then
      early=1; break
    fi
  done
  touch "$stop"; wait "${pids[@]}"
  newest=0
  for f in "$OUT/push"/soak-*; do
    read -r n ok lo < "$f" 2>/dev/null || continue
    calls=$((calls + n)); oks=$((oks + ok)); [ "${lo:-0}" -gt "$newest" ] && newest=$lo
  done
  echo "calls=$calls ok=$oks lastok=+$(( newest > 0 ? newest - t0 : -1 ))s early=$early"
}

alive_twice(){ w_alive "$VM" && return 0; sleep 20; w_alive "$VM"; }

# ONE call at the end of a boot: what the product did over qrexec this boot, whether the scan ran,
# and (SET=on|off|keep) the scan state for the NEXT boot, read back. Sets READ_* ; empty = unread.
end_read(){ # $1=on|off|keep
  local set=$1 ps b64 out
  READ_RAN=; READ_STATE=; READ_SET=; READ_CALLS=; READ_SVC=; READ_LOG=
  ps=$(cat <<PSEOF
\$ErrorActionPreference='SilentlyContinue'
\$boot=(Get-CimInstance Win32_OperatingSystem).LastBootUpTime
\$t='QubesWindowsUpdateScan'
\$ti=Get-ScheduledTaskInfo -TaskName \$t
\$ran='no'; if(\$ti.LastRunTime -and \$ti.LastRunTime -ge \$boot){ \$ran='yes' }
Write-Output ('BQ|RAN=' + \$ran + ' lastrun=' + \$(if(\$ti.LastRunTime){\$ti.LastRunTime.ToString('s')}else{'never'}) + ' result=' + \$ti.LastTaskResult + ' boot=' + \$boot.ToString('s'))
Write-Output ('BQ|STATE=' + (Get-ScheduledTask -TaskName \$t).State)
\$f=@(Get-ChildItem 'Q:\Qubes Logs','C:\Program Files\Qubes Tools\log' -Filter '*qrexec*agent*.log' -EA SilentlyContinue | Where-Object { \$_.LastWriteTime -ge \$boot } | Sort-Object LastWriteTime)
Write-Output ('BQ|LOG=' + ((\$f | ForEach-Object { \$_.Name }) -join ','))
\$m=@(\$f | ForEach-Object { Select-String -LiteralPath \$_.FullName -SimpleMatch 'Received request from client' })
Write-Output ('BQ|CALLS=' + \$m.Count)
Write-Output ('BQ|SVC=' + ((\$m | ForEach-Object { if(\$_.Line -match "service '([^']+)'"){ \$matches[1] } } | Group-Object | ForEach-Object { \$_.Name + ':' + \$_.Count }) -join ','))
if('$set' -eq 'on'){ Enable-ScheduledTask -TaskName \$t | Out-Null }
if('$set' -eq 'off'){ Disable-ScheduledTask -TaskName \$t | Out-Null }
Write-Output ('BQ|SET=' + (Get-ScheduledTask -TaskName \$t).State)
PSEOF
)
  b64=$(python3 -c "import sys,base64;print(base64.b64encode(sys.argv[1].encode('utf-16-le')).decode())" "$ps") || return 1
  local try
  for try in 1 2; do     # one retry: a transient no-answer must not become missing data (probe review)
    out=$(QTEST_VM="$VM" timeout -k 5 150 ./tools/qtest run "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $b64" 2>/dev/null | tr -d '\r' | grep -a '^BQ|')
    grep -qa '^BQ|SET=' <<<"$out" && break
    sleep 20
  done
  READ_RAN=$(sed -n 's/^BQ|RAN=//p' <<<"$out" | head -1)
  READ_STATE=$(sed -n 's/^BQ|STATE=//p' <<<"$out" | head -1)
  READ_LOG=$(sed -n 's/^BQ|LOG=//p' <<<"$out" | head -1)
  READ_CALLS=$(sed -n 's/^BQ|CALLS=//p' <<<"$out" | head -1)
  READ_SVC=$(sed -n 's/^BQ|SVC=//p' <<<"$out" | head -1)
  READ_SET=$(sed -n 's/^BQ|SET=//p' <<<"$out" | head -1)
  [ -n "$READ_SET" ]
}

# The subject would not halt: drain the queued calls (so none restarts it), kill it, and rebuild it
# from the park. Never reused after a kill - contaminated (rig-cycle #4).
restore_subject(){
  log "  restore: drain + kill $VM, then re-clone it from $PARK"
  # A queued call can START a halted guest again (memory: queued qrexec restarts guests), so the
  # drain is repeated until the subject STAYS halted for 15 s before it is removed.
  local try
  for try in 1 2 3; do
    w_drain_and_shutdown "$VM" log
    w_halt "$VM" 30 "restore-acpi" log >/dev/null || { qvm-kill "$VM" >/dev/null 2>&1; w_halt "$VM" 60 "restore-kill" log >/dev/null; }
    sleep 15
    [ "$(w_state "$VM")" = Halted ] && break
    log "  restore: $VM is $(w_state "$VM") again after the kill (try $try) - draining once more"
  done
  [ "$(w_state "$VM")" = Halted ] || { log "TERMINAL: $VM will not stay halted - no subject"; exit 1; }
  ./mgmt/clone-guest.sh "$PARK" "$VM" >> "$LOG" 2>&1 || { log "TERMINAL: re-clone from $PARK failed - no subject"; exit 1; }
  qvm-prefs "$VM" qrexec_timeout "$QTO" || { log "TERMINAL: could not set qrexec_timeout on the re-clone"; exit 1; }
  log "  restore: $VM re-cloned from $PARK (qrexec_timeout $QTO)"
  NEXT_SCAN=unknown     # the park's state, never assumed
}

# Liveness + cpu. Sets ALIVE, CPU.
probe_alive(){ ALIVE=dead; alive_twice && ALIVE=alive; CPU=$(w_cpu_state "$VM" 10); }

# ACPI shutdown -> the class. Needs ALIVE. Sets HALT, CLS.
shut_and_classify(){ # $1=label
  timeout 60 qvm-shutdown "$VM" >/dev/null 2>&1
  HALT=ignored; w_halt "$VM" 180 "$1-halt" log >/dev/null && HALT=halted
  if [ "$HALT" = ignored ]; then
    # Not yet a verdict (Jev probe review: a fixed deadline stands in for the condition). A slow
    # shutdown halts in the second window; a wedged guest stays up AND deaf through both. The
    # re-probe runs whatever the first answer was: a guest that answered at the end of the window
    # can wedge AFTER it - e.g. when the updater kills its relay and every bridge exits at once -
    # and that must read as a stall, not as a guest that merely would not shut down.
    if w_alive "$VM"; then
      [ "$ALIVE" = dead ] && ALIVE=alive-late
    else
      [ "$ALIVE" = alive ] && ALIVE=dead-late
    fi
    w_halt "$VM" 120 "$1-halt2" log >/dev/null && HALT=halted-late
    CPU="$CPU / after-deadline $(w_cpu_state "$VM" 10)"
  fi
  case "$ALIVE/$HALT" in
    alive/halted*|alive-late/halted*) CLS=OK; [ "$HALT" = halted-late ] && CLS=OK-SLOW-HALT ;;
    alive*/ignored)                   CLS=SHUTDOWN-HANG ;;
    dead/halted*)                     CLS=QREXEC-DEAD-ACPI-OK ;;
    dead/ignored)                     CLS=STALL ;;
    dead-late/ignored)                CLS=STALL-LATE ;;
    dead-late/halted*)                CLS=OK-SLOW-HALT-DEAF ;;
    *)                                CLS="UNCLASSIFIED($ALIVE/$HALT)" ;;
  esac
}

boot(){ # -> 0 = qrexec up (SESS_T = seconds from the start call), 1 = not up by BOOT_DL
  local st; st=$(w_state "$VM")
  if [ "$st" != Halted ]; then
    # Something started it (a queued call can) - shut it down cleanly first; only a subject that
    # will not halt is rebuilt.
    log "  WARNING: $VM is $st before the boot - ACPI shutdown first"
    timeout 60 qvm-shutdown "$VM" >/dev/null 2>&1
    w_halt "$VM" 300 "preboot-halt" log >/dev/null || restore_subject
  fi
  local tb rc; tb=$(date +%s)
  timeout "$BOOT_DL" qvm-start "$VM" >/dev/null 2>&1; rc=$?
  if [ "$rc" = 0 ]; then SESS_T=$(( $(date +%s) - tb )); return 0; fi
  # A start that failed with the domain never up is a rig fault, not a guest verdict.
  [ "$(w_state "$VM")" = Halted ] && { log "TERMINAL: qvm-start $VM failed (rc=$rc) and the domain is not up"; exit 1; }
  SESS_T="no-qrexec-by-${BOOT_DL}s(rc=$rc)"; return 1
}

want_state(){ case "$1" in SCANON) echo on ;; SCANOFF) echo off ;; *) echo keep ;; esac; }

if [ "${VALIDATE:-0}" = 1 ]; then
  log "=== VALIDATE: each branch must be seen to return its class ==="
  boot || { log "VALIDATE: qrexec not up (${SESS_T}) - cannot validate"; exit 1; }
  w_alive "$VM" || { log "VALIDATE FAIL: a healthy session did not answer the liveness probe"; exit 1; }
  end_read keep && log "  healthy session answers; end-of-window read: ran=$READ_RAN state=$READ_STATE calls=$READ_CALLS svc=$READ_SVC log=$READ_LOG" \
    || { log "VALIDATE FAIL: the end-of-window read returned nothing on a healthy guest"; exit 1; }
  # POSITIVE CONTROL: the healthy boot is graded and must read OK (alive, then halted on ACPI). The
  # first version stopped QrexecAgent here to force a DEAD reading; measured 2026-09-28 that is not
  # a dead guest on this build - the service's armed recovery brings the agent back inside the
  # probe window, so the guest answered and graded OK. Both classifier inputs are still seen in
  # both states: alive+halted here, dead+ignored in the paused control below.
  probe_alive; shut_and_classify v1
  log "  healthy boot -> $CLS (expected OK) alive=$ALIVE halt=$HALT cpu=$CPU"
  case "$CLS" in OK|OK-SLOW-HALT) ;; *) log "VALIDATE FAIL: the positive control returned $CLS"; case "$HALT" in halted*) ;; *) restore_subject ;; esac; exit 1 ;; esac
  boot || { log "VALIDATE: qrexec not up on the second boot (${SESS_T})"; exit 1; }
  qvm-pause "$VM" >/dev/null 2>&1 || { log "VALIDATE: qvm-pause refused"; exit 1; }
  probe_alive; shut_and_classify v2
  log "  domain paused across the ACPI request -> $CLS (expected STALL) alive=$ALIVE halt=$HALT"
  qvm-unpause "$VM" >/dev/null 2>&1
  timeout 60 qvm-shutdown "$VM" >/dev/null 2>&1; w_halt "$VM" 240 "v2-unpaused" log >/dev/null || restore_subject
  [ "$CLS" = STALL ] || { log "VALIDATE FAIL: the STALL branch returned $CLS"; exit 1; }
  log "VALIDATE PASS: a healthy boot read OK and a paused one read STALL; the end-of-window read has data"
  exit 0
fi

# One boot: quiet session wait, the arm's activity, end-of-window read (+ next state), shutdown.
# $1=cycle label $2=arm $3=next-state(on|off|keep). Appends a TSV row; updates NEXT_SCAN.
run_boot(){
  local c=$1 arm=$2 next=$3 start t0 end now r due res bursts=- pre=$NEXT_SCAN
  log "--- $c arm=$arm (scan state going in: $pre) ---"
  start=$(date +%H:%M:%S)
  if ! boot; then
    probe_alive; READ_RAN=; READ_CALLS=; READ_SVC=; READ_SET=
    [ "$ALIVE" = alive ] && end_read "$next"
    shut_and_classify "$c"; CLS="BOOT-$CLS"
  else
    log "  qrexec up at +${SESS_T}s (qvm-start returned; no call into the guest yet)"
    t0=$(date +%s)
    if [ "$arm" = BURST ]; then
      bursts=""
      for r in $(seq 1 "$ROUNDS"); do
        due=$(( t0 + (r - 1) * WINDOW / ROUNDS )); now=$(date +%s); [ "$now" -lt "$due" ] && sleep $(( due - now ))
        res=$(burst_round "$c" "$r"); bursts="$bursts r$r:$res"
        log "  burst round $r: $res"
      done
      bursts=${bursts# }
    elif [ "$arm" = SOAK ]; then
      bursts=$(soak_window "$c")
      log "  soak: $bursts"
    fi
    end=$(( t0 + WINDOW + SETTLE ))
    case "$bursts" in *early=1*) end=$(( $(date +%s) + SETTLE )) ;; esac; now=$(date +%s); [ "$now" -lt "$end" ] && sleep $(( end - now ))
    probe_alive; READ_RAN=; READ_CALLS=; READ_SVC=; READ_SET=
    if [ "$ALIVE" = alive ]; then
      end_read "$next" || log "  end-of-window read returned NOTHING (missing data - this boot's product profile is unknown)"
    fi
    shut_and_classify "$c"
  fi
  case "$READ_SET" in Ready) NEXT_SCAN=on ;; Disabled) NEXT_SCAN=off ;; *) [ "$next" = keep ] || NEXT_SCAN=unknown ;; esac
  log "  => $CLS (alive=$ALIVE halt=$HALT cpu=$CPU) scan-ran=${READ_RAN:-UNREAD} product-calls=${READ_CALLS:-UNREAD} [${READ_SVC}] next-scan=$NEXT_SCAN"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$c" "$arm" "$pre" "$start" "$SESS_T" "$bursts" \
    "$ALIVE" "$CPU" "$HALT" "$CLS" "${READ_RAN:-UNREAD}" "${READ_CALLS:-UNREAD}" "${READ_SVC:--}" >> "$TSV"
  case "$HALT" in halted*) ;; *) restore_subject ;; esac
}

printf 'cycle\tarm\tscan_going_in\tstart\tsession\tbursts\talive\tcpu\thalt\tclass\tscan_ran\tproduct_calls\tproduct_services\n' > "$TSV"
log "=== $VARIANT A/B: ${ARMS[0]} vs ${ARMS[1]}, $CYCLES cycles per arm, window ${WINDOW}s, settle ${SETTLE}s$([ "$VARIANT" = harness ] && echo "; burst = $ROUNDS x ($PUSHES copies + $CALLS calls)") ==="
NEXT_SCAN=unknown
total=$((CYCLES * 2))
for cyc in $(seq 1 "$total"); do
  ARM=${ARMS[$(( (cyc + 1) % 2 ))]}
  NXT=${ARMS[$(( cyc % 2 ))]}
  if [ "$VARIANT" = scan ] && [ "$NEXT_SCAN" != "$(want_state "$ARM")" ]; then
    # The state this boot needs was not set and read back by the previous boot (first cycle, a
    # restore, a dead previous boot): a PREP boot sets it. Graded and recorded, never counted.
    run_boot "c$cyc-prep" PREP "$(want_state "$ARM")"
    [ "$NEXT_SCAN" = "$(want_state "$ARM")" ] || { log "TERMINAL: could not set the scan state to $(want_state "$ARM") (read back: $NEXT_SCAN)"; exit 1; }
  fi
  run_boot "c$cyc" "$ARM" "$([ "$VARIANT" = scan ] && want_state "$NXT" || echo keep)"
done

log "=== RESULT (primary endpoint: STALL + STALL-LATE; arm rows only, PREP and BOOT-* rows kept apart) ==="
python3 - "$TSV" "${ARMS[0]}" "${ARMS[1]}" <<'EOF' | tee -a "$LOG"
import csv, sys, math
rows = list(csv.DictReader(open(sys.argv[1]), delimiter='\t'))
A, B = sys.argv[2], sys.argv[3]
tab = {}
for r in rows:
    tab.setdefault(r['arm'], {}); tab[r['arm']][r['class']] = tab[r['arm']].get(r['class'], 0) + 1
for a, d in tab.items():
    print(f"{a:8s} " + ' '.join(f"{k}={v}" for k, v in sorted(d.items())))
def n(a, k): return tab.get(a, {}).get(k, 0)
graded = lambda a: sum(v for k, v in tab.get(a, {}).items() if not k.startswith('BOOT-'))
a = n(A, 'STALL') + n(A, 'STALL-LATE'); b = n(B, 'STALL') + n(B, 'STALL-LATE'); na, nb = graded(A), graded(B)
def fisher_one_sided(x, n1, y, n2):   # P(X >= x) for arm A under the hypergeometric null
    K, N = x + y, n1 + n2
    tot = math.comb(N, n1)
    return sum(math.comb(K, i) * math.comb(N - K, n1 - i) for i in range(x, min(K, n1) + 1)) / tot if tot else float('nan')
print(f"STALL(+LATE) {A} {a}/{na} vs {B} {b}/{nb}; one-sided Fisher p = {fisher_one_sided(a, na, b, nb):.4f}")
mis = [r['cycle'] for r in rows if r['arm'] == 'SCANON' and r['scan_ran'] == 'no'] + \
      [r['cycle'] for r in rows if r['arm'] == 'SCANOFF' and r['scan_ran'] == 'yes']
print("arm/measurement mismatches (scan_ran contradicts the arm): " + (', '.join(mis) if mis else 'none'))
EOF
