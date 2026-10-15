#!/bin/bash
# Wrapper so the offline battery runs tools/campaign-state.py --selftest.
# campaign-state.py is the authoritative reader of a campaign's per-cell sweep reports. It exists
# because a hand-written grep watcher reported "0 FAIL" over a campaign with 4 failed cells and 3
# P1 breaches on 2026-10-15. Its selftest plants a failing report and REQUIRES the tool to report
# it, so the watcher itself can never go quietly blind the way the grep did.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
exec python3 tools/campaign-state.py --selftest
