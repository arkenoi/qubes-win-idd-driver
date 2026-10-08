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
# --allow-installer-console: the CALLING CELL DECLARES that it started a console itself, which is the
# only case where a console window is expected. Measured 2026-10-08 on the 4.3.36 gate: WIN11-upgrade
# and the template-update quick-upgrade both failed here on
#   AddWindow: ... class=CASCADIA_HOSTING_WINDOW_CLASS w=1115 h=628 t=67265
# which is the HARNESS's own installer: the upgrade path runs
#   Start-Process -WindowStyle Minimized -FilePath '<DISC>\install.cmd' ...
# and install.cmd is a batch file, so ShellExecute hosts it in cmd.exe - which on Windows 11 25H2 is
# Windows Terminal (CASCADIA_HOSTING_WINDOW_CLASS). Windows 10 hosts it in conhost and those cells
# passed. Jev 2026-10-08: whose_defect = harness 0.94, product 0.00;
# agent_should_filter_consoles 0.15 (a user who runs install.cmd DOES want to see that window);
# how_to_fix = the check excludes the cell's own installer, IDENTIFIED rather than assumed, 0.59.
# So the exclusion is DECLARED by the cell, never inferred here, and it is deliberately narrow:
# AT MOST ONE console window is tolerated under the flag. Two or more still FAIL, and any console
# window at all fails when the flag is absent - which is the four-week helper defect this check was
# written for.
#
# Exit: 0 = none mapped, 1 = FOUND (the defect), 2 = instrument failure (missing data fails).
# Prints one line naming the logs read and, on 1, the first offending AddWindow line.
set -uo pipefail
ALLOW_INSTALLER=0
_args=()
for a in "$@"; do
  case "$a" in
    --allow-installer-console) ALLOW_INSTALLER=1 ;;
    *) _args+=("$a") ;;
  esac
done
set -- "${_args[@]:-}"
VM=${1:?usage: $0 <vm> [--allow-installer-console]}
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
# Serial rig: inside quick-upgrade/matrix the held lock passes straight through (QWT_VMLOCK_HELD is
# exported there); run on its own, this takes the guest's lock like any other job.
. "$HERE/mgmt/harness/vmlock.sh"
vm_lock "$VM" 2>/dev/null || { echo "INSTRUMENT: $VM is held by another job - not judged"; exit 2; }
# ANCHOR ON THE AGENT'S OWN Init RECORD, NOT ON CLOCK COMPARISONS. This selected files by
# LastWriteTime >= LastBootUpTime and then filtered LINES by their timestamp against the boot stamp.
# Both comparisons assume the file's timestamps and LastBootUpTime were recorded in the SAME clock
# frame, and on this product they are not: the guest clock is corrected at boot (the QwtClockSync
# task pulls it from dom0 at boot+15 s), so a log written before the correction and a boot time
# recorded after it are minutes or hours apart in opposite directions. MEASURED 2026-10-08 on
# win11r-noise - BOOT=20261008.122831 with the newest agent log written at 20261008.122746, 41 s
# "before" the boot it belongs to - and the check returned CWC-LOGS=0 and could not judge on three
# consecutive installs.
# The agent writes an Init record every start, and this check ALREADY requires one as its proof of
# having read the log. So that record is the anchor: take the newest few logs by NAME (one file per
# module per day, so there are not many), find the LAST Init in each, and read only what follows it.
# No clock arithmetic anywhere, and the LogDir is resolved rather than hardcoded.
PS='$d = $null
try { $d = (Get-ItemProperty "HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools" -Name LogDir -EA Stop).LogDir } catch { }
if (-not $d) { $d = (Join-Path $env:SystemDrive "Qubes Logs") }
$f = @(Get-ChildItem -LiteralPath $d -Filter "gui-agent-*.log" -ErrorAction SilentlyContinue |
       Sort-Object Name -Descending | Select-Object -First 1)
