#!/bin/bash
# Drive guest/wedge-provoke.ps1 against a guest, detect the wedge, recover, and recover the
# black box.
#
# WHY A RUNNER AND NOT JUST `qtest run`. The wedge kills qrexec, so the call that started the
# provocation never returns and cannot report anything. A timeout on that call is therefore
# ambiguous by itself - it looks identical to a slow run, a rebooting guest, and a dead one.
# This script resolves the ambiguity from OUTSIDE the guest:
#
#     qube Running + qrexec answers        -> alive, keep waiting
#     qube Running + qrexec dead for N     -> WEDGED (the signature: alive, burning CPU, mute)
#     qube Halted/Transient                -> it rebooted or died; NOT a wedge, and recorded
#                                             as a distinct outcome rather than folded in
#
# That distinction is the entire value of the harness. Both field occurrences were "Running,
# CPU busy, nothing answering", and treating a reboot as the same event would poison the A/B
# it exists to feed.
#
# Usage:
#   tools/wedge-hunt.sh <vm> [minutes] [runs] [extra-provoke-args...]
#
# Example - hunt on .15, then fire the identical provocation at .13:
#   tools/wedge-hunt.sh win10-clean 15 5
#   tools/wedge-hunt.sh win10-clean-13 15 5
set -uo pipefail

VM="${1:?usage: $0 <vm> [minutes] [runs] [extra args]}"
MINUTES="${2:-15}"
RUNS="${3:-3}"
shift 3 2>/dev/null || shift $#
EXTRA=("$@")

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QTEST="$REPO/tools/qtest"
OUT="${WEDGE_OUT:-$REPO/evidence/wedge-hunt-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"

# How long qrexec must stay dead before we call it a wedge rather than a slow moment. A
# Windows guest under the MM pressure this harness applies genuinely can take tens of seconds
# to answer, so a short threshold would manufacture wedges out of load. 120 s is well past
# anything observed on a healthy loaded guest here.
DEAD_THRESHOLD="${DEAD_THRESHOLD:-120}"

log(){ echo "[$(date +%H:%M:%S)] $*" | tee -a "$OUT/hunt.log"; }

state(){ qvm-ls --raw-data --fields STATE "$VM" 2>/dev/null | tail -1; }

# A cheap liveness probe. Deliberately NOT the provocation call: we need something that can
# time out fast and be retried, independent of the long-running job.
alive(){
	timeout 25 "$QTEST" run "echo alive" --vm "$VM" >/dev/null 2>&1
}

log "hunting on $VM: $RUNS run(s) x ${MINUTES}min, extra=${EXTRA[*]:-none}"
log "output: $OUT"

WEDGES=0
for run in $(seq 1 "$RUNS"); do
	log "=== run $run/$RUNS ==="

	st=$(state)
	if [ "$st" != "Running" ]; then
		log "  $VM is $st - starting"
		"$QTEST" start --vm "$VM" >>"$OUT/hunt.log" 2>&1
		sleep 20
	fi
	if ! alive; then
		log "  qrexec not answering BEFORE the run started - aborting this run (a guest that is"
		log "  already sick cannot measure a provocation)"
		continue
	fi

	# Fresh heartbeat per run, so a wedge cannot be attributed to a previous run's tail.
	HB="C:\\wedge-provoke-heartbeat.log"
	"$QTEST" push "$REPO/guest/wedge-provoke.ps1" --vm "$VM" >>"$OUT/hunt.log" 2>&1

	log "  launching provocation (detached - the call must not die with the guest)"
	# Detached on the guest side: if we held the qrexec call open, the wedge would kill our
	# only channel AND the job at once, and we would learn nothing about how far it got.
	"$QTEST" run "powershell -ep bypass -c \"Start-Process powershell -WindowStyle Hidden -ArgumentList '-ep','bypass','-f','C:\\QubesIncoming\\wedge-provoke.ps1','-Minutes','$MINUTES' ${EXTRA[*]:+,'${EXTRA[*]}'}\"" \
		--vm "$VM" >>"$OUT/hunt.log" 2>&1

	# --- watch ---------------------------------------------------------------------
	deadline=$(( $(date +%s) + MINUTES * 60 + 120 ))
	dead_since=0
	outcome="SURVIVED"
	while [ "$(date +%s)" -lt "$deadline" ]; do
		sleep 20
		st=$(state)
		if [ "$st" != "Running" ]; then
			log "  state=$st -> guest left Running. NOT a wedge (a wedge stays Running)."
			outcome="REBOOTED_OR_DIED:$st"
			break
		fi
		if alive; then
			[ "$dead_since" -ne 0 ] && log "  qrexec recovered after $(( $(date +%s) - dead_since ))s"
			dead_since=0
		else
			now=$(date +%s)
			[ "$dead_since" -eq 0 ] && { dead_since=$now; log "  qrexec stopped answering"; }
			gone=$(( now - dead_since ))
			if [ "$gone" -ge "$DEAD_THRESHOLD" ]; then
				log "  *** WEDGE: Running but qrexec dead ${gone}s (>= ${DEAD_THRESHOLD}s) ***"
				outcome="WEDGED"
				break
			fi
		fi
	done

	log "  outcome: $outcome"
	echo "run=$run outcome=$outcome vm=$VM minutes=$MINUTES extra=${EXTRA[*]:-none}" >>"$OUT/outcomes.txt"

	if [ "$outcome" = "WEDGED" ]; then
		WEDGES=$((WEDGES+1))
		log "  recovering: kill + start (the guest cannot be shut down cleanly when wedged)"
		"$QTEST" kill --vm "$VM" >>"$OUT/hunt.log" 2>&1
		sleep 15
		"$QTEST" start --vm "$VM" >>"$OUT/hunt.log" 2>&1
		# Give it a real boot budget: this guest was just hard-killed.
		for _ in $(seq 1 30); do sleep 20; alive && break; done
	fi

	# Pull the black box whatever the outcome - a SURVIVED run's heartbeat is the control
	# that proves the provocation actually ran (MM_RUNNING, cycles counted) rather than
	# silently doing nothing, which is the failure mode that would make a clean .13 result
	# meaningless.
	if alive; then
		"$QTEST" run "powershell -ep bypass -c \"Get-Content -Raw '$HB'\"" --vm "$VM" \
			> "$OUT/heartbeat-run$run.txt" 2>>"$OUT/hunt.log"
		tail=$(tail -3 "$OUT/heartbeat-run$run.txt" 2>/dev/null | tr -d '\r')
		log "  heartbeat tail:"; echo "$tail" | sed 's/^/      /' | tee -a "$OUT/hunt.log"
	else
		log "  guest still unreachable - heartbeat NOT retrieved for run $run"
	fi
done

log "=== $WEDGES wedge(s) in $RUNS run(s) on $VM ==="
log "outcomes: $OUT/outcomes.txt"
exit 0
