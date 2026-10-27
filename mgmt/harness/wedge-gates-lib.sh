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
# unreliable inputs is still only as good as the inputs, so an unmeasured conjunct is always a
# first-class answer here rather than a coin-flip.
#
# WHICH INDICATOR DECIDES WHAT (owner, 2026-10-22: "CPU is weak indicator. we have strong ones."
# and "can we RELIABLY detect 'ACPI is not responding'? it is the main one"). Ranked:
#   STRONG, and each one is a CONJUNCT of the definition:
#     ACPI ignored  - the main one. A bounded, RE-ASKED request via shutdown-lib.sh's qwt_shutdown,
#                     whose rc already separates honoured / no-effect / rebooted / unknown. Session
#                     identity is host-side (DOMID) so it works on a guest with no qrexec at all.
#     no pixels     - O4 over dom0's own framebuffer. Definitional: a guest that draws is not wedged.
#     present       - O1 over the full listing.
#   STRONG, corroborating but never deciding:
#     O9 VMCS ActivityState + static RIP, and in the same dump InterruptStatus (RVI/SVI) and
#        Interruptibility - hardware fields, no thresholds.
#   WEAK, label only:
#     O2 the vCPU consumed/interval fraction against SPIN_FRACTION=0.5 - a threshold on a 10 s
#        sample over bands wedge-lib.sh's own calibration says overlap.
# The CPU reading therefore names WHICH wedge and may never decide WHETHER one is present.

# toolstack_accept and qrexec_last_packet come from the sealed primitives. Self-guarded, the same
# way this file already guards logvol_pull: three different scripts source this library, and an
# undefined toolstack_accept would return 127 and be read as "the toolstack REFUSED the request",
# which is the one verdict here that rests on that number.
declare -F toolstack_accept >/dev/null 2>&1 \
  || . "$(dirname "${BASH_SOURCE[0]}")/primitives.sh" 2>/dev/null || true

WG_CLASS=""; WG_WHY=""; WG_LINES=""; WG_SHAPE=""; WG_SHAPE_WHY=""; WG_LASTPKT=""

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
# wedge-lib.sh owns this one, but this file reads it too and MUST NOT depend on having sourced
# that file first: a caller running with `set -u` dies on the bare reference, which is how the
# first live capture of 2026-10-22 ended - "WEDGE_SAMPLE_SECS: unbound variable", mid-collect,
# after the vmlock was taken. Every externally-settable name this file reads carries a default.
WEDGE_SAMPLE_SECS="${WEDGE_SAMPLE_SECS:-10}"

_wg_say(){ WG_LINES="${WG_LINES}$*"$'\n'; }
_wg_get(){ [ -s "$1/$2" ] && tr -d '\r\n' < "$1/$2" || printf ''; }

# Where this library lives, so it can source its siblings (shutdown-lib.sh) wherever the caller
# was launched from. BASH_SOURCE, not $0: $0 is the CALLER's name when this file is sourced.
WG_DIR="${WG_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# O1 and the host-side session identity, from ONE listing shape. The FULL list is read on purpose:
# an empty list is an instrument failure, and a single-qube read cannot tell that from an absent
# qube. XID measured readable from this qube 2026-10-22 (win11de-uc|Running|17891).
_wg_list(){ qvm-ls --raw-data --fields NAME,STATE,XID 2>/dev/null; }
_wg_state(){ _wg_list | awk -F'|' -v v="$1" '$1==v{print $2; f=1} END{if(!f) print ""}'; }
_wg_xid(){   _wg_list | awk -F'|' -v v="$1" '$1==v && $3 ~ /^[0-9]+$/ {print $3}'; }

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
  # EVERY output reset, shape included: a stale shape from the previous guest classified in the same
  # process would otherwise survive into a tree that returns before T9 ever sets it.
  WG_CLASS=""; WG_WHY=""; WG_SHAPE=""; WG_SHAPE_WHY=""; WG_LASTPKT=""
  local listing="$d/listing.txt" vm; vm=$(_wg_get "$d" vm)
  [ -n "$vm" ] || { WG_CLASS="INSTRUMENT-FAILURE"; WG_WHY="no subject named (lint L10: never default a target)"; return 0; }

  # T1 instrument health. "We cannot measure" is not a guest state, and must never be reported as one.
  # dom0-ok, when a record carries it, still means what it meant: a caller that could not reach
  # dom0 at all. Records written after 2026-10-22 omit it (see wedge_collect), and an omitted
  # instrument reading is not a failing one - T1 only fires on an explicit 0.
  # THE PREDICATE IS THE PROPERTY, not a proxy for it. This read `[ "$dom0ok" != 1 ]` while its own
  # comment said "fires only on an explicit 0" - and when the separate dom0 probe was removed as
  # unsound, every record written afterwards had no dom0-ok at all and so classified
  # INSTRUMENT-FAILURE, including a guest that answered qrexec in the same record. MEASURED on
  # win11de-uc, 2026-10-22. An ABSENT instrument reading is not a failing one; what fires this now
  # is positive evidence of a broken instrument: an empty listing, or an explicit 0 from a caller
  # that recorded one.
  local dom0ok; dom0ok=$(_wg_get "$d" dom0-ok)
  if [ ! -s "$listing" ] || [ "$dom0ok" = 0 ]; then
    WG_CLASS="INSTRUMENT-FAILURE"
    WG_WHY="O1 listing $( [ -s "$listing" ] && echo present || echo 'EMPTY/unparseable' ), dom0 reachable=${dom0ok:-not recorded}"
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
  # T9 THE WEDGE BRANCH. Owner, 2026-10-22: "CPU is weak indicator. we have strong ones."
  #
  # WHAT THIS REPLACES, and it was live in the first commit. The first tree made the vCPU picture
  # DECIDE candidacy: an unreadable or self-contradicting CPU reading produced UNREADABLE-CPU and the
  # guest was never a wedge candidate at all. That is backwards twice over. The definition the owner
  # gave - "it is there, displays no pixels whatsoever and does not respond to acpi shutdown either"
  # - names three conjuncts and NONE of them is a CPU fraction. Two of the three are already
  # established by the time control reaches here (present at T2, no pixels at T8c, qrexec dead at
  # T5/T8); the third is stage 2's ACPI ask. The CPU reading is not a conjunct, so it may not veto
  # one. And the veto was not hypothetical: the ONE real specimen we have - the 2026-10-22 guest -
  # was captured with no VMCS at all, so the CPU-deciding tree classified the only wedge this
  # project has ever held as UNREADABLE-CPU, which is not a wedge. The instrument that denies the
  # finding on the only subject that has it is the wrong instrument.
  #
  # So candidacy is now unconditional here, and the CPU picture sets the SHAPE only - a label on a
  # wedge, never a gate in front of one. Ranked by strength, strongest first:
  #   O9  VMCS ActivityState + RIP static across two samples, from `xl debug-keys v` via
  #       tools/wedge-vmcs.py. STRUCTURAL: HLT vs ACTIVE is a hardware field, not a rate. The same
  #       dump carries InterruptStatus (RVI low byte / SVI high) and Interruptibility, which is the
  #       direct answer to "did the IPI reach the target's vLAPIC" - one recorded bundle showed
  #       RVI=0xE1, the Windows IPI vector, latched on a vCPU that never took it while three others
  #       spun in nt!KiIpiSendRequestEx (dom0/11-wedge-forensics.sh, step 3b).
  #   O2  the per-vCPU consumed/interval fraction against SPIN_FRACTION=0.5. WEAK: a threshold on a
  #       10 s sample, and the measured bands overlap (pegged 130,976 vs idle-unreachable 96,262).
  #       It may CORROBORATE O9 and it may never outvote it.
  local act rip2 frac rvistuck
  act=$(_wg_get "$d" vmcs-activity); rip2=$(_wg_get "$d" vmcs-rip-static); frac=$(_wg_get "$d" fraction)
  # A vector latched on the SAME vCPU in BOTH samples is one that is NOT being taken - the recorded
  # wedge signature (RVI=0xE1, the Windows IPI vector, on a vCPU that never took it while others
  # spun in nt!KiIpiSendRequestEx). It is CORROBORATION on the shape, never a gate on candidacy, and
  # its calibration is measured: a live healthy guest showed RVI=0xd1 in one sample and nothing in
  # the next - an interrupt in flight, which is what working delivery looks like (win11de-uc,
  # 2026-10-22). One sample cannot separate those; the both-samples form can.
  rvistuck=$(_wg_get "$d" vmcs-rvi-stuck)
  local allhlt allblk pause
  allhlt=$(_wg_get "$d" vmcs-exit-all-hlt); allblk=$(_wg_get "$d" vmcs-runstate-all-blocked)
  pause=$(_wg_get "$d" vmcs-pause-loop-vcpu)
  WG_CLASS="WEDGE-CANDIDATE"
  if [ "$act" = HLT ] && [ "$frac" = SPIN ]; then
    # CONTRADICTION FIRST, in both directions. This guard was lost when the shape tree was
    # restructured and the suite caught it: ActivityState saying every vCPU is halted while O2 says
    # SPIN is a measurement problem, and naming a shape from it would be picking a favourite
    # instrument. (The mirrored case - Active with a static RIP while O2 says BLOCKED - is below.)
    WG_SHAPE="UNKNOWN"; WG_SHAPE_WHY="O9 says every vCPU is HLT but O2 says SPIN - the instruments contradict"
  elif [ "$act" = HLT ]; then
    # The SDM-correct reading, kept although it has never been observed on this hardware.
    WG_SHAPE="BLOCKED"; WG_SHAPE_WHY="O9 ActivityState is HLT on every vCPU in both samples"
  elif [ "$allhlt" = 1 ] && [ "$allblk" = 1 ]; then
    # WHAT A HALTED GUEST ACTUALLY SHOWS, measured: ActivityState stayed 0x00 on all four vCPUs of a
    # live guest while three of them had taken exit 12 (HLT) and sat in runstate -b- (win11de-uc,
    # 2026-10-22). Xen deschedules a halted vCPU instead of parking it in the VMX HLT activity
    # state, so an activity-only test for "every vCPU halted" is near-dead code here.
    WG_SHAPE="BLOCKED"; WG_SHAPE_WHY="every vCPU took exit 12 (HLT) in both samples and every runstate reads blocked - which is how a halted guest presents, ActivityState staying 0x00"
  elif [ "$act" = ACTIVE ] && [ "$rip2" = 1 ]; then
    if [ -n "$pause" ]; then
      WG_SHAPE="SPIN"; WG_SHAPE_WHY="vcpu$pause took a PAUSE-loop exit (40) in BOTH samples with its RIP unchanged - a spin, structurally${rvistuck:+, and RVI=$rvistuck is latched across both samples on one vCPU: a vector that is not being taken}"
    elif [ "$frac" = BLOCKED ]; then
      WG_SHAPE="UNKNOWN"; WG_SHAPE_WHY="O9 says Active with a static RIP but O2 says BLOCKED - the instruments contradict, so the shape is not named (candidacy is unaffected: the shape is a label)"
    else
      WG_SHAPE="SPIN"; WG_SHAPE_WHY="O9 shows a vCPU Active in both samples with RIP unchanged${frac:+, and O2 corroborates $frac}${rvistuck:+; and RVI=$rvistuck is latched on one vCPU across BOTH samples - a vector that is not being taken}"
    fi
  elif [ "$act" = ACTIVE ]; then
    WG_SHAPE="UNKNOWN"; WG_SHAPE_WHY="O9: Active but the RIP advanced between samples - executing, so neither spinning nor idle"
  else
    WG_SHAPE="UNKNOWN"; WG_SHAPE_WHY="O9 unavailable or mixed (activity='${act:-absent}', exit-all-hlt='${allhlt:-absent}', runstate-all-blocked='${allblk:-absent}') - stated, never guessed"
  fi
  printf '%s\n' "$WG_SHAPE" > "$d/shape" 2>/dev/null || true
  # "QREXEC SILENT" IS A CLAIM ABOUT QREXEC, so the last packet type it handled goes on record here
  # rather than being left to inference - and 'unrecorded' is printed as such, never as 'none'.
  # The third conjunct (ACPI, through toolstack_accept) is still asked LAST, below: asking it here
  # to satisfy a grep would reorder the definition and ask it as the second conjunct instead.
  WG_LASTPKT=$(qrexec_last_packet "$vm" "$d")
  WG_WHY="present, no pixels (O4=$screen) and qrexec silent past ${WG_QREXEC_BOUND}s (last qrexec packet: $WG_LASTPKT) - the two host-side conjuncts of the definition hold. ACPI is the third and is NOT yet asked. Shape=$WG_SHAPE ($WG_SHAPE_WHY)"
  return 0
}

