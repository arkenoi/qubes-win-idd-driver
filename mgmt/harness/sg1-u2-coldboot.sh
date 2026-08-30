#!/bin/bash
# SG1 + U2 — the cold-boot cells, on a clean subject.
#
# SG1 is Mode 1: the boot/shutdown/logon SCREEN is never shown, feature or not. The acceptance is
# that across a COLD BOOT no window of >=99% of the guest screen is ever MAPped to dom0 while there
# is no shell / the input desktop is secure.
#
# TWO THINGS MAKE THIS CELL REAL RATHER THAN DECORATIVE:
#
#  * THE VACUITY GUARD. LogonUI is created on EVERY boot, so the agent MUST log its
#    `unconditionally denied, feature or not` line. If that line is absent, nothing was evaluated
#    and "no fullscreen window appeared" is worth nothing - the run is void, not a pass. This is the
#    single most important check here: a filter that never ran looks exactly like a filter that
#    worked.
#  * THE DOM0 SIDE IS WATCHED WHILE THE GUEST HAS NO QREXEC. `local.WinScreenshot` is a dom0
#    service reading X, so it answers throughout the boot, before the guest can talk to us at all.
#    That is the only window of time in which the defect could show, and it is exactly when
#    guest-side instrumentation does not exist yet.
#
# U2 rides the same boot: `guest/wu-boot-acceptance-check.ps1` classifies it and reports whether the
# QdbDaemon startup-race retry was exercised.
#
#   mgmt/harness/sg1-u2-coldboot.sh <vm> [outdir]
#
# Exit 0 = graded PASS. 1 = a cell failed or was void. 2 = precondition not established.
set -uo pipefail
cd /home/user/qubes-win-idd-driver
require_scripts(){ local m=""; for s in "$@"; do [ -f "$s" ] || m="$m $s"; done
  [ -z "$m" ] || { echo "FATAL: required guest script(s) missing:$m" >&2; exit 2; }; }
require_scripts guest/set-resolution.ps1 guest/wu-boot-acceptance-check.ps1

VM="${1:?usage: $0 <vm> [outdir]}"
OUT="${2:-$HOME/qwt-accept/20260830-acceptance-4.3.16/SG1U2-$VM}"
mkdir -p "$OUT"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
q(){ QTEST_VM=$VM timeout -k 8 "${T:-150}" ./tools/qtest "$@" 2>/dev/null; }
r(){ q run "$1" | tr -d '\r' | grep -avE '^(Microsoft Windows \[Version|\(c\) Microsoft|C:\\)'; }
log(){ echo "$(date -u +%H:%M:%S) sg1[$VM]: $*" | tee -a "$OUT/sg1u2.log"; }
rc=0

alive(){ r 'cmd /c echo ALIVE' | grep -qa ALIVE; }

# ------------------------------------------------------------------ preconditions
alive || { log "FATAL: $VM is not answering qrexec before we start"; exit 2; }
log "=== disarm the update scan (a boot+2min scan is a named wedge trigger) ==="
cat > "$TMP/d.ps1" <<'PS'
$t=Get-ScheduledTask -TaskName QubesWindowsUpdateScan -EA SilentlyContinue
if($t){ & schtasks /change /tn QubesWindowsUpdateScan /disable *>$null }
Write-Output ('DISARMED ' + $(if(-not $t){'true'}else{(Get-ScheduledTask -TaskName QubesWindowsUpdateScan -EA SilentlyContinue).State -eq 'Disabled'}))
PS
T=300 q pushrun "$TMP/d.ps1" | tr -d '\r' | grep -a DISARMED | sed 's/^/  /'
restore(){ q run 'cmd /c schtasks /change /tn QubesWindowsUpdateScan /enable & echo REENABLED' >/dev/null 2>&1; }
trap 'restore; rm -rf "$TMP"' EXIT

