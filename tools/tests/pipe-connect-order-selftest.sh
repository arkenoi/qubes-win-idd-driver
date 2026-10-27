#!/bin/bash
# a pipe thread cannot run before its client is PUBLISHED, and the one failure path leaks nothing
# run: tools/tests/pipe-connect-order-selftest.sh
# pass: exit 0
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PATCHFILE="$ROOT/patches/windows-utils-pipe-connect-rewrite.patch"
MIRROR="$ROOT/upstream/ro/qubes-windows-utils"
OUT="${CONNORDER_SELFTEST_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/pipe-connect-order-XXXXXX")}"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }
[ -f "$PATCHFILE" ] || { echo "FAIL  $PATCHFILE is missing - nothing ran (missing data fails)"; exit 2; }
[ -d "$MIRROR" ]    || { echo "FAIL  $MIRROR is missing"; exit 2; }

ref=$(command grep -oE 'WINDOWS_UTILS_REF: *[^ ]+' "$ROOT/.github/workflows/build.yml" | head -1 | awk '{print $2}')
mirror_ver=$(tr -d ' \r\n' < "$MIRROR/version" 2>/dev/null)
[ -n "$ref" ] && [ "${ref#v}" = "${mirror_ver#v}" ] \
  && ok "ref_matches_mirror: written against $mirror_ver = WINDOWS_UTILS_REF ($ref)" \
  || bad "ref_matches_mirror: ref='$ref' mirror='$mirror_ver'"

mkdir -p "$OUT/solo" && cp -r "$MIRROR"/. "$OUT/solo/"
( cd "$OUT/solo" && patch -p1 --dry-run -i "$PATCHFILE" >/dev/null 2>&1 ) \
  && ok "applies: dry run succeeds against a pristine mirror" \
  || bad "applies: dry run FAILED against a pristine mirror"

mapfile -t ORDER < <(command grep -oE 'patches\\windows-utils-[a-z-]+\.patch' "$ROOT/.github/workflows/build.yml" \
                     | sed 's/.*windows-utils-//; s/\.patch//')
mkdir -p "$OUT/stack" && cp -r "$MIRROR"/. "$OUT/stack/"
stack_rc=0
for p in "${ORDER[@]}"; do
  ( cd "$OUT/stack" && patch -p1 -i "$ROOT/patches/windows-utils-$p.patch" >>"$OUT/stack.log" 2>&1 ) || stack_rc=1
done
[ "$stack_rc" -eq 0 ] && [ "${#ORDER[@]}" -ge 7 ] \
  && ok "coexists: all ${#ORDER[@]} patches apply in build.yml's own order" \
  || bad "coexists: stack rc=$stack_rc with ${#ORDER[@]} patches - see $OUT/stack.log"

SRC="$OUT/stack/src/pipe-server.c"
PRISTINE="$MIRROR/src/pipe-server.c"
# Comments stripped for every structural assertion: this function's comments name the very calls
# being counted, and a count that includes the explanation is a count of prose.
fnbody(){ awk '/^static DWORD QpsConnectClient\(/{c++} c==2' "$1" | awk 'NR==1,/^\}/' | sed 's@//.*@@'; }
AFTER=$(fnbody "$SRC"); BEFORE=$(fnbody "$PRISTINE")
n(){ printf '%s\n' "$1" | command grep -cE "$2"; }
lineof(){ printf '%s\n' "$1" | command grep -nE "$2" | head -1 | cut -d: -f1; }

# ---- THE ORDERING INVARIANT ---------------------------------------------------------------------
ins_a=$(lineof "$AFTER" 'InsertTailList\(&Server->Clients')
res_a=$(lineof "$AFTER" 'ResumeThread\(client->ReaderThread\)')
cre_a=$(lineof "$AFTER" 'CreateThread\(NULL, 0, QpsReaderThread')
if [ -n "$ins_a" ] && [ -n "$res_a" ] && [ "$ins_a" -lt "$res_a" ]; then
  ok "order: the client is published (line $ins_a) before any thread is resumed (line $res_a)"
else
  bad "order: insert at '$ins_a', resume at '$res_a' - a thread can run before its client is findable"
