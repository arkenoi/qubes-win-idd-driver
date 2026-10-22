#!/usr/bin/env bash
# wedge-gates-lib.sh - ONE classifier for "what is this guest doing", and the gates that depend on it.
#
# WHY (owner, 2026-10-22): "i want the underlying logic to reliably detect wedge conditions by
# determenistic criteria, distinct them from other fatal failure modes that MAY look like wedge
# (absent qrexec for example), and process accordingly." And: "there should have had been
# a) abort condition wired on any fatal failure b) wedge record on anything that is classified as
# a wedge."
#
# WHAT WENT WRONG, MEASURED. A campaign had a guest wedge on the post-install second boot of the
# win11-upgrade cell. The install reported ok:true, the guest came back with a session, and the
# FIRST qrexec use after that boot got no answer by either transport; it never answered again, four
# ACPI asks were ignored, and it was killed at 600s with NO capture taken. matrix.sh FATALed and
# aborted itself, tools/release-acceptance.sh went on to the feature tests anyway, and nothing
# produced a record - although collect-failure.sh, wedge-lib.sh, fetch-wedge-core.sh,
# tools/wedge-hunt.sh and tools/verdict-jev.py all exist and were never invoked.
#
# THE SAME DAY, A GUEST THAT MERELY LOOKED WEDGED. win11-acc refused qvm-shutdown while its harness
# still held it - and qrexec ANSWERED rc=0, and it halted cleanly the moment nothing held it. Two
# guests, one surface symptom, opposite states. Anything keyed on "qrexec absent" or "shutdown
# refused" alone calls both wedged and kills a healthy guest.
#
# AND THE CLASSIFIER ALREADY EXISTED. wedge_classify() in wedge-lib.sh samples the hypervisor twice
# through dom0's local.WinWedgeForensics - no guest cooperation - and was never called on the path
# that mattered: w_install's unreachable branch classifies on the coarse cpu_time FLAT/MOVING binary
# instead, which wedge-lib.sh's own calibration says cannot separate a pegged guest (cpu_usage_raw
# 130,976) from an idle-unreachable one (96,262). Five disjoint "not answering" predicates existed
# across shutdown-lib, w_install, w_session, accept-clean and matrix's own FATAL, and none of them
# decided "wedged".
#
# DESIGN, graded with Jev at each fork (scratchpad/jev/salvage.md, spec-grade*.md):
#   * ONE implementation, sourced by every call site (where_the_abort_lives: shared_lib 0.99);
#   * the record is produced BY THE CLASSIFIER at the moment it classifies (0.59), BEFORE anything
#     kills the subject, and the kill is GATED on the record (0.76);
#   * collect-failure.sh (0.33) and wedge-lib.sh (0.31) are not salvageable as-is: this file calls
#     wedge-lib's one sound primitive and owns the decision itself;
#   * STAGE 1 is a PURE FUNCTION of (observables, context) - it issues nothing, so re-running it
#     cannot change its answer. STAGE 2 is the only step that intervenes.
#   * Everything reads FILES, so the same code grades a live guest and a captured evidence dir -
#     which is how tools/tests/wedge-gates-selftest.sh drives every class offline, including the
#     two REAL specimens of 2026-10-22.
#
# HONEST CEILING. Jev graded the written design's determinism 0.57 across four structurally
# different drafts, and the limit is not the tree - it is the instruments it reads, which the
# descending harness audit scored at failure-modes 0.06-0.46. A total, single-path tree over
# unreliable inputs is still only as good as the inputs; that is why UNREADABLE-CPU is a first-class
# answer here rather than a coin-flip between SPIN and BLOCKED.

WG_CLASS=""; WG_WHY=""; WG_LINES=""

