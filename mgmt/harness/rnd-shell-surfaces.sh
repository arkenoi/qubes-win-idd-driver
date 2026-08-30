#!/bin/bash
# RND-3 / RND-4 / SG7 — menus and toasts, judged against what this build ACTUALLY does.
#
# TWO THINGS BROKE THESE CELLS BEFORE, AND BOTH WERE MINE.
#
# 1. THE INSTRUMENT WAS BLIND. `local.WinScreenshot` enumerates `_NET_CLIENT_LIST`, which by
#    definition excludes override-redirect windows — exactly what menus and toasts are. Every "not
#    in the shot" reading was meaningless. `local.WinFullScreen` builds its list from
#    `xwininfo -root -tree` filtered by `_QUBES_VMNAME`, so it DOES carry them, and
#    `tools/qtest-geom` extracts that list and deletes the desktop image unread (owner's rule,
#    2026-08-14: whole-desktop captures stay out of the repo and out of the transcript).
#
# 2. THE ACCEPTANCE CRITERION WAS WRONG, AND IT PRODUCED A FALSE PRODUCT FAIL.
#    The first version required a menu to appear as a SEPARATE override-redirect window in dom0 and
#    reported FAIL when it did not. This build does not work that way and never claimed to. Menus
#    are SYNTHESIZED: `SynthActivate` (agent/gui-agent/main.c:1774) marks the popup synthesized,
#    accounts it on its OWNER, paints it into the owner's framebuffer, and its own comment says
#    *"no protocol traffic from here on"*. Measured on win10-p46:
#        msg=SYNTH,hwnd=0x10214,owner=0x40020,x=268,y=310,w=229,h=196
#        msg=SYNTHPAINT,hwnd=0x10214,owner=0x40020,rx=1,ry=50,w=229,h=196
#        msg=MAP ... ovr=1  -> ZERO in the entire log
#    So the correct acceptance is (a) the agent synthesizes the popup onto the right owner, and
#    (b) THE OWNER'S dom0 PIXELS CHANGE — which is what "the user can see the menu" means. Checking
#    for a separate window was checking for a design this build deliberately does not have.
#
#    Toasts may take EITHER path (they are shell-owned and may have no eligible synth owner), so
#    this accepts either a new dom0 window OR a synth onto an owner whose pixels then change, and
#    RECORDS which one happened rather than assuming.
#
# qrexec runs as SYSTEM; menus and toasts are per-user shell surfaces, so everything user-facing
# goes through `guest/run-as-user.ps1` (schtasks /ru user /it) with a distinct -Tag, because that
# helper deletes its task on entry and a shared name kills a still-running sampler.
#
#   mgmt/harness/rnd-shell-surfaces.sh <vm> [outdir]
set -uo pipefail
cd /home/user/qubes-win-idd-driver
require_scripts(){ local m=""; for s in "$@"; do [ -f "$s" ] || m="$m $s"; done
  [ -z "$m" ] || { echo "FATAL: required guest script(s) missing:$m" >&2; exit 2; }; }
require_scripts guest/surface-watch.ps1 guest/fire-toast.ps1 guest/run-as-user.ps1 tools/qtest-geom

VM="${1:?usage: $0 <vm> [outdir]}"
OUT="${2:-$HOME/qwt-accept/20260830-acceptance-4.3.16/RNDSHELL-$VM}"
mkdir -p "$OUT"
TMP=$(mktemp -d)
GUEST='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
V="$OUT/verdicts.tsv"; EV=$(basename "$OUT"); rc=0
q(){ QTEST_VM=$VM timeout -k 8 "${T:-150}" ./tools/qtest "$@" 2>/dev/null; }
r(){ q run "$1" | tr -d '\r' | grep -avE '^(Microsoft Windows \[Version|\(c\) Microsoft|C:\\)'; }
log(){ echo "$(date -u +%H:%M:%S) rnd[$VM]: $*" | tee -a "$OUT/rnd.log"; }
geom(){ QTEST_VM=$VM timeout -k 8 200 ./tools/qtest-geom 2>/dev/null; }

