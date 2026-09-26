#!/usr/bin/env python3
"""core-unwind.py - a REAL x64 stack unwind from a Xen guest core, using the guest's own .pdata.

    tools/core-unwind.py CORE MODULE-BASES.TXT [--vcpu N] [--max 32] [--pdb ntkrnlmp.pdb]

WHY THIS EXISTS. tools/core-stackscan.py reports every qword on the stack that looks like a return
address, so stale frames from earlier, deeper calls are indistinguishable from live ones. Asked to
judge a chain produced that way, Jev answered `cannot-tell-stale-vs-live` 0.66 and rated the result
NOT diagnosis-grade (0.41). That is a defect in the instrument, not a fact about the guest: x64
Windows unwinding is fully specified by each module's .pdata/UNWIND_INFO, and the modules' PE images
are mapped in the core's own memory. This reads them from there and walks the frames properly, so a
frame it prints is one the ABI says is live.

It prints, per frame: module+offset, and the symbol when a PDB is supplied for that module.
Where it CANNOT proceed it says so and stops - a truncated honest chain, never a guessed one.
"""
import sys, struct, os, re, bisect, importlib.util

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("xcr", os.path.join(HERE, "xen-core-rip.py"))
xcr = importlib.util.module_from_spec(_spec)
_argv, sys.argv = sys.argv, [sys.argv[0]]
_spec.loader.exec_module(xcr)
sys.argv = _argv

UWOP = {0: "PUSH_NONVOL", 1: "ALLOC_LARGE", 2: "ALLOC_SMALL", 3: "SET_FPREG", 4: "SAVE_NONVOL",
        5: "SAVE_NONVOL_FAR", 8: "SAVE_XMM128", 9: "SAVE_XMM128_FAR", 10: "PUSH_MACHFRAME"}


class Mem:
    def __init__(self, core, cr3):
        self.c, self.cr3 = core, cr3
    def read(self, va, n):
        out = b""
        while n > 0:
            pa, _ = self.c.v2p(self.cr3, va)
            if pa is None:
                return None
            take = min(n, 4096 - (va & 0xFFF))
            b = self.c.read_phys(pa, take)
            if b is None:
                return None
            out += b; va += take; n -= take
        return out
    def u(self, va, n):
        b = self.read(va, n)
        return None if b is None else int.from_bytes(b, "little")


def load_modules(p):
    mods, cur = [], []
    for ln in open(p, errors="replace"):
        if ln.startswith("=== BOOT"):
            cur = []; mods = cur; continue
        m = re.search(r"(0x[0-9a-fA-F]{8,16})\s+(\S+\.(?:sys|exe|dll))", ln) or \
            re.search(r"(\S+\.(?:sys|exe|dll))\s+(0x[0-9a-fA-F]{8,16})", ln)
        if m:
            a, b = m.group(1), m.group(2)
            base, name = (a, b) if a.startswith("0x") else (b, a)
            cur.append((int(base, 16), os.path.basename(name)))
    mods.sort()
    return mods


def mod_of(mods, va):
    i = bisect.bisect_right([m[0] for m in mods], va) - 1
    if i < 0:
        return None
    base, name = mods[i]
    return None if va - base > (64 << 20) else (base, name)


def pdata(mem, base):
    """(rva, size) of the exception directory, read from the in-memory PE at `base`."""
    if mem.u(base, 2) != 0x5A4D:
        return None
    e_lfanew = mem.u(base + 0x3C, 4)
    if e_lfanew is None:
        return None
    nt = base + e_lfanew
    if mem.u(nt, 4) != 0x00004550:
        return None
    magic = mem.u(nt + 0x18, 2)
    if magic != 0x20B:
        return None                      # PE32+ only
    dd = nt + 0x18 + 0x70                # OptionalHeader + DataDirectory
    return mem.u(dd + 3 * 8, 4), mem.u(dd + 3 * 8 + 4, 4)


def find_rf(mem, base, rva):
    d = pdata(mem, base)
    if not d or not d[0] or not d[1]:
        return None
    start, size = base + d[0], d[1] // 12
    lo, hi = 0, size - 1
    while lo <= hi:
        mid = (lo + hi) // 2
        b = mem.read(start + mid * 12, 12)
        if b is None:
            return None
        beg, end, unw = struct.unpack("<III", b)
        if rva < beg:
            hi = mid - 1
        elif rva >= end:
            lo = mid + 1
        else:
            return beg, end, unw
    return None


