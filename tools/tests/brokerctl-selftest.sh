#!/usr/bin/env bash
# brokerctl-selftest.sh - offline proof matrix for the de-slice broker's CONTROL PATH fix
# (findings/issues.md P1, 2026-10-07; Jev: cause control-behind-work 0.92, fix decouple-control 0.97).
#
# THE DEFECT, measured 2026-10-01: the broker's Reconcile() acknowledges each slot at the END of that slot's own
# iteration, so a new window's registration on slot 3 waited behind slot 0's WGC channel open. The agent's deadline -
# which already requires both "unacknowledged" and "no progress", and a single long call satisfies both because the
# progress counter moves only between stages - read a working broker as hung and TERMINATED it: 1218 ms with every
# window withheld, and on an eligible guest there is no composite fallback.
#
# THE FIX, both halves:
#   broker   a FIRST registration is acknowledged in a pre-pass before any per-slot work, so no slot's work delays
#            another slot's acknowledgement - and ONLY a first registration, because the same acknowledgement tells
#            the agent an arena region is reusable (R4);
#   agent    a stage the broker has DECLARED gets its own budget (WgcbrkStageBudgetMs), so a legitimately slow open is
#            not a hang, and a broker that keeps changing stage is never reaped.
#
#   budget   the shared budget table and its accessors compile and answer per stage (a C test, gcc here)
#   ackfirst the broker's pre-pass runs BEFORE the work loop and refuses the three unsafe cases
#   stage    the agent's overdue test consults the stage budget, and so does the wake-up deadline
#   syntax   the changed broker source parses (UNCOMPILED here - CI builds it with MSVC/WinRT)
# Each check is also seen to FAIL with its guarded line removed.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BRK="$ROOT/tools/wgcbroker/wgcbroker.cpp"
IPC="$ROOT/agent/gui-agent/wgcbroker_ipc.h"
MAIN="$ROOT/agent/gui-agent/main.c"
OUT="${BROKERCTL_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/brokerctl-selftest-XXXXXX")}"
mkdir -p "$OUT"
bad=0; n=0
say() { printf '%s\n' "$*"; }
ok()   { n=$((n+1)); say "PASS  $1"; }
fail() { n=$((n+1)); bad=1; say "FAIL  $1"; [ -n "${2:-}" ] && say "      $2"; }
for f in "$BRK" "$IPC" "$MAIN"; do
    [ -f "$f" ] || { say "FAIL  $f is missing - nothing ran (missing data fails)"; exit 2; }
done

# ---- the budget table, as C ---------------------------------------------------------------------------------------
cat > "$OUT/budget_test.c" <<'EOF'
/* The shared stage-budget table, exercised where the agent reads it. Only the pure parts of the header are needed,
   so the WinRT/Windows types it also declares are stubbed to the shapes these macros use. */
