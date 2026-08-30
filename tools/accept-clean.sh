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

# SKIP_PROVISION=1 — grade a guest that is ALREADY installed, starting at the reboot (step 3).
#
# Steps 3-6 (boot-path reboot, WU posture, health assertion, pixels-actually-change, chrome) are
# the post-install acceptance the protocol requires of EVERY install cell, not just of ones this
# script provisioned. The clean-install cells C1/C2 now enter through the primer
# (mgmt/harness/prime-run.sh), because a pristine base has no qrexec and therefore cannot be
# reached any other way - so by the time they need grading the guest is installed and destroying
# it to reinstall it from an ISO would throw away the very artifact under test.
#
# Writing a second script for those steps is what protocol 0.8 forbids ("never write a second
# route to a result the rig already reaches"), and the last time it was done it returned 1603.
# Hence a switch, not a fork. LOOP is unused in this mode; pass any placeholder.
if [ "${SKIP_PROVISION:-0}" = 1 ]; then
    log "SKIP_PROVISION=1 - grading the guest as it stands; starting at the boot-path reboot"
    log "  (the guest must already carry the build under test - its provenance is the caller's claim)"
else

# --- 1. clean-slate reinstall (reprovision has its own flock + qrexec wait) ---------
log "reprovisioning from $LOOP (this destroys $VM)"
# PIPESTATUS, not $?: with `cmd | tee`, $? is TEE's status, so a failing reprovision was
# reported as success and the harness went on to poll a guest that had never started
# (measured 2026-08-07 - the run continued for minutes after reprovision exited 1).
"$HERE/scratchpad/reprovision.sh" "$VM" "$LOOP" 2>&1 | tee -a "$OUT/accept.log"
[ "${PIPESTATUS[0]}" -eq 0 ] || fail "reprovision failed (see $OUT/accept.log)"

# --- 2. wait for OUR installer to finish (it reboots ONCE; twice if it had to remove
#        a previous QWT first) -------------------------------------------------------
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
fi   # SKIP_PROVISION

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

# --- 3b. UPDATE POSTURE: record always; suppress ONLY in quick mode ------------------
# Owner, 2026-08-30: "for quick tests, we disable updater; for full pass we let them complete",
# and - correcting an earlier reading of mine - "we do not suppress it on standalonevm, neither
# it is 'premature'. premature boots were related to our install process which they broke."
#
# So Windows Update running on a self-updating StandaloneVM is EXPECTED behaviour, not a defect,
# and its restart dialog is a legitimate dialog. It is NOT the "premature reboot dialog" this
# matrix grades: that one came from our install process being broken by the PV drivers. Treating
# the two as one thing (which an earlier version of this block did, by suppressing WU
# unconditionally) would both hide a real dialog and mis-attribute it.
#
# ACCEPT_MODE=quick (default): disable the updater so a cell is a controlled measurement of OUR
#   package, with no background servicing mutating the guest mid-cell.
# ACCEPT_MODE=full: leave Windows Update alone and let updates complete - the realistic
#   StandaloneVM configuration, and the only mode that exercises the post-update state.
#
# The posture is RECORDED in both modes regardless, because a cell whose update state is unknown
# cannot be interpreted later.
ACCEPT_MODE="${ACCEPT_MODE:-quick}"
# On 2026-08-30 a cell was found running against a guest that had installed Windows updates on
# its own: win10-clean (StandaloneVM, netvm=fw-net) had NoAutoUpdate absent, wuauserv Running
# and RebootRequired=True. The cause is the deliberate StandaloneVM-with-direct-internet
# carve-out in qubes-windows-update.ps1, which strips NoAutoUpdate; attaching a netvm to test
# the PV NIC is what triggers it.
#
# In QUICK mode a guest that services updates mid-cell is not the artifact under test, so the
# updater is disabled after the state is recorded. In FULL mode it is left alone deliberately.
# Either way the state is RECORDED first: that record is the per-cell evidence of which
# configuration was actually measured, and it is never skipped.
log "recording WU state (mode=$ACCEPT_MODE)"
qq run "powershell -ep bypass -c \"'NAU:'+([string](Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name NoAutoUpdate -EA SilentlyContinue).NoAutoUpdate); 'SVC:'+(Get-Service wuauserv -EA SilentlyContinue).Status; 'PENDINGREBOOT:'+(Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'); 'SERVICING:'+@(Get-Process TiWorker,TrustedInstaller -EA SilentlyContinue).Count\"" \
    2>&1 | tr -d '\r' | grep -aE '^(NAU|SVC|PENDINGREBOOT|SERVICING):' > "$OUT/wu-state-before.txt" || true