fi
# In the UNPATCHED source the threads are created BEFORE the insert, with no suspension - that is
# the defect, and this check must see it.
ins_b=$(lineof "$BEFORE" 'InsertTailList\(&Server->Clients')
cre_b=$(lineof "$BEFORE" 'CreateThread\(NULL, 0, QpsReaderThread')
if [ -n "$ins_b" ] && [ -n "$cre_b" ] && [ "$cre_b" -lt "$ins_b" ] && [ "$(n "$BEFORE" 'CREATE_SUSPENDED')" -eq 0 ]; then
  ok "order: UNPATCHED source starts threads (line $cre_b) before the insert (line $ins_b), unsuspended - the check can fail"
else
  bad "order: the mirror does not show the defect any more - re-read the source before trusting this test"
fi
[ "$(n "$AFTER" 'CREATE_SUSPENDED')" -eq 2 ] \
  && ok "order: both threads are created suspended" \
  || bad "order: $(n "$AFTER" 'CREATE_SUSPENDED') suspended creations, expected 2"
[ "$(n "$AFTER" 'ResumeThread\(')" -eq 2 ] \
  && ok "order: both threads are resumed" \
  || bad "order: $(n "$AFTER" 'ResumeThread\(') resumes, expected 2"
# A created-but-never-resumed thread would hang the client silently, so the resumes must be on the
# success path - i.e. after the publish and before the function returns success.
succ_a=$(lineof "$AFTER" 'return ERROR_SUCCESS;')
[ -n "$succ_a" ] && [ "$res_a" -lt "$succ_a" ] \
  && ok "order: the resumes happen before the success return" \
  || bad "order: resume at '$res_a' is not before the success return at '$succ_a'"

# A RESUME THAT FAILS MUST NOT LEAVE A PUBLISHED CLIENT WITH A DEAD PUMP. That is the one new
# failure mode this ordering introduces, and a silent hang is worse to diagnose than a crash - Jev's
# resume_cannot_be_missed sat at 0.62 until it was checked.
[ "$(n "$AFTER" 'ResumeThread\(client->(Reader|Writer)Thread\) == \(DWORD\)-1')" -eq 2 ] \
  && ok "resume: both resumes are checked for failure" \
  || bad "resume: $(n "$AFTER" 'ResumeThread\(client->(Reader|Writer)Thread\) == \(DWORD\)-1') checked, expected 2 - a failed resume would hang the client silently"
res_blk=$(printf '%s\n' "$AFTER" | awk '/ResumeThread\(client->ReaderThread\) == /,/^    }/')
case "$res_blk" in
  *LogError*) ok "resume: a failed resume is reported at ERROR" ;;
  *) bad "resume: a failed resume is not loud" ;;
esac
case "$res_blk" in
  *QpsDisconnectClientInternal*) ok "resume: a failed resume disconnects the published client instead of leaving it half-alive" ;;
  *) bad "resume: a failed resume leaves a published client with no pump" ;;
esac

# ---- THE SERVER LOCK NO LONGER SPANS THE CONSTRUCTION ------------------------------------------
# The old body held the global lock across two mallocs, two CmqCreate calls and two CreateThread
# calls. It should now cover the publish only.
lock_a=$(lineof "$AFTER" 'EnterCriticalSection\(&Server->Lock\)')
[ -n "$lock_a" ] && [ -n "$cre_a" ] && [ "$cre_a" -lt "$lock_a" ] \
  && ok "lock: the server lock is taken after construction (line $lock_a), not across it" \
  || bad "lock: taken at '$lock_a' with thread creation at '$cre_a' - still held across construction"
[ "$(n "$AFTER" 'EnterCriticalSection\(&Server->Lock\)')" -eq 1 ] \
  && ok "lock: taken exactly once" || bad "lock: taken $(n "$AFTER" 'EnterCriticalSection\(&Server->Lock\)') times"
[ "$(n "$AFTER" 'LeaveCriticalSection\(&Server->Lock\)')" -eq 1 ] \
  && ok "lock: released exactly once" || bad "lock: released $(n "$AFTER" 'LeaveCriticalSection\(&Server->Lock\)') times"
# No path may return while holding it: the unwind must sit outside the locked region.
unwind=$(printf '%s\n' "$AFTER" | awk '/^fail:/,0')
[ "$(n "$unwind" 'CriticalSection\(&Server->Lock\)')" -eq 0 ] \
  && ok "lock: the failure path never touches the server lock - it runs unpublished" \
  || bad "lock: the failure path touches the server lock"

