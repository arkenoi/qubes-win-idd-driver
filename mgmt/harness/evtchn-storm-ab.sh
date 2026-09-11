#!/bin/bash
# evtchn-storm-ab.sh - the defect-reintroduced proof for the xenbus bucket-lock wedge.
#
#   evtchn-storm-ab.sh <release-setup-tree-or-iso> <evtchnstorm.exe> [os]
#     <release-setup-tree-or-iso>  a package carrying pv-drivers/xenbus (the fixed driver)
#     <evtchnstorm.exe>            tools/evtchnstorm built by build.yml (idd-driver-package)
#     [os]                         win10 | win11 (default win11; the golden is <os>-qwt)
#   env: STORM_THREADS=4  STORM_SECONDS=900 (stock arm ceiling)  FIXED_MULT=3  POLL=20
#        OUT=<dir>  (default /home/user/rel/evtchn-storm-<utc>)
#        ARMS=both|stock|fixed  (default both). stock: run only the stock arm (package may be "-").
#        fixed: run only the fixed arm, taking the stock result from STOCK_VERDICT_PRIOR /
#        STOCK_T_PRIOR (copy them from a stock-only run's verdict.json) so the window is sized
#        the same way and the verdict is graded the same way.
#
# WHAT IT PROVES. The stall is a phantom writer bit on a xenbus hash-table bucket lock, planted
# when two event-channel closes collide on two CPUs (findings/issues.md, stall entry). Every
# qrexec connection is one open + one close in the guest, so the field trigger is qrexec churn.
# evtchnstorm.exe is that churn with the transport removed: N threads opening and closing
# unbound channels as fast as xeniface allows.
#
#   arm STOCK  = a clone of the <os>-qwt golden, untouched (prebuilt xenbus 9.1.0.0), stormed.
#                It MUST wedge. If it does not, the reproducer is unproven and the run is VOID -
#                a check that has never been seen to fail is not evidence (rig-cycle rule 6).
#   arm FIXED  = quick-upgrade.sh with the package (xenbus 9.1.0.<run>), the RUNNING driver's
#                version asserted on the guest, stormed for FIXED_MULT x the stock time-to-wedge
#                (never less than STORM_SECONDS/3). It MUST NOT wedge.
#
# WEDGE = qrexec dead on two consecutive polls while the domain still burns >= 60% of a core.
# Burn alone cannot classify here: a healthy guest under a 4-thread storm burns ~4 cores by
# design. qrexec death is the discriminator; the burn distinguishes a wedge from a dead domain.
#
# Exits: 0 PASS (stock wedged, fixed survived), 1 FAIL (fixed wedged), 2 VOID (stock did not
# wedge, storm did not start, or a precondition failed), 3 REFUSED.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$HERE" || exit 1
PKG="${1:?usage: evtchn-storm-ab.sh <setup-tree-or-iso> <evtchnstorm.exe> [os]}"
STORM="${2:?usage: evtchn-storm-ab.sh <setup-tree-or-iso> <evtchnstorm.exe> [os]}"
OS="${3:-win11}"
GOLDEN="$OS-qwt"
THREADS="${STORM_THREADS:-4}"
SECS="${STORM_SECONDS:-900}"
MULT="${FIXED_MULT:-3}"
POLL="${POLL:-20}"
ARMS="${ARMS:-both}"
OUT="${OUT:-/home/user/rel/evtchn-storm-$(date -u +%Y%m%dT%H%M%SZ)}"; mkdir -p "$OUT"
R="$OUT/summary.log"
say(){ echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$R"; }
INCOMING='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
GUEST_EXE="$INCOMING\\evtchnstorm.exe"

source mgmt/harness/vmlock.sh
source mgmt/harness/e2e-wait.sh

cput(){ printf '' | qrexec-client-vm "$1" admin.vm.CurrentState 2>/dev/null | tr -d '\000' | grep -oE 'cputime=[0-9]+' | cut -d= -f2; }
burn_pct(){ # $1=vm $2=seconds -> integer % of a core over the window, or "unknown"
  local a b; a=$(cput "$1"); sleep "$2"; b=$(cput "$1")
  if [ -n "$a" ] && [ -n "$b" ]; then python3 -c "print(f'{(int(\"$b\")-int(\"$a\"))/1e9/$2*100:.0f}')"; else echo unknown; fi
}
xenbus_ver(){ g_probe "$1" XBV 'Write-Host ("XBV=" + (Get-Item C:\Windows\System32\drivers\xenbus.sys).VersionInfo.FileVersion)' 60; }

# ---- preconditions -------------------------------------------------------------------------
[ -f "$STORM" ] || { say "REFUSED: $STORM is not a file"; exit 3; }
[ "$ARMS" = stock ] || [ -e "$PKG" ] || { say "REFUSED: package $PKG does not exist"; exit 3; }
case "$ARMS" in both|stock|fixed) ;; *) say "REFUSED: ARMS must be both|stock|fixed"; exit 3 ;; esac
qvm-check --quiet "$GOLDEN" 2>/dev/null || { say "REFUSED: golden $GOLDEN does not exist"; exit 3; }
busy=$(pgrep -f "[a]cceptance-races|[m]gmt/harness/matrix.sh|[p]rime-run.sh|[q]uick-upgrade.sh" | head -3)
[ -z "$busy" ] || { say "REFUSED: another VM-driving job is running (pids: $busy)"; exit 3; }
say "=== evtchn storm A/B: golden=$GOLDEN threads=$THREADS stock-ceiling=${SECS}s poll=${POLL}s out=$OUT ==="

