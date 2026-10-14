#!/bin/bash
# logsweep-rotation-placeholder-selftest.sh - an empty .old is expected ONLY below the threshold.
#
# WHY. QWT's logger rotates <log> -> <log>.old past ~1 MB (qtb_shared.h) and
# provision-etwproxy-account.ps1 pre-creates BOTH names empty so the rename ACE can name each. The
# analyzer read the 0-byte etw-proxy.log.old as missing data, so the 2026-10-14 acceptance campaign
# graded rc=3 DATA on EVERY cell while 37 files / 2631 QWT lines sat beside it.
#
# The rule must keep its teeth: an empty .old beside a live log ALREADY over the threshold means the
# rotation did not run, and that is still a problem. These checks pin both directions, so a name
# allowlist cannot pass them.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 2

pass=0; fail=0
ck(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1: expected '$2', got '$3'"; fi; }

r(){ python3 - "$@" <<'PY'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("ls", "tools/log-sweep.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
name = sys.argv[1]
gb = {}
if len(sys.argv) > 3 and sys.argv[3] != "-":
    gb[sys.argv[2]] = int(sys.argv[3])
w = m.rotation_placeholder(name, gb)
print("EXPECTED" if w else "PROBLEM")
PY
}

ck "empty .old below the threshold is expected"        "EXPECTED" "$(r 'etw-proxy.log.old' 'etw-proxy.log' 5000)"
ck "empty .old at 1 MB-1 is still expected"            "EXPECTED" "$(r 'etw-proxy.log.old' 'etw-proxy.log' 1048575)"
ck "empty .old AT the threshold is a PROBLEM"          "PROBLEM"  "$(r 'etw-proxy.log.old' 'etw-proxy.log' 1048576)"
ck "empty .old over the threshold is a PROBLEM"        "PROBLEM"  "$(r 'etw-proxy.log.old' 'etw-proxy.log' 4000000)"
ck "empty .old with NO live counterpart is a PROBLEM"  "PROBLEM"  "$(r 'etw-proxy.log.old' '-' '-')"
ck "an empty ordinary log is still a PROBLEM"          "PROBLEM"  "$(r 'agent.log' 'agent.log' 0)"
ck "an empty bridge.log.old below threshold too"       "EXPECTED" "$(r 'bridge.log.old' 'bridge.log' 12)"

echo "logsweep-rotation-placeholder-selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
