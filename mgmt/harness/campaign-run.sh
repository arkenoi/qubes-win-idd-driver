#!/bin/bash
# campaign-run.sh - start a full acceptance campaign, but only against a package that can prove it
# is the right one.
#
#   PKG=<release-package-run-id> mgmt/harness/campaign-run.sh
#
# Exit: whatever the preflight refused with (11/12/13/14), else release-acceptance's own code.
#
# WHY IT IS TRACKED. This was a scratch file. A campaign costs FOUR HOURS of exclusive rig time and
# takes over the operator's screen for the visual cells, and the only thing standing between a
# mistake and that cost was an untracked script nobody had reviewed and no suite covered. The
# refusals are now mgmt/harness/campaign-preflight.sh with tools/tests/campaign-preflight-selftest.sh
# driving one CLEAR case and ten distinct refusals, each watched to fire.
#
# IT OWNS NO JUDGEMENT OF ITS OWN. The preflight decides whether to start; release-acceptance runs
# the cells; tools/campaign-state.py reads the verdict from the per-cell report.json artifacts rather
# than from log prose - which is the defect that once reported four failed cells as "0 FAIL".
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 2

PKG="${PKG:-${1:-}}"
[ -n "$PKG" ] || { echo "usage: PKG=<release-package-run-id> $0" >&2; exit 2; }

# The matrix's entry images and fixtures. Named here rather than defaulted inside the harness, so a
# run says in one place which images it entered from.
: "${G10:=win10-iqi}" "${G11:=win11-iqi}" "${B10:=win10-base}" "${B11:=win11r-base}" "${F11:=win11r}"

log(){ printf '%s %s\n' "$(date -u '+%H:%M:%S')" "$*"; }

mgmt/harness/campaign-preflight.sh "$PKG" || exit $?

log "starting full acceptance against release-package $PKG"
G10="$G10" G11="$G11" B10="$B10" B11="$B11" F11="$F11" \
    tools/release-acceptance.sh --run "$PKG"
rc=$?
log "release-acceptance exited rc=$rc"
# THE AUTHORITATIVE VERDICT, from the artifacts. Never a grep over the campaign log.
python3 tools/campaign-state.py 2>&1 | tail -20
exit "$rc"
