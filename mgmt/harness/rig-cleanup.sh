#!/usr/bin/env bash
# rig-cleanup.sh - reclaim the thin pool by removing LEFTOVER subjects, and nothing else.
#
#   mgmt/harness/rig-cleanup.sh            # DRY by default: says what it would remove, touches nothing
#   mgmt/harness/rig-cleanup.sh --go       # remove them
#   mgmt/harness/rig-cleanup.sh --go --keep "win11r-sup win11-acc"
#
# WHY THIS IS A SCRIPT AND NOT A JUDGEMENT CALL. Owner 2026-10-25: "do better cleanup. you have a lot
# of leftover VMs", and in the same breath "all preparation and preflight gates should be mecahnized
# too". A cleanup done by picking names out of a list is exactly the hand-work that directive
# forbids: the next person does it differently, and the one time they get it wrong they delete a
# sealed golden or an entry fixture a campaign needs. So the PROTECTED set is DERIVED, never typed:
#
#   * every sealed golden            <- mgmt/goldens/*.json           (the seal records on disk)
#   * every entry fixture            <- campaign-preflight's ENTRY_FIXTURES, parsed from it
#   * every template                 <- qvm-ls CLASS=TemplateVM
#   * the appvm cells' templates     <- matrix.sh's own cell_appvm arguments
#   * dom0 and this management qube  <- never ours to touch (CLAUDE.md: off-limits)
#   * anything RUNNING               <- refused, named, and left alone
#
# Everything else that is tagged win-idd-testbed is a disposable subject: every harness here
# recreates its subject from a golden or a fixture (prime-run REMOVES and recreates its target;
# clone-guest.sh clones; the matrix parks its own checkpoint in the clean cell). A leftover is
# therefore cost without evidence - and this rig ran out of thin pool mid-campaign because of them.
#
# CHECKPOINTS ARE INCLUDED ON PURPOSE. `ckpt-<vm>-installed` is a parked install state, and
# mgmt/harness/matrix.sh:53 already sanctions `qvm-remove ckpt-<vm>-installed` while its clean cell
# PARKS A FRESH ONE for the package under test. A checkpoint from an older package is not an asset;
# it is a stale snapshot that an unpark would silently grade.
#
# Self-test: tools/tests/rig-cleanup-selftest.sh (every refusal driven; nothing touches a real qube).
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 2

GO=0; KEEP_EXTRA=""
while [ $# -gt 0 ]; do
  case "$1" in
    --go)   GO=1; shift ;;
    --keep) KEEP_EXTRA="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown argument '$1'" >&2; exit 2 ;;
  esac
done

QVM_LS="${QVM_LS:-qvm-ls}"
QVM_CHECK="${QVM_CHECK:-qvm-check}"
QVM_REMOVE="${QVM_REMOVE:-qvm-remove}"
GOLDENS_DIR="${GOLDENS_DIR:-mgmt/goldens}"
PREFLIGHT="${PREFLIGHT:-mgmt/harness/campaign-preflight.sh}"
MATRIX="${MATRIX:-mgmt/harness/matrix.sh}"
TAG="${TAG:-win-idd-testbed}"

say(){ printf '%s %s\n' "$(date -u '+%H:%M:%S')" "$*"; }

# ---- the protected set, DERIVED -----------------------------------------------------------------
protected=" dom0 win-idd-mgmt "
# sealed goldens, from the seal records themselves
for f in "$GOLDENS_DIR"/*.json; do
  [ -e "$f" ] || continue
  protected="$protected$(basename "$f" .json) "
done
# entry fixtures, parsed from the preflight's own default rather than repeated here
if [ -r "$PREFLIGHT" ]; then
  _ef=$(sed -n 's/^ENTRY_FIXTURES="\${ENTRY_FIXTURES:-\(.*\)}"$/\1/p' "$PREFLIGHT" | head -1)
  for fx in $_ef; do protected="$protected${fx%%:*} ${fx##*:} "; done
fi
# the appvm cells' templates, from the matrix's own cell arguments
if [ -r "$MATRIX" ]; then
  for t in $(sed -n 's/.*cell_appvm[^#]*\(win[0-9a-z]*-tpl\).*/\1/p' "$MATRIX" | sort -u); do
    protected="$protected$t "
  done
fi
for k in $KEEP_EXTRA; do protected="$protected$k "; done

# every TemplateVM on the rig, whatever it is called
while IFS='|' read -r n c; do
  [ "$c" = TemplateVM ] && protected="$protected$n "
done < <($QVM_LS --raw-data --fields NAME,CLASS 2>/dev/null)

say "protected (derived):$protected"

# ---- the candidates -----------------------------------------------------------------------------
# BY NAME from one listing, never a per-qube enumeration (qvm-ls fires admin.vm.property.Get per
# qube and a denied call lands in the owner's dom0 journal).
removed=0; skipped_running=0; candidates=""
while IFS='|' read -r n st; do
  [ -n "$n" ] || continue
  case " $protected " in *" $n "*) continue ;; esac
  # ONLY OURS. An untagged qube is not ours to remove, and this is the line that makes that true
  # rather than hoped: CLAUDE.md's rig rule is that every qube tagged win-idd-testbed is drivable
  # and nothing else is touched at all.
  if ! qvm-tags "$n" list 2>/dev/null | grep -qx "$TAG"; then
    say "  skip $n - not tagged $TAG, so not ours"
    continue
  fi
  if [ "$st" != Halted ]; then
    say "  SKIP $n - $st, a running guest is never removed by a cleanup"
    skipped_running=$((skipped_running+1))
    continue
  fi
  candidates="$candidates$n "
done < <($QVM_LS --raw-data --fields NAME,STATE 2>/dev/null)

if [ -z "$candidates" ]; then
  say "nothing to reclaim: no halted, tagged, unprotected subject"
  exit 0
fi
say "leftovers:$candidates"

if [ "$GO" != 1 ]; then
  say "DRY: nothing removed. Re-run with --go to remove the leftovers above."
  exit 0
fi

for n in $candidates; do
  if $QVM_REMOVE -f "$n" >/dev/null 2>&1; then
    say "  removed $n"
    removed=$((removed+1))
  else
    say "  [WARN] could not remove $n - left in place"
  fi
done
say "reclaimed $removed subject(s); $skipped_running left alone because they were running"
