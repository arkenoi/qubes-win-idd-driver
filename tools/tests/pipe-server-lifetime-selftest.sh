#!/bin/bash
# pipe-server-lifetime-selftest.sh - patches/windows-utils-pipe-server-lifetime.patch, OFFLINE.
# No guest, no CI.
#
# THE DEFECT. QpsDestroy ended with
#
#     DeleteCriticalSection(&Server->Lock);
#     ZeroMemory(Server, sizeof(PIPE_SERVER));
#     free(Server);
#
# while callers can still legally reach that pointer, because the per-client threads that use it
# belong to the CALLER and nothing joins them. The next call enters a deleted critical section in
# freed memory.
#
# MEASURED, not inferred (QDBSTOPUAF, Win10 acceptance cell WIN10-reinstall of campaign
# rel-40243956400-r2, 2026-10-26, qubesdb-daemon ver 4.3.1.0 pid 3488 - four lines, one clock):
#   092152.485 [3788-I] mainloop: service stopped, exiting
#   092153.517 [3788-I] QpsDisconnectClientInternal: [9] (000001C9A2CCEDB0) disconnecting, WriterExiting 0, ReaderExiting 0
#   092153.533 [4624-W] pipe_thread_client: QpsRead from client 9 failed: 109
#   092153.535 [4624-E] ErrUEF: Unhandled exception c0000005 at 00007FF8CCD3FAAD, flags: 0
# qubes-core-qubesdb daemon/db-daemon.c waits for the ACCEPT thread only, then calls QpsDestroy and
# nulls its pointer; its per-client threads are created with CreateThread + an immediate CloseHandle.
# Such a thread returns from QpsRead with ERROR_BROKEN_PIPE (the 109) and its next statement is
# QpsDisconnectClient(d->pipe_server, id). The cell FAILED the acceptance sweep on that one line
# (error_lines_undeclared 1, signatures_unclassified 1, P1 0).
#
# WHY THE FIX IS IN THIS DLL AND NOT IN THE CALLER: qubesdb-daemon.exe is deliberately not built by
# this fork (wave 3, boot-critical) while windows-utils.dll is, and the stock exe runs this file out
# of that DLL - proven by a line that is ABSENT from the capture, see the "runs our copy" check below.
#
# The shape follows tools/tests/pipe-client-null-selftest.sh, including the half that makes this
# evidence rather than decoration: every marker is ALSO checked against UNPATCHED source and MUST
# be absent there.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PATCHFILE="$ROOT/patches/windows-utils-pipe-server-lifetime.patch"
MIRROR="$ROOT/upstream/ro/qubes-windows-utils"
OUT="${PSLIFE_SELFTEST_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/pipe-server-lifetime-XXXXXX")}"
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
# `patch`, not `git apply`: this runs in a scratch dir that may sit under another git worktree.
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
[ -f "$SRC" ] || { echo "FAIL  the stacked source is missing - nothing below ran"; exit 2; }

# ---- 3. the patched source carries every marker the build step asserts -------------------------
marker(){ # <label> <pattern>
  if command grep -qE "$2" "$SRC"; then ok "marker: $1"; else bad "marker: $1 is MISSING from the patched source"; fi
  if command grep -qE "$2" "$PRISTINE"; then bad "marker: $1 is present in UNPATCHED source too - it proves nothing"; else ok "marker: $1 absent before the patch"; fi
}
marker "retain record"   'THE SERVER OBJECT IS DELIBERATELY RETAINED'
marker "destroy receipt" 'QPSDESTROYED server object retained'
marker "funnel guard"    'no client list to search'

# ---- 4. the DEFECT is gone from QpsDestroy, and was really there before ------------------------
# Scoped to the function body, not the file: free() and DeleteCriticalSection are legitimate
# elsewhere (QpsReleaseClient frees a CLIENT and deletes the CLIENT's lock, which stays correct).
destroy_body(){ awk '/^void QpsDestroy\(/,/^}/' "$1" | sed 's@//.*@@'; }
for site in 'free(Server)' 'DeleteCriticalSection(&Server->Lock)' 'ZeroMemory(Server'; do
  n_after=$(destroy_body "$SRC"      | command grep -cF "$site")
  n_before=$(destroy_body "$PRISTINE" | command grep -cF "$site")
  [ "$n_after" -eq 0 ] \
    && ok "defect: QpsDestroy no longer does $site" \
    || bad "defect: QpsDestroy still does $site ($n_after site(s)) - a caller's pointer is still invalidated"
  [ "$n_before" -eq 1 ] \
    && ok "defect: UNPATCHED QpsDestroy does $site (the check can fail)" \
    || bad "defect: expected 1 '$site' in the mirror's QpsDestroy, found $n_before - the shape changed, re-read the source"
