#!/usr/bin/env bash
# Cut a QWT-NG release. THE ONLY WAY TO PUBLISH ONE.
#
# ======================================================================================
# WHY THIS TAKES A CI RUN ID AND NOT A DIRECTORY
# ======================================================================================
# Every release defect this project has had came from a HUMAN CHOOSING WHICH BYTES TO ACT
# ON, and then something else being true of those bytes than was believed:
#
#   2026-09-09  ~/rel/rel-assets was staged from an EARLIER package and still sat there when
#               the corrected one passed. Publishing it would have shipped the release
#               WITHOUT the fix the whole acceptance run existed to validate. Nothing in the
#               label could have revealed it: package_version is <release>+agent.<agentsha>,
#               the fix was driver-repo-only, so both directories read 4.3.21+agent.a1956929c319.
#   2026-09-09  A chain script verified $HOME/rel/pkg-rr while acceptance ran on pkg-fin, and
#               printed PASS lines for a package that was not under test.
#   2026-09-09  The v4.3.21 tag landed on HEAD (37383a58) while the package was built from
#               3245867d - so the published release could not be checked against its source.
#   2026-09-06  4.3.19 was published on a PARTIAL check because a firefight ate the session.
#
# Adding more checks to `cut-release.sh <dir>` cannot fix this: the argument itself is the
# defect. A directory is an invitation to name the wrong one, and a check that runs on the
# named directory is as wrong as the name.
#
# So: THERE IS NO DIRECTORY ARGUMENT. This script is given a release-package RUN ID, and it
# fetches the artifacts itself, verifies what it fetched, publishes exactly those bytes, and
# then re-downloads the PUBLISHED assets and verifies them again. The operator chooses which
# BUILD to release - a thing CI can corroborate - and never which files to upload.
#
# Every gate below FAILS CLOSED: a missing file, an unresolvable sha, a failed gh call and an
# absent acceptance record are all failures, never warnings, never skips.
#
# Usage:
#     tools/cut-release.sh --run <release-package-run-id> [--draft]
#     tools/cut-release.sh --run <id> --acceptance-override "<reason>"   (see OVERRIDE)
#
# ======================================================================================
# OVERRIDE
# ======================================================================================
# --acceptance-override "<reason>" publishes a package whose acceptance record is NOT CLEAN.
# Added 2026-10-25 on the owner's explicit instruction ("cut the override release on yesterdays
# binary package. we will supercede it with current campaign, but i want to publish it now"),
# because until then the only documented escape was `--i-am-rebuilding-history`, which this header
# described and the argument parser had never implemented - it died on "unknown argument".
#
# What it relaxes: ONE predicate, the campaign verdict. What it does NOT relax - every one of these
# still fails closed under the override, because each guards a property of the BYTES rather than a
# judgement about them:
#     the run is a green release-package run; the manifest binds to it three ways; the tag lands on
#     the build commit; verify-release-package reports PACKAGE COMPLETE; the gui-agent carries no
#     fault injector; an acceptance record for THIS ISO sha EXISTS; the published assets are
#     re-downloaded and byte-compared.
# A MISSING record is still fatal. The override ships a release whose failures are KNOWN and named;
# it cannot be used to ship one nothing was ever measured on, because then there is nothing to name.
#
# It is not quiet. The reason is required and non-empty, the refused verdict and the checker's own
# output are printed, and both are prepended to the PUBLISHED release notes - so a reader who finds
# this release later learns from the release itself that it was cut on a failed record, and what
# failed, without having to find this script.
# ======================================================================================
set -uo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo "[cut] $*"; }

