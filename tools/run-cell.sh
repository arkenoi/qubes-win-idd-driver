#!/bin/bash
# Run ONE acceptance cell: install the published release onto a guest from the release ISO,
# reboot, and assert health. Verdict is the last line: CELL=PASS|FAIL reason=...
#
# WHY THIS EXISTS. The recent matrix cells were driven by ad-hoc shell written inline in a session
# that has since been compacted away, so the procedure existed only in a transcript. That is not a
# harness - a matrix that cannot be re-run identically cannot support "single package for all
# tests". This is that procedure, written down.
#
# Usage: tools/run-cell.sh <vm> <loopN carrying the release ISO> [outdir]
#   ACCEPT_MODE=quick (default) disables the updater after recording its state, so the cell
#                     measures OUR package rather than Windows Update servicing the guest.
#   ACCEPT_MODE=full  leaves Windows Update alone (the realistic StandaloneVM configuration).
#
# It does NOT reinstall Windows. Per the acceptance protocol, a full reprovision is warranted only
# for the cell that tests Windows-install-plus-QWT-at-first-logon; every other cell installs onto an
# existing Windows, which is also what makes the matrix affordable.
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE" || exit 1

VM="${1:?usage: $0 <vm> <loopN> [outdir]}"
LOOP="${2:?usage: $0 <vm> <loopN> [outdir]}"
OUT="${3:-evidence/cell-$VM-$(date +%Y%m%d-%H%M%S)}"
HOLDER=win-idd-mgmt
ACCEPT_MODE="${ACCEPT_MODE:-quick}"
mkdir -p "$OUT"

export QTEST_VM="$VM"
log(){ echo "$(date -u +%H:%M:%S) cell[$VM]: $*" | tee -a "$OUT/cell.log"; }
fail(){ log "CELL=FAIL reason=$*"; exit 1; }

# shellcheck source=/dev/null
. .claude/skills/win-guest-e2e/e2e-lib.sh 2>/dev/null || fail "could not source e2e-lib.sh"

log "mode=$ACCEPT_MODE loop=$LOOP out=$OUT"

# --- GATE 0: prove the payload is the build we mean, BEFORE it touches a guest -------------
# Non-negotiable: on 2026-08-29 a whole cell ran against a payload built from the commit BEFORE
# the fix under test, and every number it produced was about a different build.
if [ -d artifacts/rel ]; then
    tools/assert-payload.sh artifacts/rel 2>&1 | tee -a "$OUT/gate0.txt" | tail -2
    grep -q '^PASS' "$OUT/gate0.txt" || fail "Gate 0: payload does not match HEAD (see $OUT/gate0.txt)"
else
    fail "Gate 0: artifacts/rel missing - nothing to verify the ISO against"
fi

# --- 1. guest up ---------------------------------------------------------------------------
if ! echo "$(qstate)" | grep -qi Running; then
    log "starting $VM"; ./tools/qtest start >/dev/null 2>&1
fi
bootwait 15 log "$OUT" || fail "guest did not come up before the install"
log "guest alive"

# --- 2. attach the release ISO --------------------------------------------------------------
# Attached read-only as a cdrom. `assign` first (survives a reboot), falling back to a persistent
# attach - the install reboots, and a CD that vanishes mid-install looks exactly like a failed
# install an hour later.
if ! qvm-device block assign --option devtype=cdrom --ro "$VM" "$HOLDER:$LOOP" >/dev/null 2>&1; then
    qvm-device block attach --persistent --option devtype=cdrom --ro "$VM" "$HOLDER:$LOOP" >/dev/null 2>&1 \
        || log "note: ISO attach reported failure; verifying by drive letter anyway"
fi

# FIND THE ISO BY CONTENT, never by assuming a drive letter. Which letter Windows assigns depends
# on what else is attached, and a cell that installs from the WRONG disc is the same class of error
# as a wrong payload.
ISODRIVE=""
for _ in 1 2 3 4 5 6; do
    ISODRIVE=$(qrun 'powershell -NoProfile -Command "foreach($d in (Get-PSDrive -PSProvider FileSystem)){ if(Test-Path ($d.Name+\":\install.cmd\") -and (Test-Path ($d.Name+\":\MANIFEST.json\"))){ \"ISO:\"+$d.Name; break } }"' \
               | tr -d '\r' | sed -n 's/^ISO:\([A-Za-z]\)$/\1/p' | head -1)
    [ -n "$ISODRIVE" ] && break
    sleep 10
done
[ -n "$ISODRIVE" ] || fail "release ISO not visible in the guest (no drive with install.cmd + MANIFEST.json)"
log "release ISO at ${ISODRIVE}:"

