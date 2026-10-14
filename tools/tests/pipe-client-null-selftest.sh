#!/bin/bash
# pipe-client-null-selftest.sh - patches/windows-utils-pipe-client-null.patch, checked OFFLINE.
# No guest, no CI.
#
# THE DEFECT. windows-utils' QpsConnectClient starts a reader thread and a writer thread and
# returns. Each thread's FIRST statement was a dereference of QpsGetClient's result:
#
#     PPIPE_CLIENT client = QpsGetClient(server, param->ClientId);
#     HANDLE pipe = client->WritePipe;          // <- NULL when the id is not in the client list
#
# Every other function in pipe-server.c answers that race with ERROR_NOT_CONNECTED. These two
# answered it with an access violation, and an unhandled AV in a service kills the service.
#
# MEASURED, not inferred (QREXECAGENTAV, Win10 acceptance cell 2026-10-14, qrexec-agent-20261014.log):
#   150653.055 [3960-I] QpsConnectClient: [2] (000001D9CB4B6A30) connected (1 total)
#   150653.117 [6752-W] QpsDisconnectClientInternal: [2] not connected
#   150653.171 [6768-E] ErrUEF: Unhandled exception c0000005 at 00007FFFF52E54A8, flags: 0
#   150653.220 [2396-E] PipeClientThread: QpsRead(magic) failed with error 0x8ca
#   ... Parameter 0: 0 (a READ), Parameter 1: 0x18 (the address)
# 0x18 is WritePipe's offset in PIPE_CLIENT (LIST_ENTRY 16 + LONGLONG Id 8), so the faulting line is
# the writer thread's. The watchdog recorded the consequence: "DEATH #1 NEW System/7031: The Qubes
# RPC agent service stopped unexpectedly". 0x8ca is ERROR_NOT_CONNECTED - the HANDLED form of the
# same race, reaching a client call in the same 50 ms.
#
# Four checks in the shape tools/tests/pipe-eof-selftest.sh established, plus the half that makes
# this evidence rather than decoration: every marker check is ALSO run against UNPATCHED source and
# MUST fail there.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PATCHFILE="$ROOT/patches/windows-utils-pipe-client-null.patch"
MIRROR="$ROOT/upstream/ro/qubes-windows-utils"
OUT="${PIPENULL_SELFTEST_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/pipe-client-null-XXXXXX")}"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }
[ -f "$PATCHFILE" ] || { echo "FAIL  $PATCHFILE is missing - nothing ran (missing data fails)"; exit 2; }
[ -d "$MIRROR" ]    || { echo "FAIL  $MIRROR is missing"; exit 2; }

# ---- 1. written against the ref CI actually clones ---------------------------------------------
ref=$(command grep -oE 'WINDOWS_UTILS_REF: *[^ ]+' "$ROOT/.github/workflows/build.yml" | head -1 | awk '{print $2}')
mirror_ver=$(tr -d ' \r\n' < "$MIRROR/version" 2>/dev/null)
if [ -n "$ref" ] && [ -n "$mirror_ver" ] && [ "${ref#v}" = "${mirror_ver#v}" ]; then
  ok "ref_matches_mirror: written against $mirror_ver, which is WINDOWS_UTILS_REF ($ref)"
else
  bad "ref_matches_mirror: WINDOWS_UTILS_REF='$ref' but the mirror says '$mirror_ver'"
fi

# ---- 2. applies to a pristine copy, and alongside every other patch in CI ORDER ----------------
# `patch`, not `git apply`: this runs inside a scratch directory that may sit under another git
# worktree, and git then refuses with a path error about an unrelated repo.
mkdir -p "$OUT/solo" && cp -r "$MIRROR"/. "$OUT/solo/"
if ( cd "$OUT/solo" && patch -p1 --dry-run -i "$PATCHFILE" >/dev/null 2>&1 ); then
  ok "applies: dry run succeeds against a pristine mirror"
else
  bad "applies: dry run FAILED against a pristine mirror"
fi

# The order is read OUT OF build.yml, so a reordering there cannot leave this test asserting a
# stack CI no longer applies.
mapfile -t ORDER < <(command grep -oE 'patches\\windows-utils-[a-z-]+\.patch' "$ROOT/.github/workflows/build.yml" \
                     | sed 's/.*windows-utils-//; s/\.patch//')
mkdir -p "$OUT/stack" && cp -r "$MIRROR"/. "$OUT/stack/"
stack_rc=0; applied=0
for p in "${ORDER[@]}"; do
  ( cd "$OUT/stack" && patch -p1 -i "$ROOT/patches/windows-utils-$p.patch" >>"$OUT/stack.log" 2>&1 ) || stack_rc=1
  applied=$((applied+1))
done
if [ "$stack_rc" -eq 0 ] && [ "$applied" -ge 6 ]; then
  ok "coexists: all $applied windows-utils patches apply in build.yml's own order"
else
  bad "coexists: the stack failed (rc=$stack_rc, applied=$applied) - see $OUT/stack.log"
fi

SRC="$OUT/stack/src/pipe-server.c"
PRISTINE="$MIRROR/src/pipe-server.c"

# ---- 3. the patched source carries every marker the build step asserts -------------------------
# If these drift apart, CI throws on a patch that applied correctly - or passes one that did nothing.
marker(){ # <label> <pattern>
  if command grep -qE "$2" "$SRC"; then ok "marker: $1"; else bad "marker: $1 is MISSING from the patched source"; fi
  # the same check against UNPATCHED source must NOT find it
  if command grep -qE "$2" "$PRISTINE"; then bad "marker: $1 is present in UNPATCHED source too - it proves nothing"; else ok "marker: $1 absent before the patch"; fi
}
marker "reader guard"  'not in the client list; reader thread exits'
marker "writer guard"  'not in the client list; writer thread exits'
marker "release guard" 'NOTHING TO RELEASE IF THE CLIENT IS ALREADY GONE'

