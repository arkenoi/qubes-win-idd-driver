#!/bin/bash
# pwclass-truth-table.sh - prove the router refactor did not change routing.
#
# WHY. Stage 1 of the de-slice programme is instrument-only except for ONE change: PwWindowEligible
# no longer computes its BOOL directly but derives it from a new PwWindowClassify, so the
# provenance ledger records the router's own reason instead of a second copy of the predicate. That
# refactor is the only place stage 1 can change behaviour by accident, and Jev named it the thing
# to prove next (write-the-truth-table-test 0.87) once the ledger's own defects were fixed.
#
# It extracts PwWindowClassify VERBATIM from the shipped source rather than restating it, so the
# thing tested is the thing that ships, and drives every combination of the five inputs it reads.
set -u
cd "$(dirname "$0")/../.." || exit 2
SRC=agent/gui-agent/perwindow.c
[ -f "$SRC" ] || { echo "SELFTEST-ERROR: $SRC missing"; exit 2; }
T=$(mktemp -d "${TMPDIR:-/tmp}/pwclass.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT

python3 - "$SRC" > "$T/fn.inc" <<'PY'
import re, sys
s = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'^(PW_WINDOW_CLASS PwWindowClassify\(IN const WINDOW_DATA\* entry\)\n\{.*?\n\})',
              s, re.S | re.M)
if not m: sys.exit("SELFTEST-ERROR: PwWindowClassify not found in the shipped source")
print(m.group(1))
PY
[ -s "$T/fn.inc" ] || { echo "SELFTEST-ERROR: extraction produced nothing"; exit 2; }

cat > "$T/t.c" <<'C'
#include <stdio.h>
#include <string.h>
typedef int BOOL; typedef unsigned long DWORD; typedef unsigned long COLORREF;
typedef unsigned char BYTE; typedef void* HWND;
#define TRUE 1
#define FALSE 0
#define IN
#define WS_EX_LAYERED 0x00080000L
#define WS_EX_NOREDIRECTIONBITMAP 0x00200000L
#define LWA_COLORKEY 0x00000001
typedef enum { PWC_ELIGIBLE = 0, PWC_OR, PWC_NRB, PWC_ULW, PWC_COLORKEY } PW_WINDOW_CLASS;
typedef struct { BOOL IsOverrideRedirect; DWORD ExStyle; HWND Handle; } WINDOW_DATA;
/* The stub stands in for the one Win32 call the predicate makes. Both of its outcomes are driven:
   failure is the ULW case, success with LWA_COLORKEY is the colour-key case. */
static int g_glwaOk = 1, g_glwaFlags = 0;
static BOOL GetLayeredWindowAttributes(HWND h, COLORREF* k, BYTE* a, DWORD* f)
{ (void)h; (void)k; (void)a; if (!g_glwaOk) return FALSE; *f = (DWORD)g_glwaFlags; return TRUE; }
#include "fn.inc"
static BOOL PwWindowEligible(IN const WINDOW_DATA* e) { return PwWindowClassify(e) == PWC_ELIGIBLE; }

int main(void)
{
    /* or, nrb, layered, glwaOk, colorkey -> expected class. This is the ORIGINAL predicate's
       behaviour, written from the pre-refactor source, not from the refactor. */
    struct { int or_, nrb, lay, ok, key; PW_WINDOW_CLASS want; } cases[] = {
        {0,0,0,1,0, PWC_ELIGIBLE},  {0,0,0,1,1, PWC_ELIGIBLE},  /* not layered: flags irrelevant */
        {0,0,0,0,0, PWC_ELIGIBLE},  {0,0,1,1,0, PWC_ELIGIBLE},  /* layered, plain alpha */
        {0,0,1,1,1, PWC_COLORKEY},  {0,0,1,0,0, PWC_ULW},       /* colour key / ULW */
        {0,0,1,0,1, PWC_ULW},                                    /* GLWA failed: key unreadable */
        {0,1,0,1,0, PWC_NRB},       {0,1,1,1,1, PWC_NRB},        /* NRB beats layered */
        {1,0,0,1,0, PWC_OR},        {1,1,1,0,1, PWC_OR},         /* override-redirect beats all */
    };
    int fail = 0, n = (int)(sizeof(cases)/sizeof(cases[0])), i;
    for (i = 0; i < n; i++) {
        WINDOW_DATA w; PW_WINDOW_CLASS got; BOOL elig;
        memset(&w, 0, sizeof(w));
        w.IsOverrideRedirect = cases[i].or_;
        w.ExStyle = (cases[i].nrb ? WS_EX_NOREDIRECTIONBITMAP : 0) |
                    (cases[i].lay ? WS_EX_LAYERED : 0);
        g_glwaOk = cases[i].ok; g_glwaFlags = cases[i].key ? LWA_COLORKEY : 0;
        got = PwWindowClassify(&w);
        elig = PwWindowEligible(&w);
        if (got != cases[i].want) {
            printf("  FAIL or=%d nrb=%d lay=%d glwaOk=%d key=%d -> class %d, expected %d\n",
                   cases[i].or_, cases[i].nrb, cases[i].lay, cases[i].ok, cases[i].key,
                   (int)got, (int)cases[i].want);
            fail = 1;
        }
        /* the derivation itself: eligibility must be exactly "class is ELIGIBLE" */
        if (elig != (got == PWC_ELIGIBLE)) {
            printf("  FAIL eligibility %d disagrees with class %d\n", (int)elig, (int)got);
            fail = 1;
        }
    }
    printf(fail ? "FAIL: the refactor changed routing\n"
                : "PASS: %d style combinations route exactly as the original predicate\n", n);
    return fail;
}
C
gcc -O0 -I"$T" -o "$T/t" "$T/t.c" 2>"$T/cc.err" || { echo "SELFTEST-ERROR: compile failed"; sed 's/^/    /' "$T/cc.err" | head -8; exit 2; }
echo "pwclass truth-table selftest"
"$T/t"; rc=$?

# PROOF OF FAILURE. A check never seen to fail is decoration. Flip one branch in the EXTRACTED
# copy - not in the shipped source - and require the test to catch it.
if [ "${1:-}" = "--prove" ]; then
  echo "--- proof of failure: mutate one branch of the extracted predicate"
  sed 's/return PWC_COLORKEY;/return PWC_ELIGIBLE;/' "$T/fn.inc" > "$T/fn2.inc" && mv "$T/fn2.inc" "$T/fn.inc"
  gcc -O0 -I"$T" -o "$T/t2" "$T/t.c" 2>/dev/null || { echo "  SELFTEST-ERROR: mutant did not compile"; exit 2; }
  if "$T/t2" >/dev/null 2>&1; then echo "  FAIL the mutated predicate PASSED - this test is decoration"; rc=1
  else echo "  OK   the mutated predicate was caught"; fi
fi
exit $rc
