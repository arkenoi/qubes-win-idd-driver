#!/bin/bash
# Clean-path release acceptance, end to end: destroy + reinstall the guest from the
# release ISO, wait for our package's unattended install to finish, REBOOT (the boot
# path is part of acceptance), then assert actual health - not just hashes:
#   - guest/health-check.ps1 (IDD bound + desktop on it, mode loop, PnP sweep,
#     agent binary/process/log)
#   - pixels actually change in dom0 when the guest paints (two shots around a
#     visible change must differ)
# Evidence lands in <outdir>; verdict is the last line: ACCEPT=PASS|FAIL reason=...
#
# Usage: tools/accept-clean.sh <vm> <loopN> [outdir]
#   The loop device must already carry the release ISO (sudo losetup in this qube).
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
VM="${1:?usage: $0 <vm> <loopN> [outdir]}"
LOOP="${2:?usage: $0 <vm> <loopN> [outdir]}"
OUT="${3:-evidence/accept-$VM-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"
log() { echo "$(date -u +%H:%M:%S) accept[$VM]: $*" | tee -a "$OUT/accept.log"; }
fail() { log "ACCEPT=FAIL reason=$*"; exit 1; }

qq() { QTEST_VM="$VM" timeout "${QT:-60}" "$HERE/tools/qtest" "$@"; }

# --- 1. clean-slate reinstall (reprovision has its own flock + qrexec wait) ---------
log "reprovisioning from $LOOP (this destroys $VM)"
# PIPESTATUS, not $?: with `cmd | tee`, $? is TEE's status, so a failing reprovision was
# reported as success and the harness went on to poll a guest that had never started
# (measured 2026-08-07 - the run continued for minutes after reprovision exited 1).
"$HERE/scratchpad/reprovision.sh" "$VM" "$LOOP" 2>&1 | tee -a "$OUT/accept.log"
[ "${PIPESTATUS[0]}" -eq 0 ] || fail "reprovision failed (see $OUT/accept.log)"

# --- 2. wait for OUR installer to finish (it reboots the guest up to 3 times) -------
# The finished marker is a RESULT trailer with ok:true in C:\qwt-improved-install.log
# AND the gui-agent process running. Missing log after the budget = fail (never skip).
log "waiting for the release install to complete in-guest"
t0=$(date +%s); done_install=0
while [ $(( $(date +%s) - t0 )) -lt 2400 ]; do
    r=$(qq run 'powershell -NoProfile -Command "(Select-String -Path C:\qwt-improved-install.log -Pattern \"=== RESULT ===\" | Select-Object -Last 1).Line; (Get-Process gui-agent -ErrorAction SilentlyContinue) -ne $null"' 2>/dev/null | tr -d '\r\0')
    echo "$r" | grep -q '"stage":"stage2-install".*"ok":true' && echo "$r" | grep -qi 'True$' && { done_install=1; break; }
    sleep 45
done
[ "$done_install" = 1 ] || fail "install never reported stage2 ok:true + running agent (see $OUT/accept.log)"
qq run 'powershell -NoProfile -Command "Get-Content C:\qwt-improved-install.log -Tail 40"' > "$OUT/install-log-tail.txt" 2>&1
log "install reported complete"

# --- 3. reboot: acceptance is the BOOT path, not the just-installed session ---------
log "reboot for boot-path acceptance"
qq shutdown >/dev/null 2>&1
t0=$(date +%s)
while [ $(( $(date +%s) - t0 )) -lt 300 ]; do
    QTEST_VM="$VM" "$HERE/tools/qtest" state 2>/dev/null | tr -d '\0' | grep -q Halted && break
    sleep 10
done
QTEST_VM="$VM" "$HERE/tools/qtest" start >/dev/null 2>&1
t0=$(date +%s)
until out=$(qq run 'echo BOOT_OK' 2>&1) && grep -q BOOT_OK <<<"$out"; do
    [ $(( $(date +%s) - t0 )) -gt 900 ] && fail "guest did not answer qrexec after reboot"
    sleep 15
done
log "back from reboot; settling 45s"; sleep 45

# --- 4. activity + health assertion -------------------------------------------------
qq ps 'Start-Process notepad' >/dev/null 2>&1; sleep 5
log "running health-check.ps1"
QT=180 qq pushrun "$HERE/guest/health-check.ps1" 2>&1 | tr -d '\r' | grep -a '=== HEALTH ===' | tail -1 > "$OUT/health.json"
[ -s "$OUT/health.json" ] || fail "health-check produced no output"
grep -q '"ok":true' "$OUT/health.json" || fail "health-check ok:false ($(cat "$OUT/health.json" | head -c 300))"
log "health-check PASS"

# --- 5. pixels change in dom0 (the judge is output, not logs) -----------------------
log "visual: two shots around a visible change"
qq shot "$OUT/shot1.tar" >/dev/null 2>&1
# Typing goes through a pushed script: nested quotes do not survive qtest's cmd-level
# quoting, and a silently-unexecuted SendKeys would make the two shots identical -
# failing the run with a misleading reason.
cat > "$OUT/type-marker.ps1" <<'PSEOF'
$w = New-Object -ComObject WScript.Shell
$null = $w.AppActivate((Get-Process notepad | Select-Object -First 1).Id)
Start-Sleep -Milliseconds 500
$w.SendKeys('QUBES ACCEPTANCE ' + (Get-Date -Format 'HH:mm:ss'))
Write-Output 'TYPED'
PSEOF
typed=$(QT=60 qq pushrun "$OUT/type-marker.ps1" 2>&1 | tr -d '\r')
grep -q TYPED <<<"$typed" || fail "marker typing never executed in the guest"
sleep 4
qq shot "$OUT/shot2.tar" >/dev/null 2>&1
[ -s "$OUT/shot1.tar" ] && [ -s "$OUT/shot2.tar" ] || fail "screenshot service returned empty tar (no mapped windows?)"
h1=$(sha256sum "$OUT/shot1.tar" | cut -d' ' -f1); h2=$(sha256sum "$OUT/shot2.tar" | cut -d' ' -f1)
[ "$h1" != "$h2" ] || fail "shots identical - guest pixels are not reaching dom0"
log "pixels change confirmed (tars differ)"

# --- 6. the window still contains its own chrome -----------------------------------
# "Pixels changed" does not mean "the window is intact": a geometry bug cropped the
# title bar and menu bar out of every maximized window on 2026-08-07 while every
# numeric check passed. This assertion has been seen to FAIL on that build.
mkdir -p "$OUT/perwin" && tar -xf "$OUT/shot2.tar" -C "$OUT/perwin" 2>/dev/null
shopt -s nullglob
pngs=("$OUT/perwin"/*.png)
shopt -u nullglob
[ ${#pngs[@]} -gt 0 ] || fail "per-window shot contained no PNGs - cannot judge window content"
chrome_ok=0
for p in "${pngs[@]}"; do
    out=$("$HERE/tools/check-chrome.py" "$p" 2>&1); rc=$?
    log "chrome check $(basename "$p"): $out"
    [ $rc -eq 0 ] && chrome_ok=1
done
[ $chrome_ok -eq 1 ] || fail "no captured window contains its chrome (title/menu bar cropped)"
log "window chrome present"

log "ACCEPT=PASS evidence=$OUT"
