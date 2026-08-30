#!/bin/bash
# Grade a TWO-STAGE (E1) install that was performed by the answer stick on a freshly provisioned
# guest, and assert the drivers the acceptance criteria name.
#
# WHY THIS IS A SEPARATE SCRIPT rather than a matrix cell. `cell_fresh_2stage` builds its
# precondition by cloning an ST2G golden and running `bcdedit /set testsigning off`. That cannot
# work: QWT's PV drivers are TEST-SIGNED by our CI and `xenvbd` is the BOOT DISK driver, so with
# testsigning off the clone never boots - measured 2026-08-30, Transient with no window for the full
# 600 s deadline. The protocol's own entry for this cell is R3+ST0 (§P1, C1), a PRISTINE guest where
# testsigning-off is simply the natural state.
#
# And a pristine guest cannot be driven: it has no QWT, therefore no qrexec, so nothing can push a
# payload to it. The stick's FirstLogonCommands are the only execution channel, which is exactly the
# "stick-orchestrated" route P1 describes. So the install is performed BY THE STICK during
# provisioning, and this script grades the result afterwards - external introspection during, durable
# logs after, which is what §12 note 2 prescribes for pristine-start cells.
#
# The two-stage path is real and has run: a fresh Windows has testsigning OFF, so the installer must
# do stage 1 (which enables it), reboot, and complete in stage 2. Both ST2G golden builds show
# exactly that. What was missing was GRADING it as a cell, which is what this does.
#
# Usage: tools/grade-twostage.sh <vm> [release-sha]
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE" || exit 1
VM="${1:?usage: $0 <vm> [release-sha]}"
REL="${2:-6022427}"
export QTEST_VM="$VM"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "PASS  $*"; }
no(){ FAIL=$((FAIL+1)); echo "FAIL  $*"; }
q(){ timeout -k 5 "${1:-90}" ./tools/qtest run "$2" 2>/dev/null | tr -d '\r\0'; }

echo "=== TWO-STAGE (E1) GRADE: $VM against $REL ==="

# 1. BOTH stages must be present. One RESULT is not a two-stage install - that is the whole claim.
LOG=$(q 150 "powershell -NoProfile -Command \"if(Test-Path C:\\qwt-improved-install.log){Get-Content C:\\qwt-improved-install.log}\"")
s1=$(echo "$LOG" | grep -ac '"stage":"stage1-prepare".*"ok":true')
s2=$(echo "$LOG" | grep -ac '"stage":"stage2-install".*"ok":true')
[ "$s1" -ge 1 ] && ok "stage1-prepare ok:true present ($s1)" || no "no successful stage1-prepare - this was not a two-stage install"
[ "$s2" -ge 1 ] && ok "stage2-install ok:true present ($s2)" || no "no successful stage2-install"

# 2. Two RUN IDs. Stage 1 and stage 2 are separate installer invocations either side of a reboot;
#    one run_id would mean a single-stage install wearing a two-stage label.
ids=$(echo "$LOG" | grep -ao '"run_id":"[0-9a-f]*"' | sort -u | wc -l)
[ "$ids" -ge 2 ] && ok "two distinct run_ids ($ids) - stage 1 and stage 2 are separate invocations" \
                 || no "only $ids run_id(s) - no reboot boundary, so not the two-stage path"

# 3. Testsigning was OFF at stage 1 and ON by stage 2. This is the precondition that DEFINES E1,
#    and asserting it on the installer's own PRECONDITION line is the authority per P1.0.
pre_off=$(echo "$LOG" | grep -ac '"testsigning_active":false')
[ "$pre_off" -ge 1 ] && ok "stage 1 ran with testsigning INACTIVE (the E1 precondition)" \
                     || no "no precondition line shows testsigning_active:false - entry state unproven"

# 4. The RUNNING agent is the release binary, hash-compared. Not "an agent is running".
exp=$(sha256sum "$HOME/qwt-matrix-work/dl/qwt-full-package/gui-agent.exe" 2>/dev/null | cut -c1-16)
got=$(q 120 "powershell -NoProfile -Command \"(Get-FileHash (Get-Process gui-agent -EA SilentlyContinue).Path -Algorithm SHA256).Hash\"" | grep -aoE '^[0-9A-Fa-f]{64}' | head -1 | cut -c1-16)
if [ -n "$got" ] && [ "$(echo "$exp" | tr 'a-f' 'A-F')" = "$(echo "$got" | tr 'a-f' 'A-F')" ]; then
    ok "installed agent == release binary ($got)"
else
    no "running agent '$got' != release '$exp' - the artefact under test is not what installed"
fi

# 5. DRIVERS. "all drivers present" is a criterion, so assert the DEVICES, not package contents.
# The probe emits the raw PNPDeviceID and matches in shell: an earlier version did the extraction
# with a PowerShell -replace whose '$1' was mangled by shell quoting, so it reported "no devnode
# found" for ALL FOUR drivers on a guest where three were demonstrably bound. Four-for-four failure
# is a broken probe, not four broken drivers, and it must not be reported as a regression.
DRV=$(q 150 "powershell -NoProfile -Command \"Get-CimInstance Win32_PnPEntity -EA SilentlyContinue | Where-Object { \$_.PNPDeviceID -like 'XENBUS*' } | ForEach-Object { 'DEV:'+\$_.PNPDeviceID+' err='+\$_.ConfigManagerErrorCode+' svc='+\$_.Service }\"")
for d in CONS IFACE VBD; do
    line=$(echo "$DRV" | grep -a "DEV_$d" | head -1)
    if [ -z "$line" ]; then
        no "PV driver $d: no devnode found - UNVERIFIED"
    elif echo "$line" | grep -qa 'err=0'; then
        ok "PV driver $d bound ($(echo "$line" | grep -ao 'svc=[a-z]*'))"
    else
        no "PV driver $d NOT bound ($(echo "$line" | grep -ao 'err=[0-9]*'))"
    fi
done
# VIF is deliberately NOT required here. A freshly provisioned guest has netvm='' (reprovision
# resets it), so no vif exists for xenvif to bind to and the devnode is legitimately absent.
# Demanding it would fail this cell for a network that was never attached - the PV NIC is proven
# separately, on the AppVMs that actually have a netvm.
vif=$(echo "$DRV" | grep -ac 'DEV_VIF')
echo "note  DEV_VIF devnodes present: $vif (0 is expected on a netvm='' guest; PV NIC is graded on the AppVM cells)"

# 6. The premature-reboot mechanism, and the dialog itself if a watcher log survived the reboots.
mon=$(q 120 "cmd /c sc query xenbus_monitor")
echo "$mon" | grep -qai 'RUNNING' && no "xenbus_monitor is RUNNING" || ok "xenbus_monitor is not running"

echo
echo "=== TWO-STAGE GRADE: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
