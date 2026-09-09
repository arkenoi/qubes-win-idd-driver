#!/bin/bash
# HOW OFTEN DOES THE UPGRADE CELL STALL, AND DOES IT STALL IN THE SAME PLACE?
#
# One stall and one clean pass is not a rate. This runs the win10-upgrade cell N times against ONE
# unchanged package and records, per run: the verdict, whether the installer reported ok:true, how
# long after the install the harness declared the guest "back" (the t+0s tell), whether the
# post-install log fetch came back, and whether the guest was left answering qrexec.
#
# WHY THE t+0s COLUMN IS THE POINT. matrix.sh honours the installer's "caller must reboot" contract
# only `if ! w_alive`, so on the normal path it SKIPS the reboot and grades the pre-reboot session.
# The guest then reboots itself underneath the harness. That is a race, so the interesting number is
# not "did it fail" but "how often did the guest's own reboot land inside the harness's next call".
#
# Run it with the harness UNPATCHED to get the baseline rate, then with the reboot-contract fix to
# see whether the fix removes the stall. Same package both times or the comparison means nothing.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

N="${N:-3}"
W="${W:?set W to the acceptance work dir holding dl/}"
OUT="${OUT:-/home/user/rel/upgrade-repeat-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"
say(){ echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$OUT/summary.log"; }

say "=== upgrade-repeat: $N runs, package $W ==="
say "harness reboot-contract fix present: $(grep -qc 'THE REBOOT IS UNCONDITIONAL' mgmt/harness/matrix.sh 2>/dev/null && echo YES || echo no)"

for r in $(seq 1 "$N"); do
  # Every run starts from an idle rig, or prime/reclone refuses and the run measures contention.
  for vm in $(qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' '$1 ~ /^win1/ && $2!="Halted"{print $1}'); do
    qvm-shutdown --wait --timeout 180 "$vm" >/dev/null 2>&1 || qvm-kill "$vm" >/dev/null 2>&1
  done
  L="$OUT/run$r.log"
  say "--- run $r/$N"
  MATRIX_WORK="$W" RELEASE_SETUP="$W/dl/qwt-improved-setup" \
    RELEASE_ISO="$W/dl/qwt-improved-iso/qwt-improved-setup.iso" \
    CELLS="win10-upgrade" G10=win10-iqi MATRIX_OUT="$OUT/m$r" \
    ./mgmt/harness/matrix.sh >"$L" 2>&1
  rc=$?

  verdict=$(grep -a '=== MATRIX:' "$L" | tail -1)
  okline=$(grep -ac 'install reported a RESULT' "$L")
  backgap=$(awk '/RESULT line present at/{split($1,a,"[][]"); t1=a[2]} /-back: session up at/{split($1,b,"[][]"); print t1" -> "b[2]; exit}' "$L")
  fetch=$(grep -ac 'fetch attempt' "$L")
  fetched=$(if [ -s "$OUT/m$r/WIN10-upgrade-final.log" ]; then stat -c%s "$OUT/m$r/WIN10-upgrade-final.log"; else echo 0; fi)
  noqrexec=$(grep -ac 'did not answer qrexec' "$L")
  state=$(qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' '$1=="win10-acc"{print $2}')

  say "  run $r: rc=$rc | $verdict"
  say "    install-reported-RESULT=$okline  back-gap=${backgap:-n/a}  fetch-retries=$fetch  final.log=${fetched}B  no-qrexec=$noqrexec  guest=$state"
done

say "=== done. per-run logs in $OUT ==="
