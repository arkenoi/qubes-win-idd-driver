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
require_scripts guest/set-resolution.ps1 guest/wu-boot-acceptance-check.ps1 guest/wu-boot-acceptance-arm.ps1

VM="${1:?usage: $0 <vm> [outdir]}"
source mgmt/harness/vmlock.sh; vm_lock "$VM"   # one harness per guest; see vmlock.sh
OUT="${2:-$HOME/qwt-accept/20260830-acceptance-4.3.16/SG1U2-$VM}"
mkdir -p "$OUT"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
q(){ QTEST_VM=$VM timeout -k 8 "${T:-150}" ./tools/qtest "$@" 2>/dev/null; }
r(){ q run "$1" | tr -d '\r' | grep -avE '^(Microsoft Windows \[Version|\(c\) Microsoft|C:\\)'; }
log(){ echo "$(date -u +%H:%M:%S) sg1[$VM]: $*" | tee -a "$OUT/sg1u2.log"; }
rc=0

alive(){ r 'cmd /c echo ALIVE' | grep -qa ALIVE; }
# SHORT timeout. `alive` inherits T=150, so during a boot it BLOCKS until qrexec comes up - the
# watch loop below then takes ONE sample and waits, i.e. it does not watch the boot at all, which is
# the only interval in which the defect could appear. Measured 2026-08-31: "dom0 watch: 0 sample(s)"
# with the loop reporting "sample 1", and my "~4s" was arithmetic, not elapsed time.
alive_fast(){ QTEST_VM=$VM timeout -k 2 5 ./tools/qtest run 'cmd /c echo ALIVE' 2>/dev/null | grep -qa ALIVE; }

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
# PROVE THE BOOT. On 2026-08-31 this cell reported "qrexec came up at sample 1 (~4s)" and I read it
# as "the shutdown never took" and killed the run - wrongly: LastBootUpTime showed the guest HAD
# cold-booted and had simply come up in ~13 s. A cold-boot cell that cannot demonstrate a cold boot
# forces exactly that guess, so the boot is now evidence rather than an assumption.
# Through -EncodedCommand: a nested-quote one-liner fails SILENTLY (rule 16), and an empty
# bootid would make the "did a cold boot happen" test compare "" against "" and pass vacuously.
psrun(){ local b; b=$(python3 -c "
import base64,sys; print(base64.b64encode(sys.stdin.read().encode('utf-16-le')).decode(), end='')" <<< "$1")
  r "cmd /c powershell -NoProfile -EncodedCommand $b"; }
bootid(){ psrun 'Write-Output (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString("o")' \
  | grep -aoE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+' | head -1; }
BOOT_BEFORE=$(bootid); log "  LastBootUpTime before: ${BOOT_BEFORE:-unknown}"
# U2 MUST BE ARMED BEFORE THE BOOT. wu-boot-acceptance-check.ps1 compares against
# C:\ProgramData\Qubes\boot-accept-arm.txt written by the arm script; without it the check emits no
# RESULT block at all - which is exactly what happened on the first attempt.
log "  arming U2 (wu-boot-acceptance-arm.ps1) before the reboot"
T=300 q pushrun guest/wu-boot-acceptance-arm.ps1 2>/dev/null | tr -d '\r' | grep -aE '^(ARMED|=== RESULT|\{)' | head -2 | sed 's/^/    /'
timeout -k 10 320 qvm-shutdown --wait --timeout 260 "$VM" >/dev/null 2>&1; sleep 4
st=$(qvm-ls --raw-data --fields STATE "$VM" | tail -1)
[ "$st" = Halted ] || { log "FATAL: $VM is $st after qvm-shutdown --wait; this cell REQUIRES a cold boot"; exit 2; }
log "  guest is Halted - the shutdown took"
timeout -k 10 200 qvm-start "$VM" >/dev/null 2>&1 & disown

BIG=0; SAMPLES=0; TAKEN=0; MAXDIM="none"; WSTART=$(date +%s)
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
  TAKEN=$((TAKEN+1))
  # The liveness probe costs more than the screenshot, so only run it every other pass - otherwise
  # it dominates the loop and the boot window (~22 s on this rig) fits only 2 samples.
  if [ $((TAKEN % 2)) -eq 0 ] && alive_fast; then
    log "  qrexec came up after $TAKEN sample(s), $(( $(date +%s) - WSTART ))s of watching"; break
  fi
  sleep 1
done
log "  dom0 watch: $TAKEN sample(s) TAKEN across the boot, $SAMPLES returned windows; fullscreen hits: $BIG ($MAXDIM)"

alive || { log "FATAL: guest never answered qrexec after the cold boot"; exit 2; }
sleep 35
BOOT_AFTER=$(bootid); log "  LastBootUpTime after: ${BOOT_AFTER:-unknown}"
if [ -n "$BOOT_BEFORE" ] && [ "$BOOT_BEFORE" = "$BOOT_AFTER" ]; then
  log "FATAL: LastBootUpTime is unchanged - the guest did NOT cold boot, so nothing below grades."
  exit 2
fi
log "  COLD BOOT PROVEN (boot time advanced)"

# ------------------------------------------------------------------ negative control
log "=== negative control: a normal window must still map (the filter must not be a brick) ==="
r 'cmd /c start "" notepad.exe' >/dev/null 2>&1; sleep 16
nd=$(rm -f "$TMP/n.tar"; q shot "$TMP/n.tar" >/dev/null 2>&1; tar tf "$TMP/n.tar" 2>/dev/null | grep -c '\.png$')
log "  notepad mapped: ${nd:-0} window(s)"
r 'cmd /c taskkill /f /im notepad.exe' >/dev/null 2>&1

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

# ------------------------------------------------------------------ SG1 verdict
log "=== SG1 VERDICT ==="
V="$OUT/verdicts.tsv"; EV=$(basename "$OUT")

# INSTRUMENT GATES FIRST. Both of these were violated on the first attempt and would have produced
# a confident "no fullscreen window appeared" from a watch that never looked.
if [ "${TAKEN:-0}" -lt 3 ]; then
  log "  -> INVALID-INSTRUMENT: only ${TAKEN:-0} dom0 sample(s) were TAKEN across the boot. The"
  log "     boot window is the only interval in which the defect could appear; a watch that did not"
  log "     iterate proves nothing about it."
  printf 'SG1\tno-fullscreen-during-boot\tINVALID-INSTRUMENT\tonly %s dom0 samples taken across the boot\t%s\n' "${TAKEN:-0}" "$EV" >> "$V"; rc=1
elif [ "${nd:-0}" -lt 1 ]; then
  # The capture path must be shown ALIVE after the boot, or "nothing seen during boot" is
  # indistinguishable from a dead service (which exits 1 with an empty body either way).
  log "  -> INVALID-INSTRUMENT: the post-boot control window did not map, so the capture path"
  log "     cannot be shown to have been working during the boot either."
  printf 'SG1\tno-fullscreen-during-boot\tINVALID-INSTRUMENT\tpost-boot control mapped 0 windows\t%s\n' "$EV" >> "$V"; rc=1
elif [ "${BIG:-0}" -eq 0 ] && [ "${BIGMAP:-0}" -eq 0 ]; then
  log "  -> PASS: across $TAKEN dom0 samples spanning the boot, no window >= ${THRW}x${THRH} ever"
  log "     appeared, and the agent MAPped none either; the capture path was proven alive after."
  printf 'SG1\tno-fullscreen-during-boot\tPASS-UNPROVEN\t%s dom0 samples across the boot, 0 fullscreen; 0 agent MAPs >= %sx%s; capture proven alive after\t%s\n' "$TAKEN" "$THRW" "$THRH" "$EV" >> "$V"
  printf 'SG1\tno-shell-phase-observed\tPASS-UNPROVEN\tthe watch spanned Halted -> qrexec-up, i.e. the entire no-shell phase\t%s\n' "$EV" >> "$V"
else
  log "  -> FAIL: fullscreen-sized surface(s) reached dom0 (watch=$BIG, agent MAPs=$BIGMAP, $MAXDIM)"
  printf 'SG1\tno-fullscreen-during-boot\tFAIL\tdom0 watch hits=%s (%s), agent MAPs >= threshold=%s\t%s\n' "$BIG" "$MAXDIM" "$BIGMAP" "$EV" >> "$V"; rc=1
fi

# THE LOGONUI DENIAL IS NOT AVAILABLE ON AN AUTOLOGON GUEST - state that, do not fake it either way.
# The gui-agent is a USER-SESSION process: it starts after logon, and LogonUI exists only before it.
# Measured 2026-08-31: boot at 01:54:28, agent log created 01:54:44, DENY_LOGONUI 0. So on a rig
# where autologon is ENFORCED (and it is, deliberately) the agent can never witness the LogonUI
# phase, and requiring its denial line would make this cell permanently unprovable. The dom0-side
# watch above is the instrument that covers that phase; the agent-side denial is reachable only on
# an attended, autologon-disabled arm.
if [ "${DENY:-0}" -gt 0 ]; then
  printf 'SG1\tvacuity-secure-desktop-entered\tPASS-UNPROVEN\t%s "unconditionally denied, feature or not" lines - the Mode-1 filter was exercised\t%s\n' "$DENY" "$EV" >> "$V"
else
  log "  LogonUI denial not observable here: the agent is a user-session process and autologon is"
  log "  enforced, so it starts after LogonUI is gone (agent log 01:54:44 vs boot 01:54:28)."
  printf 'SG1\tvacuity-secure-desktop-entered\tN/A\tunobservable on an autologon guest: the gui-agent starts after logon, LogonUI exists only before it. Covered instead by the dom0-side watch; the agent-side denial needs an attended autologon-off arm\t%s\n' "$EV" >> "$V"
fi
if [ "${nd:-0}" -ge 1 ]; then
  printf 'SG1\tnegative-control-normal-window-maps\tPASS-UNPROVEN\tnotepad mapped %s window(s) after settle - the filter is not a brick\t%s\n' "$nd" "$EV" >> "$V"
else
  printf 'SG1\tnegative-control-normal-window-maps\tFAIL\tnotepad mapped 0 windows\t%s\n' "$EV" >> "$V"; rc=1
fi

# ------------------------------------------------------------------ U2, on the same boot
log "=== U2: boot classification + QdbDaemon startup-race retry, on this same cold boot ==="
U=$(T=400 q pushrun guest/wu-boot-acceptance-check.ps1 | tr -d '\r' | sed -n '/=== RESULT ===/,$p' | grep -ao '{.*}' | head -1)
echo "  ${U:-NO RESULT}" | tee "$OUT/u2.json"
KLASS=$(qvm-prefs "$VM" klass 2>/dev/null)
if [ -z "$U" ]; then
  log "  -> INVALID-INSTRUMENT: wu-boot-acceptance-check produced no RESULT block"
  printf 'U2\tcoldboot-classification\tINVALID-INSTRUMENT\tno RESULT block\t%s\n' "$EV" >> "$V"; rc=1
elif [ "$KLASS" != TemplateVM ]; then
  # THE FIX UNDER TEST IS TEMPLATE-SPECIFIC. wu-boot-acceptance-arm.ps1 states it: at early boot the
  # QubesDB daemon is not yet serving its pipe, Get-QubesVmClass read an EMPTY class, and a
  # TEMPLATEVM was therefore treated as a standalone and the boot pass skipped. On a StandaloneVM
  # there is no misclassification to make, so the retry loop cannot be exercised and
  # `qdb_retry_evidence:false` is the CORRECT reading, not a failure. Measured here: rebooted=true,
  # class_lines=0, ok=false on win10-p46 (StandaloneVM). Grading that as a product result would be
  # reporting against a subject the defect cannot occur on.
  log "  -> N/A on a $KLASS: the QdbDaemon race misclassifies a TEMPLATE as a standalone, so this"
  log "     cell needs a TemplateVM subject. Reboot itself confirmed: $(echo "$U" | grep -ao '"rebooted":[a-z]*')"
  printf 'U2\tcoldboot-classification\tN/A\tsubject is a %s; the QdbDaemon race is template-specific (a TemplateVM read as a standalone), so it cannot occur here. Needs a TemplateVM subject - win11-tpl is uncontaminated\t%s\n' "$KLASS" "$EV" >> "$V"
  printf 'U2\tqdbdaemon-race-fix-exercised\tN/A\tsame: unexercisable on a %s\t%s\n' "$KLASS" "$EV" >> "$V"
  printf 'U2\tcoldboot-reboot-confirmed\tPASS-UNPROVEN\t%s (LastBootUpTime advanced %s -> %s)\t%s\n' "$(echo "$U" | grep -ao '"rebooted":[a-z]*')" "$BOOT_BEFORE" "$BOOT_AFTER" "$EV" >> "$V"
else
  qr=$(echo "$U" | grep -ao '"qdb_retry_evidence":[a-z]*' | cut -d: -f2)
  cc=$(echo "$U" | grep -ao '"class_correct":[a-z]*' | cut -d: -f2)
  log "  TemplateVM subject: qdb_retry_evidence=$qr class_correct=$cc"
  if [ "$cc" = true ]; then
    printf 'U2\tcoldboot-classification\tPASS-UNPROVEN\tclass_correct=true on a real cold boot of a TemplateVM\t%s\n' "$EV" >> "$V"
    printf 'U2\tqdbdaemon-race-fix-exercised\tPASS-UNPROVEN\tqdb_retry_evidence=%s\t%s\n' "$qr" "$EV" >> "$V"
  else
    printf 'U2\tcoldboot-classification\tFAIL\tclass_correct=false on a TemplateVM cold boot: %s\t%s\n' "$U" "$EV" >> "$V"; rc=1
  fi
fi

log "=== finished rc=$rc ==="
exit $rc
