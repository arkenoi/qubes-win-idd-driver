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
# THE FIXTURES ARE THE TWO REAL SPECIMENS, and one of them is the reason the tree was rebuilt:
# "as-captured" holds exactly what the campaign actually recorded for the wedged guest - and that
# contains NO VMCS section, because nothing captured one. The FIRST tree answered UNREADABLE-CPU on
# it, i.e. not a wedge, i.e. killable: the weakest instrument deleting a finding that the two strong
# conjuncts had already established. Owner, 2026-10-22: "CPU is weak indicator. we have strong
# ones." So that fixture is now a WEDGE-CANDIDATE whose SHAPE is unknown, and the "with-record"
# fixture - the VMCS the new record takes BEFORE any kill - buys the spin site, not the verdict.
# The decisive conjunct is the ACPI ask, driven as a return-code table in section 11.
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
ck 'the TRUE WEDGE, with only the evidence ACTUALLY captured, is a WEDGE-CANDIDATE' \
   "$([ "$(cls "$d")" = WEDGE-CANDIDATE ] && echo 0 || echo 1)" "got $(cls "$d")"
# THIS LEG IS THE OWNER'S CORRECTION, ON THE REAL SUBJECT. This fixture is the 2026-10-22 guest with
# exactly what was captured from it - and NO VMCS was ever taken, so the CPU reading is absent. The
# first draft of the tree answered UNREADABLE-CPU here: the only wedge this project has ever held,
# classified as a measurement problem, hence not a wedge, hence killable. Candidacy now rests on the
# conjuncts that were measured; the missing CPU reading costs the SHAPE and nothing else.
ck '...with the shape UNKNOWN, which is what the absent VMCS actually costs us' \
   "$(cls "$d" >/dev/null; [ "$(cat "$d/shape")" = UNKNOWN ] && echo 0 || echo 1)" "shape=$(cat "$d/shape" 2>/dev/null)"
ck '...and it is PRESERVED, because the conjunct that decides is still unmeasured' \
   "$(wedge_must_preserve "$(cls "$d")" && echo 0 || echo 1)" 'a candidate is never killable'
# IN THE CURRENT SHELL, never inside $( ): a command substitution is a SUBSHELL, so WG_WHY and
# WG_LINES set by the function never reach the assertion. Three legs failed on exactly that.
wedge_stage1 "$d" >/dev/null
ck '...and it says the decisive observable was absent rather than guessing a class' \
   "$(printf '%s' "$WG_WHY" | grep -q 'absent' && echo 0 || echo 1)" "why: $WG_WHY"

# the same guest, with the record the new design takes BEFORE any kill
d=$(mk wedge-spin qrexec=SILENT c4=$((NOW-1380)) c1=1500 screen=NOWINDOW \
       vmcs-activity=ACTIVE vmcs-rip-static=1 fraction=SPIN)
ck 'the SAME guest, once the VMCS is in the record, is a WEDGE-CANDIDATE shaped SPIN' \
   "$([ "$(cls "$d")" = WEDGE-CANDIDATE ] && echo 0 || echo 1)" "got $(cls "$d")"
ck '...and NOW the shape is SPIN - the VMCS buys the spin site, not the verdict' \
   "$(cls "$d" >/dev/null; [ "$(cat "$d/shape")" = SPIN ] && echo 0 || echo 1)" "shape=$(cat "$d/shape" 2>/dev/null)"
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
   "$([ "$(cls "$d")" = WEDGE-CANDIDATE ] && echo 0 || echo 1)" "got $(cls "$d")"

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
ck 'every vCPU HLT is a WEDGE-CANDIDATE - stage 1 refuses to decide without the ACPI ask' \
   "$([ "$(cls "$d")" = WEDGE-CANDIDATE ] && echo 0 || echo 1)" "got $(cls "$d")"
ck '...and the HLT reading is carried as the SHAPE, a label on the candidate' \
   "$(cls "$d" >/dev/null; [ "$(cat "$d/shape")" = BLOCKED ] && echo 0 || echo 1)" "shape=$(cat "$d/shape" 2>/dev/null)"

# ---- 3. THE TOTALITY GAP that draft 2 had ------------------------------------------------------
# A guest that boots, ANSWERS, then dies INSIDE its boot bound matched no rule at all in draft 2.
d=$(mk gap qrexec=SILENT c1=200 c4=$((NOW-200)) screen=NOWINDOW vmcs-activity=HLT)
got=$(cls "$d")
ck 'SEEN TO FAIL in draft 2: answered then died INSIDE the boot bound still gets a class' \
   "$([ -n "$got" ] && [ "$got" != BOOTING ] && echo 0 || echo 1)" "got '$got' (draft 2 fell through every rule)"

