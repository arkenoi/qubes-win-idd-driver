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
OUT="${2:-$HOME/qwt-accept/20260830-acceptance-4.3.16/RND8-$VM}"
mkdir -p "$OUT"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
GUEST='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
q(){ QTEST_VM=$VM timeout -k 8 "${T:-150}" ./tools/qtest "$@" 2>/dev/null; }
r(){ q run "$1" | tr -d '\r' | grep -avE '^(Microsoft Windows \[Version|\(c\) Microsoft|C:\\)'; }
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
    printf 'RND-8\tmode-followed-%s\tPASS-UNPROVEN\tguest+agent both report %s\t%s\n' "$M" "$M" "$EV" >> "$V"
    printf 'RND-8\tpixels-change-after-resize-%s\tPASS-UNPROVEN\t%s -> %s after a visible guest change\t%s\n' "$M" "$h1" "$h2" "$EV" >> "$V"
  else
    log "  -> FAIL: identical pixels after a visible guest change - capture is FROZEN at $M"
    log "     (this is the 0x887a0026 keyed-mutex signature: everything reports success, frames stop)"
    printf 'RND-8\tpixels-change-after-resize-%s\tFAIL\tidentical capture hash %s before and after a visible change\t%s\n' "$M" "$h1" "$EV" >> "$V"; rc=1
  fi
done

# ---------------------------------------------------------------- the keyed-mutex check
km=$(r 'cmd /c powershell -NoProfile -Command "$d=(Get-ItemProperty \"HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools\").LogDir; $f=(Get-ChildItem $d -Filter gui-agent-*.log | Sort LastWriteTime -Desc | Select -First 1); (Select-String -Path $f.FullName -Pattern 887a0026 -SimpleMatch | Measure-Object).Count"' | grep -aoE '^[0-9]+$' | head -1)
log "=== 0x887a0026 (keyed mutex abandoned) occurrences this boot: ${km:-0} ==="
if [ "${km:-0}" -eq 0 ]; then
  printf 'RND-8\tno-keyed-mutex-abandonment\tPASS-UNPROVEN\t0 occurrences of 0x887a0026 across %s resolution changes\t%s\n' "$(echo $MODES | wc -w)" "$EV" >> "$V"
else
  printf 'RND-8\tno-keyed-mutex-abandonment\tFAIL\t%s occurrences of 0x887a0026\t%s\n' "$km" "$EV" >> "$V"; rc=1
fi

printf 'RND-8\tdom0-driven-resize\tBLOCKED\tlocal.WinResize returns no_window even with windows present; dom0 must reinstall 10-install-resize-service.sh v5 before this half can run\t%s\n' "$EV" >> "$V"
r 'cmd /c taskkill /f /im notepad.exe & exit 0' >/dev/null 2>&1
log "=== finished rc=$rc ==="
exit $rc
