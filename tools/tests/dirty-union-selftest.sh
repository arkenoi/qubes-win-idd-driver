#!/usr/bin/env bash
# dirty-union-selftest.sh - tools/wgcbroker/dirty_union.h (the broker's union of two frames' dirty regions, rest-zero S1) compiled on
# Linux from the SHIPPED header: the clean build must pass (every pixel of the union copied exactly once, none outside), and
# -DUNION_DEFECT (the two lists walked one after the other - the sum PublishCard copied until 2026-10-03) must fail. Exit 0 only if both.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
command -v g++ >/dev/null || { echo "FAIL  no g++ - nothing ran"; exit 2; }
g++ -std=c++17 -O1 -Wall -o "$T/clean" "$ROOT/tools/tests/dirty-union-test.cpp" || { echo "FAIL  the clean build did not compile"; exit 2; }
g++ -std=c++17 -O1 -DUNION_DEFECT -o "$T/defect" "$ROOT/tools/tests/dirty-union-test.cpp" || { echo "FAIL  the defect build did not compile"; exit 2; }
out=$("$T/clean"); rc=$?; dout=$("$T/defect"); drc=$?
printf '%s\n' "$out" | tail -1
if [ "$rc" = 0 ] && [ "$drc" = 1 ] && printf '%s\n' "$dout" | grep -q 'FAIL caret' && printf '%s\n' "$dout" | grep -q 'FAIL marquee'; then
  echo "PASS  the union is exact; the sum (UNION_DEFECT) fails the caret, the marquee and the random cases"; exit 0
fi
echo "FAIL  clean rc=$rc defect rc=$drc"; printf '%s\n' "$dout" | tail -3; exit 1