RUN=""
DRAFT=""
OVERRIDE=""
COVOVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --run)   RUN="${2:-}"; shift 2 ;;
    --draft) DRAFT="--draft"; shift ;;
    --acceptance-override)
      OVERRIDE="${2:-}"
      # A reason that is absent, empty or a shrug is not a reason. The whole value of this flag is
      # that the release says WHY, so an unusable reason fails here rather than reaching the notes.
      [ -n "$OVERRIDE" ] || die "--acceptance-override requires a reason in the next argument.
  It is printed and published: say what failed and why shipping anyway is the right call."
      [ "${#OVERRIDE}" -ge 24 ] || die "--acceptance-override reason is ${#OVERRIDE} characters.
  It goes into the published release notes - name the failure and the decision, not a word."
      shift 2 ;;
    --coverage-override)
      COVOVERRIDE="${2:-}"
      [ -n "$COVOVERRIDE" ] || die "--coverage-override requires a reason in the next argument.
  It is printed and published: name the suites the gate did not cover and why shipping anyway is
  the right call."
      [ "${#COVOVERRIDE}" -ge 24 ] || die "--coverage-override reason is ${#COVOVERRIDE} characters.
  It goes into the published release notes - name the uncovered suites and the decision, not a word."
      shift 2 ;;
    # The old header advertised --i-am-rebuilding-history and the parser never had it, so it died
    # on "unknown argument" (found 2026-10-25 while looking for exactly this escape hatch). Name it
    # rather than let the next reader of an old doc hit the same wall.
    --i-am-rebuilding-history)
      die "--i-am-rebuilding-history was documented but never implemented, and is now gone.
  The acceptance verdict is the only thing that was ever overridable:
      tools/cut-release.sh --run <id> --acceptance-override \"<reason>\"" ;;
    -h|--help) awk 'NR>1 && /^set -uo pipefail/{exit} NR>1' "$0"; exit 0 ;;
    *)
      # The old interface was `cut-release.sh <artifacts-dir>`. Refuse it loudly rather than
      # guessing, and say why - a stale directory is the exact defect this rewrite removes.
      [ -d "$1" ] && die "this script no longer takes a directory ($1).
  A directory argument is how a STALE package nearly shipped as v4.3.21: the label could not
  distinguish it from the correct one. Pass the release-package run that BUILT the package:
      tools/cut-release.sh --run <run-id>
  Find it with:  gh run list --workflow release-package --limit 5"
      die "unknown argument: $1 (expected --run <run-id> [--draft] [--acceptance-override \"<reason>\"] [--coverage-override \"<reason>\"])" ;;
  esac
done
[ -n "$RUN" ] || die "no --run <release-package-run-id> given. gh run list --workflow release-package --limit 5"
[[ "$RUN" =~ ^[0-9]+$ ]] || die "--run must be a numeric run id, got '$RUN'"

command -v gh >/dev/null   || die "gh is required"
command -v jq >/dev/null   || JQ=0
git rev-parse --show-toplevel >/dev/null 2>&1 || die "run from inside the repo"
cd "$(git rev-parse --show-toplevel)" || die "cannot cd to the repo root"

# ---------------------------------------------------------------- gate: the run is a real, green
# release-package run. A failed or in-progress run has no publishable artifacts, and a run of a
# DIFFERENT workflow (build.yml makes an overlay, not an installer) would produce a package that
# looks similar and is not the thing.
RUNJSON="$(gh run view "$RUN" --json databaseId,name,headSha,status,conclusion,workflowName,number 2>/dev/null)" \
  || die "cannot read run $RUN (wrong id, or gh is not authenticated)"
r_name="$(printf '%s' "$RUNJSON" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("name",""))')"
r_status="$(printf '%s' "$RUNJSON" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("status",""))')"
r_concl="$(printf '%s' "$RUNJSON" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("conclusion") or "")')"
r_sha="$(printf '%s' "$RUNJSON" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("headSha",""))')"
r_num="$(printf '%s' "$RUNJSON" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("number",""))')"
[ "$r_name" = "release-package" ] || die "run $RUN is '$r_name', not release-package - only that workflow builds a publishable installer"
[ "$r_status" = "completed" ]     || die "run $RUN is $r_status, not completed"
[ "$r_concl" = "success" ]        || die "run $RUN concluded '$r_concl' - refusing to publish artifacts from a run that did not succeed"
say "run $RUN: release-package, success, head ${r_sha:0:12}, run_number $r_num"

# ---------------------------------------------------------------- fetch, into a FRESH directory
# Named for the run, and wiped first: a directory reused across runs is how the stale-package
# class starts. Real disk, never /tmp - that is a 1 GB tmpfs here and the ISO alone is 32 MB.
WORK="$HOME/rel/cut-$RUN"
rm -rf "$WORK" || die "cannot clear $WORK"
mkdir -p "$WORK/assets" || die "cannot create $WORK"
for a in qwt-improved-setup qwt-improved-iso qwt-ng-dom0-rpm; do
  gh run download "$RUN" -n "$a" -D "$WORK/$a" >/dev/null 2>&1 \
    || die "run $RUN has no artifact '$a' - it did not produce a complete release"
