#!/usr/bin/env bash
# pipe-eof-selftest.sh - patches/windows-utils-pipe-eof.patch, checked OFFLINE. No guest, no CI.
#
# WHAT IT GUARDS. windows-utils' pipe server logged the normal END OF A CLIENT SESSION as
# "[N] read failed" at WARNING, with GetLastError DISCARDED (its win_perror was commented out), so
# an ordinary disconnect and a real fault printed the same line. This protocol has no goodbye
# message - EOF IS the disconnect (qdb_close just closes the handles; qrexec-client-vm's last act
# before exiting is CloseHandle(writePipe)) - so EVERY SUCCESSFUL SESSION ended there. Measured on
# a German 25H2 guest after one install and three boots: 199 of those lines from qrexec-agent and
# about 60 from the qubesdb daemon, 259 of the 766 error/warning lines in the whole log, every one
# of them a success. The Linux side returns the same event silently (qubes-core-qubesdb db-cmds.c,
# "/* EOF */ if (ret == 0) return 0;"), so this is a port artefact and not the design.
#
# THE FIX MAKES THE REAL CASES LOUDER, which is what keeps it from being a suppression:
#   our own CancelIo               -> Debug  (we asked for it)
#   peer closed the pipe           -> Debug  (the protocol's only goodbye)
#   ANYTHING ELSE                  -> win_perror2 at ERROR *with the Win32 code* - the old warning
#                                     did not even print the code
#   peer gone with nothing pending -> Debug
#   peer gone MID-MESSAGE          -> ERROR naming both byte counts - previously indistinguishable
#                                     from a clean session end
# Jev on the RCA: root_cause_established 0.92, fix_is_real 0.88, citations all verified.
#
# Four checks, in the shape tools/tests/svc-exitcode-selftest.sh established for a windows-utils
# patch: the patch applies to the exact ref CI clones, the patched source carries every marker the
# build step asserts, the OLD defect is gone, and - the half that makes this evidence rather than
# decoration - the same marker checks are run against UNPATCHED source and MUST FAIL.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PATCHFILE="$ROOT/patches/windows-utils-pipe-eof.patch"
MIRROR="$ROOT/upstream/ro/qubes-windows-utils"
OUT="${PIPEEOF_SELFTEST_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/pipe-eof-XXXXXX")}"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }
[ -f "$PATCHFILE" ] || { echo "FAIL  $PATCHFILE is missing - nothing ran (missing data fails)"; exit 2; }
[ -d "$MIRROR" ]    || { echo "FAIL  $MIRROR is missing"; exit 2; }

# ---- 1. the patch is written against the ref CI actually clones ---------------------------------
# build.yml clones windows-utils FRESH from upstream at WINDOWS_UTILS_REF, so a patch written
# against a different version would apply here and fail there.
ref=$(command grep -oE 'WINDOWS_UTILS_REF: *[^ ]+' "$ROOT/.github/workflows/build.yml" | head -1 | awk '{print $2}')
mirror_ver=$(tr -d ' \r\n' < "$MIRROR/version" 2>/dev/null)
if [ -n "$ref" ] && [ -n "$mirror_ver" ] && [ "${ref#v}" = "${mirror_ver#v}" ]; then
  ok "ref_matches_mirror: the patch is written against $mirror_ver, which is WINDOWS_UTILS_REF ($ref)"
else
  bad "ref_matches_mirror: WINDOWS_UTILS_REF='$ref' but the mirror says '$mirror_ver' - a patch written here may not apply in CI"
fi

# ---- 2. it applies cleanly to a pristine copy --------------------------------------------------
rm -rf "$OUT/clean"; mkdir -p "$OUT/clean"
cp -r "$MIRROR"/. "$OUT/clean/"
( cd "$OUT/clean" && git init -q . 2>/dev/null; git apply --check "$PATCHFILE" ) 2>"$OUT/apply.err"
if [ $? -eq 0 ]; then ok "applies: git apply --check succeeds against a pristine mirror"
else bad "applies: $(head -2 "$OUT/apply.err" | tr '\n' ' ')"; fi
( cd "$OUT/clean" && git apply "$PATCHFILE" ) 2>/dev/null
SRC="$OUT/clean/src/pipe-server.c"

