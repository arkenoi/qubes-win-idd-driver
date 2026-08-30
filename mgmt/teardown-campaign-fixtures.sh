#!/bin/bash
# CAMPAIGN CLOSE-OUT C-2 — remove SPENT fixtures, keep everything future work needs.
#
# The owner's standing decision (memory: goldens-are-pristine-bases-only): only the two pristine
# bases are sealed goldens. Software-carrying fixtures — 4.3.14, stock 4.2.2, nopvdisk, the per-cell
# clones — are built on demand and torn down, never kept. This script encodes which is which so the
# judgement is reviewable instead of being made fresh (and differently) each time.
#
#   mgmt/teardown-campaign-fixtures.sh          # dry run: list, size, and reason
#   mgmt/teardown-campaign-fixtures.sh --go     # actually remove
set -uo pipefail
cd /home/user/qubes-win-idd-driver
GO=0; [ "${1:-}" = --go ] && GO=1

# ------------------------------------------------------------------ KEEP, with the reason
declare -A KEEP=(
  [win10-base]="sealed golden - the only pristine Win10 base; never delete, never boot"
  [win11-base]="sealed golden - the only pristine Win11 base; never delete, never boot"
  [win10-tpl]="TemplateVM - win10-app derives from it, and the named gap 'install has never run on a
               TemplateVM' needs one. NOTE: contaminated by the U1 diagnosis; rebuild from win10-base
               before grading any template cell on it"
  [win11-tpl]="TemplateVM - win11-app derives from it"
  [win10-app]="AppVM carrying netvm - the PV-network half of the matrix needs it (0.3 GB)"
  [win11-app]="AppVM carrying netvm - same (0.5 GB)"
  [win10-p46]="current clean subject: P4/P5 ran on it, and RND-3/RND-4/RND-8 are still unrun"
)

# ------------------------------------------------------------------ SPENT, with what consumed it
declare -A SPENT=(
  [win10-c1]="C1 clean-install cell graded; rebuildable from win10-base in ~2 s + install"
  [win11-c1]="C1 clean-install cell graded; rebuildable from win11-base"
  [win10-gold0]="campaign fixture, cells graded"
  [win11-gold0]="campaign fixture, cells graded"
  [win10-goldr]="candidate-carrying upgrade fixture, cells graded"
  [win11-goldr]="candidate-carrying upgrade fixture, cells graded"
  [win10-p45]="superseded by win10-p46 (which is the subject P4/P5 actually ran on)"
)

size_gb(){ python3 - "$1" <<'PY' 2>/dev/null || echo 0
import qubesadmin,sys
v=qubesadmin.Qubes().domains[sys.argv[1]]
t=0
for vol in v.volumes.values():
    try: t+=(vol.usage or 0)
    except Exception: pass
print(f"{t/2**30:.1f}")
PY
}

echo "=== KEEP ==="
for v in "${!KEEP[@]}"; do
  qvm-check "$v" >/dev/null 2>&1 || { printf "  %-14s (absent)\n" "$v"; continue; }
  printf "  %-14s %5s GB  %s\n" "$v" "$(size_gb "$v")" "$(echo "${KEEP[$v]}" | tr -s ' \n' ' ')"
done

echo
echo "=== REMOVE ==="
total=0; targets=()
for v in "${!SPENT[@]}"; do
  qvm-check "$v" >/dev/null 2>&1 || { printf "  %-14s (already gone)\n" "$v"; continue; }
  st=$(qvm-ls --raw-data --fields STATE "$v" 2>/dev/null | tail -1)
  g=$(size_gb "$v"); total=$(python3 -c "print(f'{$total+$g:.1f}')")
  printf "  %-14s %5s GB  [%s]  %s\n" "$v" "$g" "$st" "${SPENT[$v]}"
  targets+=("$v")
done
echo "  ---- reclaim: ${total} GB across ${#targets[@]} qube(s)"

if [ "$GO" != 1 ]; then
  echo
  echo "DRY RUN. Re-run with --go to remove. Nothing was changed."
  exit 0
fi

echo
for v in "${targets[@]}"; do
  # Never remove a running qube out from under a job: shut it down first and say so.
  st=$(qvm-ls --raw-data --fields STATE "$v" 2>/dev/null | tail -1)
  if [ "$st" != Halted ]; then
    echo "  $v is $st - shutting down first"
    timeout -k 10 320 qvm-shutdown --wait --timeout 260 "$v" >/dev/null 2>&1
  fi
  if timeout -k 10 300 qvm-remove -f "$v" >/dev/null 2>&1; then
    echo "  removed $v"
    rm -f "mgmt/fixtures/$v.json" && echo "    (receipt mgmt/fixtures/$v.json deleted)"
  else
    echo "  FAILED to remove $v - left in place"
  fi
done
echo
python3 - <<'PY'
import qubesadmin
a=qubesadmin.Qubes()
p=next((x for x in a.pools.values() if x.name=='vm-pool'), None) or list(a.pools.values())[0]
u,s=getattr(p,'usage',None),getattr(p,'size',None)
if u and s: print(f"pool {p.name}: {100*u/s:.1f}% used, {(s-u)/2**30:.1f} GB free")
PY