done
cp -a "$WORK/qwt-improved-setup/." "$WORK/assets/"          || die "cannot stage the setup tree"
cp -f "$WORK/qwt-improved-iso"/*.iso "$WORK/assets/"        || die "run $RUN produced no ISO"
cp -f "$WORK/qwt-ng-dom0-rpm"/*.rpm  "$WORK/assets/"        || die "run $RUN produced no dom0 RPM"
say "fetched artifacts -> $WORK/assets"

MF="$WORK/assets/MANIFEST.json"
[ -f "$MF" ] || die "no MANIFEST.json in the fetched setup tree"

read_mf() { python3 -c "
import json,sys
m=json.load(open('$MF'))
cur=m
for k in '$1'.split('.'):
    cur=(cur or {}).get(k) if isinstance(cur,dict) else None
print('' if cur is None else cur)"; }

PKGVER="$(read_mf package_version)"
RELVER="$(read_mf release_version)"
BUILDREV="$(read_mf build_rev)"
BUILDSHA="$(read_mf source.driver_repo_commit)"
MFRUNID="$(read_mf ci.run_id)"
MFRUNNO="$(read_mf ci.run_number)"

# ---------------------------------------------------------------- gate: the package IS from this run
# Three independent bindings. Any one of them failing means the artifacts and the run disagree,
# which is the stale-package class arriving by a different door.
[ -n "$MFRUNID" ] || die "MANIFEST records no ci.run_id - cannot bind these artifacts to a build"
[ "$MFRUNID" = "$RUN" ] || die "MANIFEST says it was built by run $MFRUNID, not $RUN"
[ "$BUILDSHA" = "$r_sha" ] || die "MANIFEST build commit ${BUILDSHA:0:12} != run head ${r_sha:0:12}"
[ -n "$BUILDREV" ] || die "MANIFEST declares no build_rev - every per-component version gate would be unprovable (see packaging/version-stamp/README.md)"
[ "$BUILDREV" = "$MFRUNNO" ] || die "MANIFEST build_rev ($BUILDREV) != ci.run_number ($MFRUNNO) - the stamp does not match the build"
say "provenance: package is from run $RUN, commit ${BUILDSHA:0:12}, build_rev $BUILDREV"

# ---------------------------------------------------------------- version invariants (unchanged)
# These predate the rewrite and are the reason two releases can never share an MSI ProductVersion.
VER="$(tr -d ' \t\r\n' < agent/version)"
[[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "agent/version must be MAJOR.MINOR.PATCH, got '$VER'"
git fetch --tags --quiet origin || true
LAST="$(git tag -l 'v*-agent*' | sed -nE 's/^v([0-9]+\.[0-9]+\.[0-9]+)-agent.*/\1/p' | sort -V | tail -1)"
if [ -n "$LAST" ]; then
  printf '%s\n' "$LAST" | grep -qx "$VER" && die "version $VER was already released (tag exists). Bump agent/version's third field."
  HIGHEST="$(printf '%s\n%s\n' "$LAST" "$VER" | sort -V | tail -1)"
  [ "$HIGHEST" = "$VER" ] || die "agent/version ($VER) is NOT greater than the last release ($LAST)."
fi
[ "${PKGVER%%+*}" = "$VER" ] || die "artifact package_version (${PKGVER%%+*}) != agent/version ($VER)"
[ -z "$RELVER" ] || [ "$RELVER" = "$VER" ] || die "MANIFEST release_version ($RELVER) != agent/version ($VER)"

