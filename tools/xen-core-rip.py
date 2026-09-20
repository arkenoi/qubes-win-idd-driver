#!/usr/bin/env python3
"""xen-core-rip.py - name the code a wedged HVM guest is executing, from an `xl dump-core` image.

    tools/xen-core-rip.py CORE [--bytes N] [--around N] [--read VA:LEN] [--json out]

WHY THIS EXISTS. The register's P1 multi-vCPU wedge has been unnamed since 2026-09-10 because the
one measurement that could name it was never taken: the NMI route produces no bugcheck (a bugcheck
must freeze the other processors with IPIs, so if IPI delivery is wedged the crash path deadlocks
too), and there is no guest cooperation to be had - qrexec is dead and the console will not attach.
`xl dump-core` needs no cooperation at all. This reads the resulting image WITHOUT gdb, Windows
symbols, or copying the 8 GB anywhere.

WHAT IT DOES
  1. Parses `.xen_prstatus` - an array of `struct vcpu_guest_context`, one per vCPU. The section's
     sh_entsize is the struct size and is CHECKED against the x86_64 layout (5168 = 0x1430); a
     mismatch is an instrument error, not something to guess around.
  2. Builds the pfn -> page-index map from `.xen_pfn` (ascending, with holes written as
     0xffffffffffffffff, which are NOT valid pages and never match).
  3. Walks the guest's own 4-level page tables from CR3 to translate a virtual address to a guest
     physical one, honouring 1 GiB and 2 MiB large pages.
  4. Reads the bytes at each vCPU's RIP and disassembles them with objdump, with the vma set to the
     real RIP so the branch targets printed are the guest's actual addresses.

WHAT IT DELIBERATELY DOES NOT DO: guess module names. Without the guest's loaded-module list a
numeric RIP is not a symbol, and inventing one is how earlier explanations in this project went
wrong. It reports the addresses, the instruction stream, and which vCPUs share them - which is
enough to say whether two CPUs are in the same loop, and what kind of loop it is.

Exit 0 on success, 2 on any instrument error (unreadable core, unexpected struct size, no objdump),
so a caller can never mistake "it did not run" for "there was nothing there".
"""
import argparse, array, bisect, json, os, re, struct, subprocess, sys, tempfile

VGC_SIZE = 0x1430          # sizeof(struct vcpu_guest_context) on x86_64
UR = 520                   # offsetof(vcpu_guest_context, user_regs)
OFF = dict(rip=UR + 128, cs=UR + 136, rflags=UR + 144, rsp=UR + 152,
           r15=UR + 0, r14=UR + 8, r13=UR + 16, r12=UR + 24, rbp=UR + 32, rbx=UR + 40,
           r11=UR + 48, r10=UR + 56, r9=UR + 64, r8=UR + 72,
           rax=UR + 80, rcx=UR + 88, rdx=UR + 96, rsi=UR + 104, rdi=UR + 112,
           cr0=4984, cr2=5000, cr3=5008, cr4=5016)
PAGE = 4096
HOLE = 0xFFFFFFFFFFFFFFFF


def die(msg):
    print("INSTRUMENT: " + msg, file=sys.stderr)
    sys.exit(2)