# ---- 4. a CPU reading may never VETO candidacy; it only names the shape ------------------------
# Owner, 2026-10-22: "CPU is weak indicator. we have strong ones." The first draft let an unreadable
# or self-contradicting CPU picture produce UNREADABLE-CPU, which is NOT a wedge - so the weakest
# instrument could delete a finding established by the two strong conjuncts already proven above it.
# Each fixture below has present + no pixels + long qrexec silence, so each MUST stay a candidate,
# and only `shape` may go UNKNOWN.
for f in "contra1 vmcs-activity=ACTIVE vmcs-rip-static=1 fraction=BLOCKED|O9 spinning vs O2 BLOCKED" \
         "contra2 vmcs-activity=HLT fraction=SPIN|O9 all-HLT vs O2 SPIN" \
         "advancing vmcs-activity=ACTIVE vmcs-rip-static=0|Active with an ADVANCING RIP" \
         "nocpu |no CPU reading at all - the 2026-10-22 specimen as actually captured"; do
  spec=${f%%|*}; desc=${f##*|}
  # shellcheck disable=SC2086
  d=$(mk $spec qrexec=SILENT c4=$((NOW-1380)) c1=1500 screen=NOWINDOW)
  ck "$desc still leaves a WEDGE-CANDIDATE - the weak instrument cannot veto" \
     "$([ "$(cls "$d")" = WEDGE-CANDIDATE ] && echo 0 || echo 1)" "got $(cls "$d")"
  ck "...and it is the SHAPE that goes UNKNOWN, not the candidacy" \
     "$(cls "$d" >/dev/null; [ "$(cat "$d/shape")" = UNKNOWN ] && echo 0 || echo 1)" "shape=$(cat "$d/shape" 2>/dev/null)"
done

# ---- 5. stage 1 is PURE: re-running it cannot change the answer ---------------------------------
d=$(mk pure qrexec=SILENT c4=$((NOW-1380)) c1=1500 screen=NOWINDOW vmcs-activity=HLT)
a=$(cls "$d"); b=$(cls "$d"); c=$(cls "$d")
ck 'stage 1 is a pure function: three runs over the same evidence give the same class' \
   "$([ "$a" = "$b" ] && [ "$b" = "$c" ] && echo 0 || echo 1)" "got $a/$b/$c"

# ---- 6. stage 2 is the ONLY intervention, and it decides the look-alike -------------------------
d=$(mk s2halt acpi-result=HALTED shape=BLOCKED); wedge_stage2 "$d" >/dev/null
ck 'stage 2: an HONOURED ACPI ask means QREXEC-DEAD-ALIVE - a product failure, NOT a wedge' \
   "$([ "$WG_CLASS" = QREXEC-DEAD-ALIVE ] && echo 0 || echo 1)" "got $WG_CLASS"
d=$(mk s2no acpi-result=NOT-HALTED shape=BLOCKED); wedge_stage2 "$d" >/dev/null
ck 'stage 2: an IGNORED ACPI ask on an HLT candidate means WEDGE-BLOCKED' \
   "$([ "$WG_CLASS" = WEDGE-BLOCKED ] && echo 0 || echo 1)" "got $WG_CLASS"
d=$(mk s2spin acpi-result=NOT-HALTED shape=SPIN); wedge_stage2 "$d" >/dev/null
ck 'stage 2 preserves the SHAPE: a spinning candidate becomes WEDGE-SPIN, not WEDGE-BLOCKED' \
   "$([ "$WG_CLASS" = WEDGE-SPIN ] && echo 0 || echo 1)" "got $WG_CLASS"
# THE LEG THE OWNER'S CORRECTION TURNS ON. ACPI ignored is the decisive conjunct, so an unknown
# shape still yields a WEDGE - it costs us the spin site, not the finding. Under the first draft this
# was UNREADABLE-CPU, i.e. not a wedge at all, which is how the ONE specimen this project has ever
# held (captured with no VMCS) would have been classified as a measurement problem and thrown away.
d=$(mk s2noshape acpi-result=NOT-HALTED); wedge_stage2 "$d" >/dev/null
ck 'ACPI ignored with NO shape is still a WEDGE (unknown shape), never a non-wedge' \
   "$([ "$WG_CLASS" = WEDGE-UNKNOWN-SHAPE ] && echo 0 || echo 1)" "got $WG_CLASS"
ck '...and that class is dispositioned a wedge, so the record is mandatory' \
   "$([ "$(wedge_disposition WEDGE-UNKNOWN-SHAPE)" = "fatal wedge" ] && echo 0 || echo 1)" "$(wedge_disposition WEDGE-UNKNOWN-SHAPE)"
# A REBOOT ACROSS THE ASK IS THE EXCLUDED LOOK-ALIKE, by the owner's own words.
d=$(mk s2reboot acpi-result=REBOOTED shape=SPIN); wedge_stage2 "$d" >/dev/null
ck 'a guest that REBOOTED across the ask is NOT a wedge, however it was spinning' \
   "$([ "$WG_CLASS" = RESTART-UNEXPLAINED ] && echo 0 || echo 1)" "got $WG_CLASS"
ck '...and it is still FATAL - not a wedge is not the same as not a failure' \
   "$(wedge_is_fatal RESTART-UNEXPLAINED && echo 0 || echo 1)" 'owner: failures other than wedge may still be fatal'
d=$(mk s2none); wedge_stage2 "$d" >/dev/null
ck 'stage 2 with NO ACPI observation is UNREADABLE-ACPI - the decisive conjunct is unmeasured' \
   "$([ "$WG_CLASS" = UNREADABLE-ACPI ] && echo 0 || echo 1)" "got $WG_CLASS"
ck '...and an unmeasured ACPI conjunct preserves the guest rather than clearing or killing it' \
   "$(wedge_must_preserve UNREADABLE-ACPI && echo 0 || echo 1)" 'neither cleared nor called a wedge'

# ---- 7. the kill is GATED ON THE ANTECEDENT ---------------------------------------------------
# REWRITTEN 2026-10-22. The gate used to ask "is this class safe to destroy"; it now asks "do we
# already hold what we wanted from this guest". The owner: "we have enough register dumps so i do
# not think we are interested in 'where it stuck' anymore. the question we need answer to is 'what
# did it do right before'... So preservation per se makes little sense" and "that why stick may be
# more important than dump". Jev against the counted evidence inventory: antecedent_call_ledger 0.75
# as the next instrument, kill_once_the_stick_is_in_hand 0.42 + hold_only_when_unreadable 0.28 =
# 0.70 for killing CONDITIONAL on the antecedent, dump_is_still_primary 0.02.
#
# The stick reads on the HOST while the guest is still wedged (logvol-lib.sh: "no detach, no
# unmount, no guest"), so the normal case is that we have it before anything dies.
stick(){ # <status> [files] - fake a pulled/unreadable stick in a record dir
  local sd="$1" st="$2"; printf '%s\n' "$st" > "$sd/logvol-status"
  if [ "$st" = pulled ]; then mkdir -p "$sd/logvol/files"
    printf 'image=x\nread_utc=now\nfiles=3\n' > "$sd/logvol/pull.txt"; fi
}
d="$T/rec"; rm -rf "$d"; mkdir -p "$d"
WG_LINES=""; wedge_may_kill "$d" >/dev/null 2>&1; krc=$?
ck 'SEEN TO FAIL: a kill is REFUSED when nothing at all was recorded' \
   "$([ "$krc" -ne 0 ] && echo 0 || echo 1)" 'an empty record must not permit a kill'
ck '...and an empty record refuses for want of a CLASS, before anything else' \
   "$(printf '%s' "$WG_LINES" | grep -q 'no class was recorded' && echo 0 || echo 1)" "$WG_LINES"
printf 'WEDGE-SPIN\n' > "$d/class.txt"
for f in why.txt listing.txt screen.txt harness.txt; do printf 'x\n' > "$d/$f"; done
WG_LINES=""; wedge_may_kill "$d" "" >/dev/null 2>&1; krc=$?
ck 'SEEN TO FAIL: a complete record with NO antecedent still refuses' \
   "$([ "$krc" -ne 0 ] && echo 0 || echo 1)" "$WG_LINES"
ck '...and the refusal names the ANTECEDENT as the thing missing, not the class' \
   "$(printf '%s' "$WG_LINES" | grep -q 'ANTECEDENT was not captured' && echo 0 || echo 1)" "$WG_LINES"
stick "$d" unreadable; WG_LINES=""; wedge_may_kill "$d" "" >/dev/null 2>&1; krc=$?
ck 'an UNREADABLE stick refuses too - that is the one case holding the guest still buys something' \
   "$([ "$krc" -ne 0 ] && echo 0 || echo 1)" "$WG_LINES"
# IN THE CURRENT SHELL, so WG_LINES survives for the assertion after it (the $( ) subshell trap
# noted at the top of this file - it has cost four legs in this file alone).
stick "$d" pulled; WG_LINES=""
wedge_may_kill "$d" "" >/dev/null 2>&1; krc=$?
ck 'ONCE THE STICK IS IN HAND the kill is permitted, even on a WEDGE-SPIN' \
   "$([ "$krc" -eq 0 ] && echo 0 || echo 1)" "$WG_LINES"
ck '...and the reason says the guest is expendable BECAUSE the stick was read' \
   "$(printf '%s' "$WG_LINES" | grep -q 'BECAUSE the stick was read' && echo 0 || echo 1)" "$WG_LINES"
# THE INVERSION, ASSERTED BOTH WAYS. The register dump used to BLOCK a kill; it no longer does, and
# the stick now does. Jev did not concede that dumps are sufficient (0.28), so they stay collected -
# they just do not hold a guest hostage.
rm -f "$d/vmcs.txt" "$d/vcpu-samples.txt"; WG_LINES=""
ck 'a MISSING REGISTER DUMP no longer blocks the kill - it is best-effort now' \
   "$(wedge_may_kill "$d" "" >/dev/null 2>&1 && echo 0 || echo 1)" "$WG_LINES"
ck '...and the dump is still named in the BEST-EFFORT tier, not silently dropped' \
   "$(printf '%s' "$WG_RECORD_BESTEFFORT" | grep -q 'vmcs.txt' && echo 0 || echo 1)" "$WG_RECORD_BESTEFFORT"
ck '...while the dump is NOT in the required tier any more' \
   "$(printf '%s' "$WG_RECORD_REQUIRED" | grep -q 'vmcs' && echo 1 || echo 0)" "$WG_RECORD_REQUIRED"
rm -f "$d/screen.txt"; WG_LINES=""; wedge_may_kill "$d" "" >/dev/null 2>&1; krc=$?
ck 'a missing REQUIRED item still refuses, naming it' \
   "$([ "$krc" -ne 0 ] && printf '%s' "$WG_LINES" | grep -q 'screen.txt' && echo 0 || echo 1)" "$WG_LINES"
printf 'x\n' > "$d/screen.txt"
# A caller may DECLARE that this cell ran with no stick. That is a statement, not a gap.
rm -rf "$d/logvol"; printf 'declared-none\n' > "$d/logvol-status"; WG_LINES=""
ck 'a caller DECLARING no stick permits the kill; "unreadable" did not' \
   "$(wedge_may_kill "$d" "" >/dev/null 2>&1 && echo 0 || echo 1)" "$WG_LINES"
# DOMAIN-GONE needs no antecedent: there is no domain to collect one from.
printf 'DOMAIN-GONE\n' > "$d/class.txt"; printf 'absent\n' > "$d/logvol-status"; WG_LINES=""
ck 'DOMAIN-GONE is killable with no antecedent - nothing exists to collect' \
   "$(wedge_may_kill "$d" "" >/dev/null 2>&1 && echo 0 || echo 1)" "$WG_LINES"
# QREXEC-DEAD-ALIVE still has to carry the ACPI observation that defines it.
printf 'QREXEC-DEAD-ALIVE\n' > "$d/class.txt"; stick "$d" pulled
rm -f "$d/acpi-result" "$d/acpi-why" "$d/acpi-rc"; WG_LINES=""
wedge_may_kill "$d" "" >/dev/null 2>&1; krc=$?
ck 'SEEN TO FAIL: QREXEC-DEAD-ALIVE with the stick but NO ACPI observation is refused' \
   "$([ "$krc" -ne 0 ] && printf '%s' "$WG_LINES" | grep -q 'acpi-result' && echo 0 || echo 1)" "$WG_LINES"
for f in acpi-result acpi-why acpi-rc; do printf 'x\n' > "$d/$f"; done; WG_LINES=""
ck '...and with it, permitted' \
   "$(wedge_may_kill "$d" "" >/dev/null 2>&1 && echo 0 || echo 1)" "$WG_LINES"

# THE FOUR STICK OUTCOMES, and the one that matters is the difference between "a stick exists and
# could not be read" (holding buys a retry) and "no stick exists at all" (holding buys nothing).
# Conflating them is what would have held EVERY non-halting guest on the campaign path, because
# tools/release-acceptance.sh never set LOGVOL_IMG - Jev named runner_wiring as the regression risk
# at 0.50 and this is what it was.
for cse in "pulled|0|the antecedent is in hand" \
           "declared-none|0|the caller states this cell ran without a stick" \
           "no-stick|0|no stick exists for this guest, so holding cannot produce one" \
           "unreadable|1|a stick EXISTS and could not be read - holding buys a retry" \
           "absent|1|nothing recorded at all"; do
  st=${cse%%|*}; rest=${cse#*|}; want=${rest%%|*}; desc=${rest#*|}
  dd="$T/st-$st"; rm -rf "$dd"; mkdir -p "$dd"
  printf 'WEDGE-SPIN\n' > "$dd/class.txt"
  for f in why.txt listing.txt screen.txt harness.txt; do printf 'x\n' > "$dd/$f"; done
  [ "$st" = pulled ] && { mkdir -p "$dd/logvol/files"; printf 'files=3\n' > "$dd/logvol/pull.txt"; }
  printf '%s\n' "$st" > "$dd/logvol-status"
  WG_LINES=""; wedge_may_kill "$dd" "" >/dev/null 2>&1; krc=$?
  got=0; [ "$krc" -ne 0 ] && got=1
  ck "logvol-status=$st -> $([ "$want" = 0 ] && echo killable || echo HELD): $desc" \
     "$([ "$got" = "$want" ] && echo 0 || echo 1)" "$WG_LINES"
done
# AND A PULLED STATUS WITH NO RECEIPT IS NOT A PULL. The status file alone must not buy a kill.
dd="$T/st-lying"; rm -rf "$dd"; mkdir -p "$dd"
printf 'WEDGE-SPIN\n' > "$dd/class.txt"
for f in why.txt listing.txt screen.txt harness.txt; do printf 'x\n' > "$dd/$f"; done
printf 'pulled\n' > "$dd/logvol-status"
WG_LINES=""; wedge_may_kill "$dd" "" >/dev/null 2>&1; krc=$?
ck 'SEEN TO FAIL: logvol-status=pulled with NO pull receipt does not buy a kill' \
   "$([ "$krc" -ne 0 ] && echo 0 || echo 1)" "$WG_LINES"
# THE COLLECTOR DERIVES THE IMAGE ITSELF rather than trusting the caller to have exported it.
ck 'the collector derives the stick image per guest when the caller did not set it' \
   "$(grep -q 'logvol_image "$vm"' "$LIB" && echo 0 || echo 1)" \
   'matrix.sh and quick-upgrade.sh set LOGVOL_IMG; the acceptance runner never did'
# CALL SITES ONLY. The observable list at the top of the library NAMES WinWedgeForensics in a
# comment, hundreds of lines above any call, so an unfiltered line-order test compares a comment
# with a call and fails on correct code.
ck '...and it pulls the stick BEFORE the heavy forensics, not after' \
   "$(grep -nv '^[[:space:]]*#' "$LIB" | awk -F: '/logvol_pull/{if(!p)p=$1} /WinWedgeForensics/{if(!f)f=$1} END{exit !(p&&f&&p<f)}' && echo 0 || echo 1)" \
   'the antecedent is the thing we came for; the dump is best-effort'
# THE EXPENSIVE HALF IS SEPARATE AND CONDITIONAL. Two 300s-bounded captures per guest, in a loop
# over every guest that did not halt, for data that is now best-effort only - Jev named this as the
# one thing to fix before landing (collect_is_slow_in_the_settle_loop 0.47, blocking 0.61).
# NON-COMMENT LINES ONLY: the cheap collector EXPLAINS in a comment why it does not take the dump,
# and a leg that greps the whole body finds that explanation and calls it a call.
ck 'the cheap collector does NOT take the hypervisor dump' \
   "$(sed -n "/^wedge_collect()/,/^}/p" "$LIB" | grep -v '^[[:space:]]*#' | grep -q 'WinWedgeForensics' && echo 1 || echo 0)" \
   'the settle loop must not pay 2x300s per guest for a shape label'
ck '...the dump lives in its own function' \
   "$(grep -q '^wedge_collect_dump()' "$LIB" && echo 0 || echo 1)" 'split 2026-10-22'
ck '...and the cheap collector still pulls the STICK, which is the required half' \
   "$(sed -n "/^wedge_collect()/,/^}/p" "$LIB" | grep -q 'logvol_pull' && echo 0 || echo 1)" \
   'the antecedent is required; the dump is not'