# =============================================================================================
# THE ACPI OBSERVATION - the main indicator. Owner, 2026-10-22: "can we RELIABLY detect 'ACPI is
# not responding'? it is the main one".
#
# YES, and almost all of it was already coded in mgmt/harness/shutdown-lib.sh. That file is the
# only sanctioned asker and this one does not re-implement it:
#   - a BARE `qvm-shutdown` is the ACPI request: it returns at once and kills nothing. NEVER
#     `qvm-shutdown --wait`, which is a KILL ON A TIMER - the default --timeout 60 destroys the
#     domain, and wrapping it in `timeout 300` does not buy 300 s, the kill still lands at 60 with
#     rc=0 (findings/rig.md: it was in ten harness files, one of which killed the guest it was
#     about to shut down).
#   - the request is RE-ASKED every 120 s while polling, because one request can be lost or can
#     land while the guest is busy, and a lost request read as a refusal is a fabricated wedge
#     (DEGOLDENHALTSLOW, fixed 2026-10-21).
#   - an UNREADABLE rig is not Halted and not gone; an ABSENT qube is not "still up".
# qwt_shutdown already separates the four meanings by return code, which is the whole question:
#   0 halted on its own                     -> ACPI was HONOURED
#   1 still up at the deadline, SAME SESSION -> the request genuinely had no effect  <-- the finding
#   2 still up but the guest REBOOTED        -> it is not ignoring anything (this is exactly the
#     "has qrexec queue and restarts rapidly" case the owner excluded from the definition)
#   3 still up and we COULD NOT TELL         -> unknown, and never named either way
#   4 the rig could not be read              -> instrument
#
# THE GAP, and it is the one that matters here. rc=1 means "same session" because qwt_shutdown
# samples THE GUEST'S OWN BOOT TIME before and after - one qrexec call. A wedge has no qrexec. So
# on the only subject this gate exists for, both samples come back empty and qwt_shutdown returns
# 3, not 1: the existing instrument cannot say "same session" about a wedge AT ALL, by
# construction. Taking rc=3 as "ACPI ignored" would be exactly the fabrication its header warns
# about ("nothing measured says a QWT-less Windows ignores the power button").
#
# SO THE SESSION IDENTITY COMES FROM THE HOST INSTEAD, needing no guest cooperation: the DOMID.
# A Qubes HVM reboot destroys and recreates the domain, so the domid moves; a guest that sat
# through the whole bound on one domid did not reboot. MEASURED readable from this qube
# 2026-10-22: `qvm-ls --raw-data --fields NAME,STATE,XID` -> `win11de-uc|Running|17891`. It is the
# same identity dom0/11-wedge-forensics.sh writes to domid.txt and keys its whole bundle on.
#
# wedge_acpi_probe <vm> <evidence-dir> - asks, observes, and writes the observation. Never kills.
wedge_acpi_probe(){
  local vm="${1:?wedge_acpi_probe <vm> <dir>}" d="${2:?wedge_acpi_probe <vm> <dir>}" rc x0 x1 st why res
  mkdir -p "$d"
  x0=$(_wg_xid "$vm"); printf '%s\n' "$x0" > "$d/xid-before"
  # shellcheck disable=SC1091
  if ! declare -F qwt_shutdown >/dev/null 2>&1; then
    [ -r "$WG_DIR/shutdown-lib.sh" ] && . "$WG_DIR/shutdown-lib.sh"
  fi
  if ! declare -F qwt_shutdown >/dev/null 2>&1; then
    printf 'UNREADABLE\n' > "$d/acpi-result"
    printf 'shutdown-lib.sh could not be sourced - the ACPI ask was NOT made, so nothing is known about it\n' > "$d/acpi-why"
    return 0
  fi
  qwt_shutdown "$vm" "$WG_ACPI_BOUND" > "$d/acpi-log.txt" 2>&1; rc=$?
  wedge_acpi_record "$d" "$rc" "$x0" "$vm" "$WG_ACPI_BOUND"
  return 0
}

