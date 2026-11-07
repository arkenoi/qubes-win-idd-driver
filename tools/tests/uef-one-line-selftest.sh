#!/bin/bash
# The exception filter writes the ACCESS VIOLATION's address in ONE line (winutils/src/error.c).
# run: tools/tests/uef-one-line-selftest.sh
# pass: exit 0
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WU="$ROOT/winutils"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }
[ -f "$WU/src/error.c" ] || { echo "FAIL  $WU/src/error.c is missing (is the winutils submodule checked out?) - nothing ran (missing data fails)"; exit 2; }

SRC="$WU/src/error.c"

# ---- 3. the shipped source carries the one-line record's markers ------------------------------
marker(){ # <label> <pattern>
  if command grep -qE "$2" "$SRC"; then ok "marker: $1"; else bad "marker: $1 is MISSING from the shipped source"; fi
}
marker "one-write record" 'ONE WRITE, EVERY FACT'
marker "parameter append" 'p%u=%p'
marker "strsafe include"  '#include <strsafe\.h>'

# ---- 4. ONE LogError IN THE FILTER, where there were two ---------------------------------------
# The property is the count inside the filter body, not the presence of a string: a patch that
# added the one-line emit and LEFT the loop would satisfy every marker above and still lose the
# parameters on a process that dies.
uef_body(){ awk '/^static LONG WINAPI ErrUEF\(/,/^}/' "$1"; }
n_after=$(uef_body "$SRC" | command grep -c 'LogError(')
[ "$n_after" -eq 1 ] \
  && ok "one write: the filter makes exactly 1 LogError call" \
  || bad "one write: the filter makes $n_after LogError calls - a second one can still be lost"
if uef_body "$SRC" | command grep -qF 'LogError("Parameter %d: %p"'; then
  bad "one write: the per-parameter LogError is still there"
else
  ok "one write: the per-parameter LogError is gone"
fi

# ---- 5. THE HEAD OF THE LINE IS UNCHANGED ------------------------------------------------------
# Everything that already quotes this line - the sweep's signature key, findings/misc.md, the
# sibling selftest's measured excerpt - anchors on the head. An inserted or reworded prefix blinds
# every one of them, so the new format must EXTEND the old, not replace it.
head_re='Unhandled exception %08x at %p, flags: %x'
if command grep -qF "$head_re" "$SRC"; then
  ok "head: the line still begins '$head_re'"
else
  bad "head: the format no longer carries the old head - every consumer that quotes it is blinded"
fi
if command grep -qF 'Unhandled exception %08x at %p, flags: %x%s' "$SRC"; then
  ok "head: the detail is APPENDED to that head, in the same format string"
else
  bad "head: no appended detail - the parameters are not in the head line"
fi

# ---- 6. THE ACCESS VIOLATION IS DECODED, which is the whole reason this was touched -----------
ub=$(uef_body "$SRC")
for want in 'EXCEPTION_ACCESS_VIOLATION' 'ExceptionInformation\[1\]' 'L"read"' 'L"write"'; do
  if printf '%s' "$ub" | command grep -qE "$want"; then
    ok "decode: the filter names $want"
  else
    bad "decode: $want is missing - an AV's address or direction would still be unreadable"
  fi
done
# NumberParameters must be checked before [1] is read, or the decode itself faults.
ln_guard=$(printf '%s\n' "$ub" | command grep -nF 'NumberParameters >= 2' | head -1 | cut -d: -f1)
ln_use=$(printf '%s\n' "$ub"   | command grep -nF 'ExceptionInformation[1]' | head -1 | cut -d: -f1)
if [ -n "$ln_guard" ] && [ -n "$ln_use" ] && [ "$ln_guard" -lt "$ln_use" ]; then
  ok "decode: NumberParameters is checked (line $ln_guard) before [1] is read (line $ln_use)"
else
  bad "decode: guard at '$ln_guard', use at '$ln_use' - the filter could fault inside itself"
fi
# And the loop must stay bounded by the record's own maximum.
if printf '%s' "$ub" | command grep -qF 'EXCEPTION_MAXIMUM_PARAMETERS'; then
  ok "decode: the parameter loop is bounded by EXCEPTION_MAXIMUM_PARAMETERS"
else
  bad "decode: the parameter loop trusts NumberParameters alone"
fi

# ---- 7. THE REFUSAL THAT MUST STAY A REFUSAL ---------------------------------------------------
# Naming the module the faulting instruction belongs to is the obvious next wish, and
# GetModuleHandleEx(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS) takes the LOADER LOCK. A crash that
# happened while holding that lock would turn this filter into a hang at process exit, which is
# worse than the missing fact. The comment records the refusal; this check makes adding it a
# deliberate act that has to delete the comment first.
# COMMENTS STRIPPED FIRST, and the first draft of this very check did not: the comment that
# refuses GetModuleHandleEx names it, so the check failed on correct source. A source assertion
# must look at the code, never at the prose describing it.
if sed 's@//.*@@' "$SRC" | command grep -qF 'GetModuleHandleEx'; then
  bad "refusal: the filter now takes the loader lock - read the comment that refuses it"
else
  ok "refusal: the filter does not take the loader lock (comments stripped before asking)"
fi
if command grep -qF 'DELIBERATELY NOT DONE HERE' "$SRC"; then
  ok "refusal: the reason is recorded at the site"
else
  bad "refusal: the reason is not at the site, so the next reader will just add it"
fi

echo "uef-one-line-selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