# THE AGENT SHA COMES FROM THE PACKAGE, NEVER FROM THE WORKING TREE.
# This read `git -C agent rev-parse HEAD` until 2026-10-25, which is correct only when the cut
# happens at the very tree state that built the package. Measured that day: the tree was at agent
# e921819 while the package being cut was built from 93a1b27, so the tag would have published
# YESTERDAY's bytes under TODAY's agent sha - the v4.3.21 mislabel (tag 37383a58 / package
# 3245867d) arriving in the tag NAME instead of the tag target, and silently claiming the tag name
# the newer build needs. Two independent sources, which must agree: the submodule gitlink recorded
# at the build commit, and the +agent.<sha> suffix the builder baked into package_version.
AGENTSHA="$(git rev-parse --short=7 "${BUILDSHA}:agent" 2>/dev/null)" \
  || die "cannot read the agent gitlink at ${BUILDSHA:0:12} - the tag name is unprovable without it.
  git submodule update --init agent, or fetch the commit, then retry."
PKGAGENT="${PKGVER#*+agent.}"
[ "$PKGAGENT" != "$PKGVER" ] \
  || die "package_version '$PKGVER' carries no +agent.<sha> suffix - cannot corroborate the agent sha"
case "$PKGAGENT" in
  "$AGENTSHA"*) : ;;
  *) die "agent sha disagreement: the gitlink at ${BUILDSHA:0:12} says $AGENTSHA, the package label
  says $PKGAGENT. One of them does not describe these bytes - do not publish either name." ;;
esac
say "agent sha: $AGENTSHA (gitlink at the build commit, corroborated by package_version)"
TAG="v${VER}-agent${AGENTSHA}"
git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null 2>&1 && die "tag ${TAG} already exists"

# The tag must land on the BUILD commit, and that commit must be reachable, or the published
# release cannot be checked against the source that produced it (v4.3.21: tag 37383a58, package
# 3245867d). An ancestor test is NOT a substitute - a stale package's commit is an ancestor of the
# tag commit exactly as the right one is.
git cat-file -e "${BUILDSHA}^{commit}" 2>/dev/null || die "build commit ${BUILDSHA:0:12} not in this repo - fetch it"
git merge-base --is-ancestor "$BUILDSHA" HEAD 2>/dev/null \
  || die "build commit ${BUILDSHA:0:12} is not an ancestor of HEAD - these assets were built from a commit this branch does not contain"

# ---------------------------------------------------------------- gate: the package verifies
# Run on the FETCHED bytes, not on a directory someone named. Failure here is fatal: an unverified
# package is exactly what shipped as 4.3.18 (broker missing, inert on every clean install, invisible
# because the guest still rendered).
# VERIFY THE PURE SETUP TREE, NOT THE ASSEMBLED ASSET DIRECTORY. assets/ is the tree PLUS the ISO
# and RPM staged in for publishing, and MANIFEST.files legitimately does not list those - so
# verifying assets/ fails MANIFEST_FILES with FILE_UNLISTED on our own staging. Measured on the
# first real run of this script, 2026-09-09: the gate was right and the layout was wrong.
say "verifying the fetched package"
VOUT="$WORK/verify.log"
# --commit is the BUILD commit, not HEAD. HEAD moves between the build and the cut (release notes,
# a doc fix), and the verifier rightly refuses to assume they are the same - it failed exactly that
# way here. Passing $BUILDSHA weakens nothing: it was proven equal to the run head above, from the
# run's own metadata, before this point.
if ! bash tools/verify-release-package.sh --tree "$WORK/qwt-improved-setup" --commit "$BUILDSHA" >"$VOUT" 2>&1; then
  tail -40 "$VOUT" >&2
  die "verify-release-package FAILED on the fetched package (full log: $VOUT)"
fi
grep -aF 'RESULT: PACKAGE COMPLETE' "$VOUT" >/dev/null \
  || { tail -40 "$VOUT" >&2; die "verifier did not report PACKAGE COMPLETE (log: $VOUT)"; }
say "package verified"

