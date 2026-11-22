#!/usr/bin/env bash
# quick-upgrade-controls.sh - the control repetitions owed after a wedged cell. Owner 2026-11-22: «for every wedged cell we
# need at least 10 control repetitions afterwards». Runs mgmt/harness/quick-upgrade.sh N times, serially, with the arguments
# of the step that wedged, each run into its own evidence directory, and STOPS at the first run that does not exit 0, so that
# subject stays exactly as quick-upgrade left it: a second stall is the finding and its specimen is the evidence. It writes
# no coverage receipt - a control measures how often the step stalls; it never replaces the cell's verdict.
#
#   quick-upgrade-controls.sh <N> <release-iso-or-setup-tree> <subject> <os> [outroot]
#     outroot  default /home/user/qwt-accept/controls-<subject>-<UTC stamp>; run k writes <outroot>/run-<k>/quick-upgrade.out
#              and its quick-upgrade evidence under <outroot>/run-<k>/qu
# Prints one line per run, "CONTROL k/N PASS|FAIL rc=<rc> <seconds>s <dir>", and a last line "CONTROLS <passed>/<N> ...".
# Exit 0 when all N passed, 1 at the first non-PASS, 2 on a usage error.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 2
N="${1:-}"; PKG="${2:-}"; SUBJECT="${3:-}"; OS="${4:-}"
USAGE="[ERROR] usage: $0 <N> <release-iso-or-setup-tree> <subject> <os> [outroot]"
case "$N" in ''|*[!0-9]*|0) echo "$USAGE" >&2; exit 2 ;; esac
[ -n "$PKG" ] && [ -e "$PKG" ] && [ -n "$SUBJECT" ] && [ -n "$OS" ] || { echo "$USAGE" >&2; exit 2; }
ROOT="${5:-/home/user/qwt-accept/controls-$SUBJECT-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$ROOT" || exit 2
echo "[$(date -u +%H:%M:%S)] [INFO] CONTROLS $N x quick-upgrade $PKG $SUBJECT $OS -> $ROOT (harness $(git rev-parse --short HEAD))"
passed=0
for k in $(seq 1 "$N"); do
  d="$ROOT/run-$k"; mkdir -p "$d" || exit 2; t0=$(date +%s)
  QU_OUT="$d/qu" mgmt/harness/quick-upgrade.sh "$PKG" "$SUBJECT" "$OS" >"$d/quick-upgrade.out" 2>&1; rc=$?
  if [ "$rc" -eq 0 ]; then
    passed=$((passed + 1))
    echo "[$(date -u +%H:%M:%S)] [INFO] CONTROL $k/$N PASS rc=0 $(( $(date +%s) - t0 ))s $d"
  else
    echo "[$(date -u +%H:%M:%S)] [ERROR] CONTROL $k/$N FAIL rc=$rc $(( $(date +%s) - t0 ))s $d - stopped; $SUBJECT left as quick-upgrade left it"
    echo "[$(date -u +%H:%M:%S)] [ERROR] CONTROLS $passed/$N passed before the first non-PASS (run $k)"
    exit 1
  fi
done
echo "[$(date -u +%H:%M:%S)] [INFO] CONTROLS $passed/$N PASS"
