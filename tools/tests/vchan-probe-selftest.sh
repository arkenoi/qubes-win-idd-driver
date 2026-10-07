#!/usr/bin/env bash
# vchan-probe-selftest.sh - patches/vchan-quiet-store-probe.patch, checked OFFLINE.
#
# WHAT IT GUARDS. A client that goes away before the wrapper connects wrote FOUR error lines of ours
# per call - measured on win11r-logvol 2026-10-08, eight of the new binary's ten error lines, two
# calls' worth. ONE FAILURE, ONE REPORT: the four become one, and this checks both patches that do
# it, in the two repos the build clones.
#
#   XcStoreRead (the PROBE)   silenced  - libvchan's client init reads the peer's entry under its own
#                                         comment "test if the store entry exists; if not - wait a
#                                         second time" and DISCARDS the status on the next line, but
#                                         XcStoreRead reports every failure at XLL_ERROR from inside
#                                         xencontrol, so we logged an error for a question.
#   XcStoreRead (the RING-REF read)  silenced - the layer above reports the same missing key with the
#                                         path and the status, which is strictly more.
#   libxenvchan_client_init   KEPT at ERROR - the one report, with the path and the status.
#   libvchan_client_init      lowered to DEBUG - it repeated the layer below with less detail (the
#                                         domain it adds is already inside that path).
#
# Nothing is made quieter: the surviving line carries everything the four carried. The level is
# restored immediately in both patches, which checks 3 and 7 assert, because silencing without
# restoring would quieten every later failure on the same handle - the opposite of the point.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PATCHFILE="$ROOT/patches/vchan-quiet-store-probe.patch"
MIRROR="$ROOT/upstream/ro/qubes-core-vchan-xen"
OUT="${VCHANPROBE_SELFTEST_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/vchan-probe-XXXXXX")}"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }
[ -f "$PATCHFILE" ] || { echo "FAIL  $PATCHFILE is missing - nothing ran (missing data fails)"; exit 2; }
[ -d "$MIRROR" ]    || { echo "FAIL  $MIRROR is missing"; exit 2; }

# ---- 1. THE MIRROR IS NOT THE REF CI CLONES, SO THE REF IS WHAT MUST BE CHECKED ----------------
# The local mirror is 4.2.8 while CI pins VCHAN_REF v4.2.7. A patch verified only against the
# mirror would apply here and fail in CI - which is exactly how the windows-utils selftest's first
# check came to exist. The pinned ref's file is fetched if the network allows, and a failure to
# fetch is reported as NOT CHECKED rather than passed.
ref=$(command grep -oE 'VCHAN_REF: *[^ ]+' "$ROOT/.github/workflows/build.yml" | head -1 | awk '{print $2}')
mirror_ver=$(tr -d ' \r\n' < "$MIRROR/version" 2>/dev/null)
echo "      (CI pins $ref; the local mirror is $mirror_ver)"
mkdir -p "$OUT/ref/windows/src"
if gh api "repos/QubesOS/qubes-core-vchan-xen/contents/windows/src/init.c?ref=$ref" -q '.content' 2>/dev/null \
     | base64 -d > "$OUT/ref/windows/src/init.c" && [ -s "$OUT/ref/windows/src/init.c" ]; then
  ( cd "$OUT/ref" && git init -q . 2>/dev/null; git apply --check "$PATCHFILE" ) 2>"$OUT/ref.err"
  if [ $? -eq 0 ]; then
    ok "applies_to_pinned_ref: the patch applies to $ref, which is what CI clones"
  else
    bad "applies_to_pinned_ref: it does NOT apply to $ref: $(head -2 "$OUT/ref.err" | tr '\n' ' ')"
  fi
  # the symbols the patch uses must exist in that ref, not only in the mirror
  if command grep -qF 'g_log_level' "$OUT/ref/windows/src/init.c" \
     && command grep -qF 'XcSetLogLevel' "$OUT/ref/windows/src/init.c"; then
    ok "symbols_in_pinned_ref: g_log_level and XcSetLogLevel are both already used in $ref"
  else
    bad "symbols_in_pinned_ref: the patch calls something $ref does not have"
  fi
else
  bad "applies_to_pinned_ref: could not fetch $ref, so the patch was NOT checked against what CI builds (missing data fails, never a skip)"
