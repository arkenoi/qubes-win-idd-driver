#!/bin/bash
# a pipe thread cannot run before its client is PUBLISHED, and the one failure path leaks nothing
# run: tools/tests/pipe-connect-order-selftest.sh
# pass: exit 0
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WU="$ROOT/winutils"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }
[ -f "$WU/src/pipe-server.c" ] || { echo "FAIL  $WU/src/pipe-server.c is missing (is the winutils submodule checked out?) - nothing ran (missing data fails)"; exit 2; }

SRC="$WU/src/pipe-server.c"
# Comments stripped for every structural assertion: this function's comments name the very calls
# being counted, and a count that includes the explanation is a count of prose.
fnbody(){ awk '/^static DWORD QpsConnectClient\(/{c++} c==2' "$1" | awk 'NR==1,/^\}/' | sed 's@//.*@@'; }
AFTER=$(fnbody "$SRC")
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

# ---- it says so -----------------------------------------------------------------------------------
command grep -q 'nothing was published' "$SRC" && ok "marker: the failure path logs what happened" || bad "marker: no log line on the failure path"

echo "pipe-connect-order-selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
