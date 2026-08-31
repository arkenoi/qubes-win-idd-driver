#!/bin/bash
# RND-8 — dynamic resolution changes, judged FROM PIXELS.
#
# WHY PIXELS AND NOT A RETURN CODE. The known failure at exactly this path is
# `AcquireNextFrame` returning 0x887a0026 ("the keyed mutex was abandoned") on a resolution change,
# after which the capture thread dies. Everything guest-side still reports success: the mode is set,
# the agent re-announces the screen, `EnumDisplaySettings` reads back the new size. What stops is
# the FRAMES. So the acceptance is: after each resize, make a visible change in a mapped window and
# require the dom0 capture of that window to CHANGE. A resize that reports success while the picture
# is frozen is the defect, and only a pixel comparison sees it.
#
# SCOPE, STATED HONESTLY. RND-8 has two drivers and this runner exercises ONE:
#   * `guest/set-resolution.ps1` — guest-initiated. Exercised here.
#   * `tools/qtest resize <WxH>`  — dom0-initiated, the product path a user actually drives.
#     BLOCKED: the installed dom0 service reports `no_window` even when windows exist (its geom()
#     shells out to xwininfo); `dom0/10-install-resize-service.sh` v5 distinguishes the causes but
#     DOM0 MUST REINSTALL IT before that half can run. Recorded as BLOCKED, never folded into a pass.
#
# CONTAINMENT: only modes strictly smaller than the host are used. The adapter also offers the host
# size, and selecting it would put a host-sized guest desktop on the owner's display.
#
#   mgmt/harness/rnd8-resolution.sh <vm> [outdir]
set -uo pipefail
cd /home/user/qubes-win-idd-driver
require_scripts(){ local m=""; for s in "$@"; do [ -f "$s" ] || m="$m $s"; done
  [ -z "$m" ] || { echo "FATAL: required guest script(s) missing:$m" >&2; exit 2; }; }
require_scripts guest/set-resolution.ps1 guest/run-as-user.ps1