# The ISO's own manifest must equal the payload Gate 0 just verified. Attaching the right file and
# installing from a stale disc still in the drive is a real way to lose a cell.
ISOCOMMIT=$(qrun "powershell -NoProfile -Command \"(Get-Content ${ISODRIVE}:\\MANIFEST.json -Raw | ConvertFrom-Json).source.driver_repo_commit\"" | tr -d '\r' | grep -oE '^[0-9a-f]{40}' | head -1)
WANT=$(git rev-parse HEAD)
[ "${ISOCOMMIT:0:12}" = "${WANT:0:12}" ] || fail "ISO carries ${ISOCOMMIT:0:12}, expected ${WANT:0:12}"
log "ISO provenance verified: ${ISOCOMMIT:0:12}"

# --- 3. install -------------------------------------------------------------------------------
startrun log || fail "could not arm the run marker (stale install log)"
log "launching install from ${ISODRIVE}:"
qrun "cmd /c start \"qwt\" ${ISODRIVE}:\\install.cmd" >/dev/null 2>&1
wait_install 40 log
rc=$?
_logtail > "$OUT/install-log.txt" 2>/dev/null
[ "$rc" = 2 ] && fail "install reported failure (see $OUT/install-log.txt)"
[ "$rc" = 1 ] && fail "install stalled (see $OUT/install-log.txt)"
log "install finished"

# --- 4. reboot: acceptance is the BOOT path -----------------------------------------------
if echo "$(qstate)" | grep -qi Halted; then
    ./tools/qtest start >/dev/null 2>&1
else
    ./tools/qtest shutdown >/dev/null 2>&1
    for _ in $(seq 1 30); do echo "$(qstate)" | grep -qi Halted && break; sleep 10; done
    ./tools/qtest start >/dev/null 2>&1
fi
bootwait 20 log "$OUT" || fail "guest did not return after the post-install reboot"
log "back from reboot; settling 45s"; sleep 45

# --- 5. update posture: RECORD always, suppress only in quick mode -------------------------
qrun "powershell -NoProfile -Command \"'NAU:'+([string](Get-ItemProperty 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate\\AU' -Name NoAutoUpdate -EA SilentlyContinue).NoAutoUpdate); 'SVC:'+(Get-Service wuauserv -EA SilentlyContinue).Status; 'PENDINGREBOOT:'+(Test-Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\WindowsUpdate\\Auto Update\\RebootRequired')\"" \
    2>&1 | tr -d '\r' | grep -aE '^(NAU|SVC|PENDINGREBOOT):' > "$OUT/wu-state.txt"
[ -s "$OUT/wu-state.txt" ] || fail "could not read the update posture - refusing to grade a cell whose update state is unknown"
while read -r l; do log "  $l"; done < "$OUT/wu-state.txt"

HEALTH_ARGS=""
if [ "$ACCEPT_MODE" = "quick" ]; then
    log "mode=quick: disabling the updater so this cell measures our package"
    qrun "powershell -NoProfile -Command \"New-Item -Path 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate\\AU' -Force | Out-Null; Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate\\AU' -Name NoAutoUpdate -Value 1 -Type DWord; Stop-Service wuauserv -Force -EA SilentlyContinue; Set-Service wuauserv -StartupType Disabled -EA SilentlyContinue\"" >/dev/null 2>&1
else
    # A self-updating StandaloneVM is expected in this mode, and its WU restart dialog is a
    # legitimate dialog - NOT the premature reboot dialog this matrix grades.
    log "mode=full: leaving Windows Update alone"
    HEALTH_ARGS="-SelfUpdatingAllowed"
fi

# --- 6. health ------------------------------------------------------------------------------
qpr "guest/health-check.ps1${HEALTH_ARGS:+ $HEALTH_ARGS}" 2>&1 | tr -d '\r' | grep -a '=== HEALTH ===' | tail -1 > "$OUT/health.json"
[ -s "$OUT/health.json" ] || fail "health-check produced no output"
python3 - "$OUT/health.json" <<'PY' | tee -a "$OUT/cell.log"
import json,sys
raw=open(sys.argv[1]).read().split('=== HEALTH ===',1)[-1]
d=json.loads(raw)
bad=[k for k,v in d.get('checks',{}).items() if not v.get('pass')]
print("  health ok=%s failed=%s" % (d.get('ok'), ",".join(bad) if bad else "none"))
sys.exit(0 if d.get('ok') else 1)
PY
[ "${PIPESTATUS[0]}" -eq 0 ] || fail "health-check reported failures (see $OUT/health.json)"

log "CELL=PASS reason=install+boot+health all asserted on ${ISOCOMMIT:0:12}"
exit 0
