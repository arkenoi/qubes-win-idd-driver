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
#     tools/cut-release.sh --run <id> --i-am-rebuilding-history   (see FORCE, bottom)
# ======================================================================================
set -uo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
say() { echo "[cut] $*"; }

RUN=""
DRAFT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --run)   RUN="${2:-}"; shift 2 ;;
    --draft) DRAFT="--draft"; shift ;;
    -h|--help) sed -n '2,36p' "$0"; exit 0 ;;
    *)
      # The old interface was `cut-release.sh <artifacts-dir>`. Refuse it loudly rather than
      # guessing, and say why - a stale directory is the exact defect this rewrite removes.
      [ -d "$1" ] && die "this script no longer takes a directory ($1).
  A directory argument is how a STALE package nearly shipped as v4.3.21: the label could not
  distinguish it from the correct one. Pass the release-package run that BUILT the package:
      tools/cut-release.sh --run <run-id>
  Find it with:  gh run list --workflow release-package --limit 5"
      die "unknown argument: $1 (expected --run <run-id> [--draft])" ;;
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

AGENTSHA="$(git -C agent rev-parse --short=7 HEAD)"
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
say "verifying the fetched package"
VOUT="$WORK/verify.log"
if ! bash tools/verify-release-package.sh --tree "$WORK/assets" >"$VOUT" 2>&1; then
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
ISO="$(find "$WORK/assets" -maxdepth 1 -name '*.iso' | head -1)"
[ -n "$ISO" ] || die "no ISO among the fetched assets"
ISOSHA="$(sha256sum "$ISO" | cut -d' ' -f1)"
REC="scratchpad/acceptance-records/${ISOSHA}.json"
[ -f "$REC" ] || die "NO ACCEPTANCE RECORD for this ISO (sha ${ISOSHA:0:16}).
  Full acceptance must have RUN, on THESE bytes, before this package can be published.
  Run the campaign against $ISO, then:
      tools/record-acceptance.sh --iso $ISO --campaign <campaign-out-dir>
  There is deliberately no flag to skip this."
python3 - "$REC" "$ISOSHA" "$VER" <<'PY' || exit 1
import json,sys
rec=json.load(open(sys.argv[1]))
iso,ver=sys.argv[2],sys.argv[3]
def bad(m): print(f"ERROR: acceptance record: {m}",file=sys.stderr); sys.exit(1)
if rec.get("iso_sha256")!=iso: bad("records a different ISO than the one being published")
if rec.get("release_version")!=ver: bad(f"records release {rec.get('release_version')}, publishing {ver}")
if rec.get("verdict")!="CLEAN": bad(f"verdict is {rec.get('verdict')!r}, not CLEAN")
if int(rec.get("cell_groups_failed",1))!=0: bad(f"{rec.get('cell_groups_failed')} cell-group(s) had failures")
cells=rec.get("cells") or []
required={"win11-clean","win10-clean","win11-upgrade","win11-reinstall","win11-appvm","win10-appvm"}
missing=required-set(cells)
if missing: bad("PARTIAL MATRIX - these cells did not run: "+", ".join(sorted(missing)))
print(f"[cut] acceptance: {rec.get('cell_groups_clean')} cell-groups clean, cells={len(cells)}, recorded {rec.get('recorded_utc')}")
PY

# ---------------------------------------------------------------- notes
NOTES_FILE="docs/RELEASE-NOTES-${VER}.md"
[ -f "$NOTES_FILE" ] || die "no $NOTES_FILE - a release whose notes are a generated one-liner tells the reader nothing about what changed or what was verified"

mapfile -t ASSETS < <(find "$WORK/assets" -maxdepth 1 -type f \( -name '*.iso' -o -name '*.rpm' -o -name '*.tar.gz' -o -name '*.exe' -o -name 'SHA256SUMS.txt' \) | sort)
[ "${#ASSETS[@]}" -gt 0 ] || die "no publishable assets in $WORK/assets"

say "publishing ${TAG} at ${BUILDSHA:0:12} (${#ASSETS[@]} assets)"
for a in "${ASSETS[@]}"; do say "  $(basename "$a")  $(sha256sum "$a" | cut -c1-16)"; done

gh release create "$TAG" $DRAFT \
  --target "$BUILDSHA" \
  --title "QWT-NG ${VER} (agent ${AGENTSHA})" \
  --notes-file "$NOTES_FILE" \
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