# ---------------------------------------------------------------- gate: acceptance ran on THESE bytes
# Looked up BY THE ISO's OWN SHA256, so it cannot be pointed at a record from another run - the
# same reason there is no directory argument. Written by tools/record-acceptance.sh at the end of a
# campaign. Owner rule (memory: full-acceptance-before-release-is-a-GATE): an explicit
# "run full acceptance then release" is a HARD GATE, and 4.3.19 was published on a partial check.
# ---------------------------------------------------------------- gate: NOT a fault-injection build
# release-package.yml can now be dispatched with fault_injection=true, because two of the eighteen
# required gate suites need an INSTALLED injector build and the only artifact that carried one was
# not installable (2026-10-09). That variant must never be published: its gui-agent can be made to
# break itself on purpose from the registry.
# THE CHECK IS ON THE BYTES, not on a label. No manifest records the flag, and a manifest field
# could be stale or wrong anyway; the injector's own marker string cannot be. It is emitted by code
# that only exists when QGA_FAULT_INJECTION=1, and it is UTF-16 in the PE, so an ASCII grep would
# report a clean binary either way - this reads both encodings (measured: that exact mistake made a
# provenance check pass on a build that did not carry its change).
for _a in "$WORK/assets"/qwt-improved-setup/reference/gui-agent.exe \
          "$WORK/assets"/qwt-improved-setup/bin/gui-agent.exe; do
    [ -f "$_a" ] || continue
    if python3 - "$_a" <<'FIPY'
import sys
b = open(sys.argv[1], 'rb').read()
m = b'QGA-FAULT-INJECTION:on'
sys.exit(0 if (b.count(m) + b.count(m.decode().encode('utf-16-le'))) else 1)
FIPY
    then
        die "REFUSING: this package's gui-agent.exe carries the FAULT INJECTOR
  ($_a has the QGA-FAULT-INJECTION:on marker).
  That build can be made to break itself from the registry and must never be published. It exists
  so the failproof gate suites can run against an installed injector - dispatch release-package
  WITHOUT fault_injection for anything that is meant to ship."
    fi
done

ISO="$(find "$WORK/assets" -maxdepth 1 -name '*.iso' | head -1)"
[ -n "$ISO" ] || die "no ISO among the fetched assets"
ISOSHA="$(sha256sum "$ISO" | cut -d' ' -f1)"
REC="scratchpad/acceptance-records/${ISOSHA}.json"
[ -f "$REC" ] || die "NO ACCEPTANCE RECORD for this ISO (sha ${ISOSHA:0:16}).
  Full acceptance must have RUN, on THESE bytes, before this package can be published.
  Run the campaign against $ISO, then:
      tools/record-acceptance.sh --iso $ISO --campaign <campaign-out-dir>
  There is deliberately no flag to skip this, and --acceptance-override does NOT cover it: that
  flag ships a release whose failures are NAMED, and an absent record names nothing."
# The check itself lives in tools/acceptance-record-check.py (testable offline: tools/tests/acceptance-record-selftest.sh); it requires
# every campaign cell AND the feature tests - a record that lacks any of them is PARTIAL (2026-10-02: rz30 recorded CLEAN with both
# feature tests never run).
RECOUT="$WORK/acceptance-check.log"
if python3 tools/acceptance-record-check.py "$REC" "$ISOSHA" "$VER" >"$RECOUT" 2>&1; then
  cat "$RECOUT"
  OVERRIDE=""   # a clean record needs no override; never let the flag imply one was needed
else
  cat "$RECOUT" >&2
  [ -n "$OVERRIDE" ] || die "acceptance record ${ISOSHA:0:16} does not pass (above).
  Fix the failures and re-run acceptance, or, if the decision is to publish anyway:
      tools/cut-release.sh --run $RUN --acceptance-override \"<why this ships regardless>\""
  RECVERDICT="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("verdict","<none>"))' "$REC" 2>/dev/null || echo '<unreadable>')"
  cat >&2 <<OVR

  ============================= ACCEPTANCE OVERRIDE =============================
  The acceptance record for these bytes is $RECVERDICT, not CLEAN, and this release
  is being published anyway, deliberately.
      reason: $OVERRIDE
      record: $REC
  Every other gate remains enforced. The refusal above and this reason are being
  prepended to the published release notes.
  ===============================================================================

OVR
fi

