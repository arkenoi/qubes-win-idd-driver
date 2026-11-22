#!/usr/bin/env python3
"""wedge-vmcs-fields.py SAMPLE1 [SAMPLE2] - reduce wedge-vmcs.py's table to decidable fields.

WHY THIS EXISTS. mgmt/harness/wedge-gates-lib.sh needs three facts out of a VMCS dump: is any
vCPU Active, is every vCPU halted, and did a RIP stand still between two samples. It derived them
with awk and grep over wedge-vmcs.py's human table, and BOTH derivations were wrong:

  * activity was read from column $8. The table's columns are
        vcpu  RIP  IF  RVI  SVI  intibility  activity  last exit...  cpu-time delta
    so $7 is activity and $8 is the exit reason's NUMBER. Exit reasons print as bare decimals,
    so a vCPU whose last exit was reason 0 or 1 read as ActivityState 0x00/0x01 - "Active" or
    "HLT" - from a field that is neither.
  * "RIP static" compared the FIRST hex token in the file against the LAST, across both samples
    AND every vCPU. On a 4-vCPU guest that compares vcpu0's RIP in sample 1 with vcpu3's in
    sample 2, which answers nothing. A spin is the SAME vCPU on the SAME address twice.

Neither could have been caught offline, because neither had ever been run against real output -
a review put that parse at 0.78 as the biggest defect in the library. So the parse now lives in
one testable place with a fixture of the real table, instead of inline in a shell function.

IT READS FIELDS, NEVER THE TOOL'S CONCLUSION. wedge-vmcs.py also prints a "SHAPE:" line of its
own. That line is an instrument's verdict, and a verdict is not a measurement: this reads the
hardware fields and lets the classifier in wedge-gates-lib.sh decide. ActivityState is the VMCS
enum (0 Active, 1 HLT, 2 Shutdown, 3 Wait-for-SIPI); InterruptStatus carries RVI in the low byte,
a vector LATCHED for delivery, which is the direct evidence of an IPI that was never taken.

Output is one key=value per line, and an UNPARSEABLE input yields empty values rather than a
guess:
  vcpus=N              how many vCPU rows were read from sample 1 (0 = nothing parsed)
  activity=ACTIVE|HLT  ACTIVE: some vCPU is Active in BOTH samples. HLT: EVERY vCPU is halted in
                       both. Empty when mixed, when a sample is missing, or when unparseable.
  rip-static=0|1       1 only when the same vCPU shows the same RIP in both samples.
  rip-static-vcpu=N    which vCPU that was.
  rvi-pending=0xNN     the highest RVI latched on any vCPU in the last sample (absent if none).
  rvi-stuck=0xNN       a vector latched on the SAME vCPU in BOTH samples - i.e. one that is not
                       being taken. This is the discriminating form, and the distinction is
                       measured, not assumed: a live HEALTHY guest (win11de-uc, 2026-10-22) showed
                       RVI=0xd1 on vcpu2 in sample 1 and nothing in sample 2 - an interrupt in
                       flight, taken between samples, which is what normal delivery looks like. The
                       recorded wedge signature is the opposite: RVI=0xE1, the Windows IPI vector,
                       latched on a vCPU that never took it while others spun in
                       nt!KiIpiSendRequestEx. One sample cannot tell those apart; two can.
  rvi-stuck-vcpu=N     which vCPU that was.
  qemu-held-vcpu=N     THE QEMU WEDGE, and the only field that makes a cell a wedge. Set only when
                       ONE vCPU, in BOTH samples: has pause_flags bit 4 (VPF_blocked_in_xen), took
                       exit 18 (VMCALL) at the same RIP, that RIP sits at the VMCALL of the
                       memory_op or grant_table_op stub of the hypercall page (page offset 0x185 or
                       0x285: stub = op*32, VMCALL at +5), and its cpu-time delta is 0.0. Those are
                       the two hypercalls after which Xen sends the device model a synchronous
                       map-cache invalidate; a stub-domain QEMU that never completes it holds that
                       vCPU forever (QEMU work item 2043, fixed by QEMU 095c08a7; Qubes issue 10069,
                       whose own gdbsx dump has VCPU0 at the same stub, xen.sys+0x13288). Any
                       missing part leaves it EMPTY - a missing field is not a wedge.
  qemu-held-hypercall  memory_op or grant_table_op, for the vCPU above.
"""
import re
import sys