# ---------------------------------------------------------------------------------------------
# The observable set. Every one is host-side EXCEPT O3, and O3 is never allowed to decide a class
# by itself - that is the entire lesson of the two specimens above.
#
#   O1 domain listing   qvm-ls --raw-data --fields NAME,STATE   (the FULL list: an empty list is an
#                       instrument failure, NOT "the vm is absent")
#   O2 vcpu fraction    wedge_classify -> dom0 local.WinWedgeForensics (corroboration only)
#   O3 qrexec answer    one bounded VMShell echo                (the only guest-dependent one)
#   O4 screen class     w_screen -> qtest shot -> winshot.py    (dom0 draws the framebuffer)
#   O8 pending qrexec   pgrep -f "qrexec-client-vm [v]m " on THIS qube's own process table
#   OR restarts         how many times the domain left and re-entered Running while we watched
#   O9 ActivityState    xl debug-keys v, decoded by tools/wedge-vmcs.py: per-vCPU ActivityState is
#                       the VMCS enum {Active, HLT, Shutdown, Wait-for-SIPI} and RIP is an address,
#                       so SPIN is "Active in both samples with RIP unchanged" - structural, not a
#                       threshold over bands that wedge-lib.sh says overlap.
#   C1 since start      host clock vs the domain start this harness recorded
#   C2 shutdown asked   whether THIS harness asked, and when
#   C4 last answer      when O3 last answered on this boot
#
# BOUNDS ARE FIXED HERE, never passed in, or one guest classifies differently from two call sites.
WG_BOOT_BOUND="${WG_BOOT_BOUND:-300}"      # matrix's own stall clock
WG_QREXEC_PROBE="${WG_QREXEC_PROBE:-25}"   # one bounded VMShell echo
WG_QREXEC_BOUND="${WG_QREXEC_BOUND:-120}"  # silence after a known answer; tolerates one MSI restart
WG_ACPI_BOUND="${WG_ACPI_BOUND:-300}"      # shutdown-lib asks every 120s, so 300 covers two

_wg_say(){ WG_LINES="${WG_LINES}$*"$'\n'; }
_wg_get(){ [ -s "$1/$2" ] && tr -d '\r\n' < "$1/$2" || printf ''; }

