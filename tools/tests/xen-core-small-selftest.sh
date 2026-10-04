#!/usr/bin/env bash
# xen-core-small-selftest.sh - offline proof for tools/xen-core-rip.py --small: the SMALL STATE of an `xl dump-core` image (every vCPU's
# register context, the raw .xen_prstatus, the shared-info page) is decoded right and refused when the image is wrong.
#
# WHY: 2026-10-02 a SPIN core was read for RIP and CR3 only and deleted for space; the stuck vCPU's RAX - which hypercall it was in - was
# never recorded. --small writes every register next to the core the moment it lands (mgmt/harness/fetch-wedge-core.sh).
#
# No rig, no guest: a synthetic ELF core with PLANTED values (x86_64 vcpu_guest_context layout, 0x1430 bytes per vCPU), in both section
# table placements (after the ELF header, as Xen writes it, and at the end).
#   no env                  every check must pass AND XENCORE_SMALL_DEFECT=1 (rax read 8 bytes off) must make the value checks FAIL.
#   XENCORE_SMALL_DEFECT=1  run the checks with the defect and exit with their result - i.e. this test FAILS, by design.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 2
T=$(mktemp -d "${TMPDIR:-/tmp}/xencore-small-XXXXXX")
trap 'rm -rf "$T"' EXIT

mkcore(){ # $1 out  $2 shdr placement (head|tail)  $3 entsize override (optional)  $4 truncate-bytes (optional)
  python3 - "$1" "$2" "${3:-}" "${4:-}" <<'PY'
import struct, sys
out, place, ent_over, trunc = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
VGC, UR = 0x1430, 520
def ctx(i):
    b = bytearray(VGC)
    regs = dict(r15=0x15, r14=0x14, r13=0x13, r12=0x12, rbp=0x1b0 + i, rbx=0xb0 + i, r11=0x11, r10=0x10a + i, r9=0x9, r8=0x8a + i,
                rax=(12 if i == 1 else 0xa0 + i), rcx=0xc0 + i, rdx=0xd0 + i, rsi=0x51 + i, rdi=(1 if i == 1 else 0xd1 + i))
    order = "r15 r14 r13 r12 rbp rbx r11 r10 r9 r8 rax rcx rdx rsi rdi".split()
    for k, n in enumerate(order):
        struct.pack_into("<Q", b, UR + 8 * k, regs[n])
    struct.pack_into("<I", b, UR + 120, 0xe0 + i)                    # error_code
    struct.pack_into("<I", b, UR + 124, 0xee + i)                    # entry_vector
    struct.pack_into("<Q", b, UR + 128, 0xfffff80600001000 + i)      # rip
    struct.pack_into("<Q", b, UR + 136, 0x10)                        # cs
    struct.pack_into("<Q", b, UR + 144, 0x246)                       # rflags
    struct.pack_into("<Q", b, UR + 152, 0xffffc00000002000 + i)      # rsp
    struct.pack_into("<Q", b, UR + 160, 0x18)                        # ss
    struct.pack_into("<Q", b, 512, 1 << 1)                           # flags
    for k, v in ((4984, 0x80050033), (5000, 0x7ff0 + i), (5008, 0x1aa000 + 0x1000 * i), (5016, 0x350ef8)):
        struct.pack_into("<Q", b, k, v)                              # cr0 cr2 cr3 cr4
    for k, v in ((5144, 0xf5), (5152, 0xfffff80700000000 + i), (5160, 0x7ff700000000 + i)):
        struct.pack_into("<Q", b, k, v)                              # fs_base gs_base_kernel gs_base_user
    return bytes(b)
nv = 3
secs = [("", b"", 0), (".shstrtab", None, 0), (".note.Xen", b"\0" * 64, 0),
        (".xen_prstatus", b"".join(ctx(i) for i in range(nv)), int(ent_over) if ent_over else VGC),
        (".xen_shared_info", bytes(range(256)) * 16, 0),
        (".xen_pfn", struct.pack("<4Q", 0, 1, 2, 3), 8), (".xen_pages", b"\x90" * 4096 * 4, 4096)]
names = b"\0"; noff = {}
for n, _, _ in secs[1:]:
    noff[n] = len(names); names += n.encode() + b"\0"
secs[1] = (".shstrtab", names, 0)
shnum, ehsize, shsz = len(secs), 64, 64
body, offs = bytearray(), []
base = ehsize + (shnum * shsz if place == "head" else 0)
for n, data, ent in secs:
    offs.append(base + len(body)); body += data
shoff = ehsize if place == "head" else base + len(body)
eh = bytearray(64)
eh[0:4] = b"\x7fELF"; eh[4] = 2; eh[5] = 1; eh[6] = 1
struct.pack_into("<HHIQQQIHHHHHH", eh, 16, 4, 62, 1, 0, 0, shoff, 0, ehsize, 0, 0, shsz, shnum, 1)
sh = bytearray()
for (n, data, ent), off in zip(secs, offs):
    sh += struct.pack("<IIQQQQIIQQ", noff.get(n, 0), 0 if not n else 1, 0, 0, off if n else 0, len(data) if n else 0, 0, 0, 1, ent)
blob = bytes(eh) + (bytes(sh) + bytes(body) if place == "head" else bytes(body) + bytes(sh))
if trunc:
    # the section table (head placement) stays readable, the prstatus is cut short: a stream that died mid-context
    blob = blob[:offs[3] + 100]
open(out, "wb").write(blob)
PY
}

