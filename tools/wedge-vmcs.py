#!/usr/bin/env python3
"""wedge-vmcs.py - read the Xen-side half of a wedge capture, which is the half that gets skipped.

    tools/wedge-vmcs.py BUNDLE_DIR_OR_TARBALL [--domid N]

WHY THIS EXISTS. findings/wedge.md called "WHY the IPI never lands" the one OPEN evidentiary link,
and said it was "invisible from any guest dump by construction; needs Xen-side instrumentation at
repro time". The instrumentation already existed and had already run: dom0/11-wedge-forensics.sh
runs `xl debug-keys v`, whose VMCS dump carries the guest's InterruptStatus - the VMCS
guest-interrupt-status field, RVI in the low byte, SVI in the high byte. RVI is exactly "an
interrupt is latched for delivery to this vCPU". On 2026-09-25 four such bundles were found sitting
unread in ~/QubesIncoming/dom0, one of them showing RVI=0xE1 - the Windows IPI vector - pending on
a vCPU while three others spun in nt!KiIpiSendRequestEx waiting for it to acknowledge.

A 1826-line hypervisor log with the answer in it is not evidence anybody uses. This prints the
decoded per-vCPU state for the wedged domain only, and names the SHAPE, so the next capture is read
in one command instead of being archived.

SHAPES it distinguishes:
  SPIN         - vCPUs burning CPU, PAUSE-loop exits, and/or a pending RVI that is not being taken
  HELD-IN-XEN  - a vCPU with pause_flags=4 (VPF_blocked_in_xen) and nothing spinning: held until
                 the stub-domain device model completes an I/O request. This is the mechanism
                 class recorded 2026-10-04, and until 2026-10-28 this tool printed MIXED for it
                 because it never read pause_flags - a field every bundle already carried.
  IDLE         - every vCPU halted (exit reason 12) with nothing pending: a lost-wakeup shape
  MIXED        - none of the above, which is a finding in itself and must not be rounded

It reads only files the capture already contains and invents nothing; a field the capture does not
hold is printed as absent, never guessed.
"""
import argparse, os, re, subprocess, sys, tempfile

# Intel SDM appendix C, only the exit reasons this instrument actually reasons about.
EXIT_REASON = {0: "exception/NMI", 1: "external interrupt", 7: "interrupt window",
               10: "CPUID", 12: "HLT", 28: "control-register access", 30: "I/O instruction",
               18: "VMCALL", 31: "RDMSR", 32: "WRMSR", 40: "PAUSE-loop exiting", 48: "EPT violation",
               49: "EPT misconfiguration", 55: "XSETBV"}


def die(msg):
    print("INSTRUMENT: " + msg, file=sys.stderr)
    sys.exit(2)


def as_dir(path):
    if os.path.isdir(path):
        return path, None
    tmp = tempfile.mkdtemp(prefix="wedge-vmcs-")
    # `xzf` DEMANDS gzip, and dom0's local.WinWedgeForensics emits a PLAIN tar - so this decoder
    # could never read a bundle from the service it exists to decode. Measured 2026-10-22 against a
    # 931 KB capture from a live guest: "gzip: stdin: not in gzip format", no output, and the
    # classifier above it recorded an absent VMCS. That is very likely why four bundles sat unread
    # and nine wedges were recorded with g/e/q only. `xf` auto-detects compression, so it reads both.
    if subprocess.run(["tar", "xf", path, "-C", tmp]).returncode != 0:
        die("cannot extract %s" % path)
    entries = [os.path.join(tmp, e) for e in os.listdir(tmp)]
    inner = [e for e in entries if os.path.isdir(e)]
    return (inner[0] if len(inner) == 1 else tmp), tmp


def read(d, name):
    p = os.path.join(d, name)
    return open(p, encoding="utf-8", errors="replace").read() if os.path.exists(p) else None


def domain_block(vmx, domid):
    """The `>>> Domain N <<<` section for one domain, or None if the dmesg ring lost it."""
    out, keep = [], False
    for line in vmx.splitlines():
        m = re.search(r">>> Domain (\d+) <<<", line)
        if m:
            keep = (int(m.group(1)) == domid)
            continue
        if keep:
            out.append(line)
    return "\n".join(out) if out else None


