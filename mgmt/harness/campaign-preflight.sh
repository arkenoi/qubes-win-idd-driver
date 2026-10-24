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
# EVERY FIX THIS CAMPAIGN IS MEANT TO PROVE, as <file>:<marker> pairs. One pair was enough while one
# fix was under test; a campaign that tests a package missing the P1 fix would report a clean run for
# a build that cannot have fixed it, which is the shape of a receipt for work nobody did. Add a pair
# when a campaign is the receipt for a new fix.
# 2026-10-24: the two new pairs are the fixes the NEXT campaign is the receipt for, added under this
# paragraph's own rule. AND THE PATH MATTERS: this check reads `git show $PKGSHA:<file>` out of THIS
# repo, and `agent/` is a SUBMODULE - a gitlink, not a tree - so no marker inside agent/ can ever
# resolve here. The first attempt named agent/gui-agent/wgcbroker_ipc.h and the suite caught it as
# "does not carry CropWinValid" against a commit that does. Most product fixes live in that
# submodule, so until this check can follow a gitlink, a fix there has to be named through a
# parent-repo file that moves with it - here the broker, which writes the same flag.
# CropWinValid is the ABI 28 flag whose absence made the de-slice crop warning
# fire on three win11 cells of run 40037710497 (findings/issues.md DESLICECROPFALLSBACKONWIN11 is OPEN
# until a campaign measures it on a build that HAS it - so a package without it cannot be that
# receipt). cut_predecessor is the ingestion-time sweep exclusion: without it the campaign's own
# verdict is computed over the predecessor's lines, which is what voided run 40037710497's.
FIX_MARKERS="${FIX_MARKERS:-guest/qwt-report-death.ps1:GUARD:bootbacklog tools/notifhost/notifhost.cpp:NotifyDeferDrain tools/wgcbroker/wgcbroker.cpp:CropWinValid tools/log-sweep.py:cut_predecessor}"
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

# ---- 2b. THE RIG CAN ACTUALLY HOST IT ----------------------------------------------------------
# WHY THIS SECTION EXISTS, and it is the whole reason the owner asked for it. Campaign 40134888669
# ABORTED 11 minutes in, on its FIRST cell, with `log-volume bind FAILED
# reason=no_volume_labelled_DIAG_with_LOGVOL.TAG`. Nothing above would have caught it: the goldens
# verified, the fixtures traced, no subject was running, the package was right and CI was green. The
# preparation was what was wrong, and preparation had no gate at all. Owner 2026-10-25: "all
# preparation and preflight gates should be mecahnized too. goldens and loopbacks availability should
# be mechanically ensured as well" and "also free disk space required for campaign".
# Exit 15 is "the rig cannot host this campaign" - distinct from 11 (busy) and 12 (entry images),
# because the operator's next action is different: free space, restore a tool, clear a claim.
MTOOLS_BINS="${MTOOLS_BINS:-mcopy mdir minfo mformat}"
POOL_NAME="${POOL_NAME:-vm-pool}"
POOL_FLOOR_GB="${POOL_FLOOR_GB:-60}"
# THE RIG'S SAFE THRESHOLD, and it is a REFUSAL here, not a warning. 60 is matrix.sh's per-CELL
# floor - enough to start one cell - and matrix.sh additionally warned below 90 while starting
# anyway, which is how campaign 40134888669 began with 73 GB and was told "tight to finish". Owner
# 2026-10-25: "our safe threshold is 90% thin pool and it is unmet". So a campaign does not start
# below it. (Jev preferred measured-peak-first and rated raise-to-90 at 0.01 - on the evidence it
# had, which was a threshold nobody had measured. This is the rig's owner stating the policy for his
# own pool, which is not the same question, and the measured-peak gate below still applies on top.)
POOL_SAFE_GB="${POOL_SAFE_GB:-90}"
SPACE_RECORD="${SPACE_RECORD:-mgmt/campaign-space.json}"
LOGVOL_DIR="${LOGVOL_DIR:-$HOME/win-iso/logvol}"   # the same default logvol-lib carries
BLOCKCLAIM_LIB="${BLOCKCLAIM_LIB:-mgmt/harness/blockclaim-lib.sh}"
# The pool read is its own external BECAUSE THE SUITE HAS TO DRIVE THE REFUSAL: a check that cannot
# be made to fail is decoration, and qubesadmin cannot be stubbed from a test. Prints GB free, or
# nothing when it cannot tell - and "cannot tell" is a refusal, never an assumption.
POOL_FREE_CMD="${POOL_FREE_CMD:-}"

