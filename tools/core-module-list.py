#!/usr/bin/env python3
"""core-module-list.py - rebuild a wedged guest's LOADED MODULE TABLE from its memory image,
and say which module owns an address (and, with --stack, which modules own a stack).

    tools/core-module-list.py CORE                      # list every loaded module
    tools/core-module-list.py CORE --contains 0x<va>    # name the module containing an address
    tools/core-module-list.py CORE --stack 0x<rsp>      # walk a stack by module

WHY. Naming the code at a wedged RIP used to need a module-base table recorded INSIDE the guest on
that boot, because Windows KASLR re-randomises bases every boot. When that table is missing the
investigation stopped (the 2026-09-23 win10-acc specimen). It does not have to: the guest's own
loader list is in the image.

TWO METHODS WERE TRIED. The one that LIES is "walk back from the address to the nearest MZ": memory
holds cached copies of PE FILES, so the walk finds header after header that is not the loaded image
- on that specimen, five of them within 0x19000 below the RIP, with .idata/.didat/.rsrc sections,
one of which even "covered" the RIP by SizeOfImage. A containment check does not catch that.

THE ONE THAT WORKS, and is what this implements:
  1. scan guest physical memory for the high bytes of a kernel DllBase (C-speed bytes.find);
  2. treat a hit as a KLDR_DATA_TABLE_ENTRY candidate (DllBase +0x30, SizeOfImage +0x40,
     BaseDllName +0x58/+0x60) and VALIDATE it against the guest's page tables: DllBase must map to
     an MZ whose PE header's SizeOfImage EQUALS the entry's - a cached file page cannot satisfy
     both at once;
  3. use the first validated entry as an anchor and follow InLoadOrderLinks around the list, which
     yields the whole table with names.
On the specimen this walks 163 modules and places the spinning RIP in ntoskrnl.exe.

A NOTE ON FILE HANDLES: the linear scan and the page-table walker must not share one, or every
validation moves the scan's cursor and the scan silently finds nothing (measured; the first version
of this tool reported 0 entries over a core that has 163).
"""
import argparse, os, struct, sys
from importlib.machinery import SourceFileLoader
_HERE = os.path.dirname(os.path.abspath(__file__))
x = SourceFileLoader("xcr", os.path.join(_HERE, "xen-core-rip.py")).load_module()

KMIN, KMAX = 0xFFFFF80000000000, 0xFFFFFA0000000000
CHUNK = 8 << 20
E_FLINK, E_DLLBASE, E_SIZE, E_BNLEN, E_BNBUF = 0x00, 0x30, 0x40, 0x58, 0x60

def build(core, cr3, corepath):
    def rd(va, n):
        pa, _ = core.v2p(cr3, va)
        return core.read_phys(pa, n) if pa else None

    def is_image(base, size):
        h = rd(base, 0x40)
        if not h or h[:2] != b"MZ":
            return False
        e = struct.unpack_from("<I", h, 0x3C)[0]
        if e > 0x1000:
            return False
        nt = rd(base + e, 0x80)
        return bool(nt and nt[:4] == b"PE\0\0"
                    and struct.unpack_from("<I", nt, 24 + 56)[0] == size)

    f = open(corepath, "rb")                      # separate handle - see the note above
    total = len(core.pfns) * 4096
    pats = [bytes([b, 0xF8, 0xFF, 0xFF]) for b in (0x00, 0x01, 0x02, 0x03, 0x04)]
    anchor, pos, tested = None, 0, 0
    while pos < total and anchor is None:
        f.seek(core.pages_off + pos)
        blob = f.read(min(CHUNK, total - pos))
        if not blob:
            break
        for pat in pats:
            i = blob.find(pat)
            while i >= 0 and anchor is None:
                ent = i - (E_DLLBASE + 4)
                if ent >= 0 and ent + 0x68 <= len(blob):
                    b, = struct.unpack_from("<Q", blob, ent + E_DLLBASE)
                    s, = struct.unpack_from("<I", blob, ent + E_SIZE)
                    if b & 0xFFF == 0 and 0x1000 <= s <= 0x2000000:
                        tested += 1
                        if is_image(b, s):
                            fl, = struct.unpack_from("<Q", blob, ent + E_FLINK)
                            anchor = fl
                i = blob.find(pat, i + 1)
        pos += len(blob)
    if anchor is None:
        return None, tested, rd

    mods, cur, start, n = {}, anchor, anchor, 0
    while cur and n < 1000:
        b = rd(cur, 0x70)
        if not b:
            break
        db, = struct.unpack_from("<Q", b, E_DLLBASE)
        sz, = struct.unpack_from("<I", b, E_SIZE)
        nlen, = struct.unpack_from("<H", b, E_BNLEN)
        nbuf, = struct.unpack_from("<Q", b, E_BNBUF)
        nm = None
        if 2 <= nlen <= 512 and nbuf:
            raw = rd(nbuf, nlen)
            if raw:
                try:
                    nm = raw.decode("utf-16-le")
                except Exception:
                    nm = None
        if db and sz:
            mods[db] = (sz, nm or "?")
        cur, = struct.unpack_from("<Q", b, E_FLINK)
        n += 1
        if cur == start:
            break
    return mods, tested, rd

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("core")
    ap.add_argument("--cr3", default=None, help="default: vcpu0's")
    ap.add_argument("--contains", default=None)
    ap.add_argument("--stack", default=None, help="walk this RSP by module")
    ap.add_argument("--stack-bytes", type=lambda s: int(s, 0), default=0x2000)
    a = ap.parse_args()
    core = x.Core(a.core)
    cr3 = int(a.cr3, 0) if a.cr3 else core.vcpu(0)["cr3"]
    mods, tested, rd = build(core, cr3, a.core)
    if not mods:
        print("NOT FOUND: no VALIDATED loader entry among %d structural candidates - wrong --cr3?"
              % tested, file=sys.stderr)
        return 1
    def who(va):
        for d, (s, nm) in mods.items():
            if d <= va < d + s:
                return "%s+0x%x" % (nm, va - d)
        return None
    if a.contains:
        want = int(a.contains, 0)
        w = who(want)
        if not w:
            print("NOT FOUND: 0x%x is inside none of the %d modules" % (want, len(mods)),
                  file=sys.stderr)
            return 1
        print("0x%x = %s" % (want, w))
    if a.stack:
        rsp = int(a.stack, 0)
        print("stack from %#x, by module:" % rsp)
        last = None
        for off in range(0, a.stack_bytes, 8):
            q = rd(rsp + off, 8)
            if not q:
                break
            v, = struct.unpack("<Q", q)
            w = who(v)
            if w and w != last:
                last = w
                print("  +%04x  %016x  %s" % (off, v, w))
    if not a.contains and not a.stack:
        for d in sorted(mods):
            s, nm = mods[d]
            print("%016x  %8x  %s" % (d, s, nm))
        print("-- %d modules" % len(mods), file=sys.stderr)
    return 0

if __name__ == "__main__":
    sys.exit(main())
