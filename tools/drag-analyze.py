#!/usr/bin/env python3
"""Answer the guest-native drag questions from a QGAPROTO drag trace.

Input: any file containing the agent's QGAPROTO lines (guest/drag-trace-run.ps1 output, or a
raw gui-agent log). Reads only what the trace says; it computes nothing it cannot show.

WHAT IT DECIDES

1. WAS THE FIXED LAW APPLIED?  msg=MOTION carries br= (perf.h PTB_*). br=2/3/1 are the three
   fixed translation laws; br=0 is the LIVE origin, which is the gain-1 oscillator the fix
   exists to remove, and br=5 is the untracked-window fallback speaking a different coordinate
   space. A drag with br=0 events was not running the fix, whatever the tuning says.

2. WHAT IS dom0's REAL APPLY LAG?  This is the free parameter the whole law is fitted to, it
   was measured ONCE (2026-08-16: median 0, p75 17, tail 82/398 ms), and the shipped
   InputDragLagMs=10 / InputDragAdoptMs=25 assume it stays small. Measured here the way
   vchan-handlers.c describes: dom0 sends r = C - D, so when dom0 applies an announce, D steps
   and r steps with it. Replay the events against the announce history at each candidate lag L;
   the L that makes the reconstructed hand path C_hat = r + D(t-L) SMOOTHEST (fewest direction
   reversals) is dom0's real lag, because a human hand does not jitter at 45 Hz.

   Synthetic-drag calibration on this build (guest win10-app, 2026-09-01) says why it matters:

       dom0 lag   agent assumes   reversals   mean deviation
        17 ms        10 ms            1%          1 px
        80 ms        10 ms           22%        187 px
       200 ms        10 ms           35%        828 px

   i.e. the shipped tuning is exact while dom0 answers in ~17 ms and degrades into the
   historical wobble signature (16-19% reversals) once dom0 is slower than the assumption.

3. DID ANYTHING YANK THE WINDOW?  msg=CONFIGURE-IN with drag=1, and msg=DAEMONMOVE with
   drag=1, are the daemon dictating geometry for a window the user's hand is holding.
"""
import re
import sys
from collections import Counter

BR = {0: "LIVE(gain-1 oscillator)", 1: "FREEZE", 2: "INTERP", 3: "QUANT", 4: "SERVO",
      5: "RAWRECT(untracked)"}


def parse(path):
    ts_re = re.compile(r"\[(\d{8})\.(\d{2})(\d{2})(\d{2})\.(\d{3})")
    rows = []
    for line in open(path, encoding="utf-8", errors="replace"):
        m = re.search(r"QGAPROTO,msg=([A-Z-]+),(.*)$", line)
        if not m:
            continue
        t = ts_re.match(line.strip())
        if not t:
            continue
        ms = ((int(t.group(2)) * 3600 + int(t.group(3)) * 60 + int(t.group(4))) * 1000
              + int(t.group(5)))
        kv = {}
        for part in m.group(2).split(","):
            if "=" not in part:
                continue
            k, v = part.split("=", 1)
            v = v.strip()
            try:
                kv[k] = int(v, 16) if v.startswith("0x") else int(v)
            except ValueError:
                kv[k] = v
        rows.append((ms, m.group(1), kv))
    return rows


def reversals(seq, floor=3):
    """Direction changes in a 1-D path, ignoring steps below the noise floor."""
    n = last = 0
    for i in range(1, len(seq)):
        d = seq[i] - seq[i - 1]
        if abs(d) < floor:
            continue
        s = 1 if d > 0 else -1
        if last and s != last:
            n += 1
        last = s
    return n


def origin_at(ann, t, lag):
    """dom0's applied origin at t, modelled as a STEP: the newest announce at least lag old."""
    best = None
    for at, ax, ay in ann:
        if at <= t - lag:
            best = (ax, ay)
        else:
            break
    return best or (ann[0][1], ann[0][2]) if ann else None


