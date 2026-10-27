#!/bin/bash
# campaign-state.py REPORTS a planted failing cell - the campaign watcher cannot go quietly blind.
# run: tools/tests/campaign-state-selftest.sh
# pass: exit 0
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
exec python3 tools/campaign-state.py --selftest