fails=0
ok(){ echo "ok    $*"; }
bad(){ echo "FAIL  $*"; fails=$((fails+1)); }
run_checks(){
  local place
  for place in head tail; do
    mkcore "$T/core-$place" "$place"
    rm -rf "$T/small-$place"
    if ! python3 tools/xen-core-rip.py "$T/core-$place" --small "$T/small-$place" > "$T/out-$place" 2>&1; then
      bad "$place: --small exited non-zero on a good core: $(tail -2 "$T/out-$place")"; continue; fi
    local r="$T/small-$place/vcpu-regs.txt"
    grep -q '^vcpus=3$' "$r" && ok "$place: 3 vCPUs" || bad "$place: vcpu count"
    grep -q '^vcpu1 .* rax=0xc ' "$r" && ok "$place: vcpu1 rax=0xc (planted memory_op)" || bad "$place: vcpu1 rax not 0xc: $(grep '^vcpu1 ' "$r" | head -1 | cut -c1-160)"
    grep -q '^vcpu1   if in a hypercall: memory_op(decrease_reservation rdi=0x1 rsi=0x52 rdx=0xd1 r10=0x10b r8=0x8b)' "$r" \
      && ok "$place: vcpu1 hypercall decoded with its arguments" || bad "$place: vcpu1 hypercall line: $(grep '^vcpu1   ' "$r")"
    grep -q '^vcpu0 rip=0xfffff80600001000 rsp=0xffffc00000002000 rflags=0x246 cs=0x10 ss=0x18 rax=0xa0 ' "$r" \
      && ok "$place: vcpu0 rip/rsp/rflags/cs/ss/rax" || bad "$place: vcpu0 line: $(grep '^vcpu0 ' "$r" | cut -c1-200)"
    grep -q '^vcpu2 .*cr3=0x1ac000 .*gs_base_kernel=0xfffff80700000002 .*error_code=0xe2 entry_vector=0xf0$' "$r" \
      && ok "$place: vcpu2 cr3, gs_base_kernel, error_code, entry_vector" || bad "$place: vcpu2 line: $(grep '^vcpu2 ' "$r" | cut -c1-260)"
    [ "$(stat -c %s "$T/small-$place/xen_prstatus.bin")" = $((3 * 0x1430)) ] && ok "$place: raw prstatus kept" || bad "$place: prstatus size"
    [ "$(stat -c %s "$T/small-$place/xen_shared_info.bin" 2>/dev/null)" = 4096 ] && ok "$place: shared info kept" || bad "$place: shared info"
    grep -q '^.xen_prstatus ' "$T/small-$place/sections.txt" && ok "$place: section table written" || bad "$place: sections.txt"
  done
  # refusals: an unknown layout and a truncated stream are instrument errors (exit 2), never a decode
  mkcore "$T/core-ent" head 4096
  python3 tools/xen-core-rip.py "$T/core-ent" --small "$T/small-ent" > "$T/out-ent" 2>&1; rc=$?
  [ "$rc" = 2 ] && grep -q 'unexpected .xen_prstatus entsize' "$T/out-ent" && ok "wrong entsize refused (exit 2)" || bad "wrong entsize: rc=$rc"
  mkcore "$T/core-cut" head "" 1
  python3 tools/xen-core-rip.py "$T/core-cut" --small "$T/small-cut" > "$T/out-cut" 2>&1; rc=$?
  [ "$rc" = 2 ] && ok "truncated core refused (exit 2): $(tail -1 "$T/out-cut" | cut -c1-100)" || bad "truncated core: rc=$rc $(tail -1 "$T/out-cut")"
  # where RIP sits decides what RAX means: AT the VMCALL (pending, RAX = op), just AFTER it (returned, RAX = result); a stub's
  # `mov eax, imm32` names the op either way (the synthetic cores have no page tables, so this is checked on the function itself)
  pos=$(python3 - <<'PY'
import importlib.util
s = importlib.util.spec_from_file_location("x", "tools/xen-core-rip.py"); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
# RIP is offset 16 of the 24 bytes (code_around reads RIP-16 .. RIP+8)
at = b"\x90" * 11 + b"\xb8\x0c\x00\x00\x00" + b"\x0f\x01\xc1" + b"\xc3" * 5    # vmcall at 16..18: RIP ON it, stub op 12
aft = b"\x90" * 8 + b"\xb8\x14\x00\x00\x00" + b"\x0f\x01\xc1" + b"\xc3" * 8    # vmcall at 13..15: RIP just after it, stub op 20
amd = b"\x90" * 16 + b"\x0f\x01\xd9" + b"\x90" * 5                         # RIP on a VMMCALL, no stub
none = b"\x90" * 24
for name, code in (("at", at), ("after", aft), ("amd", amd), ("none", none), ("unread", None)):
    p, stub = m.hypercall_position(code)
    print("%s|%s|%s" % (name, p.split(" - ")[0], stub))
PY
)
  printf '%s\n' "$pos" | grep -qx 'at|RIP AT a hypercall instruction|12' && ok "RIP at a VMCALL: pending, stub op 12" || bad "at: $(printf '%s' "$pos" | grep '^at|')"
  printf '%s\n' "$pos" | grep -qx 'after|RIP just AFTER a hypercall instruction|20' && ok "RIP after a VMCALL: returned, stub op 20" || bad "after: $(printf '%s' "$pos" | grep '^after|')"
  printf '%s\n' "$pos" | grep -qx 'amd|RIP AT a hypercall instruction|None' && ok "VMMCALL recognised, no stub" || bad "amd: $(printf '%s' "$pos" | grep '^amd|')"
  printf '%s\n' "$pos" | grep -qx 'none|no hypercall instruction at or just before RIP|None' && ok "no hypercall instruction" || bad "none: $(printf '%s' "$pos" | grep '^none|')"
  printf '%s\n' "$pos" | grep -qx 'unread|code at RIP unreadable|None' && ok "unreadable code said so" || bad "unread: $(printf '%s' "$pos" | grep '^unread|')"
  # mgmt/harness/drop-core.sh: deletes only with the small state on disk (extracting it once if missing); refuses otherwise
  mkcore "$T/dc-a.core" head; python3 tools/xen-core-rip.py "$T/dc-a.core" --small "$T/dc-a.core.small" >/dev/null 2>&1
  bash mgmt/harness/drop-core.sh "$T/dc-a.core" > "$T/dc-a.out" 2>&1
  [ ! -e "$T/dc-a.core" ] && [ -s "$T/dc-a.core.small/vcpu-regs.txt" ] && ok "drop-core: deleted, small state kept" || bad "drop-core with small state: $(cat "$T/dc-a.out")"
  mkcore "$T/dc-b.core" tail
  bash mgmt/harness/drop-core.sh "$T/dc-b.core" > "$T/dc-b.out" 2>&1
  [ ! -e "$T/dc-b.core" ] && [ -s "$T/dc-b.core.small/vcpu-regs.txt" ] && ok "drop-core: extracted the missing small state, then deleted" || bad "drop-core extract: $(cat "$T/dc-b.out")"
  mkcore "$T/dc-c.core" head 4096
  bash mgmt/harness/drop-core.sh "$T/dc-c.core" > "$T/dc-c.out" 2>&1; rc=$?
  [ "$rc" = 1 ] && [ -e "$T/dc-c.core" ] && ok "drop-core: REFUSED an image whose registers cannot be extracted (kept)" || bad "drop-core refusal: rc=$rc $(cat "$T/dc-c.out")"
  echo "checks failed: $fails"
  [ "$fails" = 0 ]
}

if [ -n "${XENCORE_SMALL_DEFECT:-}" ]; then run_checks; exit $?; fi
echo "== clean"
run_checks; clean=$?
echo "== XENCORE_SMALL_DEFECT=1 (rax read 8 bytes off - must FAIL)"
fails=0
dout=$(export XENCORE_SMALL_DEFECT=1; run_checks); drc=$?
printf '%s\n' "$dout" | grep -E '^FAIL|checks failed'
if [ "$clean" = 0 ] && [ "$drc" != 0 ] && printf '%s\n' "$dout" | grep -q 'FAIL  head: vcpu1 rax not 0xc'; then
  echo "PASS  clean leg passes, the defect knob fails the planted-register checks"; exit 0
fi
echo "FAIL  clean=$clean defect_rc=$drc"; exit 1
