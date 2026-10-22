#!/usr/bin/env bash
# wedge-gates-selftest.sh - every class of mgmt/harness/wedge-gates-lib.sh, driven offline.
#
# WHY. On 2026-10-22 two guests presented the SAME surface symptom and were in opposite states:
# win11-upgrade's guest went silent after its post-install boot, ignored four ACPI asks, had an
# unreadable boot time and was killed at 600s; win11-acc refused qvm-shutdown while its harness
# still held it, yet qrexec ANSWERED rc=0 and it halted cleanly once released. Anything keyed on
# "qrexec absent" or "shutdown refused" calls both wedged and kills a healthy guest. Five disjoint
# predicates existed across the harness and none of them decided "wedged"; the one sound classifier
# (wedge_classify, host-side, no guest cooperation) was never called on the path that mattered.
#
# THE FIXTURES ARE THE TWO REAL SPECIMENS, and one of them is deliberately uncomfortable:
# "as-captured" holds exactly what the campaign actually recorded for the wedged guest - and that
# contains NO VMCS section, because nothing captured one. The honest verdict on that evidence is
# UNREADABLE-CPU, not a wedge: we could not tell. The "with-record" fixture adds the VMCS the new
# record takes BEFORE any kill, and only then is the class decidable. That contrast is the whole
# argument for the record, and it is asserted here rather than claimed in a comment.
# The VMCS values in "with-record" are a CONSTRUCTED case exercising the tree - not a measurement
# of that guest, which was killed without ever being sampled.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/mgmt/harness/wedge-gates-lib.sh"
pass=0; fail=0
say(){ printf '%s\n' "$*"; }
ck(){ if [ "$2" = 0 ]; then pass=$((pass+1)); say "ok   $1"; else fail=$((fail+1)); say "FAIL $1"; [ -n "${3:-}" ] && say "       -> $3"; fi; }
[ -f "$LIB" ] || { say "FAIL  $LIB missing - nothing ran"; exit 2; }
. "$LIB"

T="$(mktemp -d "${TMPDIR:-/tmp}/wedgegates.XXXXXX")"; trap 'rm -rf "$T"' EXIT
NOW=1792680000

# mk <name> k=v ...   - builds an evidence dir; 'listing' defaults to a healthy two-line listing
mk(){ local d="$T/$1"; shift; rm -rf "$d"; mkdir -p "$d"
  printf 'dom0  Running\nwin11-acc  Running\n' > "$d/listing.txt"
  printf '%s\n' "$NOW" > "$d/now"; printf 'win11-acc\n' > "$d/vm"; printf '1\n' > "$d/dom0-ok"
  local kv; for kv in "$@"; do
    case "$kv" in
      listing=EMPTY) : > "$d/listing.txt" ;;
      listing=NOVM)  printf 'dom0  Running\n' > "$d/listing.txt" ;;
      *) printf '%s\n' "${kv#*=}" > "$d/${kv%%=*}" ;;
    esac
  done
  printf '%s' "$d"
}
cls(){ wedge_stage1 "$1" >/dev/null 2>&1; printf '%s' "$WG_CLASS"; }

# ---- 1. the two REAL specimens -----------------------------------------------------------------
# win11-acc: qrexec ANSWERED rc=0 (measured). It must never be called wedged.
d=$(mk acc qrexec=ANSWERED c4=$((NOW-5)))
ck 'the LOOK-ALIKE (win11-acc: shutdown refused, qrexec answered rc=0) classifies ALIVE' \
   "$([ "$(cls "$d")" = ALIVE ] && echo 0 || echo 1)" "got $(cls "$d")"

# win11-upgrade AS CAPTURED: answered at 13:15:17 then silent; screen tar was 0 bytes (NOWINDOW);
# no VMCS was ever taken. The only honest answer is "we could not tell".
d=$(mk wedge-as-captured qrexec=SILENT c4=$((NOW-1380)) c1=1500 screen=NOWINDOW)
ck 'the TRUE WEDGE, with only the evidence actually captured, is UNREADABLE-CPU - not a wedge' \
   "$([ "$(cls "$d")" = UNREADABLE-CPU ] && echo 0 || echo 1)" "got $(cls "$d")"
# IN THE CURRENT SHELL, never inside $( ): a command substitution is a SUBSHELL, so WG_WHY and
# WG_LINES set by the function never reach the assertion. Three legs failed on exactly that.
wedge_stage1 "$d" >/dev/null
ck '...and it says the decisive observable was absent rather than guessing a class' \
   "$(printf '%s' "$WG_WHY" | grep -q 'absent' && echo 0 || echo 1)" "why: $WG_WHY"

