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
#                                [--rerun <rerun-campaign-dir> ... --rerun-reason "<why>"]
#
# A RE-RUN OF FAILED CELLS (owner-approved, 2026-10-03: "rerun two missing cells", the rz38d gate's WIN10-clean wedge and its
# knock-on). A cell-group of the campaign that FAILED is accepted only if EVERY 'FAIL  <CELL>:' line in it names a cell, and each of those
# cells ran again in a --rerun campaign of the SAME ISO whose cell-group is clean and lists that cell. Any FAIL line that names no cell, a
# failed cell no clean re-run covers, or a failed re-run keeps the record FAILED. The record keeps every superseded failure verbatim, the
# re-run campaigns and the reason - it can never read cleaner than the logs.
#
# The campaign dir is an accraces-*/ style directory holding runner.log plus one <tag>.out per
# cell-group (what mgmt/harness drops). Cells and the verdict are DERIVED from those logs - never
# passed in - so the record cannot claim a cleaner run than the logs show.
set -uo pipefail
die() { echo "ERROR: $*" >&2; exit 1; }

ISO=""; CAMP=""; REL=""; RERUNS=(); RERUN_REASON=""
while [ $# -gt 0 ]; do
  case "$1" in
    --iso)      ISO="${2:-}"; shift 2 ;;
    --campaign) CAMP="${2:-}"; shift 2 ;;
    --release)  REL="${2:-}"; shift 2 ;;
    --rerun)    RERUNS+=("${2:-}"); shift 2 ;;
    --rerun-reason) RERUN_REASON="${2:-}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$ISO" ]  || die "no --iso given"
[ -n "$CAMP" ] || die "no --campaign given"
[ -f "$ISO" ]  || die "no such ISO: $ISO"
[ -d "$CAMP" ] || die "no such campaign dir: $CAMP"
for r in "${RERUNS[@]}"; do [ -d "$r" ] || die "no such re-run campaign dir: $r"; done
[ "${#RERUNS[@]}" -eq 0 ] || [ -n "$RERUN_REASON" ] || die "--rerun needs --rerun-reason (the record says why a failure was superseded)"

cd "$(git rev-parse --show-toplevel)" || die "run from inside the repo"
[ -n "$REL" ] || REL="$(tr -d ' \t\r\n' < agent/version)"

ISOSHA="$(sha256sum "$ISO" | cut -d' ' -f1)"

# ---- derive the verdict from the logs, never from an argument --------------------------------
# matrix.sh's per-cell footer is '=== MATRIX: N passed, M failed ==='. A cell-group whose .out has
# no such footer did not finish, and MUST NOT be counted clean - missing data fails.
clean=0; failed=0; cells=""; FAILED_GROUPS=()
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
  if [ "$nf" = "0" ]; then clean=$((clean+1)); else failed=$((failed+1)); FAILED_GROUPS+=("$f"); fi
  # The cells a group ran are echoed by matrix.sh as '[HH:MM:SS]   cells: a b c'; the timestamp is OPTIONAL. The pattern used to be
  # '^\[[0-9:]+\]?...', where only the ']' was optional, so a line without the timestamp was silently never read (found 2026-10-02 by
  # tools/tests/acceptance-record-selftest.sh when the feature tests' cell-groups recorded no cells).
  c="$(grep -aE '^(\[[0-9:]+\])?[[:space:]]*cells:' "$f" | tail -1 | sed -nE 's/.*cells:[[:space:]]*//p')"
  [ -n "$c" ] && cells="$cells $c"
done
shopt -u nullglob

