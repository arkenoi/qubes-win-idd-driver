# wedge-lib.sh - ONE definition of "is this guest wedged", and it is the measurement that works.
#
# WHY THIS EXISTS. Every harness here grew its own spin oracle from `admin.vm.Stats` cpu_time:
# "unreachable AND cpu_time not flat" = the spin. CALIBRATED 2026-09-23 on win10-acc, 20 s samples:
#     idle, healthy .................  9,865  and  44,540
#     PEGGED (4-thread storm) ....... 130,976
#     unreachable, all vCPUs blocked .  96,262
#     a run graded "STALLED (SPINNING)" 132,323
# A pegged guest and an idle unreachable one are INDISTINGUISHABLE in that counter, so every
# verdict built on it - in my harnesses AND in quick-upgrade's stall branch - was unsound in both
# directions. Worse, one hand-rolled reader called qubesadmin's get_cputime, which does not exist
# on this toolstack: it swallowed the exception, returned 0 twice, and could never fire at all.
#
# WHAT ACTUALLY DISCRIMINATES is what the dom0 forensics service already samples: `xl vcpu-list`
# twice, seconds per vCPU. The 2026-09-23 specimen showed vcpu1 at +10.0 s over a 10 s window
# (100 % of a core) while the others did not move; the recorded 2026-09-22 reference shows the
# same shape on two vCPUs. That is the fingerprint, and it is a RATE, not "not flat".
#
# So the check and the capture are ONE action: if the guest is unreachable, capture, then decide
# from the capture. That also means a real wedge is always captured before anything is decided -
# which is what was missing when a campaign recloned a specimen out from under the investigation.
#
#   wedge_classify <vm> <outdir>   -> echoes "SPIN <max-core-fraction>" | "BLOCKED <frac>" |
#                                     "UNREADABLE -"; artefacts land in <outdir>
#   Returns 0 for SPIN, 1 for BLOCKED, 2 for UNREADABLE (never treat 2 as healthy).
SPIN_FRACTION="${SPIN_FRACTION:-0.5}"   # of one core, over the interval between the two samples

wedge_classify(){
  local vm="$1" out="$2" t0
  mkdir -p "$out"
  t0=$(date +%s)
  if ! timeout 300 qrexec-client-vm dom0 "local.WinWedgeForensics+$vm" </dev/null \
        > "$out/forensics.tar" 2>"$out/forensics.err"; then
    echo "UNREADABLE -"; return 2
  fi
  tar xf "$out/forensics.tar" -C "$out" 2>/dev/null
  # THE DATA DOES NOT COME BACK ON STDOUT. The dom0 service streams only its capture.log there and
  # DELIVERS the artefacts with qvm-copy, so they land in ~/QubesIncoming/dom0 - extracting the
  # stdout tar alone yields capture.log and nothing else, which read as UNREADABLE on a perfectly
  # good capture (measured 2026-09-23, the first time this helper ran).
  # ONLY a bundle delivered by THIS capture: "the newest one there" picked a 2026-09-25 bundle on 2026-10-04 (the service now
  # returns everything on stdout and copies nothing), unpacked beside this capture, so a classify could read a stale specimen.
  local newest
  newest=$(find "$HOME/QubesIncoming/dom0" -maxdepth 1 -name 'wedge-*.tar.gz' -newermt "@$t0" -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
  [ -n "$newest" ] && tar xzf "$newest" -C "$out" 2>/dev/null
  local d=""
  [ -s "$out/vcpu-list-1.txt" ] && d="$out"
  [ -n "$d" ] || d=$(find "$out" -mindepth 2 -maxdepth 2 -name 'vcpu-list-1.txt' -newermt "@$t0" -printf '%h\n' 2>/dev/null | head -1)
  [ -n "$d" ] || { echo "UNREADABLE -"; return 2; }
  # The service samples vcpu-list twice about 10 s apart; compare per-vCPU seconds.
  python3 - "$d" "$SPIN_FRACTION" <<'PY'
import re, sys, os
d, frac = sys.argv[1], float(sys.argv[2])
def read(p):
    out = {}
    try:
        for line in open(p):
            m = re.search(r'\s(\d+)\s+(\d+)\s+[-rb]{3}\s+([0-9.]+)\s', line)
            if m:
                out[int(m.group(1))] = float(m.group(3))
    except OSError:
        pass
    return out
a, b = read(os.path.join(d, 'vcpu-list-1.txt')), read(os.path.join(d, 'vcpu-list-2.txt'))
if not a or not b:
    print("UNREADABLE -"); sys.exit(2)
# The interval is not recorded by the service, so derive it from the LARGEST delta seen: a
# spinning vCPU consumes one core-second per wall second, which bounds the interval from below.
deltas = {v: b.get(v, a[v]) - a[v] for v in a}
top = max(deltas.values()) if deltas else 0.0
# The service's two samples are ~10 s apart (it sleeps between them).
interval = float(os.environ.get("WEDGE_SAMPLE_SECS", "10"))
f = top / interval if interval else 0.0
print(("SPIN %.2f" % f) if f >= frac else ("BLOCKED %.2f" % f))
sys.exit(0 if f >= frac else 1)
PY
}