ck 'the runner takes the dump ONLY for an undecided class, and re-runs stage 1 after it' \
   "$(grep -nv '^[[:space:]]*#' "$ROOT/tools/release-acceptance.sh" | awk -F: '/= undecided/{if(!u)u=$1} /wedge_collect_dump/{if(!d)d=$1} END{exit !(u&&d&&u<d)}' && echo 0 || echo 1)" \
   'a wedge candidate is the only case where the shape is worth 600s'
ck '...and it also salvages the TAIL, which is the last thing the guest did' \
   "$(grep -q 'logvol_salvage' "$LIB" && echo 0 || echo 1)" \
   'mcopy stops at the recorded size; the final lines are past it'

# ---- 7b. EVERY failing class is killable with the stick, and NONE without it ------------------
for c in WEDGE-SPIN WEDGE-BLOCKED WEDGE-UNKNOWN-SHAPE WEDGE-CANDIDATE UNREADABLE-CPU \
         UNREADABLE-ACPI UNREADABLE-SCREEN RESTART-UNEXPLAINED UNRESPONSIVE-WITH-PIXELS \
         RECOVERY NOT-A-CLASS-AT-ALL; do
  dd="$T/ant-$c"; rm -rf "$dd"; mkdir -p "$dd"
  printf '%s\n' "$c" > "$dd/class.txt"
  for f in why.txt listing.txt screen.txt harness.txt; do printf 'x\n' > "$dd/$f"; done
  printf 'absent\n' > "$dd/logvol-status"
  WG_LINES=""; wedge_may_kill "$dd" "" >/dev/null 2>&1; krc=$?
  ck "without the stick, $c is PRESERVED" "$([ "$krc" -ne 0 ] && echo 0 || echo 1)" "$WG_LINES"
  ck "...and wedge_must_preserve agrees, reading the record" \
     "$(wedge_must_preserve "$c" "$dd" && echo 0 || echo 1)" "$c with no antecedent must be held"
  stick "$dd" pulled; WG_LINES=""
  ck "with the stick, $c is killable - the rig is not held for a dump" \
     "$(wedge_may_kill "$dd" "" >/dev/null 2>&1 && echo 0 || echo 1)" "$WG_LINES"
  ck "...and wedge_must_preserve agrees there is nothing left to hold it for" \
     "$(wedge_must_preserve "$c" "$dd" && echo 1 || echo 0)" "$c with the antecedent in hand"
done
# WITH NO RECORD AT ALL, a failing class still says HOLD - that is what the campaign's stop message
# has to go on before any record exists.
ck 'a failing class with NO record at all defaults to HOLD' \
   "$(wedge_must_preserve WEDGE-SPIN && echo 0 || echo 1)" 'no record yet means hold until there is one'
ck 'a non-failing class never asks to be held' \
   "$(wedge_must_preserve ALIVE && echo 1 || echo 0)" 'nothing failed'

# ---- 7c. FATAL and HOLD are INDEPENDENT axes (owner: "failures other than wedge may still be
# fatal"). The fatal axis is unchanged by the antecedent reframing: a wedge still stops the run even
# though the guest is now killable once the stick is read.
for c in WEDGE-SPIN WEDGE-BLOCKED WEDGE-UNKNOWN-SHAPE RECOVERY UNREADABLE-CPU UNREADABLE-ACPI \
         UNREADABLE-SCREEN RESTART-UNEXPLAINED UNRESPONSIVE-WITH-PIXELS QREXEC-DEAD-ALIVE; do
  ck "FATAL axis: $c stops the campaign" \
     "$(wedge_is_fatal "$c" && echo 0 || echo 1)" "$c must be fatal whether or not it is a wedge"