done

# The replacement must actually mark the server, and must NOT take the lock to do it.
db=$(destroy_body "$SRC")
case "$db" in
  *"InterlockedExchange((LONG *)&Server->Destroyed, TRUE)"*) ok "destroy: publishes the flag with a barrier" ;;
  *) bad "destroy: never sets Destroyed - the funnel guard below can never fire" ;;
esac
# NO LOCK AROUND THE FLAG. The first draft took &Server->Lock to set it, which is a wait this
# function cannot afford: two TerminateThread calls can orphan that lock while a destroy runs - the
# one in QpsDisconnectClientInternal ("killing it", its own comment already warning it may do nasty
# things) and the caller's own on the accept thread after a 1000 ms wait. A destroy that HANGS at
# service stop would be worse than the crash this patch removes, so the trailing lock must stay
# gone. Measured by position: nothing after the disconnect loop may enter that lock.
after_loop=$(printf '%s\n' "$db" | sed -n '/QpsDisconnectClientInternal(Server, clientIds\[clientCount\]/,$p')
if printf '%s\n' "$after_loop" | command grep -qF 'EnterCriticalSection(&Server->Lock)'; then
  bad "destroy: the tail of QpsDestroy takes the server lock - an orphaned lock turns the fix into a hang"
else
  ok "destroy: nothing after the disconnect loop takes the server lock"
fi
# And the struct has to declare it, or none of the above compiles.
if awk '/^typedef struct _PIPE_SERVER/,/} \*PIPE_SERVER/' "$SRC" | command grep -qE '^ *BOOL Destroyed;'; then
  ok "struct: PIPE_SERVER declares Destroyed"
else
  bad "struct: PIPE_SERVER has no Destroyed field"
fi

# ---- 5. THE GUARD IS IN THE ONE FUNNEL, AND PRECEDES THE LOCK ---------------------------------
# The whole fix rests on this: every function that takes a client id reaches the client list
# through QpsGetClientRaw. A guard placed after the EnterCriticalSection would enter a lock in
# memory the caller may have already seen freed - which is the crash itself.
raw_body=$(awk '/^static PPIPE_CLIENT QpsGetClientRaw\(/,/^}/' "$SRC" | sed 's@//.*@@')
g_check=$(printf '%s\n' "$raw_body" | command grep -nE 'if \(!Server \|\| Server->Destroyed\)' | head -1 | cut -d: -f1)
g_lock=$(printf '%s\n' "$raw_body"  | command grep -nF 'EnterCriticalSection(&Server->Lock)'    | head -1 | cut -d: -f1)
if [ -n "$g_check" ] && [ -n "$g_lock" ] && [ "$g_check" -lt "$g_lock" ]; then
  ok "funnel: the guard (line $g_check) precedes EnterCriticalSection (line $g_lock)"
else
  bad "funnel: guard at '$g_check', lock at '$g_lock' - the guard does not precede the lock"
fi
if printf '%s\n' "$raw_body" | command grep -qE 'return NULL;'; then
  ok "funnel: the guard returns NULL, which every caller already handles"
else
  bad "funnel: the guard does not return NULL"
fi
# NULL as well as destroyed: the shipped caller nulls its pointer right after the destroy.
case "$raw_body" in
  *'!Server'*) ok "funnel: a NULL server is checked too, not only a destroyed one" ;;
  *) bad "funnel: only the destroyed case is checked - a NULL pointer still faults" ;;
esac

