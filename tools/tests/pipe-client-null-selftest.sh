#!/bin/bash
# The NULL-client guards cover both pipe-server thread entries and the sibling site, in the winutils source we ship.
# run: tools/tests/pipe-client-null-selftest.sh
# pass: exit 0
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WU="$ROOT/winutils"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }
[ -f "$WU/src/pipe-server.c" ] || { echo "FAIL  $WU/src/pipe-server.c is missing (is the winutils submodule checked out?) - nothing ran (missing data fails)"; exit 2; }

SRC="$WU/src/pipe-server.c"

# ---- 3. the shipped source carries the guards' own log lines -----------------------------------
marker(){ # <label> <pattern>
  if command grep -qE "$2" "$SRC"; then ok "marker: $1"; else bad "marker: $1 is MISSING from the shipped source"; fi
}
marker "reader guard"  'not in the client list; reader thread exits'
marker "writer guard"  'not in the client list; writer thread exits'
marker "release guard" 'NOTHING TO RELEASE IF THE CLIENT IS ALREADY GONE'

# ---- 4. the DEFECT is gone ---------------------------------------------------------------------
# The defect's exact shape: the lookup, then a dereference on the next line, with nothing between.
defect_re='QpsGetClient\(server, param->ClientId\);'
# -E, not BRE: in a BRE `\(` is a GROUP, so this pattern matched nothing and the count came back 0 -
# the "defect gone" check passed vacuously. So the lookups are COUNTED too: a pattern that finds none
# proves nothing, and there are exactly two thread entries.
n_bad_after=$(command grep -E -A1 "$defect_re" "$SRC" | command grep -c 'HANDLE pipe = client->')
n_lookups=$(command grep -cE "$defect_re" "$SRC")
[ "$n_bad_after" -eq 0 ] && [ "$n_lookups" -eq 2 ] \
  && ok "defect: no thread entry dereferences the client on the line after the lookup (2 lookups, 0 unguarded)" \
  || bad "defect: $n_bad_after of $n_lookups lookups are dereferenced immediately (want 0 of 2 - or the lookup's shape changed, re-read the source)"

# ---- 4b. THE SIBLING SITE, which the first draft of this patch left unguarded ------------------
# Jev, on that draft: sibling_sites_left_unguarded leaned one_or_more_left. It was right.
# QpsReleaseClient decrements Client->RefCount, and the PUBLIC QpsDisconnectClient hands it the
# result of QpsGetClientRaw - NULL for a client that has just been unlinked. RefCount is at offset
# 0x78 and InterlockedDecrement WRITES through the pointer, so that is a distinct crash of the same
# class; a fix guarding only the two thread entries would have been a repeat waiting to happen.
rel_after=$(awk '/^void QpsDisconnectClient\(/,/^}/' "$SRC" | command grep -c 'if (client)')
[ "$rel_after" -ge 1 ] \
  && ok "sibling: QpsDisconnectClient checks the lookup before releasing it" \
  || bad "sibling: QpsDisconnectClient still passes an unchecked lookup to QpsReleaseClient"
# And the guard must come BEFORE the decrement, not merely exist somewhere in the function.
# COMPARE THE LINE NUMBERS. The first attempt grepped for a literal '1:' prefix, which is the
# stream position of the match, not its rank - it can never be 1 here, so the check failed on a
# correct patch.
# COMMENTS STRIPPED FIRST. The guard's own comment contains the word InterlockedDecrement, so the
# comparison below matched the EXPLANATION and placed the write before the check - the same trap as
# a scripted edit landing inside the comment describing it, and the fourth time today in some form.
rel_body=$(awk '/^void QpsDisconnectClient\(/,/^}/' "$SRC" | sed 's@//.*@@')
ln_check=$(printf '%s\n' "$rel_body" | command grep -nE 'if \(client\)' | head -1 | cut -d: -f1)
ln_dec=$(printf '%s\n' "$rel_body" | command grep -nE 'QpsReleaseClient' | head -1 | cut -d: -f1)
if [ -n "$ln_check" ] && [ -n "$ln_dec" ] && [ "$ln_check" -lt "$ln_dec" ]; then
  ok "sibling: the check (line $ln_check) precedes the release call (line $ln_dec)"
else
  bad "sibling: check at '$ln_check', release at '$ln_dec' - the guard does not precede the call"
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

echo "pipe-client-null-selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