# ---------------------------------------------------------------- gate: the COVERAGE RECEIPT
# WHY THIS IS HERE (2026-10-30), AND IT IS NOT THAT THE GATE WAS MISSING.
# tools/hooks/release-cut-gate.sh already enforces exactly this rule. It is a PreToolUse hook that
# matches the COMMAND TEXT for `gh release create`, `git tag v...` or a push of a v-tag, and
# refuses unless a receipt for HEAD satisfies tools/gate-scope.py check. It works: handed the
# literal text it blocks, with the required range and the command to produce the receipt.
#
# It cannot see THIS script. The sanctioned way to publish is `bash tools/cut-release.sh --run N`,
# and the `gh release create` it runs is inside the file, not in the command the hook is shown. So
# the one path a release is actually cut by is the one path the gate is blind to. Measured on
# 2026-10-30: v4.3.39-agentf0dd19f published through this script at a HEAD with NO receipt at all,
# while the gate was armed and would have refused the same act written out by hand. A text matcher
# on the caller cannot gate a thing the callee does.
#
# So the check moves to where the act is. This runs in-process, next to the acceptance record,
# before a single asset is uploaded, and no wrapper can hide it. The hook stays - it still catches
# a hand-cut tag, which this file knows nothing about. Belt and braces, each covering the other's
# blind spot.
#
# The per-ISO acceptance record above does NOT cover this: it says every CELL of the campaign ran
# clean and says nothing about which SUITES the diff required. On the night of 4.3.39 the receipt
# stood at 16 of 19 while the record was legitimately CLEAN. Two gates that disagree are one gate,
# and the 4.3.35 ledger row "claims full=true" on 13 of 19 is what that costs.
#
# The receipt is keyed by the commit the gate RAN at, which is not always the commit the package
# was built from - the harness moves HEAD after a build with changes that touch no product path.
# A receipt taken at a DESCENDANT of the build commit is accepted, but ONLY as a list of which
# suites ran. What those suites must COVER is computed here, over this package's own range, and
# passed to gate-scope explicitly.
#
# THAT EXPLICIT RANGE IS THE WHOLE POINT, and the first draft of this block got it wrong. Without
# it, `gate-scope.py check` falls back to the range recorded INSIDE the receipt - lastTag..D, not
# lastTag..BUILD. The tempting argument is that a descendant's diff contains the package's, so its
# required set is a superset. It is not: these are NET diffs from a common base, so a commit
# between BUILD and D that REVERTS a product file removes that file from lastTag..D while it is
# still in lastTag..BUILD. The receipt would then be checked against a SMALLER requirement than
# the package actually has, and a release could pass on a gate that never asked for the suite its
# own diff needed. Computing the requirement here, from BUILDSHA, cannot drift that way.
#
# What the descendant still costs: those suites ran against D's code, not BUILD's. The commits in
# between are printed rather than waved through, so a reader can see what the gate was actually
# exercised over. A receipt from an unrelated commit, or none at all, is not a pass - missing data
# fails, exactly as it does for the acceptance record, and for the same reason: an absent receipt
# names nothing, so there is nothing for --coverage-override to be an override OF.
COVOUT="$WORK/coverage-check.log"
COVREC="scratchpad/gate-coverage-${BUILDSHA:0:12}.json"
if [ ! -f "$COVREC" ]; then
  COVREC=""
  for _c in $(ls -t scratchpad/gate-coverage-*.json 2>/dev/null); do
    _sha="$(basename "$_c" .json)"; _sha="${_sha#gate-coverage-}"
    git rev-parse -q --verify "${_sha}^{commit}" >/dev/null 2>&1 || continue
    git merge-base --is-ancestor "$BUILDSHA" "$_sha" 2>/dev/null || continue
    git merge-base --is-ancestor "$_sha" HEAD 2>/dev/null || continue
    COVREC="$_c"; break
  done
fi
[ -n "$COVREC" ] || die "NO COVERAGE RECEIPT for the build commit ${BUILDSHA:0:12}.
  tools/gate-scope.py decides which suites THIS diff requires, and nothing here recorded that they
  ran. Produce one with the committed gate, then cut:
      tools/gate-remainder.sh --run $RUN --vm10 <win10> --vm11 <win11> --os11 <label>
  There is no flag to skip this. --coverage-override relaxes a receipt that is SHORT and names what
  it missed; an absent receipt names nothing."
# The range, computed the same way tools/hooks/release-cut-gate.sh computes it: the newest release
# tag that is an ancestor of the build commit, to the build commit. With no such tag the whole
# history is the diff, which maps to the full set - the right answer for a first release.
COVBASE="$(git describe --tags --abbrev=0 --match 'v[0-9]*' "${BUILDSHA}^" 2>/dev/null)" \
  || COVBASE="$(git rev-list --max-parents=0 "$BUILDSHA" | head -1)"
