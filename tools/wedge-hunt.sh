#!/bin/bash
# Reproduce the wedge on demand by driving its PROVEN trigger, detect it from outside the
# guest, recover safely, and record the result.
#
# ============================ WHAT THE TRIGGER ACTUALLY IS ============================
# Read the 2026-08-20 FINDINGS entry before changing anything here. The mechanism is proven
# end to end from an armed NMI dump (MEMORY.DMP sha256 4BF9…E554), not hypothesised:
#
#   1. Each qrexec bridge process (qrexec-client-vm / qrexec-wrapper) maps a vchan/grant
#      shared region into its USER address space, locked and secured via libvchan/xeniface
#      gnttab.
#   2. On process EXIT that mapping is destroyed:
#        MmUnmapLockedPages -> MiUnmapLockedPagesInUserSpace -> MiRemoveSecureEntry
#        -> MiDeleteVad -> MiDeletePagablePteRange -> MiDeleteVaTail -> KeFlushMultipleRangeTb
#   3. That issues a SINGLE-TARGET TLB shootdown. Live spin caught at
#      nt!KeFlushMultipleRangeTb+0x13e (a `pause`), with _KPRCB.PacketBarrier=1 TargetCount=1:
#      one target vCPU, which never acknowledges. Windows' HvlLongSpinCount enlightenment
#      tries to hypercall the hypervisor to schedule the stuck vCPU; under Xen HVM that
#      rescue does not land, so the spin is forever.
#   4. At freeze time the guest held 38 concurrent qrexec-client-vm processes. Churn is the
#      VOLUME driver: more short-lived grant-mapping processes exiting = more shootdowns =
#      more chances for one to hang.
#
# So the provocation is PROCESS CHURN of qrexec bridges - specifically their EXIT. It is not
# generic memory pressure: ordinary VirtualAlloc/free never maps a secured grant region and
# never takes that path. An earlier version of this harness pushed heap churn inside the
# guest and would have produced a confident null result.
#
# HISTORY THAT MATTERS. This is the same fault that killed the Windows updater path until the
# relay was rewritten to multiplex: per-fetch qrexec spawning made it "die pretty quickly"
# (owner). The multiplexer removed the RELAY's churn, which is why that path recovered - but
# it only removed one PRODUCER. Every qrexec service call still spawns a process that maps a
# grant and unmaps it on exit, so the trigger is still present system-wide. That is the most
# likely reason the wedge still shows up "often enough to be annoying" with no code change
# between builds to explain it: our own acceptance testing is now a heavy churn source.
#
# ==================================== DETECTION ======================================
# The wedge kills qrexec, so the call that provoked it cannot report it. Judge from OUTSIDE:
#
#     Running + qrexec answers        -> alive
#     Running + qrexec mute >= N sec  -> WEDGED   (alive, burning CPU, deaf: the signature)
#     not Running                     -> rebooted/died: a DIFFERENT outcome, recorded as such
#
# Folding a reboot into "wedge" would poison the very A/B this feeds.
#
# Usage:
#   tools/wedge-hunt.sh <vm> [minutes] [soakers]
#
# Example - establish a rate on .15, then fire the identical provocation at the ORIGINAL .13:
#   tools/wedge-hunt.sh win10-clean 20 6
set -uo pipefail

VM="${1:?usage: $0 <vm> [minutes] [soakers]}"
MINUTES="${2:-20}"
# 4 soakers is what produced the captured dump; 6 gives headroom without being absurd. Each
# soaker is a serial loop, so this is the concurrency of bridge processes, not a rate cap.
SOAKERS="${3:-6}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QTEST="$REPO/tools/qtest"
export QTEST_VM="$VM"          # qtest reads the target from the environment, not a flag
OUT="${WEDGE_OUT:-$REPO/evidence/wedge-hunt-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"

DEAD_THRESHOLD="${DEAD_THRESHOLD:-120}"   # seconds of silence before calling it a wedge
STOP="$OUT/.stop"

log(){ echo "[$(date +%H:%M:%S)] $*" | tee -a "$OUT/hunt.log"; }
state(){ qvm-ls --raw-data --fields STATE "$VM" 2>/dev/null | tail -1; }
alive(){ timeout 30 "$QTEST" run "echo alive" >/dev/null 2>&1; }

# --- recovery -------------------------------------------------------------------------
# A wedged guest cannot be shut down cleanly (it never sees ACPI - the 2026-08-29 dm log
# shows no SHUTDOWN event at all), so recovery is kill+start. The drain is not optional:
# queued qrexec calls AUTO-START a Halted qube and outlive the caller, so without it the
# guest gets restarted underneath us and looks "unkillable". Drop qrexec_timeout to expire
# the backlog, then RESTORE 6000 - the standing value. Leaving 15 in place breaks every
# later long-running call.
recover(){
	log "  recovering: draining queued qrexec calls, then kill + start"
	qvm-prefs "$VM" qrexec_timeout 15 2>>"$OUT/hunt.log"
	"$QTEST" kill  >>"$OUT/hunt.log" 2>&1
	sleep 25
	qvm-prefs "$VM" qrexec_timeout 6000 2>>"$OUT/hunt.log"
	log "  qrexec_timeout restored to 6000"
	"$QTEST" start >>"$OUT/hunt.log" 2>&1
	for _ in $(seq 1 40); do sleep 15; alive && { log "  guest back"; return 0; }; done
	log "  guest did NOT come back within ~10min"
	return 1
}