# wedge_acpi_record <dir> <qwt_shutdown-rc> <xid-before> <vm> - map an ASK THAT ALREADY HAPPENED.
# Split out because the ask is usually NOT ours to make: tools/release-acceptance.sh's settle_rig
# calls qwt_shutdown itself, on every guest, as ordinary rig hygiene. Before 2026-10-22 it threw
# that return code away into a boolean `if ! qwt_shutdown` - so the single strongest indicator in
# the whole gate was already being measured, on the exact guest that mattered, and discarded. One
# mapping, two entry points, so a recorded ACPI verdict means the same thing wherever it came from.
wedge_acpi_record(){
  local d="${1:?wedge_acpi_record <dir> <rc> <xid0> <vm> <deadline>}" rc="${2?}" x0="${3-}" vm="${4:?}"
  # THE DEADLINE IS AN ARGUMENT, NOT A GLOBAL, and it is required. Jev, 2026-10-22: the one
  # unhandled confound in this predicate was that the two bounds disagree - the caller asks with
  # its own deadline (release-acceptance settles at 600 s) while the recorded reason named
  # WG_ACPI_BOUND (300). A conclusion stated against a number that was never the measurement is
  # not evidence, whichever way it errs, so the ask writes down the bound it actually used.
  local bound="${5:?wedge_acpi_record needs the deadline that was ACTUALLY asked with}"
  local x1 st why res
  mkdir -p "$d"
  printf '%s\n' "$bound" > "$d/acpi-bound"
  x1=$(_wg_xid "$vm"); printf '%s\n' "$x1" > "$d/xid-after"
  st=$(_wg_state "$vm"); printf '%s\n' "$st" > "$d/state-after-acpi"
  printf '%s\n' "$rc" > "$d/acpi-rc"
  [ -s "$d/xid-before" ] || printf '%s\n' "$x0" > "$d/xid-before"
  case "$rc" in
    0) res=HALTED;   why="qwt_shutdown rc=0: the guest reached Halted on its own" ;;
    2) res=REBOOTED; why="qwt_shutdown rc=2: the guest's own boot time MOVED while we waited - it went down and came back, so it is not ignoring anything" ;;
    1) res=NOT-HALTED; why="qwt_shutdown rc=1: still up at the ${bound}s deadline and the GUEST'S OWN boot time is unchanged - the request had no effect, measured guest-side" ;;
    4) res=UNREADABLE; why="qwt_shutdown rc=4: the rig could not be read, which is not a guest state" ;;
    3)
      # The wedge case. Fall back to the host-side session identity.
      if [ -z "$x0" ] || [ -z "$x1" ]; then
        res=UNREADABLE; why="qwt_shutdown rc=3 (guest boot time unreadable) and the domid was also unreadable (before='${x0:-absent}' after='${x1:-absent}') - no session identity from either side, so this is NOT named"
      elif [ "$x0" != "$x1" ]; then
        res=REBOOTED; why="qwt_shutdown rc=3 (no guest clock) but the DOMID moved $x0 -> $x1: the domain was destroyed and recreated, so the guest rebooted and is not ignoring ACPI"
      elif [ "$st" != Running ]; then
        res=UNREADABLE; why="qwt_shutdown rc=3 (asked with a ${bound}s deadline) and the post-ask state is '${st:-unreadable}', neither Running nor Halted - not named"
      else
        res=NOT-HALTED; why="qwt_shutdown rc=3 (no qrexec, so no guest clock - expected of a wedge), AND the domid is unchanged at $x0 across the whole ${bound}s with the domain still Running: the ACPI request was re-asked every 120s and had no effect on the SAME domain instance. Session identity is host-side here, not guest-side."
      fi ;;
    *) res=UNREADABLE; why="qwt_shutdown returned an unexpected rc=$rc" ;;
  esac
  # WAS THE REQUEST EVEN ACCEPTED? Jev, 2026-10-22, named the one confound left in this predicate
  # as "nothing verifies the request reached the guest" (0.50): a toolstack-side refusal, or a
  # request lost before it got there, is indistinguishable from a guest ignoring one - and "it
  # ignored ACPI" is the conjunct that turns a candidate into a wedge. qwt_shutdown issues
  # `timeout 120 qvm-shutdown "$vm"` and discards that status, so the information existed and was
  # thrown away.
  #
  # AND THE EVIDENCE IS ASYMMETRIC, which is the whole point and was got wrong on the first attempt.
  # Jev, on that attempt, at 0.98: "a qvm-shutdown that returns 0 only means the toolstack ACCEPTED
  # the request, not that the guest's ACPI was reached - so the delivery check does not close the gap
  # it was added for." Correct. A REFUSAL falsifies delivery and is therefore decisive; an acceptance
  # verifies nothing beyond the toolstack's own queue. So this records both and claims only the
  # first: a refused request downgrades the verdict to UNREADABLE, and an accepted one leaves the
  # verdict standing while saying IN THE REASON that acceptance is not proof the guest saw it. The
  # residual gap is real, is named in the record, and is not papered over by a check that cannot
  # close it.
  #
  # A bare qvm-shutdown IS the ACPI request: it returns at once, kills nothing, and is idempotent -
  # which is why shutdown-lib re-asks every 120 s by design. It is issued once more only before
  # NOT-HALTED, the single verdict that rests on the request having been made at all.
  if [ "$res" = NOT-HALTED ]; then
    # toolstack_accept (mgmt/harness/primitives.sh) IS this request, and it records the acceptance
    # on its own run-id-scoped ledger as well - which is what lets a later unusable verdict cite
    # the toolstack's answer instead of re-asking and destroying a live specimen. No timeout: a
    # bare ACPI request returns at once, as the note above records.
    local ark _tsa
    _tsa=$(toolstack_accept "$vm" acpi 2>&1); ark=$?
    printf '%s\n' "$_tsa" > "$d/acpi-reask.log"
    printf '%s\n' "$ark" > "$d/acpi-reask-rc"
    if [ "$ark" -ne 0 ]; then
      res=UNREADABLE
      why="the guest was still up on the same domain, but the ACPI request itself was REFUSED when re-issued (qvm-shutdown rc=$ark). A request that cannot be delivered is not a request that was ignored, so the deciding conjunct is unproven. Earlier observation, for the record: $why"
    else
      why="$why. The request was re-issued at the end and ACCEPTED by the toolstack (qvm-shutdown rc=0) - which rules out a toolstack-side refusal but does NOT prove the guest's ACPI was reached, so that gap stays open and is stated rather than closed."
    fi
  fi
  printf '%s\n' "$res" > "$d/acpi-result"
  printf '%s\n' "$why" > "$d/acpi-why"
  _wg_say "ACPI: $res ($why)"
  return 0
}

