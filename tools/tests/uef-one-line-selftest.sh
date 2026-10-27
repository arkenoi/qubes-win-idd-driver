#!/bin/bash
# The exception filter writes the ACCESS VIOLATION's address in ONE line, and FAILS unpatched.
# run: tools/tests/uef-one-line-selftest.sh
# pass: exit 0
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PATCHFILE="$ROOT/patches/windows-utils-uef-one-line.patch"
MIRROR="$ROOT/upstream/ro/qubes-windows-utils"
OUT="${UEFONELINE_SELFTEST_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/uef-one-line-XXXXXX")}"
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
mkdir -p "$OUT/solo" && cp -r "$MIRROR"/. "$OUT/solo/"
if ( cd "$OUT/solo" && patch -p1 --dry-run -i "$PATCHFILE" >/dev/null 2>&1 ); then
  ok "applies: dry run succeeds against a pristine mirror"
else
  bad "applies: dry run FAILED against a pristine mirror"
fi
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

SRC="$OUT/stack/src/error.c"
PRISTINE="$MIRROR/src/error.c"
[ -f "$SRC" ] || { echo "FAIL  the stacked source is missing - nothing below ran"; exit 2; }

# ---- 3. markers the build step asserts, and the must-fail-on-unpatched half --------------------
marker(){ # <label> <pattern>
  if command grep -qE "$2" "$SRC"; then ok "marker: $1"; else bad "marker: $1 is MISSING from the patched source"; fi
  if command grep -qE "$2" "$PRISTINE"; then bad "marker: $1 is present in UNPATCHED source too - it proves nothing"; else ok "marker: $1 absent before the patch"; fi
}
marker "one-write record" 'ONE WRITE, EVERY FACT'
marker "parameter append" 'p%u=%p'
marker "strsafe include"  '#include <strsafe\.h>'

# ---- 4. ONE LogError IN THE FILTER, where there were two ---------------------------------------
# The property is the count inside the filter body, not the presence of a string: a patch that
# added the one-line emit and LEFT the loop would satisfy every marker above and still lose the
# parameters on a process that dies.
uef_body(){ awk '/^static LONG WINAPI ErrUEF\(/,/^}/' "$1"; }
n_after=$(uef_body "$SRC"      | command grep -c 'LogError(')
n_before=$(uef_body "$PRISTINE" | command grep -c 'LogError(')
[ "$n_after" -eq 1 ] \
  && ok "one write: the filter makes exactly 1 LogError call" \
  || bad "one write: the filter makes $n_after LogError calls - a second one can still be lost"
[ "$n_before" -eq 2 ] \
  && ok "one write: UNPATCHED makes 2 (the check can fail)" \
  || bad "one write: expected 2 LogError calls in the mirror's filter, found $n_before - re-read the source"
if uef_body "$SRC" | command grep -qF 'LogError("Parameter %d: %p"'; then
  bad "one write: the per-parameter LogError is still there"
else
  ok "one write: the per-parameter LogError is gone"
fi
if uef_body "$PRISTINE" | command grep -qF 'LogError("Parameter %d: %p"'; then
  ok "one write: UNPATCHED has the per-parameter LogError (the check can fail)"
else
  bad "one write: the mirror has no per-parameter LogError - this test is asserting nothing"
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

# ---- 8. EVERY PRODUCER APPLIES EVERY PATCH -----------------------------------------------------
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
  command grep -q 'UEF one-line patch did not apply' "$w" \
    && ok "producers: $(basename "$w") FAILS the build if this patch does not apply" \
    || bad "producers: $(basename "$w") would let a failed apply pass silently"
done

echo "uef-one-line-selftest: $pass passed, $fail failed  (tree: $OUT)"
[ "$fail" -eq 0 ]
