#!/usr/bin/env bash
# console-window-check.sh <vm> - did our agent map a CONSOLE or TERMINAL window on this boot?
#
# WHY (2026-09-30). The toast bridge's helper was a console program started in the user's session,
# so every boot put a blank Windows Terminal window on the user's desktop and the agent mapped it to
# dom0 as a black window. It shipped for four weeks and was SEEN twice (09-08, 09-27) without being
# questioned, because no check anywhere looked for a window nobody asked for - every pixel check
# looks at its own fixture. On a boot where no one opened a console, a console or Terminal window
# the agent maps is ours (a helper) or the harness's, never the user's.
#
# Reads EVERY gui-agent log created since this boot (an agent restart must not hide an earlier
# window) for AddWindow lines of the console classes. Proof the logs were read: at least one
# agent `Init:` line - no proof, no verdict.
#
# Exit: 0 = none mapped, 1 = FOUND (the defect), 2 = instrument failure (missing data fails).
# Prints one line naming the logs read and, on 1, the first offending AddWindow line.
set -uo pipefail
VM=${1:?usage: $0 <vm>}
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
# Serial rig: inside quick-upgrade/matrix the held lock passes straight through (QWT_VMLOCK_HELD is
# exported there); run on its own, this takes the guest's lock like any other job.
. "$HERE/mgmt/harness/vmlock.sh"
vm_lock "$VM" 2>/dev/null || { echo "INSTRUMENT: $VM is held by another job - not judged"; exit 2; }
PS='$b = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
$f = @(Get-ChildItem -Path "Q:\Qubes Logs" -Filter "gui-agent-*.log" -ErrorAction SilentlyContinue | Where-Object { $_.CreationTime -ge $b })
Write-Output ("CWC-LOGS=" + $f.Count)
foreach ($x in $f) {
  Select-String -LiteralPath $x.FullName -Pattern "Init:", "AddWindow:.*class=(CASCADIA_HOSTING_WINDOW_CLASS|ConsoleWindowClass|PseudoConsoleWindow)" |
    ForEach-Object { if ($_.Line -match "Init:") { "CWC-INIT|" + $x.Name } else { "CWC-HIT|" + $x.Name + "|" + $_.Line } }
}
Write-Output "CWC-END"'
enc=$(printf '%s' "$PS" | python3 -c "import sys,base64;print(base64.b64encode(sys.stdin.read().encode('utf-16-le')).decode())")
out=$(QTEST_VM="$VM" timeout -k 5 120 "$HERE/tools/qtest" run "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc" 2>/dev/null | tr -d '\r')
echo "$out" | grep -aq '^CWC-END' || { echo "INSTRUMENT: no complete answer from $VM"; exit 2; }
nlogs=$(echo "$out" | grep -ao '^CWC-LOGS=[0-9]*' | cut -d= -f2)
[ "${nlogs:-0}" -ge 1 ] || { echo "INSTRUMENT: no gui-agent log created since this boot on $VM"; exit 2; }
ninit=$(echo "$out" | grep -a '^CWC-INIT|' | cut -d'|' -f2 | sort -u | wc -l)
[ "$ninit" -ge 1 ] || { echo "INSTRUMENT: $nlogs agent log(s) since boot but no Init: line read - not judged"; exit 2; }
hits=$(echo "$out" | grep -a '^CWC-HIT|')
if [ -n "$hits" ]; then
  echo "FOUND $(echo "$hits" | wc -l) console/Terminal window(s) mapped since boot ($nlogs agent log(s)): $(echo "$hits" | head -1 | cut -d'|' -f3- | cut -c1-200)"
  exit 1
fi
echo "NONE: no console/Terminal window mapped since boot ($nlogs agent log(s), $ninit with Init)"
exit 0
