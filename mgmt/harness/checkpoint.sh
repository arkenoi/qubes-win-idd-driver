#!/bin/bash
# Subject checkpoints: restore points in SECONDS instead of a 17-20 min reprovision. Owner
# directive 2026-09-01: "avoid unnecessary long reprovisioning, save snapshots as checkpoints
# and revert."
#
# TWO VERBS, deliberately distinct (a first draft had a "checkpoint" that recorded the state of
# ONE SESSION AGO because lvm -back revisions hold a volume's content as of the START of the
# session that ended at that shutdown - its own proof run only passed because the last session
# wrote nothing; that verb is gone):
#
#   park / unpark    PLAN-AHEAD checkpoint. Thin volume clone of the CURRENT halted state into a
#                    storage qube ckpt-<vm>-<label> (never booted). Exact, durable, measured
#                    1.6-1.9 s per direction on this pool. Costs pool space as content diverges -
#                    remove parks at campaign end.
#   undo-session     POST-HOC restore, no planning needed. Reverts root+private to their latest
#                    clean-shutdown revision = the state the LAST COMPLETED SESSION STARTED from.
#                    This is the G-0b tool: a cell boots, mutates, FAILS, halts -> undo-session
#                    puts the subject back at the cell's entry state. Measured: 2 s revert,
#                    19 s boot-to-qrexec after; a marker written in the undone session was GONE,
#                    one written before it SURVIVED (validated probe, no-revert control).
#                    LIMITS, measured: revisions_to_keep=2 and admin.vm.volume.Set is
#                    policy-refused, so at most the last two sessions are undoable; each further
#                    clean shutdown (a diagnostic boot!) burns one. Park before diagnosing.
#
# R3 (reprovision-usb.sh) remains warranted for EXACTLY ONE thing: the cell testing
# Windows-install-plus-QWT-at-first-logon. Everything else parks, undoes, or reclones.
#
# NOT FOR GOLDENS: a sealed golden's tamper signal IS its revision list (golden.sh); refused.
#
#   checkpoint.sh park         <vm> <label>
#   checkpoint.sh unpark       <vm> <label>
#   checkpoint.sh undo-session <vm>
#   checkpoint.sh list         <vm>
#
# Exits: 0 done; 1 the restore is impossible (park missing / revisions unusable) - caller
# decides (reclone, or R3 if truly the install-at-first-logon cell); 2 misuse/refusal (running
# vm, golden, mismatched revision epochs). Refusals are LOUD: a checkpoint that silently
# restores the wrong state is worse than none.
set -uo pipefail
cd "$(dirname "$0")/../.."
. mgmt/harness/vmlock.sh
RDIR=mgmt/checkpoints
mkdir -p "$RDIR"

die(){ echo "REFUSE: $*" >&2; exit 2; }
vm_state(){ qvm-ls --raw-data --fields NAME,STATE | grep "^$1|" | cut -d'|' -f2; }
latest_rev(){ qvm-volume info "$1:$2" 2>/dev/null | sed -n '/available revisions/,$p' | tail -n +2 | tr -d ' ' | tail -1; }

CMD="${1:?usage: checkpoint.sh park|unpark|undo-session|list <vm> [label]}"
VM="${2:?<vm> required}"
[ -f "mgmt/goldens/$VM.json" ] && die "$VM is a SEALED GOLDEN - its revision list is its tamper signal (golden.sh); checkpointing or reverting it would desync the seal. Clone a subject from it instead."

case "$CMD" in
  park)
    LABEL="${3:?<label> required}"
    vm_lock "$VM"
    st=$(vm_state "$VM"); [ "$st" = "Halted" ] || die "$VM is $st - halt first so the park is a settled state"
    CK="ckpt-$VM-$LABEL"
    qvm-ls --raw-data --fields NAME | grep -qx "$CK" && die "park $CK already exists - qvm-remove it first if you mean to replace it"
    qvm-create --class StandaloneVM --label gray --property virt_mode=hvm --property kernel='' "$CK" || die "create $CK failed"
    qvm-tags "$CK" add win-idd-testbed || die "tag $CK failed"
    python3 - "$VM" "$CK" <<'EOF' || die "volume clone into park failed"
