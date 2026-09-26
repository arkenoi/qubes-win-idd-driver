#!/usr/bin/env python3
"""core-stackscan.py - recover a CALL CHAIN for each vCPU from a Xen guest core.

    tools/core-stackscan.py CORE MODULE-BASES.TXT [--vcpu N] [--depth BYTES] [--pdb ntkrnlmp.pdb]

WHY. A single RIP says where one instruction pointer was; it does not say how the CPU got there,
and on 2026-09-26 that gap was the whole difference between a catalogued specimen and a diagnosis.
Jev rated `unwind-the-stacks` the highest-value next measurement (0.42) on exactly that core.

WHAT THIS IS, STATED HONESTLY. It is a stack SCAN, not a true unwinder: x64 Windows unwinding needs
each module's .pdata/UNWIND_INFO, which is not in the core. It walks the stack upwards from RSP and
reports every qword that lands inside a loaded module's text - i.e. plausible RETURN ADDRESSES.
That means FALSE POSITIVES: stale frames from earlier, deeper calls stay on the stack and look
identical to live ones. Read the output as "these functions were on this stack", NOT as an exact
chain, and never quote a single hit as proof of a code path. Ordering (nearest RSP first) is the
only ranking it can honestly offer.
"""
import sys, struct, importlib.util, os, re

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("xcr", os.path.join(HERE, "xen-core-rip.py"))
xcr = importlib.util.module_from_spec(spec)
sys.argv_backup, sys.argv = sys.argv, [sys.argv[0]]
spec.loader.exec_module(xcr)
sys.argv = sys.argv_backup


def load_modules(p):
    """[(base, name)] from a module-bases.txt recorded by the guest, newest boot block."""
    mods, cur = [], []
    for ln in open(p, errors="replace"):
        if ln.startswith("=== BOOT"):
            cur = []
            mods = cur
            continue
        m = re.search(r"(0x[0-9a-fA-F]{8,16})\s+(\S+\.(?:sys|exe|dll))", ln) or \
            re.search(r"(\S+\.(?:sys|exe|dll))\s+(0x[0-9a-fA-F]{8,16})", ln)
        if m:
            a, b = m.group(1), m.group(2)
            base, name = (a, b) if a.startswith("0x") else (b, a)
            cur.append((int(base, 16), os.path.basename(name)))
    mods.sort()
    return mods


def resolve(mods, va):
    import bisect
    i = bisect.bisect_right([m[0] for m in mods], va) - 1
    if i < 0:
        return None
    base, name = mods[i]
    off = va - base
    # A return address more than 64 MiB past a base is not in that module; it is past the end.
    return None if off > (64 << 20) else (name, off)


def main():
    a = sys.argv[1:]
    if len(a) < 2:
        print(__doc__)
        return 2
    core_p, mods_p = a[0], a[1]
    want = None
    depth = 16384
    pdb = None
    for i, t in enumerate(a):
        if t == "--vcpu":
            want = int(a[i + 1])
        if t == "--depth":
            depth = int(a[i + 1])
        if t == "--pdb":
            pdb = a[i + 1]

    core = xcr.Core(core_p)
    mods = load_modules(mods_p)
    if not mods:
        print(f"no module bases parsed from {mods_p} - cannot resolve anything", file=sys.stderr)
        return 2
    print(f"{len(mods)} modules, bases {hex(mods[0][0])} .. {hex(mods[-1][0])}")

    nv = len(core.sections[".xen_prstatus"]["size"] // xcr.VGC_SIZE * [0]) \
        if isinstance(core.sections[".xen_prstatus"], dict) else 4
    syms = {}
    for v in range(nv):
        if want is not None and v != want:
            continue
        r = core.vcpu(v)
        rip, rsp, cr3 = r["rip"], r["rsp"], r["cr3"]
        top = resolve(mods, rip)
        print(f"\n=== vcpu{v}  RIP={rip:#x} ({top[0]}+{top[1]:#x})" if top else
              f"\n=== vcpu{v}  RIP={rip:#x} (unresolved)")
        print(f"    RSP={rsp:#x} CR3={cr3:#x}  scanning {depth} bytes upwards")
        hits, seen = 0, set()
        for off in range(0, depth, 8):
            va = rsp + off
            pa, _ = core.v2p(cr3, va)
            if pa is None:
                continue
            b = core.read_phys(pa, 8)
            if not b:
                continue
            q = struct.unpack("<Q", b)[0]
            if q < 0xFFFF800000000000:
                continue
            m = resolve(mods, q)
            if not m:
                continue
            key = (m[0], m[1])
            if key in seen:
                continue
            seen.add(key)
            hits += 1
            print(f"    +{off:<6} {q:#018x}  {m[0]} + {m[1]:#x}")
            if hits >= 40:
                print("    ... (truncated at 40 distinct hits)")
                break
        if hits == 0:
            print("    no module-resolvable qwords on this stack - MISSING DATA, not an empty stack")
    return 0


if __name__ == "__main__":
    sys.exit(main())
