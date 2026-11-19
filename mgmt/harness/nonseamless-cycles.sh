#!/usr/bin/env bash
# nonseamless-cycles.sh <vm> <outdir> [cycles] - the non-seamless desktop entered and left through dom0's own
# qubes.SetGuiMode, graded on what dom0 shows and what the agent did, then a clean restart (docs/ADR-capture.md 33).
#
# The subject must be RUNNING with a session in seamless mode (quick-upgrade leaves one after its last boot).
# EVERY ENTRY PUTS THE WHOLE GUEST DESKTOP ON THE SCREEN AS ONE DOM0 WINDOW (owner 2026-10-06, "why i see
# near-fullscreen windows again"): say so before running it, with how long it takes.
#
# Per cycle:
#   entry   the guest's dom0 windows are photographed (w_screen, per window) until the largest is the desktop
#           (verdict DESKTOP) - a black, missing or recovery desktop at the deadline is a FAIL;
#   return  photographed until no window of the entry's desktop size is left - one still there is a FAIL.
# After the cycles, a clean shutdown, then from the log volume read on the host (halted: everything is on it):
#   on 26200+ (the agent's "WGCBROKER gate: enabled=1"), one QGADESKENGINE "created" and one "released" line and one
#   "STAGING cleared" per cycle, no QGADESKENGINE ERROR and no CAPTUREABANDON; below the floor none of those lines.
# Then a boot (GRANTOWNERREVOKECRASH, findings/issues.md: the access violation came at the session
# end after non-seamless use): a crash record of one of our executables (Application 1000/1001) or an agent death
# record (4001/4002) newer than the newest one read before the first cycle is a FAIL. Records are compared by
# RecordId, never by the guest's clock. Last, mgmt/harness/log-sweep.sh from the start: undeclared errors FAIL.
#
# Exit 0 PASS, 1 FAIL (the product), 2 INSTRUMENT (no verdict; the product is not implicated).
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 2
VM="${1:?usage: $0 <vm> <outdir> [cycles]}"; OUT="${2:?usage: $0 <vm> <outdir> [cycles]}"; CYCLES="${3:-3}"
mkdir -p "$OUT/shots" || exit 2
export QTEST_VM="$VM"
T0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
log(){ printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$OUT/cycles.log"; }
source mgmt/harness/vmlock.sh
source mgmt/harness/e2e-wait.sh
source mgmt/harness/shutdown-lib.sh
source mgmt/harness/logvol-lib.sh
vm_lock "$VM" || { log "INSTRUMENT the vmlock was refused"; exit 2; }
trap 'vm_unlock "$VM"' EXIT
NF=0
fail(){ NF=$((NF+1)); log "FAIL $*"; }
# Ours only: the agent's own death records (provider 'Qubes Windows Tools', 4001/4002) and Windows' crash records
# naming one of our executables - the image name is not translated, so this holds on the German guest too.
APPEVT_PS="Get-WinEvent -FilterHashtable @{LogName='Application'; Id=1000,1001,4001,4002} -EA SilentlyContinue | Where-Object { \$_.ProviderName -eq 'Qubes Windows Tools' -or \$_.Message -match 'gui-agent|qrexec|wgcbroker|notifhost' }"

w_alive "$VM" 40 || { log "INSTRUMENT $VM does not answer qrexec - nothing switched"; exit 2; }
rec0=$(timeout 120 tools/qtest ps "\$m = ($APPEVT_PS | Measure-Object -Property RecordId -Maximum).Maximum; 'RECMAX=' + [int64]\$m" 2>/dev/null \
       | tr -d '\r' | sed -n 's/^RECMAX=\([0-9]*\)$/\1/p' | tail -1)
[ -n "$rec0" ] || { log "INSTRUMENT the Application log's last error record could not be read"; exit 2; }
log "baseline: newest error-class Application record $rec0"

desk_w=0; desk_h=0
for c in $(seq 1 "$CYCLES"); do
  printf 'FULLSCREEN' | timeout 60 qrexec-client-vm "$VM" qubes.SetGuiMode >"$OUT/setguimode-$c-FULLSCREEN.out" 2>&1
  log "cycle $c: qubes.SetGuiMode FULLSCREEN sent (rc=$?)"
  t0=$SECONDS; v=""
  while :; do
    v=$(w_screen "$VM" "c$c-entry" "$OUT/shots")
    [ "$v" = DESKTOP ] && break
    [ $((SECONDS - t0)) -ge 60 ] && break
    w_alive "$VM" 40 || { log "INSTRUMENT cycle $c: the guest stopped answering during the entry"; exit 2; }
    sleep 3
  done
  dims=$(file "$OUT/shots/c$c-entry.png" 2>/dev/null | sed -n 's/.*PNG image data, \([0-9]*\) x \([0-9]*\).*/\1 \2/p')
  if [ "$v" = DESKTOP ] && [ -n "$dims" ]; then
    read -r desk_w desk_h <<<"$dims"
    log "cycle $c entry: the desktop window shows the desktop (${desk_w}x${desk_h}) at t+$((SECONDS - t0))s"
  else
    fail "cycle $c entry: after 60 s the largest window of $VM read '$v' (${dims:-no image}), not the desktop"
  fi

  printf 'SEAMLESS' | timeout 60 qrexec-client-vm "$VM" qubes.SetGuiMode >"$OUT/setguimode-$c-SEAMLESS.out" 2>&1
  log "cycle $c: qubes.SetGuiMode SEAMLESS sent (rc=$?)"
  t0=$SECONDS; left=""
  while :; do
    rm -rf "$OUT/shots/c$c-return.ex"; mkdir -p "$OUT/shots/c$c-return.ex"
    QTEST_VM=$VM timeout -k 8 150 ./tools/qtest shot "$OUT/shots/c$c-return.tar" >/dev/null 2>&1
    tar xf "$OUT/shots/c$c-return.tar" -C "$OUT/shots/c$c-return.ex" 2>/dev/null
    left=""
    for p in "$OUT/shots/c$c-return.ex"/*.png; do
      [ -e "$p" ] || continue
      read -r pw ph < <(file "$p" | sed -n 's/.*PNG image data, \([0-9]*\) x \([0-9]*\).*/\1 \2/p')
      [ "$desk_w" -gt 0 ] && [ "${pw:-0}" -ge $((desk_w * 9 / 10)) ] && [ "${ph:-0}" -ge $((desk_h * 9 / 10)) ] \
        && left="$(basename "$p") ${pw}x${ph}"
    done
    [ -z "$left" ] && break
    [ $((SECONDS - t0)) -ge 60 ] && break
    w_alive "$VM" 40 || { log "INSTRUMENT cycle $c: the guest stopped answering during the return"; exit 2; }
    sleep 3
  done
  if [ "$desk_w" -eq 0 ]; then
    log "cycle $c return: not graded - the entry produced no desktop size to look for"
  elif [ -n "$left" ]; then
    fail "cycle $c return: after 60 s a window of the desktop's size is still shown ($left)"
  else
    log "cycle $c return: no desktop-sized window left at t+$((SECONDS - t0))s"
  fi
  # A USER DOES NOT TOGGLE TWICE IN TWO SECONDS. The agent defers a mode echo inside a settle window after the last
  # mode change ("RESECHO 1280x800 suspect - deferring 1984 ms (settle window after 5120x1440)", win11r-c3c
  # 2026-11-20 cycle 2, entered 2 s after the return), and that deferral reads as a stalled entry.
  sleep 5
done

# HALTED FIRST: the host reads the guest's disk image as it is, and a line the guest wrote a second ago may not be on
# it yet - measured on win11r-c3c, the third return's release was logged 01:18:51.217 and missing from a read at
# 01:18:53 (it was there in the guest's own copy). The clean shutdown flushes it, and the session end is part of the test.
log "clean shutdown, then the log volume, then boot"
qwt_shutdown "$VM" 300 >"$OUT/shutdown.out" 2>&1 || { log "INSTRUMENT $VM did not halt within 300 s - left as it is, NOT killed"; exit 2; }
img=$(logvol_image "$VM")
logvol_pull "$img" "$OUT/logvol" >"$OUT/logvol-pull.out" 2>&1 \
  || { log "INSTRUMENT the log volume could not be read: $(tail -1 "$OUT/logvol-pull.out" | cut -c1-140)"; exit 2; }
alog=$(ls -t "$OUT"/logvol/files/qwt-logs/*/gui-agent-[0-9]*.log 2>/dev/null | grep -v -- '-[0-9]\{6\}-[0-9]*\.log$' | head -1)
[ -n "$alog" ] || { log "INSTRUMENT no agent log on the log volume"; exit 2; }
gate=$(grep -a 'WGCBROKER gate: enabled=' "$alog" | tail -1 | sed -n 's/.*enabled=\([01]\).*/\1/p')
nc=$(grep -ac 'QGADESKENGINE desktop duplication created' "$alog")
nr=$(grep -ac 'QGADESKENGINE desktop duplication released' "$alog")
ns=$(grep -ac 'STAGING cleared on the return to seamless' "$alog")
ne=$(grep -a 'QGADESKENGINE' "$alog" | grep -ac -- '-E\]')
na=$(grep -ac 'CAPTUREABANDON' "$alog")
log "agent log $(basename "$alog"): gate enabled=${gate:-?} created=$nc released=$nr cleared=$ns engine-errors=$ne abandoned=$na"
grep -a 'QGADESKENGINE desktop duplication created' "$alog" | sed -n 's/.* in \([0-9]*\) ms.*/\1/p' | tr '\n' ' ' \
  | sed 's/^/creation times (ms): /' | tee -a "$OUT/cycles.log"; echo | tee -a "$OUT/cycles.log"
case "$gate" in
  1) [ "$nc" = "$CYCLES" ] || fail "$nc duplication(s) created for $CYCLES entries"
     [ "$nr" = "$CYCLES" ] || fail "$nr duplication(s) released for $CYCLES returns"
     [ "$ns" = "$CYCLES" ] || fail "the buffer was cleared on $ns of $CYCLES returns" ;;
  0) [ "$nc$nr$ns" = 000 ] || fail "below the floor the engine lines appeared (created=$nc released=$nr cleared=$ns)" ;;
  *) log "INSTRUMENT the agent log carries no WGCBROKER gate line"; exit 2 ;;