# (a) THE TOOLS THAT READ THE EVIDENCE. mtools lives in ~/bin and is LOST ON EVERY MGMT REBOOT
# (findings: rpm2cpio recovery) - and without it the log volume cannot be read at all, which is the
# one instrument that survives a wedge. A campaign that discovers this in hour three has wasted it.
for _b in $MTOOLS_BINS; do
    command -v "$_b" >/dev/null 2>&1 || die 15 "$_b is not on PATH - mtools is lost on every mgmt reboot and the log volume is unreadable without it (restore with rpm2cpio into ~/bin)"
done
command -v udisksctl >/dev/null 2>&1 || die 15 "udisksctl is not on PATH - images cannot be put on loop devices without it"
log "evidence tools present: $MTOOLS_BINS udisksctl"

# (b) THE LOG VOLUME DIRECTORY AND EVERY EXISTING IMAGE. An image that exists must be a volume this
# harness made: label DIAG + LOGVOL.TAG, read with mtools and no guest. A corrupt or foreign image is
# refused here rather than by a bind nine minutes into a cell.
[ -d "$LOGVOL_DIR" ] || die 15 "no log-volume directory at $LOGVOL_DIR"
[ -w "$LOGVOL_DIR" ] || die 15 "log-volume directory $LOGVOL_DIR is not writable"
_imgs=0; _bad=""
for _v in $SUBJECTS; do
    _img="$LOGVOL_DIR/logs-$_v.img"
    [ -s "$_img" ] || continue          # absent is fine: logvol_create makes it for the cell
    _imgs=$((_imgs+1))
    if ! MTOOLS_SKIP_CHECK=1 mdir -i "$_img" :: 2>/dev/null | grep -qi 'LOGVOL'; then
        _bad="$_bad $_v"
    fi
done
[ -z "$_bad" ] || die 15 "these existing log volumes carry no LOGVOL.TAG and are not volumes this harness made:$_bad (delete them or re-create with logvol_create)"
log "log volumes: $LOGVOL_DIR writable, $_imgs existing image(s), each carrying LOGVOL.TAG"

# (c) NO STALE BLOCK CLAIM. A persistent `assign --required` naming a transient loop number makes a
# guest unstartable with nothing but `internal error: libxenlight failed to create new domain`, and
# the predicate is the BACKING FILE, not the presence of a loop node (blockclaim-lib's own lesson).
# The sweep is the committed code; this only refuses when it cannot leave the guest startable.
if [ -r "$BLOCKCLAIM_LIB" ]; then
    # shellcheck disable=SC1091
    . "$BLOCKCLAIM_LIB"
    _stuck=""
    for _v in $SUBJECTS; do
        "$QVM_CHECK" "$_v" >/dev/null 2>&1 || continue      # a subject that does not exist yet has no claims
        claim_sweep_stale "$_v" >/dev/null 2>&1 || _stuck="$_stuck $_v"
    done
    [ -z "$_stuck" ] || die 15 "stale block claims remain on:$_stuck - these guests cannot be created until they are dropped (mgmt/harness/blockclaim-lib.sh claim_drop_loop)"
    log "no stale block claim on any subject"
else
    die 15 "$BLOCKCLAIM_LIB is missing - stale loop claims cannot be checked, and one makes a guest unstartable"
fi

# (d) FREE SPACE, AND THE FLOOR IS MEASURED OR IT IS NOT CLAIMED. Jev: measured-peak-first 0.91 -
# refusing to assert a number nobody measured. Campaign 40134888669 started with 73 GB and the
# harness only WARNED ("warn below 90 - enough to start, tight to finish"); that 90 was a threshold,
# not an observation. So: always refuse below the committed per-cell floor (matrix.sh refuses there
# anyway, and finding it out at minute 0 is the point), and refuse below a measured campaign PEAK
# only once one exists in $SPACE_RECORD. Until then the campaign-level requirement is UNVERIFIED and
# says so, rather than inventing a bound.
if [ -n "$POOL_FREE_CMD" ]; then
    _free=$($POOL_FREE_CMD 2>/dev/null | tr -dc '0-9')