# wedge_stage2 <evidence-dir> - the ONLY step that intervenes: the bounded ACPI ask, above.
# Split out so stage 1 can never be changed by having been asked.
#   <dir>/acpi-result = HALTED | NOT-HALTED | REBOOTED | UNREADABLE
#   <dir>/shape       = SPIN | BLOCKED | UNKNOWN   (a LABEL from stage 1, never a gate)
# ACPI decides wedge-or-not. The shape only names which wedge, so an unknown shape yields
# WEDGE-UNKNOWN-SHAPE - still a wedge, still fatal, still preserved. It must not be demoted to a
# measurement problem: that is the inversion the owner corrected, and it is how the only real
# specimen we hold would have been thrown away.
wedge_stage2(){
  local d="${1:?wedge_stage2 <evidence-dir>}" r shape acpiwhy
  r=$(_wg_get "$d" acpi-result)
  shape=$(_wg_get "$d" shape); [ -n "$shape" ] || shape=$(_wg_get "$d" candidate)
  acpiwhy=$(_wg_get "$d" acpi-why)
  # The bound AS ASKED, read from the record. Stage 2 states what was measured, not a default it
  # happens to have compiled in.
  local bound; bound=$(_wg_get "$d" acpi-bound); [ -n "$bound" ] || bound="an unrecorded"
  case "$r" in
    HALTED)
      WG_CLASS="QREXEC-DEAD-ALIVE"
      WG_WHY="the ACPI ask was HONOURED within ${bound}s ($acpiwhy), so the third conjunct of a wedge FAILS - a PRODUCT failure, not a wedge. This is what separated win11-acc from win11-upgrade on 2026-10-22." ;;
    REBOOTED)
      WG_CLASS="RESTART-UNEXPLAINED"
      WG_WHY="the guest RESTARTED across the ACPI ask ($acpiwhy). The owner's definition excludes this explicitly - it is not to be confused with 'has qrexec queue and restarts rapidly'. Fatal, not a wedge." ;;
    NOT-HALTED)
      case "$shape" in
        SPIN|WEDGE-SPIN-CANDIDATE)       WG_CLASS="WEDGE-SPIN";          WG_WHY="ALL THREE conjuncts hold: present, no pixels, and ACPI ignored for ${bound}s ($acpiwhy). Shape: a vCPU spinning on an unchanged RIP." ;;
        BLOCKED|WEDGE-BLOCKED-CANDIDATE) WG_CLASS="WEDGE-BLOCKED";       WG_WHY="ALL THREE conjuncts hold: present, no pixels, and ACPI ignored for ${bound}s ($acpiwhy). Shape: every vCPU HLT." ;;
        *)                               WG_CLASS="WEDGE-UNKNOWN-SHAPE"; WG_WHY="ALL THREE conjuncts hold: present, no pixels, and ACPI ignored for ${bound}s ($acpiwhy). The SHAPE is not named ('${shape:-absent}') - which costs us the spin site, not the finding. This is a wedge." ;;
      esac ;;
    *) WG_CLASS="UNREADABLE-ACPI"; WG_WHY="the ACPI observation is '${r:-absent}' - ${acpiwhy:-no reason recorded}. The decisive conjunct is UNMEASURED, so the guest is neither cleared nor called a wedge, and it is preserved." ;;
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
    WEDGE-SPIN|WEDGE-BLOCKED|WEDGE-UNKNOWN-SHAPE)  echo "fatal wedge" ;;
    WEDGE-CANDIDATE|WEDGE-SPIN-CANDIDATE|WEDGE-BLOCKED-CANDIDATE) echo "undecided" ;;
    RECOVERY|UNREADABLE-CPU|UNREADABLE-SCREEN|UNREADABLE-ACPI|RESTART-UNEXPLAINED) echo "fatal" ;;
    UNRESPONSIVE-WITH-PIXELS)  echo "fatal product" ;;
    QREXEC-QUEUE-RESTART)      echo "wait" ;;
    QREXEC-DEAD-ALIVE)         echo "fatal product" ;;
    BOOTING|SHUTTING-DOWN|ALIVE-RECENT) echo "wait" ;;
    ALIVE)                     echo "ok" ;;
    INSTRUMENT-FAILURE|DOMAIN-GONE) echo "neither" ;;
    *)                         echo "unknown" ;;
  esac
}

# TWO INDEPENDENT AXES, and conflating them is a defect in each direction.
# Owner, 2026-10-22: "failures other than wedge may still be fatal."
#
#   wedge_is_fatal       - does the CAMPAIGN STOP? Nine classes are fatal and only three of them
#                          are wedges. A non-wedge fatal (a RECOVERY screen, a guest that answers
#                          ACPI but never qrexec, an unexplained restart, any UNREADABLE verdict on
#                          a decisive conjunct) must stop the run just as hard. The 2026-10-22
#                          campaign walked PAST an aborted matrix into the feature tests, which is
#                          this exact axis being absent.
#   wedge_must_preserve  - is the GUEST the only copy of the evidence? Orthogonal. QREXEC-DEAD-ALIVE
#                          is fatal and NOT preserved (it halted when asked - there is nothing left
#                          to hold); UNRESPONSIVE-WITH-PIXELS is fatal AND preserved (a live failure
#                          with a readable screen is a specimen); BOOTING is not fatal at all.
#
# The preserve axis is the one that must fail SAFE, so it is stated as the complement of a short
# explicit list: anything this table has never heard of is PRESERVED, not killed.
wedge_is_fatal(){
  case "$(wedge_disposition "${1:?wedge_is_fatal <class>}")" in
    fatal|"fatal wedge"|"fatal product"|undecided|unknown) return 0 ;;
    *) return 1 ;;
  esac
}
#   wedge_must_preserve  - must this guest be HELD? As of 2026-10-22 this is a property of the
#                          RECORD, not of the class. Holding a guest buys exactly one thing: another
#                          chance to get the antecedent off it. So it is required when the class is a
#                          failure AND the stick was not read, and pointless otherwise - the owner's
#                          "preservation per se makes little sense", with Jev at 0.70 for "kill,
#                          conditional on holding the antecedent". Called with only a class (no
#                          record) it answers the dispositional question alone, which is what the
#                          campaign's stop message needs before any record exists.
wedge_must_preserve(){
  local c="${1:?wedge_must_preserve <class> [record-dir]}" d="${2:-}" _k lvs
  for _k in $WG_KILL_SAFE; do [ "$c" = "$_k" ] && return 1; done
  case "$(wedge_disposition "$c")" in
    wait|ok|neither) return 1 ;;   # nothing failed, so there is nothing to hold it for
  esac
  [ -n "$d" ] || return 0          # a failure with no record yet: hold until there is one
  lvs=$(_wg_get "$d" logvol-status)
  case "$lvs" in
    pulled)        [ -s "$d/logvol/pull.txt" ] && return 1 ;;  # we have what it was for
    declared-none) return 1 ;;
    no-stick)
      # Holding cannot produce a stick that was never attached. It CAN keep the guest while its
      # private volume is read, so the hold ends when the record says where the antecedent is.
      if [ -s "$d/antecedent-location" ]; then
        case "$(_wg_get "$d" antecedent-reachable)" in
          qrexec)      return 1 ;;
          volume-only) [ -s "$d/volume-hold" ] && return 1 ;;
        esac
      fi ;;
  esac
  return 0
}

# wedge_record_required <evidence-dir> - the REQUIRED tier, every item obtainable with NO qrexec and
# NO prior arming. The kill gate reads exactly this. The BEST-EFFORT tier (the ELF core, and the
# module-base table for the wedging boot) is recorded as absent WITH ITS REASON and never blocks a
# kill: a guest whose FIRST boot wedges can never have an onstart task, and a kill refused forever
# leaves a wedged guest holding the rig.
# THE ANTECEDENT IS THE REQUIRED TIER NOW; the register state is best-effort. This is the owner's
# ordering of 2026-10-22, not a convenience: "stick may be more important than dump", because the
# open question is what the guest DID to the Xen API before it stopped - so that load can be
# reduced - and not where its instruction pointer ended up. Nine specimens' worth of register state
# is already recorded in findings/wedge.md; none of them answered the antecedent question.
#
# vmcs.txt and vcpu-samples.txt therefore MOVE OUT of the required tier. They are still collected,
# still in the record, and still label the shape - they just no longer hold a guest hostage.
WG_RECORD_REQUIRED="class.txt why.txt listing.txt screen.txt harness.txt"
WG_RECORD_BESTEFFORT="vmcs.txt vmcs-1.txt vmcs-2.txt vcpu-samples.txt vmcs-fields.txt forensics-1.tar forensics-2.tar"

# AND THE EVIDENCE THAT JUSTIFIES THE KILL ITSELF. QREXEC-DEAD-ALIVE is the only class that permits
# killing a LIVE guest, and the whole justification for killing it is that it HONOURED the ACPI
# request - the third conjunct failing is what makes it not a wedge. A kill on that class with no
# ACPI observation in the record would be killing a guest on the strength of a conclusion whose
# evidence was never written down, which is the same shape of mistake as the 600 s kill that
# captured nothing. So that class carries two extra required items.
WG_RECORD_REQUIRED_QREXEC_DEAD_ALIVE="acpi-result acpi-why acpi-rc"
wedge_record_complete(){
  local d="${1:?wedge_record_complete <dir>}" f missing="" req="$WG_RECORD_REQUIRED" class="${2:-}"
  [ -n "$class" ] || class=$(_wg_get "$d" class.txt)
  [ "$class" = QREXEC-DEAD-ALIVE ] && req="$req $WG_RECORD_REQUIRED_QREXEC_DEAD_ALIVE"
  for f in $req; do [ -s "$d/$f" ] || missing="$missing $f"; done
  printf '%s' "$missing"
  [ -z "$missing" ]
}

