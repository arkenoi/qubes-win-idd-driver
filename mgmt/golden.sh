#!/bin/bash
# Golden image custody: SEAL a golden, VERIFY it has not been touched, and refuse to let a
# campaign clone from one that has.
#
# WHY THIS EXISTS (owner, 2026-08-30: "make fucking normal goldens, RECORD IT, PROHIBIT ANY
# MODIFICATIONS"). Every install cell reclones from a golden, so a golden's state is inherited by
# every clone made from it - which means a single careless boot contaminates an entire campaign
# silently. On 2026-08-29/30 the Win10 golden was used all evening as a scratch guest: agent binary
# hot-swapped twice, xencons side-loaded by hand, `debug` toggled, Windows Update enabled and then
# disabled, private volume extended mid-life, repeated hard kills. Cells were then cloned from it.
# Nothing in the harness noticed, because nothing was ever recorded to notice against.
#
# THE RULE, and it is absolute: a golden is SEALED, and after sealing it is CLONED, never started,
# never logged into, never "just checked". Diagnostic work belongs on a churn qube. A golden that
# has been booted is not a golden any more, whatever its name says - re-seal it deliberately or
# rebuild it, but never quietly keep using it.
#
# HOW THE TAMPER SIGNAL WORKS. Qubes cuts a root-volume REVISION on every clean shutdown, so a
# golden that gets started and stopped acquires a revision its seal never recorded. Volume size,
# and the qube properties that decide how a clone behaves, are recorded alongside. Verification is
# therefore cheap and needs no boot - which matters, because booting a golden to check it would
# itself be the modification we are trying to forbid.
#
#   mgmt/golden.sh seal   <vm> [note]   - record the current state as the sealed state
#   mgmt/golden.sh verify <vm>          - exit 0 if untouched, 2 if drifted (prints what changed)
#   mgmt/golden.sh list                 - show every sealed golden
#
# Seals live in mgmt/goldens/<vm>.json and are COMMITTED: the record has to outlive the session
# that made it, or it is not a record.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
SEALDIR="$HERE/mgmt/goldens"
mkdir -p "$SEALDIR"

_state(){ # $1=vm -> a stable, boot-free fingerprint of the golden
    local vm=$1
    python3 - "$vm" <<'PY'
import subprocess, sys, json
vm = sys.argv[1]
def run(*a):
    try: return subprocess.run(a, capture_output=True, text=True, timeout=60).stdout
    except Exception: return ""
out = {"vm": vm, "volumes": {}, "props": {}}
for v in ("root", "private"):
    info = run("qvm-volume", "info", f"{vm}:{v}")
    d = {}
    for line in info.splitlines():
        p = line.split(None, 1)
        if len(p) == 2 and p[0] in ("size", "usage", "revisions_to_keep"):
            d[p[0]] = p[1].strip()
    # Revisions are the tamper signal: a clean shutdown cuts one, so a booted golden gains a
    # revision its seal never recorded.
    #
    # THEY COME FROM `qvm-volume info`, NOT from a `revisions` subcommand. The first version of
    # this script shelled out to `qvm-volume revisions`, which DOES NOT EXIST in this client
    # (qvm-volume takes info/config/set/resize/extend/list/revert/import/clear). run() swallows
    # the failure and returns "", so every seal written before 2026-08-30 recorded
    # revisions: [] - the signal was dead in all four goldens, and "verified intact" was really
    # only comparing size and properties, neither of which changes when a golden is booted.
    # That is precisely the modification this tool exists to catch, so it caught nothing.
    revs, seen_header = [], False
    for line in info.splitlines():
        if "available revisions" in line.lower():
            seen_header = True
            continue
        if seen_header and line.strip():
            revs.append(line.strip())
    # Fail loudly rather than silently emptying the signal again: a check that cannot fail is
    # worthless, and this one already failed that way once.
    if not seen_header:
        sys.stderr.write(
            f"FATAL: no revision list in `qvm-volume info {vm}:{v}` - the tamper signal cannot "
            f"be read, so this seal would be worthless. Has the qvm-volume output changed?\n")
        sys.exit(3)
    d["revisions"] = sorted(revs)
    out["volumes"][v] = d
for p in ("klass", "virt_mode", "kernel", "memory", "maxmem", "vcpus", "netvm", "template"):
    val = run("qvm-prefs", vm, p).strip()
    if val:
        out["props"][p] = val
print(json.dumps(out, indent=2, sort_keys=True))
PY
}

