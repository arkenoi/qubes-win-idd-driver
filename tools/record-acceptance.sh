#!/usr/bin/env bash
# Record that full acceptance ran on a SPECIFIC ISO, so tools/cut-release.sh can require it.
#
# WHY THE RECORD IS KEYED BY THE ISO's OWN SHA256, and why cut-release takes no path to it:
# a record you can point at is a record you can point at the wrong one. 4.3.19 was published on a
# partial check (owner: "full acceptance before release is a HARD GATE"), and on 2026-09-09 a chain
# script verified one package while acceptance ran on another. So the record's FILENAME is the hash
# of the bytes it is about; cut-release computes that hash from the ISO it fetched and looks it up.
# There is no way to hand it a different record, and no flag to skip the lookup.
#
# The record lives under scratchpad/ (gitignored): it is per-run evidence, and per the repo rule
# internal/per-run material never enters this public repo.
#
# Usage:
#     tools/record-acceptance.sh --iso <path> --campaign <campaign-out-dir> [--release <ver>]
#
# The campaign dir is an accraces-*/ style directory holding runner.log plus one <tag>.out per
# cell-group (what mgmt/harness drops). Cells and the verdict are DERIVED from those logs - never
# passed in - so the record cannot claim a cleaner run than the logs show.
set -uo pipefail
die() { echo "ERROR: $*" >&2; exit 1; }

ISO=""; CAMP=""; REL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --iso)      ISO="${2:-}"; shift 2 ;;
    --campaign) CAMP="${2:-}"; shift 2 ;;
    --release)  REL="${2:-}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$ISO" ]  || die "no --iso given"
[ -n "$CAMP" ] || die "no --campaign given"
[ -f "$ISO" ]  || die "no such ISO: $ISO"
[ -d "$CAMP" ] || die "no such campaign dir: $CAMP"

cd "$(git rev-parse --show-toplevel)" || die "run from inside the repo"
[ -n "$REL" ] || REL="$(tr -d ' \t\r\n' < agent/version)"

ISOSHA="$(sha256sum "$ISO" | cut -d' ' -f1)"

# ---- derive the verdict from the logs, never from an argument --------------------------------
# matrix.sh's per-cell footer is '=== MATRIX: N passed, M failed ==='. A cell-group whose .out has
# no such footer did not finish, and MUST NOT be counted clean - missing data fails.
clean=0; failed=0; cells=""
shopt -s nullglob
outs=("$CAMP"/*.out)
[ "${#outs[@]}" -gt 0 ] || die "no cell-group output (*.out) in $CAMP - nothing to record"
for f in "${outs[@]}"; do
  line="$(grep -aE '^=== MATRIX: [0-9]+ passed, [0-9]+ failed ===$' "$f" | tail -1)"
  if [ -z "$line" ]; then
    echo "ERROR: $(basename "$f") has no MATRIX footer - that cell-group did not finish" >&2
    failed=$((failed+1)); continue
  fi
  nf="$(printf '%s' "$line" | sed -nE 's/.*, ([0-9]+) failed ===$/\1/p')"
  if [ "$nf" = "0" ]; then clean=$((clean+1)); else failed=$((failed+1)); fi
  # The cells a group ran are echoed by matrix.sh as '  cells: a b c'
  c="$(grep -aE '^\[[0-9:]+\]?[[:space:]]*cells:' "$f" | tail -1 | sed -nE 's/.*cells:[[:space:]]*//p')"
  [ -n "$c" ] && cells="$cells $c"
done
shopt -u nullglob

CELLS_JSON="$(printf '%s' "$cells" | tr ' ' '\n' | sed '/^$/d' | sort -u | python3 -c '
import sys,json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"

VERDICT="CLEAN"
[ "$failed" -eq 0 ] || VERDICT="FAILED"

OUTDIR="scratchpad/acceptance-records"
mkdir -p "$OUTDIR" || die "cannot create $OUTDIR"
OUT="$OUTDIR/${ISOSHA}.json"

python3 - "$OUT" "$ISOSHA" "$REL" "$clean" "$failed" "$VERDICT" "$CAMP" "$CELLS_JSON" <<'PY'
import json,sys,os,datetime
out,iso,rel,clean,failed,verdict,camp,cells = sys.argv[1:9]
json.dump({
  "iso_sha256": iso,
  "release_version": rel,
  "cells": json.loads(cells),
  "cell_groups_clean": int(clean),
  "cell_groups_failed": int(failed),
  "verdict": verdict,
  "campaign_dir": os.path.abspath(camp),
  "recorded_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
}, open(out,"w"), indent=2)
print(f"recorded {verdict}: {clean} clean, {failed} failed -> {out}")
PY

if [ "$VERDICT" != "CLEAN" ]; then
  echo "NOTE: the record says FAILED. cut-release will refuse it - which is the point." >&2
  exit 1
fi