VM="${1:?usage: $0 <vm> [outdir]}"
source mgmt/harness/vmlock.sh; vm_lock "$VM"   # one harness per guest; see vmlock.sh
OUT="${2:-$HOME/qwt-accept/20260830-acceptance-4.3.16/RND8-$VM}"
mkdir -p "$OUT"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
GUEST='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
q(){ QTEST_VM=$VM timeout -k 8 "${T:-150}" ./tools/qtest "$@" 2>/dev/null; }
r(){ q run "$1" | tr -d '\r' | grep -avE '^(Microsoft Windows \[Version|\(c\) Microsoft|C:\\)'; }
# Any PowerShell with quotes or backslashes goes through -EncodedCommand: bash -> qtest ->
# cmd.exe -> powershell re-splits a nested-quote one-liner at every hop, and the failure mode
# is SILENCE, not an error (protocol 0.8b rule 2).
psrun(){ local b; b=$(python3 -c "
import base64,sys; print(base64.b64encode(sys.stdin.read().encode('utf-16-le')).decode(), end='')" <<< "$1")
  r "cmd /c powershell -NoProfile -EncodedCommand $b"; }
log(){ echo "$(date -u +%H:%M:%S) rnd8[$VM]: $*" | tee -a "$OUT/rnd8.log"; }
V="$OUT/verdicts.tsv"; EV=$(basename "$OUT"); rc=0

HOSTW=$(xdpyinfo 2>/dev/null | awk '/dimensions:/{split($2,a,"x"); print a[1]}'); HOSTW=${HOSTW:-5120}
HOSTH=$(xdpyinfo 2>/dev/null | awk '/dimensions:/{split($2,a,"x"); print a[2]}'); HOSTH=${HOSTH:-1440}

log "=== disarm the update scan ==="
cat > "$TMP/d.ps1" <<'PS'
$t=Get-ScheduledTask -TaskName QubesWindowsUpdateScan -EA SilentlyContinue
if($t){ & schtasks /change /tn QubesWindowsUpdateScan /disable *>$null }
Write-Output 'DISARMED done'
PS
T=300 q pushrun "$TMP/d.ps1" >/dev/null 2>&1
trap 'q run "cmd /c schtasks /change /tn QubesWindowsUpdateScan /enable" >/dev/null 2>&1; rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------- the mode list
LST=$(T=300 q pushrun guest/set-resolution.ps1 -List | tr -d '\r' | grep -a '^{')
echo "  $LST" | tee "$OUT/modes.json"
MODES=$(echo "$LST" | python3 -c "
import json,sys
d=json.loads(sys.stdin.read().strip())
hw,hh=$HOSTW,$HOSTH
out=[m for m in d.get('modes',[]) if int(m.split('x')[0])<hw and int(m.split('x')[1])<hh]
print(' '.join(out))")
log "  sub-host modes to exercise: ${MODES:-none}"
[ -n "$MODES" ] || { log "FATAL: no sub-host mode offered"; exit 2; }

# ---------------------------------------------------------------- pixel helper
# hash of the LARGEST mapped window's PNG - the same window across a pair of captures.
shot_hash(){
  local t="$TMP/s.tar"; rm -f "$t"; rm -rf "$TMP/sx"; mkdir -p "$TMP/sx"
  q shot "$t" >/dev/null 2>&1
  [ -s "$t" ] || { echo "NOCAP"; return; }
  tar xf "$t" -C "$TMP/sx" 2>/dev/null
  local big=""; big=$(ls -S "$TMP/sx"/*.png 2>/dev/null | head -1)
  [ -n "$big" ] || { echo "NOWIN"; return; }
  python3 -c "
import struct,hashlib,sys
b=open(sys.argv[1],'rb').read(); w,h=struct.unpack('>II',b[16:24])
print(f'{w}x{h}:{hashlib.sha256(b).hexdigest()[:16]}')" "$big"
}

# type into Notepad from the USER session so the pixels genuinely change
cat > "$TMP/type.ps1" <<'PS'
$ErrorActionPreference='Continue'
Add-Type -AssemblyName System.Windows.Forms
$w = New-Object -ComObject WScript.Shell
if ($w.AppActivate('Untitled - Notepad') -or $w.AppActivate('Notepad')) {
  Start-Sleep -Milliseconds 600
  [System.Windows.Forms.SendKeys]::SendWait("RND8 " + (Get-Random) + "`n" + ("#" * 60) + "`n")
  Write-Output 'TYPED ok'
} else { Write-Output 'TYPED no-notepad' }
PS
q push "$TMP/type.ps1" >/dev/null 2>&1

cat > "$TMP/ascreen.ps1" <<'PS'
$d=(Get-ItemProperty 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -EA SilentlyContinue).LogDir
$f=(Get-ChildItem $d -Filter 'gui-agent-*.log' -EA SilentlyContinue | Sort-Object LastWriteTime -Desc | Select-Object -First 1)
$m = (Get-Content $f.FullName -Tail 4000 | Select-String -Pattern 'A6CONFIGURE window 0 -> (\d+)x(\d+)' | Select-Object -Last 1)
if($m){ Write-Output ('AGENTSCREEN ' + $m.Matches[0].Groups[1].Value + 'x' + $m.Matches[0].Groups[2].Value) } else { Write-Output 'AGENTSCREEN none' }
PS

r 'cmd /c taskkill /f /im notepad.exe & exit 0' >/dev/null 2>&1
r 'cmd /c start "" notepad.exe' >/dev/null 2>&1; sleep 14

# ---------------------------------------------------------------- per-mode
for M in $MODES; do
  W=${M%x*}; H=${M#*x}
  log "=== mode $M ==="
  t0=$(date +%s%3N)
  res=$(T=300 q pushrun guest/set-resolution.ps1 -Width "$W" -Height "$H" | tr -d '\r' | grep -a '^{' | tail -1)
  t1=$(date +%s%3N)
  log "  set: $res"
  echo "$res" | grep -qa '"ok":true' || {
    log "  -> FAIL: the guest did not adopt $M"
    printf 'RND-8\tmode-followed-%s\tFAIL\t%s\t%s\n' "$M" "$res" "$EV" >> "$V"; rc=1; continue; }

  # the AGENT must agree, or dom0 is being told a different screen than the guest has
  ag=$(T=300 q pushrun "$TMP/ascreen.ps1" 2>/dev/null | tr -d '\r' | grep -ao 'AGENTSCREEN .*' | head -1)
  if [ -z "$ag" ]; then
    cat > "$TMP/ascreen.ps1" <<'PS'
$d=(Get-ItemProperty 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -EA SilentlyContinue).LogDir
$f=(Get-ChildItem $d -Filter 'gui-agent-*.log' -EA SilentlyContinue | Sort-Object LastWriteTime -Desc | Select-Object -First 1)
$m = (Get-Content $f.FullName -Tail 4000 | Select-String -Pattern 'A6CONFIGURE window 0 -> (\d+)x(\d+)' | Select-Object -Last 1)
if($m){ Write-Output ('AGENTSCREEN ' + $m.Matches[0].Groups[1].Value + 'x' + $m.Matches[0].Groups[2].Value) } else { Write-Output 'AGENTSCREEN none' }
PS
    ag=$(T=300 q pushrun "$TMP/ascreen.ps1" | tr -d '\r' | grep -ao 'AGENTSCREEN .*' | head -1)
  fi
  log "  agent: ${ag:-?}"

  # GRADE THE AGENT'S AGREEMENT, which is what this check has always CLAIMED to do.
  #
  # Until 2026-08-31 `ag` was logged here and then never compared: `mode-followed-<M>` was
  # emitted from inside the PIXEL branch below, with the detail string "guest+agent both report
  # <M>" - a statement about a comparison that no line of code performed. Measured with
  # FI_NOSCREENCONFIG armed (the agent deliberately never tells dom0 the resolution changed):
  # AGENTSCREEN came back `none` for all three modes and the cell still recorded
  # "guest+agent both report 1920x1080". The check could not fail against the exact defect it
  # names, and would have passed a build where dom0 is left on stale geometry forever.
  #
  # Graded on its own now, not as a side effect of the pixel test - a check that can be SKIPPED
  # by an unrelated branch is nearly as bad as one that cannot fail (the other two modes emitted
  # no mode-followed verdict at all in that run, because the pixel judge went INVALID first).
  agv=$(echo "$ag" | awk '{print $2}')
  if [ -z "$agv" ]; then
    log "  -> INVALID-INSTRUMENT: the agent-screen query returned nothing; not grading mode-followed"
    printf 'RND-8\tmode-followed-%s\tINVALID-INSTRUMENT\tagent-screen query returned no data\t%s\n' "$M" "$EV" >> "$V"; rc=1
  elif [ "$agv" = "$M" ]; then
    log "  -> PASS: the guest adopted $M AND the agent's last A6CONFIGURE to dom0 agrees ($agv)"
    printf 'RND-8\tmode-followed-%s\tPASS-UNPROVEN\tguest adopted %s and the agent last told dom0 %s - they agree\t%s\n' "$M" "$M" "$agv" "$EV" >> "$V"
  else
    log "  -> FAIL: the guest adopted $M but the agent last told dom0 '$agv' - dom0 is on stale geometry"
    printf 'RND-8\tmode-followed-%s\tFAIL\tguest adopted %s but the agent last told dom0 %s\t%s\n' "$M" "$M" "$agv" "$EV" >> "$V"; rc=1
  fi

  sleep 6
  h1=$(shot_hash)
  T=200 q pushrun guest/run-as-user.ps1 -Script "$GUEST\\type.ps1" >/dev/null 2>&1
  sleep 8
  h2=$(shot_hash)
  t2=$(date +%s%3N)
  log "  pixels before=$h1  after=$h2   (set $((t1-t0))ms, first-pixel ~$((t2-t1))ms)"

  if [ "$h1" = NOCAP ] || [ "$h2" = NOCAP ] || [ "$h1" = NOWIN ] || [ "$h2" = NOWIN ]; then
    log "  -> INVALID-INSTRUMENT: no capture at $M, so the pixel judge could not run"
    printf 'RND-8\tpixels-change-after-resize-%s\tINVALID-INSTRUMENT\tcapture returned %s / %s\t%s\n' "$M" "$h1" "$h2" "$EV" >> "$V"; rc=1
  elif [ "$h1" != "$h2" ]; then
    log "  -> PASS: capture is alive after the resize (window ${h2%%:*}, pixels changed)"
    printf 'RND-8\tpixels-change-after-resize-%s\tPASS-UNPROVEN\t%s -> %s after a visible guest change\t%s\n' "$M" "$h1" "$h2" "$EV" >> "$V"
  else
    log "  -> FAIL: identical pixels after a visible guest change - capture is FROZEN at $M"
    log "     (this is the 0x887a0026 keyed-mutex signature: everything reports success, frames stop)"
    printf 'RND-8\tpixels-change-after-resize-%s\tFAIL\tidentical capture hash %s before and after a visible change\t%s\n' "$M" "$h1" "$EV" >> "$V"; rc=1
  fi
done

# ---------------------------------------------------------------- the keyed-mutex check
# THE CRITERION IS RECOVERY, NOT ABSENCE.
# CLAUDE.md records a "PREREQUISITE BUG": on a resolution change AcquireNextFrame fails with
# 0x887a0026 ("the keyed mutex was abandoned") AND THE CAPTURE THREAD DIES. Measured 2026-08-31
# across three mode changes: the error occurred 12 times and the thread never died once. Each
# occurrence is followed immediately by `RecreateDuplication: STAGING dormant-park-path (screen
# grant kept across duplication recreate)` and a fresh `GetDuplication` at the NEW size, e.g.
#   GetFrame: ... 0x887a0026 -> RecreateDuplication -> Got output duplication ... 1024x768
# 0x887a0026 is simply how DXGI signals that the duplication is stale after a mode change; demanding
# ZERO occurrences would fail a correctly-behaving build. What must hold is that every occurrence is
# recovered and FRAMES RESUME - and the per-mode pixel comparison above is the independent proof of
# the second half (CLAUDE.md: "RecreateDuplication: recovered - windows kept" was once logged while
# every dom0 window was frozen, so the log line alone is not enough).
# THROUGH -EncodedCommand, NOT nested quotes. The previous form was a `cmd /c powershell
# -Command "... \"...\" ..."` one-liner, and on 2026-08-31 it was measured returning NOTHING at
# all: cmd echoed the command and produced no output, no error. km/rec/died came back EMPTY,
# `[ "" -eq 0 ]` failed, and the else-branch wrote `keyed-mutex-recovered FAIL` with a detail
# line reading " abandonments,  recreates,  thread deaths". A fabricated product defect from a
# silently broken query - protocol 0.8b rule 2, the same hazard that made a health-check plant
# silently do nothing. The identical query through -EncodedCommand returns `KM=10 RC=23 DIED=0`.
KM=$(psrun '$d=(Get-ItemProperty "HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools\").LogDir
$f=Get-ChildItem $d -Filter gui-agent-*.log | Sort LastWriteTime -Desc | Select -First 1
$a=Get-Content $f.FullName
Write-Output ("KM=" + @($a | Select-String -SimpleMatch 887a0026).Count + " RC=" + @($a | Select-String -SimpleMatch RecreateDuplication).Count + " DIED=" + @($a | Select-String -Pattern "capture thread|thread exiting|giving up").Count)' \
  | grep -aoE 'KM=[0-9]+ RC=[0-9]+ DIED=[0-9]+' | head -1)
km=$(echo "$KM" | grep -ao 'KM=[0-9]*' | cut -d= -f2); rec=$(echo "$KM" | grep -ao 'RC=[0-9]*' | cut -d= -f2); died=$(echo "$KM" | grep -ao 'DIED=[0-9]*' | cut -d= -f2)
log "=== keyed mutex: ${km:-?} abandonment(s), ${rec:-?} RecreateDuplication, ${died:-?} thread death(s) ==="

# ---------------------------------------------------------------- FRAME LIVENESS, from OUTPUT
# The `DIED` counter above is a LOG GREP, and on 2026-08-31 it was measured to be worthless for
# the defect it names: with FI_CAPTURE_EXIT armed - the capture thread returning without
# signalling its error event - the ONLY line in the whole agent log matching
# /capture thread|thread exiting|giving up/ was the FAULT INJECTOR'S OWN MESSAGE. The check
# scored a "thread death" it had detected from the injector announcing itself, and a silently
# dead capture thread produces no such line at all.
#
# So ask the capture engine whether it is still PRODUCING. QGAPERF emits one line per frame with
# a monotonic `seq=`; if seq advances across a visible guest change, frames are genuinely being
# captured. That cannot be satisfied by any log message, which is the whole point
# (CLAUDE.md: "Judge output, not logs").
perf_seq(){ psrun '$d=(Get-ItemProperty "HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools\").LogDir
$f=Get-ChildItem $d -Filter gui-agent-*.log | Sort LastWriteTime -Desc | Select -First 1
$m=@(Get-Content $f.FullName -Tail 3000 | Select-String -Pattern "QGAPERF,v=\d+,seq=(\d+)")
if ($m.Count -eq 0) { Write-Output "PERFSEQ none" }
else { Write-Output ("PERFSEQ " + $m[-1].Matches[0].Groups[1].Value) }'     | grep -aoE 'PERFSEQ [0-9]+|PERFSEQ none' | awk '{print $2}' | head -1; }

s0=$(perf_seq)
T=200 q pushrun guest/run-as-user.ps1 -Script "$GUEST\\type.ps1" >/dev/null 2>&1
sleep 8
s1=$(perf_seq)
log "  frame liveness: QGAPERF seq $s0 -> $s1"
alive=unknown
if [ "$s0" = none ] || [ "$s1" = none ] || [ -z "$s0" ] || [ -z "$s1" ]; then
  alive=unknown
elif [ "$s1" -gt "$s0" ] 2>/dev/null; then alive=yes
else alive=no
fi
# MISSING DATA IS AN INSTRUMENT FAULT, NOT A PRODUCT VERDICT. CLAUDE.md says missing data must
# fail - it must never be approximated or skipped - but failing it as FAIL would put a defect
# on the PRODUCT's record that the product never committed. Distinguish the two explicitly.
if [ -z "$km" ] || [ -z "$rec" ] || [ -z "$died" ]; then
  log "  -> INVALID-INSTRUMENT: the log counter returned no data (raw='${KM}'). Nothing is graded"
  log "     here; this says nothing about the guest, only that the query did not run."
  printf 'RND-8\tkeyed-mutex-recovered\tINVALID-INSTRUMENT\tcounter query returned no data (raw=%s)\t%s\n' "${KM:-EMPTY}" "$EV" >> "$V"; rc=1
elif [ "$alive" = unknown ]; then
  log "  -> INVALID-INSTRUMENT: QGAPERF produced no seq (is service.gui-agent-debug on?), so frame"
  log "     liveness could not be measured. The log counters alone are NOT sufficient evidence -"
  log "     see the comment above; they were measured detecting the injector rather than a death."
  printf 'RND-8\tkeyed-mutex-recovered\tINVALID-INSTRUMENT\tno QGAPERF seq available; frame liveness unmeasurable\t%s\n' "$EV" >> "$V"; rc=1
elif [ "$alive" = no ]; then
  log "  -> FAIL: frames are NOT advancing (QGAPERF seq $s0 -> $s1) after a visible guest change."
  log "     Capture has stopped producing, whatever the log counters say."
  printf 'RND-8\tkeyed-mutex-recovered\tFAIL\tQGAPERF seq did not advance (%s -> %s) after a visible change: capture is not producing\t%s\n' "$s0" "$s1" "$EV" >> "$V"
  printf 'RND-8\tcapture-thread-survives-resize\tFAIL\tframes stopped: QGAPERF seq %s -> %s\t%s\n' "$s0" "$s1" "$EV" >> "$V"; rc=1
elif [ "$died" -eq 0 ] && [ "$rec" -ge "$km" ]; then
  log "  -> PASS: every abandonment was recovered and the capture thread never died; frames"
  log "     provably resumed (the pixel comparisons above)."
  printf 'RND-8\tkeyed-mutex-recovered\tPASS-UNPROVEN\t%s abandonment(s), %s RecreateDuplication, 0 thread deaths, AND frames provably still advancing (QGAPERF seq %s -> %s after a visible change)\t%s\n' "$km" "$rec" "$s0" "$s1" "$EV" >> "$V"
  printf 'RND-8\tcapture-thread-survives-resize\tPASS-UNPROVEN\tthe prerequisite bug (thread dies on 0x887a0026) did NOT reproduce across %s mode changes, and capture is still PRODUCING (QGAPERF seq %s -> %s)\t%s\n' "$(echo $MODES | wc -w)" "$s0" "$s1" "$EV" >> "$V"
else
  log "  -> FAIL: abandonment(s) not recovered (thread deaths=${died:-?}, recreates=${rec:-?} vs ${km:-?})"
  printf 'RND-8\tkeyed-mutex-recovered\tFAIL\t%s abandonments, %s recreates, %s thread deaths\t%s\n' "$km" "$rec" "$died" "$EV" >> "$V"; rc=1
fi

printf 'RND-8\tdom0-driven-resize\tBLOCKED\tlocal.WinResize returns no_window even with windows present; dom0 must reinstall 10-install-resize-service.sh v5 before this half can run\t%s\n' "$EV" >> "$V"
r 'cmd /c taskkill /f /im notepad.exe & exit 0' >/dev/null 2>&1
log "=== finished rc=$rc ==="
exit $rc