[ -n "$COVBASE" ] || die "cannot determine the range base for ${BUILDSHA:0:12} - refusing to check
  coverage against a range this script had to guess."
COVRANGE="${COVBASE}..${BUILDSHA}"
say "coverage receipt: $COVREC"
say "coverage range:   $COVRANGE (the PACKAGE's diff, not the receipt's own)"
_rsha="$(basename "$COVREC" .json)"; _rsha="${_rsha#gate-coverage-}"
if [ "${_rsha}" != "${BUILDSHA:0:${#_rsha}}" ]; then
  say "  note: the receipt was taken at ${_rsha}, which is ahead of the build commit. The suites ran"
  say "        over these extra commit(s), and the requirement below is still computed from ${BUILDSHA:0:12}:"
  git --no-pager log --oneline "${BUILDSHA}..${_rsha}" 2>/dev/null | sed 's/^/          /'
fi
if python3 tools/gate-scope.py check "$COVREC" "$COVRANGE" >"$COVOUT" 2>&1; then
  cat "$COVOUT"
  COVOVERRIDE=""   # a satisfied receipt needs no override; never let the flag imply one was needed
else
  COVRC=$?
  cat "$COVOUT" >&2
  # rc=2 is gate-scope saying it COULD NOT DECIDE - a missing map, an unreadable ledger, a bad
  # range. Its own header says that is never "nothing required", so it is not something an override
  # can be an override OF: there is no named gap to accept. Only a decided refusal (rc=1) is.
  [ "$COVRC" != 2 ] || die "tools/gate-scope.py could not DECIDE what this diff requires (rc=2, above).
  That is missing data, not a short receipt, so --coverage-override does not cover it - there is no
  named gap to accept. Fix what it names (usually mgmt/gate-scope.json or the ledger) and re-run."
  [ -n "$COVOVERRIDE" ] || die "the coverage receipt does not satisfy the gate (above, rc=$COVRC).
  Run the suites it names and record them, or, if the decision is to publish anyway:
      tools/cut-release.sh --run $RUN --coverage-override \"<why this ships under-covered>\""
  cat >&2 <<COV

  ============================== COVERAGE OVERRIDE ==============================
  The coverage receipt for ${BUILDSHA:0:12} does not cover every suite this diff
  requires, and this release is being published anyway, deliberately.
      reason:  $COVOVERRIDE
      receipt: $COVREC
  Every other gate remains enforced. The refusal above and this reason are being
  prepended to the published release notes.
  ===============================================================================

COV
fi

# ---------------------------------------------------------------- notes
NOTES_FILE="docs/RELEASE-NOTES-${VER}.md"
[ -f "$NOTES_FILE" ] || die "no $NOTES_FILE - a release whose notes are a generated one-liner tells the reader nothing about what changed or what was verified"

# Under an override the PUBLISHED notes lead with the override, carrying the checker's own refusal
# text. The committed notes file is NOT edited: a release-specific fact about one cut does not
# belong in the tree, and touching the tree here would also move HEAD under a running campaign.
PUBNOTES="$NOTES_FILE"
if [ -n "$OVERRIDE" ] || [ -n "$COVOVERRIDE" ]; then
  PUBNOTES="$WORK/RELEASE-NOTES-published.md"
  : > "$PUBNOTES" || die "cannot write $PUBNOTES"
fi
if [ -n "$OVERRIDE" ]; then
  {
    echo "> ## Published on a FAILED acceptance record"
    echo ">"
    echo "> This release was cut deliberately with \`--acceptance-override\`. The acceptance"
    echo "> record for these exact bytes (ISO sha \`${ISOSHA}\`) reads **${RECVERDICT}**, not CLEAN."
    echo ">"
    echo "> **Reason given at the cut:** ${OVERRIDE}"
    echo ">"
    echo "> The acceptance checker refused it as follows:"
    echo ">"
    sed -e 's/^/>     /' "$RECOUT"
    echo ">"
    echo "> Everything else was enforced as normal: the package is from green release-package run"
    echo "> ${RUN}, built at \`${BUILDSHA}\`, it passes \`verify-release-package\` as PACKAGE"
    echo "> COMPLETE, it carries no fault injector, and the published assets were re-downloaded and"
    echo "> byte-compared after upload."
    echo ""
    echo "---"
    echo ""
  } >> "$PUBNOTES" || die "cannot write $PUBNOTES"
  say "published notes lead with the acceptance-override banner ($PUBNOTES)"
