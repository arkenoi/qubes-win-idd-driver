#!/bin/bash
# burst-quiet-ab.sh - does OUR post-boot qrexec burst provoke the guest stall?
#
# HYPOTHESIS: the stall needs a burst of qrexec bridge processes (each maps grant pages into its
#   own user address space and unmaps them at exit) in the first minutes after a boot. Jev
#   2026-09-28, judged from every recorded occurrence and negative: implicated behaviour =
#   qrexec bridge churn 0.91; the most material unmeasured fact = the stall rate WITHOUT such a
#   burst 0.93; best single A/B = this one 0.49. REFUTED if the QUIET arm stalls about as often as
#   the BURST arm. UNSUPPORTED (not refuted) if the BURST arm does not stall at all.
# BASELINE: 2026-09-27, census cold boots on win11de clones: 3 stalls in ~25 boots, every one
#   inside a harness burst in the first minutes after qrexec came up. The QUIET control has never
#   been run - that is the gap this closes.
# VARIABLE: ONE. The first WINDOW seconds after the session appears:
#   BURST = ROUNDS rounds, each PUSHES concurrent file copies (qubes.Filecopy) + CALLS concurrent
#           short qubes.VMShell calls - heavier than the natural onset on purpose, so a real effect
#           shows within the budget (the 2026-08-20 specimen held 38 concurrent bridges);
#   QUIET = no qrexec call INTO THE GUEST at all. Session-up is read from dom0's per-window capture
#           (local.WinScreenshot runs in dom0 and never touches the guest).
#   Same subject, same build, same boot, same liveness check, same ACPI shutdown. Arms alternate
#   B,Q,B,Q so rig drift and time of day are shared.
# INSTRUMENT: after WINDOW+SETTLE, qrexec liveness (two tries, 20 s apart) and the cpu delta, then
#   an ACPI shutdown with a 180 s halt deadline plus a 120 s second window that re-probes qrexec (a
#   slow shutdown must not read as a wedge). Classes:
#     OK / OK-SLOW-HALT    answered, halted (in the first / the second window)
#     STALL                qrexec dead AND ACPI ignored            <- the primary endpoint
#     SHUTDOWN-HANG        answered, but ACPI ignored              <- secondary (the 09-21 shape)
#     QREXEC-DEAD-ACPI-OK  dead but halted - the qrexec-not-started defect of findings/install.md,
#                          NOT the stall, counted apart
#     BOOT-*               no session within BOOT_DL - BEFORE the variable applied: counts for
#                          neither arm
#   Validate before trusting it: VALIDATE=1 drives the DEAD branch (QrexecAgent stopped in the
#   guest -> must read QREXEC-DEAD-ACPI-OK) and the STALL branch (domain paused across the ACPI
#   request -> must read STALL), and nothing else.
# BUDGET: ~5.5 min a cycle (boot ~100 s, window 180 s, settle 60 s, shutdown ~20 s); default 20
#   cycles per arm, ~3.7 h. A subject that will not halt is drained, killed and RE-CLONED from its
#   park - a killed subject is never reused. No memory image, no forensics (owner, 2026-09-27).
#
#   VM=<subject> PARK=<ckpt-qube> mgmt/harness/burst-quiet-ab.sh
#   env: CYCLES (per arm, 20)  WINDOW (180)  SETTLE (60)  BOOT_DL (300)  ROUNDS (4)  PUSHES (6)
#        CALLS (16)  ORDER (BQ = burst first)  VALIDATE=1  OUT=<evidence dir>
set -u
cd "$(dirname "$0")/../.." || exit 3
VM=${VM:?set VM - the subject; there is no default target}
PARK=${PARK:?set PARK - the parked qube the subject is re-cloned from after a stall}
CYCLES=${CYCLES:-20}; WINDOW=${WINDOW:-180}; SETTLE=${SETTLE:-60}; BOOT_DL=${BOOT_DL:-300}
ROUNDS=${ROUNDS:-4}; PUSHES=${PUSHES:-6}; CALLS=${CALLS:-16}; ORDER=${ORDER:-BQ}
OUT=${OUT:-$HOME/qwt-burst-quiet/$VM-$(date +%Y%m%d-%H%M%S)}
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
# rendered content. 0 = session (SESS_T = seconds), 1 = none by BOOT_DL (SESS_T = why).
wait_session_quietly(){ # $1=tag
  # TWO consecutive DESKTOP samples (Jev probe review: one sample is not a stable state). The
  # session time recorded is the FIRST of the two.
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
  local c=$1 r=$2 i f pids=() ok=0 tot=0 mx=0 line
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
  [ "$tot" -eq $((PUSHES + CALLS)) ] || tot=$((PUSHES + CALLS))
  rm -f "$OUT/push"/bq-c"$c"-r"$r"-*.bin
  echo "ok=$ok/$tot max=${mx}s"
}

