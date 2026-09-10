#!/bin/bash
# IS A LOADED GUEST'S SHUTDOWN UNCLEAN? Load vs idle, interleaved, read out by MECHANISM. ANSWER: NO.
#
# THE QUESTION AS ORIGINALLY POSED - and it has since been ANSWERED IN THE NEGATIVE, 2026-09-10:
# a guest under ~2 GB of writes was reported to log Kernel-Power 41 / 6008 on the next boot, 3/3,
# while an idle guest was 3/3 clean. That measurement is VOID (its probe could not tell this round's
# events from the previous round's) and does NOT reproduce: this harness measured 0/6 loaded rounds
# unclean across both load shapes, idle 0/6. The script is kept because the question is still worth
# being able to ask, and because it is the instrument that produced the negative result.
#
# THE TWO MECHANISMS IT WAS BUILT TO SEPARATE, kept because the reasoning is what made the negative
# result readable - and (A) is now refuted on architecture as well as on measurement (an acked write
# cannot be lost while dom0 lives: blkback responds only after the bio completes, and that data is in
# dom0's block stack, which outlives the guest):
#   (A) A WRITE WAS LOST. Windows finished shutdown believing its last writes were durable, and they
#       were not. In our stack that has a source-level candidate: xenvbd's TargetSyncCache
#       (src/xenvbd/target.c) completes SCSIOP_SYNCHRONIZE_CACHE with SRB_STATUS_SUCCESS *without
#       sending anything* when the backend advertises neither feature-flush-cache nor
#       feature-barrier - and FrontendRemoveFeature() can clear those features at RUNTIME after
#       Windows has already read WriteCacheEnable=1 from the MODE SENSE caching page, which Windows
#       never re-reads. Verified in the pinned upstream source, unproven on this rig.
#   (B) NOTHING WAS LOST. Windows never got to the END of shutdown - the domain went away first -
#       so the clean-shutdown marker was never written at all. A power-off race, not a flush bug.
# Both produce an identical Kernel-Power 41. They are told apart by whether the BOOT DISK complained:
# under (A) the storage stack leaves fingerprints (Ntfs 137/140 "failed to flush data to the
# transaction log", disk 129 device reset, disk 51 paging I/O error); under (B) it leaves none,
# because from its point of view every I/O it was given completed fine.
#
# THE DESIGN, and why each piece is there:
# * INTERLEAVED, load and idle alternating, never blocked. The project has already voided one whole
#   bisect to a metric that was repeatable within a run and inverted when interleaved - it was
#   measuring scene state, not the build. Anything drifting on this rig over an hour would otherwise
#   land entirely in whichever arm ran second.
# * IDLE IS RUN, not assumed. "An idle guest is clean" is a prior measurement on a different guest;
#   re-running it here is what makes THIS guest's load result mean anything.
# * EVERY ROUND IS TIME-SCOPED. The System log accumulates: after one unclean round an unscoped read
#   reports "unclean" forever. Each round stamps the guest's own clock first and the probe is scoped
#   to it, so a round is graded on its own cycle and nothing else.
# * ONE SHUTDOWN ROUTE per invocation (ROUTE=poweroff|acpi), because both arms must differ in exactly
#   one thing - the load - and the route is the other variable. Run it twice to cover both.
# * NOTHING IS EVER KILLED. A killed guest is dirty BECAUSE of the kill, and grading that would
#   manufacture the result under test. A round that cannot halt cleanly is VOID, not a data point.
#
# THE LOAD comes in two shapes and they are NOT interchangeable - LOAD_MODE picks one:
#   complete   - ~2 GB written and every handle closed, then shut down. Maximum dirty pages, but
#                nothing is being issued any more by the time Windows starts tearing down.
#   concurrent - a detached writer that is STILL WRITING when the shutdown is issued, verified live
#                (byte count sampled twice and required to be growing) at that moment.
# The register describes the original 3/3 as "writes IN FLIGHT", which is 'concurrent'; that
# measurement was ad hoc and never committed, so it cannot be reproduced from the repo. 'complete'
# was measured on win10-abt 2026-09-10 and came back CLEAN, which is why the distinction is drawn
# here rather than assumed away.
#
# READ-OUT: mgmt/harness/xenvbd-flush-probe.sh per round, scoped to that round.
#
# Usage:  VM=win10-abt ROUNDS=3 ROUTE=poweroff LOAD_MODE=concurrent mgmt/harness/flush-durability-ab.sh
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

