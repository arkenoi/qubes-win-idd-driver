#!/usr/bin/env python3
"""core-module-name.py - name the module that CONTAINS a guest virtual address, from a core.

    tools/core-module-name.py CORE 0xfffff8015d6bfa5e [--cr3 0x1aa000] [--max-mb 64]

WHY THIS EXISTS. Naming the code at a wedged guest's RIP has needed the module-base table recorded
inside the guest on THAT boot, because Windows KASLR re-randomises the bases every boot. When the
table is missing - which is exactly what happened to the 2026-09-23 win10-acc specimen - the RIP
has been unresolvable and the investigation stops.

It does not have to. A core image contains the loaded image itself, and a PE image names itself:
every driver carries an export directory Name and, in practice, a CodeView (RSDS) debug record with
the PDB path. So walk BACKWARDS from the address, page by page, to the image that contains it, and
read the name out of its own headers. No table, no symbols, no guessing.

WHAT IT REFUSES TO DO
  * report a module whose SizeOfImage does not actually cover the address - a nearby MZ is not the
    containing image, and returning it would be a plausible-looking lie;
  * invent a name when the headers carry none - it prints the base and says UNNAMED;
  * search further back than --max-mb (default 64 MB), because an unbounded walk over a 8 GB core
    will find *an* MZ eventually and it will be the wrong one.
Exit 0 when the containing image was found and named, 1 when not found, 2 on instrument error.
"""
import argparse, os, struct, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from importlib.machinery import SourceFileLoader
_xcr = SourceFileLoader("xcr", os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                            "xen-core-rip.py")).load_module()
PAGE = 4096

def die(m):
    print("ERROR: %s" % m, file=sys.stderr); sys.exit(2)

def read_at(core, cr3, va, n):
    pa, _why = core.v2p(cr3, va)
    if pa is None:
        return None
    return core.read_phys(pa, n)

def pe_at(core, cr3, base):
    """If `base` is a PE image header, return its parsed dict, else None."""
    hdr = read_at(core, cr3, base, 0x40)
    if not hdr or hdr[:2] != b"MZ":
        return None
    e_lfanew = struct.unpack_from("<I", hdr, 0x3C)[0]
    if e_lfanew > 0x1000:
        return None
    nt = read_at(core, cr3, base + e_lfanew, 0x108)
    if not nt or nt[:4] != b"PE\0\0":
        return None
    machine, nsec = struct.unpack_from("<HH", nt, 4)
    opt_off = 24
    magic = struct.unpack_from("<H", nt, opt_off)[0]
    if magic != 0x20B:                      # PE32+ only; a 32-bit image on x64 is not our driver
        return None
    size_of_image = struct.unpack_from("<I", nt, opt_off + 56)[0]
    nrva = struct.unpack_from("<I", nt, opt_off + 108)[0]
    dirs = []
    for i in range(min(nrva, 16)):
        rva, sz = struct.unpack_from("<II", nt, opt_off + 112 + i * 8)
        dirs.append((rva, sz))
    return dict(base=base, size=size_of_image, dirs=dirs, machine=machine, nsec=nsec)

def cstr(core, cr3, va, cap=260):
    b = read_at(core, cr3, va, cap)
    if not b:
        return None
    z = b.find(b"\0")
    return b[:z if z >= 0 else cap].decode("ascii", "replace")

def name_of(core, cr3, pe):
    """(export-name, pdb-path) - either may be None; both read from the image's own headers."""
    exp = None
    if len(pe["dirs"]) > 0 and pe["dirs"][0][0]:
        d = read_at(core, cr3, pe["base"] + pe["dirs"][0][0], 16)
        if d:
            name_rva = struct.unpack_from("<I", d, 12)[0]
            if name_rva:
                exp = cstr(core, cr3, pe["base"] + name_rva, 64)
    pdb = None
    if len(pe["dirs"]) > 6 and pe["dirs"][6][0]:
        drva, dsz = pe["dirs"][6]
        for i in range(0, min(dsz, 16 * 28), 28):
            e = read_at(core, cr3, pe["base"] + drva + i, 28)
            if not e:
                break
            dtype = struct.unpack_from("<I", e, 12)[0]
            daddr = struct.unpack_from("<I", e, 20)[0]
            if dtype == 2 and daddr:        # IMAGE_DEBUG_TYPE_CODEVIEW
                cv = read_at(core, cr3, pe["base"] + daddr, 0x120)
                if cv and cv[:4] == b"RSDS":
                    z = cv.find(b"\0", 24)
                    pdb = cv[24:z if z >= 0 else 0x120].decode("ascii", "replace")
                break
    return exp, pdb

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("core")
    ap.add_argument("va")
    ap.add_argument("--cr3", default=None, help="page tables to walk (default: each vCPU's, in turn)")
    ap.add_argument("--max-mb", type=int, default=64)
    a = ap.parse_args()
    va = int(a.va, 0)
    core = _xcr.Core(a.core)
    cr3s = [int(a.cr3, 0)] if a.cr3 else []
    if not cr3s:
        seen = []
        for i in range(core.nvcpu):
            c = core.vcpu(i)["cr3"] if "cr3" in core.vcpu(i) else None
            if c and c not in seen:
                seen.append(c)
        cr3s = seen
    if not cr3s:
        die("no CR3 available - pass --cr3")

    for cr3 in cr3s:
        if read_at(core, cr3, va, 1) is None:
            continue
        base = va & ~(PAGE - 1)
        steps = (a.max_mb * 1024 * 1024) // PAGE
        for _ in range(steps):
            pe = pe_at(core, cr3, base)
            if pe:
                if not (pe["base"] <= va < pe["base"] + pe["size"]):
                    # A real image, but it does not cover the address: keep walking rather than
                    # report a neighbour as the container.
                    base -= PAGE
                    continue
                exp, pdb = name_of(core, cr3, pe)
                nm = pdb or exp or "UNNAMED"
                print("cr3        0x%x" % cr3)
                print("image base 0x%x  size 0x%x" % (pe["base"], pe["size"]))
                print("address    0x%x  =  %s + 0x%x" % (va, os.path.basename(nm), va - pe["base"]))
                if exp:
                    print("export name %s" % exp)
                if pdb:
                    print("pdb         %s" % pdb)
                return 0
            base -= PAGE
    print("NOT FOUND: no PE image containing 0x%x within %d MB below it" % (va, a.max_mb),
          file=sys.stderr)
    return 1

if __name__ == "__main__":
    sys.exit(main())