fi

# ---- 2. it applies to the local mirror too -----------------------------------------------------
rm -rf "$OUT/clean"; mkdir -p "$OUT/clean"
cp -r "$MIRROR"/. "$OUT/clean/"
( cd "$OUT/clean" && git init -q . 2>/dev/null; git apply "$PATCHFILE" ) 2>"$OUT/apply.err"
if [ $? -eq 0 ]; then ok "applies_to_mirror: the patch also applies to the local $mirror_ver mirror"
else bad "applies_to_mirror: $(head -2 "$OUT/apply.err" | tr '\n' ' ')"; fi
SRC="$OUT/clean/windows/src/init.c"

# ---- 3. the probe is silenced AND the level is put back ----------------------------------------
# Silencing without restoring would quieten every later failure in the same handle - the opposite
# of the point.
if command grep -qF 'XcSetLogLevel(xc_handle, (XENCONTROL_LOG_LEVEL)0)' "$SRC" \
   && command grep -qF 'XcSetLogLevel(xc_handle, g_log_level)' "$SRC"; then
  ok "silenced_and_restored: the probe runs at level 0 and the level is restored immediately after"
else
  bad "silenced_and_restored: the probe is not silenced, or the level is left lowered"
fi
# the restore must come AFTER the read, not before it
# The file ALREADY had an XcSetLogLevel(xc_handle, g_log_level) at :106 before this patch, so the
# restore to look for is the FIRST one AFTER the probe - taking the first in the file matched the
# pre-existing call and read as "the ordering is wrong".
probe_line=$(command grep -n 'entry_present = ' "$SRC" | head -1 | cut -d: -f1)
restore_line=$(command grep -n 'XcSetLogLevel(xc_handle, g_log_level)' "$SRC" | cut -d: -f1 \
               | awk -v p="${probe_line:-0}" '$1 > p { print $1; exit }')
if [ -n "$probe_line" ] && [ -n "$restore_line" ] && [ "$restore_line" -gt "$probe_line" ]; then
  ok "restore_is_after_the_read: the level goes back at line $restore_line, after the probe at $probe_line"
else
  bad "restore_is_after_the_read: probe=$probe_line restore=$restore_line - the ordering is wrong"
fi

# ---- 4. ONE REPORT SURVIVES, AND IT IS THE ONE WITH THE DETAIL -------------------------------
# The duplicate goes to DEBUG; the neighbours that report DIFFERENT failures must be untouched.
if command grep -qF 'Log(XLL_DEBUG, "libxenvchan_client_init(%u, %S) failed - reported above"' "$SRC" \
   && ! command grep -qF 'Log(XLL_ERROR, "libxenvchan_client_init(%u, %S) failed"' "$SRC"; then
  ok "duplicate_is_debug: libvchan stops repeating the failure the layer below already reported"
else
  bad "duplicate_is_debug: the duplicate report is still at ERROR, or the DEBUG replacement is missing"
fi
kept=0
command grep -qF 'Log(XLL_WARNING, "Wait for xenstore (2) failed' "$SRC" && kept=$((kept+1))
command grep -qF 'Log(XLL_ERROR, "adding xenstore watch' "$SRC" && kept=$((kept+1))
command grep -qF 'Log(XLL_ERROR, "CreateEvent(xs watch) failed' "$SRC" && kept=$((kept+1))
if [ "$kept" = 3 ]; then
  ok "other_failures_untouched: the watch-add, the event-create and the second wait all still report"
else
  bad "other_failures_untouched: only $kept of 3 unrelated reports survived - this is not a silencer"
fi
# and exactly ONE read is wrapped in this file
n_zero=$(command grep -cF 'XcSetLogLevel(xc_handle, (XENCONTROL_LOG_LEVEL)0)' "$SRC")
[ "$n_zero" = 1 ] && ok "one_read_only: exactly one read is silenced in libvchan" \
                  || bad "one_read_only: $n_zero reads are silenced in libvchan (want 1)"

# ---- 4b. THE libxenvchan HALF ------------------------------------------------------------------
PVPATCH="$ROOT/patches/libxenvchan-one-report-per-failure.patch"
PVMIRROR="$ROOT/upstream/ro/qubes-vmm-xen-windows-pvdrivers"
pvref=$(command grep -oE 'PVDRIVERS_REF: *[^ ]+' "$ROOT/.github/workflows/build.yml" | head -1 | awk '{print $2}')
if [ ! -f "$PVPATCH" ]; then
  bad "pv_patch_present: $PVPATCH is missing"