STORM_PGID=""
stop_storm(){ [ -n "$STORM_PGID" ] && { kill -TERM -- "-$STORM_PGID" 2>/dev/null; sleep 1; kill -KILL -- "-$STORM_PGID" 2>/dev/null; }; STORM_PGID=""; }

# ---- one storm run against a live, session-up subject ------------------------------------
# storm <vm> <label> <seconds> -> sets STORM_VERDICT (WEDGED|CLEAN|VOID) and STORM_T (seconds)
storm(){
  local vm=$1 lbl=$2 secs=$3 t0 now dead=0 b st rc
  STORM_VERDICT=VOID; STORM_T=0
  QTEST_VM=$vm ./tools/qtest synctime >/dev/null 2>&1
  QTEST_VM=$vm ./tools/qtest push "$STORM" >"$OUT/$lbl-push.out" 2>&1 || { say "  $lbl: push failed: $(tail -1 "$OUT/$lbl-push.out")"; return; }
  say "  $lbl: launching evtchnstorm $THREADS threads for ${secs}s"
  # setsid: the storm is its own process group so that stopping it kills the qrexec-client-vm
  # child too. A lingering qrexec call AUTO-STARTS a halted qube (the "queued qrexec restarts
  # guests" trap): the first run's discard killed the subject and a still-pending call started
  # it again, so qvm-remove failed and the guest was left Running.
  setsid bash -c "QTEST_VM=$vm exec timeout -k 10 $((secs + 180)) ./tools/qtest run '\"$GUEST_EXE\" $THREADS $secs 0'" > "$OUT/$lbl-storm.out" 2>&1 &
  local spid=$!
  STORM_PGID=$spid
  t0=$(date +%s)
  # The storm must PROVE it started: the tool prints a probe line after one successful
  # open/close. Without it a missing xencontrol.dll would read as "did not wedge".
  for i in $(seq 1 12); do sleep 5; grep -qa 'probe: open/close' "$OUT/$lbl-storm.out" && break; done
  if ! grep -qa 'probe: open/close' "$OUT/$lbl-storm.out"; then
    say "  $lbl: VOID - storm never reported its probe line: $(tr -d '\r' < "$OUT/$lbl-storm.out" | tail -2 | tr '\n' ' ')"
    stop_storm; return
  fi
  say "  $lbl: storm running ($(grep -a 'xencontrol:' "$OUT/$lbl-storm.out" | head -1 | tr -d '\r'))"
  while :; do
    now=$(( $(date +%s) - t0 ))
    if grep -qa '=== RESULT ===' "$OUT/$lbl-storm.out"; then
      say "  $lbl: storm finished at t+${now}s: $(grep -a '=== RESULT ===' "$OUT/$lbl-storm.out" | tr -d '\r')"
      if w_alive "$vm"; then STORM_VERDICT=CLEAN; STORM_T=$now; say "  $lbl: CLEAN - qrexec answers after the storm"; else say "  $lbl: storm reported a result but qrexec is dead - classifying below"; fi
      [ "$STORM_VERDICT" = CLEAN ] && return
    fi
    if w_alive "$vm"; then
      dead=0
      [ $(( now % 120 )) -lt "$POLL" ] && say "  $lbl: t+${now}s alive, $(grep -a '^t=' "$OUT/$lbl-storm.out" | tail -1 | tr -d '\r')"
    else
      dead=$(( dead + 1 ))
      b=$(burn_pct "$vm" 15)
      say "  $lbl: t+${now}s qrexec DEAD (#$dead), burn=${b}% of a core, qvm=$(w_state "$vm")"
      if [ "$dead" -ge 2 ] && [ "$b" != unknown ] && [ "${b%%.*}" -ge 60 ]; then
        STORM_VERDICT=WEDGED; STORM_T=$now
        say "  $lbl: WEDGED at t+${now}s (qrexec dead x2, ${b}% of a core sustained)"
        QTEST_VM=$vm ./tools/qtest wedge "$OUT/$lbl-wedge" >/dev/null 2>&1 && say "  $lbl: dom0 forensics in $OUT/$lbl-wedge" || say "  $lbl: dom0 forensics capture unavailable"
        stop_storm; return
      fi
      if [ "$dead" -ge 4 ]; then
        say "  $lbl: qrexec dead x$dead without the spin signature (burn=${b}%) - UNCLASSIFIED, treated as VOID"
        stop_storm; return
      fi
    fi
    if [ "$now" -ge $((secs + 150)) ]; then
      say "  $lbl: t+${now}s storm overran its window without a result line - VOID"
      stop_storm; return
    fi
    sleep "$POLL"
  done
}