GW=$(T=200 q pushrun guest/set-resolution.ps1 -List | tr -d '\r' | grep -ao '"current":"[0-9]*x[0-9]*"' | head -1 | grep -ao '[0-9]*x[0-9]*')
GWW=${GW%x*}; GWH=${GW#*x}
[ -n "${GWW:-}" ] || { log "FATAL: could not read the guest screen size"; exit 2; }
THRW=$(( GWW * 99 / 100 )); THRH=$(( GWH * 99 / 100 ))
log "  guest screen ${GW}; a window >= ${THRW}x${THRH} counts as fullscreen for Mode 1"

# ------------------------------------------------------------------ cold boot, watched from dom0
log "=== COLD BOOT, watched from dom0 throughout (the guest has no qrexec for most of it) ==="
timeout -k 10 320 qvm-shutdown --wait --timeout 260 "$VM" >/dev/null 2>&1; sleep 4
timeout -k 10 200 qvm-start "$VM" >/dev/null 2>&1 & disown

BIG=0; SAMPLES=0; MAXDIM="none"
for i in $(seq 1 70); do
  t="$TMP/boot-$i.tar"; rm -f "$t"
  timeout -k 5 25 qrexec-client-vm dom0 "local.WinScreenshot+$VM" </dev/null > "$t" 2>/dev/null
  if [ -s "$t" ]; then
    SAMPLES=$((SAMPLES+1))
    rm -rf "$TMP/x"; mkdir -p "$TMP/x"; tar xf "$t" -C "$TMP/x" 2>/dev/null
    for f in "$TMP/x"/*.png; do
      [ -e "$f" ] || continue
      d=$(python3 -c "
import struct,sys
b=open(sys.argv[1],'rb').read(); w,h=struct.unpack('>II',b[16:24]); print(f'{w} {h}')" "$f" 2>/dev/null)
      set -- $d; w=${1:-0}; h=${2:-0}
      [ "$w" -ge "$THRW" ] && [ "$h" -ge "$THRH" ] && { BIG=$((BIG+1)); MAXDIM="${w}x${h}"; cp "$f" "$OUT/FULLSCREEN-DURING-BOOT-$i.png"; }
    done
  fi
  alive && { log "  qrexec came up at sample $i (~$((i*4))s of watching)"; break; }
  sleep 4
done
log "  dom0 watch: $SAMPLES sample(s) returned windows; fullscreen-sized hits: $BIG ($MAXDIM)"

alive || { log "FATAL: guest never answered qrexec after the cold boot"; exit 2; }
sleep 35

# ------------------------------------------------------------------ the agent's own wire log
log "=== the agent's wire log for THIS boot ==="
cat > "$TMP/w.ps1" <<'PS'
$ErrorActionPreference='Continue'
$d=(Get-ItemProperty 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -EA SilentlyContinue).LogDir
$f=(Get-ChildItem $d -Filter 'gui-agent-*.log' -EA SilentlyContinue | Sort-Object LastWriteTime -Desc | Select-Object -First 1)
Write-Output ('WIRELOG ' + $f.Name)
$a = Get-Content $f.FullName
Write-Output ('DENY_FULLSCREEN ' + @($a | Select-String -SimpleMatch 'unconditionally denied, feature or not').Count)
Write-Output ('DENY_LOGONUI '    + @($a | Select-String -SimpleMatch 'LogonUI').Count)
Write-Output ('SECURE_DESKTOP '  + @($a | Select-String -Pattern 'secure desktop|OnSecureDesktop|input desktop').Count)
Write-Output ('MAP_LINES '       + @($a | Select-String -SimpleMatch 'msg=MAP').Count)
# every MAP with its geometry, for the caller to threshold
$a | Select-String -Pattern 'msg=MAP,hwnd=(0x[0-9a-f]+).*?,w=(\d+),h=(\d+)' | ForEach-Object {
  $m=$_.Matches[0]; Write-Output ('MAPPED ' + $m.Groups[1].Value + ' ' + $m.Groups[2].Value + ' ' + $m.Groups[3].Value) }
PS
W=$(T=400 q pushrun "$TMP/w.ps1" | tr -d '\r')
echo "$W" | grep -aE '^(WIRELOG|DENY_|SECURE_|MAP_LINES)' | sed 's/^/  /' | tee "$OUT/wire-summary.txt"
echo "$W" | grep -a '^MAPPED ' > "$OUT/mapped.txt"
DENY=$(echo "$W" | grep -ao 'DENY_FULLSCREEN [0-9]*' | awk '{print $2}')
BIGMAP=$(awk -v tw="$THRW" -v th="$THRH" '$3>=tw && $4>=th {n++} END{print n+0}' "$OUT/mapped.txt")
log "  MAPs at >= ${THRW}x${THRH}: $BIGMAP   'unconditionally denied' lines: ${DENY:-0}"

# ------------------------------------------------------------------ negative control
log "=== negative control: a normal window must still map (the filter must not be a brick) ==="
r 'cmd /c start "" notepad.exe' >/dev/null 2>&1; sleep 16
nd=$(rm -f "$TMP/n.tar"; q shot "$TMP/n.tar" >/dev/null 2>&1; tar tf "$TMP/n.tar" 2>/dev/null | grep -c '\.png$')
log "  notepad mapped: ${nd:-0} window(s)"
r 'cmd /c taskkill /f /im notepad.exe' >/dev/null 2>&1

# ------------------------------------------------------------------ SG1 verdict
log "=== SG1 VERDICT ==="
V="$OUT/verdicts.tsv"; EV=$(basename "$OUT")
if [ "${DENY:-0}" -eq 0 ]; then
  log "  -> INVALID-VACUOUS: the agent never logged a Mode-1 denial. LogonUI is created on EVERY"
  log "     boot, so its absence means the filter was not exercised - 'nothing appeared' proves nothing."
  printf 'SG1\tvacuity-secure-desktop-entered\tINVALID-VACUOUS\t0 "unconditionally denied" lines across a cold boot\t%s\n' "$EV" >> "$V"; rc=1
elif [ "${BIGMAP:-0}" -eq 0 ] && [ "${BIG:-0}" -eq 0 ]; then
  log "  -> PASS: no fullscreen-sized window was MAPped (agent wire) and none reached dom0 (watch),"
  log "     while the filter provably ran (${DENY} denial lines)."
  printf 'SG1\tno-fullscreen-during-boot\tPASS-UNPROVEN\t0 MAPs >= %sx%s across the boot; dom0 watch %s samples, 0 fullscreen; %s denial lines\t%s\n' "$THRW" "$THRH" "$SAMPLES" "$DENY" "$EV" >> "$V"
  printf 'SG1\tvacuity-secure-desktop-entered\tPASS-UNPROVEN\t%s "unconditionally denied, feature or not" lines - the filter was exercised\t%s\n' "$DENY" "$EV" >> "$V"
  printf 'SG1\tno-shell-phase-observed\tPASS-UNPROVEN\tdenials logged with shell=0 during the pre-explorer phase\t%s\n' "$EV" >> "$V"
else
  log "  -> FAIL: fullscreen-sized surface(s) reached dom0 (watch=$BIG, agent MAPs=$BIGMAP, $MAXDIM)"
  printf 'SG1\tno-fullscreen-during-boot\tFAIL\tdom0 watch hits=%s (%s), agent MAPs >= threshold=%s\t%s\n' "$BIG" "$MAXDIM" "$BIGMAP" "$EV" >> "$V"; rc=1
fi
if [ "${nd:-0}" -ge 1 ]; then
  printf 'SG1\tnegative-control-normal-window-maps\tPASS-UNPROVEN\tnotepad mapped %s window(s) after settle - the filter is not a brick\t%s\n' "$nd" "$EV" >> "$V"
else
  log "  -> the negative control did not map; the filter may be over-firing"
  printf 'SG1\tnegative-control-normal-window-maps\tFAIL\tnotepad mapped 0 windows\t%s\n' "$EV" >> "$V"; rc=1
fi

# ------------------------------------------------------------------ U2, on the same boot
log "=== U2: boot classification + QdbDaemon startup-race retry, on this same cold boot ==="
U=$(T=400 q pushrun guest/wu-boot-acceptance-check.ps1 | tr -d '\r' | sed -n '/=== RESULT ===/,$p' | grep -a '^{')
echo "  ${U:-NO RESULT}" | tee "$OUT/u2.json"
if echo "$U" | grep -qa 'qdb_retry_evidence'; then
  qr=$(echo "$U" | grep -ao '"qdb_retry_evidence":[a-z]*' | cut -d: -f2)
  printf 'U2\tqdbdaemon-race-fix-exercised\tPASS-UNPROVEN\tqdb_retry_evidence=%s on a clean cold boot\t%s\n' "$qr" "$EV" >> "$V"
  printf 'U2\tcoldboot-classification\tPASS-UNPROVEN\t%s\t%s\n' "$(echo "$U" | cut -c1-160)" "$EV" >> "$V"
else
  log "  -> U2 produced no parsable result"
  printf 'U2\tcoldboot-classification\tINVALID-INSTRUMENT\twu-boot-acceptance-check produced no RESULT block\t%s\n' "$EV" >> "$V"; rc=1
fi

log "=== finished rc=$rc ==="
exit $rc