done
for c in ALIVE BOOTING SHUTTING-DOWN ALIVE-RECENT QREXEC-QUEUE-RESTART DOMAIN-GONE INSTRUMENT-FAILURE; do
  ck "FATAL axis: $c does NOT stop the campaign" \
     "$(wedge_is_fatal "$c" && echo 1 || echo 0)" "$c is not a failure of the product"
done
dd="$T/axes"; rm -rf "$dd"; mkdir -p "$dd"; stick "$dd" pulled
ck 'the axes are INDEPENDENT: a WEDGE with the stick read is FATAL but NOT held' \
   "$(wedge_is_fatal WEDGE-SPIN && ! wedge_must_preserve WEDGE-SPIN "$dd" && echo 0 || echo 1)" \
   'the run stops; the guest does not have to live for it'
printf 'unreadable\n' > "$dd/logvol-status"
ck '...and the SAME class with no stick is FATAL and held' \
   "$(wedge_is_fatal WEDGE-SPIN && wedge_must_preserve WEDGE-SPIN "$dd" && echo 0 || echo 1)" \
   'holding buys another chance at the antecedent, and only that'
ck 'the axes are INDEPENDENT: BOOTING is neither fatal nor held' \
   "$(! wedge_is_fatal BOOTING && ! wedge_must_preserve BOOTING && echo 0 || echo 1)" 'nothing has failed yet'

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
ck 'a guest whose ANTECEDENT was not captured is LEFT UP, and the runner records which one holds the rig' \
   "$(grep -qE 'HOLDING \$vm' "$RA" && grep -q 'specimen-held' "$RA" && echo 0 || echo 1)" \
   'the specimen is the only evidence a wedge leaves'
ck '...and the held-specimen check runs BEFORE the feature-test loop, not after it' \
   "$(awk '/specimen-held/{if(!h)h=NR} /release-feature-tests\.txt/{if(!f)f=NR} END{exit !(h&&f&&h<f)}' "$RA" && echo 0 || echo 1)" \
   'a preserved specimen occupies the rig: every later cell would be refused with "these are not Halted"'
# THE ACPI RC, KEPT. `if ! qwt_shutdown` collapsed four measured meanings into a boolean on the one
# path where a wedge is decided - the strongest indicator, measured and discarded.
ck 'the settle path KEEPS the ACPI return code instead of collapsing it to a boolean' \
   "$(grep -q 'qwt_shutdown "\$vm" 600; _src=\$?' "$RA" && echo 0 || echo 1)" \
   'owner: "can we RELIABLY detect ACPI is not responding? it is the main one"'
ck '...and feeds it to the ONE mapping, with a host-side session id sampled BEFORE the ask' \
   "$(awk '/_x0=\$\(_wg_xid/{x=NR} /qwt_shutdown "\$vm" 600/{s=NR} /wedge_acpi_record/{r=NR} END{exit !(x&&s&&r&&x<s&&s<r)}' "$RA" && echo 0 || echo 1)" \
   'the domid must be sampled before the ask or it cannot witness a reboot across it'
ck '...and stage 2 runs on an UNDECIDED stage-1 class, so the third conjunct is actually asked' \
   "$(grep -q 'wedge_stage2' "$RA" && echo 0 || echo 1)" 'a candidate that never reaches stage 2 is never a wedge'

# ---- 11. THE ACPI MAPPING, driven offline -----------------------------------------------------
# "can we RELIABLY detect 'ACPI is not responding'? it is the main one" (owner, 2026-10-22). The
# answer is a return-code table, so the table is tested rather than described. _wg_xid and _wg_state
# are shell FUNCTIONS called directly by wedge_acpi_record, so overriding them here substitutes the
# host reading without touching a guest. (A stub only works because nothing here is exec'd through
# `timeout` - that distinction cost a day on 2026-10-21.)
acpi_case(){ # <rc> <xid-before> <xid-after> <state-after> -> the recorded verdict
  # TWO statements, not one: under `set -u` bash evaluates every RHS of a single `local`
  # before binding any of them, so "$rc" in dd= is an unbound variable. Caught here 2026-10-22.
  local rc="$1" x0="$2" x1="$3" st="$4"
  local dd="$T/acpi-$rc-${x0:-e}-${x1:-e}-$st"
  rm -rf "$dd"; mkdir -p "$dd"
  # DISTINCT NAMES, and this is not cosmetic: wedge_acpi_record declares its OWN `local x1`, so a
  # stub reading "$x1" resolves to the callee's empty local under dynamic scoping, not to this
  # function's. Both rc=3 legs - the wedge path itself - silently read an absent domid that way.
  WG_STUB_XID="$x1"; WG_STUB_STATE="$st"
  _wg_xid(){ printf '%s\n' "$WG_STUB_XID"; }; _wg_state(){ printf '%s\n' "$WG_STUB_STATE"; }
  # A NOT-HALTED verdict verifies that the request can actually be DELIVERED, so these legs must
  # supply a request that succeeds - otherwise every one of them measures the absence of a
  # qvm-shutdown in the test environment instead of the mapping under test. The stub is a real
  # executable on PATH because the call goes through `timeout`, which EXECs.
  mkdir -p "$dd/bin"; printf '#!/bin/sh\nexit 0\n' > "$dd/bin/qvm-shutdown"; chmod +x "$dd/bin/qvm-shutdown"
  ( PATH="$dd/bin:$PATH"; wedge_acpi_record "$dd" "$rc" "$x0" somevm 600 >/dev/null 2>&1 )
  unset -f _wg_xid _wg_state
  cat "$dd/acpi-result" 2>/dev/null
}
ck 'rc=0 (halted on its own) is HALTED - ACPI was honoured' \
   "$([ "$(acpi_case 0 17891 '' Halted)" = HALTED ] && echo 0 || echo 1)" "got $(acpi_case 0 17891 '' Halted)"
ck 'rc=1 (same session by the GUEST clock) is NOT-HALTED - the strongest form' \
   "$([ "$(acpi_case 1 17891 17891 Running)" = NOT-HALTED ] && echo 0 || echo 1)" "got $(acpi_case 1 17891 17891 Running)"
ck 'rc=2 (the guest rebooted) is REBOOTED, never a wedge' \
   "$([ "$(acpi_case 2 17891 17902 Running)" = REBOOTED ] && echo 0 || echo 1)" "got $(acpi_case 2 17891 17902 Running)"
ck 'rc=4 (the rig could not be read) is UNREADABLE, never a guest state' \
   "$([ "$(acpi_case 4 17891 17891 Running)" = UNREADABLE ] && echo 0 || echo 1)" "got $(acpi_case 4 17891 17891 Running)"
# rc=3 IS THE WEDGE PATH, and it is the whole reason the domid is sampled. qwt_shutdown decides
# "same session" from the GUEST'S OWN boot time - one qrexec call - so a wedge, having no qrexec,
# returns 3 and NOT 1 by construction. Taking 3 as "ignored" would be the fabrication shutdown-lib's
# own header warns against; taking it as unknown forever would mean a wedge can never be detected.
# The host-side domid settles it without the guest.
ck 'rc=3 with the domid UNCHANGED and still Running is NOT-HALTED - the wedge path' \
   "$([ "$(acpi_case 3 17891 17891 Running)" = NOT-HALTED ] && echo 0 || echo 1)" "got $(acpi_case 3 17891 17891 Running)"
ck 'rc=3 with the domid MOVED is REBOOTED - the excluded look-alike, caught host-side' \
   "$([ "$(acpi_case 3 17891 17902 Running)" = REBOOTED ] && echo 0 || echo 1)" "got $(acpi_case 3 17891 17902 Running)"
ck 'rc=3 with NO domid either side is UNREADABLE - not named from neither side' \
   "$([ "$(acpi_case 3 '' '' Running)" = UNREADABLE ] && echo 0 || echo 1)" "got $(acpi_case 3 '' '' Running)"
ck 'rc=3 with a post-ask state that is neither Running nor Halted is UNREADABLE' \
   "$([ "$(acpi_case 3 17891 17891 Transient)" = UNREADABLE ] && echo 0 || echo 1)" "got $(acpi_case 3 17891 17891 Transient)"
