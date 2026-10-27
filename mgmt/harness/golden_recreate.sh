#!/bin/bash
# golden_recreate.sh - THE ONLY path that reseals a golden from a pristine base. Parameterised by
# NAME, so it does not carry the win10/win11 pair that seal-qwt-golden.sh hardcodes and that the
# retail rename (win11r-*) already moved past.
#
#   mgmt/harness/golden_recreate.sh --golden <name> --base <pristine-base> [options]
#     --golden <name>     the golden to produce/reseal (e.g. win11r-qwt, or a base to reseal)
#     --base <name>       the PRISTINE base it is built from (must be present and Halted)
#     --setup <dir>       an N-1 RELEASE setup tree (install.cmd + MANIFEST.json at root). With it,
#                         the QWT golden is built by seal-qwt-golden.sh; without it, this reseals
#                         <base> itself and <golden> must equal <base>.
#     --note "<text>"     the seal note (default says recreated and when)
#     --out <dir>         where this run's artefacts land (default scratchpad/golden-recreate)
#
# WHY A SCRIPT, NOT PROSE. docs/PROCEDURE-recreate-goldens.md is the committed sequence and stays
# the authority for WHY; this is that sequence with its preconditions and evidence rules made
# non-optional. A prose procedure cannot refuse to run.
#
# WHAT IT REFUSES, AND WHY EACH ONE IS HERE:
#   * no Jev receipt carrying recreate_goldens - this is the heavy path, and the gate exception in
#     CLAUDE.md is a RECEIPT, not an intention (tools/hooks/committed-procedure-gate.sh);
#   * the base is not present+Halted - a running base is not pristine;
#   * the golden already verifies against its seal - then nothing needs recreating, and rebuilding
#     one on a whim is how an intact pool gets destroyed;
#   * a reseal that would abandon revisions already gone, unless GOLDEN_RESEAL_REASON records the
#     decision (mgmt/golden.sh enforces this; revisions_to_keep is 2, so the window is TWO
#     shutdowns wide - that is how win10-base was lost on 2026-10-11).
#
# IT NEVER STARTS THE GOLDEN. A golden is CLONED. The build runs on a fresh clone, by the committed
# harness, and tools/hooks/golden-boot-gate.sh refuses a start regardless of what this script wants.
#
# Exit: 0 the golden is sealed and VERIFIED (or already was); 1 a precondition refused;
#       2 usage; 3 the build or the verify failed - the output says which.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$HERE" || exit 2
# shellcheck source=/dev/null
. "$HERE/mgmt/harness/primitives.sh"

GOLDEN="" BASE="" SETUP="" NOTE="" OUT="scratchpad/golden-recreate"
while [ $# -gt 0 ]; do
  case "$1" in
    --golden) GOLDEN="${2:?}"; shift 2 ;;
    --base)   BASE="${2:?}";   shift 2 ;;
    --setup)  SETUP="${2:?}";  shift 2 ;;
    --note)   NOTE="${2:?}";   shift 2 ;;
    --out)    OUT="${2:?}";    shift 2 ;;
    *) echo "usage: $0 --golden <name> --base <pristine-base> [--setup <dir>] [--note <text>] [--out <dir>]"; exit 2 ;;
  esac
done
[ -n "$GOLDEN" ] && [ -n "$BASE" ] || { echo "usage: $0 --golden <name> --base <pristine-base> [--setup <dir>]"; exit 2; }
[ -n "$SETUP" ] || [ "$GOLDEN" = "$BASE" ] \
  || { echo "REFUSE: --golden $GOLDEN != --base $BASE and no --setup tree was given, so there is nothing to install between them"; exit 2; }

