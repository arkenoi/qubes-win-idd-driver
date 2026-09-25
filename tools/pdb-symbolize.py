#!/usr/bin/env python3
"""pdb-symbolize.py - turn a Windows guest RVA into a NAME, from a core, without a debugger.

    tools/pdb-symbolize.py ident CORE --base <hex> [--cr3 <hex>]   # PDB name+GUID+age+URL
    tools/pdb-symbolize.py fetch  <pdb-name> <GUID> <age> [-o DIR] # download it from msdl
    tools/pdb-symbolize.py sym    PDB RVA...                       # RVA -> nearest public
    tools/pdb-symbolize.py field  PDB STRUCT [OFFSET...]           # struct offset -> member
    tools/pdb-symbolize.py addr   PDB NAME...                      # public name -> RVA

WHY THIS EXISTS. findings/wedge.md recorded, for months, that the wedged guest's spinning function
"cannot be named further without a PDB and this qube has no symbol-server route". BOTH halves of
that were false. msdl.microsoft.com answers from this qube, and the PDB identity is sitting in the
core itself - the guest's own ntoskrnl PE header carries the CodeView RSDS GUID. On 2026-09-25 the
unnamed function turned out to be nt!KiIpiSendRequestEx+0xae and the unnamed flag it spins on to be
_KPRCB.PacketBarrier, with _KPRCB.TargetCount saying how many targets still owe an acknowledgement.
That is the difference between "a spin on an unknown dword" and a named IPI/TLB-shootdown wedge.

There is no llvm-pdbutil, no gdb and no Windows debugger on this qube, so this reads the MSF/PDB
container directly: the stream directory, the DBI stream (stream 3) for the symbol-record and
section-header streams, S_PUB32 records for publics, and the TPI stream (stream 2) for LF_STRUCTURE
/ LF_FIELDLIST so a raw structure offset can be named.

LIMITS, stated so a caller does not over-read the output:
  * Publics only. A hit is the nearest PUBLIC at or below the address, so "+0x1e5" can span an
    unexported static. Treat a large delta as "in this region", not as a precise frame.
  * Sections come from the PDB's own section-header stream, so RVAs are image RVAs; add the
    guest's module base before comparing to a live RIP, never after.
  * `field` resolves direct members of the named structure. Members nested in anonymous unions are
    not walked; an offset that lands in one reports the enclosing member, or nothing.

Exit 0 on success, 2 on any instrument error, so a caller can never mistake "it did not run" for
"there was nothing there".
"""
import argparse, bisect, os, struct, sys, urllib.request

MSDL = "https://msdl.microsoft.com/download/symbols"


def die(msg):
    print("INSTRUMENT: " + msg, file=sys.stderr)
    sys.exit(2)


class MSF:
    """The PDB container: a block-addressed file with a stream directory."""

    def __init__(self, path):
        try:
            self.d = open(path, "rb").read()
        except OSError as e:
            die("cannot read %s: %s" % (path, e))
        if self.d[:26] != b"Microsoft C/C++ MSF 7.00\r\n":
            die("%s is not an MSF 7.00 PDB" % path)
        bs, _fpm, _nblk, ndirb, _unk, blkmap = struct.unpack_from("<IIIIII", self.d, 32)
        self.bs = bs
        nblocks = (ndirb + bs - 1) // bs
        dirblocks = struct.unpack_from("<%dI" % nblocks, self.d, blkmap * bs)
        dirdata = b"".join(self.blk(b) for b in dirblocks)[:ndirb]
        ns = struct.unpack_from("<I", dirdata, 0)[0]
        sizes = struct.unpack_from("<%dI" % ns, dirdata, 4)
        off = 4 + 4 * ns
        self.streams = []
        for s in sizes:
            if s == 0xFFFFFFFF:
                s = 0
            n = (s + bs - 1) // bs
            blks = struct.unpack_from("<%dI" % n, dirdata, off)
            off += 4 * n
            self.streams.append((s, blks))

    def blk(self, i):
        return self.d[i * self.bs:(i + 1) * self.bs]

    def stream(self, i):
        size, blks = self.streams[i]
        return b"".join(self.blk(b) for b in blks)[:size]


DBI_FMT = "<iIIHHHHHHiiiiiIiiHHI"


