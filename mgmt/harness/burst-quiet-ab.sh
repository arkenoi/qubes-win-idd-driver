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
#   harness BURST = ROUNDS rounds of PUSHES concurrent file copies + CALLS concurrent short calls
#           right after the session appears; QUIET = none. The updater is left as installed.
#   Session-up is read from dom0's per-window capture (local.WinScreenshot runs in dom0 and never
#   touches the guest). Same subject, same build, same boot, same end-of-window read, same ACPI
#   shutdown. Arms alternate so rig drift and time of day are shared.
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
#     BOOT-*               no session within BOOT_DL - graded, but kept apart
#   Validate before trusting it: VALIDATE=1 drives the DEAD branch (QrexecAgent stopped in the
#   guest -> must read QREXEC-DEAD-ACPI-OK) and the STALL branch (domain paused across the ACPI
#   request -> must read STALL).
# BUDGET: ~6.5 min a cycle for scan (boot ~100 s, window 240 s, settle 60 s, read + shutdown ~40 s),
#   ~5.5 min for harness; default 20 cycles per arm. A subject that will not halt is drained, killed
#   and RE-CLONED from its park - a killed subject is never reused. No memory image, no forensics
#   (owner, 2026-09-27).
#
#   VM=<subject> PARK=<ckpt-qube> [VARIANT=scan|harness] mgmt/harness/burst-quiet-ab.sh
#   env: CYCLES (per arm, 20)  WINDOW (240 scan / 180 harness)  SETTLE (60)  BOOT_DL (300)
#        ROUNDS (4)  PUSHES (6)  CALLS (16)  VALIDATE=1  OUT=<evidence dir>
set -u
cd "$(dirname "$0")/../.." || exit 3
VM=${VM:?set VM - the subject; there is no default target}
PARK=${PARK:?set PARK - the parked qube the subject is re-cloned from after a stall}
VARIANT=${VARIANT:-scan}
case "$VARIANT" in
  scan)    ARMS=(SCANON SCANOFF); WINDOW=${WINDOW:-240} ;;
  harness) ARMS=(BURST QUIET);    WINDOW=${WINDOW:-180} ;;
  *) echo "VARIANT must be scan or harness" >&2; exit 3 ;;
esac
CYCLES=${CYCLES:-20}; SETTLE=${SETTLE:-60}; BOOT_DL=${BOOT_DL:-300}
ROUNDS=${ROUNDS:-4}; PUSHES=${PUSHES:-6}; CALLS=${CALLS:-16}
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

# Session-up WITHOUT touching the guest's qrexec: dom0's per-window capture until a window shows
# rendered content, on TWO consecutive samples (Jev probe review: one sample is not a stable
# state). 0 = session (SESS_T = seconds to the first of the two), 1 = none by BOOT_DL.
wait_session_quietly(){ # $1=tag
  local t0 st=none seen=; t0=$(date +%s)
  while :; do
    SESS_T=$(( $(date +%s) - t0 ))
    [ "$SESS_T" -ge "$BOOT_DL" ] && { SESS_T="none-by-${BOOT_DL}s(last=$st)"; return 1; }
    st=$(w_screen "$VM" "$1-t$SESS_T" "$OUT/shots")
    case "$st" in
      DESKTOP)  [ -n "$seen" ] && { SESS_T=$seen; return 0; }; seen=$SESS_T ;;
      RECOVERY) SESS_T=RECOVERY; return 1 ;;
      *)        seen= ;;
    esac
    sleep 10
  done
}

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
  log "  restore: $VM re-cloned from $PARK"
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

boot(){ # -> 0 started
  local st; st=$(w_state "$VM")
  if [ "$st" != Halted ]; then
    # Something started it (a queued call can) - shut it down cleanly first; only a subject that
    # will not halt is rebuilt.
    log "  WARNING: $VM is $st before the boot - ACPI shutdown first"
    timeout 60 qvm-shutdown "$VM" >/dev/null 2>&1
    w_halt "$VM" 300 "preboot-halt" log >/dev/null || restore_subject
  fi
  timeout 180 qvm-start "$VM" >/dev/null 2>&1 || { log "TERMINAL: qvm-start $VM failed"; exit 1; }
}