# THE DEFINITION OF A WEDGE, from the owner, 2026-10-22: "it is there, displays no pixels
# whatsoever and does not respond to acpi shutdown either (not to be confused with 'has qrexec
# queue and restarts rapidly')". All THREE conjuncts are required:
#   present (O1) AND no pixels at all (O4 in {BLACK, NOWINDOW}) AND ACPI ignored (stage 2).
# The first version of this library got two of them wrong: WEDGE-SPIN was decided by the vCPU alone
# with no ACPI ask at all (only the BLOCKED branch probed), and the screen was consulted only for
# RECOVERY, so a guest that was DRAWING but silent could have been called a wedge. A spinning vCPU
# behind a live desktop is not a wedge; it is an unresponsive guest that still renders.
# And the look-alike the owner names had no class at all: a guest with a QUEUED qrexec call restarts
# as soon as it halts, so it cycles Running and looks unreachable at every sample. That is
# QREXEC-QUEUE-RESTART, discriminated by this qube's OWN process table (O8) plus the observed
# restart count - both host-side, neither needing the guest.
#
# wedge_stage1 <evidence-dir> -> sets WG_CLASS and WG_WHY. PURE: reads files, issues nothing.
# The tree is total because every test is over a CLOSED domain, and no leaf is reachable twice.
wedge_stage1(){
  local d="${1:?wedge_stage1 <evidence-dir>}"
  WG_CLASS=""; WG_WHY=""
  local listing="$d/listing.txt" vm; vm=$(_wg_get "$d" vm)
  [ -n "$vm" ] || { WG_CLASS="INSTRUMENT-FAILURE"; WG_WHY="no subject named (lint L10: never default a target)"; return 0; }

  # T1 instrument health. "We cannot measure" is not a guest state, and must never be reported as one.
  local dom0ok; dom0ok=$(_wg_get "$d" dom0-ok)
  if [ ! -s "$listing" ] || [ "$dom0ok" != 1 ]; then
    WG_CLASS="INSTRUMENT-FAILURE"
    WG_WHY="O1 listing $( [ -s "$listing" ] && echo present || echo 'EMPTY/unparseable' ), dom0 qrexec ok=${dom0ok:-unknown}"
    return 0
  fi
  # T2 presence, decided only against a listing already known healthy
  if ! grep -qE "^$vm[[:space:]]" "$listing"; then
    WG_CLASS="DOMAIN-GONE"; WG_WHY="$vm absent from a healthy O1 listing"; return 0
  fi
  # T3 did WE ask it to stop, recently? Benign, and no wedge class is reachable while it holds.
  local c2 now; c2=$(_wg_get "$d" c2); now=$(_wg_get "$d" now); now="${now:-$(date +%s)}"
  if [ -n "$c2" ] && [ $((now - c2)) -lt "$WG_ACPI_BOUND" ]; then
    WG_CLASS="SHUTTING-DOWN"; WG_WHY="we asked $((now - c2))s ago, inside ACPI_BOUND ${WG_ACPI_BOUND}s"; return 0
  fi
  # T4 the framebuffer is authoritative over any cpu reading
  local screen; screen=$(_wg_get "$d" screen)
  if [ "$screen" = RECOVERY ]; then
    WG_CLASS="RECOVERY"; WG_WHY="O4=RECOVERY - terminal whatever the cpu says"; return 0
  fi
  # T5 the guest's own answer
  local qrexec; qrexec=$(_wg_get "$d" qrexec)
  if [ "$qrexec" = ANSWERED ]; then
    WG_CLASS="ALIVE"; WG_WHY="O3 answered within ${WG_QREXEC_PROBE}s"; return 0
  fi
  # T6/T7/T8 silence is only meaningful against the right bound: a guest that answered and then
  # died inside its boot bound fell through EVERY rule in an earlier draft of this tree.
  local c1 c4; c1=$(_wg_get "$d" c1); c4=$(_wg_get "$d" c4)
  if [ -z "$c4" ]; then
    if [ -n "$c1" ] && [ "$c1" -lt "$WG_BOOT_BOUND" ]; then
      WG_CLASS="BOOTING"; WG_WHY="O3 has never answered and C1=${c1}s < BOOT_BOUND ${WG_BOOT_BOUND}s - a spinning vCPU here means nothing"; return 0
    fi
  else
    if [ $((now - c4)) -lt "$WG_QREXEC_BOUND" ]; then
      WG_CLASS="ALIVE-RECENT"; WG_WHY="silent $((now - c4))s, inside QREXEC_BOUND ${WG_QREXEC_BOUND}s of its last answer"; return 0
    fi
  fi
  # T8b the owner's named look-alike: a queued call restarts the guest the moment it halts, so it
  # cycles Running and reads unreachable at every sample. Host-side only: our own process table.
  local pending restarts; pending=$(_wg_get "$d" pending-qrexec); restarts=$(_wg_get "$d" restarts)
  if [ -n "$restarts" ] && [ "$restarts" -ge 1 ] 2>/dev/null; then
    if [ -n "$pending" ] && [ "$pending" -ge 1 ] 2>/dev/null; then
      WG_CLASS="QREXEC-QUEUE-RESTART"; WG_WHY="the domain re-entered Running ${restarts}x while watched and ${pending} qrexec call(s) are queued on THIS qube - it restarts as soon as it halts, which is not a wedge"; return 0
    fi
    WG_CLASS="RESTART-UNEXPLAINED"; WG_WHY="the domain re-entered Running ${restarts}x with NO queued call to explain it - fatal, but not a wedge"; return 0
  fi
  # T8c NO PIXELS IS PART OF THE DEFINITION. A guest that is still drawing is not wedged, however
  # silent its qrexec and however busy its vCPUs.
  case "$screen" in
    BLACK|NOWINDOW) : ;;
    '')  WG_CLASS="UNREADABLE-SCREEN"; WG_WHY="O4 was not captured, and 'displays no pixels' cannot be asserted without it"; return 0 ;;
    *)   WG_CLASS="UNRESPONSIVE-WITH-PIXELS"; WG_WHY="O4=$screen - the guest is drawing, so this is silent qrexec on a rendering guest, not a wedge"; return 0 ;;
  esac
  # T9 the wedge branch, decided STRUCTURALLY and host-side only. It yields CANDIDATES: the third
  # conjunct of the definition (ACPI ignored) can only be established by stage 2's single ask.
  local act rip2 frac
  act=$(_wg_get "$d" vmcs-activity); rip2=$(_wg_get "$d" vmcs-rip-static); frac=$(_wg_get "$d" fraction)
  case "$act" in
    ACTIVE)
      if [ "$rip2" = 1 ]; then
        if [ "$frac" = BLOCKED ]; then
          WG_CLASS="UNREADABLE-CPU"; WG_WHY="O9 says Active with a static RIP but O2 says BLOCKED - two instruments contradict, which is a measurement problem and not a guest state"
        else
          WG_CLASS="WEDGE-SPIN-CANDIDATE"; WG_WHY="present, no pixels (O4=$screen), and O9 shows a vCPU Active in both samples with RIP unchanged${frac:+; O2 corroborates $frac} - ACPI must still be asked"
        fi
      else
        WG_CLASS="UNREADABLE-CPU"; WG_WHY="O9: Active but RIP advanced between samples - executing, not spinning, and not idle either"
      fi ;;
    HLT)
      if [ "$frac" = SPIN ]; then
        WG_CLASS="UNREADABLE-CPU"; WG_WHY="O9 says every vCPU is HLT but O2 says SPIN - two instruments contradict"
      else
        WG_CLASS="WEDGE-BLOCKED-CANDIDATE"; WG_WHY="present, no pixels (O4=$screen), and O9 shows every vCPU HLT in both samples - ACPI must still be asked"
      fi ;;
    *)
      WG_CLASS="UNREADABLE-CPU"; WG_WHY="O9 unavailable or mixed (activity='${act:-absent}') - stated, never guessed" ;;
  esac
  return 0
}