# ---- ONE FAILURE PATH, AND IT RELEASES EVERYTHING ----------------------------------------------
bare_after=$(printf '%s\n' "$AFTER" | command grep -A1 'LeaveCriticalSection(&Server->Lock);' | command grep -c 'return ERROR_')
[ "$bare_after" -eq 0 ] \
  && ok "unwind: no failure returns from the middle of a half-built client" \
  || bad "unwind: $bare_after bare returns remain"
[ "$(printf '%s\n' "$BEFORE" | command grep -A1 'LeaveCriticalSection(&Server->Lock);' | command grep -c 'return ERROR_')" -ge 5 ] \
  && ok "unwind: UNPATCHED source has them (the check can fail)" \
  || bad "unwind: the mirror no longer shows the bare returns"
[ "$(n "$AFTER" '^fail:')" -eq 1 ] && ok "unwind: exactly one failure label" || bad "unwind: label count wrong"
[ "$(n "$AFTER" 'goto fail;')" -eq 2 ] \
  && ok "unwind: two failure points, both reaching it" \
  || bad "unwind: $(n "$AFTER" 'goto fail;') goto fail - the rewrite has two"
for res in 'TerminateThread(client->WriterThread, 0);' 'CloseHandle(client->WriterThread);' \
           'TerminateThread(client->ReaderThread, 0);' 'CloseHandle(client->ReaderThread);' \
           'free(writerParam);' 'free(readerParam);' \
           'CmqDestroy(client->WriteBuffer);' 'CmqDestroy(client->ReadBuffer);' \
           'DeleteCriticalSection(&client->Lock);' 'free(client);' \
           'CloseHandle(WritePipe);' 'CloseHandle(ReadPipe);'; do
  [ "$(printf '%s\n' "$unwind" | command grep -cF "$res")" -ge 1 ] \
    && ok "unwind: releases $res" || bad "unwind: never releases $res"
done
# TerminateThread is only ever acceptable on a thread that has not run. Assert it cannot reach a
# resumed one: the unwind is unreachable once the publish has happened.
[ -n "$ins_a" ] && [ "$ins_a" -lt "$(lineof "$AFTER" '^fail:')" ] \
  && ok "unwind: it sits after the publish, so it is only reachable while both threads are suspended" \
  || bad "unwind: cannot establish that it only runs pre-publish"
# The pipes are closed by PARAMETER: client->WritePipe is set early here, but closing the field
# would still be right - what must not happen is closing neither.
[ "$(n "$unwind" 'CloseHandle\(WritePipe\)')" -eq 1 ] \
  && ok "unwind: the inbound pipes are closed, which no other code does on failure" \
  || bad "unwind: the pipes handed in are leaked on failure"
# It must not touch the refcount or the disconnect machinery - that is the server's job, and the
# client was never handed over.
[ "$(n "$unwind" 'QpsReleaseClient|QpsDisconnectClient|RefCount')" -eq 0 ] \
  && ok "unwind: no refcount or disconnect machinery - the client was never published" \
  || bad "unwind: touches refcount/disconnect state for a client that was never published"

# ---- it says so, and BOTH producers apply it ----------------------------------------------------
command grep -q 'nothing was published' "$SRC" && ok "marker: the failure path logs what happened" || bad "marker: no log line on the failure path"
command grep -q 'nothing was published' "$PRISTINE" && bad "marker: present in UNPATCHED source too" || ok "marker: absent before the patch"
for w in "$ROOT/.github/workflows/build.yml" "$ROOT/.github/workflows/qwt-full.yml"; do
  command grep -q 'windows-utils-pipe-connect-rewrite.patch' "$w" \
    && ok "wired: $(basename "$w") applies it" || bad "wired: $(basename "$w") does not apply it"
  command grep -q 'connect-order rewrite did not apply' "$w" \
    && ok "wired: $(basename "$w") fails the build if it does not apply" || bad "wired: $(basename "$w") would pass a failed apply"
  command grep -q 'a thread is resumed before the client is published' "$w" \
    && ok "wired: $(basename "$w") asserts the ordering invariant in CI" || bad "wired: $(basename "$w") does not check the order"
done

echo "pipe-connect-order-selftest: $pass passed, $fail failed  (tree: $OUT)"
[ "$fail" -eq 0 ]
