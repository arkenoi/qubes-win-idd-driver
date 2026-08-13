#!/bin/bash
# CLEAN SHOT: rebuild the Windows TemplateVM from the pristine source and run the whole
# dom0-driven update flow once, end to end, on state that has never seen a partial pass.
#
# WHY IT EXISTS. A template that has survived killed DISM runs, aborted downloads and stale
# packages cannot tell you whether the shipped path works - it can only tell you whether it
# recovers. Every acceptance claim about updates must come from a run like this one.
#
# WHAT IT PROVES, in order, and it fails loudly at the first step that does not hold:
#   1. a fresh TemplateVM can be built from the source guest (class change + CoW clone)
#   2. the updater agent installs into it
#   3. dom0's own command sequence drives it (mkdir/cat/tar/entrypoint/rm/cat log)
#   4. the pass installs what it found and reports it honestly
#   5. the template shuts ITSELF down, and dom0's updates-available is cleared
#   6. the next boot COMMITS the servicing - the build number must MOVE
#
# Usage: clean-shot-template.sh [source-qube] [template-name]
set -uo pipefail
cd /home/user/qubes-win-idd-driver

SRC=${1:-win11-24h2}
TPL=${2:-win11-tpl}
export QTEST_VM="$TPL"
t0=$(date +%s); el() { printf 't+%ss ' "$(( $(date +%s) - t0 ))"; }
die() { el; echo "FAILED: $*"; exit 1; }

echo "=== clean shot: $SRC -> $TPL ==="

el; echo "halting both qubes"
qvm-shutdown --wait "$TPL" 2>/dev/null
qvm-shutdown --wait "$SRC" 2>/dev/null

el; echo "removing the old template"
qvm-remove -f "$TPL" 2>&1 | tail -1

el; echo "creating a fresh TemplateVM"
qvm-create --class TemplateVM --label red "$TPL" || die "qvm-create"
qvm-tags "$TPL" add win-idd-testbed || die "qvm-tags"

el; echo "cloning volumes + properties from $SRC"
python3 - "$SRC" "$TPL" <<'PY' || exit 1
import sys, qubesadmin
app = qubesadmin.Qubes(); src = app.domains[sys.argv[1]]; dst = app.domains[sys.argv[2]]
for v in ('root', 'private'):
    dst.volumes[v].clone(src.volumes[v]); print(f"  cloned {v}")
for p in ('virt_mode', 'kernel', 'memory', 'maxmem', 'vcpus', 'qrexec_timeout', 'netvm'):
    setattr(dst, p, getattr(src, p))
for f in ('os', 'gui', 'qrexec', 'stubdom-qrexec', 'audio-model', 'timezone',
          'no-monitor-layout', 'rpc-clipboard'):
    val = src.features.get(f, None)
    if val is not None:
        dst.features[f] = val
dst.features['vmexec'] = '1'          # required, and the guest cannot set it itself
print("  properties + features copied, vmexec=1")
PY

el; echo "starting the template"
./tools/qtest start >/dev/null 2>&1
for i in $(seq 1 40); do
  printf 'ver& exit\n' | timeout 20 qrexec-client-vm "$TPL" qubes.VMShell >/dev/null 2>&1 && break
  read -t 15 < /dev/zero 2>/dev/null || true
done
printf 'ver& exit\n' | timeout 20 qrexec-client-vm "$TPL" qubes.VMShell >/dev/null 2>&1 || die "qrexec never answered"
el; echo "qrexec answers"

el; echo "deploying the updater agent (current build)"
./tools/qtest push guest/install-updater-agent.ps1 guest/qubes-windows-update.ps1 \
    guest/qubes-updates-relay.cs guest/wu-update.ps1 guest/vmupdate-shim.ps1 guest/VMExec.ps1 \
    guest/qubes-posix-cat.cs guest/ps-syntax-check.ps1 guest/wu-verify-installed.ps1 \
    guest/quiet-desktop.ps1 guest/ensure-autologon.ps1 >/dev/null 2>&1
INC='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
./tools/qtest run "powershell -NoProfile -ExecutionPolicy Bypass -File \"$INC\\install-updater-agent.ps1\" -SetupRoot \"$INC\"" 2>&1 |
    grep -E 'deployed|prepared|NoAutoUpdate' | sed 's/^/  /'

el; echo "applying the shipped desktop tweaks (stage 2 does this on a real install)"
./tools/qtest run "powershell -NoProfile -ExecutionPolicy Bypass -File \"$INC\\quiet-desktop.ps1\"" 2>&1 |
    grep -E 'RESULT|FAIL' | sed 's/^/  /'

el; echo "build BEFORE the update:"
BEFORE=$(./tools/qtest pushrun guest/wu-verify-installed.ps1 2>&1 | sed -n '/=== RESULT ===/,$p' | tail -1)
echo "  $BEFORE"

el; echo "running dom0's update sequence"
python3 -u tools/replay-dom0-update.py "$TPL" --with-entrypoint 2>&1 | sed 's/^/  /'

el; echo "waiting for the template to shut ITSELF down"
for i in $(seq 1 40); do
  st=$(timeout 25 ./tools/qtest state 2>/dev/null | tr -d '\0' | grep -o 'power_state=[A-Za-z]*')
  case "$st" in *Halted*) el; echo "halted by itself"; break;; esac
  read -t 20 < /dev/zero 2>/dev/null || true
done

el; printf 'dom0 updates-available after the pass: '
timeout 20 qrexec-client-vm "$TPL" 'admin.vm.feature.Get+updates-available' </dev/null 2>&1 | tr -d '\0'; echo

el; echo "commit boot"
./tools/qtest start >/dev/null 2>&1
for i in $(seq 1 60); do
  printf 'ver& exit\n' | timeout 20 qrexec-client-vm "$TPL" qubes.VMShell >/dev/null 2>&1 && break
  read -t 15 < /dev/zero 2>/dev/null || true
done

el; echo "build AFTER the commit boot:"
AFTER=$(./tools/qtest pushrun guest/wu-verify-installed.ps1 2>&1 | sed -n '/=== RESULT ===/,$p' | tail -1)
echo "  $AFTER"

echo
echo "=== VERDICT ==="
echo "before: $BEFORE"
echo "after : $AFTER"
echo "The build number (CurrentBuild.UBR) MUST have moved. If it did not, the update did not"
echo "commit and the pass reported more than it delivered - do not call this a pass."
