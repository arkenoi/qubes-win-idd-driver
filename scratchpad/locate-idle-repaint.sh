#!/bin/bash
# =============================================================================
# locate-idle-repaint.sh - WHERE is the idle Windows 11 repaint coming from?
# =============================================================================
#
#   scratchpad/locate-idle-repaint.sh <vm> <label> [samples]
#
# Measured: Windows 11 presents 18.75 fps with NO input at all, carrying ~350k real dirty
# pixels per frame (empty=0). That is 77% of its own workload rate and MORE than Windows 10's
# entire workload rate, so the Win11 "surplus" is mostly ambient - something repaints with
# nobody touching the machine.
#
# What is NOT known is WHICH surface. Widgets/weather, search highlights, Copilot and the
# taskbar clock are all plausible, and testing them one registry key at a time costs a
# ~45-minute reinstall per guess.
#
# THIS NEEDS NO AGENT CHANGE AND NO BUILD. dom0's fullshot service already returns the whole
# desktop as PNG. Capture a few during idle, diff consecutive pairs, and report the bounding
# box of changed pixels. A taskbar strip, a widget flyout and a window's client area are
# trivially distinguishable by that box.
#
# Screenshots are a poor benchmark instrument - too slow, and they measure the capture path
# rather than the guest. That objection does not apply here: this is not timing anything, it
# is locating a region.
set -u
cd /home/user/qubes-win-idd-driver

VM="${1:?usage: $0 <vm> <label> [samples]}"
LABEL="${2:?usage: $0 <vm> <label> [samples]}"
N="${3:-6}"
GAP="${GAP:-2}"

S=/tmp/claude-1000/-home-user-qubes-win-idd-driver/596ce65c-62cf-4820-af62-c943df501f00/scratchpad
OUT="$S/idlerepaint-$LABEL"; mkdir -p "$OUT"
log(){ echo "$(date -u +%H:%M:%S) locate[$LABEL]: $*"; }
qq(){ QTEST_VM="$VM" timeout "${QT:-180}" ./tools/qtest "$@"; }
state(){ qvm-ls --fields NAME,STATE 2>/dev/null | awk -v v="$1" '$1==v{print $2}'; }

[ "$(state "$VM")" = Running ] || { log "starting $VM"; timeout 150 qvm-start "$VM" >/dev/null 2>&1; }
t0=$(date +%s)
while [ $(( $(date +%s)-t0 )) -lt 900 ]; do
    qq run 'echo UP' 2>&1 | tr -d '\r\0' | grep -q UP && break; sleep 20
done
qq run 'echo UP' 2>&1 | tr -d '\r\0' | grep -q UP || { log "ABORT: $VM not answering"; exit 1; }

# Enumerate top-level windows FIRST, so the changed box can be attributed to a real window
# rather than eyeballed. Without this the diff gives coordinates and nothing to match them to.
log "enumerating top-level windows (so the box can be attributed, not guessed)"
qq run 'powershell -NoProfile -ExecutionPolicy Bypass -Command "Add-Type -Namespace W -Name U -MemberDefinition \"[DllImport(\\\"user32.dll\\\")] public static extern int GetWindowTextW(System.IntPtr h, System.Text.StringBuilder s, int n); [DllImport(\\\"user32.dll\\\")] public static extern bool IsWindowVisible(System.IntPtr h); [DllImport(\\\"user32.dll\\\")] public static extern bool GetWindowRect(System.IntPtr h, out W.U+R r); public struct R { public int l,t,r,b; }\"; Get-Process | Where-Object {$_.MainWindowHandle -ne 0} | ForEach-Object { $r = New-Object W.U+R; [void][W.U]::GetWindowRect($_.MainWindowHandle, [ref]$r); \"WIN {0} {1} {2},{3},{4},{5}\" -f $_.ProcessName, $_.MainWindowHandle, $r.l, $r.t, $r.r, $r.b }"' 2>&1 \
    | tr -d '\r\0' | grep -a "^WIN " | tee "$OUT/windows.txt" | sed 's/^/    /'

log "capturing $N whole-desktop frames, ${GAP}s apart, with NO input"
for i in $(seq 1 "$N"); do
    qq fullshot "$OUT/f$i.tar" >/dev/null 2>&1
    mkdir -p "$OUT/x$i" && tar -xf "$OUT/f$i.tar" -C "$OUT/x$i" 2>/dev/null
    sleep "$GAP"
done

log "diffing consecutive frames"
python3 ./scratchpad/idle-repaint-diff.py "$OUT" | tee "$OUT/REPORT.txt"
log "done - $OUT"