# wedge_may_kill <record-dir> [class] - ONE SHOT: the default is PRESERVE.
#
# Owner, 2026-10-22: "the wedge part - it should work at one shot, because if you destroy the
# specimen because of wrong branch, there would be none to retry."
#
# THE FLAW THIS REPLACES, and it was live in the first commit of this file. A kill gated only on
# record COMPLETENESS kills on a misparse: if the VMCS parse silently fails, the class becomes
# UNREADABLE-CPU, whose disposition is "fatal" and not "wedge", so it fell past the preserve branch;
# every required file still EXISTED (vmcs.txt is present - it is the PARSE of it that failed), so
# the record read complete and the guest was killed. Jev put that parse at 0.78 as the biggest
# implementation defect precisely because it has never been run against a real bundle.
#
# So the permission is now POSITIVE: a kill needs a class that is explicitly known safe to kill,
# AND a complete record. Everything else - every wedge, every candidate, every UNREADABLE, every
# unknown class, and a missing class - PRESERVES the guest. Blocking the rig is recoverable; a
# destroyed specimen is not, and there is no second one.
# THE KILL IS GATED ON THE ANTECEDENT, NOT ON THE CLASS. Rewritten 2026-10-22 after the owner
# reframed what a specimen is FOR - "we have enough register dumps... the question we need answer to
# is 'what did it do right before', because we need to reduce XEN API (vchan, grants, whatever) load
# further" and "that why stick may be more important than dump" - and after Jev weighed that against
# the counted evidence inventory: highest_value_next_instrument = antecedent_call_ledger 0.75
# (one_real_vmcs_decode 0.06, a_memory_core 0.03, more_rate_experiments 0.03);
# drop_preservation_as_default = kill_once_the_stick_is_in_hand 0.42 with
# hold_only_when_the_stick_is_unreadable 0.28, i.e. 0.70 combined for "kill, CONDITIONAL on holding
# the antecedent"; dump_is_still_primary 0.02.
#
# So the question a kill has to answer is no longer "is this class safe to destroy" but "do we
# already hold what we wanted from it". The stick reads on the HOST while the guest is still wedged,
# so in the normal case we do - and then the guest is expendable and must not block a serial rig.
# When the stick could NOT be read we hold, because that is the only case where the running guest is
# still the sole place the antecedent exists, in its own unflushed buffers.
#
# WHAT THE REVIEW ACTUALLY SAID, AFTER MY OWN COUNT WAS CORRECTED. The first pass scored
# enough_dumps_already 0.28 - "we have enough register dumps" unsupported - and I had handed it a
# line reading "guest cores on disk: 0" as though that measured whether cores had ever been
# obtained. IT MEASURED WHAT WAS ON DISK THAT DAY. Cores were captured and mined: #5's core gave
# "same mechanism 0.95", "the BLOCKED shape means something new 0.14" and "no new defect shown
# 0.96"; the mechanism class was identified down to pause_flags=4 (VPF_blocked_in_xen, the vCPU
# held until the stub-domain device model completes an I/O request, other vCPUs idle, ioreq channel
# not pending either side); six core-reading tools were built and used; and the originals were then
# dropped DELIBERATELY as spent - mgmt/harness/drop-core.sh exists for that disposal.
#
# Re-scored on the corrected inventory: enough_dumps_already 0.28 -> 0.53,
# post_mortem_axis_exhausted 0.65, and on whether the fault was the count or the investigation,
# inventory_was_misleading 0.70 against methodology_was_wrong 0.03. The open question was never a
# post-mortem one: the record puts the rate jump in our TEST CONDITIONS 0.62 (product code 0.24)
# with exposure at 1.00. Prioritisation re-scored antecedent-primary 0.78.
#
# The residual, which costs nothing: the bundle stays in the best-effort tier and is still
# collected, so the first real wedge gets decoded once now that decoding works at all.
#
# DOMAIN-GONE stays listed because there is nothing to collect from a domain that is not there.
WG_KILL_SAFE="DOMAIN-GONE"
wedge_may_kill(){
  local d="${1:?wedge_may_kill <record-dir> [class]}" class="${2:-}" missing c
  [ -n "$class" ] || class=$(tr -d '\r\n' < "$d/class.txt" 2>/dev/null)
  if [ -z "$class" ]; then
    _wg_say "REFUSING TO KILL: no class was recorded, so nothing is known about this guest."
    _wg_say "  One shot: an unclassified guest is a possible specimen and there is no retry."
    return 1
  fi
  # THE ANTECEDENT TEST. A pulled stick with a pull receipt is the thing we came for; "declared-none"
  # is a caller stating this cell ran without a stick at all, which is a declaration and not a gap.
  local lvs; lvs=$(_wg_get "$d" logvol-status)
  local have=0
  case "$lvs" in
    pulled)        [ -s "$d/logvol/pull.txt" ] && have=1 ;;
    declared-none) have=1 ;;            # the caller states this cell ran without one
    no-stick)
      # Killable only once the record says WHERE the antecedent is. "no stick" used to be treated as
      # "nothing to collect", which is false for an AppVM cell: its logs are on the private volume.
      # A kill does not destroy that volume, so the kill may proceed - but it may not proceed with
      # nothing written down about where the only copy lives, because the step after this one
      # re-creates the AppVM over it.
      if [ -s "$d/antecedent-location" ]; then
        case "$(_wg_get "$d" antecedent-reachable)" in
          qrexec)      have=1 ;;                               # the collector can read it
          volume-only) [ -s "$d/volume-hold" ] && have=1 ;;    # recorded: that volume must survive
        esac
      fi ;;
  esac
  local safe=0
  for c in $WG_KILL_SAFE; do [ "$class" = "$c" ] && safe=1; done
  if [ "$safe" != 1 ] && [ "$have" != 1 ]; then
    _wg_say "REFUSING TO KILL: the ANTECEDENT was not captured (logvol-status='${lvs:-absent}'), class=$class."
    _wg_say "  The stick is what answers 'what did it do right before', and it reads on the host while"
    _wg_say "  the guest is still wedged - so failing to get it means the only remaining copy is in"
    _wg_say "  this guest's own unflushed buffers. It stays up until the stick is read."
    return 1
  fi
  missing=$(wedge_record_complete "$d" "$class") || {
    _wg_say "REFUSING TO KILL: the record is incomplete, missing:$missing (class=$class)"
    return 1
  }
  if [ "$safe" = 1 ]; then
    _wg_say "kill permitted: class=$class has nothing to collect, and the required record is complete in $d"
  else
    _wg_say "kill permitted: the antecedent is in hand (logvol-status=$lvs) and the required record is complete in $d - class=$class"
    _wg_say "  The guest is expendable BECAUSE the stick was read, not because the class looked harmless."
  fi
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

  # THE STICK COMES FIRST, BEFORE ANY FORENSICS. Owner, 2026-10-22: "we have enough register dumps
  # so i do not think we are interested in 'where it stuck' anymore. the question we need answer to
  # is 'what did it do right before', because we need to reduce XEN API (vchan, grants, whatever)
  # load further, not to chase how exactly xen damages it on wedge" - and "that why stick may be
  # more important than dump".
  #
  # The stick answers that question and needs nothing from the guest. logvol-lib.sh's volume is a
  # plain image file on a loop device in THIS qube, write-through at all three layers
  # (LogSafeFlush=1 -> qemu block layer -> this qube's page cache), so mtools reads it on the host
  # "while the guest runs, wedges or sits Halted - no detach, no unmount, no guest", and its own
  # acceptance is that a line written ONE SECOND before a qvm-kill is present. logvol_salvage then
  # recovers the tail whose bytes are in the image while the directory entry still predates them -
  # which is precisely the last thing the guest did before it stopped.
  #
  # LOGVOL_IMG is the SAME variable collect-failure.sh reads; this does not invent a second name.
  # "none" is a caller DECLARING the cell ran without a stick, which is different from not knowing.
  # FOUR OUTCOMES, and the difference between the last two is the whole point of holding a guest:
  #   pulled        the antecedent is in hand
  #   unreadable    a stick EXISTS for this guest and could not be read -> holding buys a retry
  #   no-stick      no image exists for this guest at all -> holding buys NOTHING, because there is
  #                 no stick to read later either. Recorded distinctly so the record never says
  #                 "declared" about something that was merely absent.
  #   declared-none the caller states this cell ran without one
  declare -F logvol_pull >/dev/null 2>&1 || . mgmt/harness/logvol-lib.sh 2>/dev/null
  local _img="${LOGVOL_IMG:-}"
  # NOT SET BY EVERY CALLER. matrix.sh and quick-upgrade.sh set LOGVOL_IMG per guest;
  # tools/release-acceptance.sh's settle path does not, and on 2026-10-22 that would have left every
  # non-halting guest "not-declared" and therefore HELD, stopping the campaign on the first one
  # (Jev named runner_wiring as the regression risk at 0.50). So derive it the same way they do,
  # from the guest's own id, rather than depending on the caller to have exported it.
  if [ -z "$_img" ] && declare -F logvol_image >/dev/null 2>&1; then
    _img=$(logvol_image "$vm" 2>/dev/null) || _img=""
  fi
  if [ "${LOGVOL_IMG:-}" = none ]; then
    printf 'declared-none\n' > "$d/logvol-status"
  elif [ -n "$_img" ] && [ -s "$_img" ]; then
    printf '%s\n' "$_img" > "$d/logvol-image"
    if declare -F logvol_pull >/dev/null 2>&1 && logvol_pull "$_img" "$d/logvol" >>"$d/logvol.log" 2>&1; then
      printf 'pulled\n' > "$d/logvol-status"
      # The tail mcopy cannot see: bytes in allocated clusters whose directory entry predates them.
      # That tail IS the last thing the guest did, so it is the part worth most here.
      logvol_salvage "$_img" "$d/logvol" >>"$d/logvol.log" 2>&1 || :
    else
      printf 'unreadable\n' > "$d/logvol-status"
    fi
  else
    # NO STICK IS NOT "NOTHING TO COLLECT", and treating it as such was a defect in the first version
    # of this gate. An AppVM cell has no evidence stick BY RULING, not by failure: matrix.sh's
    # logvol_stick_scope returns 1 for the appvm class because "THE EVIDENCE STICK IS AN
    # INSTALL-TESTING INSTRUMENT, and this cell installs nothing". Its logs come from the collector
    # at the LogDir the guest resolves - normally Q:\Qubes Logs, which lives on the guest's PRIVATE
    # volume (.claude/skills/rig-logging-sweep/SKILL.md).
    #
    # SO THE ANTECEDENT EXISTS; WHAT CHANGES IS HOW IT IS REACHED, and on a wedge that matters more
    # than anywhere else. The collector reads that LogDir over QREXEC, and a wedged guest has no
    # qrexec - which is the exact hole the stick exists to close ("the log volume is the ONLY
    # instrument that survives a wedge - a guest that will not halt cannot be asked for its logs, and
    # mtools reads the image with no guest at all", matrix.sh). For a no-stick guest the only
    # surviving copy is on the private volume, which OUTLIVES a qvm-kill and does NOT outlive a
    # qvm-remove or a re-create - and matrix.sh's appvm cell re-creates the AppVM FRESH from the
    # template, "private auto-seeded from the template's private at creation", in the same function.
    # So the kill is not the hazard here; the recreate is, and nothing recorded it.
    printf 'no-stick\n' > "$d/logvol-status"
    printf '%s\n' "${_img:-<no image path could be derived>}" > "$d/logvol-image"
    printf 'private-volume:%s:%s\n' "$vm" 'Q:\Qubes Logs (the LogDir the guest resolves)' > "$d/antecedent-location"
    if [ "$(_wg_get "$d" qrexec)" = ANSWERED ]; then
      # The collector can still read it, so this guest is no different from any other.
      printf 'qrexec\n' > "$d/antecedent-reachable"
    else
      # It cannot be read without the guest. Name the volume that must survive, so the next step is
      # a decision someone took rather than a cell quietly recreating over the only evidence.
      printf 'volume-only\n' > "$d/antecedent-reachable"
      printf '%s\n' "$vm" > "$d/volume-hold"
      _wg_say "ANTECEDENT IS ON ${vm}'s PRIVATE VOLUME ONLY: no stick for this cell class and qrexec is"
      _wg_say "  silent, so the collector cannot read the LogDir. The volume survives a kill; it does"
      _wg_say "  NOT survive a remove or a re-create from the template. Read it (clone the private"
      _wg_say "  volume into a reader and mount it) BEFORE this guest is recreated."
    fi
  fi

  # O1 the FULL listing: an empty one is an instrument failure, never "the vm is absent"
  qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | tr '|' ' ' > "$d/listing.txt"
  # DOM0 REACHABILITY IS NOT PROBED SEPARATELY. It used to be, with `timeout 25` on
  # local.WinWedgeForensics - a service whose own script takes two vcpu-list samples 10 s apart
  # plus several debug-keys dumps with sleeps between them, so it CANNOT return inside 25 s. The
  # probe therefore failed always, and on 2026-10-22 it reported dom0-ok=0 for a guest whose
  # forensics capture then succeeded in the same run. A bound shorter than the service is a
  # measurement of the bound. The real capture below answers the same question with evidence, and
  # dropping the probe removes one heavy dom0 call from every classification.

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
    # TWO ARGUMENTS: wedge_classify <vm> <outdir>, and it writes artefacts into the outdir. Called
    # with one, it died under `set -u` on its own "$2" and every run recorded fraction=UNREADABLE.
    # Offline fixtures cannot catch that - they write `fraction` directly - so it took a live run.
    wedge_classify "$vm" "$d/classify" > "$d/vcpu-samples.txt" 2>&1 || :
    case "$(head -1 "$d/vcpu-samples.txt" 2>/dev/null)" in
      SPIN*)    printf 'SPIN\n'    > "$d/fraction" ;;
      BLOCKED*) printf 'BLOCKED\n' > "$d/fraction" ;;
      *)        printf 'UNREADABLE\n' > "$d/fraction" ;;
    esac
  else : > "$d/vcpu-samples.txt"; printf 'UNREADABLE\n' > "$d/fraction"; fi

  # O9 proper: two VMCS samples, ActivityState + RIP per vCPU, decoded by tools/wedge-vmcs.py.
  # ActivityState is the VMCS enum, so this is structural and not a threshold over overlapping bands.
  # THE EXPENSIVE HALF IS NOT TAKEN HERE. wedge_collect is called in a loop over every guest that
  # did not halt, and the two forensics captures below are bounded at 300 s EACH (a real one takes
  # ~90 s) - so taking them unconditionally adds minutes per guest to a settle loop, for data that
  # is now BEST-EFFORT: it labels the wedge shape and no longer gates anything. Jev named exactly
  # this as the one thing to fix before landing (collect_is_slow_in_the_settle_loop 0.47,
  # fix-before-landing 0.61). So the caller takes the dump only once a class says it would mean
  # something - see wedge_collect_dump.
  # the harness's own account, so a reader knows what was running when this was taken
  { printf 'harness-pid=%s\n' "$$"
    printf 'harness-cmd=%s\n' "$(tr '\0' ' ' < "/proc/$$/cmdline" 2>/dev/null)"
    printf 'taken-utc=%s\n' "$(date -u +%FT%TZ)"
    printf 'vm=%s\n' "$vm"
  } > "$d/harness.txt"
  return 0
}

