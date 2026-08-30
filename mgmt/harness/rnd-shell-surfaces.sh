#!/bin/bash
# RND-3 / RND-4 / SG7 — menus and toasts, with instruments that can actually see them.
#
# WHY THESE CELLS KEPT FAILING TO GRADE. Both surfaces are OVERRIDE-REDIRECT, and
# `local.WinScreenshot` enumerates `_NET_CLIENT_LIST`, which by definition does not contain
# override-redirect windows. So the per-window shot is STRUCTURALLY BLIND to exactly the thing these
# cells are about, and every "not in the shot" reading was meaningless. The window list from
# `local.WinFullScreen` DOES carry them, complete with an `override_redirect` column — and
# `tools/qtest-geom` extracts that list and deletes the desktop image unread, so no whole-desktop
# capture is ever read or kept (owner's rule, 2026-08-14).
#
# The other half of why RND-3 died: qrexec runs as SYSTEM, and menus/toasts are per-user shell
# surfaces. `Alt+F` sent from a qrexec process never reached the interactive session, the menu never
# opened, and the cell was INVALID-VACUOUS. Everything user-facing here goes through
# `guest/run-as-user.ps1` (schtasks /ru user /it).
#
#   mgmt/harness/rnd-shell-surfaces.sh <vm> [outdir]
#
# Exit 0 = all cells graded PASS. 1 = a cell failed. 2 = precondition not established.
set -uo pipefail
cd /home/user/qubes-win-idd-driver

require_scripts(){
  local missing=""
  for s in "$@"; do [ -f "$s" ] || missing="$missing $s"; done
  [ -z "$missing" ] || { echo "FATAL: required guest script(s) missing:$missing" >&2; exit 2; }
}
require_scripts guest/surface-watch.ps1 guest/fire-toast.ps1 guest/run-as-user.ps1 tools/qtest-geom

VM="${1:?usage: $0 <vm> [outdir]}"
OUT="${2:-$HOME/qwt-accept/20260830-acceptance-4.3.16/RNDSHELL-$VM}"
mkdir -p "$OUT"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
GUEST='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
q(){ QTEST_VM=$VM timeout -k 8 "${T:-150}" ./tools/qtest "$@" 2>/dev/null; }
log(){ echo "$(date -u +%H:%M:%S) rnd[$VM]: $*" | tee -a "$OUT/rnd.log"; }
rc=0

# Window list for the VM, override-redirect included. Never a pixel is read.
geom(){ QTEST_VM=$VM timeout -k 8 200 ./tools/qtest-geom 2>/dev/null; }

# count_or <geometry> -> "<total>|<override_redirect count>|<sample titles>"
parse_geom(){
python3 - "$1" <<'PY'
import sys
txt = open(sys.argv[1]).read()
has_mapped = None
tot = orc = 0; names = []
for line in txt.splitlines():
    if line.startswith('#'):
        # Decide the column layout from the HEADER, never from a data line's field count -
        # a window title is free text and may contain any number of spaces (winshot.py:42-54).
        has_mapped = 'mapped' in line
        continue
    if has_mapped is None or not line.strip():
        continue
    f = line.split(None, 7 if has_mapped else 6)
    if len(f) < (7 if has_mapped else 6):
        continue
    tot += 1
    ovr = f[5]
    name = f[7] if has_mapped and len(f) > 7 else (f[6] if len(f) > 6 else '?')
    if ovr not in ('0', 'False', 'false'):
        orc += 1
        names.append(name.strip()[:40])
print(f"{tot}|{orc}|{','.join(names[:6])}")
PY
}

# ------------------------------------------------------------------ preconditions
log "=== disarm the update scan (P3: never concurrent with a rendering cell) ==="
cat > "$TMP/disarm.ps1" <<'PS'
$t = Get-ScheduledTask -TaskName QubesWindowsUpdateScan -EA SilentlyContinue
if (-not $t) { Write-Output 'DISARMED true'; exit 0 }
& schtasks /change /tn QubesWindowsUpdateScan /disable *>$null
Get-Process qubes-updates-relay -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Start-Sleep 2
Write-Output ('DISARMED ' + ((Get-ScheduledTask -TaskName QubesWindowsUpdateScan -EA SilentlyContinue).State -eq 'Disabled'))
PS
T=300 q pushrun "$TMP/disarm.ps1" | tr -d '\r' | grep -a DISARMED | sed 's/^/  /'
restore(){ q run 'cmd /c schtasks /change /tn QubesWindowsUpdateScan /enable & echo REENABLED' | tr -d '\r' | grep -a REENABLED | sed 's/^/  /'; }
trap 'restore; rm -rf "$TMP"' EXIT

