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

REPO="${WEDGE_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
QTEST="${QTEST_BIN:-$REPO/tools/qtest}"
# FAIL LOUDLY if the tool is missing. Without this check the harness cannot tell "qtest is not
# where I looked" from "the guest is dead": every probe runs `timeout 60 "$QTEST" ...`, a
# missing file exits non-zero instantly, and the run reports an ABORT about a sick guest.
# That is exactly what happened on 2026-08-30 - long runs were being started from a snapshot
# copy in a scratch dir (so edits could not corrupt a running script), which made REPO resolve
# to the scratch dir and QTEST point at nothing. Three runs "aborted on an unresponsive guest"
# that was in fact answering in 0 s, and I nearly recorded a healthy-guest latency transient
# that never existed. A probe that cannot distinguish a broken instrument from a real result
# is worse than no probe. Override REPO/QTEST via WEDGE_REPO/QTEST_BIN when running a snapshot.
if [ ! -x "$QTEST" ]; then
	echo "FATAL: qtest not found or not executable at '$QTEST'." >&2
	echo "       This is an INSTRUMENT failure, not a guest failure - do not read it as a wedge." >&2
	echo "       Running from a copy outside the repo? Set WEDGE_REPO=/path/to/repo (or QTEST_BIN)." >&2
	exit 2
fi
export QTEST_VM="$VM"          # qtest reads the target from the environment, not a flag
OUT="${WEDGE_OUT:-$REPO/evidence/wedge-hunt-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"

# Seconds of silence before calling it a wedge.
#
# RETRACTION (2026-08-30): an earlier version of this comment justified 600 by claiming a
# "~2 minute transient unresponsiveness MEASURED on a healthy guest under this soak". That
# measurement was NOT REAL. Those probe failures came from the harness being unable to find
# qtest (see the QTEST check above), not from the guest, which was answering in 0 s throughout.
# No healthy-guest transient of any length has been observed here.
#
# 600 is kept anyway, on an honest basis: it is a deliberately conservative floor for a fault
# whose defining property is that it NEVER recovers. Making it generous costs one thing - a
# slower verdict - and buys immunity to load transients, whereas a threshold that is too tight
# fabricates wedges and would send a fix in an invented direction.
DEAD_THRESHOLD="${DEAD_THRESHOLD:-600}"
STOP="$OUT/.stop"

log(){ echo "[$(date +%H:%M:%S)] $*" | tee -a "$OUT/hunt.log"; }
state(){ qvm-ls --raw-data --fields STATE "$VM" 2>/dev/null | tail -1; }
# 60 s rather than 30, as headroom for a guest under 36-way churn. NOTE: the "~2 minutes of
# healthy-guest silence" once cited here was an artefact of a broken qtest path, not a
# measurement - see the RETRACTION on DEAD_THRESHOLD. Measured round-trip on this guest,
# repeatedly, is 0-1 s.
alive(){ timeout 60 "$QTEST" run "echo alive" >/dev/null 2>&1; }

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
# Preflight liveness, RETRIED. A single probe is not enough to call a guest sick: right after a
# previous soak is torn down its in-flight qrexec calls are still draining, and a lone 30 s
# probe into that backlog can fail on a healthy guest. Retries are cheap insurance. (The runs
# that actually aborted here were caused by a missing qtest binary, not a backlog - guarded
# directly by the QTEST check above.)
ok=0
for attempt in 1 2 3 4 5; do
	if alive; then ok=1; break; fi
	log "preflight probe $attempt/5 failed - waiting for any qrexec backlog to drain"
	sleep 30
done
if [ "$ok" -ne 1 ]; then
	log "ABORT: qrexec did not answer in 5 attempts over ~2.5min. A guest that is already sick"
	log "       cannot measure a provocation."
	exit 1
fi

# Count the qrexec bridge processes, so the soak's concurrency can be compared against the
# 38 seen in the dump at freeze time. MARKER-DELIMITED: qtest run goes through cmd, so raw
# stdout carries the interactive banner and prompt and a bare number cannot be picked out of
# it - the first version of this probe logged "C:\Windows\system32>" as the count.
bridge_procs(){
	timeout 40 "$QTEST" run "powershell -ep bypass -c \"'QBP:' + @(Get-Process qrexec-client-vm,qrexec-wrapper -ErrorAction SilentlyContinue).Count\"" 2>/dev/null \
		| tr -d '\r' | sed -n 's/^QBP:\([0-9][0-9]*\)$/\1/p' | tail -1
}
before=$(bridge_procs)
log "qrexec bridge processes before soak: ${before:-UNREADABLE}"

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
		# Track peak CONCURRENCY, not just the call total. The dump's freeze happened at 38
		# concurrent bridge processes, so if a survived run never got near that, the run did
		# not actually reach the conditions the wedge was observed under - and reporting it
		# as "survived" would overstate what was tested.
		c=$(bridge_procs)
		if [ -n "$c" ] && [ "$c" -gt "${peak:-0}" ] 2>/dev/null; then peak=$c; log "peak bridge procs: $peak"; fi
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
	echo "bridge_procs_before=${before:-unreadable} peak_concurrent=${peak:-unmeasured}"
	echo "reference: the captured wedge froze at 38 concurrent qrexec-client-vm processes"
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