# wedge_release <vm> <record-dir> <reason> - the ONE way a held specimen is released.
#
# Jev, 2026-10-22: preserve_and_analyze 0.55, and preserve_but_bound_it 0.44 - preserving is right,
# but a hold with no named end leaves the rig blocked and nothing saying how that is meant to
# finish. So the release is a step with a name, a required reason, and the same record gate as any
# other kill: the point was never that the guest is immortal, it is that nothing destroys it by
# accident or by falling through a branch. A deliberate release with a written reason is the
# opposite of that, and it is recorded next to the evidence it ends.
wedge_release(){
  local vm="${1:?wedge_release <vm> <record-dir> <reason>}" d="${2:?}" reason="${3:?wedge_release needs a REASON - a release with no reason recorded is the accident this gate exists to stop}"
  local class; class=$(_wg_get "$d" class.txt)
  local missing; missing=$(wedge_record_complete "$d" "$class") || {
    _wg_say "REFUSING TO RELEASE $vm: the record is incomplete, missing:$missing"
    _wg_say "  Releasing now would destroy state that was never written down. Complete the record first."
    return 1
  }
  printf '%s\n' "$reason" > "$d/released-reason.txt"
  date -u +%FT%TZ > "$d/released-utc"
  _wg_say "RELEASING $vm (class=${class:-unclassified}): $reason"
  _wg_say "  the record is complete at $d and stays there; the guest does not."
  timeout 60 qvm-kill "$vm" >/dev/null 2>&1
  return 0
}