if [ -s "$OUT/wu-state-before.txt" ]; then
    while read -r l; do log "    $l"; done < "$OUT/wu-state-before.txt"
    if grep -q '^NAU:$' "$OUT/wu-state-before.txt" || grep -q '^PENDINGREBOOT:True' "$OUT/wu-state-before.txt"; then
        log "note: guest is SELF-UPDATING (StandaloneVM direct-internet carve-out) - expected on a"
        log "      netvm-attached standalone, not a defect. Recorded; mode=$ACCEPT_MODE decides what happens next."
    fi
else
    # Missing data fails: without this record we cannot tell a controlled cell from a
    # contaminated one, which is the whole point of taking it.
    fail "could not read WU state - refusing to grade a cell whose update posture is unknown"
fi
if [ "$ACCEPT_MODE" = "quick" ]; then
    log "mode=quick: disabling the updater so this cell measures OUR package, not WU servicing"
    qq run "powershell -ep bypass -c \"New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Force | Out-Null; Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name NoAutoUpdate -Value 1 -Type DWord; Stop-Service wuauserv -Force -EA SilentlyContinue; Set-Service wuauserv -StartupType Disabled -EA SilentlyContinue\"" \
        >/dev/null 2>&1 || true
else
    # FULL pass: Windows Update is deliberately left running. A self-updating StandaloneVM is
    # the real configuration, and its restart dialog is a legitimate dialog - NOT the premature
    # reboot dialog this matrix grades, which came from our install process being broken by the
    # PV drivers. So health-check must not fail the cell on it: -SelfUpdatingAllowed downgrades
    # updates_dom0_owned to evidence for this cell only.
    log "mode=full: leaving Windows Update alone; updates are allowed to complete"
    HEALTH_ARGS="${HEALTH_ARGS:+$HEALTH_ARGS }-SelfUpdatingAllowed"
fi

# --- 4. activity + health assertion -------------------------------------------------
qq ps 'Start-Process notepad' >/dev/null 2>&1; sleep 5
log "running health-check.ps1"
# HEALTH_ARGS: pass -NoIddExpected ONLY for a deliberate Basic-Display-Adapter control run.
# It is not the default and must not become one: the IDD topology apply landed in the agent
# on 2026-08-07 (EnsureQubesIddSolo), so a release run asserts the IDD for real.
log "health-check args: ${HEALTH_ARGS:-<none, full IDD assertion>}"
QT=180 qq pushrun "$HERE/guest/health-check.ps1" ${HEALTH_ARGS:+$HEALTH_ARGS} 2>&1 | tr -d '\r' | grep -a '=== HEALTH ===' | tail -1 > "$OUT/health.json"
[ -s "$OUT/health.json" ] || fail "health-check produced no output"

# GATE ON asserted_all, NOT ok. `ok` is true when no HARD check failed, but it deliberately
# tolerates checks marked na (not applicable) - which is how a whole subsystem can drop out
# of a "passing" run without anyone noticing. A release run must have measured every one:
# disks (pv_disk_bound), network (pv_drivers_bound + network_carries_traffic) and display
# (idd_device_bound + desktop_on_idd + idd_modes_published) all asserted in the SAME run.
# ALLOW_NA=1 relaxes this to the old ok:true for deliberately partial configurations
# (e.g. an offline install, where the network checks cannot apply) - and says so loudly.
grep -q '"ok":true' "$OUT/health.json" || fail "health-check ok:false ($(cat "$OUT/health.json" | head -c 300))"
if [ "${ALLOW_NA:-0}" = 1 ]; then
    nas=$(python3 -c "
import json
d=json.loads(open('$OUT/health.json').read().split('=== HEALTH ===',1)[1])
print(','.join(d.get('not_applicable') or []) or 'none')" 2>/dev/null || echo '?')
    log "WARNING: ALLOW_NA=1 - not_applicable checks tolerated: ${nas:-none}"
else
    grep -q '"asserted_all":true' "$OUT/health.json" ||         fail "not every check was asserted (na present). $(python3 -c "
import json,sys
d=json.loads(open('$OUT/health.json').read().split('=== HEALTH ===',1)[1])
print('not_applicable=' + ','.join(d.get('not_applicable') or []) + ' failed=' + ','.join(d.get('failed') or []))
" 2>/dev/null || head -c 300 "$OUT/health.json")"
fi
log "health-check PASS (every check asserted)"

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