def unwind_one(mem, base, rip, rsp):
    """Apply UNWIND_INFO for the function containing rip. Returns (ret_addr, new_rsp, note)."""
    rva = rip - base
    rf = find_rf(mem, base, rva)
    if rf is None:
        return None, None, "no RUNTIME_FUNCTION (leaf or no .pdata)"
    chain_guard = 0
    while True:
        chain_guard += 1
        if chain_guard > 8:
            return None, None, "unwind chain too deep"
        beg, end, unw = rf
        hdr = mem.read(base + unw, 4)
        if hdr is None:
            return None, None, "UNWIND_INFO unreadable"
        verflags, prolog, ncodes, frame = hdr[0], hdr[1], hdr[2], hdr[3]
        ver, flags = verflags & 7, verflags >> 3
        # Version 2 is the modern MSVC format: same prologue unwind codes, plus UWOP_EPILOG (6)
        # nodes that describe epilogues. Epilogue nodes are irrelevant to unwinding from a body
        # RIP, so they are skipped. Refusing version 2 outright stopped this walk at frame #0 on
        # the 2026-09-26 core, where every module is built by a toolchain that emits it.
        if ver not in (1, 2):
            return None, None, f"UNWIND_INFO version {ver}"
        codes = mem.read(base + unw + 4, ncodes * 2)
        if codes is None:
            return None, None, "unwind codes unreadable"
        i = 0
        while i < ncodes:
            off, op = codes[i * 2], codes[i * 2 + 1] & 0xF
            info = codes[i * 2 + 1] >> 4
            if op == 0:                      # PUSH_NONVOL
                rsp += 8; i += 1
            elif op == 1:                    # ALLOC_LARGE
                if info == 0:
                    rsp += struct.unpack_from("<H", codes, (i + 1) * 2)[0] * 8; i += 2
                else:
                    rsp += struct.unpack_from("<I", codes, (i + 1) * 2)[0]; i += 3
            elif op == 2:                    # ALLOC_SMALL
                rsp += info * 8 + 8; i += 1
            elif op == 3:                    # SET_FPREG
                i += 1
            elif op in (4, 8):
                i += 2
            elif op in (5, 9):
                i += 3
            elif op in (6, 7):               # UWOP_EPILOG / reserved (version 2): not a prologue op
                i += 1
            elif op == 10:                   # PUSH_MACHFRAME
                rsp += 40 if info == 0 else 48
                ra = mem.u(rsp - (40 if info == 0 else 48), 8)
                return ra, rsp, "machine frame"
            else:
                return None, None, f"unknown unwind op {op}"
        if flags & 0x4:                      # UNW_FLAG_CHAININFO
            b = mem.read(base + unw + 4 + ((ncodes + 1) & ~1) * 2, 12)
            if b is None:
                return None, None, "chained RUNTIME_FUNCTION unreadable"
            rf = struct.unpack("<III", b)
            continue
        break
    ra = mem.u(rsp, 8)
    return ra, rsp + 8, ""


def main():
    a = sys.argv[1:]
    if len(a) < 2:
        print(__doc__); return 2
    core_p, mods_p = a[0], a[1]
    want, mx, pdb = None, 32, None
    for i, t in enumerate(a):
        if t == "--vcpu": want = int(a[i + 1])
        if t == "--max":  mx = int(a[i + 1])
        if t == "--pdb":  pdb = a[i + 1]

    core = xcr.Core(core_p)
    mods = load_modules(mods_p)
    sym = None
    if pdb:
        try:
            spec2 = importlib.util.spec_from_file_location("ps", os.path.join(HERE, "pdb-symbolize.py"))
            ps = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(ps)
            sym = ps
        except Exception as e:
            print(f"(pdb load failed: {e}; continuing unsymbolised)")

    for v in range(4):
        if want is not None and v != want:
            continue
        r = core.vcpu(v)
        rip, rsp, cr3 = r["rip"], r["rsp"], r["cr3"]
        mem = Mem(core, cr3)
        print(f"\n=== vcpu{v}  RIP={rip:#x} RSP={rsp:#x} CR3={cr3:#x}")
        depth = 0
        while depth < mx:
            m = mod_of(mods, rip)
            if not m:
                print(f"  #{depth:<2} {rip:#018x}  <outside every known module>"); break
            base, name = m
            print(f"  #{depth:<2} {rip:#018x}  {name} + {rip-base:#x}")
            ra, nrsp, note = unwind_one(mem, base, rip, rsp)
            if ra is None:
                print(f"       stop: {note}"); break
            if ra < 0xFFFF800000000000:
                print(f"       stop: next return address {ra:#x} is not kernel space (user boundary)"); break
            rip, rsp, depth = ra, nrsp, depth + 1
        if depth >= mx:
            print(f"       stop: reached --max {mx}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