def pause_flags(d, domid):
    """Per-vCPU pause_flags for one domain, from `xl debug-keys q`, or {} if absent.

    THE FIELD THAT NAMES THE MECHANISM, and until 2026-10-28 nothing read it. Xen's VPF_* flags:
    1 = VPF_blocked (an ordinary idle HLT), 4 = VPF_blocked_in_xen (the vCPU is held INSIDE Xen
    until the stub-domain device model completes an I/O request). `xl vcpu-list` renders a vCPU
    with pause_flags=4 as `---`, because its flag column covers only running / VPF_blocked /
    paused - so the list makes the recorded wedge shape look like "runnable and never scheduled",
    which is how the 2026-10-28 win10-acc specimen was misread for several rounds with the
    answer sitting unread in its own bundle. `q` is collected by dom0/11-wedge-forensics.sh on
    every capture.

    The dump may be truncated (`xl dmesg | tail -200`), so a partial block yields partial data
    rather than nothing, and an absent block yields {}.
    """
    txt = read(d, "xl-dmesg-domains.txt")
    if not txt:
        return {}
    out, keep, cur = {}, False, None
    want_vcpus = False
    for line in txt.splitlines():
        line = line.replace("(XEN)", "").strip()
        # ANY line naming a domain id switches context. Not an enumerated list of header
        # spellings: `dump_domains` prints several ("General information for domain N",
        # "Rangesets belonging to domain N", "NODE affinity for domain N", ...) and an
        # unlisted one would let the NEXT domain's vCPUs be read as this domain's. Verified
        # against the real dump: no line INSIDE a vCPU block names a domain, so this cannot
        # terminate a block early.
        m = re.search(r"\bdomain (\d+)", line)
        if m:
            keep = (int(m.group(1)) == domid)
            want_vcpus = keep and line.startswith("VCPU information")
            cur = None
            continue
        # Only the "VCPU information and callbacks" section carries pause_flags. A truncated
        # dump (`xl dmesg | tail -200`) may cut that header off while leaving VCPU lines
        # behind; those are then attributed to no domain and dropped, which is the safe way
        # to be wrong.
        if not (keep and want_vcpus):
            continue
        m = re.match(r"VCPU(\d+):", line)
        if m:
            cur = int(m.group(1))
            continue
        m = re.search(r"pause_flags=(\d+)", line)
        if m and cur is not None:
            out[cur] = int(m.group(1))
            cur = None
    return out


def parse_vcpus(block):
    vcpus, cur = [], None
    for line in block.splitlines():
        line = line.replace("(XEN)", "").strip()
        m = re.match(r"VCPU (\d+)", line)
        if m:
            cur = {"n": int(m.group(1))}
            vcpus.append(cur)
            continue
        if cur is None:
            continue
        m = re.search(r"RIP = (0x[0-9a-f]+)", line)
        if m and "rip" not in cur and "vmx_asm" not in line:
            cur["rip"] = m.group(1)
        m = re.search(r"RFLAGS=(0x[0-9a-f]+)", line)
        if m:
            cur["rflags"] = int(m.group(1), 16)
        m = re.search(r"Interruptibility = ([0-9a-f]+)\s+ActivityState = ([0-9a-f]+)", line)
        if m:
            cur["intibility"] = int(m.group(1), 16)
            cur["activity"] = int(m.group(2), 16)
        m = re.search(r"InterruptStatus = ([0-9a-f]+)", line)
        if m:
            cur["istatus"] = int(m.group(1), 16)
        m = re.search(r"reason=([0-9a-f]+)", line)
        if m and "reason" not in cur:
            cur["reason"] = int(m.group(1), 16)
    return vcpus