cleanup(){ touch "$STOP" 2>/dev/null; sleep 1; kill $(jobs -p) 2>/dev/null; }
trap cleanup EXIT INT TERM

log "wedge hunt on $VM — ${MINUTES}min, $SOAKERS soakers"
log "trigger: qrexec bridge process churn (grant unmap at process exit)"
log "output: $OUT"

st=$(state)
if [ "$st" != "Running" ]; then log "$VM is $st - starting"; "$QTEST" start >>"$OUT/hunt.log" 2>&1; sleep 25; fi
if ! alive; then
	log "ABORT: qrexec not answering before the soak started. A guest that is already sick"
	log "       cannot measure a provocation."
	exit 1
fi

# Record the pre-soak process count, so the heartbeat can be compared against the dump's 38.
"$QTEST" run "powershell -ep bypass -c \"(Get-Process qrexec-client-vm,qrexec-wrapper -ErrorAction SilentlyContinue).Count\"" \
	> "$OUT/procs-before.txt" 2>>"$OUT/hunt.log"
log "qrexec bridge processes before soak: $(tr -d '\r\n' < "$OUT/procs-before.txt" | tail -c 20)"

# --- the soak -------------------------------------------------------------------------
# Each iteration is one full qrexec service call: a bridge process is created in the guest,
# maps its grant region, runs a trivial command, and EXITS - and the exit is the part that
# issues the shootdown. Keep the payload trivial: we are buying process lifecycles, not work.
rm -f "$STOP"
for i in $(seq 1 "$SOAKERS"); do
	(
		n=0
		while [ ! -f "$STOP" ]; do
			timeout 45 "$QTEST" run "echo s$i" >/dev/null 2>&1
			n=$((n+1))
			echo "$n" > "$OUT/.soaker$i.count"
		done
	) &
done
log "$SOAKERS soakers running"

# --- watch ----------------------------------------------------------------------------
deadline=$(( $(date +%s) + MINUTES * 60 ))
dead_since=0
outcome="SURVIVED"
while [ "$(date +%s)" -lt "$deadline" ]; do
	sleep 20
	st=$(state)
	if [ "$st" != "Running" ]; then
		log "state=$st -> left Running. NOT a wedge (a wedge stays Running)."
		outcome="REBOOTED_OR_DIED:$st"
		break
	fi
	if alive; then
		if [ "$dead_since" -ne 0 ]; then
			log "qrexec recovered after $(( $(date +%s) - dead_since ))s (transient, not a wedge)"
			dead_since=0
		fi
	else
		now=$(date +%s)
		[ "$dead_since" -eq 0 ] && { dead_since=$now; log "qrexec stopped answering"; }
		gone=$(( now - dead_since ))
		if [ "$gone" -ge "$DEAD_THRESHOLD" ]; then
			log "*** WEDGE: Running but qrexec mute ${gone}s (>= ${DEAD_THRESHOLD}s) ***"
			outcome="WEDGED"
			break
		fi
	fi
done

touch "$STOP"; sleep 2; kill $(jobs -p) 2>/dev/null; wait 2>/dev/null

total=0
for i in $(seq 1 "$SOAKERS"); do
	c=$(cat "$OUT/.soaker$i.count" 2>/dev/null || echo 0); total=$(( total + c ))
done
elapsed=$(( MINUTES * 60 - ( deadline - $(date +%s) ) ))
log "outcome: $outcome after ${elapsed}s, $total qrexec calls across $SOAKERS soakers"

# The call count is the DOSE. Without it a "survived" run is uninterpretable: it cannot be
# told apart from a run whose soakers silently failed to connect, which is exactly the kind
# of empty control that would make a clean .13 look like evidence.
{
	echo "vm=$VM outcome=$outcome minutes=$MINUTES soakers=$SOAKERS"
	echo "elapsed_s=$elapsed qrexec_calls=$total"
	echo "dose_calls_per_min=$(( total / (elapsed/60 + 1) ))"
} >> "$OUT/outcomes.txt"
cat "$OUT/outcomes.txt" | tee -a "$OUT/hunt.log"

if [ "$outcome" = "WEDGED" ]; then
	# Try the dom0 forensics capture FIRST, while the guest is still wedged - after kill it
	# is gone forever. Needs dom0/13-install-wedge-forensics-service.sh; if absent this is a
	# no-op and says so rather than failing the run.
	log "attempting dom0 wedge forensics capture (qtest wedge)"
	"$QTEST" wedge "$OUT/forensics" >>"$OUT/hunt.log" 2>&1 \
		&& log "  forensics captured -> $OUT/forensics" \
		|| log "  forensics NOT captured (service installed in dom0?)"
	recover
fi

log "done: $OUT"
[ "$outcome" = "WEDGED" ] && exit 10
exit 0