# the same guest, with the record the new design takes BEFORE any kill
d=$(mk wedge-spin qrexec=SILENT c4=$((NOW-1380)) c1=1500 screen=NOWINDOW \
       vmcs-activity=ACTIVE vmcs-rip-static=1 fraction=SPIN)
ck 'the SAME guest, once the VMCS is in the record, is a WEDGE-SPIN-CANDIDATE' \
   "$([ "$(cls "$d")" = WEDGE-SPIN-CANDIDATE ] && echo 0 || echo 1)" "got $(cls "$d")"
ck '...and stage 1 does NOT call it a wedge, because ACPI has not been asked yet' \
   "$(printf '%s' "$(cls "$d")" | grep -q '^WEDGE-SPIN$' && echo 1 || echo 0)" 'the third conjunct needs stage 2'

# THE OWNER'S DEFINITION: present + NO PIXELS + ACPI ignored. Each conjunct tested on its own.
d=$(mk pixels qrexec=SILENT c4=$((NOW-1380)) c1=1500 screen=DESKTOP vmcs-activity=ACTIVE vmcs-rip-static=1)
ck 'a guest that is DRAWING is never a wedge, however silent and however busy its vCPU' \
   "$([ "$(cls "$d")" = UNRESPONSIVE-WITH-PIXELS ] && echo 0 || echo 1)" "got $(cls "$d")"
d=$(mk noscreen qrexec=SILENT c4=$((NOW-1380)) c1=1500 vmcs-activity=HLT)
ck 'with NO screen capture, "displays no pixels" cannot be asserted -> UNREADABLE-SCREEN' \
   "$([ "$(cls "$d")" = UNREADABLE-SCREEN ] && echo 0 || echo 1)" "got $(cls "$d")"
d=$(mk blackok qrexec=SILENT c4=$((NOW-1380)) c1=1500 screen=BLACK vmcs-activity=HLT)
ck 'BLACK counts as no pixels, same as NOWINDOW' \
   "$([ "$(cls "$d")" = WEDGE-BLOCKED-CANDIDATE ] && echo 0 || echo 1)" "got $(cls "$d")"

# THE LOOK-ALIKE THE OWNER NAMED: a queued call restarts it the moment it halts.
d=$(mk queue qrexec=SILENT c4=$((NOW-1380)) c1=1500 screen=NOWINDOW vmcs-activity=HLT restarts=3 pending-qrexec=2)
ck 'queued qrexec + rapid restarts is QREXEC-QUEUE-RESTART, NOT a wedge' \
   "$([ "$(cls "$d")" = QREXEC-QUEUE-RESTART ] && echo 0 || echo 1)" "got $(cls "$d")"
ck '...and it is dispositioned "wait", so nothing kills it' \
   "$([ "$(wedge_disposition QREXEC-QUEUE-RESTART)" = wait ] && echo 0 || echo 1)" "$(wedge_disposition QREXEC-QUEUE-RESTART)"
d=$(mk queue0 qrexec=SILENT c4=$((NOW-1380)) c1=1500 screen=NOWINDOW vmcs-activity=HLT restarts=3 pending-qrexec=0)
ck 'restarts with NOTHING queued to explain them is RESTART-UNEXPLAINED, not a wedge' \
   "$([ "$(cls "$d")" = RESTART-UNEXPLAINED ] && echo 0 || echo 1)" "got $(cls "$d")"

# ---- 2. every other leaf, one fixture each ------------------------------------------------------
d=$(mk instr listing=EMPTY qrexec=SILENT)
ck 'an empty/unparseable listing is INSTRUMENT-FAILURE, never a guest state' \
   "$([ "$(cls "$d")" = INSTRUMENT-FAILURE ] && echo 0 || echo 1)" "got $(cls "$d")"
d=$(mk nodom0 dom0-ok=0 qrexec=SILENT)
ck 'dom0 not answering is INSTRUMENT-FAILURE' \
   "$([ "$(cls "$d")" = INSTRUMENT-FAILURE ] && echo 0 || echo 1)" "got $(cls "$d")"
d=$(mk gone listing=NOVM qrexec=SILENT)
ck 'absent from a HEALTHY listing is DOMAIN-GONE' \
   "$([ "$(cls "$d")" = DOMAIN-GONE ] && echo 0 || echo 1)" "got $(cls "$d")"
