#!/bin/bash
# One boot-phase measurement for the fair two-boot netvm test
# (SESSION-HANDOFF-qwt-full.md "MANDATORY next experiment" / fair-retest).
# Polls domain cputime and qrexec every 20 s, appending CSV to the log; exits 0 the
# moment qrexec answers, 1 on timeout. GRACEFUL transitions only are done by the CALLER
# (qtest shutdown / in-guest shutdown /r) — this script only watches.
#
#   tools/netvm-bootwatch.sh <label> [max-seconds=900]
# Log: instrumentation/qwtfull-w10/netvm-<label>.csv  (elapsed_s,cputime_ns,delta_cores,qrexec)
set -uo pipefail
LABEL="${1:?usage: $0 <label> [max-seconds]}"
MAX="${2:-900}"
VM="${QTEST_VM:-win-idd-test}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$HERE/instrumentation/qwtfull-w10/netvm-$LABEL.csv"
mkdir -p "$(dirname "$OUT")"

state() { qrexec-client-vm "$VM" admin.vm.CurrentState </dev/null 2>/dev/null | tr -d '\0'; }
cput() { state | grep -oE 'cputime=[0-9]+' | cut -d= -f2; }
probe() { timeout 15 bash -c "printf 'echo QOK\r\n' | qrexec-client-vm $VM qubes.VMShell 2>/dev/null" | grep -q QOK && echo up || echo down; }

echo "elapsed_s,cputime_ns,delta_cores,qrexec" >> "$OUT"
t0=$(date +%s); prev_c=$(cput); prev_t=$t0
echo "== netvm-bootwatch '$LABEL' vm=$VM max=${MAX}s -> $OUT =="
while :; do
    sleep 20
    now=$(date +%s); el=$((now - t0))
    c=$(cput); q=$(probe)
    if [[ -n "$c" && -n "$prev_c" ]]; then
        # cores burned since last sample (cputime is ns)
        d=$(awk -v a="$c" -v b="$prev_c" -v s=$((now - prev_t)) 'BEGIN{ if(s>0) printf "%.2f", (a-b)/1e9/s; else print "0" }')
    else d="?"; fi
    echo "$el,${c:-?},$d,$q" | tee -a "$OUT"
    prev_c="$c"; prev_t=$now
    [[ "$q" == up ]] && { echo "QREXEC UP at ${el}s"; exit 0; }
    (( el >= MAX )) && { echo "TIMEOUT at ${el}s, qrexec never answered"; exit 1; }
done
