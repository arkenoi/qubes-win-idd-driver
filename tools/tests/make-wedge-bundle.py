#!/usr/bin/env python3
"""make-wedge-bundle.py <shape> <outdir-or-tar> - emit a forensics bundle in dom0's REAL format.

WHY THIS EXISTS. The wedge path cannot be exercised by waiting for a wedge: the owner, 2026-10-22 -
"the wedge path wont happen without wedge and it could be weeks before we see one, so we should try
offline assurance meanwhile". And the one real capture available is from a HEALTHY guest, which can
only produce the ACTIVE shape; the HLT and stuck-vector branches - the ones that label a real wedge
- had no real-format coverage at all, which is why a review put that parse at 0.24 verified.

A real capture cannot be committed (public repo: captures live in scratchpad/ or evidence/ and are
never tracked), so this GENERATES one instead. Every line shape below was read off an actual
931,840-byte bundle taken from live win11de-uc on 2026-10-22, domain 17891, four vCPUs:

  (XEN) >>> Domain 17891 <<<
  (XEN) \tVCPU 0                       <- TAB-indented; the decoder strips "(XEN)" then matches
  (XEN) *** Guest State ***
  (XEN) RSP = 0x... (0x...)  RIP = 0xfffff80276aa5aae (0xfffff80276aa5aaf)
  (XEN) RFLAGS=0x00040282 (0x00040282)  DR7 = 0x0000000000000400
  (XEN) Interruptibility = 00000000  ActivityState = 00000000
  (XEN) InterruptStatus = 0000
  (XEN)         reason=0000000c qualification=0000000000000000

and vcpu-list, whose State column is where a halted vCPU actually shows:

  Name                                ID  VCPU   CPU State   Time(s) Affinity (Hard / Soft)
  win11de-uc                       17891     0    9   -b-     934.4  all / all

The RIP 0xfffff80276aa5aae is the real idle-loop address that guest's vCPUs were parked on.

SHAPES, and each is a shape the project has RECORDED rather than one invented here:
  spin     one vCPU Active on an unchanged RIP taking PAUSE-loop exits (40) in both samples, with
           RVI=0xE1 - the Windows IPI vector - latched on it and never taken. findings/wedge.md's
           recorded spin specimens, and the bundle that showed RVI=0xE1 while other vCPUs spun in
           nt!KiIpiSendRequestEx.
  hlt      every vCPU halted: exit reason 12, runstate -b-, no cpu-time movement. The recorded
           BLOCKED shape (a vCPU held in Xen after a grant/memory hypercall, nothing spinning).
  healthy/healthy2  the two samples the live guest actually gave: in the first a vector is
           latched on vcpu2, in the second it has been taken. What the live guest actually gave: all Active, idle RIP, one transient RVI taken between
           samples. The NEGATIVE control - it must not read as any wedge shape.
  garbage  a bundle whose VMX block is unparseable, to prove the chain declines to answer.

Used by tools/tests/wedge-gates-selftest.sh. It writes a tar when the target ends in .tar.
"""
import os
import subprocess
import sys
import tempfile

DOMID = 17891
IDLE_RIP = "0xfffff80276aa5aae"
SPIN_RIP = "0xfffff802741c8b60"
VM = "win11de-uc"

# Intel SDM exit reasons, only the ones these shapes use.
HLT, EPT_VIOLATION, PAUSE_LOOP = 0x0C, 0x30, 0x28


def vcpu_block(n, rip, activity, istatus, reason):
    """One vCPU's VMX dump, in the line shapes the real capture carries."""
    return "\n".join([
        "(XEN) \tVCPU %d" % n,
        "(XEN) *** Guest State ***",
        "(XEN) CR0: actual=0x0000000080050031, shadow=0x0000000080050031, gh_mask=ffffffffffffffff",
        "(XEN) CR3 = 0x00000000001aa000",
        "(XEN) RSP = 0xfffff8020c07b9a8 (0xfffff8020c07b9a8)  RIP = %s (%s)" % (rip, rip),
        "(XEN) RFLAGS=0x00040282 (0x00040282)  DR7 = 0x0000000000000400",
        "(XEN) Sysenter RSP=0000000000000000 CS:RIP=0000:0000000000000000",
        "(XEN) Interruptibility = 00000000  ActivityState = %08x" % activity,
        "(XEN) InterruptStatus = %04x" % istatus,
        "(XEN) *** Host State ***",
        "(XEN) RIP = 0xffff82d0402a9f90 (vmx_asm_vmexit_handler)  RSP = 0xffff83177b63ff70",
        "(XEN) EntryControls=0000d3ff ExitControls=002fefff",
        "(XEN) VMExit: intr_info=00000000 errcode=00000000 ilen=00000001",
        "(XEN)         reason=%08x qualification=0000000000000000" % reason,
    ])