def main(path):
    rows = parse(path)
    if not rows:
        print("NO QGAPROTO LINES. The trace is not armed, or this file is not a trace.\n"
              "Arm it with: guest/drag-trace-run.ps1 -Sim 0   (sets ProtoTraceDrag=1 and\n"
              "restarts the agent), then drag, then pull the log again.")
        return 2

    kinds = Counter(k for _, k, _ in rows)
    print("trace lines by message:", dict(kinds))

    latch = [(t, kv) for t, k, kv in rows if k == "DRAGLATCH"]
    print("\n-- drag latch --")
    if not latch:
        print("  NO DRAGLATCH lines: no Button1 press for a tracked window reached the agent.")
        print("  A drag that never armed the latch runs the LIVE origin for every event.")
    for t, kv in latch:
        print(f"  {t}  ev={kv.get('ev')} armed={kv.get('armed')} "
              f"origin=({kv.get('ox')},{kv.get('oy')}) grab=({kv.get('gx')},{kv.get('gy')})"
              + (f" mode={kv['mode']}" if "mode" in kv else ""))

    motion = [(t, kv) for t, k, kv in rows if k == "MOTION"]
    ann = [(t, kv["x"], kv["y"]) for t, k, kv in rows if k == "CONFIGURE" and "x" in kv]
    print("\n-- translation branch actually taken --")
    br = Counter(kv.get("br") for _, kv in motion)
    for b, n in br.most_common():
        pct = 100 * n / max(1, len(motion))
        print(f"  br={b} {BR.get(b, '?'):26s} {n:5d} events ({pct:.0f}%)")
    if br.get(0):
        print("  ^^ br=0 events ran the LIVE origin. The drag fix did NOT apply to them.")

    yank = [(t, kv) for t, k, kv in rows if k in ("CONFIGURE-IN", "DAEMONMOVE")
            and kv.get("drag") == 1]
    print("\n-- daemon geometry arriving mid-drag --")
    print(f"  CONFIGURE-IN with drag=1: {sum(1 for _,k,kv in rows if k=='CONFIGURE-IN' and kv.get('drag')==1)}")
    print(f"  DAEMONMOVE   with drag=1: {sum(1 for _,k,kv in rows if k=='DAEMONMOVE' and kv.get('drag')==1)}")
    for t, kv in yank[:10]:
        print(f"  {t}  {kv}")
    if not yank:
        print("  none - the inbound-configure hypothesis (InputDragCfgGuard) is INERT on this run.")

    if not motion or len(ann) < 3:
        print("\nToo few motion/announce events to estimate dom0's apply lag.")
        return 0

    print("\n-- announce cadence (the loop's feedback rate) --")
    gaps = sorted(ann[i + 1][0] - ann[i][0] for i in range(len(ann) - 1))
    span = (ann[-1][0] - ann[0][0]) / 1000.0
    print(f"  {len(ann)} announces over {span:.2f}s = {len(ann)/max(span,1e-9):.1f}/s, "
          f"gap p50={gaps[len(gaps)//2]}ms p90={gaps[int(len(gaps)*0.9)]}ms max={gaps[-1]}ms")
    print("  reference: 13.7/s at the 2026-08-16 approved baseline (25/50 rung)")

    print("\n-- dom0's REAL apply lag, fitted --")
    print("  L(ms)  reversals in the reconstructed hand path (lower = better fit)")
    best = None
    for lag in range(0, 401, 10):
        c = []
        for t, kv in motion:
            o = origin_at(ann, t, lag)
            if o:
                c.append(kv["rx"] + o[0])
        r = reversals(c)
        if best is None or r < best[1]:
            best = (lag, r)
        if lag % 20 == 0:
            print(f"   {lag:4d}   {r}")
    print(f"\n  BEST FIT: dom0 apply lag ~= {best[0]} ms (hand-path reversals {best[1]})")
    print(f"  agent assumes InputDragLagMs=10 / InputDragAdoptMs=25.")
    if best[0] > 40:
        print("  >>> MISMATCH. Per the synthetic calibration above, a dom0 lag this far past the")
        print("      assumption is enough on its own to restore the full wobble with no code")
        print("      regression anywhere.")

    winx = [kv["wx"] for _, kv in motion if "wx" in kv]
    if winx:
        print(f"\n-- what the user saw: window path --")
        print(f"  {len(winx)} samples, direction reversals: {reversals(winx)} "
              f"({100*reversals(winx)/max(1,len(winx)):.0f}% of events)")
        print("  reference: 16-19% of announces reversing = the wobble as originally measured")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "-"))