# THE DELIVERY CHECK. Jev put the last unhandled confound in this predicate at "nothing verifies
# the request reached the guest" (0.50): a toolstack refusal looks exactly like a guest ignoring the
# ask, and "ignored ACPI" is the conjunct that makes a wedge. So a NOT-HALTED verdict re-issues the
# request and keeps its status; a refused request downgrades the verdict to UNREADABLE.
deliv(){ # <qvm-shutdown rc for the re-ask> -> recorded verdict
  local sd="$T/deliv-$1"; rm -rf "$sd"; mkdir -p "$sd"
  WG_STUB_XID=17891; WG_STUB_STATE=Running
  _wg_xid(){ printf '%s\n' "$WG_STUB_XID"; }; _wg_state(){ printf '%s\n' "$WG_STUB_STATE"; }
  # Stub the REQUEST, not the classifier: a fake qvm-shutdown earlier on PATH, so the code under
  # test runs unchanged. (A shell function would not do - the call goes through `timeout`, which
  # EXECs, and an exec'd binary cannot see a function. That cost a day on 2026-10-21.)
  mkdir -p "$sd/bin"; printf '#!/bin/sh\nexit %s\n' "$1" > "$sd/bin/qvm-shutdown"
  chmod +x "$sd/bin/qvm-shutdown"
  ( PATH="$sd/bin:$PATH"; wedge_acpi_record "$sd" 3 17891 somevm 600 >/dev/null 2>&1 )
  unset -f _wg_xid _wg_state
  cat "$sd/acpi-result" 2>/dev/null
}
ck 'a DELIVERED request that had no effect stays NOT-HALTED' \
   "$([ "$(deliv 0)" = NOT-HALTED ] && echo 0 || echo 1)" "got $(deliv 0)"
ck 'SEEN TO FAIL: a REFUSED request downgrades the verdict to UNREADABLE, not a wedge' \
   "$([ "$(deliv 1)" = UNREADABLE ] && echo 0 || echo 1)" "got $(deliv 1)"
ck '...and the recorded reason says the request was refused, keeping the earlier observation' \
   "$(grep -q 'REFUSED when re-issued' "$T/deliv-1/acpi-why" && grep -q 'Earlier observation' "$T/deliv-1/acpi-why" && echo 0 || echo 1)" \
   "$(cat "$T/deliv-1/acpi-why" 2>/dev/null | head -c 160)"
# THE EVIDENCE IS ASYMMETRIC AND MUST BE STATED THAT WAY. A refusal falsifies delivery; an
# acceptance only means the toolstack queued it. The first version of this check claimed the second
# as proof of delivery, and Jev rejected that at 0.98: "a qvm-shutdown that returns 0 only means the
# toolstack ACCEPTED the request, not that the guest's ACPI was reached."
ck '...and an ACCEPTED request is recorded as accepted, explicitly NOT as proof the guest saw it' \
   "$(grep -q 'ACCEPTED by the toolstack' "$T/deliv-0/acpi-why" && grep -q 'does NOT prove' "$T/deliv-0/acpi-why" && echo 0 || echo 1)" \
   "$(cat "$T/deliv-0/acpi-why" 2>/dev/null | head -c 200)"
ck '...and the reason does not claim the request was DELIVERED, which nothing here can show' \
   "$(grep -qE 'it was delivered' "$T/deliv-0/acpi-why" && echo 1 || echo 0)" \
   'acceptance by the toolstack is not delivery to the guest'
ck 'the residual gap is NAMED in the record rather than closed by a check that cannot close it' \
   "$(grep -q 'gap stays open' "$T/deliv-0/acpi-why" && echo 0 || echo 1)" "$(cat "$T/deliv-0/acpi-why" 2>/dev/null | tail -c 120)"
ck 'the re-ask status is kept as a raw field too' \
   "$([ "$(cat "$T/deliv-1/acpi-reask-rc" 2>/dev/null)" = 1 ] && echo 0 || echo 1)" "rc=$(cat "$T/deliv-1/acpi-reask-rc" 2>/dev/null)"
# HALTED and REBOOTED must NOT trigger a re-ask: the guest already answered, and re-asking a guest
# that went down is how a helper ends up starting one (shutdown-lib's own 2026-09-21 incident).
ck 'a HALTED verdict issues no further request' \
   "$(sd="$T/nore"; rm -rf "$sd"; mkdir -p "$sd/bin"
      printf '#!/bin/sh\ntouch "%s/CALLED"\nexit 0\n' "$sd" > "$sd/bin/qvm-shutdown"; chmod +x "$sd/bin/qvm-shutdown"
      WG_STUB_XID=; WG_STUB_STATE=Halted
      _wg_xid(){ printf '\n'; }; _wg_state(){ printf 'Halted\n'; }
      ( PATH="$sd/bin:$PATH"; wedge_acpi_record "$sd" 0 17891 somevm 600 >/dev/null 2>&1 )
      unset -f _wg_xid _wg_state
      [ ! -e "$sd/CALLED" ] && echo 0 || echo 1)" \
   'only the NOT-HALTED verdict rests on the request having been made'

dd="$T/acpi-why"; rm -rf "$dd"; mkdir -p "$dd"
_wg_xid(){ printf '17891\n'; }; _wg_state(){ printf 'Running\n'; }
mkdir -p "$dd/bin"; printf '#!/bin/sh\nexit 0\n' > "$dd/bin/qvm-shutdown"; chmod +x "$dd/bin/qvm-shutdown"
( PATH="$dd/bin:$PATH"; wedge_acpi_record "$dd" 3 17891 somevm 600 >/dev/null 2>&1 )
unset -f _wg_xid _wg_state
ck 'the recorded WHY names the domid it reasoned from, so the verdict can be checked later' \
   "$(grep -q '17891' "$dd/acpi-why" && echo 0 || echo 1)" "$(cat "$dd/acpi-why" 2>/dev/null)"
ck '...and the raw rc is kept alongside it, not just the conclusion' \
   "$([ "$(cat "$dd/acpi-rc")" = 3 ] && echo 0 || echo 1)" "acpi-rc=$(cat "$dd/acpi-rc" 2>/dev/null)"
# THE BOUND IS THE ONE ACTUALLY ASKED WITH. Jev 2026-10-22 put the single unhandled confound in
# this predicate at "the two bounds disagree" (0.41, material 0.68): the runner settles with a 600s
# deadline while the recorded reason named WG_ACPI_BOUND=300, so the conclusion was stated against a
# number that was never the measurement.
dd="$T/acpi-bound"; rm -rf "$dd"; mkdir -p "$dd"
WG_STUB_XID=17891; WG_STUB_STATE=Running
_wg_xid(){ printf '%s\n' "$WG_STUB_XID"; }; _wg_state(){ printf '%s\n' "$WG_STUB_STATE"; }
mkdir -p "$dd/bin"; printf '#!/bin/sh\nexit 0\n' > "$dd/bin/qvm-shutdown"; chmod +x "$dd/bin/qvm-shutdown"
( PATH="$dd/bin:$PATH"; wedge_acpi_record "$dd" 3 17891 somevm 600 >/dev/null 2>&1 )
unset -f _wg_xid _wg_state
ck 'the ACPI record stores the deadline it was ASKED with' \
   "$([ "$(cat "$dd/acpi-bound" 2>/dev/null)" = 600 ] && echo 0 || echo 1)" "acpi-bound=$(cat "$dd/acpi-bound" 2>/dev/null)"
ck '...and the recorded REASON quotes that bound, not the library default' \
   "$(grep -q '600s' "$dd/acpi-why" && ! grep -q '300s' "$dd/acpi-why" && echo 0 || echo 1)" "$(cat "$dd/acpi-why" 2>/dev/null)"
printf 'NOT-HALTED\n' > "$dd/acpi-result"; wedge_stage2 "$dd" >/dev/null
ck '...and stage 2 states the asked bound too, so the class and its reason agree' \
   "$(printf '%s' "$WG_WHY" | grep -q '600s' && echo 0 || echo 1)" "$WG_WHY"
# A ${N:?} FAILURE EXITS THE SHELL, so it cannot be tested with `cmd && echo 1 || echo 0` inside a
# command substitution: the subshell dies before either echo runs and the predicate arrives EMPTY,
# which is not 0 and reads as a failing leg for the wrong reason. Capture the status instead.
( wedge_acpi_record "$T/nob" 1 17891 somevm >/dev/null 2>&1 ); _nrc=$?
ck 'SEEN TO FAIL: omitting the deadline is REFUSED, never silently defaulted' \
   "$([ "$_nrc" -ne 0 ] && echo 0 || echo 1)" \
   "a caller that inherits the wrong bound is exactly the confound (rc=$_nrc)"