else
    _free=$(python3 - "$POOL_NAME" <<'PYPOOL' 2>/dev/null
import sys
try:
    import qubesadmin
    p = qubesadmin.Qubes().pools[sys.argv[1]]
    d = p.usage_details
    print(int((int(d['data_size']) - int(d['data_usage'])) / (1024**3)))
except Exception:
    print("")
PYPOOL
)
fi
[ -n "$_free" ] || die 15 "the free space on pool '$POOL_NAME' could not be read - a campaign is not started blind on space"
[ "$_free" -ge "$POOL_FLOOR_GB" ] || die 15 "only ${_free} GB free on $POOL_NAME, the per-cell floor is ${POOL_FLOOR_GB} GB - matrix.sh would refuse the first cell"
[ "$_free" -ge "$POOL_SAFE_GB" ] || die 15 "only ${_free} GB free on $POOL_NAME and the rig's SAFE THRESHOLD is ${POOL_SAFE_GB} GB - reclaim first (mgmt/harness/rig-cleanup.sh lists every leftover subject and removes them with --go); a pool that fills mid-campaign invalidates every cell, not just the one that filled it"
_peak=""
[ -s "$SPACE_RECORD" ] && _peak=$(python3 -c "import json,sys
try:
    d=json.load(open(sys.argv[1]))
    v=d.get('peak_used_gb')
    print(int(v) if v is not None else '')
except Exception: print('')" "$SPACE_RECORD" 2>/dev/null)
if [ -n "$_peak" ]; then
    [ "$_free" -ge "$_peak" ] || die 15 "only ${_free} GB free on $POOL_NAME and a measured campaign peak is ${_peak} GB ($SPACE_RECORD) - this campaign would run out"
    log "space: ${_free} GB free on $POOL_NAME, above the MEASURED campaign peak of ${_peak} GB"
else
    log "space: ${_free} GB free on $POOL_NAME, above the per-cell floor of ${POOL_FLOOR_GB} GB - the campaign-level requirement is UNVERIFIED (no peak recorded in $SPACE_RECORD yet; the matrix records one as it runs)"
fi

# ---- 3. ONE PRODUCT, and the fix is IN the package ---------------------------------------------
con=$("$GH_BIN" run view "$PKG" --json conclusion -q .conclusion 2>/dev/null)
[ "$con" = success ] || die 13 "release-package $PKG concluded '${con:-<unreadable>}'"
PKGSHA=$("$GH_BIN" run view "$PKG" --json headSha -q .headSha 2>/dev/null)
[ -n "$PKGSHA" ] || die 13 "could not read the commit behind package $PKG"
git merge-base --is-ancestor "$PKGSHA" HEAD 2>/dev/null || die 13 "${PKGSHA:0:8} is not an ancestor of HEAD"
# shellcheck disable=SC2086
drift=$(git diff --name-only "$PKGSHA"..HEAD -- $PRODUCT_PATHS 2>/dev/null)
[ -z "$drift" ] || die 13 "the product changed since the package was built: $(printf '%s' "$drift" | tr '\n' ' ')"
for _fm in $FIX_MARKERS; do
    _ff=${_fm%%:*}; _mk=${_fm#*:}
    # NOT grep. This shell's `grep` can be ugrep, which treats a large .cpp as binary and SKIPS it -
    # so the gate said "8fe8828a does not carry NotifyDeferDrain" about a commit that carries it
    # twice, and `command grep` on the same input said present. A gate whose verdict depends on
    # which grep is installed is not a gate; python3 is already a hard dependency of every check
    # above and reads the stream the same way everywhere.
    git show "$PKGSHA:$_ff" 2>/dev/null \
        | python3 -c 'import sys; sys.exit(0 if sys.argv[1].encode() in sys.stdin.buffer.read() else 1)' "$_mk" \
        || die 13 "${PKGSHA:0:8} does not carry '"'"'$_mk'"'"' in $_ff - wrong package for this campaign"
    log "package carries '$_mk' in $_ff"
done
log "package $PKG built from ${PKGSHA:0:8}, carries every fix under test, no product drift since"

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