def dbi_parts(m):
    dbi = m.stream(3)
    v = struct.unpack_from(DBI_FMT, dbi, 0)
    symrec = v[7]
    dbghdr_size, dbghdr_off = v[15], 64 + v[9] + v[10] + v[11] + v[12] + v[13] + v[16]
    dbg = struct.unpack_from("<%dH" % (dbghdr_size // 2), dbi, dbghdr_off)
    return symrec, dbg


def sections(m):
    _symrec, dbg = dbi_parts(m)
    sh = m.stream(dbg[5])
    out = []
    for i in range(len(sh) // 40):
        name, _vs, va, _rs, _rp = struct.unpack_from("<8sIIII", sh, i * 40)
        out.append((name.rstrip(b"\0").decode(), va))
    return out


def publics(m):
    """Every S_PUB32 in the symbol-record stream, as (rva, name), sorted."""
    symrec, _dbg = dbi_parts(m)
    secs = [va for _n, va in sections(m)]
    sr = m.stream(symrec)
    out, off = [], 0
    while off + 4 <= len(sr):
        ln, kind = struct.unpack_from("<HH", sr, off)
        if ln < 2:
            break
        if kind == 0x110E:  # S_PUB32
            _flags, o, seg = struct.unpack_from("<IIH", sr, off + 4)
            nm = sr[off + 14:off + 2 + ln].split(b"\0")[0].decode("utf-8", "replace")
            if 1 <= seg <= len(secs):
                out.append((secs[seg - 1] + o, nm))
        off += ln + 2
    out.sort()
    return out


def _numeric(b, o):
    """A CodeView numeric leaf: a bare u16, or a tag naming a wider type."""
    v = struct.unpack_from("<H", b, o)[0]
    if v < 0x8000:
        return v, o + 2
    fmt = {0x8000: "<b", 0x8001: "<h", 0x8002: "<H", 0x8003: "<i",
           0x8004: "<I", 0x8009: "<q", 0x800A: "<Q"}.get(v)
    if fmt is None:
        die("unhandled numeric leaf 0x%04x" % v)
    return struct.unpack_from(fmt, b, o + 2)[0], o + 2 + struct.calcsize(fmt)


def _cstr(b, o):
    e = b.index(b"\0", o)
    return b[o:e].decode("utf-8", "replace"), e + 1


def members(m, struct_name):
    """Direct members of a named LF_STRUCTURE, as a list of (offset, name)."""
    tpi = m.stream(2)
    _ver, hsz, tibeg, _tiend, trbytes = struct.unpack_from("<IIIII", tpi, 0)
    recs, off, ti = {}, hsz, tibeg
    while off + 4 <= hsz + trbytes:
        ln, kind = struct.unpack_from("<HH", tpi, off)
        recs[ti] = (kind, tpi[off + 4:off + 2 + ln])
        ti += 1
        off += ln + 2
    fieldlist = None
    for _idx, (kind, b) in recs.items():
        if kind != 0x1505:  # LF_STRUCTURE
            continue
        _cnt, prop, fld, _der, _vs = struct.unpack_from("<HHIII", b, 0)
        _size, o = _numeric(b, 16)
        nm, _ = _cstr(b, o)
        if nm == struct_name and not prop & 0x80:  # skip forward references
            fieldlist = fld
    if fieldlist is None:
        die("no complete definition of %s in this PDB" % struct_name)
    fl = recs[fieldlist][1]
    out, o = [], 0
    while o + 4 <= len(fl):
        if struct.unpack_from("<H", fl, o)[0] != 0x150D:  # LF_MEMBER
            break
        _attr, _ty = struct.unpack_from("<HI", fl, o + 2)
        v, o = _numeric(fl, o + 8)
        nm, o = _cstr(fl, o)
        out.append((v, nm))
        while o < len(fl) and 0xF1 <= fl[o] <= 0xF3:  # LF_PAD
            o += 1
    out.sort()
    return out


def pe_pdb_ident(read, base):
    """(pdb name, guid, age) from a loaded module's CodeView debug directory."""
    hdr = read(base, 0x400)
    if not hdr or hdr[:2] != b"MZ":
        die("no MZ header at %016x" % base)
    pe = struct.unpack_from("<I", hdr, 0x3C)[0]
    if hdr[pe:pe + 4] != b"PE\0\0":
        die("no PE signature at %016x+%x" % (base, pe))
    opt = pe + 24
    if struct.unpack_from("<H", hdr, opt)[0] != 0x20B:
        die("not a PE32+ image")
    dbg_rva, dbg_sz = struct.unpack_from("<II", hdr, opt + 112 + 6 * 8)
    dd = read(base + dbg_rva, dbg_sz)
    for i in range(dbg_sz // 28):
        _c, _t, _mj, _mn, typ, sz, rva, _fp = struct.unpack_from("<IIHHIIII", dd, i * 28)
        if typ != 2:  # IMAGE_DEBUG_TYPE_CODEVIEW
            continue
        cv = read(base + rva, sz)
        if cv[:4] != b"RSDS":
            continue
        d1, d2, d3 = struct.unpack_from("<IHH", cv, 4)
        age = struct.unpack_from("<I", cv, 20)[0]
        guid = "%08X%04X%04X%s" % (d1, d2, d3, cv[12:20].hex().upper())
        return cv[24:].split(b"\0")[0].decode(), guid, age
    die("no RSDS CodeView record in the debug directory")


def core_reader(core_path, cr3):
    """A VA->bytes reader over an `xl dump-core` image, via the guest's page tables."""
    import importlib.util
    here = os.path.dirname(os.path.abspath(__file__))
    spec = importlib.util.spec_from_file_location("xcr", os.path.join(here, "xen-core-rip.py"))
    xcr = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(xcr)
    core = xcr.Core(core_path)
    if cr3 is None:
        cr3 = core.vcpu(0)["cr3"]

    def read(va, n):
        out = b""
        while n > 0:
            pa, _kind = core.v2p(cr3, va)
            if pa is None:
                return None
            c = min(n, 0x1000 - (pa & 0xFFF))
            out += core.read_phys(pa, c)
            va += c
            n -= c
        return out
    return read, cr3


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("ident", help="read a module's PDB identity out of a core")
    p.add_argument("core")
    p.add_argument("--base", required=True, help="module base VA (hex)")
    p.add_argument("--cr3", help="CR3 to translate with (hex); default vcpu0's")

    p = sub.add_parser("fetch", help="download a PDB from the Microsoft symbol server")
    p.add_argument("name")
    p.add_argument("guid")
    p.add_argument("age", type=lambda s: int(s, 0))
    p.add_argument("-o", "--out-dir", default=".")

    p = sub.add_parser("sym", help="RVA -> nearest public symbol")
    p.add_argument("pdb")
    p.add_argument("rva", nargs="+")

    p = sub.add_parser("field", help="structure offset -> member name")
    p.add_argument("pdb")
    p.add_argument("struct")
    p.add_argument("offset", nargs="*")

    p = sub.add_parser("addr", help="public symbol name -> RVA")
    p.add_argument("pdb")
    p.add_argument("name", nargs="+")

    a = ap.parse_args()

    if a.cmd == "ident":
        read, cr3 = core_reader(a.core, int(a.cr3, 16) if a.cr3 else None)
        name, guid, age = pe_pdb_ident(read, int(a.base, 16))
        print("pdb   %s" % name)
        print("guid  %s" % guid)
        print("age   %d" % age)
        print("cr3   0x%x" % cr3)
        print("url   %s/%s/%s%X/%s" % (MSDL, name, guid, age, name))
        print("fetch tools/pdb-symbolize.py fetch %s %s %d" % (name, guid, age))
        return

    if a.cmd == "fetch":
        url = "%s/%s/%s%X/%s" % (MSDL, a.name, a.guid, a.age, a.name)
        dest = os.path.join(a.out_dir, a.name)
        req = urllib.request.Request(url, headers={"User-Agent": "Microsoft-Symbol-Server/10.0.0.0"})
        try:
            with urllib.request.urlopen(req, timeout=300) as r, open(dest, "wb") as f:
                f.write(r.read())
        except Exception as e:
            die("download failed: %s" % e)
        print("%s (%d bytes)" % (dest, os.path.getsize(dest)))
        return

    m = MSF(a.pdb)

    if a.cmd == "sym":
        pubs = publics(m)
        rvas = [p[0] for p in pubs]
        for s in a.rva:
            t = int(s, 16)
            i = bisect.bisect_right(rvas, t) - 1
            if i < 0:
                print("%08x  <below the first public>" % t)
                continue
            rva, nm = pubs[i]
            print("%08x  %s + 0x%x" % (t, nm, t - rva))
        return

    if a.cmd == "field":
        mem = members(m, a.struct)
        if not a.offset:
            for v, nm in mem:
                print("  0x%05x  %s" % (v, nm))
            return
        for s in a.offset:
            t = int(s, 16)
            hit = [nm for v, nm in mem if v == t]
            if hit:
                for nm in hit:
                    print("%s + 0x%x  =  %s" % (a.struct, t, nm))
            else:
                prev = [x for x in mem if x[0] <= t][-1:]
                nxt = [x for x in mem if x[0] > t][:1]
                print("%s + 0x%x  =  <no direct member>; between %s" % (
                    a.struct, t, " and ".join("%s@0x%x" % (nm, v) for v, nm in prev + nxt)))
        return

    if a.cmd == "addr":
        by_name = {nm: rva for rva, nm in publics(m)}
        for nm in a.name:
            print("%-40s %s" % (nm, hex(by_name[nm]) if nm in by_name else "NOT FOUND"))
        return


if __name__ == "__main__":
    main()