class Core:
    def __init__(self, path):
        self.f = open(path, "rb")
        self.sections = self._sections()
        for need in (".xen_prstatus", ".xen_pages", ".xen_pfn"):
            if need not in self.sections:
                die("core has no %s section - is this an `xl dump-core` image?" % need)
        pr = self.sections[".xen_prstatus"]
        if pr["entsize"] != VGC_SIZE:
            die("unexpected .xen_prstatus entsize %d (want %d = x86_64 vcpu_guest_context); "
                "refusing to parse a layout I do not know" % (pr["entsize"], VGC_SIZE))
        self.nvcpu = pr["size"] // pr["entsize"]
        pf = self.sections[".xen_pfn"]
        self.f.seek(pf["offset"])
        self.pfns = array.array("Q")
        self.pfns.frombytes(self.f.read(pf["size"]))
        self.pages_off = self.sections[".xen_pages"]["offset"]

    def _sections(self):
        f = self.f
        f.seek(0)
        e = f.read(64)
        if e[:4] != b"\x7fELF":
            die("not an ELF file")
        shoff, shentsize, shnum, shstrndx = (struct.unpack_from("<Q", e, 0x28)[0],
                                             struct.unpack_from("<H", e, 0x3A)[0],
                                             struct.unpack_from("<H", e, 0x3C)[0],
                                             struct.unpack_from("<H", e, 0x3E)[0])
        f.seek(shoff)
        raw = f.read(shentsize * shnum)
        hdrs = []
        for i in range(shnum):
            n, _t, _fl, _ad, off, size, _l, _i, _al, ent = struct.unpack_from("<IIQQQQIIQQ", raw, i * shentsize)
            hdrs.append(dict(name=n, offset=off, size=size, entsize=ent))
        f.seek(hdrs[shstrndx]["offset"])
        strtab = f.read(hdrs[shstrndx]["size"])
        out = {}
        for h in hdrs:
            nm = strtab[h["name"]:strtab.index(b"\0", h["name"])].decode()
            out[nm] = h
        return out

    def vcpu(self, i):
        pr = self.sections[".xen_prstatus"]
        self.f.seek(pr["offset"] + i * VGC_SIZE)
        b = self.f.read(VGC_SIZE)
        return {k: struct.unpack_from("<Q", b, o)[0] for k, o in OFF.items()}

    def page_index(self, pfn):
        """pfn -> index into .xen_pages, or None. The array is ascending with holes at the tail."""
        i = bisect.bisect_left(self.pfns, pfn)
        if i < len(self.pfns) and self.pfns[i] == pfn and pfn != HOLE:
            return i
        return None

    def read_phys(self, pa, n):
        out = b""
        while n > 0:
            pfn, off = pa >> 12, pa & 0xFFF
            idx = self.page_index(pfn)
            if idx is None:
                return None
            take = min(n, PAGE - off)
            self.f.seek(self.pages_off + idx * PAGE + off)
            out += self.f.read(take)
            pa += take
            n -= take
        return out

    def v2p(self, cr3, va):
        """4-level walk. Returns (pa, level_str) or (None, why)."""
        def ent(table_pa, idx):
            b = self.read_phys(table_pa + idx * 8, 8)
            return None if b is None else struct.unpack("<Q", b)[0]
        base = cr3 & 0x000FFFFFFFFFF000
        i4, i3, i2, i1 = (va >> 39) & 0x1FF, (va >> 30) & 0x1FF, (va >> 21) & 0x1FF, (va >> 12) & 0x1FF
        e4 = ent(base, i4)
        if e4 is None or not e4 & 1:
            return None, "PML4E not present"
        e3 = ent(e4 & 0x000FFFFFFFFFF000, i3)
        if e3 is None or not e3 & 1:
            return None, "PDPTE not present"
        if e3 & (1 << 7):
            return (e3 & 0x000FFFFC0000000) | (va & 0x3FFFFFFF), "1G"
        e2 = ent(e3 & 0x000FFFFFFFFFF000, i2)
        if e2 is None or not e2 & 1:
            return None, "PDE not present"
        if e2 & (1 << 7):
            return (e2 & 0x000FFFFFFE00000) | (va & 0x1FFFFF), "2M"
        e1 = ent(e2 & 0x000FFFFFFFFFF000, i1)
        if e1 is None or not e1 & 1:
            return None, "PTE not present"
        return (e1 & 0x000FFFFFFFFFF000) | (va & 0xFFF), "4K"


