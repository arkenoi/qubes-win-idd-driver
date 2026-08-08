#!/bin/bash
# Self-test for sweep-analyze.py, per CLAUDE.md: "A check counts as evidence only once it has
# been seen to FAIL on a build with the defect deliberately re-introduced."
#
# Builds two SYNTHETIC sweeps and asserts the analyzer reaches opposite conclusions:
#
#   scenario FLAT     acq/tot constant, damaged area constant  -> "flat",   no INVALID
#   scenario SCALING  acq/tot ~ pixels, damaged area ~ pixels   -> "SCALES", INVALID fires
#
# If the FLAT case ever prints SCALES, or the SCALING case prints flat, the analyzer is not
# measuring what it claims and no real run may be believed.
set -u
cd /home/user/qubes-win-idd-driver
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0

gen(){ # gen <dir> <scale:0|1>
python3 - "$1" "$2" <<'PY'
import json, os, sys
root, scale = sys.argv[1], int(sys.argv[2])
MODES = [("1920x1080", 1920*1080), ("3440x1440", 3440*1440), ("7680x4320", 7680*4320)]
base = MODES[0][1]
for mode, px in MODES:
    k = (px / base) if scale else 1.0
    for rep in (1, 2, 3):
        d = os.path.join(root, f"{mode}-r{rep}")
        os.makedirs(d, exist_ok=True)
        json.dump({"mode": mode, "rep": rep, "pixels": px,
                   "cpu_ms": int(500 * k), "records": 60, "valid": True},
                  open(os.path.join(d, "point.json"), "w"))
        lines, ph = [], []
        # three phases, 10 s apart, 20 records each (n=1 per record)
        for pi, phase in enumerate(("drag", "scroll", "type")):
            h, m0 = 12, pi * 2
            start = f"20260808.{h:02d}{m0:02d}00.000"
            end   = f"20260808.{h:02d}{m0:02d}10.000"
            ph.append(f"PHASE-START {phase} {start}")
            ph.append(f"PHASE-END {phase} {end}")
            for i in range(20):
                ts = f"20260808.{h:02d}{m0:02d}{i//2:02d}.{(i%2)*500:03d}"
                acq = int(300 * k); tot = int(1000 * k); area = int(440000 * k)
                lines.append(f"[{ts}-1234-D] QGAPERF,v=1,seq={i},n=1,mode=pw,dt=8000,"
                             f"acq={acq},wak=10,mrq=5,drq=20,upd=30,enu=15,rem=5,dmg=40,"
                             f"snd=200,tot={tot},dr=1,mr=0,mrmax=0,area={area},win=6,"
                             f"iwn=0,wev=2,sends=1,skip=0,log=3")
        open(os.path.join(d, "perf.txt"), "w").write("\n".join(lines) + "\n")
        open(os.path.join(d, "phases.txt"), "w").write("\n".join(ph) + "\n")
PY
}

echo "=== scenario FLAT (cost and area independent of desktop size) ==="
gen "$T/flat" 0
out=$(./scratchpad/sweep-analyze.py "$T/flat" 2>&1) || true
echo "$out" | tail -6
echo "$out" | grep -q "Cost is FLAT in desktop area" \
    || { echo "  FAIL: flat scenario did not report flat"; fail=1; }
echo "$out" | grep -q "INVALID" \
    && { echo "  FAIL: validity gate fired on a constant-area workload"; fail=1; }

echo
echo "=== scenario SCALING (cost and area both proportional to desktop size) ==="
gen "$T/scaling" 1
out=$(./scratchpad/sweep-analyze.py "$T/scaling" 2>&1) || true
echo "$out" | tail -6
echo "$out" | grep -q "Cost DOES move with desktop area" \
    || { echo "  FAIL: scaling scenario was not detected"; fail=1; }
echo "$out" | grep -q "INVALID" \
    || { echo "  FAIL: validity gate did NOT fire although damaged area tracked desktop size"; fail=1; }

echo
if [ "$fail" -eq 0 ]; then
    echo "SELFTEST OK - the analyzer distinguishes the two cases and its validity gate fires."
else
    echo "SELFTEST FAILED - do not believe any sweep result until this passes."
fi
exit "$fail"