d=$(mk shut qrexec=SILENT c2=$((NOW-30)) c4=$((NOW-9999)) vmcs-activity=ACTIVE vmcs-rip-static=1)
ck 'a guest WE asked to stop 30s ago is SHUTTING-DOWN even with a spinning vCPU' \
   "$([ "$(cls "$d")" = SHUTTING-DOWN ] && echo 0 || echo 1)" "got $(cls "$d")"
d=$(mk rec qrexec=SILENT screen=RECOVERY vmcs-activity=HLT)
ck 'a RECOVERY screen is terminal whatever the cpu says' \
   "$([ "$(cls "$d")" = RECOVERY ] && echo 0 || echo 1)" "got $(cls "$d")"
d=$(mk boot qrexec=SILENT c1=120 vmcs-activity=ACTIVE vmcs-rip-static=1 fraction=SPIN)
ck 'a guest 120s into its FIRST boot is BOOTING, not WEDGE-SPIN - the draft-2 defect' \
   "$([ "$(cls "$d")" = BOOTING ] && echo 0 || echo 1)" "got $(cls "$d")"
d=$(mk recent qrexec=SILENT c4=$((NOW-30)) c1=60 vmcs-activity=ACTIVE vmcs-rip-static=1)
ck 'silent for 30s after a known answer is ALIVE-RECENT, inside its own bound' \
   "$([ "$(cls "$d")" = ALIVE-RECENT ] && echo 0 || echo 1)" "got $(cls "$d")"
d=$(mk cand qrexec=SILENT c4=$((NOW-1380)) c1=1500 screen=NOWINDOW vmcs-activity=HLT)
ck 'every vCPU HLT is WEDGE-BLOCKED-CANDIDATE - stage 1 refuses to decide without the probe' \
   "$([ "$(cls "$d")" = WEDGE-BLOCKED-CANDIDATE ] && echo 0 || echo 1)" "got $(cls "$d")"

# ---- 3. THE TOTALITY GAP that draft 2 had ------------------------------------------------------
# A guest that boots, ANSWERS, then dies INSIDE its boot bound matched no rule at all in draft 2.
d=$(mk gap qrexec=SILENT c1=200 c4=$((NOW-200)) screen=NOWINDOW vmcs-activity=HLT)
got=$(cls "$d")
ck 'SEEN TO FAIL in draft 2: answered then died INSIDE the boot bound still gets a class' \
   "$([ -n "$got" ] && [ "$got" != BOOTING ] && echo 0 || echo 1)" "got '$got' (draft 2 fell through every rule)"

# ---- 4. contradicting instruments are a MEASUREMENT problem, not a guest state -----------------
d=$(mk contra1 qrexec=SILENT c4=$((NOW-1380)) c1=1500 screen=NOWINDOW vmcs-activity=ACTIVE vmcs-rip-static=1 fraction=BLOCKED)
ck 'O9 says spinning but O2 says BLOCKED -> UNREADABLE-CPU, not a preference between them' \
   "$([ "$(cls "$d")" = UNREADABLE-CPU ] && echo 0 || echo 1)" "got $(cls "$d")"
d=$(mk contra2 qrexec=SILENT c4=$((NOW-1380)) c1=1500 screen=NOWINDOW vmcs-activity=HLT fraction=SPIN)
ck 'O9 says all HLT but O2 says SPIN -> UNREADABLE-CPU' \
   "$([ "$(cls "$d")" = UNREADABLE-CPU ] && echo 0 || echo 1)" "got $(cls "$d")"
d=$(mk advancing qrexec=SILENT c4=$((NOW-1380)) c1=1500 screen=NOWINDOW vmcs-activity=ACTIVE vmcs-rip-static=0)
ck 'Active with an ADVANCING RIP is not a spin and not idle -> UNREADABLE-CPU' \
   "$([ "$(cls "$d")" = UNREADABLE-CPU ] && echo 0 || echo 1)" "got $(cls "$d")"

# ---- 5. stage 1 is PURE: re-running it cannot change the answer ---------------------------------
d=$(mk pure qrexec=SILENT c4=$((NOW-1380)) c1=1500 screen=NOWINDOW vmcs-activity=HLT)
a=$(cls "$d"); b=$(cls "$d"); c=$(cls "$d")
ck 'stage 1 is a pure function: three runs over the same evidence give the same class' \
   "$([ "$a" = "$b" ] && [ "$b" = "$c" ] && echo 0 || echo 1)" "got $a/$b/$c"