# ---- 14. RELEASING a held specimen is a named step with a reason -------------------------------
# Jev: preserve_and_analyze 0.55, preserve_but_bound_it 0.44 - preserving is right, but a hold with
# no named end strands the rig. The release is therefore a step, not a timeout, and it is gated on
# the same record as any kill.
rel="$T/rel"; rm -rf "$rel"; mkdir -p "$rel"
printf 'WEDGE-SPIN\n' > "$rel/class.txt"
WG_LINES=""
ck 'SEEN TO FAIL: releasing an INCOMPLETE record is refused' \
   "$(wedge_release somevm "$rel" 'analysed' >/dev/null 2>&1 && echo 1 || echo 0)" 'the record is the only thing that survives'
for f in why.txt listing.txt vmcs.txt vcpu-samples.txt screen.txt harness.txt; do printf 'x\n' > "$rel/$f"; done
( wedge_release somevm "$rel" >/dev/null 2>&1 ); _rrc=$?
ck 'SEEN TO FAIL: releasing with NO REASON is refused even on a complete record' \
   "$([ "$_rrc" -ne 0 ] && echo 0 || echo 1)" "a release with no reason recorded is the accident the gate exists to stop (rc=$_rrc)"
ck 'the runner names the release step in its stop message, so the hold has an end' \
   "$(grep -q 'wedge_release' "$ROOT/tools/release-acceptance.sh" && echo 0 || echo 1)" \
   'a preserved specimen with no documented way to release it strands the rig'

# NEVER `qvm-shutdown --wait`: the default --timeout 60 DESTROYS the domain, and `timeout 300`
# around it does not buy 300 s - the kill still lands at 60, with rc=0.
# CODE, not comments: both files DISCUSS --wait at length, so strip comment lines before grepping.
ck 'neither this library nor the runner ever calls qvm-shutdown --wait' \
   "$(grep -hv '^[[:space:]]*#' "$LIB" "$ROOT/tools/release-acceptance.sh" | grep -q 'qvm-shutdown --wait' && echo 1 || echo 0)" \
   'qvm-shutdown --wait is a kill on a timer (findings/rig.md)'
# THE POLLING AND RE-ASK DISCIPLINE STAYS IN shutdown-lib.sh - this file does not reimplement it.
# What it does issue is exactly ONE delivery verification, and only on the verdict that depends on
# the request having been made. So the rule is "one call site, never --wait", not "no calls".
ck 'the bounded ask and its re-ask discipline are delegated to shutdown-lib.sh' \
   "$(grep -q 'qwt_shutdown' "$LIB" && echo 0 || echo 1)" 'one asker, which is the file that knows the re-ask discipline'
ck '...and this file issues at most ONE qvm-shutdown of its own, for delivery verification' \
   "$([ "$(grep -cE '^[[:space:]]*(timeout [0-9]+ )?qvm-shutdown ' "$LIB")" -le 1 ] && echo 0 || echo 1)" \
   "found $(grep -cE '^[[:space:]]*(timeout [0-9]+ )?qvm-shutdown ' "$LIB") call sites"

# ---- 11b. stage 1 resets EVERY output, shape included -----------------------------------------
# Two guests classified in one process: the first a wedge candidate, the second plainly alive. A
# shape left over from the first would travel into the second's record.
d=$(mk resetA qrexec=SILENT c4=$((NOW-1380)) c1=1500 screen=NOWINDOW vmcs-activity=HLT)
wedge_stage1 "$d" >/dev/null
ck 'a candidate sets a shape' "$([ "$WG_SHAPE" = BLOCKED ] && echo 0 || echo 1)" "WG_SHAPE=$WG_SHAPE"
d=$(mk resetB qrexec=ANSWERED c4=$((NOW-5)) c1=1500 screen=DESKTOP)
wedge_stage1 "$d" >/dev/null
ck '...and an ALIVE guest classified next carries NO leftover shape' \
   "$([ "$WG_CLASS" = ALIVE ] && [ -z "$WG_SHAPE" ] && echo 0 || echo 1)" "class=$WG_CLASS shape=$WG_SHAPE"

# ---- 11c. what a LIVE run found, kept as regressions ------------------------------------------
# Both defects below were invisible offline and were found by running wedge_collect against a live
# guest on 2026-10-22. Neither is reachable from a fixture, so they are asserted against the CODE.
ck 'wedge_classify is called with its outdir, not one argument' \
   "$(grep -qE 'wedge_classify "\$vm" "\$d/' "$LIB" && echo 0 || echo 1)" \
   'wedge_classify <vm> <outdir>: called with one arg it dies on its own $2 under set -u'
ck 'the one-argument call is GONE, so fraction cannot silently read UNREADABLE forever' \
   "$(grep -qE 'wedge_classify "\$vm" >' "$LIB" && echo 1 || echo 0)" 'it was the O2 corroborator for every run'
ck 'nothing bounds local.WinWedgeForensics below the time its own script needs' \
   "$(grep -oE 'timeout [0-9]+ qrexec-client-vm dom0 "local.WinWedgeForensics' "$LIB" | awk '{if ($2 < 120) bad=1} END{exit !bad}' && echo 1 || echo 0)" \
   'the service takes two vcpu samples 10s apart plus debug-keys dumps; timeout 25 measured the bound'
ck 'the separate dom0 reachability probe is gone - the real capture answers it' \
   "$(grep -q 'dom0-ok"; else' "$LIB" && echo 1 || echo 0)" 'one fewer heavy dom0 call, and no bound shorter than the service'

# ---- 11d. THE LIBRARY MUST SURVIVE `set -u` ---------------------------------------------------
# Two live captures died mid-collect on unbound variables - once on wedge_classify's own "$2", once
# on WEDGE_SAMPLE_SECS, which wedge-lib.sh owns and this file also reads. Both left the vmlock taken
# and nothing captured. A library sourced by harnesses cannot depend on its caller's shell options,
# so this is checked structurally rather than by hoping the next run catches it.
undefaulted=$(python3 - "$LIB" <<'PYEOF'
import re, sys
src = open(sys.argv[1]).read()
# Names this file ASSIGNS (with or without a default) are fine - they exist by the time anything
# reads them. Anything else read bare, in UPPER_CASE, is a caller-supplied name needing ${X:-...}.
# Assignments are not only at line start: `WG_CLASS=""; WG_WHY=""; WG_LINES=""` puts two of
# them after a semicolon, and a detector that misses those reports the file's own globals as
# caller-supplied. Accept an assignment after start-of-line, `;`, `&&`, `||` or `local `.
assigned = set(re.findall(r'(?:^|[;&|]\s*|\blocal\s+)([A-Z][A-Z0-9_]*)=', src, re.M))
guarded  = set(re.findall(r'\$\{([A-Z][A-Z0-9_]*)[:#%/\-=?+]', src))
bare     = set(re.findall(r'\$\{?([A-Z][A-Z0-9_]*)\}?', src))
missing  = sorted(bare - assigned - guarded - {'BASH_SOURCE','PIPESTATUS','IFS','OSTYPE','PATH','HOME','TMPDIR','PWD'})
print(' '.join(missing))
PYEOF
)
ck 'every caller-supplied variable the library reads has a default' \
   "$([ -z "$undefaulted" ] && echo 0 || echo 1)" "undefaulted: $undefaulted"
# AND RUN IT THAT WAY: the pure half of the library, under set -u, over a real fixture.
d=$(mk setu qrexec=SILENT c4=$((NOW-1380)) c1=1500 screen=NOWINDOW vmcs-activity=HLT)
ck 'the pure functions run clean under set -u' \
   "$(bash -u -c '
      . "'"$LIB"'"
      # STUB THE HOST READS INSIDE THIS SUBSHELL. It is a fresh shell, so the stubs defined in the
      # parent are not here - and without them wedge_acpi_record calls the real qvm-ls, which the
      # offline estate correctly refuses ("TOUCHED-RIG ... 2 call(s) to the rig from an OFFLINE
      # suite"). An offline suite that reaches the rig is a defect in the suite, not in the gate.
      _wg_xid(){ printf "17891\n"; }; _wg_state(){ printf "Running\n"; }
      wedge_stage1 "'"$d"'" >/dev/null
      printf "%s\n" "$WG_CLASS" > "'"$d"'/class.txt"
      wedge_acpi_record "'"$d"'" 4 17891 somevm 600 >/dev/null 2>&1
      wedge_stage2 "'"$d"'" >/dev/null
      wedge_disposition "$WG_CLASS" >/dev/null
      wedge_is_fatal "$WG_CLASS"; wedge_must_preserve "$WG_CLASS"
      wedge_record_complete "'"$d"'" >/dev/null
      wedge_may_kill "'"$d"'" "$WG_CLASS" >/dev/null 2>&1
      wedge_gates_jev "'"$d"'" "$WG_CLASS" >/dev/null 2>&1
      exit 0' >/dev/null 2>&1 && echo 0 || echo 1)" \
   'a library sourced by harnesses cannot depend on the caller shell options'