# wedge_collect_dump <vm> <outdir> - the EXPENSIVE half: two hypervisor captures and their parse.
#
# Split out of wedge_collect on 2026-10-22. It is bounded at 300 s per capture and a real one takes
# ~90 s, so it is paid ONLY when the cheap half has produced a class whose SHAPE is worth labelling -
# i.e. a wedge candidate. Everything it produces is in the BEST-EFFORT tier: it names which wedge,
# it never decides whether there is one, and it holds no guest. Owner, 2026-10-22: "we have enough
# register dumps... that why stick may be more important than dump."
#
# Re-run wedge_stage1 after this to pick the shape up; stage 1 is pure, so running it twice over a
# richer record is exactly what it is for.
wedge_collect_dump(){
  local vm="${1:?wedge_collect_dump <vm> <outdir>}" d="${2:?wedge_collect_dump <vm> <outdir>}" i
  mkdir -p "$d" || return 2
  # TWO SAMPLES, KEPT APART. A spin is the SAME vCPU on the SAME address twice, so the samples
  # cannot be concatenated before they are compared - the first version of this appended both to
  # one file and then compared the first hex token in it against the last, which on a 4-vCPU guest
  # compares vcpu0 in sample 1 with vcpu3 in sample 2. The field extraction lives in
  # tools/wedge-vmcs-fields.py with a fixture of the real table, because it also read activity from
  # the exit-reason column; neither defect was reachable offline while the parse was inline here.
  : > "$d/vmcs.txt"
  for i in 1 2; do
    if timeout 300 qrexec-client-vm dom0 "local.WinWedgeForensics+$vm" </dev/null > "$d/forensics-$i.tar" 2>/dev/null \
       && [ -s "$d/forensics-$i.tar" ]; then
      python3 tools/wedge-vmcs.py "$d/forensics-$i.tar" > "$d/vmcs-$i.txt" 2>/dev/null || :
      cat "$d/vmcs-$i.txt" >> "$d/vmcs.txt" 2>/dev/null || :
    else
      : > "$d/vmcs-$i.txt"
    fi
    [ "$i" = 1 ] && sleep "$WEDGE_SAMPLE_SECS"
  done
  # DOM0 HEALTH FROM THE CAPTURE ITSELF. Not a separate probe with its own bound - whether the
  # forensics service answered with a bundle IS the answer, and it is evidence rather than a ping.
  if [ -s "$d/forensics-1.tar" ] || [ -s "$d/forensics-2.tar" ]; then
    printf '1\n' > "$d/dom0-ok"
  else
    printf '0\n' > "$d/dom0-ok"
  fi
  printf '%s\n' "" > "$d/vmcs-activity"; printf '0\n' > "$d/vmcs-rip-static"
  if [ -s "$d/vmcs-1.txt" ]; then
    python3 tools/wedge-vmcs-fields.py "$d/vmcs-1.txt" "$d/vmcs-2.txt" > "$d/vmcs-fields.txt" 2>/dev/null || :
    while IFS='=' read -r k v; do
      case "$k" in
        activity)    printf '%s\n' "$v" > "$d/vmcs-activity" ;;
        rip-static)  printf '%s\n' "${v:-0}" > "$d/vmcs-rip-static" ;;
        rvi-pending) [ -n "$v" ] && printf '%s\n' "$v" > "$d/vmcs-rvi" ;;
        rvi-stuck)   [ -n "$v" ] && printf '%s\n' "$v" > "$d/vmcs-rvi-stuck" ;;
        exit-all-hlt)         printf '%s\n' "${v:-0}" > "$d/vmcs-exit-all-hlt" ;;
        runstate-all-blocked) printf '%s\n' "${v:-0}" > "$d/vmcs-runstate-all-blocked" ;;
        exit-pause-loop-vcpu) [ -n "$v" ] && printf '%s\n' "$v" > "$d/vmcs-pause-loop-vcpu" ;;
      esac
    done < "$d/vmcs-fields.txt"
  fi

  return 0
}

# wedge_volume_hold <record-dir> - prints the guest whose PRIVATE VOLUME holds the only copy of the
# antecedent, or nothing. A cell that re-creates an AppVM from its template destroys that volume
# ("private auto-seeded from the template's private at creation"), so the recreate path asks this
# first. Empty output means nothing is held and the recreate is free.
wedge_volume_hold(){
  local d="${1:?wedge_volume_hold <record-dir>}"
  [ -s "$d/volume-hold" ] || return 1
  _wg_get "$d" volume-hold
}

# wedge_volume_held_for <vm> <records-root> - is THIS guest's private volume held as the only copy
# of an antecedent? Prints the record dir(s) that hold it; rc 0 when held, 1 when free.
#
# THE READER AND THE WRITER IN ONE FILE, deliberately. wedge_collect writes volume-hold; this is how
# a caller about to DESTROY that volume finds out. Jev reviewed the first version of the no-stick
# work as "right but unenforced" (0.76) for exactly the missing half: recording a hold changes
# nothing until the path that recreates the guest consults it. The consumer is matrix.sh's appvm
# cell, which removes the AppVM and re-creates it FRESH from its template - "private auto-seeded
# from the template's private at creation" - which is the step that destroys the volume. A kill does
# not; this does.
wedge_volume_held_for(){
  local vm="${1:?wedge_volume_held_for <vm> <records-root>}" root="${2:?}" f held=""
  [ -d "$root" ] || return 1
  # Any wedge record under this campaign naming this guest. find, not a glob: the records are
  # wedge-<vm>-<HHMMSS> directories created per classification and there may be several.
  for f in $(find "$root" -maxdepth 3 -name volume-hold -type f 2>/dev/null); do
    [ "$(tr -d '\r\n' < "$f" 2>/dev/null)" = "$vm" ] || continue
    held="$held $(dirname "$f")"
  done
  [ -n "$held" ] || return 1
  printf '%s\n' "${held# }"
}

# =============================================================================================
# JEV AS SECONDARY EVALUATOR - REFERENCE ONLY (owner, 2026-10-22: "add builtin jev gate to judge
# common failure modes (reference only)"; and earlier, "we MAY have jev as secondary evaluator in
# any script... the main flow should stay determenistic and self contained, but we SHOULD ask jev
# for supplementary data").
#
# THE DIVISION OF LABOUR IS THE SAME AS THE UPDATER GATE'S (updater_gates_jev), deliberately:
# the CLASS is decided by the deterministic tree above - three conjuncts, host-side, no network -
# and Jev is asked one further question the tree does not answer and must not guess at: given this
# class, WHICH KNOWN MECHANISM does the evidence most support? A mechanism attribution is a
# classification, and "if it assigns a case to a class, it is Jev's, not a hand call" (owner,
# 2026-09-21). But a gate verdict may never depend on a network call, so nothing here can change
# WG_CLASS, and a missing jev-artifact.sh, a missing network or an empty answer all leave the
# deterministic verdict exactly as it stands. wedge_gates_jev writes WG_JEV and NOTHING else.
#
# THE CANDIDATE SETS ARE NOT INVENTED PER RUN. Each one is the recorded set of mechanisms this
# project has actually measured for that class, so Jev chooses among real alternatives:
#   SPIN     - findings/wedge.md: "THE STALL'S MECHANISM CLASS IS IDENTIFIED: THE STUCK vCPU WAITS
#              FOR QEMU IN THE STUB DOMAIN" (2026-10-04), the qrexec-wrapper pinned on a CPU that
#              never acknowledges (2026-09-30, 2026-10-02, 2026-10-04), and the IPI shape - RVI=0xE1
#              latched in the VMCS on a vCPU that never took it while others spun in
#              nt!KiIpiSendRequestEx (dom0/11-wedge-forensics.sh step 3b).
#   BLOCKED  - the same file: a vCPU HELD IN XEN right after a grant/memory hypercall
#              (GNTTABOP_unmap_grant_ref) with pause_flags=4 = VPF_blocked_in_xen, and NO second
#              CPU spinning on it. Jev then: same mechanism 0.95, "the BLOCKED shape means something
#              new" 0.14, "a new 4.3.34 defect behind them: no new defect shown" 0.96.
#   look-alikes - findings/install.md: "QREXEC CAN GO MISSING FOR GOOD AFTER A CLEAN INSTALL, and
#              the permanence is a service-configuration defect of ours"; findings/network.md: the
#              xenvif DISPATCH-level busy-wait under Frontend->Lock against an unpatched mirage
#              firewall (~2 cores, no qrexec, ACPI ignored) - FIXED, and listed so Jev can rule it
#              back in if a netvm is attached.
# Exposure, not code, is the standing prior: Jev put the rate jump in our TEST CONDITIONS 0.62
# against product code 0.24, so "our quality changes synchronize the guest's demands on the device
# model at its most fragile moment" is a candidate on its own and not a rhetorical aside.
WG_JEV=""

