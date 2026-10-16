#!/bin/bash
# campaign-preflight.sh - EVERY REASON NOT TO START A CAMPAIGN, in one place that can be tested.
#
#   mgmt/harness/campaign-preflight.sh <release-package-run-id>
#
# Exit: 0 clear to launch · 11 the rig is busy · 12 the entry images are wrong · 13 the package or
#       the product is wrong · 14 CI is not green for the package's commit · 2 usage.
#
# WHY THIS IS A TRACKED FILE WITH A SUITE. These checks lived in a scratchpad chain script: untracked,
# unreviewed, covered by nothing. So the one thing standing between a mistake and FOUR HOURS of
# exclusive rig time - plus the operator's screen, which the visual cells take over - was a scratch
# file whose refusals had never been seen to fire. On this project that is the cardinal rule: never a
# PASS the check has not been seen to FAIL. tools/tests/campaign-preflight-selftest.sh drives every
# refusal below by stubbing the programs this script shells out to, so the REAL code path runs.
#
# EVERY EXTERNAL IS OVERRIDABLE for exactly that reason - the suite replaces gh, qvm-check, the
# golden tool and the CI reader, and nothing stubs this script itself.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 2

PKG="${1:-}"
[ -n "$PKG" ] || { echo "usage: $0 <release-package-run-id>" >&2; exit 2; }

GH_BIN="${GH_BIN:-gh}"
GOLDEN_SH="${GOLDEN_SH:-mgmt/golden.sh}"
QVM_CHECK="${QVM_CHECK:-qvm-check}"
CI_STATE="${CI_STATE:-python3 tools/ci-state.py}"
GOLDENS_DIR="${GOLDENS_DIR:-mgmt/goldens}"
FIXTURES_DIR="${FIXTURES_DIR:-mgmt/fixtures}"
# The fix under test must be IN the package. Named rather than assumed, so a campaign cannot be run
# against a build that predates the thing it is meant to prove.
FIX_FILE="${FIX_FILE:-guest/qwt-report-death.ps1}"
FIX_MARKER="${FIX_MARKER:-GUARD:bootbacklog}"
ENTRY_GOLDENS="${ENTRY_GOLDENS:-win10-base win11r-base win11r-qwt}"
ENTRY_FIXTURES="${ENTRY_FIXTURES:-win10-iqi:win10-base win11-iqi:win11r-base}"
SUBJECTS="${SUBJECTS:-win11r-lt win10-clean win11-clean win10-appvm win11-appvm win10-acc win11-acc}"
PRODUCT_PATHS="${PRODUCT_PATHS:-agent guest packaging driver tools/notifhost}"
# NOT FINISHED IS NOT RED (ci-state says CI 2). A package that built while another workflow was still
# compiling used to kill the run; an unfinished gate is worth waiting for, a red one never is.
CI_WAIT_SECONDS="${CI_WAIT_SECONDS:-3600}"
CI_POLL_SECONDS="${CI_POLL_SECONDS:-60}"

log(){ printf '%s %s\n' "$(date -u '+%H:%M:%S')" "$*"; }
die(){ local rc=$1; shift; log "[ERROR] STOP: $*"; exit "$rc"; }

# ---- 1. the entry images ------------------------------------------------------------------------
for g in $ENTRY_GOLDENS; do
    "$GOLDEN_SH" verify "$g" >/dev/null 2>&1 || die 12 "golden $g does not verify"
    log "golden $g verifies"
done
# A FIXTURE MUST TRACE TO THE SEAL THAT IS ACTUALLY ON THE RIG. Six seals for ABSENT images once made
# this rig look like it had goldens it did not, so the fixture's recorded base seal is compared with
# the golden's live one rather than merely existing.
for fx in $ENTRY_FIXTURES; do
    v=${fx%%:*}; b=${fx##*:}
    [ -f "$FIXTURES_DIR/$v.json" ] || die 12 "no fixture record for $v"
    [ -f "$GOLDENS_DIR/$b.json" ] || die 12 "no golden record for $b"
    fb=$(python3 -c "import json,sys;d=json.load(open(sys.argv[1]));print(d.get('base',''),d.get('base_sealed_utc',''))" "$FIXTURES_DIR/$v.json") || die 12 "fixture $v is unreadable"
    gb=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('sealed_utc',''))" "$GOLDENS_DIR/$b.json") || die 12 "golden $b is unreadable"
    [ "$fb" = "$b $gb" ] || die 12 "fixture $v was built from '$fb', but $b is sealed '$gb'"
    log "fixture $v traces to the live $b seal ($gb)"
done

# ---- 2. the rig is free ------------------------------------------------------------------------
# BY NAME, NEVER AN ENUMERATION: qvm-ls fires admin.vm.property.Get at every qube, this one included.
for v in $SUBJECTS; do
    if "$QVM_CHECK" --running "$v" >/dev/null 2>&1; then
        die 11 "$v is RUNNING - a campaign never starts beside a running subject"
    fi
done
log "no subject guest is running"

# ---- 3. ONE PRODUCT, and the fix is IN the package ---------------------------------------------
con=$("$GH_BIN" run view "$PKG" --json conclusion -q .conclusion 2>/dev/null)
[ "$con" = success ] || die 13 "release-package $PKG concluded '${con:-<unreadable>}'"
PKGSHA=$("$GH_BIN" run view "$PKG" --json headSha -q .headSha 2>/dev/null)
[ -n "$PKGSHA" ] || die 13 "could not read the commit behind package $PKG"
git merge-base --is-ancestor "$PKGSHA" HEAD 2>/dev/null || die 13 "${PKGSHA:0:8} is not an ancestor of HEAD"
# shellcheck disable=SC2086
drift=$(git diff --name-only "$PKGSHA"..HEAD -- $PRODUCT_PATHS 2>/dev/null)
[ -z "$drift" ] || die 13 "the product changed since the package was built: $(printf '%s' "$drift" | tr '\n' ' ')"
git show "$PKGSHA:$FIX_FILE" 2>/dev/null | grep -qa -- "$FIX_MARKER" \
    || die 13 "${PKGSHA:0:8} does not carry $FIX_MARKER in $FIX_FILE - wrong package for this campaign"
log "package $PKG built from ${PKGSHA:0:8}, carries $FIX_MARKER, no product drift since"

# ---- 4. CI green for THAT commit, from its own runs --------------------------------------------
# ci-state refuses an inherited green for a required gate, so "green" here means a run against this
# very commit - not an ancestor's, which is how a required gate was once satisfied for 15 hours.
waited=0
while :; do
    _ci=$($CI_STATE "$PKGSHA" 2>&1 | tail -1)
    case "$_ci" in
        "CI 0"*) log "CI green for ${PKGSHA:0:8}"; break ;;
        "CI 2"*)
            [ "$waited" -lt "$CI_WAIT_SECONDS" ] || die 14 "CI has not finished for ${PKGSHA:0:8} after ${waited}s"
            log "CI still running for ${PKGSHA:0:8} - waiting"
            sleep "$CI_POLL_SECONDS"; waited=$((waited + CI_POLL_SECONDS)) ;;
        *) die 14 "CI is not green for ${PKGSHA:0:8}: $_ci" ;;
    esac
done

log "PREFLIGHT CLEAR: package $PKG, commit ${PKGSHA:0:8}"
exit 0