# ---- 4. the DEFECT is gone, and was really there before ----------------------------------------
# The defect's exact shape: the lookup, then a dereference on the next line, with nothing between.
defect_re='QpsGetClient\(server, param->ClientId\);'
# -E, not BRE: in a BRE `\(` is a GROUP, so this pattern matched nothing and BOTH counts came
# back 0 - the "defect gone" check passed vacuously and only the must-fail-on-unpatched half of
# this test exposed it. That is precisely what that half is for.
n_bad_after=$(command grep -E -A1 "$defect_re" "$SRC" | command grep -c 'HANDLE pipe = client->')
n_bad_before=$(command grep -E -A1 "$defect_re" "$PRISTINE" | command grep -c 'HANDLE pipe = client->')
[ "$n_bad_after" -eq 0 ] \
  && ok "defect: no thread entry dereferences the client on the line after the lookup" \
  || bad "defect: $n_bad_after thread entry/entries still dereference the client immediately"
[ "$n_bad_before" -eq 2 ] \
  && ok "defect: UNPATCHED source has it in BOTH thread entries (the check can fail)" \
  || bad "defect: expected 2 unguarded entries in the mirror, found $n_bad_before - the shape changed, re-read the source"

# ---- 4b. THE SIBLING SITE, which the first draft of this patch left unguarded ------------------
# Jev, on that draft: sibling_sites_left_unguarded leaned one_or_more_left. It was right.
# QpsReleaseClient decrements Client->RefCount, and the PUBLIC QpsDisconnectClient hands it the
# result of QpsGetClientRaw - NULL for a client that has just been unlinked. RefCount is at offset
# 0x78 and InterlockedDecrement WRITES through the pointer, so that is a distinct crash of the same
# class; a fix guarding only the two thread entries would have been a repeat waiting to happen.
rel_after=$(awk '/^static void QpsReleaseClient/,/^}/' "$SRC" | command grep -c 'if (!Client)')
rel_before=$(awk '/^static void QpsReleaseClient/,/^}/' "$PRISTINE" | command grep -c 'if (!Client)')
[ "$rel_after" -ge 1 ] \
  && ok "sibling: QpsReleaseClient checks the client before decrementing its refcount" \
  || bad "sibling: QpsReleaseClient still decrements through an unchecked pointer"
[ "$rel_before" -eq 0 ] \
  && ok "sibling: UNPATCHED QpsReleaseClient has no check (the check can fail)" \
  || bad "sibling: the mirror already checks - re-read the source, this test is asserting nothing"
# And the guard must come BEFORE the decrement, not merely exist somewhere in the function.
# COMPARE THE LINE NUMBERS. The first attempt grepped for a literal '1:' prefix, which is the
# stream position of the match, not its rank - it can never be 1 here, so the check failed on a
# correct patch.
# COMMENTS STRIPPED FIRST. The guard's own comment contains the word InterlockedDecrement, so the
# comparison below matched the EXPLANATION and placed the write before the check - the same trap as
# a scripted edit landing inside the comment describing it, and the fourth time today in some form.
rel_body=$(awk '/^static void QpsReleaseClient/,/^}/' "$SRC" | sed 's@//.*@@')
ln_check=$(printf '%s\n' "$rel_body" | command grep -nE 'if \(!Client\)' | head -1 | cut -d: -f1)
ln_dec=$(printf '%s\n' "$rel_body" | command grep -nE 'InterlockedDecrement' | head -1 | cut -d: -f1)
if [ -n "$ln_check" ] && [ -n "$ln_dec" ] && [ "$ln_check" -lt "$ln_dec" ]; then
  ok "sibling: the check (line $ln_check) precedes the decrement (line $ln_dec)"
else
  bad "sibling: check at '$ln_check', decrement at '$ln_dec' - the guard does not precede the write"
fi

# ---- 5. the guard's own behaviour --------------------------------------------------------------
# A NULL client must not be handed to the release/disconnect helpers, which dereference it.
guard_body(){ awk "/WINAPI Qps${1}Thread/,/HANDLE pipe =/" "$SRC"; }
for t in Reader Writer; do
  body=$(guard_body "$t")
  case "$body" in
    *"if (!client)"*) ok "guard($t): checks the lookup before using it" ;;
    *) bad "guard($t): no NULL check between the lookup and the dereference" ;;
  esac
  case "$body" in
    *"free(param);"*) ok "guard($t): frees its thread parameter on the early exit" ;;
    *) bad "guard($t): leaks param on the early exit" ;;
  esac
  # QpsReleaseClient(NULL)/QpsDisconnectClientInternal would dereference what we just found NULL.
  if printf '%s' "$body" | command grep -qE 'QpsReleaseClient|QpsDisconnectClientInternal'; then
    bad "guard($t): hands the NULL client to a helper that dereferences it"
  else
    ok "guard($t): does not pass the NULL client on"
  fi
done

# ---- 6. CI actually applies it ------------------------------------------------------------------
if command grep -q 'windows-utils-pipe-client-null.patch' "$ROOT/.github/workflows/build.yml"; then
  ok "wired: build.yml applies the patch"
else
  bad "wired: build.yml never applies the patch - it would ship unfixed"
fi
if command grep -q 'pipe-client NULL patch did not apply' "$ROOT/.github/workflows/build.yml"; then
  ok "wired: the build step FAILS if the patch does not apply"
else
  bad "wired: a failed apply would pass silently"
fi

echo "pipe-client-null-selftest: $pass passed, $fail failed  (tree: $OUT)"
[ "$fail" -eq 0 ]