Write-Output ("CWC-LOGS=" + $f.Count)
Write-Output ("CWC-DIR=" + $d)
foreach ($x in $f) {
  $fs = $null
  try {
    $fs = [System.IO.File]::Open($x.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $sr = New-Object System.IO.StreamReader($fs)
    # TWO PASSES over the lines held in memory: find the FIRST Init in this file, then report every
    # AddWindow after it. ONE FILE, THE NEWEST BY NAME, and from its FIRST Init: the log is one file
    # per module per DAY, so every agent instance of this run is in it, and an agent restart must
    # not hide an earlier window - which is why this takes the first Init and not the last. Reading
    # the three newest files instead reported YESTERDAYS window as this runs, measured here.
    $lines = New-Object System.Collections.ArrayList
    while ($null -ne ($ln = $sr.ReadLine())) {
      if ($ln -match "^.?\[(\d{8}\.\d{6})\.") { [void]$lines.Add($ln) }
    }
    $firstInit = -1
    for ($k = 0; $k -lt $lines.Count; $k++) { if ($lines[$k] -match "Init:") { $firstInit = $k; break } }
    if ($firstInit -ge 0) {
      "CWC-INIT|" + $x.Name
      for ($k = $firstInit; $k -lt $lines.Count; $k++) {
        if ($lines[$k] -match "AddWindow:.*class=(CASCADIA_HOSTING_WINDOW_CLASS|ConsoleWindowClass|PseudoConsoleWindow)") {
          "CWC-HIT|" + $x.Name + "|" + $lines[$k]
        }
      }
    }
    $sr.Dispose()
  } catch { "CWC-UNREADABLE|" + $x.Name }
  finally { if ($fs) { $fs.Dispose() } }
}
Write-Output "CWC-END"'
enc=$(printf '%s' "$PS" | python3 -c "import sys,base64;print(base64.b64encode(sys.stdin.read().encode('utf-16-le')).decode())")
out=$(QTEST_VM="$VM" timeout -k 5 120 "$HERE/tools/qtest" run "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc" 2>/dev/null | tr -d '\r')
echo "$out" | grep -aq '^CWC-END' || { echo "INSTRUMENT: no complete answer from $VM"; exit 2; }
nlogs=$(echo "$out" | grep -ao '^CWC-LOGS=[0-9]*' | cut -d= -f2)
[ "${nlogs:-0}" -ge 1 ] || { echo "INSTRUMENT: no gui-agent log found in $(echo "$out" | grep -ao '^CWC-DIR=.*' | cut -d= -f2-) on $VM"; exit 2; }
unread=$(echo "$out" | grep -ac '^CWC-UNREADABLE|')
[ "${unread:-0}" = 0 ] || { echo "INSTRUMENT: $unread agent log(s) could not be read on $VM - missing data fails: $(echo "$out" | grep -a '^CWC-UNREADABLE|' | cut -d'|' -f2 | tr '\n' ' ')"; exit 2; }
ninit=$(echo "$out" | grep -a '^CWC-INIT|' | cut -d'|' -f2 | sort -u | wc -l)
[ "$ninit" -ge 1 ] || { echo "INSTRUMENT: $nlogs agent log(s) read but no Init: line in any of them - not judged"; exit 2; }
hits=$(echo "$out" | grep -a '^CWC-HIT|')
if [ -n "$hits" ]; then
  nhits=$(echo "$hits" | wc -l)
  first=$(echo "$hits" | head -1 | cut -d'|' -f3- | cut -c1-200)
  if [ "$ALLOW_INSTALLER" = 1 ] && [ "$nhits" -eq 1 ]; then
    # The cell DECLARED that it started a console. Exactly one is the installer's; it is still
    # REPORTED, so it can never go unseen, and a second one is still the defect.
    echo "ONE console/Terminal window mapped and the cell declared its own installer console - tolerated, reported: $first"
    exit 0
  fi
  echo "FOUND $nhits console/Terminal window(s) mapped since the agent's last Init ($nlogs agent log(s)): $first"
  [ "$ALLOW_INSTALLER" = 1 ] && echo "  (the cell declared ONE installer console; $nhits were mapped, so at least one is not it)"
  exit 1
fi
echo "NONE: no console/Terminal window mapped since the agent's last Init ($nlogs agent log(s), $ninit with Init)"
exit 0