# ---- 5b. EVERY PATH REALLY DOES GO THROUGH THAT FUNNEL ----------------------------------------
# The predicate IS the property: if some public function reached Server->Clients itself, or used a
# lookup result without checking it, the single guard above would not cover it.
# A SET, NOT A COUNT: a threshold goes stale on the first unrelated edit and says nothing about
# which function is unguarded. These four are the whole legitimate list, each for its own reason -
# QpsGetClientRaw IS the funnel; QpsConnectClient publishes a client while the server is alive and
# is unreachable from a caller that has destroyed it; QpsReleaseClient takes the server lock to free
# a client's data; QpsDestroy walks the list to disconnect everyone. Any other name here is a path
# the single guard does not cover, and the test names it.
reach=$(awk '
  /^[A-Za-z_].*\(/ || /^static [A-Za-z_].*\(/ { fn=$0; sub(/\(.*/,"",fn); n=split(fn,a," "); fn=a[n] }
  /Server->Clients|EnterCriticalSection\(&Server->Lock\)/ { print fn }
' "$SRC" | sort -u | tr '\n' ' ')
expected="QpsConnectClient QpsDestroy QpsGetClientRaw QpsReleaseClient "
if [ "$reach" = "$expected" ]; then
  ok "paths: the client list is touched directly only by [$reach] - every other path goes through the funnel"
else
  bad "paths: functions touching the client list are [$reach], declared [$expected] - audit the difference"
fi
for fn in QpsRead QpsWrite QpsGetReadBufferSize QpsSetClientData QpsGetClientData; do
  body=$(awk "/^(DWORD|PVOID) $fn\\(/,/^}/" "$SRC")
  if printf '%s' "$body" | command grep -qF 'QpsGetClient(Server, ClientId)' \
     && printf '%s' "$body" | command grep -qF 'if (!client)'; then
    ok "paths: $fn goes through the funnel and handles its NULL"
  else
    bad "paths: $fn either bypasses the funnel or does not handle a NULL lookup"
  fi
done
# AND THE SET OF ENTRY POINTS IS READ FROM THE HEADER, not typed here: the fix rests on the
# sentence "every public entry point is covered", and a hand-written list makes that sentence true
# by construction. Each exported Qps* that takes a live PIPE_SERVER must either reach the client
# list through the funnel or carry the guard itself. QpsCreate takes an OUT parameter and QpsConnect
# takes no server, so both are exempt - stated, not silently skipped.
mapfile -t EXPORTED < <(command grep -A3 'WINDOWSUTILS_API' "$MIRROR/include/pipe-server.h" \
                        | command grep -oE '^(DWORD|void|PVOID) Qps[A-Za-z]+' | awk '{print $2}' | sort -u)
[ "${#EXPORTED[@]}" -ge 8 ] \
  && ok "entry points: ${#EXPORTED[@]} exported from the header ($(printf '%s ' "${EXPORTED[@]}"))" \
  || bad "entry points: only ${#EXPORTED[@]} found in the header - the derivation broke, not the code"
for fn in "${EXPORTED[@]}"; do
  case "$fn" in QpsCreate|QpsConnect) continue ;; esac
  # ORDER, not presence. QpsDestroy contains a funnel call AND dereferences Server->Lock before it,
  # so "contains the funnel" passes it for the wrong reason - what makes it safe is its own
  # `if (!Server) return` as its first statement. So the predicate is: the first of {guard, funnel
  # call, Server-> dereference} must not be the dereference. Comments stripped first.
  body=$(awk "/^(DWORD|void|PVOID) $fn\\(/,/^}/" "$SRC" | sed 's@//.*@@')
  ln_g=$(printf '%s\n' "$body" | command grep -nE 'if \(!Server \|\| Server->Destroyed\)|if \(!Server\)'      | head -1 | cut -d: -f1)
  ln_f=$(printf '%s\n' "$body" | command grep -nE 'QpsGetClient\(|QpsGetClientRaw\(|QpsDisconnectClientInternal\(' | head -1 | cut -d: -f1)
  ln_d=$(printf '%s\n' "$body" | command grep -nE 'Server->'                                                      | head -1 | cut -d: -f1)
  first=$(printf '%s\n%s\n%s\n' "${ln_g:-9999}" "${ln_f:-9999}" "${ln_d:-9999}" | sort -n | head -1)
  # A TIE COUNTS AS THE GUARD: `if (!Server || Server->Destroyed)` IS a Server-> dereference, on
  # the same line as the check that makes it safe - the `!Server` test short-circuits before it.
  if [ "${ln_d:-9999}" = "9999" ] || [ "$first" != "${ln_d:-9999}" ] || [ "${ln_g:-x}" = "$first" ]; then
    what="funnel"; [ -n "$ln_g" ] && [ "${ln_g}" = "$first" ] && what="its own guard"
    ok "entry points: $fn reaches $what (line $first) before any Server-> dereference (${ln_d:-none})"
  else
    bad "entry points: $fn dereferences Server-> at line $ln_d, before any guard (${ln_g:-none}) or funnel call (${ln_f:-none}) - a late call faults there"
  fi
done

# AND THE SAME PREDICATE MUST FAIL ON UNPATCHED SOURCE, or it is decoration: pristine QpsMainLoop
# reads Server->PipeName with no guard anywhere above it.
pb=$(awk '/^DWORD QpsMainLoop\(/,/^}/' "$PRISTINE" | sed 's@//.*@@')
p_g=$(printf '%s\n' "$pb" | command grep -nE 'if \(!Server \|\| Server->Destroyed\)|if \(!Server\)' | head -1 | cut -d: -f1)
p_d=$(printf '%s\n' "$pb" | command grep -nE 'Server->' | head -1 | cut -d: -f1)
if [ -z "$p_g" ] && [ -n "$p_d" ]; then
  ok "entry points: UNPATCHED QpsMainLoop dereferences Server-> at line $p_d with no guard (the check can fail)"
else
  bad "entry points: the mirror's QpsMainLoop already guards (guard '$p_g', deref '$p_d') - this leg is asserting nothing"
fi

dci=$(awk '/^static void QpsDisconnectClientInternal\(/,/^}/' "$SRC")
if printf '%s' "$dci" | command grep -qF 'QpsGetClient(Server, ClientId)' \
   && printf '%s' "$dci" | command grep -qF 'if (!client)'; then
  ok "paths: QpsDisconnectClientInternal - the crashing call's own target - goes through the funnel"
else
  bad "paths: QpsDisconnectClientInternal does not go through the funnel"
fi

# ---- 6. THE STOCK DAEMON RUNS OUR COPY ---------------------------------------------------------
# This is why a windows-utils patch is a fix at all. Pristine QpsDisconnectClientInternal logs BOTH
# "disconnecting, WriterExiting .." and "disconnected (%lld total)" at LogInfo;
# windows-utils-percall-mechanics-debug.patch demotes the second to LogDebug. The 2026-10-26
# capture holds 61 of the first and zero of the second, with no DEBUG line in the file - so the
# code that wrote them is the patched copy. If that patch ever stops demoting the line, this
# argument is gone and the register entry has to be re-read, so it is asserted here.
pc="$ROOT/patches/windows-utils-percall-mechanics-debug.patch"
if command grep -qE '^[-].*LogInfo\("\[%lld\] disconnected \(%lld total\)' "$pc" \
   && command grep -qE '^[+].*LogDebug\("\[%lld\] disconnected \(%lld total\)' "$pc"; then
  ok "runs our copy: the demotion that proves it is still in percall-mechanics-debug.patch"
else
  bad "runs our copy: percall-mechanics-debug.patch no longer demotes the 'disconnected' line - the proof that the stock daemon runs this DLL needs re-establishing"
fi

# ---- 7. EVERY PRODUCER APPLIES EVERY PATCH -----------------------------------------------------
# Two workflows clone windows-utils and each carries its own copy of the apply steps: build.yml and
# qwt-full.yml, the one the RELEASE PACKAGE is built from. A patch applied by one and not the other
# ships a package without the fix while every offline check here still passes.
mapfile -t PRODUCERS < <(command grep -rl 'deps-src.windows-utils' "$ROOT/.github/workflows/" | sort)
mapfile -t ALLPATCHES < <(ls "$ROOT"/patches/windows-utils-*.patch | xargs -n1 basename | sort)
[ "${#PRODUCERS[@]}" -ge 2 ] \
  && ok "producers: ${#PRODUCERS[@]} workflows clone windows-utils ($(printf '%s ' "${PRODUCERS[@]##*/}"))" \
  || bad "producers: only ${#PRODUCERS[@]} found - if a producer was removed, re-check this test"
missing=0
for w in "${PRODUCERS[@]}"; do
  for pf in "${ALLPATCHES[@]}"; do
    command grep -q "$pf" "$w" || { bad "producers: $(basename "$w") never applies $pf"; missing=$((missing+1)); }
  done
done
[ "$missing" -eq 0 ] && ok "producers: every windows-utils patch is applied by every producer (${#ALLPATCHES[@]} patches x ${#PRODUCERS[@]} workflows)"
for w in "${PRODUCERS[@]}"; do
  command grep -q 'pipe-server lifetime patch did not apply' "$w" \
    && ok "producers: $(basename "$w") FAILS the build if this patch does not apply" \
    || bad "producers: $(basename "$w") would let a failed apply pass silently"
done

echo "pipe-server-lifetime-selftest: $pass passed, $fail failed  (tree: $OUT)"
[ "$fail" -eq 0 ]
