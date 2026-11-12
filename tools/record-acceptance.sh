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
# WHAT IT READS: the campaign's JSON, through tools/acceptance_json.py - <campaign>/matrix/matrix-result.json and
# checks.jsonl (written by mgmt/harness/matrix.sh) and one <campaign>/feature-<test>.json per feature test (written by
# tools/release-acceptance.sh). The groups, the cells and the verdict are DERIVED from those - never passed in - so the
# record cannot claim a cleaner run than the campaign wrote. No log text is read; a campaign that left no JSON cannot
# be recorded.
#
# A GROUP IS CLEAN when: the matrix's result is final and complete, none of its rows is FAIL or INVALID, and every
# planned cell has a passing check; a feature test exited 0. Anything else is a failed group, and missing data fails.
#
# A RE-RUN OF FAILED CELLS (owner-approved 2026-10-03: "rerun two missing cells"). The rule is _supersede in
# tools/acceptance_json.py: a failed MATRIX group is accepted only if it reached its footer, at least one failed check
# in it names a cell, and every cell a failed row names or that has no passing check passed in a --rerun campaign of
# the SAME ISO whose every group is clean; a failed FEATURE group only if its test exited 2 (could not measure) and
# that group passed in such a campaign - a product failure stays. Anything else keeps the record FAILED. The record
# keeps every superseded failure verbatim, the re-run campaigns and the reason.
# FIRST REAL USE 2026-11-12, read row by row: build-4.3.41.1272's record (ISO c42abbb8) from the full campaign
# rel-43099265433 with --rerun rel-43099265433.tup-r4 - template-update's exit 2 superseded, the other five groups
# and all 13 cells matching the campaign's own JSON, verdict CLEAN; a re-run that is itself not clean refuses the
# whole supersession (_supersede), so only the clean re-run is passed and an earlier failed one is named in the reason.
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

OUTDIR="${ACCEPT_RECORD_DIR:-scratchpad/acceptance-records}"
mkdir -p "$OUTDIR" || die "cannot create $OUTDIR"
OUT="$OUTDIR/${ISOSHA}.json"

# ---- derive the record from what the campaign wrote as JSON, never from an argument or a log line ----------------------
# The reader is asked directly, in this one process: the facts never travel through a shell variable or a pipe.
# Exit: 0 recorded CLEAN, 1 recorded FAILED, 3 the campaign holds no group result (nothing is recorded).
python3 - "$OUT" "$ISOSHA" "$REL" "$CAMP" "$RERUN_REASON" "${RERUNS[@]}" <<'PY'
import datetime, json, os, sys
sys.path.insert(0, os.path.join(os.getcwd(), "tools"))
import acceptance_json
out, iso, rel, camp, reason = sys.argv[1:6]
reruns = sys.argv[6:]
f = acceptance_json.record_facts(camp, reruns)
if not f["groups"]:
    print("ERROR: no group result in %s (matrix/matrix-result.json, feature-*.json) - nothing to record" % camp, file=sys.stderr)
    sys.exit(3)
verdict = "CLEAN" if f["failed"] == 0 else "FAILED"
rec = {
  "iso_sha256": iso,
  "release_version": rel,
  "cells": f["cells"],
  "cell_groups_clean": f["clean"],
  "cell_groups_failed": f["failed"],
  "verdict": verdict,
  "campaign_dir": os.path.abspath(camp),
  "recorded_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
  "derived_from": "the campaign's JSON results, through tools/acceptance_json.py; no log text",
  "groups": [{"group": g["group"], "clean": g["clean"], "why": g["why"]} for g in f["groups"]],
}
if f["superseded"]:
    rec["superseded_failures"] = f["superseded"]
    rec["rerun_campaign_dirs"] = [os.path.abspath(r) for r in reruns]
    rec["rerun_reason"] = reason
if f["rerun_refused"]:
    rec["rerun_refused"] = f["rerun_refused"]
json.dump(rec, open(out, "w"), indent=2)
print(f"recorded {verdict}: {f['clean']} clean, {f['failed']} failed -> {out}")
for g in f["groups"]:
    if not g["clean"]:
        print(f"  not clean: {g['group']} - {g['why']}")
if f["rerun_refused"]:
    print(f"  re-run NOT accepted: {f['rerun_refused']}")
sys.exit(0 if verdict == "CLEAN" else 1)
PY
rc=$?

case "$rc" in
  0) ;;
  1) echo "NOTE: the record says FAILED. cut-release will refuse it - which is the point." >&2; exit 1 ;;
  3) die "no group result in $CAMP - nothing to record" ;;
  *) die "the record could not be written (rc=$rc)" ;;
esac