# ---- 12. THE BUILT-IN JEV GATE IS REFERENCE ONLY ----------------------------------------------
# Owner, 2026-10-22: "add builtin jev gate to judge common failure modes (reference only)". The
# deterministic class is the verdict; Jev names the MECHANISM behind it. So the legs that matter are
# the ones proving it cannot reach the verdict: no network is used here, and nothing below asserts
# what Jev would say - only that the gate is wired, scoped, and inert with respect to WG_CLASS.
jd="$T/jev"; rm -rf "$jd"; mkdir -p "$jd"
for f in why.txt listing.txt vmcs.txt vcpu-samples.txt screen.txt harness.txt acpi-why; do printf 'x\n' > "$jd/$f"; done
# PATH-proof: tools/jev-artifact.sh is reached by a relative path, so from another cwd the gate must
# degrade to a message rather than silently claim an answer. Driven from $T on purpose.
( cd "$T" && WG_JEV=""; wedge_gates_jev "$jd" WEDGE-SPIN >/dev/null 2>&1; printf '%s' "$WG_JEV" > "$jd/out-nocwd" ) || true
ck 'with no reachable jev-artifact.sh the gate SAYS SO instead of inventing an answer' \
   "$(grep -q 'not available' "$jd/out-nocwd" && echo 0 || echo 1)" "$(cat "$jd/out-nocwd" 2>/dev/null)"
printf 'WEDGE-SPIN\n' > "$jd/class.txt"
before=WEDGE-SPIN; WG_CLASS="$before"
( cd "$T" && wedge_gates_jev "$jd" ) >/dev/null 2>&1
ck 'the Jev gate NEVER changes the class - it is reference only' \
   "$([ "$WG_CLASS" = "$before" ] && echo 0 || echo 1)" "WG_CLASS=$WG_CLASS"
for c in ALIVE BOOTING SHUTTING-DOWN ALIVE-RECENT QREXEC-QUEUE-RESTART DOMAIN-GONE; do
  WG_JEV=""; wedge_gates_jev "$jd" "$c" >/dev/null 2>&1
  ck "Jev is NOT asked about $c - nothing failed, so there is no mechanism to attribute" \
     "$(printf '%s' "$WG_JEV" | grep -q 'not asked' && echo 0 || echo 1)" "$WG_JEV"
done
WG_JEV=""; wedge_gates_jev "$jd" '' >/dev/null 2>&1
rm -f "$jd/class.txt"; WG_JEV=""; wedge_gates_jev "$jd" '' >/dev/null 2>&1
ck 'with no class at all Jev is not asked either' \
   "$(printf '%s' "$WG_JEV" | grep -q 'not asked' && echo 0 || echo 1)" "$WG_JEV"
# EVERY FATAL CLASS MUST HAVE A CANDIDATE SET, or the gate is decoration on the classes that matter.
for c in WEDGE-SPIN WEDGE-BLOCKED WEDGE-UNKNOWN-SHAPE WEDGE-CANDIDATE WEDGE-SPIN-CANDIDATE \
         WEDGE-BLOCKED-CANDIDATE QREXEC-DEAD-ALIVE RESTART-UNEXPLAINED UNRESPONSIVE-WITH-PIXELS \
         UNREADABLE-ACPI UNREADABLE-CPU UNREADABLE-SCREEN RECOVERY; do
  WG_JEV=""; wedge_gates_jev "$jd" "$c" >/dev/null 2>&1
  ck "the fatal class $c HAS a candidate mechanism set" \
     "$(printf '%s' "$WG_JEV" | grep -q 'no candidate set' && echo 1 || echo 0)" "$WG_JEV"
  ck "...and $c's rubric is valid JSON with criteria naming real alternatives" \
     "$(python3 -c "
import json,sys
r=json.load(open('$jd/jev-mechanism-rubric.json'))
q=r['questions']
assert q['mechanism']['type']=='choice', 'mechanism must be a choice question'
assert len(q['mechanism']['criteria'])>=3, 'at least three real alternatives'
assert 'criteria' in q['evidence_is_sufficient']
sys.exit(0)" >/dev/null 2>&1 && echo 0 || echo 1)" "invalid rubric for $c"
done
# A `choice` question takes criteria, NOT choices - a rubric with `choices` scores nothing.
# ONLY THE TWO TYPES THE SERVICE ACCEPTS. A `text` question returns HTTP 400 "Invalid request" -
# measured 2026-10-22, after I invented that type; it appears nowhere else in the repo. A rubric
# that 400s makes the reference gate silently useless exactly when it is wanted.
ck 'every question is noul or choice - no invented question types' \
   "$(python3 -c "
import json,sys
r=json.load(open('$jd/jev-mechanism-rubric.json'))
bad=[k for k,v in r['questions'].items() if v.get('type') not in ('noul','choice')]
sys.exit(1 if bad else 0)" >/dev/null 2>&1 && echo 0 || echo 1)" \
   'jev.py renders noul and choice; anything else is rejected by the service'
ck 'the rubric uses criteria, never choices' \
   "$(grep -q '"choices"' "$jd/jev-mechanism-rubric.json" && echo 1 || echo 0)" 'jev choice questions take criteria'
ck 'the gate asks what CAPTURE is missing, so a preserved specimen has a next step' \
   "$(grep -q 'next_capture' "$jd/jev-mechanism-rubric.json" && echo 0 || echo 1)" 'a specimen held for analysis needs the next capture named'
ck 'the runner calls the Jev gate, and labels it supplementary' \
   "$(grep -q 'wedge_gates_jev' "$ROOT/tools/release-acceptance.sh" && echo 0 || echo 1)" 'an unwired reference gate is not a reference'

# ---- 13. THE VMCS PARSE, against the REAL table format ----------------------------------------
# This was the biggest defect in the library (a review put it at 0.78) for one reason: it had never
# been run against real output. The fixture below is wedge-vmcs.py's actual print format, header and
# all, taken from its own format string - so the column positions are the real ones.
FX="$T/vmcs"; mkdir -p "$FX"
hdr=$'\n vcpu  RIP                 IF  RVI   SVI  intibility activity  last exit                 cpu-time delta'
# A SPIN: vcpu0 Active (activity 0x00) on an unchanged RIP in both samples, with the Windows IPI
# vector latched in RVI and never taken - the shape one recorded bundle actually showed.
{ printf '%s\n' "$hdr"
  printf '    0  0xfffff8027a1b3c42  1  0xe1  0x00      0x00      0x00  40 (PAUSE-loop exit)      +9.8 s (a->b)\n'
  printf '    1  0xfffff80279004100  1  0x00  0x00      0x00      0x01  12 (HLT)                  +0.0 s (a->b)\n'
} > "$FX/spin-1.txt"
{ printf '%s\n' "$hdr"
  printf '    0  0xfffff8027a1b3c42  1  0xe1  0x00      0x00      0x00  40 (PAUSE-loop exit)      +9.9 s (a->b)\n'
  printf '    1  0xfffff80279004100  1  0x00  0x00      0x00      0x01  12 (HLT)                  +0.0 s (a->b)\n'
} > "$FX/spin-2.txt"
# EVERY vCPU HLT in both samples, nothing latched.
{ printf '%s\n' "$hdr"
  printf '    0  0xfffff80279004100  1  0x00  0x00      0x00      0x01  12 (HLT)                  +0.0 s (a->b)\n'
  printf '    1  0xfffff80279004100  1  0x00  0x00      0x00      0x01  12 (HLT)                  +0.0 s (a->b)\n'
} > "$FX/hlt-1.txt"
cp "$FX/hlt-1.txt" "$FX/hlt-2.txt"
# Active, but the RIP MOVED: executing, so neither spinning nor idle.
{ printf '%s\n' "$hdr"
  printf '    0  0xfffff8027a1b3c42  1  0x00  0x00      0x00      0x00  30 (I/O instruction)      +4.0 s (a->b)\n'
} > "$FX/moving-1.txt"
{ printf '%s\n' "$hdr"
  printf '    0  0xfffff8027affee10  1  0x00  0x00      0x00      0x00  30 (I/O instruction)      +4.0 s (a->b)\n'
} > "$FX/moving-2.txt"
fields(){ python3 "$ROOT/tools/wedge-vmcs-fields.py" "$@" 2>/dev/null; }
ck 'a SPIN table yields activity=ACTIVE' \
   "$(fields "$FX/spin-1.txt" "$FX/spin-2.txt" | grep -q '^activity=ACTIVE$' && echo 0 || echo 1)" "$(fields "$FX/spin-1.txt" "$FX/spin-2.txt" | tr '\n' ' ')"