discard(){ # a stormed subject is never reused: kill (it is being discarded), wait, remove
  local vm=$1 i
  stop_storm
  pkill -f "qrexec-client-vm [${vm:0:1}]${vm:1} " 2>/dev/null; sleep 1   # nothing pending may restart it
  vm_unlock "$vm" 2>/dev/null
  qvm-kill "$vm" >/dev/null 2>&1; w_halt "$vm" 120 "discard-$vm" say >/dev/null 2>&1
  # Halted must HOLD: a queued call restarts a killed qube within seconds.
  for i in 1 2 3; do sleep 5; [ "$(w_state "$vm")" = Halted ] || { say "  $vm came back ($(w_state "$vm")) after kill - killing again"; pkill -f "qrexec-client-vm [${vm:0:1}]${vm:1} " 2>/dev/null; qvm-kill "$vm" >/dev/null 2>&1; }; done
  if qvm-remove -f "$vm" >/dev/null 2>&1; then say "  $vm discarded"; else say "  WARNING: could not remove $vm (state $(w_state "$vm")) - clean it by hand before the next run"; fi
}

# ==== ARM 1: STOCK ==========================================================================
S1="$OS-storm-stock"
STOCK_VERDICT="${STOCK_VERDICT_PRIOR:-SKIPPED}"; STOCK_T="${STOCK_T_PRIOR:-0}"
if [ "$ARMS" != fixed ]; then
say "--- arm STOCK: $S1 from $GOLDEN, prebuilt xenbus ---"
if qvm-check --quiet "$S1" 2>/dev/null; then
  [ "$(w_state "$S1")" = Halted ] || { qvm-kill "$S1" >/dev/null 2>&1; w_halt "$S1" 120 "leftover-$S1" say >/dev/null; }
  qvm-remove -f "$S1" >/dev/null 2>&1 || { say "VOID: could not remove leftover $S1"; exit 2; }