alive_twice(){ w_alive "$VM" && return 0; sleep 20; w_alive "$VM"; }

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
}

# Liveness, cpu, ACPI shutdown -> the class. Sets CLS, ALIVE, CPU, HALT.
grade(){ # $1=label
  ALIVE=dead; alive_twice && ALIVE=alive
  CPU=$(w_cpu_state "$VM" 10)
  timeout 60 qvm-shutdown "$VM" >/dev/null 2>&1
  HALT=ignored; w_halt "$VM" 180 "$1-halt" log >/dev/null && HALT=halted
  if [ "$HALT" = ignored ]; then
    # Not yet a verdict (Jev probe review: a fixed deadline stands in for the condition). A slow
    # shutdown halts in the second window; a wedged guest stays up AND deaf through both.
    [ "$ALIVE" = dead ] && w_alive "$VM" && ALIVE=alive-late
    w_halt "$VM" 120 "$1-halt2" log >/dev/null && HALT=halted-late
    CPU="$CPU / after-deadline $(w_cpu_state "$VM" 10)"
  fi
  case "$ALIVE/$HALT" in
    alive/halted*|alive-late/halted*) CLS=OK; [ "$HALT" = halted-late ] && CLS=OK-SLOW-HALT ;;
    alive*/ignored)                   CLS=SHUTDOWN-HANG ;;
    dead/halted*)                     CLS=QREXEC-DEAD-ACPI-OK ;;
    dead/ignored)                     CLS=STALL ;;
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

if [ "${VALIDATE:-0}" = 1 ]; then
  log "=== VALIDATE: each branch must be seen to return its class ==="
  boot; wait_session_quietly v1 || { log "VALIDATE: no session (${SESS_T}) - cannot validate"; exit 1; }
  w_alive "$VM" || { log "VALIDATE FAIL: a healthy session did not answer the liveness probe"; exit 1; }
  log "  healthy session answers (the ALIVE branch has data)"
  QTEST_VM="$VM" timeout -k 5 40 ./tools/qtest run 'cmd /c sc stop QrexecAgent' >/dev/null 2>&1
  sleep 15; grade v1
  log "  QrexecAgent stopped -> $CLS (expected QREXEC-DEAD-ACPI-OK) alive=$ALIVE halt=$HALT cpu=$CPU"
  [ "$CLS" = QREXEC-DEAD-ACPI-OK ] || { log "VALIDATE FAIL: the DEAD branch returned $CLS"; case "$HALT" in halted*) ;; *) restore_subject ;; esac; exit 1; }
  boot; wait_session_quietly v2 || { log "VALIDATE: no session on the second boot (${SESS_T})"; exit 1; }
  qvm-pause "$VM" >/dev/null 2>&1 || { log "VALIDATE: qvm-pause refused"; exit 1; }
  grade v2
  log "  domain paused across the ACPI request -> $CLS (expected STALL) alive=$ALIVE halt=$HALT"
  qvm-unpause "$VM" >/dev/null 2>&1
  timeout 60 qvm-shutdown "$VM" >/dev/null 2>&1; w_halt "$VM" 240 "v2-unpaused" log >/dev/null || restore_subject
  [ "$CLS" = STALL ] || { log "VALIDATE FAIL: the STALL branch returned $CLS"; exit 1; }
  log "VALIDATE PASS: ALIVE, DEAD and STALL branches each seen to return their class"
  exit 0