def disasm(data, vma):
    if not data:
        return ["<unreadable>"]
    d = tempfile.mkdtemp(prefix="xencore-", dir=os.environ.get("XENCORE_TMP") or None)
    p = os.path.join(d, "b.bin")
    open(p, "wb").write(data)
    try:
        out = subprocess.run(["objdump", "-b", "binary", "-m", "i386:x86-64", "-D",
                              "--adjust-vma=0x%x" % vma, p],
                             capture_output=True, text=True, timeout=60)
    except FileNotFoundError:
        die("objdump not found")
    finally:
        try:
            os.remove(p); os.rmdir(d)
        except OSError:
            pass
    lines = [l for l in out.stdout.splitlines() if re.match(r"^\s+[0-9a-f]+:", l)]
    return lines or ["<objdump produced nothing>"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("core")
    ap.add_argument("--bytes", type=int, default=64, help="bytes to disassemble forward from RIP")
    ap.add_argument("--around", type=int, default=32, help="bytes to show BEFORE RIP (loop tops live there)")
    ap.add_argument("--read", help="also translate+hexdump an arbitrary VA, as VA:LEN (hex VA)")
    ap.add_argument("--json")
    a = ap.parse_args()

    c = Core(a.core)
    print("vcpus=%d  pages=%d  (pfn entries %d)" % (c.nvcpu, c.sections[".xen_pages"]["size"] // PAGE, len(c.pfns)))
    print()
    rows = []
    for i in range(c.nvcpu):
        v = c.vcpu(i)
        pa, how = c.v2p(v["cr3"], v["rip"])
        row = dict(vcpu=i, rip=v["rip"], rsp=v["rsp"], cr3=v["cr3"], rflags=v["rflags"],
                   pa=pa, mapping=how)
        print("=== vcpu%d  RIP=0x%016x  RSP=0x%016x  CR3=0x%011x  RFLAGS=0x%x  IF=%d" %
              (i, v["rip"], v["rsp"], v["cr3"], v["rflags"], 1 if v["rflags"] & 0x200 else 0))
        if pa is None:
            print("    RIP does not translate: %s" % how)
            rows.append(row); print(); continue
        print("    RIP -> GPA 0x%x (%s page)" % (pa, how))
        start = v["rip"] - a.around
        spa, _ = c.v2p(v["cr3"], start)
        blob = c.read_phys(spa, a.around + a.bytes) if spa is not None else c.read_phys(pa, a.bytes)
        vma = start if spa is not None else v["rip"]
        lines = disasm(blob, vma)
        row["disasm"] = lines
        for l in lines:
            mark = "  <== RIP" if re.match(r"^\s+%x:" % v["rip"], l) else ""
            print("   ", l.rstrip(), mark)
        rows.append(row)
        print()

    # Which vCPUs share a RIP, and which share a CR3 - the whole question for a multi-CPU wedge.
    byrip, bycr3 = {}, {}
    for r in rows:
        byrip.setdefault(r["rip"], []).append(r["vcpu"])
        bycr3.setdefault(r["cr3"], []).append(r["vcpu"])
    print("shared RIPs :", {hex(k): v for k, v in byrip.items() if len(v) > 1} or "none")
    print("shared CR3s :", {hex(k): v for k, v in bycr3.items() if len(v) > 1} or "none")

    if a.read:
        va, ln = a.read.split(":")
        va, ln = int(va, 16), int(ln)
        cr3 = rows[0]["cr3"]
        pa, how = c.v2p(cr3, va)
        print("\nread 0x%x (cr3 of vcpu0): %s" % (va, ("GPA 0x%x (%s)" % (pa, how)) if pa else how))
        if pa:
            d = c.read_phys(pa, ln)
            for o in range(0, len(d), 16):
                print("    %016x  %s" % (va + o, " ".join("%02x" % x for x in d[o:o + 16])))

    if a.json:
        json.dump(rows, open(a.json, "w"), indent=1, default=str)
    return 0


if __name__ == "__main__":
    sys.exit(main())