ck '...and rip-static=1 naming WHICH vCPU stood still' \
   "$(fields "$FX/spin-1.txt" "$FX/spin-2.txt" | grep -q '^rip-static=1$' && fields "$FX/spin-1.txt" "$FX/spin-2.txt" | grep -q '^rip-static-vcpu=0$' && echo 0 || echo 1)" \
   "$(fields "$FX/spin-1.txt" "$FX/spin-2.txt" | tr '\n' ' ')"
ck '...and the LATCHED IPI VECTOR is carried out of the dump, not discarded' \
   "$(fields "$FX/spin-1.txt" "$FX/spin-2.txt" | grep -q '^rvi-pending=0xe1$' && echo 0 || echo 1)" \
   'RVI is the direct evidence of an IPI that was never taken'
# THE LATCHED-VECTOR DISTINCTION, calibrated against a REAL healthy guest. win11de-uc on
# 2026-10-22 showed RVI=0xd1 on vcpu2 in sample 1 and nothing in sample 2: an interrupt in flight,
# taken between samples. That is what working delivery looks like, so a single-sample RVI is not a
# finding. The recorded wedge is the same vector in BOTH samples on the same vCPU.
ck 'a vector latched in ONE sample only is NOT reported stuck - that is normal delivery' \
   "$(printf '%s\n' "$hdr" > "$FX/rvi1-1.txt"
      printf '    2  0xfffff802767d6db8  1  0xd1  0xd1      0x00      0x00  48 (EPT violation)    +1.6 s (a->b)\n' >> "$FX/rvi1-1.txt"
      printf '%s\n' "$hdr" > "$FX/rvi1-2.txt"
      printf '    2  0xfffff802767d6db8  1  0x00  0x00      0x00      0x00  48 (EPT violation)    +1.6 s (a->b)\n' >> "$FX/rvi1-2.txt"
      fields "$FX/rvi1-1.txt" "$FX/rvi1-2.txt" | grep -q '^rvi-stuck=$' && echo 0 || echo 1)" \
   "$(fields "$FX/rvi1-1.txt" "$FX/rvi1-2.txt" | tr '\n' ' ')"
ck '...while the SAME vector in BOTH samples IS reported stuck, naming the vCPU' \
   "$(fields "$FX/spin-1.txt" "$FX/spin-2.txt" | grep -q '^rvi-stuck=0xe1$' && fields "$FX/spin-1.txt" "$FX/spin-2.txt" | grep -q '^rvi-stuck-vcpu=0$' && echo 0 || echo 1)" \
   "$(fields "$FX/spin-1.txt" "$FX/spin-2.txt" | tr '\n' ' ')"
ck 'a latched vector corroborates the SHAPE and never gates candidacy' \
   "$(d2=$(mk rvigate qrexec=SILENT c4=$((NOW-1380)) c1=1500 screen=NOWINDOW vmcs-activity=ACTIVE vmcs-rip-static=1 vmcs-rvi-stuck=0xe1)
      wedge_stage1 "$d2" >/dev/null
      [ "$WG_CLASS" = WEDGE-CANDIDATE ] && printf '%s' "$WG_SHAPE_WHY" | grep -q '0xe1' && echo 0 || echo 1)" \
   'the IPI evidence belongs in the reason, not in the gate'

ck 'an all-HLT table yields activity=HLT' \
   "$(fields "$FX/hlt-1.txt" "$FX/hlt-2.txt" | grep -q '^activity=HLT$' && echo 0 || echo 1)" "$(fields "$FX/hlt-1.txt" "$FX/hlt-2.txt" | tr '\n' ' ')"
ck '...with nothing reported as latched when nothing is' \
   "$(fields "$FX/hlt-1.txt" "$FX/hlt-2.txt" | grep -q '^rvi-pending=$' && echo 0 || echo 1)" "$(fields "$FX/hlt-1.txt" "$FX/hlt-2.txt" | tr '\n' ' ')"
ck 'an ADVANCING RIP is not static, however Active the vCPU is' \
   "$(fields "$FX/moving-1.txt" "$FX/moving-2.txt" | grep -q '^rip-static=0$' && echo 0 || echo 1)" "$(fields "$FX/moving-1.txt" "$FX/moving-2.txt" | tr '\n' ' ')"
# THE TWO DEFECTS, ASSERTED AS REGRESSIONS so they cannot come back.
# (1) activity was read from column $8, which is the exit reason's NUMBER. On the spin fixture the
#     old expression read "40 12" - PAUSE-loop and HLT exit reasons - as ActivityState values.
ck 'SEEN TO FAIL: column $8 is the exit reason, NOT activity' \
   "$([ "$(awk '/activity/{next} NF>6{print $8}' "$FX/spin-1.txt" | head -1)" = 40 ] && echo 0 || echo 1)" \
   'if $8 ever becomes the activity column this leg is the warning'
ck '...and the tested parse reads activity from the right column instead' \
   "$(fields "$FX/spin-1.txt" "$FX/spin-2.txt" | grep -q '^activity=ACTIVE$' && echo 0 || echo 1)" 'activity is field 7'
# (2) "RIP static" compared the first hex token in the file to the last, across BOTH samples and
#     EVERY vCPU. Here that compares vcpu0's RIP with vcpu1's and calls a genuine spin not-static.
old_static(){ cat "$FX/spin-1.txt" "$FX/spin-2.txt" > "$FX/cat.txt"
  a=$(grep -oE '0x[0-9a-f]{6,}' "$FX/cat.txt" | head -1); b=$(grep -oE '0x[0-9a-f]{6,}' "$FX/cat.txt" | tail -1)
  [ "$a" = "$b" ] && echo 1 || echo 0; }
ck 'SEEN TO FAIL: the first-vs-last-hex-token test calls a REAL spin not-static' \
   "$([ "$(old_static)" = 0 ] && echo 0 || echo 1)" 'it compared vcpu0 in sample 1 with the last vCPU in sample 2'
ck '...while the per-vCPU comparison identifies it' \
   "$(fields "$FX/spin-1.txt" "$FX/spin-2.txt" | grep -q '^rip-static=1$' && echo 0 || echo 1)" 'same vCPU, same address, twice'
# ONE SAMPLE IS NOT TWO: a spin claim needs both, so activity stays empty rather than guessing.
ck 'with only ONE sample the activity verdict is EMPTY, never assumed' \
   "$(fields "$FX/spin-1.txt" | grep -q '^activity=$' && echo 0 || echo 1)" "$(fields "$FX/spin-1.txt" | tr '\n' ' ')"
ck 'garbage in yields vcpus=0 and no verdict, rather than a shape' \
   "$(printf 'not a table at all\n' > "$FX/junk.txt"; fields "$FX/junk.txt" "$FX/junk.txt" | grep -q '^vcpus=0$' && echo 0 || echo 1)" \
   "$(fields "$FX/junk.txt" "$FX/junk.txt" | tr '\n' ' ')"
# AND IT READS FIELDS, NOT THE TOOL'S OWN CONCLUSION: wedge-vmcs.py prints its own "SHAPE:" line,
# which is a verdict, and a verdict is not a measurement.
ck 'the parse never keys on wedge-vmcs.py SHAPE line' \
   "$(grep -q 'SHAPE' "$ROOT/tools/wedge-vmcs-fields.py" && grep -qE '^[^#]*(grep|==|in ).*SHAPE' "$ROOT/tools/wedge-vmcs-fields.py" && echo 1 || echo 0)" \
   'an instrument conclusion must not be quoted as the measurement'
ck 'the collector calls the tested parse rather than deriving fields inline' \
   "$(grep -q 'wedge-vmcs-fields.py' "$LIB" && ! grep -qE "awk .*\\\$8" "$LIB" && echo 0 || echo 1)" \
   'the inline awk/grep derivation is what was never testable'

say ''
say "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