else
  mkdir -p "$OUT/pvref/src/libxenvchan"
  if gh api "repos/QubesOS/qubes-vmm-xen-windows-pvdrivers/contents/src/libxenvchan/init.c?ref=$pvref" -q '.content' 2>/dev/null \
       | base64 -d > "$OUT/pvref/src/libxenvchan/init.c" && [ -s "$OUT/pvref/src/libxenvchan/init.c" ]; then
    ( cd "$OUT/pvref" && git init -q . 2>/dev/null; git apply --check "$PVPATCH" ) 2>"$OUT/pvref.err"
    [ $? -eq 0 ] && ok "pv_applies_to_pinned_ref: it applies to PVDRIVERS_REF $pvref, which is what CI clones" \
                 || bad "pv_applies_to_pinned_ref: does NOT apply to $pvref: $(head -2 "$OUT/pvref.err" | tr '\n' ' ')"
  else
    bad "pv_applies_to_pinned_ref: could not fetch $pvref, so it was NOT checked against what CI builds"
  fi
  rm -rf "$OUT/pv"; mkdir -p "$OUT/pv"; cp -r "$PVMIRROR"/. "$OUT/pv/" 2>/dev/null
  ( cd "$OUT/pv" && git init -q . 2>/dev/null; git apply "$PVPATCH" ) 2>/dev/null
  PVSRC="$OUT/pv/src/libxenvchan/init.c"
  if command grep -qF 'XcSetLogLevel(ctrl->xc, (XENCONTROL_LOG_LEVEL)0)' "$PVSRC" \
     && command grep -qF 'XcSetLogLevel(ctrl->xc, log_level)' "$PVSRC" \
     && command grep -qF "failed to read '%S' from store" "$PVSRC"; then
    ok "pv_one_report: the inner xencontrol report is silenced, the level restored, and the detailed line kept"
  else
    bad "pv_one_report: the libxenvchan half is not in place"
  fi
  # the ring-ref read is the ONLY one wrapped - the event-channel read right below it must not be
  n_pv=$(command grep -cF 'XcSetLogLevel(ctrl->xc, (XENCONTROL_LOG_LEVEL)0)' "$PVSRC")
  [ "$n_pv" = 1 ] && ok "pv_one_read_only: exactly one read is silenced in libxenvchan" \
                  || bad "pv_one_read_only: $n_pv reads are silenced in libxenvchan (want 1)"
fi

# ---- 5. THE CHECKS MUST FAIL ON UNPATCHED SOURCE -----------------------------------------------
UN="$MIRROR/windows/src/init.c"
if ! command grep -qF 'XcSetLogLevel(xc_handle, (XENCONTROL_LOG_LEVEL)0)' "$UN" \
   && command grep -qE 'if \(XcStoreRead\(xc_handle, xs_path_watch' "$UN"; then
  ok "seen_to_fail: against UNPATCHED source the marker is absent and the bare probe is present"
else
  bad "seen_to_fail: unpatched source already looks patched - the checks above prove nothing"
fi

# ---- 6. wired in BOTH workflows, with assertions that refuse a no-op --------------------------
for wf in build qwt-full; do
  f="$ROOT/.github/workflows/$wf.yml"
  if command grep -q 'vchan-quiet-store-probe.patch' "$f" \
     && command grep -q 'the probe is not silenced after patch' "$f" \
     && command grep -q 'the probe does not restore the log level after patch' "$f" \
     && command grep -q 'libxenvchan-one-report-per-failure.patch' "$f" \
     && command grep -q 'the inner store report is not silenced after patch' "$f" \
     && command grep -q 'the single remaining report is gone after patch' "$f"; then
    ok "wired_$wf: BOTH patches applied unconditionally, each with silence and restore assertions"
  else
    bad "wired_$wf: not applied, or applied without the marker assertions"
  fi
done

echo
echo "vchan-probe-selftest: $pass passed, $fail failed   (work dir: $OUT)"
[ "$fail" = 0 ] || exit 1