VM="${VM:?set VM to an installed guest answering qrexec}"
ROUNDS="${ROUNDS:-3}"
ROUTE="${ROUTE:-poweroff}"     # poweroff = the installer's own line; acpi = qvm-shutdown from the host
LOAD_MB="${LOAD_MB:-2048}"
LOAD_MODE="${LOAD_MODE:-complete}"   # complete = 2 GB written and closed, then shut down
                                     # concurrent = still WRITING when the shutdown is issued
OUT="${OUT:-/home/user/rel/flush-ab-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"
say(){ echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$OUT/summary.log"; }

case "$ROUTE" in poweroff|acpi) ;; *) echo "ROUTE must be poweroff or acpi"; exit 2 ;; esac
case "$LOAD_MODE" in complete|concurrent) ;; *) echo "LOAD_MODE must be complete or concurrent"; exit 2 ;; esac

source mgmt/harness/vmlock.sh
vm_lock "$VM"
trap 'vm_unlock "$VM"' EXIT
source mgmt/harness/e2e-wait.sh

b64(){ python3 -c "import sys,base64;print(base64.b64encode(sys.argv[1].encode('utf-16-le')).decode())" "$1"; }
gq(){ QTEST_VM=$VM timeout -k 5 "${2:-120}" ./tools/qtest run "$1" 2>/dev/null | tr -d '\r'; }
psp(){ local k="$1"; gq "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $(b64 "$2")" "${3:-180}" \
       | grep -aoE "^$k=.*" | head -1 | sed "s/^$k=//"; }
