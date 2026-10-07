#!/usr/bin/env bash
# vchan-probe-selftest.sh - patches/vchan-quiet-store-probe.patch, checked OFFLINE.
#
# WHAT IT GUARDS. A client that goes away before the wrapper connects wrote FOUR error lines of ours
# per call - measured on win11r-logvol 2026-10-08, eight of the new binary's ten error lines, two
# calls' worth. The first of the four is a PROBE: libvchan's client init reads the peer's xenstore
# entry under the comment "test if the store entry exists; if not - wait a second time" and
# DISCARDS the status on the next line, but XcStoreRead reports every failure at XLL_ERROR from
# inside xencontrol. So we logged an error for a question we only wanted the answer to.
#
# The handle's log level belongs to the caller (XcSetLogLevel) and xencontrol emits a message only
# when its level <= the current one (`if (LogLevel > CurrentLogLevel) return;`), so 0 silences that
# one read; it is restored to g_log_level immediately after. NOTHING ELSE IS QUIETENED: the real
# ring-ref read in libxenvchan_client_init still reports with the path and the status, and
# libvchan_client_init still reports the failure. Three of the four lines remain, which is what this
# patch claims - see findings/issues.md for the rest of that class.
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

# ---- 4. NOTHING ELSE WAS QUIETENED -------------------------------------------------------------
# The claim is one line of four. The other reports must still be there, at their own levels.
kept=0
command grep -qF 'Log(XLL_ERROR, "libxenvchan_client_init(%u, %S) failed"' "$SRC" && kept=$((kept+1))
command grep -qF 'Log(XLL_WARNING, "Wait for xenstore (2) failed' "$SRC" && kept=$((kept+1))
command grep -qF 'Log(XLL_ERROR, "adding xenstore watch' "$SRC" && kept=$((kept+1))
if [ "$kept" = 3 ]; then
  ok "nothing_else_quietened: the client-init failure, the watch failure and the second wait all still report"
else
  bad "nothing_else_quietened: only $kept of 3 neighbouring reports survived - this patch is one line, not a silencer"
fi
# and exactly ONE read is wrapped
n_zero=$(command grep -cF 'XcSetLogLevel(xc_handle, (XENCONTROL_LOG_LEVEL)0)' "$SRC")
[ "$n_zero" = 1 ] && ok "one_read_only: exactly one read is silenced" \
                  || bad "one_read_only: $n_zero reads are silenced (want 1)"

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
     && command grep -q 'the probe does not restore the log level after patch' "$f"; then
    ok "wired_$wf: applied unconditionally, with assertions for both the silence and the restore"
  else
    bad "wired_$wf: not applied, or applied without the marker assertions"
  fi
done

echo
echo "vchan-probe-selftest: $pass passed, $fail failed   (work dir: $OUT)"
[ "$fail" = 0 ] || exit 1