ACTIVITY = {0: "Active", 1: "HLT", 2: "Shutdown", 3: "Wait-for-SIPI"}
# Page offset of the VMCALL inside the hypercall page for the two ops that trigger the map-cache
# invalidate (names as tools/xen-core-rip.py HYPERCALL: 12 memory_op, 20 grant_table_op).
INVALIDATE_VMCALL = {12 * 32 + 5: "memory_op", 20 * 32 + 5: "grant_table_op"}


def parse(path):
    """-> {vcpu_number: {"activity": int|None, "rip": str|None, "rvi": int|None}}"""
    out = {}
    try:
        with open(path, "r", errors="replace") as fh:
            lines = fh.readlines()
    except OSError:
        return out
    for line in lines:
        # The header carries the literal word, so skip it rather than relying on column count.
        if "activity" in line and "last exit" in line:
            continue
        f = line.split()
        # vcpu RIP IF RVI SVI intibility activity ... - seven fields before the exit reason.
        if len(f) < 7 or not f[0].isdigit():
            continue
        n = int(f[0])
        rip = f[1] if f[1].startswith("0x") else None

        def hexfield(s):
            return int(s, 16) if re.fullmatch(r"0x[0-9a-fA-F]+", s or "") else None

        # The tail is VARIABLE WIDTH - "12 (HLT)" is two tokens, "40 (PAUSE-loop exit)" is three -
        # so the exit reason and the runstate come from a regex over the rest of the line, never
        # from a fixed column index. (A fixed index over this tail is how the first version of this
        # derivation read the exit reason as ActivityState.)
        tail = line.split(None, 7)[7] if len(f) > 7 else ""
        m = re.match(r"\s*(\d+)\s*\(", tail)
        reason = int(m.group(1)) if m else None
        # "+3.3 s (-b-->-b-)" - the runstate BEFORE and AFTER the cpu-time samples. Xen's single
        # letters: r running, b blocked, - offline/other.
        m = re.search(r"\(([^()]*?)->([^()]*?)\)\s*$", tail)
        rs_after = m.group(2).strip() if m else None
        m = re.search(r"([+-]?\d+(?:\.\d+)?)\s*s\s*\([^()]*\)\s*$", tail)
        cpu = float(m.group(1)) if m else None
        out[n] = {"rip": rip, "rvi": hexfield(f[3]), "activity": hexfield(f[6]),
                  "reason": reason, "rs_after": rs_after, "cpu": cpu}
    return out


