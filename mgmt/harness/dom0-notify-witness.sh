#!/bin/bash
# DOM0 RENDER WITNESS - did a notification actually get PAINTED on the dom0 desktop?
#
# WHY IT EXISTS. Every green result the notify-errors route has ever produced means "the guest
# handed the message to qubes.Notifications and dom0 accepted the call". That is an ACK. The owner's
# standing rule for this work is DONE = PIXELS, NOT ACKS, and by that standard the route had never
# once been shown to work: nothing in the harness had ever looked at the screen.
#
# WHY A DESKTOP CAPTURE, WHICH IS OTHERWISE FORBIDDEN. A dom0 notification bubble is an
# override-redirect window. It is absent from _NET_CLIENT_LIST, so `qtest shot` / local.WinScreenshot
# CANNOT see it - not "is inconvenient for", cannot. This is the same sanctioned exception
# a0-toast-bridge.sh and p3a-etw-gate.sh already carry (.claude/skills/guest-capture). Captures are
# written under scratchpad/ (gitignored) and are never staged; the commit and push hooks content-
# inspect archives and would refuse them anyway.
#
# THE CONTROL IS THE POINT. The dom0 desktop is NOT static - terminals repaint, clocks tick - so a
# naive before/after diff "detects a notification" every single time. This measures AMBIENT churn
# first, with no trigger, and requires the triggered delta to stand out against it. Without that
# control this witness would be a check that cannot fail, which is worse than no check.
#
# Usage:  mgmt/harness/dom0-notify-witness.sh <vm> <label> <trigger-command...>
#   <vm>      the guest whose qtest context is used for the capture service
#   <label>   short tag for the evidence files
#   trigger   the command that should cause dom0 to render a notification
# Prints WITNESS=<verdict> and exits 0 only on RENDERED.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