import sys, qubesadmin
app = qubesadmin.Qubes(); src = app.domains[sys.argv[1]]; dst = app.domains[sys.argv[2]]
for v in ('root','private'): dst.volumes[v].clone(src.volumes[v])
EOF
    printf '{"vm":"%s","label":"%s","kind":"park","park_qube":"%s","utc":"%s"}\n' \
      "$VM" "$LABEL" "$CK" "$(date -u +%FT%TZ)" > "$RDIR/$VM-$LABEL.park.json"
    echo "PARKED $VM/$LABEL -> $CK (storage only - NEVER boot it). Remove at campaign end: qvm-remove $CK"
    ;;
  unpark)
    LABEL="${3:?<label> required}"
    vm_lock "$VM"
    st=$(vm_state "$VM"); [ "$st" = "Halted" ] || die "$VM is $st - halt before unparking"
    CK="ckpt-$VM-$LABEL"
    if ! qvm-ls --raw-data --fields NAME,STATE | grep -q "^$CK|Halted"; then
      echo "UNRESTORABLE: park $CK missing (or not Halted). Reclone the subject from its entry image instead." >&2
      exit 1
    fi
    python3 - "$CK" "$VM" <<'EOF' || die "volume clone back from park failed"
import sys, qubesadmin
app = qubesadmin.Qubes(); src = app.domains[sys.argv[1]]; dst = app.domains[sys.argv[2]]
for v in ('root','private'): dst.volumes[v].clone(src.volumes[v])
EOF
    echo "UNPARKED $VM from $CK. Boot and re-assert the state your cell depends on - a restore returns volumes, not your assumptions."
    ;;
  undo-session)
    vm_lock "$VM"
    st=$(vm_state "$VM"); [ "$st" = "Halted" ] || die "$VM is $st - halt it first (undo-session reverts to the last completed session's entry state)"
    r=$(latest_rev "$VM" root); p=$(latest_rev "$VM" private)
    if [ -z "$r" ] || [ -z "$p" ]; then
      echo "UNRESTORABLE: $VM has no clean-shutdown revision (never booted, or revisions consumed). Reclone from the entry image." >&2
      exit 1
    fi
    re=${r%-back}; pe=${p%-back}
    d=$((re>pe ? re-pe : pe-re))
    [ "$d" -le 30 ] || die "root and private latest revisions are from DIFFERENT sessions (${d}s apart: $r vs $p) - reverting them together would mix states. Investigate before undoing."
    qvm-volume revert "$VM:root" "$r"    || die "revert of $VM:root to $r failed"
    qvm-volume revert "$VM:private" "$p" || die "revert of $VM:private to $p failed"
    echo "UNDONE: $VM is back at the entry state of its last completed session (root=$r private=$p)."
    echo "Boot and re-assert the state your cell depends on. NOTE: at most one more undo-session is possible (revisions_to_keep=2); park before diagnostic boots."
    ;;
  list)
    shown=0
    for f in "$RDIR/$VM-"*.park.json; do
      [ -f "$f" ] || continue
      shown=1
      python3 - "$f" <<'EOF'
import json, subprocess, sys
d = json.load(open(sys.argv[1]))
rc = subprocess.run(["qvm-ls","--raw-data","--fields","NAME"],capture_output=True,text=True)
ok = d["park_qube"] in rc.stdout.split()
print(f'{d["vm"]}/{d["label"]}  park -> {d["park_qube"]}  {"RESTORABLE" if ok else "PARK QUBE MISSING"}  ({d["utc"]})')
EOF
    done
    r=$(latest_rev "$VM" root)
    [ -n "$r" ] && echo "$VM  undo-session target: $r (last completed session's entry state)" || echo "$VM  undo-session: unavailable (no clean-shutdown revision)"
    [ "$shown" = 1 ] || echo "$VM  no parks"
    ;;
  *) die "unknown command $CMD" ;;
esac