# wedge_stage2 <evidence-dir> - the ONLY step that intervenes: exactly one ACPI ask, bounded.
# Split out so stage 1 can never be changed by having been asked.
#   <dir>/acpi-result = HALTED | NOT-HALTED  (written by the caller from its own observation)
# It takes the stage-1 CANDIDATE so the sub-shape survives: ACPI decides wedge-or-not, the vCPU
# shape decides which wedge. A missing candidate is an error, not a default to BLOCKED.
wedge_stage2(){
  local d="${1:?wedge_stage2 <evidence-dir>}" r cand
  r=$(_wg_get "$d" acpi-result); cand=$(_wg_get "$d" candidate)
  case "$r" in
    HALTED)
      WG_CLASS="QREXEC-DEAD-ALIVE"
      WG_WHY="one ACPI ask was HONOURED within ${WG_ACPI_BOUND}s, so the third conjunct of a wedge fails - a PRODUCT failure, not a wedge. This is what separated win11-acc from win11-upgrade on 2026-10-22." ;;
    NOT-HALTED)
      case "$cand" in
        WEDGE-SPIN-CANDIDATE)    WG_CLASS="WEDGE-SPIN";    WG_WHY="present, no pixels, ACPI ignored for ${WG_ACPI_BOUND}s, and a vCPU spinning on an unchanged RIP" ;;
        WEDGE-BLOCKED-CANDIDATE) WG_CLASS="WEDGE-BLOCKED"; WG_WHY="present, no pixels, ACPI ignored for ${WG_ACPI_BOUND}s, and every vCPU HLT" ;;
        *)                       WG_CLASS="UNREADABLE-CPU"; WG_WHY="ACPI was ignored but stage 1 left no candidate ('${cand:-absent}') - the wedge SHAPE is unknown and must not be defaulted" ;;
      esac ;;
    *) WG_CLASS="UNREADABLE-CPU"; WG_WHY="the ACPI probe produced no observation ('${r:-absent}')" ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------------------------
# What each class MEANS to a caller. One place, so five callers cannot invent five answers.
#   fatal   - the run stops here and every caller above stops too
#   wedge   - a record is mandatory BEFORE any kill, and the kill is gated on it
#   product - a real product failure, but not a wedge (no core fetch)
#   wait    - not a failure: keep waiting, the bound is in WG_WHY
#   neither - never a product failure
wedge_disposition(){
  case "${1:?wedge_disposition <class>}" in
    WEDGE-SPIN|WEDGE-BLOCKED)  echo "fatal wedge" ;;
    WEDGE-SPIN-CANDIDATE|WEDGE-BLOCKED-CANDIDATE) echo "undecided" ;;
    RECOVERY|UNREADABLE-CPU|UNREADABLE-SCREEN|RESTART-UNEXPLAINED) echo "fatal" ;;
    UNRESPONSIVE-WITH-PIXELS)  echo "fatal product" ;;
    QREXEC-QUEUE-RESTART)      echo "wait" ;;
    QREXEC-DEAD-ALIVE)         echo "fatal product" ;;
    BOOTING|SHUTTING-DOWN|ALIVE-RECENT) echo "wait" ;;
    ALIVE)                     echo "ok" ;;
    INSTRUMENT-FAILURE|DOMAIN-GONE) echo "neither" ;;
    *)                         echo "unknown" ;;
  esac
}

