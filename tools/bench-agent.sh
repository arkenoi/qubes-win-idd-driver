#!/bin/bash
# Repeatable gui-agent frame-cost benchmark. Run it identically before and after a change
# so the numbers are comparable; it drives the same workload and parses the same fields.
#
#   tools/bench-agent.sh <label>
#
# Produces instrumentation/bench-<label>.txt (raw QGAPERF log) and prints the summary.
# Requires: the instrumented agent running in win-idd-test, and drag-harness.ps1 +
# activity-gen.ps1 already pushed (this script pushes them itself).
set -uo pipefail

LABEL="${1:?usage: $0 <label>   e.g. before / after}"
VM="${QTEST_VM:-win-idd-test}"
IN="${QTEST_INCOMING:-C:\\Users\\user\\Documents\\QubesIncoming\\win-idd-mgmt}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HERE/instrumentation/bench-$LABEL.txt"

vmsh() { printf '%s\r\n' "$1" | qrexec-client-vm "$VM" qubes.VMShell 2>/dev/null | tr -d '\r'; }

echo "== bench '$LABEL' =="
# 0. sanity: the agent must be alive, and it must be the instrumented build
alive=$(vmsh 'powershell -NoProfile -Command "Write-Output (\"agent=\"+[bool](Get-Process gui-agent -EA SilentlyContinue))"' | grep -oE 'agent=(True|False)')
echo "  $alive"
[[ "$alive" == "agent=True" ]] || { echo "  FATAL: gui-agent not running"; exit 1; }

# 1. push the workload scripts (qtest push deletes-then-copies, so re-running is fine)
"$HERE/tools/qtest" push "$HERE/instrumentation/drag-harness.ps1" "$HERE/instrumentation/activity-gen.ps1" >/dev/null 2>&1

# 2. note the current agent log so we only collect records produced by THIS run
# NOTE: qubes.VMShell echoes the command line back, and that echo also contains "C:" and
# ".log", so a naive grep matches the echo instead of the answer. Use an explicit marker.
before_log=$(vmsh "powershell -NoProfile -Command \"Write-Output ('LOGPATH=' + (Get-ChildItem 'C:\\Program Files\\Qubes Tools\\log' -Filter 'gui-agent-*.log' | Sort LastWriteTime -Desc | Select -First 1).FullName)\"" | grep -oE '^LOGPATH=.*\.log' | tail -1 | cut -d= -f2-)
echo "  log: $before_log"

# 3. run the workload (idle / drag / scroll / type / idle)
echo "  running drag-harness..."
vmsh "powershell -NoProfile -ExecutionPolicy Bypass -File \"$IN\\drag-harness.ps1\"" > "$OUT.harness" 2>&1
grep -oE '### PHASE-(START|END) +[a-z0-9-]+ +[0-9.]+' "$OUT.harness" | head -20

# 4. pull the perf records via a pushed SCRIPT (inline -Command mangles the quoting
#    around "C:\Program Files\..." through cmd -> powershell and returns nothing).
"$HERE/tools/qtest" pushrun "$HERE/instrumentation/collect-perf.ps1" 2>/dev/null \
    | tr -d '\r' | sed -n '/===PERFSTART===/,/===PERFEND===/p' | grep 'QGAPERF,' > "$OUT"
n=$(grep -c 'QGAPERF,' "$OUT" || true)
echo "  collected $n QGAPERF records -> $OUT"
[[ "$n" -gt 0 ]] || { echo "  FATAL: no perf records (is PerfLog enabled?)"; exit 1; }

# 5. summarise
python3 "$HERE/instrumentation/analyze-perf.py" "$OUT" 2>&1 | sed -n '1,40p'