# ---- 6. stage 2 is the ONLY intervention, and it decides the look-alike -------------------------
d=$(mk s2halt acpi-result=HALTED candidate=WEDGE-BLOCKED-CANDIDATE); wedge_stage2 "$d" >/dev/null
ck 'stage 2: an HONOURED ACPI ask means QREXEC-DEAD-ALIVE - a product failure, NOT a wedge' \
   "$([ "$WG_CLASS" = QREXEC-DEAD-ALIVE ] && echo 0 || echo 1)" "got $WG_CLASS"
d=$(mk s2no acpi-result=NOT-HALTED candidate=WEDGE-BLOCKED-CANDIDATE); wedge_stage2 "$d" >/dev/null
ck 'stage 2: an IGNORED ACPI ask on an HLT candidate means WEDGE-BLOCKED' \
   "$([ "$WG_CLASS" = WEDGE-BLOCKED ] && echo 0 || echo 1)" "got $WG_CLASS"
d=$(mk s2spin acpi-result=NOT-HALTED candidate=WEDGE-SPIN-CANDIDATE); wedge_stage2 "$d" >/dev/null
ck 'stage 2 preserves the SHAPE: a spinning candidate becomes WEDGE-SPIN, not WEDGE-BLOCKED' \
   "$([ "$WG_CLASS" = WEDGE-SPIN ] && echo 0 || echo 1)" "got $WG_CLASS"
d=$(mk s2nocand acpi-result=NOT-HALTED); wedge_stage2 "$d" >/dev/null
ck 'ACPI ignored with NO candidate does not default to BLOCKED' \
   "$([ "$WG_CLASS" = UNREADABLE-CPU ] && echo 0 || echo 1)" "got $WG_CLASS"
d=$(mk s2none); wedge_stage2 "$d" >/dev/null
ck 'stage 2 with no observation is UNREADABLE-CPU, never a wedge by default' \
   "$([ "$WG_CLASS" = UNREADABLE-CPU ] && echo 0 || echo 1)" "got $WG_CLASS"

# ---- 7. the kill is GATED on the record (Jev 0.76) ---------------------------------------------
d="$T/rec"; rm -rf "$d"; mkdir -p "$d"
WG_LINES=""
wedge_may_kill "$d" >/dev/null 2>&1; krc=$?
ck 'SEEN TO FAIL: a kill is REFUSED when the record is empty' \
   "$(wedge_may_kill "$d" >/dev/null 2>&1 && echo 1 || echo 0)" 'an empty record must not permit a kill'
ck '...and the refusal NAMES what is missing' \
   "$(printf '%s' "$WG_LINES" | grep -q 'missing:' && echo 0 || echo 1)" "$WG_LINES"
for f in class.txt why.txt listing.txt vmcs.txt vcpu-samples.txt screen.txt harness.txt; do printf 'x\n' > "$d/$f"; done
WG_LINES=""
ck 'a COMPLETE required record permits the kill' \
   "$(wedge_may_kill "$d" >/dev/null 2>&1 && echo 0 || echo 1)" "$WG_LINES"
rm -f "$d/vmcs.txt"; WG_LINES=""
wedge_may_kill "$d" >/dev/null 2>&1; krc=$?
ck '...and removing ONE required item refuses it again, naming that item' \
   "$([ "$krc" -ne 0 ] && printf '%s' "$WG_LINES" | grep -q 'vmcs.txt' && echo 0 || echo 1)" "$WG_LINES"
printf 'x\n' > "$d/vmcs.txt"; printf 'absent: first boot, no onstart task existed\n' > "$d/module-bases.MISSING"
WG_LINES=""
ck 'a missing BEST-EFFORT item (module bases) does NOT block the kill' \
   "$(wedge_may_kill "$d" >/dev/null 2>&1 && echo 0 || echo 1)" "$WG_LINES"

# ---- 8. the abort gate: one implementation, every caller stops ---------------------------------
for c in WEDGE-SPIN WEDGE-BLOCKED RECOVERY UNREADABLE-CPU UNREADABLE-SCREEN RESTART-UNEXPLAINED UNRESPONSIVE-WITH-PIXELS QREXEC-DEAD-ALIVE; do
  WG_LINES=""
  ck "the abort gate STOPS the caller on $c" \
     "$(wedge_fatal_gate "$c" test >/dev/null 2>&1 && echo 1 || echo 0)" "$WG_LINES"
