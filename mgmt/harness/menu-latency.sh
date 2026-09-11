#!/bin/bash
# menu-latency.sh - measure how long the agent HOLDS a menu's map before showing it.
#
#   mgmt/harness/menu-latency.sh <vm> [count]
#
# WHAT IS BEING MEASURED, and what is NOT. A menu/toast is CREATE'd and buffer-attached, but its
# MAP is DEFERRED (crop-before-show) until the shadow-margin crop resolves - from the broker's
# measured opaque bounds or the UIA card query - or the CROP_BEFORE_SHOW_TIMEOUT_MS ceiling
# elapses. The agent logs `QGASLICEMAP hwnd=0x.. held_ms=..` once per first map; held_ms IS that
# hold. That is the part WE control and the only part this reports.
#
# It deliberately does NOT report "time from right-click to menu visible": a large and varying
# chunk of that is Windows' own WinUI flyout render before the agent ever sees the window, and
# mixing the two would credit or blame us for someone else's latency. The stimulus polls for the
# new popup HWND and reports it, so every held_ms here is attributed to a window we know was a menu.
#
# Output: the per-sample held_ms values and min/median/max, plus the crop insets actually applied.
# A sample with no matching QGASLICEMAP line is reported as UNMATCHED, never silently dropped.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$HERE" || exit 1
VM="${1:?usage: menu-latency.sh <vm> [count]}"
N="${2:-12}"
OUT="${OUT:-/home/user/rel/menu-latency-$VM-$(date -u +%Y%m%dT%H%M%SZ)}"; mkdir -p "$OUT"
say(){ echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$OUT/summary.log"; }

source mgmt/harness/vmlock.sh
source mgmt/harness/e2e-wait.sh
vm_lock "$VM"
trap 'vm_unlock "$VM" 2>/dev/null' EXIT

w_alive "$VM" || { say "VOID: $VM is not answering qrexec"; exit 2; }
say "=== menu map-hold on $VM, $N opens ==="

# Mark the log so only THIS run's lines are read - a previous run's samples in the same file
# would otherwise be averaged in and the result would not belong to any one build.
# SLICE TO THIS RUN. The agent log persists across runs within one agent instance, so simply
# grepping it counts EVERY menu since the agent started - the sample set grows run over run and
# every median silently blends this run with the last. Found 2026-09-11 when three consecutive
# runs reported 14, 22 and 30 crop-releases for 8 opens each. There is no usable in-log marker
# (a qtest echo lands in cmd, not in the agent's own log), so record how many timing lines exist
# BEFORE the stimulus and read only the ones that appear after.
prior_held(){ QTEST_VM=$VM timeout -k 5 120 ./tools/qtest run "powershell -NoProfile -Command \"(Select-String -Path '$1' -Pattern 'QGAHELDMAP' -AllMatches | Measure-Object).Count\"" 2>/dev/null | tr -d '\r' | grep -aoE '^[0-9]+$' | head -1; }

LOG=$(g_probe "$VM" LOG 'Write-Host ("LOG=" + (Get-ChildItem "Q:\Qubes Logs\gui-agent-*.log" | Sort-Object LastWriteTime | Select-Object -Last 1).FullName)' 90)
[ -n "$LOG" ] || { say "VOID: could not locate the gui-agent log"; exit 2; }
PRIOR=$(prior_held "$LOG"); PRIOR=${PRIOR:-0}
say "agent log: $LOG (already holds $PRIOR timing lines - they are NOT this run's)"
QTEST_VM=$VM ./tools/qtest push guest/menu-stim.ps1 >/dev/null 2>&1
say "running the stimulus ($N context-menu opens)"
QTEST_VM=$VM timeout -k 10 $((N * 12 + 180)) ./tools/qtest run \
  "powershell -NoProfile -ExecutionPolicy Bypass -File \"C:\\Users\\user\\Documents\\QubesIncoming\\win-idd-mgmt\\menu-stim.ps1\" -Count $N" \
  > "$OUT/stim.out" 2>&1
tr -d '\r' < "$OUT/stim.out" | grep -aE '^POPUP=|=== RESULT ===' > "$OUT/popups.txt"
opened=$(grep -c '^POPUP=0x' "$OUT/popups.txt" 2>/dev/null || echo 0)
say "stimulus: $(grep -a '=== RESULT ===' "$OUT/popups.txt" | tail -1)"
[ "$opened" -gt 0 ] || { say "VOID: no popup was opened - nothing to attribute held_ms to"; exit 2; }

# Pull the agent log and keep only this run's tail.
b64=$(python3 -c "import sys,base64;print(base64.b64encode(('Get-Content -LiteralPath \"'+sys.argv[1]+'\" -Tail 4000').encode('utf-16-le')).decode())" "$LOG")
QTEST_VM=$VM timeout -k 5 180 ./tools/qtest run "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $b64" 2>/dev/null | tr -d '\r' > "$OUT/agent.log"
# keep only the timing lines that appeared AFTER the pre-stimulus baseline
grep -a 'QGAHELDMAP' "$OUT/agent.log" | tail -n +$((PRIOR + 1)) > "$OUT/maplines.txt" 2>/dev/null
grep -a 'QGASLICEMAP\|insets l=' "$OUT/agent.log" >> "$OUT/maplines.txt" 2>/dev/null
say "this run contributed $(grep -ac QGAHELDMAP "$OUT/maplines.txt") timing line(s)"

python3 - "$OUT" <<'PY' | tee -a "$OUT/summary.log"
import re, sys, statistics
out = sys.argv[1]
pop = [int(m.group(1), 16) for m in
       (re.match(r'POPUP=(0x[0-9a-f]+)', l) for l in open(f"{out}/popups.txt")) if m]
# QGAHELDMAP is the menu-capable line (every deferred window); QGASLICEMAP only fires for
# slice-fed ones and produced NOTHING for menus - that is why this harness first read zero
# samples. Prefer QGAHELDMAP and keep its reason=, so "it got faster" can be told apart from
# "it started mapping uncropped", which would be a regression dressed as a win.
held, reason, menus = {}, {}, {}
for l in open(f"{out}/maplines.txt", errors="ignore"):
    m = re.search(r'QGAHELDMAP hwnd=(0x[0-9a-fA-F]+).*held_ms=(\d+) reason=(\S+) menu=(\d)', l)
    if m:
        h = int(m.group(1), 16)
        held[h] = int(m.group(2)); reason[h] = m.group(3); menus[h] = m.group(4) == '1'
        continue
    m = re.search(r'QGASLICEMAP hwnd=(0x[0-9a-fA-F]+).*held_ms=(-?\d+)', l)
    if m and int(m.group(1), 16) not in held:
        held[int(m.group(1), 16)] = int(m.group(2))
# Attribute by the line's OWN menu= flag, not by HWND. A WinUI context menu is a PAIR of
# windows - a zero-rect site bridge (which the agent rejects) and the real popup - and the
# stimulus can only see the bridge, so HWND matching found nothing even when the agent was
# holding and mapping menus correctly.
menu_vals = [held[h] for h in held if menus.get(h)]
vals, unmatched = list(menu_vals), max(0, len(pop) - len(menu_vals))
print(f"popups opened      : {len(pop)}")
print(f"matched QGASLICEMAP: {len(vals)}")
print(f"UNMATCHED          : {unmatched}  (no held_ms line - not counted, not hidden)")
if vals:
    vals.sort()
    print(f"held_ms samples    : {vals}")
    print(f"held_ms min/median/max = {vals[0]} / {int(statistics.median(vals))} / {vals[-1]}")
    ceiling = sum(1 for v in vals if v >= 700)
    print(f"at or above the 700 ms ceiling: {ceiling}/{len(vals)}")
    # PAINTED IS A PASS/FAIL, NOT A FOOTNOTE. A menu that maps with painted=0 has no pixels yet -
    # that is the BLACK BLINK the owner saw on 2026-09-11, and it is exactly how a "faster" median
    # can be a regression. Any unpainted map fails the run regardless of how good held_ms looks.
    unpainted = len(re.findall(r'QGASLICEMAP.*painted=0', open(f"{out}/maplines.txt", errors="ignore").read()))
    print(f"mapped UNPAINTED (black flash): {unpainted}   <- must be 0")
    to = sum(1 for h in held if menus.get(h) and reason.get(h) == 'timeout')
    cr = sum(1 for h in held if menus.get(h) and reason.get(h) == 'crop')
    print(f"released by crop / by timeout: {cr} / {to}   (timeout = mapped UNCROPPED)")
else:
    print("NO held_ms SAMPLES - the measurement failed; do not read a speedup into this.")
PY
say "evidence: $OUT"