log "=== VALIDATE THE DETECTOR IN THIS SESSION (H5: no result counts until the instrument is) ==="
q push guest/surface-watch.ps1 >/dev/null 2>&1
q push guest/fire-toast.ps1 >/dev/null 2>&1
st=$(T=400 q pushrun guest/run-as-user.ps1 -Script "$GUEST\\surface-watch.ps1" -ScriptArgs '-SelfTest' | tr -d '\r')
echo "$st" | grep -ao '"detector_fires":[a-z]*' | head -1 | sed 's/^/  /'
echo "$st" | grep -qa '"detector_fires":true' || {
  log "FATAL: the surface detector did not fire on its own self-test. Nothing it reports can be"
  log "       trusted, in either direction. Refusing to grade RND-3/RND-4/SG7."
  exit 2
}

base=$(geom > "$TMP/g0.txt"; parse_geom "$TMP/g0.txt")
log "  baseline dom0 window list: total=${base%%|*} override_redirect=$(echo "$base" | cut -d'|' -f2)"

# ------------------------------------------------------------------ RND-4 / SG7: toasts
log "=== RND-4 / SG7: a toast must REACH dom0 (the chrome filter must not eat notifications) ==="
q run 'cmd /c del /q C:\qwt-improved-setup\surface-watch.jsonl 2>nul & exit 0' >/dev/null 2>&1
# sampler first (bounded), then the toast, both in the USER session
T=120 q pushrun guest/run-as-user.ps1 -Script "$GUEST\\surface-watch.ps1" \
    -ScriptArgs '-DurationSeconds 90 -IntervalSeconds 1' -NoWait >/dev/null 2>&1
sleep 6
T=300 q pushrun guest/run-as-user.ps1 -Script "$GUEST\\fire-toast.ps1" -ScriptArgs "-Title 'QWT ACCEPT TOAST'" >/dev/null 2>&1
sleep 12
geom > "$TMP/g1.txt"; g1=$(parse_geom "$TMP/g1.txt")
cp "$TMP/g1.txt" "$OUT/geom-toast.txt"
t1=${g1%%|*}; o1=$(echo "$g1" | cut -d'|' -f2); n1=$(echo "$g1" | cut -d'|' -f3)
log "  dom0 during toast: total=$t1 override_redirect=$o1  [$n1]"
# guest-side vacuity: did a toast surface actually exist?
sw=$(T=300 q run 'cmd /c powershell -NoProfile -Command "Get-Content C:\qwt-improved-setup\surface-watch.jsonl -EA SilentlyContinue | Select-String -Pattern ToastHost,ShellExperienceHost,Windows.UI.Core.CoreWindow | Measure-Object | ForEach-Object Count"' | tr -d '\r' | grep -aoE '^[0-9]+$' | head -1)
log "  guest-side toast-surface samples: ${sw:-0}"
if [ "${sw:-0}" -gt 0 ] && [ "${o1:-0}" -gt "$(echo "$base" | cut -d'|' -f2)" ]; then
  log "  -> PASS: the toast existed guest-side AND a new override-redirect window reached dom0"
  printf 'RND-4\ttoast-reaches-dom0\tPASS-UNPROVEN\tguest-side samples=%s; dom0 o-r windows %s -> %s [%s]\t%s\n' \
    "$sw" "$(echo "$base" | cut -d'|' -f2)" "$o1" "$n1" "$(basename "$OUT")" >> "$OUT/verdicts.tsv"
  printf 'SG7\ttoasts-survive-filter\tPASS-UNPROVEN\tsame run: the chrome filter did not eat the notification\t%s\n' "$(basename "$OUT")" >> "$OUT/verdicts.tsv"
elif [ "${sw:-0}" -eq 0 ]; then
  log "  -> INVALID-VACUOUS: no toast surface guest-side; the stimulus never existed, so dom0 proves nothing"
  printf 'RND-4\ttoast-reaches-dom0\tINVALID-VACUOUS\tno toast surface seen guest-side by a self-validated detector\t%s\n' "$(basename "$OUT")" >> "$OUT/verdicts.tsv"; rc=1