esac
[ "$ne" = 0 ] || fail "$ne QGADESKENGINE error line(s)"
[ "$na" = 0 ] || fail "$na CAPTUREABANDON line(s): a capture thread did not stop"

timeout -k 10 150 qvm-start "$VM" >"$OUT/start.out" 2>&1 & disown
w_session "$VM" 600 boot "$OUT" log || { log "INSTRUMENT no session after the boot"; exit 2; }
timeout 120 tools/qtest ps "$APPEVT_PS | Where-Object { \$_.RecordId -gt $rec0 } | ForEach-Object { 'APPEVT ' + \$_.RecordId + ' ' + \$_.Id + ' ' + ((\$_.Message -split [char]10)[0]) }; 'APPEVT-END'" \
  >"$OUT/appevents.out" 2>&1
grep -aq '^APPEVT-END' "$OUT/appevents.out" || { log "INSTRUMENT the Application log could not be read after the boot"; exit 2; }
nev=$(grep -ac '^APPEVT [0-9]' "$OUT/appevents.out")
if [ "$nev" -gt 0 ]; then
  fail "$nev error-class Application record(s) since the first entry: $(grep -a '^APPEVT [0-9]' "$OUT/appevents.out" | head -3 | tr '\n' ';' | cut -c1-300)"
else
  log "no Application error 1000/1001 or agent death 4001/4002 since the first entry"
fi

# Every entry and return is a resolution change; the release campaign's per-cell sweep tolerates the same line for the
# same cause, with the owner's ruling as its reason.
timeout 900 mgmt/harness/log-sweep.sh "$VM" "$T0" "$OUT/sweep" \
  --tolerate-error 'RecreateDuplication: .*BUT THE GEOMETRY CHANGED' \
                   'owner 2026-10-17: a resolution change recovers in place (staging grant kept, work area re-applied) and DXGI signals staleness this way by design; every non-seamless entry and return this cell drives is a resolution change' \
  >"$OUT/sweep.log" 2>&1; src=$?
case "$src" in
  0) log "log sweep since the start: clean" ;;
  1) fail "the log sweep found undeclared errors: $(tail -1 "$OUT/sweep.log" | cut -c1-200)" ;;
  *) log "INSTRUMENT the log sweep gave no verdict (rc=$src): $(tail -1 "$OUT/sweep.log" | cut -c1-200)"; exit 2 ;;
esac

if [ "$NF" -gt 0 ]; then log "VERDICT: FAIL ($NF) - evidence in $OUT"; exit 1; fi
log "VERDICT: PASS - $CYCLES entries and returns, then a clean restart - evidence in $OUT"
exit 0