# wedge_record_required <evidence-dir> - the REQUIRED tier, every item obtainable with NO qrexec and
# NO prior arming. The kill gate reads exactly this. The BEST-EFFORT tier (the ELF core, and the
# module-base table for the wedging boot) is recorded as absent WITH ITS REASON and never blocks a
# kill: a guest whose FIRST boot wedges can never have an onstart task, and a kill refused forever
# leaves a wedged guest holding the rig.
WG_RECORD_REQUIRED="class.txt why.txt listing.txt vmcs.txt vcpu-samples.txt screen.txt harness.txt"
wedge_record_complete(){
  local d="${1:?wedge_record_complete <dir>}" f missing=""
  for f in $WG_RECORD_REQUIRED; do [ -s "$d/$f" ] || missing="$missing $f"; done
  printf '%s' "$missing"
  [ -z "$missing" ]
}

# wedge_may_kill <record-dir> - the kill DEPENDS on the record. Jev 0.76.
wedge_may_kill(){
  local d="${1:?wedge_may_kill <record-dir>}" missing
  missing=$(wedge_record_complete "$d") || {
    _wg_say "REFUSING TO KILL: the wedge record is incomplete, missing:$missing"
    _wg_say "  A kill destroys the only live state there is. On 2026-10-22 the subject was killed at"
    _wg_say "  600s with nothing captured, and the specimen has no resolvable RIP as a result."
    return 1
  }
  _wg_say "kill permitted: the required record is complete in $d"
  return 0
}

# wedge_fatal_gate <class> <where> - THE abort. One implementation, sourced by matrix.sh,
# release-acceptance.sh and campaign-full.sh, so the three cannot drift (Jev 0.99). Returns 0 when
# the caller may continue, 1 when it must stop.
wedge_fatal_gate(){
  local class="${1:?wedge_fatal_gate <class> <where>}" where="${2:-caller}" disp
  disp=$(wedge_disposition "$class")
  case "$disp" in
    *fatal*)
      _wg_say "FATAL at $where: class=$class disposition='$disp' - this run stops, and so does every caller above it"
      [ "${disp#*wedge}" != "$disp" ] && _wg_say "  a wedge record is MANDATORY before anything kills the subject"
      return 1 ;;
    undecided)
      _wg_say "UNDECIDED at $where: class=$class - stage 2 must run before any disposition is acted on"
      return 1 ;;
    *) return 0 ;;
  esac
}