done
for c in ALIVE BOOTING SHUTTING-DOWN ALIVE-RECENT INSTRUMENT-FAILURE DOMAIN-GONE QREXEC-QUEUE-RESTART; do
  ck "the abort gate lets the caller continue on $c" \
     "$(wedge_fatal_gate "$c" test >/dev/null 2>&1 && echo 0 || echo 1)" "class $c must not be fatal"
done
WG_LINES=""
for c in WEDGE-SPIN-CANDIDATE WEDGE-BLOCKED-CANDIDATE; do
  WG_LINES=""
  ck "$c stops the caller too - undecided is not permission" \
     "$(wedge_fatal_gate "$c" test >/dev/null 2>&1 && echo 1 || echo 0)" "$WG_LINES"
done
WG_LINES=""; wedge_fatal_gate WEDGE-SPIN test >/dev/null 2>&1
ck '...and a wedge class says the record is MANDATORY before any kill' \
   "$(printf '%s' "$WG_LINES" | grep -qi 'record is MANDATORY' && echo 0 || echo 1)" "$WG_LINES"

# ---- 9. dispositions are stated in ONE place --------------------------------------------------
ck 'a wedge is dispositioned fatal AND wedge' \
   "$([ "$(wedge_disposition WEDGE-BLOCKED)" = "fatal wedge" ] && echo 0 || echo 1)" "$(wedge_disposition WEDGE-BLOCKED)"
ck 'the look-alike is dispositioned a PRODUCT failure, not a wedge' \
   "$([ "$(wedge_disposition QREXEC-DEAD-ALIVE)" = "fatal product" ] && echo 0 || echo 1)" "$(wedge_disposition QREXEC-DEAD-ALIVE)"
ck 'instrument failure is NEVER a product failure' \
   "$([ "$(wedge_disposition INSTRUMENT-FAILURE)" = neither ] && echo 0 || echo 1)" "$(wedge_disposition INSTRUMENT-FAILURE)"
ck 'an unknown class is reported unknown rather than treated as ok' \
   "$([ "$(wedge_disposition NOT-A-CLASS)" = unknown ] && echo 0 || echo 1)" "$(wedge_disposition NOT-A-CLASS)"

# ---- 10. IS IT WIRED? The defect this library exists to fix was unwired machinery ------------
# collect-failure.sh, wedge-lib.sh, fetch-wedge-core.sh, wedge-hunt.sh and verdict-jev.py all
# existed on 2026-10-22 and NONE of them was invoked. A classifier nobody calls is exactly what we
# already had, so the call sites are asserted here, not assumed.
RA="$ROOT/tools/release-acceptance.sh"
ck 'release-acceptance.sh SOURCES the shared library' \
   "$(grep -q 'wedge-gates-lib.sh' "$RA" && echo 0 || echo 1)" 'an unwired classifier is the defect, not the fix'
# ANCHOR ON THE LOOP, not on the flag: SKIP_FEATURES is declared at line 41 and parsed at 69, so
# "the first SKIP_FEATURES" is nowhere near the feature-test block and the first draft of this leg
# failed on correct wiring. The loop over release-feature-tests.txt is the block itself.
ck 'it stops on the matrix ABORTED tally BEFORE the feature-test loop' \
   "$(awk '/grep -qaE .=== MATRIX: .* ABORTED/{a=NR} /release-feature-tests\.txt/{if(!f)f=NR} END{exit !(a&&f&&a<f)}' "$RA" && echo 0 || echo 1)" \
   'the abort check must precede the loop over release-feature-tests.txt - that order is the 2026-10-22 defect'
ck 'the kill is gated on wedge_may_kill, not on a bare shutdown rc' \
   "$(grep -q 'wedge_may_kill' "$RA" && echo 0 || echo 1)" 'a kill destroys the only live state there is'
ck 'it classifies BEFORE it kills' \
   "$(awk '/wedge_collect/{c=NR} /qvm-kill/{if(!k)k=NR} END{exit !(c&&k&&c<k)}' "$RA" && echo 0 || echo 1)" \
   'wedge_collect must appear before the first qvm-kill in the settle path'
ck 'a wedge specimen is LEFT UP rather than killed' \
   "$(grep -q 'LEAVING IT UP' "$RA" && echo 0 || echo 1)" 'the specimen is the only evidence a wedge leaves'

say ''
say "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