VM="${1:?vm}"; LABEL="${2:?label}"; shift 2
[ $# -gt 0 ] || { echo "WITNESS=no-trigger-given"; exit 2; }

# vm_lock is RE-ENTRANT (it returns immediately when QWT_VMLOCK_HELD already names this vm), so this
# is a no-op under a lock-holding caller like notify-errors-guest-test.sh and a real lock when this
# is run on its own. Either way two jobs cannot interleave on one subject.
source mgmt/harness/vmlock.sh
vm_lock "$VM"

OUT="scratchpad/notify-witness/$LABEL-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT"
say(){ echo "[$(date -u +%H:%M:%S)] witness: $*"; }

cap(){  # cap <name> -> a tar of the dom0 desktop
  QTEST_VM=$VM timeout -k 8 60 ./tools/qtest fullshot "$OUT/$1.tar" >/dev/null 2>&1  # DOM0 RENDER WITNESS: a notification bubble is override-redirect and cannot be captured per-window
  [ -s "$OUT/$1.tar" ]
}

# TOTAL changed area is the WRONG measure, and it called a REAL, photographed bubble "not
# rendered": on a live desktop the operator's own terminal repaints continuously (measured here:
# 161168 changed pixels with NO trigger at all), which swamps a bubble's ~35000 and makes any
# ratio-against-ambient test unpassable.
#
# A bubble differs by SHAPE, not amount: it is a SOLID BLOCK in one place, while terminal churn is
# scattered text over a wide area. So this reports the DENSEST bubble-sized window in the diff.
# Measured on this rig: a real notification fills ~41% of a 420x180 block; ambient churn does not.
delta(){ python3 - "$OUT/$1.tar" "$OUT/$2.tar" <<'PY'
import sys, tarfile, io, numpy as np
from PIL import Image
def biggest(p):
    with tarfile.open(p) as t:
        best=None
        for m in t.getmembers():
            if m.name.lower().endswith('.png') and (best is None or m.size>best.size): best=m
        if best is None: return None
        return Image.open(io.BytesIO(t.extractfile(best).read())).convert('RGB')
a,b=biggest(sys.argv[1]),biggest(sys.argv[2])
if a is None or b is None or a.size!=b.size:
    print("DENSE=-1 AREA=-1 AT=none"); sys.exit(0)
d=(np.abs(np.asarray(a,dtype=np.int16)-np.asarray(b,dtype=np.int16)).sum(axis=2)>30)
area=int(d.sum())
H,W=d.shape; bh,bw=180,420
best=(0,0,0)
for y in range(0,max(1,H-bh),60):
    for x in range(0,max(1,W-bw),60):
        v=int(d[y:y+bh,x:x+bw].sum())
        if v>best[0]: best=(v,x,y)
v,x,y=best
print(f"DENSE={v} FILL={v/(bw*bh):.2f} AT={x},{y} AREA={area} W={W} H={H}")
PY
}

# ---- ambient control: two captures, nothing triggered ------------------------------------------
cap amb0 || { echo "WITNESS=capture-failed(amb0)"; exit 1; }
sleep 4
cap amb1 || { echo "WITNESS=capture-failed(amb1)"; exit 1; }
AMB=$(delta amb0 amb1); AMB_AREA=$(printf '%s' "$AMB" | sed -nE 's/.*DENSE=(-?[0-9]+).*/\1/p')
say "ambient churn with no trigger: $AMB"

# ---- triggered ---------------------------------------------------------------------------------
cap pre || { echo "WITNESS=capture-failed(pre)"; exit 1; }
say "trigger: $*"
"$@" >"$OUT/trigger.out" 2>&1; trc=$?
say "trigger rc=$trc"
# THE WAIT MUST COVER THE HANDOFF. notifhost, when it is not already the console user, re-runs
# itself in the interactive session via the Task Scheduler and settles before exiting, so the bubble
# lands ~10 s after the call - not the 3 s this used to allow. Measured 2026-09-10: with a 3 s wait
# the pre->post delta was DENSE=1122 (nothing yet) and the bubble turned up in the NEXT interval.
sleep 10
cap post  || { echo "WITNESS=capture-failed(post)"; exit 1; }

# THE COMPARISON IS REGION-LOCAL, and that is the whole trick. Find the bubble-sized block that
# changed between pre and post, then ask how much THAT SAME REGION changed in the ambient pair, with
# nothing triggered. A notification lands in a screen corner that is ambiently quiet; the operator's
# terminal churns where the terminal is. Two earlier discriminators failed on real bubbles: whole
# screen density (ambient 32352 vs a real bubble 30727 on a busy desktop) and persistence (a bubble
# AUTO-DISMISSES, so its region changes again moments later - measured settled_after=30257).
read -r TRG_AREA AMB_IN_R FILL AT <<EOF
$(python3 - "$OUT/pre.tar" "$OUT/post.tar" "$OUT/amb0.tar" "$OUT/amb1.tar" <<'PY'
import sys, tarfile, io
import numpy as np
from PIL import Image
def big(p):
    with tarfile.open(p) as t:
        b=None
        for m in t.getmembers():
            if m.name.lower().endswith('.png') and (b is None or m.size>b.size): b=m
        return Image.open(io.BytesIO(t.extractfile(b).read())).convert('RGB')
try:
    a,b,e0,e1 = (np.asarray(big(x), dtype=np.int16) for x in sys.argv[1:5])
except Exception:
    print("-1 -1 0 none"); raise SystemExit
if not (a.shape == b.shape == e0.shape == e1.shape):
    print("-1 -1 0 none"); raise SystemExit
d1=(np.abs(a-b).sum(axis=2)>30)            # pre  -> post : the bubble arriving
d2=(np.abs(e0-e1).sum(axis=2)>30)          # ambient pair: what this desktop does with NO trigger
H,W=d1.shape; bh,bw=180,420; best=(0,0,0)
for y in range(0,max(1,H-bh),60):
    for x in range(0,max(1,W-bw),60):
        v=int(d1[y:y+bh,x:x+bw].sum())
        if v>best[0]: best=(v,x,y)
v,x,y=best
still=int(d2[y:y+bh,x:x+bw].sum())       # AMBIENT change in THAT SAME region
print(f"{v} {still} {v/(bw*bh):.2f} {x},{y}")
PY
)
EOF
say "triggered: densest=$TRG_AREA fill=$FILL at=$AT ; ambient in that same region=$AMB_IN_R"

# ---- verdict ------------------------------------------------------------------------------------
# Graded on DENSITY, still against the ambient control: the triggered capture must contain a
# markedly fuller bubble-sized block than the same desktop produced with no trigger at all.
: "${AMB_AREA:=-1}"; : "${TRG_AREA:=-1}"
if [ "$TRG_AREA" -lt 0 ] || [ "$AMB_AREA" -lt 0 ]; then
  echo "WITNESS=undecidable(capture-unreadable) ambient='$AMB' triggered='$TRG'"; exit 1
fi
FLOOR=15000
: "${AMB_IN_R:=-1}"
# RENDERED needs BOTH: a bubble-sized block appeared (density over the floor), AND the screen then
# went quiet where it appeared (persistence). The second term is what a busy desktop cannot fake -
# churn that big keeps changing between captures, a bubble does not. The ambient figure is still
# reported, but it no longer decides: it was measured before the trigger and on a live desktop it
# can legitimately be as large as a bubble.
# RENDERED: a bubble-sized block appeared where the desktop is ambiently QUIET. A busy region cannot
# qualify however much it changed, and a quiet corner that changed only when we triggered can.
if [ "$TRG_AREA" -ge "$FLOOR" ] && [ "$AMB_IN_R" -ge 0 ] && [ "$AMB_IN_R" -lt $(( TRG_AREA / 3 )) ]; then
  echo "WITNESS=RENDERED densest=$TRG_AREA fill=$FILL at=$AT ambient_here=$AMB_IN_R evidence=$OUT"; exit 0
fi
echo "WITNESS=NOT-RENDERED densest=$TRG_AREA fill=$FILL at=$AT ambient_here=$AMB_IN_R floor=$FLOOR evidence=$OUT"
exit 1