def cputime(d):
    """Per-vCPU (state, seconds) from the two vcpu-list snapshots, as a delta."""
    out = {}
    for n in (1, 2):
        txt = read(d, "vcpu-list-%d.txt" % n)
        if not txt:
            return None
        for line in txt.splitlines()[1:]:
            f = line.split()
            if len(f) >= 6:
                out.setdefault(int(f[2]), []).append((f[4], float(f[5])))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("bundle")
    ap.add_argument("--domid", type=int)
    a = ap.parse_args()

    d, _tmp = as_dir(a.bundle)
    domid = a.domid
    if domid is None:
        txt = read(d, "domid.txt") or ""
        m = re.search(r"(\d+)", txt)
        if not m:
            die("no domid.txt in the bundle and --domid not given")
        domid = int(m.group(1))

    vmx = read(d, "xl-dmesg-vmx.txt")
    if vmx is None:
        die("bundle has no xl-dmesg-vmx.txt - the capture did not run `xl debug-keys v`")
    block = domain_block(vmx, domid)
    print("bundle %s" % os.path.basename(d.rstrip("/")))
    print("domain %d" % domid)
    if block is None:
        print("\nVMCS: ABSENT for this domain - the hypervisor dmesg ring wrapped before `xl dmesg`")
        print("      ran. This is a CAPTURE DEFECT, not a property of the wedge. Nothing about")
        print("      interrupt delivery can be concluded from this bundle.")
        sys.exit(1)

    vcpus = parse_vcpus(block)
    times = cputime(d)
    print("\n vcpu  RIP                 IF  RVI   SVI  intibility activity  last exit                 cpu-time delta")
    spin = idle = 0
    for v in vcpus:
        ist = v.get("istatus")
        rvi = ist & 0xFF if ist is not None else None
        svi = (ist >> 8) & 0xFF if ist is not None else None
        reason = v.get("reason")
        t = times.get(v["n"]) if times else None
        delta = "%+.1f s (%s->%s)" % (t[1][1] - t[0][1], t[0][0], t[1][0]) if t and len(t) == 2 else "absent"
        print(" %4d  %-18s  %d  0x%02x  0x%02x  %8s  %8s  %-24s  %s" % (
            v["n"], v.get("rip", "absent"), (v.get("rflags", 0) >> 9) & 1,
            rvi if rvi is not None else 0, svi if svi is not None else 0,
            "0x%02x" % v["intibility"] if "intibility" in v else "absent",
            "0x%02x" % v["activity"] if "activity" in v else "absent",
            "%d (%s)" % (reason, EXIT_REASON.get(reason, "?")) if reason is not None else "absent",
            delta))
        if reason == 12:
            idle += 1
        if reason == 40 or (t and len(t) == 2 and t[1][1] - t[0][1] > 5.0):
            spin += 1

    # PAUSE-FLAGS, printed as a FIELD on its own line. Deliberately NOT a new column: the table's
    # columns are parsed by position in tools/wedge-vmcs-fields.py, and widening it would shift
    # every consumer anchored on them.
    pf = pause_flags(d, domid)
    if pf:
        print("\nPAUSE-FLAGS: " + " ".join("vcpu%d=%d" % (n, pf[n]) for n in sorted(pf)))
        held = [n for n in sorted(pf) if pf[n] & 4]
        if held:
            print("  vcpu%s has VPF_blocked_in_xen (pause_flags & 4): held INSIDE Xen until the"
                  % ",".join(str(n) for n in held))
            print("  stub-domain device model completes an I/O request. `xl vcpu-list` shows this")
            print("  as `---`, which is NOT 'runnable' - its flag column cannot render this state.")
    else:
        print("\nPAUSE-FLAGS: ABSENT - no `xl debug-keys q` block for this domain in the bundle")
        print("  (xl-dmesg-domains.txt missing, or the dmesg ring wrapped past it). Absent, not 0.")

    print()
    pending = [v for v in vcpus if v.get("istatus", 0) & 0xFF]
    held_vcpus = [n for n in sorted(pf) if pf[n] & 4]
    if held_vcpus and not spin:
        # The criterion wedge-gates-lib.sh already names: "a vCPU held in Xen right after a grant
        # or memory hypercall (pause_flags=4) WITH NO SECOND CPU SPINNING ON IT". With a spin
        # present this is the 2026-10-26 shape instead, so the spin keeps the label and the held
        # vCPU is reported above as the additional fact it is.
        print("SHAPE: HELD-IN-XEN - vcpu%s blocked in Xen awaiting the device model, nothing"
              % ",".join(str(n) for n in held_vcpus))
        print("       spinning. The recorded BLOCKED shape (findings/wedge.md, 2026-10-04).")
    elif idle == len(vcpus) and not pending:
        print("SHAPE: IDLE - every vCPU halted with nothing pending anywhere. A lost-wakeup shape,")
        print("       NOT the PacketBarrier spin. Do not merge the two.")
    elif spin:
        print("SHAPE: SPIN - %d vCPU(s) burning CPU or taking PAUSE-loop exits." % spin)
    else:
        print("SHAPE: MIXED - neither clean shape. Record it as mixed; do not round it to either.")

    for v in pending:
        rvi = v["istatus"] & 0xFF
        print("\nPENDING INTERRUPT: vcpu%d has RVI=0x%02x latched in the VMCS with IF=%d,"
              % (v["n"], rvi, (v.get("rflags", 0) >> 9) & 1))
        print("  Interruptibility=0x%02x ActivityState=0x%02x." % (v.get("intibility", 0), v.get("activity", 0)))
        print("  Xen HAS latched this vector for delivery; if it is not taken, the reason is on the")
        print("  guest side (TPR/CR8) - which NO field in this capture holds. Do not infer it here.")
        if rvi == 0xE1:
            print("  0xE1 is the Windows IPI vector: this is the shootdown-acknowledgement path.")

    print("\nNOT IN THIS CAPTURE, and needed to close the case: the guest CR8/TPR of any vCPU")
    print("holding a pending RVI, and a core from THIS SAME instance so the stuck RIP can be")
    print("attributed to a module (tools/core-module-list.py, then tools/pdb-symbolize.py).")


if __name__ == "__main__":
    main()
