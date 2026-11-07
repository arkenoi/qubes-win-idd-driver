#!/bin/bash
# QpsDestroy cannot free a pipe server a caller's threads can still reach - the lifetime fix in winutils/src/pipe-server.c holds.
# run: tools/tests/pipe-server-lifetime-selftest.sh
# pass: exit 0
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WU="$ROOT/winutils"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }
[ -f "$WU/src/pipe-server.c" ] || { echo "FAIL  $WU/src/pipe-server.c is missing (is the winutils submodule checked out?) - nothing ran (missing data fails)"; exit 2; }

SRC="$WU/src/pipe-server.c"

# ---- 3. the shipped source carries the receipts and the funnel guard's own log line ---------------
marker(){ # <label> <pattern>
  if command grep -qE "$2" "$SRC"; then ok "marker: $1"; else bad "marker: $1 is MISSING from the shipped source"; fi
}
marker "retain record"   'THE SERVER OBJECT IS DELIBERATELY RETAINED'
marker "destroy receipt" 'QPSDESTROYED server object retained'
marker "funnel guard"    'no client list to search'

# ---- 4. the DEFECT is gone from QpsDestroy -----------------------------------------------------
# Scoped to the function body, not the file: free() and DeleteCriticalSection are legitimate
# elsewhere (QpsReleaseClient frees a CLIENT and deletes the CLIENT's lock, which stays correct).
destroy_body(){ awk '/^void QpsDestroy\(/,/^}/' "$1" | sed 's@//.*@@'; }
for site in 'free(Server)' 'DeleteCriticalSection(&Server->Lock)' 'ZeroMemory(Server'; do
  n_after=$(destroy_body "$SRC" | command grep -cF "$site")
  [ "$n_after" -eq 0 ] \
    && ok "defect: QpsDestroy no longer does $site" \
    || bad "defect: QpsDestroy still does $site ($n_after site(s)) - a caller's pointer is still invalidated"
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
mapfile -t EXPORTED < <(command grep -A3 'WINDOWSUTILS_API' "$WU/include/pipe-server.h" \
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

dci=$(awk '/^static void QpsDisconnectClientInternal\(/,/^}/' "$SRC")
if printf '%s' "$dci" | command grep -qF 'QpsGetClient(Server, ClientId)' \
   && printf '%s' "$dci" | command grep -qF 'if (!client)'; then
  ok "paths: QpsDisconnectClientInternal - the crashing call's own target - goes through the funnel"
else
  bad "paths: QpsDisconnectClientInternal does not go through the funnel"
fi

# ---- 6. THE STOCK DAEMON RUNS OUR COPY ---------------------------------------------------------
# This is why a windows-utils fix is a fix at all. Stock (v4.2.2) QpsDisconnectClientInternal logs BOTH
# "disconnecting, WriterExiting .." and "disconnected (%lld total)" at LogInfo; our source demotes the
# second to LogDebug. The 2026-10-26 capture holds 61 of the first and zero of the second, with no
# DEBUG line in the file - so the code that wrote them is OUR copy. If the shipped source ever stops
# demoting the line, this argument is gone and the register entry has to be re-read, so it is
# asserted here.
if command grep -qE '^[[:space:]]*LogDebug\("\[%lld\] disconnected \(%lld total\)' "$SRC" \
   && ! command grep -qE '^[[:space:]]*LogInfo\("\[%lld\] disconnected \(%lld total\)' "$SRC"; then
  ok "runs our copy: the shipped pipe-server.c logs the 'disconnected' line at Debug, not Info (stock logs it at Info)"
else
  bad "runs our copy: winutils pipe-server.c no longer demotes the 'disconnected' line - the proof that the stock daemon runs this DLL needs re-establishing"
fi

echo "pipe-server-lifetime-selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