# wedge_collect <vm> <outdir> - fill an evidence dir from a LIVE guest, host-side.
# Every item is best-effort EXCEPT the required tier, which is what wedge_may_kill reads. Nothing
# here needs the guest to cooperate apart from the one bounded qrexec probe that defines ALIVE, and
# that probe's failure is recorded as SILENT rather than treated as proof of anything.
wedge_collect(){
  local vm="${1:?wedge_collect <vm> <outdir>}" d="${2:?wedge_collect <vm> <outdir>}" i
  mkdir -p "$d" || return 2
  # THE LOCK, because this drives a guest (lint L2). vm_lock is a no-op when an ancestor already
  # holds THIS guest, which is the normal case here: the campaign owns the subject and this runs
  # inside it. Taking it when nobody does matters for the other case - a classification run against
  # a guest left up as a specimen, which must not race a second harness onto it.
  if [ "${QWT_VMLOCK_HELD:-}" != "$vm" ]; then
    declare -F vm_lock >/dev/null 2>&1 || . mgmt/harness/vmlock.sh
    vm_lock "$vm" || { echo "wedge_collect: could not take the vmlock for $vm"; return 2; }
  fi
  printf '%s\n' "$vm" > "$d/vm"; date +%s > "$d/now"

  # O1 the FULL listing: an empty one is an instrument failure, never "the vm is absent"
  qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | tr '|' ' ' > "$d/listing.txt"
  # dom0 reachable? the classifier's own instruments all ride this
  if timeout 25 qrexec-client-vm dom0 "local.WinWedgeForensics+$vm" </dev/null >/dev/null 2>&1; then
    printf '1\n' > "$d/dom0-ok"; else printf '0\n' > "$d/dom0-ok"; fi

  # the context the CALLER holds; absent is absent, never invented
  [ -n "${WG_C1:-}" ] && printf '%s\n' "$WG_C1" > "$d/c1"
  [ -n "${WG_C2:-}" ] && printf '%s\n' "$WG_C2" > "$d/c2"
  [ -n "${WG_C4:-}" ] && printf '%s\n' "$WG_C4" > "$d/c4"

  # O8 + restarts, both read from THIS qube only
  printf '%s\n' "$(pgrep -f "qrexec-client-vm [${vm:0:1}]${vm:1} " 2>/dev/null | grep -cv "^$$\$")" > "$d/pending-qrexec"
  [ -n "${WG_RESTARTS:-}" ] && printf '%s\n' "$WG_RESTARTS" > "$d/restarts"

  # O3 one bounded probe. SILENT is a measurement, not a verdict.
  if QTEST_VM="$vm" timeout "$WG_QREXEC_PROBE" ./tools/qtest run "cmd /c echo WGALIVE" 2>/dev/null | tr -d '\r\0' | grep -qa WGALIVE; then
    printf 'ANSWERED\n' > "$d/qrexec"; date +%s > "$d/c4"
  else printf 'SILENT\n' > "$d/qrexec"; fi

  # O4 the framebuffer, which dom0 draws whether or not the guest's agent lives
  if declare -F w_screen >/dev/null 2>&1 || . mgmt/harness/e2e-wait.sh 2>/dev/null; then
    w_screen "$vm" "wedge" "$d" > "$d/screen" 2>/dev/null || printf '\n' > "$d/screen"
  fi
  cp -f "$d/screen" "$d/screen.txt" 2>/dev/null || : > "$d/screen.txt"

  # O2 + O9 from ONE dom0 capture: the vcpu fraction (corroboration) and the VMCS (the decider)
  declare -F wedge_classify >/dev/null 2>&1 || . mgmt/harness/wedge-lib.sh 2>/dev/null
  if declare -F wedge_classify >/dev/null 2>&1; then
    wedge_classify "$vm" > "$d/vcpu-samples.txt" 2>&1 || :
    case "$(head -1 "$d/vcpu-samples.txt" 2>/dev/null)" in
      SPIN*)    printf 'SPIN\n'    > "$d/fraction" ;;
      BLOCKED*) printf 'BLOCKED\n' > "$d/fraction" ;;
      *)        printf 'UNREADABLE\n' > "$d/fraction" ;;
    esac
  else : > "$d/vcpu-samples.txt"; printf 'UNREADABLE\n' > "$d/fraction"; fi

  # O9 proper: two VMCS samples, ActivityState + RIP per vCPU, decoded by tools/wedge-vmcs.py.
  # ActivityState is the VMCS enum, so this is structural and not a threshold over overlapping bands.
  : > "$d/vmcs.txt"
  for i in 1 2; do
    if timeout 300 qrexec-client-vm dom0 "local.WinWedgeForensics+$vm" </dev/null > "$d/forensics-$i.tar" 2>/dev/null \
       && [ -s "$d/forensics-$i.tar" ]; then
      python3 tools/wedge-vmcs.py "$d/forensics-$i.tar" >> "$d/vmcs.txt" 2>/dev/null || :
    fi
    [ "$i" = 1 ] && sleep "$WEDGE_SAMPLE_SECS" 2>/dev/null || sleep 10
  done
  # ACTIVE only when a vCPU is Active in BOTH samples; HLT only when every vCPU is HLT in both.
  local act=""; local a1 a2
  a1=$(awk '/activity/{next} NF>6{print $8}' "$d/vmcs.txt" 2>/dev/null | head -8 | tr '\n' ' ')
  if printf '%s' "$a1" | grep -qE '\<0x?0+\>' 2>/dev/null; then act=ACTIVE
  elif [ -n "$a1" ] && ! printf '%s' "$a1" | grep -qvE '\<0x?0*1\>' 2>/dev/null; then act=HLT; fi
  printf '%s\n' "$act" > "$d/vmcs-activity"
  # RIP static across the two samples?
  a1=$(grep -oE '0x[0-9a-f]{6,}' "$d/vmcs.txt" 2>/dev/null | head -1)
  a2=$(grep -oE '0x[0-9a-f]{6,}' "$d/vmcs.txt" 2>/dev/null | tail -1)
  if [ -n "$a1" ] && [ "$a1" = "$a2" ]; then printf '1\n' > "$d/vmcs-rip-static"; else printf '0\n' > "$d/vmcs-rip-static"; fi

  # the harness's own account, so a reader knows what was running when this was taken
  { printf 'harness-pid=%s\n' "$$"
    printf 'harness-cmd=%s\n' "$(tr '\0' ' ' < "/proc/$$/cmdline" 2>/dev/null)"
    printf 'taken-utc=%s\n' "$(date -u +%FT%TZ)"
    printf 'vm=%s\n' "$vm"
  } > "$d/harness.txt"
  return 0
}