else
  log "  -> FAIL: the toast existed guest-side but no new override-redirect window reached dom0"
  printf 'RND-4\ttoast-reaches-dom0\tFAIL\tguest-side samples=%s but dom0 o-r stayed at %s\t%s\n' \
    "$sw" "$o1" "$(basename "$OUT")" >> "$OUT/verdicts.tsv"; rc=1
fi

# ------------------------------------------------------------------ RND-3: menus
log "=== RND-3: an app menu must map as an OVERRIDE-REDIRECT popup ==="
cat > "$TMP/menu.ps1" <<'PS'
# Open Notepad's File menu from INSIDE the user session. Sent from a qrexec (SYSTEM) process this
# keystroke never reaches the interactive desktop, which is why RND-3 was INVALID-VACUOUS before.
$ErrorActionPreference='Continue'
Add-Type -AssemblyName System.Windows.Forms
Start-Process notepad.exe
Start-Sleep -Seconds 4
$w = New-Object -ComObject WScript.Shell
$null = $w.AppActivate('Untitled - Notepad')
Start-Sleep -Seconds 1
[System.Windows.Forms.SendKeys]::SendWait('%f')     # Alt+F
Start-Sleep -Seconds 2
Add-Type -Namespace M -Name W -MemberDefinition @'
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
public delegate bool EnumProc(IntPtr h, IntPtr l);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
'@
$n=0
$cb=[M.W+EnumProc]{ param($h,$l)
  if([M.W]::IsWindowVisible($h)){
    $c=New-Object Text.StringBuilder 128; [void][M.W]::GetClassNameW($h,$c,128)
    if($c.ToString() -eq '#32768'){ $script:n++ } }
  return $true }
[void][M.W]::EnumWindows($cb,[IntPtr]::Zero)
Write-Output ("MENU_WINDOWS " + $n)
Start-Sleep -Seconds 25
PS
q push "$TMP/menu.ps1" >/dev/null 2>&1
T=200 q pushrun guest/run-as-user.ps1 -Script "$GUEST\\menu.ps1" -NoWait >/dev/null 2>&1
sleep 22
geom > "$TMP/g2.txt"; g2=$(parse_geom "$TMP/g2.txt")
cp "$TMP/g2.txt" "$OUT/geom-menu.txt"
o2=$(echo "$g2" | cut -d'|' -f2); n2=$(echo "$g2" | cut -d'|' -f3)
mw=$(T=200 q run 'cmd /c type C:\ProgramData\Qubes\runasuser\out.txt' | tr -d '\r' | grep -ao 'MENU_WINDOWS [0-9]*' | awk '{print $2}')
log "  guest-side #32768 menu windows=${mw:-?}   dom0 override_redirect=$o2  [$n2]"
if [ "${mw:-0}" -gt 0 ] && [ "${o2:-0}" -gt "$(echo "$base" | cut -d'|' -f2)" ]; then
  log "  -> PASS: the menu opened guest-side AND mapped override-redirect in dom0"
  printf 'RND-3\tmenu-override-redirect\tPASS-UNPROVEN\tguest #32768=%s; dom0 o-r %s -> %s [%s]\t%s\n' \
    "$mw" "$(echo "$base" | cut -d'|' -f2)" "$o2" "$n2" "$(basename "$OUT")" >> "$OUT/verdicts.tsv"
elif [ "${mw:-0}" -eq 0 ]; then
  log "  -> INVALID-VACUOUS: the menu never opened guest-side (same trap as before). Cell grades nothing."
  printf 'RND-3\tmenu-override-redirect\tINVALID-VACUOUS\tno #32768 window guest-side\t%s\n' "$(basename "$OUT")" >> "$OUT/verdicts.tsv"; rc=1
else
  log "  -> FAIL: the menu opened guest-side but did not reach dom0 as an override-redirect window"
  printf 'RND-3\tmenu-override-redirect\tFAIL\tguest #32768=%s but dom0 o-r stayed at %s\t%s\n' "$mw" "$o2" "$(basename "$OUT")" >> "$OUT/verdicts.tsv"; rc=1
fi

q run 'cmd /c taskkill /f /im notepad.exe & taskkill /f /im powershell.exe & exit 0' >/dev/null 2>&1
log "=== finished rc=$rc ==="
exit $rc
