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
. "$(dirname "$0")/harness/shutdown-lib.sh"
set -uo pipefail
cd /home/user/qubes-win-idd-driver
GO=0; REBUILD=0
case "${1:-}" in
  --go)              GO=1 ;;
  --rebuild-missing) REBUILD=1 ;;
esac

# WHICH rebuild-rig STEP PRODUCES EACH KEEP ITEM. This is a MAP, not a sentence: a KEEP entry that
# is absent is rebuilt by running its step, and this script runs it. It used to carry prose telling
# the reader how to rebuild win10-tpl, and that prose was WRONG - it said "from win10-base", which
# cannot work because clone-to-template waits for qrexec on its settle boot and a pristine base has
# no QWT (seven minutes of timeout, measured 2026-10-13). Instructions rot because nothing executes
# them; a step name is checked every time the step runs.
declare -A REBUILD_STEP=(
  [win10-base]=base10   [win11r-base]=base11
  [win10-iqi]=iqi10     [win11-iqi]=iqi11
  [win10-tpl]=tpl10     [win10-app]=tpl10
  [win11-tpl]=tpl11     [win11-app]=tpl11
)

# ------------------------------------------------------------------ KEEP, with the reason
# REMOVED FROM KEEP 2026-10-13, deliberately, so this list states what is true:
#   win11-base                   expired Enterprise Evaluation; superseded by win11r-base 2026-10-01
#   win11de-base                 no gate suite enters from it - the German work is served by
#                                win11de-qwt, so rebuilding it costs ~30 min and 15 GB for nothing
#   ckpt-win11de-gwt-pretuesday  park of win11de-gwt, which no longer exists
#   win11de-gwt, win10-p46       gone
# A KEEP list naming things nobody keeps is the same rot as a comment describing a procedure nobody
# runs: it reads as a decision when it is only a leftover.
declare -A KEEP=(
  [win10-base]="sealed golden - the only pristine Win10 base; never delete, never boot"
  [win11r-base]="sealed golden - pristine RETAIL Win11 Pro 26300.9457 en-US, no QWT; THE Win11 base since 2026-10-01 (owner: no time-limited eval); never delete, never boot"
  [win10-iqi]="previous-ours ENTRY FIXTURE (4.3.17) for the win10-upgrade acceptance cell (tools/release-acceptance.sh G10 default); pruned once on 2026-09-17 and the campaign went PARTIAL - rebuild costs ~10 min, keep it"
  [win11-iqi]="previous-ours ENTRY FIXTURE (4.3.17) for the win11-upgrade acceptance cell (G11 default); same story - keep it"
  [win11de-qwt]="sealed golden - German Win11 25H2 + QWT-NG 4.3.29, account gerd-test, TemplateVM, UN-UPDATED: GWeck's environment before a Windows Update pass. Owner 2026-09-16: keep, with QWT, to avoid lengthy reinstalls; never delete, never boot - clone it"
  [win10-tpl]="TemplateVM - win10-app derives from it; the 'install has never run on a TemplateVM' gap needs one"
  [win11-tpl]="TemplateVM - win11-app derives from it"
  [win10-app]="AppVM carrying netvm - the PV-network half of the matrix needs it (0.3 GB)"
  [win11-app]="AppVM carrying netvm - same (0.5 GB)"
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
  if ! qvm-check "$v" >/dev/null 2>&1; then
    step="${REBUILD_STEP[$v]:-}"
    if [ -z "$step" ]; then printf "  %-14s (absent, no rebuild step defined)\n" "$v"; continue; fi
    if [ "$REBUILD" = 1 ]; then
      printf "  %-14s ABSENT -> rebuilding with step %s\n" "$v" "$step"
      mgmt/harness/rebuild-rig.sh --only "$step" || { echo "  rebuild of $v FAILED - see its evidence dir" >&2; exit 10; }
    else
      printf "  %-14s (absent; --rebuild-missing runs step %s)\n" "$v" "$step"
    fi
    continue
  fi
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
    qwt_shutdown "$v" 600
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