RUN="$OUT/$(attempt_id)"
attempt_dir "$RUN" || exit 1
LOG="$RUN/recreate.log"; attempt_open "$LOG"
say(){ printf '[%s] golden_recreate: %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$LOG"; }
die(){ say "REFUSE: $*"; exit "${2:-1}"; }

if complete_once "$RUN"; then say "already complete for attempt $(attempt_id)"; exit 0; fi

# --- the gate exception is a RECEIPT ------------------------------------------------------------
RCPT="${GOLDEN_RECREATE_RECEIPT:-}"
[ -n "$RCPT" ] || die "no GOLDEN_RECREATE_RECEIPT. This is the heavy path; CLAUDE.md's exception is a Jev call whose state contains recreate_goldens and quotes docs/PROCEDURE-recreate-goldens.md"
[ -s "$RCPT" ] || die "GOLDEN_RECREATE_RECEIPT=$RCPT is missing or empty"
grep -q 'recreate_goldens' "$RCPT" || die "$RCPT does not contain the marker recreate_goldens, so it is not a receipt for THIS procedure"
say "receipt: $RCPT ($(wc -c < "$RCPT") bytes, marker present)"

# --- preconditions ------------------------------------------------------------------------------
# Single-VM queries only: a bare qvm-ls fires denied admin calls into the owner's dom0 journal, and
# TAGS is never requested from here.
vstate(){ qvm-ls --raw-data --fields NAME,STATE "$1" 2>/dev/null | awk -F'|' -v v="$1" '$1==v{print $2}'; }

bstate="$(vstate "$BASE")"
[ -n "$bstate" ] || die "base $BASE does not exist - there is no pristine source to build from"
[ "$bstate" = Halted ] || die "base $BASE is $bstate, not Halted - a running base is not pristine"
say "base $BASE is present and Halted"

gstate="$(vstate "$GOLDEN")"
if [ -n "$gstate" ] && [ "$gstate" != Halted ]; then
  die "golden $GOLDEN is $gstate - nothing is recreated under a running guest"
fi

# Already intact? Then recreating it is the damage, not the fix.
if vout=$(mgmt/golden.sh verify "$GOLDEN" 2>&1); then
  say "$GOLDEN already VERIFIES against its seal - nothing to recreate:"
  printf '%s\n' "$vout" | tee -a "$LOG"
  complete_mark "$RUN"
  exit 0
fi
say "$GOLDEN does not verify (that is why we are here):"
printf '%s\n' "$vout" | sed 's/^/    /' | tee -a "$LOG"

# --- serialise, AFTER the verify gate --------------------------------------------------------
# Rebuilding a golden is the heaviest VM-mutating job on this rig and CLAUDE.md makes such jobs
# serial. The lock is taken HERE and not at entry on purpose: above this line the script only reads
# (receipt, base state, golden verify) and exits 0 when the golden is already good, and holding the
# rig's lock through a no-op would block a real job for nothing.
# shellcheck source=/dev/null
. mgmt/harness/vmlock.sh
vm_lock "$GOLDEN" || die "vmlock busy for $GOLDEN - another VM-mutating job holds the rig"

# --- screenshot cadence: the procedure requires one at least every 15 min on a long run ---------
SHOTS="$RUN/shots"; mkdir -p "$SHOTS"
shot_ticker(){
  local vm="$1" i=0
  while :; do
    sleep 600
    i=$((i+1))
    QTEST_VM="$vm" ./tools/qtest shot "$SHOTS/$vm-$i.tar" >/dev/null 2>&1 \
      && say "shot $i: $SHOTS/$vm-$i.tar" || say "shot $i: no capture (guest may have no session yet)"
  done
}
TICKER=""
start_ticker(){ shot_ticker "$1" & TICKER=$!; say "shot ticker pid=$TICKER every 10 min -> $SHOTS"; }
# The pid is RECORDED and killed by that pid. Never a pattern scan into kill.
stop_ticker(){ [ -n "$TICKER" ] && kill "$TICKER" 2>/dev/null; TICKER=""; }
trap stop_ticker EXIT

# --- build ---------------------------------------------------------------------------------------
: "${NOTE:=recreated $(date -u +%F) by golden_recreate.sh from $BASE}"

if [ -n "$SETUP" ]; then
  [ -f "$SETUP/install.cmd" ] || die "$SETUP has no install.cmd - that is not a release setup tree" 2
  [ -f "$SETUP/MANIFEST.json" ] || die "$SETUP has no MANIFEST.json - that is not a release setup tree" 2
  # seal-qwt-golden.sh takes an OS token and derives <os>-base/<os>-qwt itself. Only drive it when
  # the names it derives are the names asked for; otherwise say so rather than build the wrong pair.
  os="${GOLDEN%-qwt}"
  if [ "$GOLDEN" = "$os-qwt" ] && [ "$BASE" = "$os-base" ]; then
    say "building $GOLDEN from $BASE via seal-qwt-golden.sh $os $SETUP"
    start_ticker "$GOLDEN"
    if ! mgmt/harness/seal-qwt-golden.sh "$os" "$SETUP" 2>&1 | tee -a "$LOG"; then
      stop_ticker; die "seal-qwt-golden.sh failed - see $LOG" 3
    fi
    stop_ticker
  else
    die "seal-qwt-golden.sh derives <os>-base/<os>-qwt from one token and cannot express $BASE -> $GOLDEN. Teach it the pair, or seal this golden by the base route; do not improvise a third path" 2
  fi
else
  say "resealing the base $GOLDEN in place (no setup tree given)"
  mgmt/golden.sh seal "$GOLDEN" "$NOTE" 2>&1 | tee -a "$LOG" \
    || die "mgmt/golden.sh seal refused. If it refused because the sealed revisions are already gone, that is the TWO-shutdown window having closed: set GOLDEN_RESEAL_REASON to record the decision, or rebuild" 3
fi

# --- verify, and paste the output ---------------------------------------------------------------
say "verifying $GOLDEN"
if mgmt/golden.sh verify "$GOLDEN" 2>&1 | tee -a "$LOG"; then
  say "VERIFIED $GOLDEN"
else
  die "$GOLDEN does not verify after the rebuild - it is NOT a golden yet, whatever its name says" 3
fi

printf 'GOLDENRECREATE golden=%s base=%s setup=%s shots=%s log=%s\n' \
  "$GOLDEN" "$BASE" "${SETUP:-none}" "$(find "$SHOTS" -type f 2>/dev/null | wc -l)" "$LOG" | tee -a "$LOG"
complete_mark "$RUN"
exit 0