cmd=${1:-}; vm=${2:-}
case "$cmd" in
  seal)
    [ -n "$vm" ] || { echo "usage: $0 seal <vm> [note]"; exit 1; }
    st=$(qvm-ls --raw-data --fields STATE "$vm" 2>/dev/null | tail -1)
    # Sealing a RUNNING guest would record a state that changes the moment it stops - and a golden
    # should not be running in the first place.
    [ "$st" = "Halted" ] || { echo "REFUSING: $vm is $st. A golden must be Halted to be sealed."; exit 1; }
    tmp=$(mktemp)
    # _state exits 3 when the tamper signal is unreadable. Sealing anyway would write a seal that
    # cannot detect anything - exactly the failure being fixed here.
    _state "$vm" > "$tmp" || { echo "REFUSING to seal $vm: state could not be read"; rm -f "$tmp"; exit 3; }
    python3 - "$tmp" "${3:-}" <<'PY' > "$SEALDIR/$vm.json"
import json, sys, subprocess
d = json.load(open(sys.argv[1]))
d["note"] = sys.argv[2] if len(sys.argv) > 2 else ""
d["sealed_utc"] = subprocess.run(["date","-u","+%Y-%m-%dT%H:%M:%SZ"],
                                 capture_output=True, text=True).stdout.strip()
print(json.dumps(d, indent=2, sort_keys=True))
PY
    rm -f "$tmp"
    echo "SEALED $vm -> mgmt/goldens/$vm.json"
    echo "  From now on: CLONE it. Do not start it, do not log in, do not 'just check'."
    ;;
  verify)
    [ -n "$vm" ] || { echo "usage: $0 verify <vm>"; exit 1; }
    seal="$SEALDIR/$vm.json"
    # An unsealed golden fails CLOSED. "No record" must never read as "unchanged" - that is exactly
    # how the contaminated golden went unnoticed.
    [ -f "$seal" ] || { echo "UNSEALED: no record for $vm - a golden with no seal cannot be trusted"; exit 2; }
    now=$(mktemp)
    _state "$vm" > "$now" || { echo "CANNOT VERIFY $vm: state could not be read"; rm -f "$now"; exit 3; }
    if python3 - "$seal" "$now" <<'PY'
import json, sys
a = json.load(open(sys.argv[1])); b = json.load(open(sys.argv[2]))
drift = []
for v, av in a.get("volumes", {}).items():
    bv = b.get("volumes", {}).get(v, {})
    for k in ("size", "revisions"):
        if av.get(k) != bv.get(k):
            drift.append(f"  {v}.{k}: sealed={av.get(k)} now={bv.get(k)}")
for p, val in a.get("props", {}).items():
    if b.get("props", {}).get(p) != val:
        drift.append(f"  prop {p}: sealed={val} now={b.get('props', {}).get(p)}")
if drift:
    print("DRIFTED:"); [print(d) for d in drift]; sys.exit(2)
print("intact")
PY
    then
        echo "VERIFIED $vm matches its seal (sealed $(python3 -c "import json;print(json.load(open('$seal'))['sealed_utc'])"))"
        rm -f "$now"; exit 0
    else
        echo "REFUSE to clone from $vm: it has been modified since sealing."
        echo "Rebuild it, or re-seal deliberately if the change was intended and recorded."
        rm -f "$now"; exit 2
    fi
    ;;
  list)
    for f in "$SEALDIR"/*.json; do
        [ -e "$f" ] || { echo "(no goldens sealed)"; break; }
        python3 -c "
import json,sys
d=json.load(open('$f'))
print('%-16s sealed %s  %s' % (d['vm'], d['sealed_utc'], d.get('note','')))"
    done
    ;;
  *) echo "usage: $0 {seal|verify|list} <vm> [note]"; exit 1 ;;
esac