#include <stdio.h>
#include <string.h>
typedef unsigned long ULONG;
typedef long LONG;
typedef unsigned int UINT;
#define __inline inline
/* the pieces of the header under test, extracted by the suite (see BUDGET-BEGIN/END in wgcbroker_ipc.h) */
#include "budget_frag.h"
static int fails;
static void eq(const char *what, unsigned got, unsigned want)
{
    if (got != want) { printf("FAIL %s: got %u want %u\n", what, got, want); fails++; }
    else printf("ok   %s = %u\n", what, got);
}
int main(void)
{
    eq("open-channel gets its own budget", WgcbrkStageBudgetMs(WGCBRK_STG_OPEN), 8000u);
    eq("close gets it too", WgcbrkStageBudgetMs(WGCBRK_STG_CLOSE), 8000u);
    eq("the DWM relay stage gets it too", WgcbrkStageBudgetMs(WGCBRK_STG_RELAY_DWM), 8000u);
    eq("a PrintWindow stage gets its own", WgcbrkStageBudgetMs(WGCBRK_STG_POLL_PW), 6000u);
    eq("our own bookkeeping keeps the ordinary deadline", WgcbrkStageBudgetMs(WGCBRK_STG_RECONCILE), WGCBRK_ACK_DEADLINE_MS);
    eq("the main loop keeps the ordinary deadline", WgcbrkStageBudgetMs(WGCBRK_STG_LOOP), WGCBRK_ACK_DEADLINE_MS);
    /* the published value packs (code << 8) | slot - the agent splits it to pick the budget and to name the slot */
    eq("the stage code is the high bits", WGCBRK_STAGE_CODE((LONG)((WGCBRK_STG_OPEN << 8) | 7)), WGCBRK_STG_OPEN);
    eq("the slot is the low byte", (unsigned)WGCBRK_STAGE_SLOT((LONG)((WGCBRK_STG_OPEN << 8) | 7)), 7u);
    /* every stage must have SOME budget at least as long as the ordinary deadline - never shorter */
    for (unsigned c = 0; c <= 8; c++)
        if (WgcbrkStageBudgetMs(c) < WGCBRK_ACK_DEADLINE_MS) { printf("FAIL stage %u has a budget shorter than the deadline\n", c); fails++; }
    printf("%s\n", fails ? "FAILED" : "all budget checks passed");
    return fails ? 1 : 0;
}
EOF
# the fragment the test includes: the deadline constant, the stage codes and the budget accessor
{
    grep -E '^#define WGCBRK_ACK_DEADLINE_MS' "$IPC"
    grep -E '^#define WGCBRK_STG_' "$IPC"
    sed -n '/^static __inline unsigned WgcbrkStageBudgetMs/,/^}/p' "$IPC"
    grep -E '^#define WGCBRK_STAGE_(CODE|SLOT)' "$IPC"
} > "$OUT/budget_frag.h"
if [ "$(grep -c . "$OUT/budget_frag.h")" -lt 12 ]; then
    fail "budget: the fragment could not be extracted from wgcbroker_ipc.h ($(grep -c . "$OUT/budget_frag.h") line(s))"
elif gcc -std=c99 -Wall -Wextra -Werror -I"$OUT" "$OUT/budget_test.c" -o "$OUT/budget" 2>"$OUT/budget.build"; then
    if "$OUT/budget" >"$OUT/budget.out" 2>&1; then ok "budget: the stage budgets answer per stage, and none is shorter than the ordinary deadline"
    else fail "budget: the C test failed" "$(grep '^FAIL' "$OUT/budget.out" | head -3)"; fi
else fail "budget: the C test did not build" "$(head -3 "$OUT/budget.build")"; fi

# ---- shape: the broker acks first, and refuses the unsafe cases ---------------------------------------------------
shape() { # $1 label, $2 file, $3 predicate-fn, $4 guarded-line-substring
    local f="$2" fn="$3" guard="$4"
    if "$fn" "$f"; then
        local tmp="$OUT/$(basename "$f").knob"
        grep -vF "$guard" "$f" > "$tmp"
        if [ "$(wc -l < "$tmp")" -eq "$(wc -l < "$f")" ]; then fail "$1 (the guarded line '$guard' is not in the file - the knob cannot fire)"; return; fi
        if "$fn" "$tmp"; then fail "$1 - the check still passes with the guarded line removed (it is decoration)"
        else ok "$1 (and FAILS with the guarded line removed)"; fi
    else fail "$1"; fi
}
brk_ack_first() {   # the pre-pass is called from Reconcile BEFORE its slot loop
    awk '/^static void Reconcile\(\) \{/{r=NR} r&&/AckFirstRegistrations\(\);/{a=NR} r&&/for \(int i = 0; i < WGCBRK_MAX_SLOTS/{l=NR; exit} END{exit !(r && a && l && a<l)}' "$1"
}
shape "ackfirst: the broker acknowledges first registrations BEFORE its per-slot work" "$BRK" brk_ack_first 'AckFirstRegistrations();   // GUARD:ackfirst'

