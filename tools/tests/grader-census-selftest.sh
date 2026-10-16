#!/bin/bash
# grader-census-selftest.sh - the coverage census must not flatter itself.
#
# WHY THIS EXISTS. tools/grader-census.py overstated coverage TWICE in one afternoon, each time
# moving its own headline in the reassuring direction:
#   1. it counted a suite's STUB of a grader as coverage of it. Suites for the cell graders stub
#      locate_release_disc, ensure_churn_target and boot_with_release_iso to keep the cell under
#      test from running them, and all three were scored covered - the count read 29 of 156 when the
#      truth was 36.
#   2. with that fixed, cell_appvm dropped off the uncovered list because a new suite's header
#      comment merely DISCUSSED it, and its 18 decisions left the untested count silently: the
#      headline went 36 -> 12 on prose alone.
# A census that rewards stubbing and writing is worse than no census, because it reads as progress.
# So each rule is driven here against a throwaway tree, with the real tool.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 2
ROOT="$PWD"
T=$(mktemp -d "${TMPDIR:-/tmp}/gradercensus.XXXXXX") || exit 2
trap 'rc=$?; if [ "$rc" -eq 0 ]; then rm -rf "$T"; else printf "kept %s (rc=%s)\n" "$T" "$rc" >&2; fi' EXIT INT TERM
pass=0; fail=0
ok_(){  printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
no_(){ printf '  FAIL  %s\n     -> %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# A throwaway tree with the tool, one harness carrying three graders, and a tests/ directory whose
# contents each case controls. The harness paths the tool reads are relative, so the case runs there.
mkdir -p "$T/mgmt/harness" "$T/tools/tests"
cp "$ROOT/tools/grader-census.py" "$T/tools/"
cat > "$T/mgmt/harness/matrix.sh" <<'EOF'
#!/bin/bash
graded_a(){
  ok "a passed"
  no "a failed"
}
graded_b(){
  no "b failed"
}
helper_c(){
  ok "c passed"
}
EOF

run(){ ( cd "$T" && python3 tools/grader-census.py --json 2>/dev/null ); }
unc(){ run | python3 -c "import json,sys; print(' '.join(json.load(sys.stdin)['uncovered']))"; }
dec(){ run | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['decisions_uncovered'])"; }

# ---- 0. with no suites at all, every grader is uncovered --------------------------------------
rm -f "$T/tools/tests"/*
got=$(unc)
if [ "$got" = "graded_a graded_b helper_c" ] || [ "$got" = "graded_a helper_c graded_b" ]; then
  ok_ "with no suites, all three graders are uncovered"
else no_ "with no suites all are uncovered" "got '$got'"; fi
[ "$(dec)" = 4 ] && ok_ "and it counts the DECISIONS, not just the graders (4)" || no_ "decision count" "got $(dec)"

# ---- 1. A STUB IS NOT COVERAGE (the first overstatement) --------------------------------------
printf '#!/bin/bash\ngraded_a(){ return 0; }\n' > "$T/tools/tests/stub-selftest.sh"
case " $(unc) " in *" graded_a "*) ok_ "a suite that only STUBS graded_a does not cover it" ;;
  *) no_ "a stub is not coverage" "uncovered: $(unc)" ;; esac

# ---- 2. A COMMENT IS NOT COVERAGE (the second overstatement) ----------------------------------
rm -f "$T/tools/tests"/*
printf '#!/bin/bash\n# this suite discusses graded_a at length but never calls it\necho hi\n' > "$T/tools/tests/prose-selftest.sh"
case " $(unc) " in *" graded_a "*) ok_ "a suite that only WRITES ABOUT graded_a does not cover it" ;;
  *) no_ "prose is not coverage" "uncovered: $(unc)" ;; esac

# a python docstring is prose too
rm -f "$T/tools/tests"/*
printf '%s\n' '"""graded_a is interesting."""' 'print(1)' > "$T/tools/tests/doc-selftest.py"
case " $(unc) " in *" graded_a "*) ok_ "a python DOCSTRING mentioning graded_a does not cover it" ;;
  *) no_ "a docstring is not coverage" "uncovered: $(unc)" ;; esac

# ---- 3. REAL CODE DOES COVER IT, or every rule above would pass by counting nothing -----------
rm -f "$T/tools/tests"/*
printf '#!/bin/bash\ngraded_a one two\n' > "$T/tools/tests/real-selftest.sh"
case " $(unc) " in *" graded_a "*) no_ "a real call DOES cover it" "graded_a still uncovered" ;;
  *) ok_ "a suite that actually CALLS graded_a covers it" ;; esac

# and a suite that stubs AND exercises counts, because the name appears outside the stub
rm -f "$T/tools/tests"/*
printf '#!/bin/bash\ngraded_a(){ return 0; }\nif graded_a; then echo ok; fi\n' > "$T/tools/tests/both-selftest.sh"
case " $(unc) " in *" graded_a "*) no_ "stub PLUS a real call counts" "still uncovered" ;;
  *) ok_ "a suite that stubs AND then calls it does count - the stub rule is not a blanket refusal" ;; esac

# ---- 4. the ceiling can FAIL, and is the only thing that moves it -----------------------------
rm -f "$T/tools/tests"/*
( cd "$T" && python3 tools/grader-census.py --max-uncovered 2 >/dev/null 2>&1 )
[ $? -ne 0 ] && ok_ "--max-uncovered 2 FAILS with three uncovered graders" || no_ "the ceiling fails" "it passed"
( cd "$T" && python3 tools/grader-census.py --max-uncovered 3 >/dev/null 2>&1 )
[ $? -eq 0 ] && ok_ "--max-uncovered 3 passes with three - the ceiling is exact, not approximate" || no_ "the ceiling is exact" "it failed"

# ---- 5. SEEN TO FAIL: a census that counted comments would report ZERO here -------------------
rm -f "$T/tools/tests"/*
printf '#!/bin/bash\n# graded_a graded_b helper_c\n' > "$T/tools/tests/allprose-selftest.sh"
if [ "$(dec)" = 4 ]; then ok_ "SEEN TO FAIL: a file naming all three in a COMMENT still leaves 4 decisions untested"
else no_ "SEEN TO FAIL: prose does not zero the count" "decisions_uncovered=$(dec), want 4"; fi

printf 'grader-census-selftest: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