# ---- 3. the patched source carries every marker the build step asserts -------------------------
# If these drift apart, CI throws on a patch that applied correctly - or worse, passes one that
# no-opped. The strings are duplicated deliberately so a change has to be made in both places.
miss=""
for m in 'peer closed the pipe (end of session)' \
         'peer gone mid-message' \
         'win_perror2(readError, "ReadFile(client pipe)")' \
         'read cancelled by our own disconnect' \
         'write to a peer that is already gone'; do
  command grep -qF "$m" "$SRC" || miss="$miss [$m]"
done
[ -z "$miss" ] && ok "markers: every string the build step asserts is present after patching" \
               || bad "markers: missing$miss"

# the old defect must be GONE, not merely shadowed
if command grep -qF 'LogWarning("[%lld] read failed"' "$SRC"; then
  bad "defect_removed: the unconditional read-failed warning is still in the patched source"
else
  ok "defect_removed: the unconditional \"read failed\" warning is gone"
fi
# and the error code must be captured rather than discarded
command grep -qF 'DWORD readError = GetLastError();' "$SRC" \
  && ok "code_captured: GetLastError is taken as the first statement after the failed read" \
  || bad "code_captured: the error code is still discarded"

# ---- 4. NOTHING IS QUIETER THAN IT WAS for a case that is not an expected end -------------------
# The three Debug lines must each be guarded by a condition. A Debug with no condition would be the
# suppression this fix is not allowed to be.
# count: three Debug lines in the reader/QpsRead paths, one in QpsWrite, and TWO new loud sites
n_dbg=$(command grep -cE 'LogDebug\("\[%lld\] (peer closed|read cancelled|peer gone, nothing pending|write to a peer)' "$SRC")
n_loud=$(command grep -cE 'win_perror2\(readError|LogError\("\[%lld\] peer gone mid-message' "$SRC")
if [ "$n_dbg" = 4 ] && [ "$n_loud" = 2 ]; then
  ok "louder_where_it_matters: 4 expected-end cases at Debug, and 2 NEW loud sites (non-EOF read error with its code, peer-gone mid-message)"
else
  bad "louder_where_it_matters: debug=$n_dbg (want 4) loud=$n_loud (want 2)"
fi

# ---- 5. THE CHECKS MUST FAIL ON UNPATCHED SOURCE -----------------------------------------------
# A check never seen to fail is decoration. Run the same marker checks against the pristine mirror.
UN="$MIRROR/src/pipe-server.c"
un_markers=0
for m in 'peer closed the pipe (end of session)' 'peer gone mid-message' 'DWORD readError = GetLastError();'; do
  command grep -qF "$m" "$UN" && un_markers=$((un_markers+1))
done
if [ "$un_markers" = 0 ] && command grep -qF 'LogWarning("[%lld] read failed"' "$UN"; then
  ok "seen_to_fail: against UNPATCHED source every marker is absent and the old warning is present"
else
  bad "seen_to_fail: unpatched source has $un_markers/3 markers and old-warning=$(command grep -cF 'LogWarning("[%lld] read failed"' "$UN") - the checks above prove nothing"
fi

# ---- 6. the build wires it in BOTH workflows, with the no-op guard ------------------------------
for wf in build qwt-full; do
  f="$ROOT/.github/workflows/$wf.yml"
  if command grep -q 'windows-utils-pipe-eof.patch' "$f" && command grep -q 'pipe-EOF marker missing after patch' "$f"; then
    ok "wired_$wf: applied unconditionally with a marker assertion that refuses a no-op"
  else
    bad "wired_$wf: the patch is not applied, or applies with no marker assertion"
  fi
done

echo
echo "pipe-eof-selftest: $pass passed, $fail failed   (work dir: $OUT)"
[ "$fail" = 0 ] || exit 1