fi
if [ -n "$COVOVERRIDE" ]; then
  {
    echo "> ## Published UNDER-COVERED: the gate did not run every required suite"
    echo ">"
    echo "> This release was cut deliberately with \`--coverage-override\`. tools/gate-scope.py"
    echo "> computes which suites this diff requires; the receipt for \`${BUILDSHA:0:12}\` does not"
    echo "> cover all of them."
    echo ">"
    echo "> **Reason given at the cut:** ${COVOVERRIDE}"
    echo ">"
    echo "> The scope checker refused it as follows:"
    echo ">"
    sed -e 's/^/>     /' "$COVOUT"
    echo ">"
    echo "> This says nothing about the cells that DID run: acceptance for these exact bytes is"
    echo "> recorded separately and was enforced above."
    echo ""
    echo "---"
    echo ""
  } >> "$PUBNOTES" || die "cannot write $PUBNOTES"
  say "published notes carry the coverage-override banner ($PUBNOTES)"
fi
if [ "$PUBNOTES" != "$NOTES_FILE" ]; then
  cat "$NOTES_FILE" >> "$PUBNOTES" || die "cannot write $PUBNOTES"
fi

mapfile -t ASSETS < <(find "$WORK/assets" -maxdepth 1 -type f \( -name '*.iso' -o -name '*.rpm' -o -name '*.tar.gz' -o -name '*.exe' -o -name 'SHA256SUMS.txt' \) | sort)
[ "${#ASSETS[@]}" -gt 0 ] || die "no publishable assets in $WORK/assets"

say "publishing ${TAG} at ${BUILDSHA:0:12} (${#ASSETS[@]} assets)"
for a in "${ASSETS[@]}"; do say "  $(basename "$a")  $(sha256sum "$a" | cut -c1-16)"; done

gh release create "$TAG" $DRAFT \
  --target "$BUILDSHA" \
  --title "QWT-NG ${VER} (agent ${AGENTSHA})" \
  --notes-file "$PUBNOTES" \
  "${ASSETS[@]}" || die "gh release create failed"

# ---------------------------------------------------------------- gate: what is PUBLISHED is what was verified
# The last gap in the chain: everything above proves things about local bytes. Re-download what
# GitHub now serves and prove it is the same. An upload can truncate; a tag can be re-pointed; a
# release can be edited. Verified 2026-09-09 by hand for v4.3.21 - now it is not by hand.
say "re-downloading the published assets to confirm they match"
PUB="$WORK/published"
rm -rf "$PUB"; mkdir -p "$PUB"
gh release download "$TAG" -D "$PUB" >/dev/null 2>&1 || die "PUBLISHED, but could not download the release back to check it: $TAG"
bad=0
for a in "${ASSETS[@]}"; do
  b="$PUB/$(basename "$a")"
  if [ ! -f "$b" ]; then echo "ERROR: published release is missing $(basename "$a")" >&2; bad=1; continue; fi
  l="$(sha256sum "$a" | cut -d' ' -f1)"; p="$(sha256sum "$b" | cut -d' ' -f1)"
  if [ "$l" != "$p" ]; then echo "ERROR: $(basename "$a") differs after upload (local ${l:0:16}, published ${p:0:16})" >&2; bad=1; fi
done
[ "$bad" -eq 0 ] || die "PUBLISHED ASSETS DO NOT MATCH what was verified - delete the release ($TAG) and investigate"
say "published assets byte-match the verified ones"
say "Published ${TAG}  (tag -> ${BUILDSHA:0:12}, acceptance ${ISOSHA:0:16}, verify log $VOUT)"
[ -z "$OVERRIDE" ] || say "Published UNDER ACCEPTANCE OVERRIDE (record ${RECVERDICT}): $OVERRIDE"