brk_ack_safe() {    # the pre-pass refuses a release, a re-registration and an empty slot
    awk '/^static void AckFirstRegistrations\(\) \{/{f=1}
         f&&/s->ReqState != WGCBRK_REQUESTED\) continue;/{a=1}
         f&&/g_ch\[i\].hwnd != nullptr\) continue;/{b=1}
         f&&/s->Hwnd\) continue;/{c=1}
         f&&/^\}/{exit} END{exit !(a && b && c)}' "$1"
}
shape "ackfirst-safe: it refuses a release, a re-registration and an empty slot (R4: an ack frees the agent's region)" \
      "$BRK" brk_ack_safe 'if (g_ch[i].hwnd != nullptr) continue;                         // a re-registration: buffers may be in flight'

# ---- shape: the agent's deadline is stage-aware -------------------------------------------------------------------
agent_stage() {     # the overdue test requires all three: ack, progress AND the stage's own budget
    awk '/static BOOL BrokerAckOverdue/{f=1}
         f&&/WGCBRK_ACK_DEADLINE_MS && now - g_BrokerProgressAt >= WGCBRK_ACK_DEADLINE_MS &&/{a=1}
         f&&/WgcbrkStageBudgetMs\(WGCBRK_STAGE_CODE\(g_BrokerStageSeen\)\)/{b=1}
         f&&/^\}/{exit} END{exit !(a && b)}' "$1" && grep -q 'g_BrokerStageAt = now;' "$1"
}
shape "stage: the agent's hang test also requires the declared stage to have stood still for its own budget" \
      "$MAIN" agent_stage 'now - g_BrokerStageAt >= WgcbrkStageBudgetMs(WGCBRK_STAGE_CODE(g_BrokerStageSeen)))   // GUARD:stagebudget'

agent_due() {       # the wake-up deadline accounts for the same stage budget, or the loop wakes to a false check
    awk '/static ULONGLONG BrokerNextDue/{f=1} f&&/stageDue = g_BrokerStageAt \+ WgcbrkStageBudgetMs/{a=1}
         f&&/if \(stageDue > d\) d = stageDue;/{b=1} f&&/^\}/{exit} END{exit !(a && b)}' "$1"
}
shape "stage-due: the wake-up deadline accounts for the stage budget (no wake that can only find the check false)" \
      "$MAIN" agent_due 'if (stageDue > d) d = stageDue;'

# ---- syntax: the changed broker source still parses ---------------------------------------------------------------
# UNCOMPILED here: wgcbroker.cpp is C++/WinRT and only MSVC builds it. What this proves is that the edit did not break
# the file's structure - braces, statements, the new function's shape - which is what a bad merge or a stray brace does.
if python3 - "$BRK" <<'PY'
import re, sys
src = open(sys.argv[1], encoding='utf-8', errors='replace').read()
# brace balance outside strings/comments, crudely but symmetrically
s = re.sub(r'//[^\n]*', '', src)
s = re.sub(r'/\*.*?\*/', '', s, flags=re.S)
s = re.sub(r'"(\\.|[^"\\])*"', '""', s)
s = re.sub(r"'(\\.|[^'\\])*'", "''", s)
depth = s.count('{') - s.count('}')
fn = re.search(r'static void AckFirstRegistrations\(\) \{(.*?)\n\}', s, re.S)
ok = depth == 0 and fn is not None and fn.group(1).count('continue;') == 4 and 's->CtlAck = ctl;' in fn.group(1)
print(f'brace-delta={depth} prepass={"found" if fn else "MISSING"}')
sys.exit(0 if ok else 1)
PY
then ok "syntax: wgcbroker.cpp's braces balance and the pre-pass has its four refusals and its one write (UNCOMPILED: CI builds it)"
else fail "syntax: wgcbroker.cpp's structure is wrong after the edit"; fi

say "--- $n check(s), $( [ $bad -eq 0 ] && echo 0 || echo 'at least 1') failed; outputs in $OUT"
exit $bad