# ---- a failed group superseded by clean re-runs of exactly its failed cells -----------------------------------------------------
SUPERSEDED_JSON="[]"
if [ "$failed" -gt 0 ] && [ "${#RERUNS[@]}" -gt 0 ]; then
  SUPERSEDED_JSON="$(python3 - "${#FAILED_GROUPS[@]}" "${FAILED_GROUPS[@]}" "${RERUNS[@]}" <<'PY'
import sys, re, glob, os, json
n = int(sys.argv[1]); groups = sys.argv[2:2+n]; reruns = sys.argv[2+n:]
footer = re.compile(r'^=== MATRIX: (\d+) passed, (\d+) failed ===$')
cellsln = re.compile(r'^(\[[0-9:]+\])?\s*cells:\s*(.*)$')
failln = re.compile(r'^(\[[0-9:]+\])?\s*FAIL  (.*)$')
named = re.compile(r'^([A-Za-z0-9]+-[A-Za-z0-9-]+?)(?: boot \d+)?:')   # 'WIN10-clean:' / 'WIN10-appvm boot 2:'
# the cells the re-runs passed: a re-run group counts only if its footer says 0 failed
passed_by = {}
for d in reruns:
    for f in sorted(glob.glob(os.path.join(d, '*.out'))):
        lines = open(f, encoding='utf-8', errors='replace').read().splitlines()
        fl = [footer.match(l) for l in lines if footer.match(l)]
        if not fl or fl[-1].group(2) != '0':
            print(f"FAILED: re-run group {f} did not finish clean", file=sys.stderr); sys.exit(3)
        cl = [cellsln.match(l).group(2) for l in lines if cellsln.match(l)]
        for c in (cl[-1].split() if cl else []):
            passed_by[c.lower()] = os.path.abspath(d)
out = []
for g in groups:
    fails = [failln.match(l).group(2) for l in open(g, encoding='utf-8', errors='replace').read().splitlines() if failln.match(l)]
    if not fails:
        print(f"FAILED: {g} says failed but carries no FAIL line - nothing to supersede", file=sys.stderr); sys.exit(3)
    for t in fails:
        m = named.match(t)
        if not m:
            print(f"FAILED: a FAIL line in {g} names no cell: {t[:120]}", file=sys.stderr); sys.exit(3)
        c = m.group(1).lower()
        if c not in passed_by and os.environ.get("RERUN_COVER_DEFECT") != "1":   # GUARD:rerun-covers (knob: tools/tests/acceptance-record-selftest.sh)
            print(f"FAILED: cell {c} failed in {g} and no clean re-run covers it", file=sys.stderr); sys.exit(3)
        out.append({"cell": c, "failed_in": os.path.abspath(g), "failure": t[:400], "passed_in": passed_by.get(c, "(no clean re-run)")})
print(json.dumps(out))
PY
)" && { failed=0; clean=$((clean+${#FAILED_GROUPS[@]})); for r in "${RERUNS[@]}"; do outs2=("$r"/*.out); for f in "${outs2[@]}"; do
      c="$(grep -aE '^(\[[0-9:]+\])?[[:space:]]*cells:' "$f" | tail -1 | sed -nE 's/.*cells:[[:space:]]*//p')"; [ -n "$c" ] && cells="$cells $c"; done; done; } \
    || SUPERSEDED_JSON="[]"
fi

CELLS_JSON="$(printf '%s' "$cells" | tr ' ' '\n' | sed '/^$/d' | sort -u | python3 -c '
import sys,json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"

VERDICT="CLEAN"
[ "$failed" -eq 0 ] || VERDICT="FAILED"

OUTDIR="${ACCEPT_RECORD_DIR:-scratchpad/acceptance-records}"   # override: tools/tests/acceptance-record-selftest.sh only
mkdir -p "$OUTDIR" || die "cannot create $OUTDIR"
OUT="$OUTDIR/${ISOSHA}.json"

python3 - "$OUT" "$ISOSHA" "$REL" "$clean" "$failed" "$VERDICT" "$CAMP" "$CELLS_JSON" "$SUPERSEDED_JSON" "$RERUN_REASON" "${RERUNS[@]}" <<'PY'
import json,sys,os,datetime
out,iso,rel,clean,failed,verdict,camp,cells,superseded,reason = sys.argv[1:11]
reruns = [os.path.abspath(r) for r in sys.argv[11:]]
rec = {
  "iso_sha256": iso,
  "release_version": rel,
  "cells": json.loads(cells),
  "cell_groups_clean": int(clean),
  "cell_groups_failed": int(failed),
  "verdict": verdict,
  "campaign_dir": os.path.abspath(camp),
  "recorded_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
}
if json.loads(superseded):
    rec["superseded_failures"] = json.loads(superseded)
    rec["rerun_campaign_dirs"] = reruns
    rec["rerun_reason"] = reason
json.dump(rec, open(out,"w"), indent=2)
print(f"recorded {verdict}: {clean} clean, {failed} failed -> {out}")
PY

if [ "$VERDICT" != "CLEAN" ]; then
  echo "NOTE: the record says FAILED. cut-release will refuse it - which is the point." >&2
  exit 1
fi
