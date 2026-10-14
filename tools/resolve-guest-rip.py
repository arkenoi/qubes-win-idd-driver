#!/usr/bin/env python3
"""Resolve a captured guest RIP to module + RVA, using module bases recorded on THAT boot.

WHY THIS EXISTS. Class B of the guest-stability defect (findings/issues.md) is a Windows kernel
spin: three vCPUs were captured at guest RIP fffff800038bfcfe / fffff800038bfd00, exiting on
EXIT_REASON_PAUSE_INSTRUCTION, with per-vCPU RSP identical across three dumps nine minutes apart.
Naming the code needs the module that contains that address - and Windows KASLR re-randomises the
bases every boot, so an offset resolved against any other boot is meaningless. Xen prints no guest
symbols for an HVM domain, and the guest is wedged, so it cannot be asked afterwards.

mgmt/harness/arm-module-bases.sh records the table during every boot, before anything can wedge.
This does the arithmetic against it, scoped to the boot the RIP came from.

WHAT IT REFUSES TO DO, because a wrong answer here is worse than none:
  * resolve against a DIFFERENT boot's table than the one asked for (that is the KASLR trap itself);
  * pick a module when the address falls outside every recorded range - it says UNRESOLVED instead
    of returning the nearest base, which would be a plausible-looking lie;
  * guess a module SIZE. EnumDeviceDrivers gives bases but not sizes, so containment cannot be
    proven, only bounded: an address is attributed to the highest base at or below it, and the
    distance is reported so an implausible offset is visible rather than hidden. A 12 MB offset into
    a 900 KB driver means the real owner was not in the table.

Usage:
    tools/resolve-guest-rip.py <module-bases.txt> <rip> [<rip> ...]
    tools/resolve-guest-rip.py <module-bases.txt> --boot 2026-09-10T12:00:00Z <rip>
"""
import re
import sys

# TWO RECORD SHAPES, and the older one must keep parsing. Kernel lines come from
# EnumDeviceDrivers, which reports no size:
#     MODBASE boot=<iso> base=0x<16hex> name=<file>
# User-mode lines carry a size and the space they belong to, because a module list read per process
# CAN report one:
#     MODBASE boot=<iso> base=0x<16hex> size=0x<hex> space=user name=<file>
# Every archived capture is the first shape, so the optional groups are what keeps them readable.
REC = re.compile(r'MODBASE boot=(\S+) base=0x([0-9a-fA-F]+)'
                 r'(?: size=0x([0-9a-fA-F]+))?'
                 r'(?: space=(\S+))?'
                 r' name=(.+?)\s*$')
# The recorder says so when it dropped user-mode records rather than letting a short table look
# complete; a truncated table resolves a RIP to the WRONG module.
TRUNC = re.compile(r'MODBASE-TRUNCATED boot=(\S+)')


def load(path):
    """-> ({boot: [(base, name, size|None, space)]}, {boot: truncation note})"""
    boots, trunc = {}, {}
    with open(path, errors='ignore') as fh:
        for line in fh:
            line = line.strip()
            t = TRUNC.search(line)
            if t:
                trunc[t.group(1)] = line
                continue
            m = REC.match(line)
            if not m:
                continue
            boot = m.group(1)
            base = int(m.group(2), 16)
            size = int(m.group(3), 16) if m.group(3) else None
            space = m.group(4) or 'kernel'
            boots.setdefault(boot, []).append((base, m.group(5), size, space))
    for b in boots:
        boots[b].sort()
    return boots, trunc


def resolve(mods, rip):
    """Highest base at or below rip.

    Containment is PROVEN where a size is recorded (user-mode) and merely bounded where none is
    (kernel, which EnumDeviceDrivers cannot report). A proven MISS is not a weaker answer than a
    guess - it is the difference between naming the right module and naming a neighbour.
    """
    lo, hi, best = 0, len(mods) - 1, None
    while lo <= hi:
        mid = (lo + hi) // 2
        if mods[mid][0] <= rip:
            best = mods[mid]
            lo = mid + 1
        else:
            hi = mid - 1
    return best


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    args = sys.argv[1:]
    path = args.pop(0)
    want = None
    if args and args[0] == '--boot':
        args.pop(0)
        want = args.pop(0)
    if not args:
        print("no RIP given")
        return 2

    boots, trunc = load(path)
    if not boots:
        print(f"FAIL  no MODBASE records in {path}. Missing data fails - resolve nothing from this.")
        return 1

    if want is None:
        if len(boots) > 1:
            print(f"NOTE  {len(boots)} boots recorded. Resolving against the LATEST; pass --boot to")
            print("      pick another. Resolving a RIP against the wrong boot is the KASLR trap this")
            print("      tool exists to avoid, so if the capture is not from the latest boot, say so.")
        want = sorted(boots)[-1]
    if want not in boots:
        print(f"FAIL  no records for boot {want}. Recorded boots: {', '.join(sorted(boots))}")
        return 1

    mods = boots[want]
    nker = sum(1 for m in mods if m[3] == 'kernel')
    nusr = len(mods) - nker
    print(f"boot {want}: {len(mods)} modules ({nker} kernel, {nusr} user-mode), "
          f"bases 0x{mods[0][0]:x} .. 0x{mods[-1][0]:x}")
    if nusr == 0:
        print("NOTE  no user-mode records in this capture: a user-mode RIP (0x00007f...) cannot be")
        print("      attributed from it. That is what left the 2026-10-14 access violation in")
        print("      qrexec-agent anonymous - the recorder read kernel drivers only.")
    if want in trunc:
        print(f"WARN  {trunc[want]}")
    rc = 0
    for a in args:
        rip = int(a, 16)
        hit = resolve(mods, rip)
        if hit is None:
            print(f"  {a}  UNRESOLVED - below every recorded base. Not attributing it.")
            rc = 1
            continue
        base, name, size, space = hit
        off = rip - base
        flag = ''
        if size is not None:
            # A SIZE MAKES THIS DECIDABLE. Outside the module's extent the nearest base below is a
            # NEIGHBOUR, not the owner, and printing its name would be a confident wrong answer.
            if off >= size:
                print(f"  {a}  UNRESOLVED - falls 0x{off - size:x} past the end of {name} "
                      f"(base 0x{base:x} + 0x{size:x}) and inside no recorded module. Not attributing it.")
                rc = 1
                continue
            flag = f'  [{space}, containment PROVEN within 0x{size:x}]'
        else:
            # No size: kernel records cannot report one, so containment stays bounded by the next
            # base up. An offset past any plausible module means the owner is simply absent.
            if off > 0x2000000:
                flag = '  <-- IMPLAUSIBLE OFFSET (>32 MB): the real owner is probably NOT in this table'
                rc = 1
            else:
                flag = f'  [{space}, containment BOUNDED - no size recorded]'
        print(f"  {a}  ->  {name} + 0x{off:x}{flag}")
    if rc == 0:
        print("Next: match the RVA against that build's symbols. The module file itself is on the")
        print("guest volume; a PDB for the exact build is what turns an RVA into a function name.")
    return rc


if __name__ == '__main__':
    sys.exit(main())