parse_geom(){
python3 - "$1" <<'PY'
import sys
txt = open(sys.argv[1]).read()
has_mapped = None; tot = orc = 0; names = []
for line in txt.splitlines():
    if line.startswith('#'):
        # Layout comes from the HEADER, never from a data line's field count - a window title is
        # free text and may hold any number of spaces (tools/winshot.py:42-54).
        has_mapped = 'mapped' in line; continue
    if has_mapped is None or not line.strip(): continue
    f = line.split(None, 7 if has_mapped else 6)
    if len(f) < (7 if has_mapped else 6): continue
    tot += 1
    name = f[7] if has_mapped and len(f) > 7 else (f[6] if len(f) > 6 else '?')
    if f[5] not in ('0','False','false'):
        orc += 1; names.append(name.strip()[:40])
print(f"{tot}|{orc}|{','.join(names[:6])}")
PY
}

# hash of the largest mapped window - the synth OWNER. Pixel change here is the user-visible fact.
owner_hash(){
  local t="$TMP/o.tar"; rm -f "$t"; rm -rf "$TMP/ox"; mkdir -p "$TMP/ox"
  q shot "$t" >/dev/null 2>&1
  [ -s "$t" ] || { echo NOCAP; return; }
  tar xf "$t" -C "$TMP/ox" 2>/dev/null
  local big; big=$(ls -S "$TMP/ox"/*.png 2>/dev/null | head -1)
  [ -n "$big" ] || { echo NOWIN; return; }
  python3 -c "
import hashlib,struct,sys
b=open(sys.argv[1],'rb').read(); w,h=struct.unpack('>II',b[16:24])
print(f'{w}x{h}:{hashlib.sha256(b).hexdigest()[:16]}')" "$big"
}

cat > "$TMP/mark.ps1" <<'PS'
$d=(Get-ItemProperty 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -EA SilentlyContinue).LogDir
$f=(Get-ChildItem $d -Filter 'gui-agent-*.log' -EA SilentlyContinue | Sort-Object LastWriteTime -Desc | Select-Object -First 1)
if($f){ Write-Output ('AGENTMARK ' + @(Get-Content $f.FullName).Count) } else { Write-Output 'AGENTMARK 0' }
PS
cat > "$TMP/since.ps1" <<'PS'
param([int]$Mark, [string]$Pattern)
$d=(Get-ItemProperty 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -EA SilentlyContinue).LogDir
$f=(Get-ChildItem $d -Filter 'gui-agent-*.log' -EA SilentlyContinue | Sort-Object LastWriteTime -Desc | Select-Object -First 1)
if(-not $f){Write-Output 'SINCE_HITS 0';exit}
$all = Get-Content $f.FullName
$new = if ($all.Count -gt $Mark) { $all[$Mark..($all.Count-1)] } else { @() }
$h = @($new | Select-String -Pattern $Pattern -SimpleMatch)
Write-Output ("SINCE_HITS " + $h.Count)
@($h | Select-Object -First 3) | ForEach-Object { Write-Output ("  S " + $_.Line) }
PS
cat > "$TMP/menu.ps1" <<'PS'
# Open Notepad's File menu from INSIDE the user session. Sent from a qrexec (SYSTEM) process the
# keystroke never reaches the interactive desktop, which is why RND-3 was INVALID-VACUOUS before.
$ErrorActionPreference='Continue'
Add-Type -AssemblyName System.Windows.Forms
$w = New-Object -ComObject WScript.Shell
$null = $w.AppActivate('Untitled - Notepad'); Start-Sleep -Milliseconds 800
[System.Windows.Forms.SendKeys]::SendWait('%f')
Start-Sleep -Seconds 40
PS

log "=== disarm the update scan (P3: never concurrent with a rendering cell) ==="
cat > "$TMP/disarm.ps1" <<'PS'
$t = Get-ScheduledTask -TaskName QubesWindowsUpdateScan -EA SilentlyContinue
if ($t) { & schtasks /change /tn QubesWindowsUpdateScan /disable *>$null }
Get-Process qubes-updates-relay -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Write-Output 'DISARMED done'
PS
T=300 q pushrun "$TMP/disarm.ps1" >/dev/null 2>&1
trap 'q run "cmd /c schtasks /change /tn QubesWindowsUpdateScan /enable" >/dev/null 2>&1; rm -rf "$TMP"' EXIT

log "=== VALIDATE THE DETECTOR IN THIS SESSION (H5: no result counts until the instrument is) ==="
q push guest/surface-watch.ps1 >/dev/null 2>&1
q push guest/fire-toast.ps1 >/dev/null 2>&1
q push "$TMP/menu.ps1" >/dev/null 2>&1
st=$(T=400 q pushrun guest/run-as-user.ps1 -Script "$GUEST\\surface-watch.ps1" -ScriptArgs '-SelfTest' -Tag selftest | tr -d '\r')
echo "$st" | grep -ao '"detector_fires":[a-z]*' | head -1 | sed 's/^/  /'
echo "$st" | grep -qa '"detector_fires":true' || {
  log "FATAL: the surface detector did not fire on its own self-test; nothing it reports can be"
  log "       trusted in either direction. Refusing to grade."; exit 2; }

# ------------------------------------------------------------------ SCENE RESET
# fire-toast raises a PERSISTENT reminder toast: it stays until dismissed and SURVIVES BETWEEN RUNS.
# Measured 2026-08-31, twice: a toast left over from the previous run was on screen at baseline
# (override_redirect=1 before anything had been fired). It held focus, so the menu cell's Alt+F never
# reached Notepad; and it made RND-4's delta check read 1->1 and report FAIL for a toast that had in
# fact appeared. Restarting ShellExperienceHost dismisses everything it owns and it respawns on
# demand, so the run starts from a known scene instead of inheriting the last one.
log "=== scene reset: dismiss any leftover notifications ==="
r 'cmd /c taskkill /f /im ShellExperienceHost.exe & taskkill /f /im notepad.exe & exit 0' >/dev/null 2>&1
sleep 8
geom > "$TMP/gr.txt"; pre=$(parse_geom "$TMP/gr.txt"); preo=$(echo "$pre" | cut -d'|' -f2)
log "  after reset: total=${pre%%|*} override_redirect=$preo"
if [ "${preo:-0}" -ne 0 ]; then
  log "FATAL: an override-redirect surface is STILL on screen after the reset, so neither cell can"
  log "       measure a delta. Refusing to grade rather than reporting against a dirty scene."
  exit 2
fi

geom > "$TMP/g0.txt"; base=$(parse_geom "$TMP/g0.txt"); baseo=$(echo "$base" | cut -d'|' -f2)
log "  baseline dom0 list: total=${base%%|*} override_redirect=$baseo"

# ORDER MATTERS: the menu cell runs FIRST. fire-toast raises a PERSISTENT reminder toast, and on
# 2026-08-31 it was still on screen during the menu cell - it held focus so Alt+F never reached
# Notepad, and its 23 ovr=1 samples made the vacuity guard believe the menu had opened. Scene
# contamination between cells is a real failure mode; the cheap fix is ordering.
# ------------------------------------------------------------------ RND-3: menus (synth design)
log "=== RND-3: a menu must be SYNTHESIZED onto its owner, and the owner's pixels must change ==="
r 'cmd /c taskkill /f /im notepad.exe & exit 0' >/dev/null 2>&1
q run 'cmd /c start "" notepad.exe' >/dev/null 2>&1; sleep 16
h_before=$(owner_hash); log "  owner before menu: $h_before"
mark=$(T=200 q pushrun "$TMP/mark.ps1" | tr -d '\r' | grep -ao 'AGENTMARK [0-9]*' | awk '{print $2}')
T=200 q pushrun guest/run-as-user.ps1 -Tag menu -Script "$GUEST\\menu.ps1" -NoWait >/dev/null 2>&1
sleep 16
h_after=$(owner_hash); log "  owner with menu open: $h_after"
syn=$(T=300 q pushrun "$TMP/since.ps1" -Mark "${mark:-0}" -Pattern 'msg=SYNTH,hwnd=' | tr -d '\r' | grep -ao 'SINCE_HITS [0-9]*' | awk '{print $2}')
# #32768 SPECIFICALLY, not "any ovr=1 surface". Measured 2026-08-31: a persistent toast from the
# previous cell was still on screen, contributing 23 ovr=1 hits, so the cell concluded "the menu
# opened" when it had not - and then reported FAIL because nothing had been synthesized. A vacuity
# guard that any other surface can satisfy is not a vacuity guard.
ovr=$(T=300 q pushrun "$TMP/since.ps1" -Mark "${mark:-0}" -Pattern '#32768' | tr -d '\r' | grep -ao 'SINCE_HITS [0-9]*' | awk '{print $2}')
log "  agent: SYNTH events=${syn:-0}  #32768 menu surfaces seen=${ovr:-0}"
if [ "${ovr:-0}" -eq 0 ]; then
  log "  -> INVALID-VACUOUS: the agent never saw a #32768 menu window; the menu never opened"
  printf 'RND-3\tmenu-synthesized-onto-owner\tINVALID-VACUOUS\tno #32768 surface seen by the agent\t%s\n' "$EV" >> "$V"; rc=1
elif [ "${syn:-0}" -gt 0 ] && [ "$h_before" != "$h_after" ] && [ "$h_after" != NOCAP ] && [ "$h_after" != NOWIN ]; then
  log "  -> PASS: menu synthesized onto its owner AND the owner's dom0 pixels changed"
  printf 'RND-3\tmenu-synthesized-onto-owner\tPASS-UNPROVEN\t%s SYNTH events; owner capture %s -> %s\t%s\n' "$syn" "$h_before" "$h_after" "$EV" >> "$V"
elif [ "${syn:-0}" -eq 0 ]; then
  log "  -> FAIL: an override-redirect surface existed but the agent did not synthesize it"
  printf 'RND-3\tmenu-synthesized-onto-owner\tFAIL\t#32768 surfaces=%s but 0 SYNTH events\t%s\n' "$ovr" "$EV" >> "$V"; rc=1
else
  log "  -> FAIL: synthesized, but the owner's dom0 pixels did not change - invisible to the user"
  printf 'RND-3\tmenu-visible-in-dom0\tFAIL\t%s SYNTH events but owner capture identical (%s)\t%s\n' "$syn" "$h_before" "$EV" >> "$V"; rc=1
fi

# ------------------------------------------------------------------ RND-4 / SG7: toasts
log "=== RND-4 / SG7: a toast must reach the user - by EITHER path ==="
r 'cmd /c taskkill /f /im notepad.exe & exit 0' >/dev/null 2>&1
q run 'cmd /c start "" notepad.exe' >/dev/null 2>&1; sleep 16   # a synth owner, in case that path is used
r 'cmd /c del /q C:\qwt-improved-setup\surface-watch.jsonl 2>nul & exit 0' >/dev/null 2>&1
tmark=$(T=200 q pushrun "$TMP/mark.ps1" | tr -d '\r' | grep -ao 'AGENTMARK [0-9]*' | awk '{print $2}')
th_before=$(owner_hash)
# distinct -Tag: run-as-user deletes its task on entry, so a shared name kills the sampler
# base64 the args: they contain spaces and would be re-split at every hop (see run-as-user.ps1)
WB64=$(python3 -c "import base64;print(base64.b64encode('-DurationSeconds 90 -IntervalSeconds 1'.encode('utf-16-le')).decode())")
T=120 q pushrun guest/run-as-user.ps1 -Tag watch -Script "$GUEST\\surface-watch.ps1" -ArgsB64 "$WB64" -NoWait >/dev/null 2>&1
sleep 6
TB64=$(python3 -c "import base64;print(base64.b64encode(\"-Title 'QWT ACCEPT TOAST'\".encode('utf-16-le')).decode())")
T=300 q pushrun guest/run-as-user.ps1 -Tag toast -Script "$GUEST\\fire-toast.ps1" -ArgsB64 "$TB64" >/dev/null 2>&1
sleep 12
geom > "$TMP/g1.txt"; g1=$(parse_geom "$TMP/g1.txt"); cp "$TMP/g1.txt" "$OUT/geom-toast.txt"
o1=$(echo "$g1" | cut -d'|' -f2); n1=$(echo "$g1" | cut -d'|' -f3)
th_after=$(owner_hash)
tsyn=$(T=300 q pushrun "$TMP/since.ps1" -Mark "${tmark:-0}" -Pattern 'msg=SYNTH,hwnd=' | tr -d '\r' | grep -ao 'SINCE_HITS [0-9]*' | awk '{print $2}')
sw=$(r 'cmd /c powershell -NoProfile -Command "@(Get-Content C:\qwt-improved-setup\surface-watch.jsonl -EA SilentlyContinue | Select-String -Pattern ToastHost,ShellExperienceHost,CoreWindow).Count"' | grep -aoE '^[0-9]+$' | head -1)
log "  guest-side toast samples=${sw:-0}  dom0 o-r ${baseo}->${o1} [$n1]  synth=${tsyn:-0}  owner px $th_before -> $th_after"
if [ "${sw:-0}" -eq 0 ]; then
  log "  -> INVALID-VACUOUS: no toast surface guest-side; the stimulus never existed"
  printf 'RND-4\ttoast-reaches-dom0\tINVALID-VACUOUS\tno toast surface seen by a self-validated detector\t%s\n' "$EV" >> "$V"; rc=1
elif [ "${o1:-0}" -gt "${baseo:-0}" ]; then
  log "  -> PASS: the toast reached dom0 as its own override-redirect window"
  printf 'RND-4\ttoast-reaches-dom0\tPASS-UNPROVEN\tguest samples=%s; dom0 o-r %s->%s [%s] (own-window path)\t%s\n' "$sw" "$baseo" "$o1" "$n1" "$EV" >> "$V"
  printf 'SG7\ttoasts-survive-filter\tPASS-UNPROVEN\tthe chrome filter did not eat the notification\t%s\n' "$EV" >> "$V"
elif [ "${tsyn:-0}" -gt 0 ] && [ "$th_before" != "$th_after" ]; then
  log "  -> PASS: the toast was synthesized and the owner's pixels changed (synth path)"
  printf 'RND-4\ttoast-reaches-dom0\tPASS-UNPROVEN\tguest samples=%s; %s SYNTH events; owner px %s -> %s (synth path)\t%s\n' "$sw" "$tsyn" "$th_before" "$th_after" "$EV" >> "$V"
  printf 'SG7\ttoasts-survive-filter\tPASS-UNPROVEN\tthe chrome filter did not eat the notification\t%s\n' "$EV" >> "$V"
else
  log "  -> FAIL: the toast existed guest-side but reached dom0 by NEITHER path"
  printf 'RND-4\ttoast-reaches-dom0\tFAIL\tguest samples=%s but dom0 o-r stayed %s and no synth+pixel change\t%s\n' "$sw" "$o1" "$EV" >> "$V"; rc=1
fi

r 'cmd /c taskkill /f /im notepad.exe & exit 0' >/dev/null 2>&1
log "=== finished rc=$rc ==="
exit $rc