want_state(){ case "$1" in SCANON) echo on ;; SCANOFF) echo off ;; *) echo keep ;; esac; }

if [ "${VALIDATE:-0}" = 1 ]; then
  log "=== VALIDATE: each branch must be seen to return its class ==="
  boot; wait_session_quietly v1 || { log "VALIDATE: no session (${SESS_T}) - cannot validate"; exit 1; }
  w_alive "$VM" || { log "VALIDATE FAIL: a healthy session did not answer the liveness probe"; exit 1; }
  end_read keep && log "  healthy session answers; end-of-window read: ran=$READ_RAN state=$READ_STATE calls=$READ_CALLS svc=$READ_SVC log=$READ_LOG" \
    || { log "VALIDATE FAIL: the end-of-window read returned nothing on a healthy guest"; exit 1; }
  QTEST_VM="$VM" timeout -k 5 40 ./tools/qtest run 'cmd /c sc stop QrexecAgent' >/dev/null 2>&1
  sleep 15; probe_alive; shut_and_classify v1
  log "  QrexecAgent stopped -> $CLS (expected QREXEC-DEAD-ACPI-OK) alive=$ALIVE halt=$HALT cpu=$CPU"
  [ "$CLS" = QREXEC-DEAD-ACPI-OK ] || { log "VALIDATE FAIL: the DEAD branch returned $CLS"; case "$HALT" in halted*) ;; *) restore_subject ;; esac; exit 1; }
  boot; wait_session_quietly v2 || { log "VALIDATE: no session on the second boot (${SESS_T})"; exit 1; }
  qvm-pause "$VM" >/dev/null 2>&1 || { log "VALIDATE: qvm-pause refused"; exit 1; }
  probe_alive; shut_and_classify v2
  log "  domain paused across the ACPI request -> $CLS (expected STALL) alive=$ALIVE halt=$HALT"
  qvm-unpause "$VM" >/dev/null 2>&1
  timeout 60 qvm-shutdown "$VM" >/dev/null 2>&1; w_halt "$VM" 240 "v2-unpaused" log >/dev/null || restore_subject
  [ "$CLS" = STALL ] || { log "VALIDATE FAIL: the STALL branch returned $CLS"; exit 1; }
  log "VALIDATE PASS: ALIVE, DEAD and STALL branches each seen to return their class; the read has data"
  exit 0
fi

# One boot: quiet session wait, the arm's activity, end-of-window read (+ next state), shutdown.
# $1=cycle label $2=arm $3=next-state(on|off|keep). Appends a TSV row; updates NEXT_SCAN.
run_boot(){
  local c=$1 arm=$2 next=$3 start t0 end now r due res bursts=- pre=$NEXT_SCAN
  log "--- $c arm=$arm (scan state going in: $pre) ---"
  boot; start=$(date +%H:%M:%S)
  if ! wait_session_quietly "$c"; then
    probe_alive; READ_RAN=; READ_CALLS=; READ_SVC=; READ_SET=
    [ "$ALIVE" = alive ] && end_read "$next"
    shut_and_classify "$c"; CLS="BOOT-$CLS"
  else
    log "  session at +${SESS_T}s (dom0 window capture; no guest qrexec yet)"
    t0=$(date +%s)
    if [ "$arm" = BURST ]; then
      bursts=""
      for r in $(seq 1 "$ROUNDS"); do
        due=$(( t0 + (r - 1) * WINDOW / ROUNDS )); now=$(date +%s); [ "$now" -lt "$due" ] && sleep $(( due - now ))
        res=$(burst_round "$c" "$r"); bursts="$bursts r$r:$res"
        log "  burst round $r: $res"
      done
      bursts=${bursts# }
    fi
    end=$(( t0 + WINDOW + SETTLE )); now=$(date +%s); [ "$now" -lt "$end" ] && sleep $(( end - now ))
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
  rm -f "$OUT/shots"/"$c"-*          # the per-window captures served their purpose; keep the table
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