fi

printf 'cycle\tarm\tstart\tsession\tbursts\talive\tcpu\thalt\tclass\n' > "$TSV"
log "=== burst-vs-quiet: $CYCLES cycles per arm, order $ORDER, window ${WINDOW}s, settle ${SETTLE}s; burst = $ROUNDS x ($PUSHES copies + $CALLS calls) ==="
total=$((CYCLES * 2))
for cyc in $(seq 1 "$total"); do
  if [ $(( cyc % 2 )) = 1 ]; then arm=${ORDER:0:1}; else arm=${ORDER:1:1}; fi
  [ "$arm" = B ] && ARM=BURST || ARM=QUIET
  log "--- cycle $cyc/$total arm=$ARM ---"
  boot; start=$(date +%H:%M:%S)
  if ! wait_session_quietly "c$cyc"; then
    # Before the variable applied: probe now (the arm is void either way) and grade.
    grade "c$cyc"; cls="BOOT-$CLS"
    log "  no session ($SESS_T) -> $cls alive=$ALIVE halt=$HALT cpu=$CPU"
    printf '%s\t%s\t%s\t%s\t-\t%s\t%s\t%s\t%s\n' "$cyc" "$ARM" "$start" "$SESS_T" "$ALIVE" "$CPU" "$HALT" "$cls" >> "$TSV"
    case "$HALT" in halted*) ;; *) restore_subject ;; esac
    continue
  fi
  log "  session at +${SESS_T}s (dom0 window capture; no guest qrexec yet)"
  t0=$(date +%s); bursts=-
  if [ "$ARM" = BURST ]; then
    bursts=""
    for r in $(seq 1 "$ROUNDS"); do
      due=$(( t0 + (r - 1) * WINDOW / ROUNDS )); now=$(date +%s); [ "$now" -lt "$due" ] && sleep $(( due - now ))
      res=$(burst_round "$cyc" "$r"); bursts="$bursts r$r:$res"
      log "  burst round $r: $res"
    done
  fi
  end=$(( t0 + WINDOW + SETTLE )); now=$(date +%s); [ "$now" -lt "$end" ] && sleep $(( end - now ))
  grade "c$cyc"
  log "  => $CLS (alive=$ALIVE halt=$HALT cpu=$CPU)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$cyc" "$ARM" "$start" "$SESS_T" "${bursts# }" "$ALIVE" "$CPU" "$HALT" "$CLS" >> "$TSV"
  rm -f "$OUT/shots"/c"$cyc"-*          # the per-window captures served their purpose; keep the table
  case "$HALT" in halted*) ;; *) restore_subject ;; esac
done

log "=== RESULT (primary endpoint: STALL after the variable applied) ==="
python3 - "$TSV" <<'EOF' | tee -a "$LOG"
import csv, sys, math
rows = list(csv.DictReader(open(sys.argv[1]), delimiter='\t'))
arms = {'BURST': {}, 'QUIET': {}}
for r in rows:
    arms.setdefault(r['arm'], {}); arms[r['arm']][r['class']] = arms[r['arm']].get(r['class'], 0) + 1
for a, d in arms.items():
    print(f"{a:5s} " + ' '.join(f"{k}={v}" for k, v in sorted(d.items())))
def n(a, k): return arms[a].get(k, 0)
graded = lambda a: sum(v for k, v in arms[a].items() if not k.startswith('BOOT-'))
b, q = n('BURST', 'STALL'), n('QUIET', 'STALL'); nb, nq = graded('BURST'), graded('QUIET')
def fisher_one_sided(a, n1, c, n2):   # P(X >= a) for the burst arm, hypergeometric
    K, N = a + c, n1 + n2
    tot = math.comb(N, n1)
    return sum(math.comb(K, x) * math.comb(N - K, n1 - x) for x in range(a, min(K, n1) + 1)) / tot if tot else float('nan')
print(f"STALL burst {b}/{nb} vs quiet {q}/{nq}; one-sided Fisher p = {fisher_one_sided(b, nb, q, nq):.4f}")
EOF