def shape(name):
    """-> (list of (rip, activity, istatus, reason) per vCPU, list of (state, t1, t2))"""
    if name == "spin":
        # vcpu0 spins with the IPI vector latched and never taken; the rest idle.
        v = [(SPIN_RIP, 0, 0x00E1, PAUSE_LOOP)] + [(IDLE_RIP, 0, 0, HLT)] * 3
        t = [("r--", 100.0, 110.0)] + [("-b-", 50.0, 50.0)] * 3
    elif name == "hlt":
        # every vCPU halted, in the VMX activity state AND by exit reason and runstate.
        v = [(IDLE_RIP, 1, 0, HLT)] * 4
        t = [("-b-", 50.0, 50.0)] * 4
    elif name == "healthy":
        # exactly what the live capture gave, including the transient RVI on vcpu2.
        v = [(IDLE_RIP, 0, 0, HLT), (IDLE_RIP, 0, 0, HLT),
             ("0xfffff802767d6db8", 0, 0x00D1, EPT_VIOLATION), (IDLE_RIP, 0, 0, HLT)]
        t = [("-b-", 934.4, 937.7), ("-b-", 1090.0, 1094.8),
             ("---", 787.5, 789.1), ("r--", 812.0, 813.7)]
    elif name == "healthy2":
        # The SECOND sample of the healthy capture: vcpu2's latched vector has been TAKEN, and the
        # cpu times have moved. This is the negative control that matters - feeding the same sample
        # twice would make a transient vector look stuck, which is the exact distinction being
        # tested. On the real guest, 0xd1 was present in sample 1 and gone in sample 2.
        v = [(IDLE_RIP, 0, 0, HLT), (IDLE_RIP, 0, 0, HLT),
             ("0xfffff802767d6db8", 0, 0, EPT_VIOLATION), (IDLE_RIP, 0, 0, HLT)]
        t = [("-b-", 937.7, 941.0), ("-b-", 1094.8, 1099.1),
             ("-b-", 789.1, 790.3), ("-b-", 813.7, 815.0)]
    elif name == "garbage":
        return None, None
    else:
        sys.stderr.write("unknown shape %r\n" % name)
        return False, False
    return v, t


def write_bundle(name, d, second=False):
    vcpus, times = shape(name)
    if vcpus is False:
        return 2
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "domid.txt"), "w") as fh:
        fh.write("domid=%d\n" % DOMID)
    if vcpus is None:                       # garbage: present but unparseable
        with open(os.path.join(d, "xl-dmesg-vmx.txt"), "w") as fh:
            fh.write("(XEN) the hypervisor ring wrapped before xl dmesg ran\n")
        for n in (1, 2):
            with open(os.path.join(d, "vcpu-list-%d.txt" % n), "w") as fh:
                fh.write("Name                                ID  VCPU   CPU State   Time(s)\n")
        return 0
    # A foreign domain FIRST, because the real dump carries every HVM domain on the host and the
    # decoder has to pick this one out - a bundle with only our domain in it would not test that.
    out = ["(XEN) >>> Domain 44 <<<", vcpu_block(0, "0xffffffffbc701cae", 0, 0, HLT),
           "(XEN) >>> Domain %d <<<" % DOMID]
    for n, (rip, act, ist, reason) in enumerate(vcpus):
        out.append(vcpu_block(n, rip, act, ist, reason))
    out.append("(XEN) >>> Domain 90 <<<")
    out.append(vcpu_block(0, "0xffffffff81701cae", 0, 0, HLT))
    with open(os.path.join(d, "xl-dmesg-vmx.txt"), "w") as fh:
        fh.write("\n".join(out) + "\n")
    for n in (1, 2):
        rows = ["Name                                ID  VCPU   CPU State   Time(s) Affinity (Hard / Soft)"]
        for i, (st, t1, t2) in enumerate(times):
            rows.append("%-32s %6d %5d %4d   %-5s %7.1f  all / all"
                        % (VM, DOMID, i, 9 + i, st, t2 if n == 2 else t1))
        with open(os.path.join(d, "vcpu-list-%d.txt" % n), "w") as fh:
            fh.write("\n".join(rows) + "\n")
    return 0


def main():
    if len(sys.argv) < 3:
        sys.stderr.write(__doc__.splitlines()[0] + "\n")
        return 2
    name, target = sys.argv[1], sys.argv[2]
    if target.endswith(".tar"):
        tmp = tempfile.mkdtemp(prefix="mkwedge-")
        rc = write_bundle(name, tmp)
        if rc:
            return rc
        # A PLAIN tar, because that is what dom0's service emits - the thing the decoder got wrong.
        return subprocess.run(["tar", "cf", target, "-C", tmp, "."]).returncode
    return write_bundle(name, target)


if __name__ == "__main__":
    sys.exit(main())