fi
vm_lock "$S1"
qvm-create --class StandaloneVM --label red --property virt_mode=hvm --property kernel='' "$S1" || { say "VOID: create $S1 failed"; exit 2; }
qvm-tags "$S1" add win-idd-testbed || { say "VOID: tag $S1 failed"; exit 2; }
qvm-features "$S1" os Windows
for p in memory:8192 maxmem:8192 vcpus:4 qrexec_timeout:600; do qvm-prefs "$S1" "${p%%:*}" "${p##*:}"; done
qvm-prefs "$S1" netvm '' 2>/dev/null
cerr=$(python3 - "$GOLDEN" "$S1" 2>&1 <<'PY'
import sys, qubesadmin
app = qubesadmin.Qubes(); src = app.domains[sys.argv[1]]; dst = app.domains[sys.argv[2]]
for v in ('root', 'private'):
    dst.volumes[v].clone(src.volumes[v])
PY
) || { say "VOID: volume clone failed: $(echo "$cerr" | tail -1 | cut -c1-200)"; exit 2; }
say "  cloned $GOLDEN -> $S1"
qvm-start "$S1" >"$OUT/stock-start.out" 2>&1 || { say "VOID: qvm-start $S1 failed: $(tail -1 "$OUT/stock-start.out")"; exit 2; }
w_session "$S1" 600 "stock-boot" "$OUT" say || { say "VOID: $S1 never came up"; exit 2; }
v=$(xenbus_ver "$S1"); say "  stock xenbus.sys FileVersion on the guest: '${v:-unreadable}'"
case "$v" in 9.1.0.0) ;; *) say "VOID: the stock arm must run the prebuilt xenbus 9.1.0.0, got '${v:-unreadable}'"; exit 2 ;; esac
storm "$S1" stock "$SECS"
STOCK_VERDICT=$STORM_VERDICT; STOCK_T=$STORM_T
discard "$S1"
say "--- arm STOCK verdict: $STOCK_VERDICT (t=${STOCK_T}s) ---"
if [ "$ARMS" = stock ]; then
  printf '{"golden":"%s","threads":%s,"stock":{"verdict":"%s","t":%s}}\n' "$GOLDEN" "$THREADS" "$STOCK_VERDICT" "$STOCK_T" > "$OUT/verdict.json"
  say "stock-only run complete: $OUT/verdict.json (feed STOCK_VERDICT_PRIOR=$STOCK_VERDICT STOCK_T_PRIOR=$STOCK_T to ARMS=fixed)"
  [ "$STOCK_VERDICT" = WEDGED ] && exit 0 || exit 2
fi
else
  say "--- arm STOCK skipped (ARMS=fixed): prior verdict $STOCK_VERDICT t=${STOCK_T}s ---"
fi

# ==== ARM 2: FIXED ==========================================================================
S2="$OS-storm-fixed"
say "--- arm FIXED: quick-upgrade $S2 with $PKG ---"
if ! ./mgmt/harness/quick-upgrade.sh "$PKG" "$S2" "$OS" >"$OUT/fixed-quick-upgrade.out" 2>&1; then
  say "VOID: quick-upgrade failed (rc=$?): $(tail -3 "$OUT/fixed-quick-upgrade.out" | tr '\n' ' ' | cut -c1-300)"
  exit 2
fi
say "  quick-upgrade verified ($(grep -a 'VERIFIED\|PASS' "$OUT/fixed-quick-upgrade.out" | tail -1 | cut -c1-120))"
vm_lock "$S2"
w_alive "$S2" || { say "VOID: $S2 not answering after quick-upgrade"; exit 2; }
v=$(xenbus_ver "$S2"); say "  fixed xenbus.sys FileVersion on the guest: '${v:-unreadable}'"
case "$v" in 9.1.0.0|"") say "VOID: the fixed arm is still running xenbus '${v:-unreadable}' - the package did not replace the driver, nothing to grade"; exit 2 ;; esac
grep -a 'pv_xenbus' "$OUT/fixed-quick-upgrade.out" | tail -1 | sed 's/^/  /' | tee -a "$R"
FSECS=$(( STOCK_T * MULT )); [ "$FSECS" -lt $((SECS / 3)) ] && FSECS=$((SECS / 3)); [ "$STOCK_VERDICT" = WEDGED ] || FSECS=$SECS
storm "$S2" fixed "$FSECS"
FIXED_VERDICT=$STORM_VERDICT; FIXED_T=$STORM_T
say "--- arm FIXED verdict: $FIXED_VERDICT (t=${FIXED_T}s, window ${FSECS}s) ---"

# ==== VERDICT ================================================================================
printf '{"golden":"%s","threads":%s,"stock":{"verdict":"%s","t":%s},"fixed":{"verdict":"%s","t":%s,"window":%s,"xenbus":"%s"}}\n' \
  "$GOLDEN" "$THREADS" "$STOCK_VERDICT" "$STOCK_T" "$FIXED_VERDICT" "$FIXED_T" "$FSECS" "$v" > "$OUT/verdict.json"
case "$STOCK_VERDICT/$FIXED_VERDICT" in
  WEDGED/CLEAN)  say "PASS: stock wedged at ${STOCK_T}s; fixed xenbus $v survived ${FSECS}s of the same storm. $S2 left running."; exit 0 ;;
  WEDGED/WEDGED) say "FAIL: the FIXED driver wedged too (t=${FIXED_T}s vs stock ${STOCK_T}s). $S2 left as evidence in $OUT."; exit 1 ;;
  */*)           say "VOID: stock=$STOCK_VERDICT fixed=$FIXED_VERDICT - the reproducer did not prove itself on stock, so the fixed arm's result is not evidence."; exit 2 ;;
esac