def parse_pause_flags(path):
    """-> {vcpu: flags} from wedge-vmcs.py's "PAUSE-FLAGS: vcpu0=4 vcpu1=1" line, {} if absent.

    A FIELD, not the tool's HELD-IN-XEN conclusion - same division as everything else here. Xen's
    VPF_* bits: 1 = VPF_blocked (idle HLT), 4 = VPF_blocked_in_xen (held inside Xen until the
    stub-domain device model completes an I/O request). `xl vcpu-list` cannot render the second
    one and shows it as `---`, which reads as "runnable"; it is not.
    """
    try:
        with open(path, "r", errors="replace") as fh:
            txt = fh.read()
    except OSError:
        return {}
    m = re.search(r"^PAUSE-FLAGS:\s*(vcpu\d+=\d+(?:\s+vcpu\d+=\d+)*)\s*$", txt, re.M)
    if not m:
        return {}
    return {int(a): int(b) for a, b in re.findall(r"vcpu(\d+)=(\d+)", m.group(1))}


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    if not args:
        sys.stderr.write(__doc__.splitlines()[0] + "\n")
        return 2
    s1 = parse(args[0])
    s2 = parse(args[1]) if len(args) > 1 else {}

    activity = ""
    if s1 and s2:
        both = [n for n in s1 if n in s2]
        if both:
            act = lambda s, n: s[n]["activity"]
            if any(act(s1, n) == 0 and act(s2, n) == 0 for n in both):
                activity = "ACTIVE"
            elif all(
                act(s1, n) is not None and act(s2, n) is not None
                and act(s1, n) in (1, 2, 3) and act(s2, n) in (1, 2, 3)
                for n in both
            ):
                activity = "HLT"

    static, static_vcpu = 0, ""
    for n in sorted(set(s1) & set(s2)):
        r1, r2 = s1[n]["rip"], s2[n]["rip"]
        if r1 and r2 and r1 == r2:
            static, static_vcpu = 1, n
            break

    last = s2 or s1
    rvis = [v["rvi"] for v in last.values() if v["rvi"]]

    # A vector latched on the SAME vCPU in BOTH samples is one that is NOT being taken.
    stuck, stuck_vcpu = None, ""
    for n in sorted(set(s1) & set(s2)):
        a, b = s1[n]["rvi"], s2[n]["rvi"]
        if a and b and a == b:
            stuck, stuck_vcpu = a, n
            break

    print("vcpus=%d" % len(s1))
    print("activity=%s" % activity)
    print("rip-static=%d" % static)
    print("rip-static-vcpu=%s" % static_vcpu)
    print("rvi-pending=%s" % ("0x%02x" % max(rvis) if rvis else ""))
    print("rvi-stuck=%s" % ("0x%02x" % stuck if stuck else ""))
    print("rvi-stuck-vcpu=%s" % stuck_vcpu)

    # THE EVIDENCE REAL BUNDLES ACTUALLY CARRY. ActivityState=HLT was NOT observed on a live guest
    # whose vCPUs were halted (win11de-uc, 2026-10-22): all four read 0x00 while three had taken
    # exit 12 (HLT) and sat in runstate "-b-" (blocked). Xen deschedules a halted vCPU rather than
    # parking it in the VMX HLT activity state, so an activity-only reading of "every vCPU halted"
    # is close to dead code on this hardware. These two fields are what a halted guest does show.
    # They are reported as FIELDS; the classifier decides what shape they mean.
    both = sorted(set(s1) & set(s2))
    all_hlt = 1 if both and all(
        s1[n]["reason"] == 12 and s2[n]["reason"] == 12 for n in both) else 0
    all_blocked = 1 if both and all(
        (s1[n]["rs_after"] or "").startswith("-b") and (s2[n]["rs_after"] or "").startswith("-b")
        for n in both) else 0
    pause = ""
    for n in both:
        if s1[n]["reason"] == 40 and s2[n]["reason"] == 40:
            pause = n
            break
    # pause_flags, from the LAST sample that carried it. Reported as a field; the classifier in
    # wedge-gates-lib.sh decides what shape it means. Empty means the `q` block was not in the
    # bundle - ABSENT, never 0.
    pf = parse_pause_flags(args[1]) if len(args) > 1 else {}
    if not pf:
        pf = parse_pause_flags(args[0])
    held = ""
    for n_ in sorted(pf):
        if pf[n_] & 4:
            held = n_
            break
    pf1 = parse_pause_flags(args[0])
    pf2 = parse_pause_flags(args[1]) if len(args) > 1 else {}
    qheld, qcall = "", ""
    for n in both:
        a, b = s1[n], s2[n]
        if not (pf1.get(n, 0) & 4 and pf2.get(n, 0) & 4):
            continue
        if not (a["reason"] == 18 and b["reason"] == 18 and a["rip"] and a["rip"] == b["rip"]):
            continue
        if not (a["cpu"] == 0.0 and b["cpu"] == 0.0):
            continue
        op = INVALIDATE_VMCALL.get(int(a["rip"], 16) & 0xFFF)
        if op:
            qheld, qcall = n, op
            break
    print("pause-flags=%s" % " ".join("%d:%d" % (k, pf[k]) for k in sorted(pf)))
    print("held-in-xen-vcpu=%s" % held)
    print("qemu-held-vcpu=%s" % qheld)
    print("qemu-held-hypercall=%s" % qcall)
    print("exit-all-hlt=%d" % all_hlt)
    print("runstate-all-blocked=%d" % all_blocked)
    print("exit-pause-loop-vcpu=%s" % pause)
    return 0


if __name__ == "__main__":
    sys.exit(main())