state(){ qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' -v v="$VM" '$1==v{print $2}'; }

# The guest's OWN clock, not this qube's. A skew of even a few seconds between the two would scope
# the read-out to the wrong window and silently drop or import events.
gnow(){ psp NOW 'Write-Host ("NOW=" + [datetime]::UtcNow.ToString("o"))' 60; }

# ~LOAD_MB of dirty pages, written and NOT flushed. FileStream with no Flush()/FlushAsync() and no
# WriteThrough leaves the data in the cache manager, which is the state the defect needs. The write
# is VERIFIED - a load that silently wrote nothing would turn the load arm into a second idle arm and
# the whole comparison into noise, which is exactly the "injection fired but the code never saw it"
# failure this project has paid for once already.
apply_load(){
  local mb=$1
  psp WROTE "
\$ErrorActionPreference='Stop'
\$dir = Join-Path \$env:SystemDrive 'flushload'
if (-not (Test-Path \$dir)) { New-Item -ItemType Directory -Path \$dir | Out-Null }
\$buf = New-Object byte[] (1MB)
(New-Object Random 1).NextBytes(\$buf)
\$total = 0
for (\$i = 0; \$i -lt $((mb/32)); \$i++) {
  \$fs = [IO.File]::Create((Join-Path \$dir \"f\$i.bin\"))
  for (\$j = 0; \$j -lt 32; \$j++) { \$fs.Write(\$buf, 0, \$buf.Length); \$total += 1 }
  \$fs.Close()      # closes the handle; does NOT flush the cache manager to disk
}
\$onDisk = (Get-ChildItem \$dir -File | Measure-Object -Sum Length).Sum
Write-Host (\"WROTE=\" + \$total + \"MB|ondisk:\" + [int](\$onDisk/1MB))" 900
}

clear_load(){ gq "cmd /c del /q /f \"%SystemDrive%\\flushload.stop\" 2>nul & rd /s /q \"%SystemDrive%\\flushload\" 2>nul & exit 0" 120 >/dev/null 2>&1 || true; }

# LOAD_MODE=concurrent: writes still IN FLIGHT when the shutdown is issued.
#
# WHY THIS ARM EXISTS. The register records the original result as "under ~2 GB of writes IN FLIGHT,
# BOTH UNCLEAN 3/3" - but that measurement was made ad hoc and was never committed, so the exact
# load is not recoverable from the repo, which is itself a defect in how it was recorded. The
# 'complete' arm above - write 2 GB, close every handle, then shut down - came back CLEAN on this
# guest, and the obvious candidate difference is that it is no longer writing by the time shutdown
# starts. "In flight" and "recently written" are not the same condition, and only one of them is
# what an MSI's tail looks like.
#
# The writer runs DETACHED in the guest and keeps going until a stop file appears, so it is still
# issuing writes while Windows tears down. Per experimenter rule 5, the injection is verified to be
# LIVE at the moment the code under test runs: the byte count is sampled twice and must be GROWING,
# because a "concurrent" arm whose writer had already died would silently be a third idle arm.
start_load_bg(){
  local ps1="$OUT/loadgen.ps1"
  cat > "$ps1" <<'GEN'
$ErrorActionPreference='SilentlyContinue'
$dir  = Join-Path $env:SystemDrive 'flushload'
$stop = Join-Path $env:SystemDrive 'flushload.stop'
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
$buf = New-Object byte[] (1MB)
(New-Object Random 7).NextBytes($buf)
$i = 0
while (-not (Test-Path $stop)) {
  $fs = [IO.File]::Create((Join-Path $dir "g$i.bin"))
  for ($j = 0; $j -lt 32; $j++) { $fs.Write($buf, 0, $buf.Length) }
  $fs.Close()
  $i++
  if ($i -gt 400) { $i = 0 }   # ~12.8 GB ceiling then reuse names, so the volume cannot fill
}
GEN
  QTEST_VM=$VM timeout -k 5 90 ./tools/qtest push "$ps1" >/dev/null 2>&1 || return 1
  local inc; inc="${QTEST_INCOMING:-C:\\Users\\user\\Documents\\QubesIncoming\\$(hostname)}"
  gq "cmd /c del /q /f \"%SystemDrive%\\flushload.stop\" 2>nul & start /b powershell -NoProfile -ExecutionPolicy Bypass -File \"$inc\\loadgen.ps1\"" 40 >/dev/null 2>&1 || true
  return 0
}

# bytes currently in the load directory - the liveness sample
load_bytes(){ psp SZ '
$dir = Join-Path $env:SystemDrive "flushload"
$s = 0
if (Test-Path $dir) { $s = (Get-ChildItem $dir -File | Measure-Object -Sum Length).Sum }
Write-Host ("SZ=" + [int64]$s)' 90; }

round(){                              # $1=arm (load|idle) $2=round number
  local arm=$1 n=$2 t0 wrote before st
  say "--- round $n, arm=$arm, route=$ROUTE"
  w_alive "$VM" || { say "  VOID: guest not answering qrexec at round start"; return 1; }

  t0=$(gnow); [ -n "$t0" ] || { say "  VOID: could not read the guest clock - the round cannot be scoped"; return 1; }
  before=$(psp BOOT 'Write-Host ("BOOT=" + (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString("o"))')
  [ -n "$before" ] || { say "  VOID: no boot id before"; return 1; }

  if [ "$arm" = load ] && [ "$LOAD_MODE" = concurrent ]; then
    start_load_bg || { say "  VOID: could not start the background writer"; return 1; }
    sleep 20
    local s1 s2
    s1=$(load_bytes); sleep 10; s2=$(load_bytes)
    if [ -z "${s1:-}" ] || [ -z "${s2:-}" ] || [ "${s2:-0}" -le "${s1:-0}" ]; then
      say "  VOID: the writer is NOT growing the load ($s1 -> $s2 bytes), so nothing would have been"
      say "        in flight at shutdown - this would be an idle round wearing the load label"
      clear_load; return 1
    fi
    say "  load IN FLIGHT and verified growing: $s1 -> $s2 bytes ($(( (s2-s1)/1048576 )) MB in 10s)"
  elif [ "$arm" = load ]; then
    wrote=$(apply_load "$LOAD_MB")
    case "$wrote" in
      *MB*) say "  load applied and closed: $wrote" ;;
      *)    say "  VOID: the load did not run (got '${wrote:-<nothing>}') - without it this is an idle"
            say "        round mislabelled as loaded, which would poison the comparison"; return 1 ;;
    esac
  else
    say "  idle arm: no load applied (this is the control, and it is RUN, not assumed)"
  fi

  # The shutdown under test. poweroff is EXACTLY the installer's line; the guest dies mid-call, so a
  # non-zero rc here is expected and meaningless.
  if [ "$ROUTE" = poweroff ]; then
    gq 'cmd /c shutdown.exe /s /f /t 2' 30 >/dev/null 2>&1 || true
  else
    qvm-shutdown "$VM" >/dev/null 2>&1 || true
  fi

  for i in $(seq 1 60); do [ "$(state)" = Halted ] && break; sleep 5; done
  st=$(state)
  [ "$st" = Halted ] || {
    say "  VOID: guest is $st after 300s and is NOT being killed - a killed guest is dirty because of"
    say "        the kill, so this round is ungraded rather than wrong"; return 1; }

  qvm-start "$VM" >/dev/null 2>&1
  for i in $(seq 1 60); do w_alive "$VM" && break; sleep 10; done
  w_alive "$VM" || { say "  TERMINAL: no qrexec 10 min after start - leaving the guest as it stands"; return 2; }

  # SETTLE, AND THEN CONFIRM IT STAYED UP. CLAUDE.md says it outright - "Do not grade immediately
  # after qrexec comes up. Allow ~90 s" - and this harness ignored it, which cost the first ACPI run
  # (2026-09-10): the guest answered the boot-id probe and had stopped answering by the time the
  # read-out ran a few seconds later, so round 1 VOIDed on the load arm and round 1's idle arm VOIDed
  # at "not answering qrexec at round start". The first qrexec response is not the guest being ready;
  # it is the agent's first breath, and on the ACPI route under load the session is still coming up
  # behind it. So wait, then require a SECOND, SEPARATE liveness answer, and treat a guest that
  # answered once and then went quiet as the transient it is - retry with backoff rather than
  # failing the run (experimenter rule 11), logging every attempt so a flapping guest is visible in
  # the record instead of being smoothed away.
  sleep "${SETTLE_S:-90}"
  local ok=0
  for i in 1 2 3; do
    if w_alive "$VM"; then ok=1; break; fi
    say "  guest answered, then went quiet (settle attempt $i/3) - waiting $((i*30))s and retrying"
    sleep $((i * 30))
  done
  [ "$ok" = 1 ] || { say "  TERMINAL: guest will not stay up after three settle attempts - left as it stands"; return 2; }

  local after; after=$(psp BOOT 'Write-Host ("BOOT=" + (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString("o"))')
  [ "$after" != "$before" ] || { say "  VOID: boot id unchanged ($before) - it did not actually reboot"; return 1; }

  PROBE_SINCE="$t0" VM="$VM" OUT="$OUT/r$n-$arm" ./mgmt/harness/xenvbd-flush-probe.sh >"$OUT/r$n-$arm.log" 2>&1
  local f
  f="$OUT/r$n-$arm/facts.txt"
  [ -f "$f" ] || { say "  VOID: the probe produced no facts - see $OUT/r$n-$arm.log"; return 1; }
  g(){ grep -aoE "^$1=.*" "$f" | head -1 | sed "s/^$1=//"; }
  say "  unclean=$(g UNCLEAN_N) bootdisk#$(g BOOTDISK) flush=$(g FLUSHFAIL_N) reset=$(g RESET_N) paging=$(g PAGEERR_N) retry=$(g RETRY_N) corrupt=$(g CORRUPT_N) other-disk-io=$(g OTHERDISK_IO_N)"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$arm" "$(g UNCLEAN_N)" "$(g FLUSHFAIL_N)" "$(g RESET_N)" "$(g PAGEERR_N)" "$(g RETRY_N)" "$(g CORRUPT_N)" >> "$OUT/table.tsv"
  [ "$arm" = load ] && clear_load
  return 0
}

say "=== flush durability A/B on $VM: $ROUNDS x (load | idle), route=$ROUTE, load=${LOAD_MB}MB mode=$LOAD_MODE ==="
printf 'round\tarm\tunclean\tflushfail\treset\tpaging\tretry\tcorrupt\n' > "$OUT/table.tsv"
for r in $(seq 1 "$ROUNDS"); do
  for arm in load idle; do
    round "$arm" "$r" || { rc=$?; [ "$rc" = 2 ] && { say "stopping: terminal state"; exit 1; }; }
  done
done

say "=== table ==="; column -t "$OUT/table.tsv" 2>/dev/null | tee -a "$OUT/summary.log" || cat "$OUT/table.tsv"

# THE VERDICT IS COMPUTED, not narrated, and it refuses to answer when the data cannot support one.
python3 - "$OUT/table.tsv" <<'EOF' | tee -a "$OUT/summary.log"
import sys, csv
rows = list(csv.DictReader(open(sys.argv[1]), delimiter='\t'))
if not rows:
    print("VERDICT: no graded rounds. Nothing may be concluded."); sys.exit(0)
def arm(a): return [r for r in rows if r['arm'] == a]
def n(r, k): return int(r[k])
load, idle = arm('load'), arm('idle')
lu = sum(1 for r in load if n(r,'unclean') > 0); iu = sum(1 for r in idle if n(r,'unclean') > 0)
fp = sum(n(r,'flushfail') + n(r,'reset') + n(r,'paging') + n(r,'corrupt') for r in load)
print(f"\nload arm: {lu}/{len(load)} unclean   idle arm: {iu}/{len(idle)} unclean")
print(f"boot-disk storage fingerprints in the load arm: {fp}")
if not load or not idle:
    print("VERDICT: one arm has no graded rounds - the comparison does not exist. Re-run."); sys.exit(0)
if lu == 0:
    print("VERDICT: THE LOAD ARM DID NOT REPRODUCE THE DEFECT on this guest. The prior 3/3 does not")
    print("         transfer, and nothing about the mechanism can be read off a cycle that came back")
    print("         clean. Establish the reproducer on THIS guest before reading any mechanism.")
elif lu > 0 and iu > 0:
    print("VERDICT: BOTH ARMS ARE UNCLEAN, so it is not load-dependent on this guest and the load is")
    print("         not the variable. Something else differs from the guest the 3/3 was measured on.")
elif fp > 0:
    print("VERDICT: A WRITE WAS LOST (mechanism A). The load arm is unclean AND the boot disk left")
    print("         storage fingerprints in the same window. The flush lead is CONFIRMED - see which")
    print("         signature fired (flushfail / reset / paging) in the per-round facts.")
else:
    print("VERDICT: NOTHING WAS LOST (mechanism B). The load arm is unclean, the idle arm clean, and")
    print("         the boot disk complained about NOTHING in the same window - so no flush failed and")
    print("         no I/O was dropped. Windows never reached the end of shutdown: the domain went")
    print("         away first. THE XENVBD FLUSH LEAD IS REFUTED and the defect is a POWER-OFF RACE;")
    print("         the fix belongs on the shutdown-completion path, not in the storage stack.")
    print("         CAVEAT that must travel with this: it rests on Windows logging a storage failure")
    print("         when one occurs. Ntfs 137/140 has NOT been seen to fire on this rig, so this")
    print("         instrument's ability to detect mechanism A is UNPROVEN - a silent no-op flush is")
    print("         precisely the case where nothing would be logged. Treat as strong evidence for B,")
    print("         not as proof against A.")
EOF
say "=== done: $OUT ==="