# wedge_gates_jev <evidence-dir> [class] - fills $WG_JEV. Needs network; NEVER affects the class.
wedge_gates_jev(){
  local d="${1:?wedge_gates_jev <evidence-dir> [class]}" class="${2:-}" crit="" ctx=""
  WG_JEV=""
  [ -n "$class" ] || class=$(_wg_get "$d" class.txt)
  [ -n "$class" ] || { WG_JEV="(no class recorded - Jev not asked)"; return 0; }
  if ! wedge_is_fatal "$class"; then WG_JEV="(class $class is not a failure - Jev not asked)"; return 0; fi
  case "$class" in
    WEDGE-SPIN|WEDGE-SPIN-CANDIDATE)
      ctx="A guest classified $class: present, drawing no pixels, ignoring a re-asked ACPI request, with a vCPU Active across both VMCS samples on an unchanged RIP."
      crit='"qemu_stubdom_wait":"the stuck vCPU is waiting on QEMU in the stub domain - the mechanism class identified 2026-10-04, the stuck side being a qrexec-wrapper just after a grant or memory hypercall",
         "ipi_never_acknowledged":"an IPI was latched and never taken: a vector pending in the VMCS InterruptStatus (RVI) on a vCPU that never takes it, while other vCPUs spin waiting for that acknowledgement",
         "grant_path":"the spin sits on the grant/map path - the staging grant or an unmap that never completes",
         "xenvif_dispatch":"xenvif busy-waiting at DISPATCH_LEVEL under Frontend->Lock against an unpatched network backend - needs a netvm to be attached at all",
         "our_driver":"our own driver or agent code is the spinning site",
         "test_conditions":"no new product defect: our test conditions concentrate the guest demands on the device model during a fresh domain first minutes, which is where the rate lives (exposure 0.62 vs product code 0.24)"' ;;
    WEDGE-BLOCKED|WEDGE-BLOCKED-CANDIDATE)
      ctx="A guest classified $class: present, drawing no pixels, ignoring a re-asked ACPI request, with EVERY vCPU HLT across both VMCS samples - nothing is burning CPU."
      crit='"held_in_xen":"a vCPU held in Xen right after a grant or memory hypercall (pause_flags=4, VPF_blocked_in_xen) with no second CPU spinning on it - the recorded BLOCKED shape",
         "evtchn_never_delivered":"every vCPU idled waiting for an event channel notification that was never delivered",
         "qemu_gone":"the device model in the stub domain stopped serving, so the guest waits forever on an emulated access",
         "guest_halted_itself":"the guest reached a state where it halted every processor on purpose - a bugcheck that never got to draw, or a firmware stop",
         "something_new":"the BLOCKED shape is a DIFFERENT defect from the spin shape rather than the same mechanism (Jev previously put this at 0.14)"' ;;
    WEDGE-UNKNOWN-SHAPE|WEDGE-CANDIDATE)
      ctx="A guest whose three wedge conjuncts all hold - present, no pixels, ACPI re-asked and ignored - but whose vCPU shape could not be read, so SPIN vs BLOCKED is unknown."
      crit='"capture_gap":"the shape is unknown only because the VMCS dump was not captured or the hypervisor ring wrapped before it was read - an instrument gap, not a guest state",
         "likely_spin":"the surrounding evidence still favours the spin shape",
         "likely_blocked":"the surrounding evidence still favours the blocked shape",
         "undeterminable":"this evidence cannot favour either shape and only a fresh capture from a live specimen can"' ;;
    QREXEC-DEAD-ALIVE)
      ctx="A guest that drew no pixels and never answered qrexec, but HONOURED the ACPI request and halted - so it was never wedged."
      crit='"qrexec_service_config":"the permanent qrexec loss after a clean install - a service-configuration defect of ours, measured twice",
         "agent_not_running":"the gui/qrexec agent was not running or had exited on that boot",
         "vchan_only":"the guest was alive but no transport came up - a vchan or daemon-side fault rather than a guest fault",
         "no_session":"there was no logged-on session for the service to run in, so calls could not be served",
         "install_left_it_broken":"the install or upgrade on this boot left the service set up such that it could never serve"' ;;
    RESTART-UNEXPLAINED)
      ctx="A domain that left and re-entered Running, or rebooted across the ACPI ask, with no queued qrexec call on this qube to explain it."
      crit='"guest_bugcheck_reboot":"the guest bugchecked and rebooted on its own",
         "install_reboot":"an install or update stage rebooted it legitimately and the harness did not expect that boot",
         "queue_missed":"a queued call DID drive the restart but was not visible in this qube process table when sampled",
         "toolstack_restart":"something in the toolstack or another harness started it"' ;;
    UNRESPONSIVE-WITH-PIXELS)
      ctx="A guest still DRAWING - so not wedged by definition - that nonetheless answers no qrexec call."
      crit='"session_wedged":"the session or shell is stuck while the kernel runs fine - the screen is live but nothing services calls",
         "agent_dead":"the agent or its service died while the guest kept rendering",
         "modal_blocker":"a dialog, logon surface or installer window is holding the session",
         "transport_only":"the guest is healthy and only the transport is down"' ;;
    UNREADABLE-ACPI|UNREADABLE-CPU|UNREADABLE-SCREEN|INSTRUMENT-FAILURE)
      ctx="A run where the DECIDING observation could not be made at all, so no guest state is asserted."
      crit='"instrument_down":"the instrument itself failed - the dom0 service, the screenshot path or the listing - and the guest may be perfectly healthy",
         "guest_too_broken_to_measure":"the guest is in a state where the instrument cannot complete, which is itself a symptom",
         "harness_race":"the measurement was taken at a moment the harness had the guest in transition",
         "evidence_incomplete":"the evidence was collected but the parse or extraction of it failed"' ;;
    RECOVERY)
      ctx="A guest showing a recovery or repair surface - terminal for the run whatever the CPU says."
      crit='"boot_damage":"the boot configuration or system volume was damaged by the install or by a kill",
         "killed_mid_write":"a previous kill interrupted a write and the next boot could not complete",
         "update_rollback":"an update failed and the guest fell into its own repair path",
         "volume_state":"the volume the guest booted from was not the state the harness believed it was"' ;;
    *) WG_JEV="(no candidate set for $class)"; return 0 ;;
  esac
  local rub="$d/jev-mechanism-rubric.json"
  cat > "$rub" <<JEOF
{"questions":{
 "mechanism":{"type":"choice","instructions":{"judge":"$ctx The artifact is the evidence record taken BEFORE anything killed the subject: the classifier's own reason, the domain listing, two vCPU samples, the decoded VMCS, the screen verdict and the ACPI observation with its return code. Judge ONLY from what is present. A mechanism that would have left a line leaves one, so the ABSENCE of a line is itself evidence. The CLASS is already decided deterministically and is not in question - only the mechanism behind it is."},"criteria":{$crit}},
 "evidence_is_sufficient":{"type":"noul","instructions":{"judge":"Does this record actually separate those mechanisms, or would several explain it equally well? Answer true only if what is present picks out one."},"criteria":{"true":"the record picks out one mechanism","false":"several fit equally well"}},
 "next_capture":{"type":"choice","instructions":{"judge":"Which ONE capture would most separate the remaining candidates? The subject is PRESERVED and still running, so each of these is still obtainable from it - choose by what the record above is missing, not by what is generally interesting."},"criteria":{
   "memory_image":"an ELF core: only a core can name the module and frames the stuck vCPU is in, by walking its stack",
   "fresh_vmcs":"another VMCS dump: the interrupt status and activity fields, if this record lacks them or they wrapped",
   "module_bases":"the per-boot module base table, without which a RIP cannot be resolved to driver+offset",
   "guest_event_logs":"the guest's own event logs off the private volume",
   "device_model_log":"the stub domain device-model log from dom0",
   "nothing_more_needed":"the record already picks out one mechanism"}}}}
JEOF
  if [ ! -x tools/jev-artifact.sh ]; then
    WG_JEV="(tools/jev-artifact.sh not available - the deterministic class stands on its own)"; return 0
  fi
  WG_JEV=$(JEV_ARTIFACT_OUT="$d/jev-mechanism.json" tools/jev-artifact.sh "$rub" \
             "$d/why.txt" -- "cat $d/listing.txt" "cat $d/vcpu-samples.txt" "cat $d/vmcs.txt" \
             "cat $d/screen.txt" "cat $d/acpi-why" "cat $d/harness.txt" 2>&1 | tail -5)
  [ -n "$WG_JEV" ] || WG_JEV="(Jev produced no answer - the deterministic class above is the verdict)"
  return 0
}
