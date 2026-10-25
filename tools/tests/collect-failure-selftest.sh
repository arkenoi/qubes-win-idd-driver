#!/usr/bin/env bash
# UNRELIABLE - DROPPED FROM PREFLIGHT 2026-10-25, owner's directive: never write a test for a
# test, and never fault-inject a harness fix as part of the harness. This file mutates another
# TEST or HARNESS file and runs the mutants, so a defect in it corrupts both arms. It is not in
# tools/tests/offline-suites.txt, nothing runs it, and it is NOT to be fixed or re-registered
# without the owner saying so. See TESTFORATESTRECURSION in findings/issues.md.
# collect-failure-selftest.sh - offline proof matrix for mgmt/harness/collect-failure.sh (the failure package,
# PLAN-acceptance-optimization section 4) and tools/activity-snapshot.py.
#
# No rig, no guest: the collector runs from a FIXTURE ROOT whose mgmt/harness and tools are symlinks to the
# real libraries (vmlock, run-lib, wedge-lib, logvol-lib, e2e-wait, log-sweep.py, activity-snapshot.py) and
# stubs for everything that would touch a guest (tools/qtest, log-sweep.sh, fetch-wedge-core.sh, the dom0
# forensics service qrexec-client-vm). The secondary volume is a REAL FAT image read with REAL mtools. The
# offline analysis runs the REAL analyzer with a stub judge. Each check is also seen to FAIL with its defect
# present (a copy of the collector with ONE `# GUARD:<knob>` line replaced by the defect beside it).
#
#   alive      guest answers: volume first, then the live sweep, a per-window capture, the snapshot with all
#              six fields, a VERIFIED tarball, the manifest LAST -> rc 0, complete
#   halted     guest Halted: no live call; the volume's copy is analysed OFFLINE by the real analyzer; the
#              snapshot comes from the volume; the only gap is the clock (nothing to read it from) -> rc 1
#   wedged     Running but no QREADY: the wedge is classified SPIN from the forensics samples and the memory
#              image is fetched, kept beside the package and NOT in the tarball
#   refused    the core fetch refuses for space: recorded as the instrument-fail it is, specimen left alive
#   no-volume  no --logvol and no manifest entry is a GAP; '--logvol none' is a declaration, not a gap
#   qwtfree    --no-qrexec DECLARES a guest that carries no QWT: the probe is skipped, nothing is classified,
#              no memory image is taken, and the dom0-side per-window capture still runs
#   undecl     the same guest with the flag FORGOTTEN: the core is still refused, but a GAP is recorded so the
#              run is incomplete and the caller gets fixed - never silently right
#   bound      a guest that answers later than --unresponsive-secs is unresponsive (the only case where the
#              real `timeout` fires; every other silent case answers nothing instantly, so no case races a clock)
#   refusals   an outdir inside the tracked tree, a bad --since, a missing argument -> rc 2, nothing written
#   knobs      logvolgap, unresponsive, declqwtfree, qwtfreebackstop, qwtfreescreen, manifestlast, snapshotgaps,
#              gaprecord (collector); missingtails (snapshot)
#
#   CF_SELFTEST_OUT=<dir>  keep fixtures and outputs (default: a mktemp dir, removed on exit)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/mgmt/harness/collect-failure.sh"
T="${CF_SELFTEST_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/cf-selftest-XXXXXX")}"
[ -n "${CF_SELFTEST_OUT:-}" ] || trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }
for t in mkfs.fat mcopy mdir mmd flock; do command -v $t >/dev/null || { echo "FAIL  $t is not installed - nothing ran"; exit 2; }; done
[ -f "$SRC" ] || { echo "FAIL  $SRC is missing - nothing ran"; exit 2; }

# ---- the fixture root ---------------------------------------------------------------------------------------
FX="$T/fx"; mkdir -p "$FX/mgmt/harness" "$FX/mgmt/goldens" "$FX/tools" "$FX/scratchpad" "$T/bin" "$T/out"
for f in vmlock.sh serial-rig.sh run-lib.sh wedge-lib.sh logvol-lib.sh e2e-wait.sh shutdown-lib.sh log-sweep-baseline.json; do ln -sfn "$ROOT/mgmt/harness/$f" "$FX/mgmt/harness/$f"; done
ln -sfn "$ROOT/.claude" "$FX/.claude"
for f in activity-snapshot.py log-sweep.py winshot.py; do ln -sfn "$ROOT/tools/$f" "$FX/tools/$f"; done
ln -sfn "$SRC" "$FX/mgmt/harness/collect-failure.sh"

# fixture logs in the writers' formats (the shapes tools/log-sweep.py parses)
mkdir -p "$T/logs"
cat > "$T/logs/gui-agent-20261013.log" <<'EOF'
[20261013.100000.000-3228:3364-I] LogInit: Log started, module name: gui-agent
[20261013.100000.000-3228:3364-I] LogInit: System uptime: 31.200 seconds
[20261013.100000.001-3228:3364-I] LogInit: Running as user: SYSTEM, process ID: 3228
[20261013.100000.001-3228:3364-I] LogInit: Module version: 4.3.36.900
[20261013.100000.001-3228:3364-I] LogInit: Session: 1
[20261013.100001.000-3228:3364-I] WatchForEvents: Awaiting for a vchan client, write buffer size: 65536
[20261013.100001.500-3228:3364-I] WatchForEvents: A vchan client has connected
[20261013.100010.000-3228:3364-I] SendWindowMap: Mapping window 0x301c4 (979x512)
[20261013.100011.000-3228:3364-I] SendWindowFocus: focus -> 0x301c4
[20261013.100020.000-3228:3364-I] SendWindowUnmap: Unmapping window 0x301c4
[20261013.100021.000-3228:3364-I] AddAllWindows: QGALEDGERSUM engineDamage=0 c8DrainVchan=0
EOF
cat > "$T/logs/gui-watchdog-20261013.log" <<'EOF'
[20261013.095959.000-3652:3772-I] LogInit: Log started, module name: gui-watchdog
[20261013.095959.000-3652:3772-I] LogInit: Running as user: SYSTEM, process ID: 3652
[20261013.095959.000-3652:3772-I] LogInit: Module version: 4.3.36.900
[20261013.095959.000-3652:3772-I] LogInit: Session: 0
[20261013.100000.000-3652:3773-I] StartTargetProcess: Running process 'C:\Program Files\Qubes Tools\bin\gui-agent.exe' in session 1
[20261013.100010.000-3652:3773-I] WatchdogThread: Process 'gui-agent.exe' has been up for 10000 ms, restart delay reset
EOF
cat > "$T/logs/qrexec-wrapper-20261013.log" <<'EOF'
[20261013.100005.000-5500:5616-I] LogInit: Log started, module name: qrexec-wrapper
[20261013.100005.000-5500:5616-I] LogInit: Running as user: SYSTEM, process ID: 5500
[20261013.100005.000-5500:5616-I] LogInit: Command line: qrexec-wrapper.exe 10858|515|(null)|6|c:\Windows\System32\cmd.exe
[20261013.100005.100-5500:5616-I] StartChild: Running 'c:\Windows\System32\cmd.exe' as SYSTEM
[20261013.100005.200-5500:5616-I] HandleDataMessage: data protocol version 4 (peer 4, ours 4)
[20261013.100030.000-5804:5456-I] LogInit: Log started, module name: qrexec-wrapper
[20261013.100030.000-5804:5456-I] LogInit: Running as user: SYSTEM, process ID: 5804
[20261013.100030.000-5804:5456-I] LogInit: Command line: qrexec-wrapper.exe 10858|515|user|6|cmd /c echo QREADY
[20261013.100030.050-5804:5456-I] StartChild: Running 'cmd /c echo QREADY' as user 'user'
[20261013.100030.900-5804:5456-I] WrapperCtrlHandler: child exited with code 0x0
EOF
cat > "$T/logs/events.txt" <<'EOF'
EV 2026-10-13 09:59:30.000 [System] id=6005 level=4 EventLog: The Event log service was started.
EV 2026-10-13 09:59:31.000 [System] id=6013 level=4 EventLog: The system uptime is 20 seconds.
EV NONE [Microsoft-Windows-TaskScheduler/Operational]
EOF

# the secondary volume: a real FAT image with the fixture logs on it (what a bound guest writes)
. "$ROOT/mgmt/harness/logvol-lib.sh"
export LOGVOL_DIR="$T/img" LOGVOL_ARCHIVE_DIR="$T/img/archive"
IMG="$T/img/logs-cell1.img"
logvol_create "$IMG" cell1 64 >/dev/null 2>&1 || { echo "FATAL: could not create the fixture volume"; exit 2; }
mkdir -p "$T/vol/cell1"; cp "$T/logs"/*.log "$T/vol/cell1/"
mcopy -s -i "$IMG" "$T/vol/cell1" ::/qwt-logs/ >/dev/null 2>&1

# ---- the stubs -------------------------------------------------------------------------------------------
# tools/qtest: state from $QSTATE; the liveness probe answers only when $ALIVE=1.
#
# A GUEST THAT CANNOT ANSWER IS MODELLED BY ANSWERING NOTHING, INSTANTLY - never by outlasting a
# timeout. Until 2026-10-14 the silent case slept 30 s against a 12 s bound, which made BOTH
# directions a wall-clock race: on a loaded machine the HEALTHY fixture's instant answer also missed
# the bound, so the alive case read unresponsive, classified a wedge SPIN 1.00 and fetched a memory
# core. Three identical runs that day scored 46/0, 44/2 and 39/7 - an instrument that disagrees with
# itself cannot validate anything (CLAUDE.md: a metric is shown stable on ONE unchanged binary over
# >= 3 runs before any verdict).
#
# The observable is identical either way - empty output, no QREADY - so the collector's branch is
# exercised exactly as before, and now nothing here depends on how busy the machine is.
# ALIVE=timeout keeps ONE case that genuinely makes `timeout` fire, so the bound itself stays tested.
cat > "$FX/tools/qtest" <<'SH'
#!/bin/bash
echo "qtest $*" >> "$CALLS"
case "$1" in
  state) echo "power_state=${QSTATE:-Running}" ;;
  run) case "${ALIVE:-1}" in
         1)       echo "C:\\Windows\\System32>$2"; echo "QREADY" ;;
         timeout) sleep $(( ${CF_UNRESPONSIVE_SECS:-40} + 30 )) ;;
         *)       exit 1 ;;
       esac ;;
  shot) : > "$2" ;;   # an EMPTY tar: w_screen grades NOWINDOW, the legitimate verdict for a guest with no window
  *) echo "stub: $*" ;;
esac
SH
# log-sweep.sh: the live sweep - decodes the fixture logs the way the real one lands them, with a pre-sync clock
cat > "$FX/mgmt/harness/log-sweep.sh" <<SH
#!/bin/bash
echo "log-sweep \$*" >> "\$CALLS"
out="\$3"; mkdir -p "\$out/logs/files"
cp "$T/logs"/*.log "\$out/logs/files/"; cp "$T/logs/events.txt" "\$out/logs/events.txt"
echo "2026-10-13T10:00:00.000Z" > "\$out/clock-presync.txt"
echo "LOGSWEEP-RESULT vm=\$1 rc=\${SWEEP_STUB_RC:-0} status=\${SWEEP_STUB_STATUS:-CLEAN} report=\$out/report.json summary=\$out/summary.txt"
exit \${SWEEP_STUB_RC:-0}
SH
# fetch-wedge-core.sh: writes an image, or refuses for space exactly as the real one does
cat > "$FX/mgmt/harness/fetch-wedge-core.sh" <<'SH'
#!/bin/bash
echo "fetch-core $*" >> "$CALLS"
if [ "${CORE_STUB:-ok}" = refuse ]; then
  echo "fetch-core: REFUSED: not enough free space. Free some first - an image half-written into a full disk is"
  echo "fetch-core:   SHORT BY 912 MiB. Largest REGENERABLE candidates (all re-downloadable"
  echo "fetch-core:   THE SPECIMEN IS STILL ALIVE AND MUST NOT BE DISCARDED until this is resolved"
  exit 1
fi
mkdir -p "$(dirname "$2")"; head -c 4096 /dev/zero > "$2"; echo "fetch-core: OK: $2"; exit 0
SH
# qvm-features: the fixture subject is a guest that CARRIES QWT - that is what a wedge subject is.
# collect-failure now refuses to classify a wedge or take a memory image when the guest has no
# qrexec FEATURE, because a QWT-free pristine base can never answer and its silence means nothing.
# Without this stub the real qvm-features is asked about a VM that does not exist, answers empty,
# and every wedge case here is skipped - which is what happened when that guard was added.
cat > "$T/bin/qvm-features" <<'SH'
#!/bin/bash
echo "qvm-features $*" >> "$CALLS"
case "$2" in
  qrexec) [ -n "${QREXEC_FEATURE-1}" ] && echo "${QREXEC_FEATURE-1}" ;;   # QREXEC_FEATURE='' = the feature is absent
  *) ;;
esac
true
SH
chmod +x "$T/bin/qvm-features"

# qrexec-client-vm: the dom0 forensics service - two vcpu-list samples 10 s apart, vcpu 0 spinning
cat > "$T/bin/qrexec-client-vm" <<'SH'
#!/bin/bash
echo "qrexec-client-vm $*" >> "$CALLS"
case "$2" in
  admin.vm.List)
    # vm_lock's assert_sole_guest (mgmt/harness/serial-rig.sh) asks the rig what is up: the subject
    # itself (skipped as self) and a Halted qube (skipped by state); nothing else, so no qvm-tags call
    printf 'win11-cell class=StandaloneVM state=Running\\0win10-other class=StandaloneVM state=Halted\\0' ;;
  local.WinWedgeForensics+*)
    d=$(mktemp -d)
    printf 'Name ID VCPU CPU State Time(s) Affinity\nwin11-cell 12 0 2 r-- 25.0 all\nwin11-cell 12 1 3 -b- 4.0 all\n' > "$d/vcpu-list-1.txt"
    printf 'Name ID VCPU CPU State Time(s) Affinity\nwin11-cell 12 0 2 r-- 35.0 all\nwin11-cell 12 1 3 -b- 4.0 all\n' > "$d/vcpu-list-2.txt"
    echo "capture ok" > "$d/capture.log"
    tar -cf - -C "$d" vcpu-list-1.txt vcpu-list-2.txt capture.log; rm -rf "$d" ;;
  *) exit 1 ;;
esac
SH
# the judge for the offline analyzer: every question 'expected' (the item format is the analyzer's)
cat > "$T/jev-stub.py" <<'PY'
#!/usr/bin/env python3
import json, sys
rub = json.load(open(sys.argv[1])); q = rub.get("questions", rub)
out = sys.argv[sys.argv.index("--out") + 1]
ans = {k: {"type": "choice", "choice": "expected", "confidence": 0.9, "probabilities": {"expected": 0.9, "defect": 0.05, "noise": 0.03, "insufficient-evidence": 0.02}} for k in q}
json.dump({"model": "stub", "answers": ans}, open(out, "w"))
for k in q: print("%s choice=expected conf=0.90" % k)
PY
# qvm-tags: never the real one from a self-test (an admin call at a qube); answers "no tags"
printf '#!/bin/bash\necho "qvm-tags $*" >> "$CALLS"\nexit 0\n' > "$T/bin/qvm-tags"; chmod +x "$T/bin/qvm-tags"
chmod +x "$FX/tools/qtest" "$FX/mgmt/harness/log-sweep.sh" "$FX/mgmt/harness/fetch-wedge-core.sh" "$T/bin/qrexec-client-vm" "$T/jev-stub.py"
export CALLS="$T/calls.log" PATH="$T/bin:$PATH" TMPDIR="$T" CF_JEV_CMD="$T/jev-stub.py" CF_UNRESPONSIVE_SECS=12
export QWT_VMLOCK_HELD=""   # never inherit a lock from the caller's shell

# FATAL goes to stderr and the function RETURNS non-zero (it runs inside $(...); an exit would only leave
# the subshell and hand the caller the FATAL text as a script path). Callers: K=$(knob x) || exit 2.
knob(){ local n="$1" out="$FX/mgmt/harness/collect-failure-$1.sh" hits
  hits=$(grep -c "# GUARD:$n DEFECT: " "$SRC")
  [ "$hits" = 1 ] || { echo "FATAL: GUARD:$n appears $hits times in $SRC (want exactly 1)" >&2; return 2; }
  sed -E "s|^( *)[^#]*# GUARD:$n DEFECT: (.*)$|\1\2|" "$SRC" > "$out"
  [ "$(diff "$SRC" "$out" | grep -c '^>')" = 1 ] || { echo "FATAL: knob $n changed $(diff "$SRC" "$out" | grep -c '^>') lines" >&2; return 2; }
  bash -n "$out" 2>/dev/null || { echo "FATAL: knob $n does not parse" >&2; bash -n "$out" 2>&1 | head -2 >&2; return 2; }
  chmod +x "$out"; printf '%s' "$out"; }
# collect <script> <label> <args...> -> rc; output in $T/out/<label>.out, package in $T/out/<label>
collect(){ local s="$1" l="$2"; shift 2; : > "$CALLS"
  (cd "$FX" && bash "$s" win11-cell "$T/out/$l" "selftest: $l" "$@") > "$T/out/$l.out" 2>&1; echo $?; }
mfield(){ python3 -c "import json,sys; r=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))" "$T/out/$1/manifest.json" "$2" 2>/dev/null; }
sfield(){ python3 -c "import json,sys; r=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))" "$T/out/$1/activity-snapshot.json" "$2" 2>/dev/null; }

# ---- alive -----------------------------------------------------------------------------------------------
rc=$(QSTATE=Running ALIVE=1 collect mgmt/harness/collect-failure.sh alive --logvol "$IMG" --since 2026-10-13T09:00:00Z --harness-cmd "mgmt/harness/quick-upgrade.sh pkg win11-cell win11r")
if [ "$rc" = 0 ] && [ "$(mfield alive "r['complete']")" = True ]; then ok "alive: rc=0 and the manifest says complete"; else bad "alive: rc=$rc $(tail -3 "$T/out/alive.out" | tr '\n' ' ')"; fi
[ -s "$T/out/alive/manifest.json" ] && [ -s "$T/out/alive/package.tar.gz" ] && [ -s "$T/out/alive/activity-snapshot.json" ] && ok "alive: manifest, tarball and snapshot all exist" || bad "alive: package files missing"
m=$(mfield alive "r['tarball']['members']"); n=$(tar -tzf "$T/out/alive/package.tar.gz" | grep -vc '/$'); s=$(mfield alive "r['tarball']['sha256']"); s2=$(sha256sum "$T/out/alive/package.tar.gz" | cut -d' ' -f1)
[ "$m" = "$n" ] && [ "$s" = "$s2" ] && [ "$n" -gt 5 ] && ok "alive: the tarball is VERIFIED - $n members listed, sha256 matches the manifest" || bad "alive: tarball members=$m listed=$n sha ok=$([ "$s" = "$s2" ] && echo yes || echo no)"
[ "$(sfield alive "r['complete']")" = True ] && ok "alive: the snapshot is COMPLETE (all six fields)" || bad "alive: snapshot missing: $(sfield alive "r['missing']")"
[ "$(sfield alive "r['last_qrexec_pair']['request']")" = 'qrexec-wrapper.exe 10858|515|user|6|cmd /c echo QREADY' ] && [ "$(sfield alive "r['last_qrexec_pair']['outcome']['line']")" = '[20261013.100030.900-5804:5456-I] WrapperCtrlHandler: child exited with code 0x0' ] \
  && ok "alive: last qrexec pair = the LAST request and the last line of THAT pid" || bad "alive: qrexec pair: $(sfield alive "r['last_qrexec_pair']")"
[ "$(sfield alive "r['last_window']['func']")" = SendWindowUnmap ] && [ "$(sfield alive "r['last_window']['hwnd']")" = 0x301c4 ] && ok "alive: last window/focus event = the unmap of 0x301c4" || bad "alive: last_window: $(sfield alive "r['last_window']")"
[ "$(sfield alive "len(r['module_logs'])")" = 3 ] && [ "$(sfield alive "r['module_logs']['gui-agent-20261013.log']['family']")" = agent ] && [ "$(sfield alive "len(r['module_logs']['gui-agent-20261013.log']['tail'])")" = 11 ] \
  && ok "alive: per-module tails for 3 logs, families named, whole file when shorter than 20 lines" || bad "alive: module_logs: $(sfield alive "list(r['module_logs'])")"
[ "$(sfield alive "r['clock_skew']['guest_utc']")" = "2026-10-13T10:00:00.000Z" ] && ok "alive: clock skew read from the sweep's pre-sync measurement" || bad "alive: clock: $(sfield alive "r['clock_skew']")"
[ "$(sfield alive "[x['state'] for x in r['power_timeline']]")" = "['eventlog-started (boot)', 'Running', 'alive']" ] && ok "alive: power timeline merges the guest's boot event with the collector's readings, in time order" || bad "alive: timeline: $(sfield alive "r['power_timeline']")"
[ "$(sfield alive "r['harness_cmd']['cmd']")" = "mgmt/harness/quick-upgrade.sh pkg win11-cell win11r" ] && ok "alive: the exact harness command is recorded" || bad "alive: harness_cmd: $(sfield alive "r['harness_cmd']")"
lv=$(grep -n 'secondary volume:' "$T/out/alive/collect.log" | head -1 | cut -d: -f1); li=$(grep -n 'liveness:' "$T/out/alive/collect.log" | head -1 | cut -d: -f1)
[ -n "$lv" ] && [ -n "$li" ] && [ "$lv" -lt "$li" ] && ok "alive: the secondary volume is read BEFORE anything is asked of the guest (line $lv before $li)" || bad "alive: order: volume at $lv, liveness at $li"
[ "$(mfield alive "r['sources']['secondary_volume']['status']")" = pulled ] && [ "$(mfield alive "r['sources']['secondary_volume']['files']")" = 4 ] && ok "alive: manifest names the volume as pulled (4 files)" || bad "alive: volume source: $(mfield alive "r['sources']['secondary_volume']")"
[ "$(mfield alive "r['sources']['live_sweep']['status']")" = CLEAN ] && [ "$(mfield alive "r['sources']['screen']")" = NOWINDOW ] && ok "alive: live sweep CLEAN and the per-window capture graded NOWINDOW are both recorded" || bad "alive: sweep/screen: $(mfield alive "r['sources']")"
grep -q 'qtest shot' "$CALLS" && ! grep -qE 'qtest (shutdown|kill|start)' "$CALLS" && ok "alive: a per-window shot was taken and the guest was never stopped, killed or started" || bad "alive: calls: $(grep qtest "$CALLS" | tr '\n' ';')"
[ "$(mfield alive "r['sources']['offline_analysis']['status']")" != None ] && ok "alive: the volume's copy was ALSO analysed offline (status $(mfield alive "r['sources']['offline_analysis']['status']"))" || bad "alive: no offline analysis"
grep -q 'COLLECT-RESULT vm=win11-cell rc=0 complete=1 manifest=' "$T/out/alive.out" && ok "alive: the COLLECT-RESULT line is the last line" || bad "alive: result line: $(tail -1 "$T/out/alive.out")"

# ---- a sweep that does not complete is a gap, not a verdict ------------------------------------------------
rc=$(QSTATE=Running ALIVE=1 SWEEP_STUB_RC=3 SWEEP_STUB_STATUS=DATA collect mgmt/harness/collect-failure.sh sweepdata --logvol "$IMG" --since 2026-10-13T09:00:00Z --harness-cmd x)
[ "$rc" = 1 ] && mfield sweepdata "r['gaps']" | grep -q 'live log sweep did not complete (rc=3 status=DATA)' && ok "sweep DATA: rc=1 with the gap named" || bad "sweep DATA: rc=$rc gaps=$(mfield sweepdata "r['gaps']")"

# ---- halted ---------------------------------------------------------------------------------------------
rc=$(QSTATE=Halted collect mgmt/harness/collect-failure.sh halted --logvol "$IMG" --since 2026-10-13T09:00:00Z --harness-cmd x)
if [ "$rc" = 1 ] && [ "$(mfield halted "len(r['gaps'])")" = 1 ] && mfield halted "r['gaps'][0]" | grep -q 'clock_skew'; then ok "halted: rc=1 and the ONLY gap is the clock (no guest to read it from)"; else bad "halted: rc=$rc gaps=$(mfield halted "r['gaps']")"; fi
! grep -qE 'qtest (run|shot|pushrun)' "$CALLS" && ok "halted: nothing was asked of the guest beyond its power state" || bad "halted: guest calls: $(grep qtest "$CALLS" | tr '\n' ';')"
[ -s "$T/out/halted/sweep-offline/report.json" ] && [ "$(mfield halted "r['sources']['offline_analysis']['status']")" != None ] && ok "halted: the REAL analyzer ran OFFLINE over the volume's copy (status $(mfield halted "r['sources']['offline_analysis']['status']"))" || bad "halted: no offline report ($(tail -2 "$T/out/halted/sweep-offline/analyze.out" 2>/dev/null | tr '\n' ' '))"
[ "$(sfield halted "len(r['module_logs'])")" = 3 ] && [ "$(sfield halted "r['last_window']['hwnd']")" = 0x301c4 ] && ok "halted: the snapshot's module tails and last window come from the VOLUME" || bad "halted: snapshot from volume: $(sfield halted "list(r['module_logs'])")"
[ "$(mfield halted "r['complete']")" = False ] && [ -s "$T/out/halted/manifest.json" ] && ok "halted: the package exists and says complete=false (a partial package is evidence)" || bad "halted: manifest/complete"

# ---- wedged: SPIN classified, core fetched, kept out of the tarball ----------------------------------------
rc=$(QSTATE=Running ALIVE=0 CORE_STUB=ok collect mgmt/harness/collect-failure.sh wedged --logvol "$IMG" --since 2026-10-13T09:00:00Z --harness-cmd x)
[ "$(mfield wedged "r['liveness']")" = unresponsive ] && mfield wedged "r['sources']['wedge_class']" | grep -q '^SPIN' && ok "wedged: liveness=unresponsive, wedge classified $(mfield wedged "r['sources']['wedge_class']") from the forensics samples" || bad "wedged: liveness=$(mfield wedged "r['liveness']") class=$(mfield wedged "r['sources']['wedge_class']") rc=$rc $(tail -3 "$T/out/wedged.out" | tr '\n' ' ')"
[ "$(mfield wedged "r['sources']['core']['status']")" = fetched ] && [ -s "$T/out/wedged/wedge/win11-cell.core" ] && ok "wedged: the memory image was fetched ($(mfield wedged "r['sources']['core']['path']"))" || bad "wedged: core: $(mfield wedged "r['sources']['core']")"
! tar -tzf "$T/out/wedged/package.tar.gz" | grep -q '\.core$' && ok "wedged: the core is NOT in the tarball" || bad "wedged: core inside the tarball"
lv=$(grep -n 'secondary volume:' "$T/out/wedged/collect.log" | head -1 | cut -d: -f1); lw=$(grep -n 'wedge:' "$T/out/wedged/collect.log" | head -1 | cut -d: -f1)
[ "$lv" -lt "$lw" ] && ok "wedged: the volume was read (host-side) BEFORE the wedge forensics paused anything" || bad "wedged: order volume=$lv wedge=$lw"
! grep -qE 'qtest (shutdown|kill|start)' "$CALLS" && ok "wedged: the specimen was left alive" || bad "wedged: lifecycle call made"
[ "$(sfield wedged "len(r['module_logs'])")" = 3 ] && ok "wedged: the snapshot still carries every module tail - from the volume, no guest needed" || bad "wedged: snapshot tails: $(sfield wedged "list(r['module_logs'])")"

# ---- the BOUND itself: a guest that answers too late is unresponsive ---------------------------------------
# Every other silent case answers nothing instantly, so this is the only one where `timeout` actually
# fires. Its own 3 s bound keeps it cheap; the stub sleeps bound+30, so the margin is not a race.
rc=$(QSTATE=Running ALIVE=timeout CF_UNRESPONSIVE_SECS=3 collect mgmt/harness/collect-failure.sh toolate --logvol "$IMG" --since 2026-10-13T09:00:00Z --harness-cmd x --no-core)
[ "$(mfield toolate "r['liveness']")" = unresponsive ] && ok "bound: a guest that answers later than --unresponsive-secs is unresponsive (timeout fired)" || bad "bound: liveness=$(mfield toolate "r['liveness']") rc=$rc"

# ---- refused core -------------------------------------------------------------------------------------------
rc=$(QSTATE=Running ALIVE=0 CORE_STUB=refuse collect mgmt/harness/collect-failure.sh refused --logvol "$IMG" --since 2026-10-13T09:00:00Z --harness-cmd x)
[ "$rc" = 1 ] && [ "$(mfield refused "r['sources']['core']['status']")" = refused-space ] && mfield refused "r['gaps']" | grep -q 'SHORT BY 912 MiB' && mfield refused "r['gaps']" | grep -q 'SPECIMEN STAYS ALIVE' \
  && ok "refused: core refused for space -> gap names the shortfall and says the specimen stays alive (rc=1)" || bad "refused: rc=$rc core=$(mfield refused "r['sources']['core']") gaps=$(mfield refused "r['gaps']")"
rc=$(QSTATE=Running ALIVE=0 collect mgmt/harness/collect-failure.sh nocore --logvol "$IMG" --since 2026-10-13T09:00:00Z --harness-cmd x --no-core)
[ "$(mfield nocore "r['sources']['core']['status']")" = skipped-by-caller ] && ! grep -q 'fetch-core' "$CALLS" && ok "--no-core: the image is not fetched and the manifest says why" || bad "--no-core: $(mfield nocore "r['sources']['core']")"

# ---- no volume ------------------------------------------------------------------------------------------------
rc=$(QSTATE=Running ALIVE=1 collect mgmt/harness/collect-failure.sh novol --since 2026-10-13T09:00:00Z --harness-cmd x)
[ "$rc" = 1 ] && mfield novol "r['gaps']" | grep -q 'secondary volume: none named' && ok "no-volume: a cell that named no volume is a GAP (rc=1)" || bad "no-volume: rc=$rc gaps=$(mfield novol "r['gaps']")"
rc=$(QSTATE=Running ALIVE=1 collect mgmt/harness/collect-failure.sh declnone --logvol none --since 2026-10-13T09:00:00Z --harness-cmd x)
[ "$rc" = 0 ] && [ "$(mfield declnone "r['sources']['secondary_volume']['status']")" = declared-none ] && ok "--logvol none: a DECLARED absence is recorded, not a gap (rc=0)" || bad "declared none: rc=$rc gaps=$(mfield declnone "r['gaps']")"

# ---- a guest that carries NO QWT: its silence is declared, never read as a wedge ------------------------------
# 2026-10-13: a pristine base build failed on a harness bug, the guest was healthy, and its normal qrexec
# silence was classified as a wedge - an 8.1 GB memory core of a healthy guest filled /home to 97%.
# $CALLS is cumulative across cases, so each of these reads only the lines ITS case appended.
before=$(wc -l < "$CALLS")
rc=$(QSTATE=Running ALIVE=0 CORE_STUB=ok collect mgmt/harness/collect-failure.sh qwtfree --logvol "$IMG" --since 2026-10-13T09:00:00Z --harness-cmd x --no-qrexec)
tail -n +$((before+1)) "$CALLS" > "$T/calls-qwtfree.log"
# rc=1 with ONE gap, the clock, is the HONEST outcome and the same one the halted case gets: the clock
# skew is read from the guest and this guest cannot be asked. The declaration suppresses the wedge
# verdict and the core, never the accounting of what could not be read.
[ "$rc" = 1 ] && [ "$(mfield qwtfree "len(r['gaps'])")" = 1 ] && mfield qwtfree "r['gaps'][0]" | grep -q 'clock_skew' \
  && [ "$(mfield qwtfree "r['liveness']")" = no-qrexec-by-design ] && [ "$(mfield qwtfree "r['sources']['core']['status']")" = skipped-no-qrexec ] && ! mfield qwtfree "r['sources']['wedge_class']" | grep -qE 'SPIN|BLOCKED' \
  && ok "--no-qrexec: a declared QWT-free guest is not classified and no memory image is taken; the only gap is the clock" \
  || bad "--no-qrexec: rc=$rc gaps=$(mfield qwtfree "r['gaps']") liveness=$(mfield qwtfree "r['liveness']") core=$(mfield qwtfree "r['sources']['core']") class=$(mfield qwtfree "r['sources']['wedge_class']")"
! grep -q '^qtest run' "$T/calls-qwtfree.log" && ok "--no-qrexec: the liveness probe is not run at all - it could only ever fail, and waiting for it is not a measurement" || bad "--no-qrexec: the guest was probed: $(grep '^qtest run' "$T/calls-qwtfree.log" | head -1)"
[ "$(mfield qwtfree "r['sources']['screen']")" = NOWINDOW ] && ok "--no-qrexec: the dom0-side per-window capture still runs - the only instrument that needs nothing from the guest" || bad "--no-qrexec: screen=$(mfield qwtfree "r['sources']['screen']")"

# The backstop for a caller that forgot the flag: it refuses the expensive step AND records a gap, so the
# run is incomplete and the CALLER gets fixed. It never silently does the right thing.
rc=$(QSTATE=Running ALIVE=0 CORE_STUB=ok QREXEC_FEATURE='' collect mgmt/harness/collect-failure.sh undecl --logvol "$IMG" --since 2026-10-13T09:00:00Z --harness-cmd x)
[ "$rc" = 1 ] && [ "$(mfield undecl "r['liveness']")" = no-qrexec-undeclared ] && [ "$(mfield undecl "r['sources']['core']['status']")" = skipped-no-qrexec ] && mfield undecl "r['gaps']" | grep -q 'did not pass --no-qrexec' \
  && ok "backstop: a forgotten --no-qrexec refuses the core AND records a gap (rc=1) - loud, not silently right" \
  || bad "backstop: rc=$rc liveness=$(mfield undecl "r['liveness']") core=$(mfield undecl "r['sources']['core']") gaps=$(mfield undecl "r['gaps']")"
# a manifest entry names the image, no --logvol needed
MF="$T/lv-manifest.json"; printf '{"logvol":[{"vm":"win11-cell","id":"cell1","image":"%s","loop":"loop5","frontend":"xvdj"}]}\n' "$IMG" > "$MF"
rc=$(QSTATE=Running ALIVE=1 collect mgmt/harness/collect-failure.sh viamf --logvol-manifest "$MF" --since 2026-10-13T09:00:00Z --harness-cmd x)
[ "$rc" = 0 ] && [ "$(mfield viamf "r['sources']['secondary_volume']['image']")" = "$IMG" ] && ok "manifest lookup: the volume is found from the campaign manifest" || bad "manifest lookup: rc=$rc image=$(mfield viamf "r['sources']['secondary_volume']")"
# the harness command falls back to the PARENT's command line when not given
rc=$(QSTATE=Running ALIVE=1 collect mgmt/harness/collect-failure.sh parentcmd --logvol none --since 2026-10-13T09:00:00Z)
[ "$(mfield parentcmd "r['harness_cmd_source']")" != argument ] && [ -n "$(mfield parentcmd "r['harness_cmd']")" ] && ok "harness cmd: defaults to the parent process's command line ($(mfield parentcmd "r['harness_cmd_source']"))" || bad "harness cmd fallback: $(mfield parentcmd "r['harness_cmd_source']")"

rc=$(HARNESS_CMD="mgmt/harness/matrix.sh via env" QSTATE=Running ALIVE=1 collect mgmt/harness/collect-failure.sh envcmd --logvol none --since 2026-10-13T09:00:00Z)
[ "$(mfield envcmd "r['harness_cmd_source']")" = environment ] && [ "$(mfield envcmd "r['harness_cmd']")" = "mgmt/harness/matrix.sh via env" ] && ok "harness cmd: HARNESS_CMD in the environment is used when no argument is given" || bad "harness cmd env: $(mfield envcmd "r['harness_cmd_source']") '$(mfield envcmd "r['harness_cmd']")'"

# ---- refusals ---------------------------------------------------------------------------------------------------
(cd "$FX" && bash mgmt/harness/collect-failure.sh win11-cell "$FX/mgmt/evidence-here" reason --logvol none) >"$T/out/tracked.out" 2>&1; rc=$?
[ $rc -eq 2 ] && [ ! -d "$FX/mgmt/evidence-here" ] && ok "refusal: an outdir inside the tracked tree is REFUSED (rc=2), nothing written" || bad "refusal tracked: rc=$rc"
(cd "$FX" && bash mgmt/harness/collect-failure.sh win11-cell "$T/out/badsince" reason --since yesterday) >"$T/out/badsince.out" 2>&1; rc=$?
[ $rc -eq 2 ] && ok "refusal: a --since that is not an instant is REFUSED (rc=2)" || bad "refusal since: rc=$rc"
(cd "$FX" && bash mgmt/harness/collect-failure.sh win11-cell) >"$T/out/usage.out" 2>&1; rc=$?
[ $rc -eq 2 ] && ok "refusal: missing arguments -> usage, rc=2" || bad "refusal usage: rc=$rc"

# ---- the knobs: each check seen to fail -----------------------------------------------------------------------
K=$(knob logvolgap) || exit 2; rc=$(QSTATE=Running ALIVE=1 collect "$K" k-logvolgap --since 2026-10-13T09:00:00Z --harness-cmd x)
[ "$rc" = 0 ] && [ "$(mfield k-logvolgap "r['complete']")" = True ] && ok "knob 'logvolgap': a missing volume no longer counts - the check is SEEN TO FAIL (complete=true)" || bad "knob logvolgap: rc=$rc"
K=$(knob declqwtfree) || exit 2; rc=$(QSTATE=Running ALIVE=0 CORE_STUB=ok collect "$K" k-declqf --logvol "$IMG" --since 2026-10-13T09:00:00Z --harness-cmd x --no-qrexec)
[ "$(mfield k-declqf "r['sources']['core']['status']")" = fetched ] && ok "knob 'declqwtfree': the declaration is ignored and the QWT-free guest is cored again - the check is SEEN TO FAIL" || bad "knob declqwtfree: core=$(mfield k-declqf "r['sources']['core']")"
K=$(knob qwtfreebackstop) || exit 2; rc=$(QSTATE=Running ALIVE=0 CORE_STUB=ok QREXEC_FEATURE='' collect "$K" k-backstop --logvol "$IMG" --since 2026-10-13T09:00:00Z --harness-cmd x)
[ "$(mfield k-backstop "r['sources']['core']['status']")" = fetched ] && ok "knob 'qwtfreebackstop': a forgotten flag cores a featureless guest again - the check is SEEN TO FAIL" || bad "knob qwtfreebackstop: core=$(mfield k-backstop "r['sources']['core']")"
K=$(knob qwtfreescreen) || exit 2; rc=$(QSTATE=Running ALIVE=0 collect "$K" k-qfscreen --logvol "$IMG" --since 2026-10-13T09:00:00Z --harness-cmd x --no-qrexec)
[ "$(mfield k-qfscreen "r['sources']['screen']")" = None ] && ok "knob 'qwtfreescreen': the one working instrument goes unused - the check is SEEN TO FAIL" || bad "knob qwtfreescreen: screen=$(mfield k-qfscreen "r['sources']['screen']")"
K=$(knob unresponsive) || exit 2; rc=$(QSTATE=Running ALIVE=0 CORE_STUB=ok collect "$K" k-unresp --logvol "$IMG" --since 2026-10-13T09:00:00Z --harness-cmd x)
[ "$(mfield k-unresp "r['liveness']")" = alive ] && ! grep -q 'fetch-core' "$CALLS" && ok "knob 'unresponsive': a dead guest reads as alive and no core is taken - the check is SEEN TO FAIL" || bad "knob unresponsive: liveness=$(mfield k-unresp "r['liveness']")"
# manifestlast: make the tarball fail (a tar that exits 1) - shipped: no manifest, rc=2; knob: a manifest for an unverified package
mkdir -p "$T/badbin"; printf '#!/bin/bash\nexit 1\n' > "$T/badbin/tar"; chmod +x "$T/badbin/tar"
rc=$(PATH="$T/badbin:$PATH" QSTATE=Running ALIVE=1 collect mgmt/harness/collect-failure.sh notar --logvol "$IMG" --since 2026-10-13T09:00:00Z --harness-cmd x)
[ "$rc" = 2 ] && [ ! -e "$T/out/notar/manifest.json" ] && grep -q 'COLLECT-RESULT vm=win11-cell rc=2 complete=0 manifest=none' "$T/out/notar.out" && ok "manifest last: when the tarball cannot be verified there is NO manifest and rc=2 (not collected)" || bad "manifest last: rc=$rc manifest exists=$([ -e "$T/out/notar/manifest.json" ] && echo yes || echo no)"
K=$(knob manifestlast) || exit 2; rc=$(PATH="$T/badbin:$PATH" QSTATE=Running ALIVE=1 collect "$K" k-manifest --logvol "$IMG" --since 2026-10-13T09:00:00Z --harness-cmd x)
[ -e "$T/out/k-manifest/manifest.json" ] && ok "knob 'manifestlast': a manifest exists for an unverified package - the check is SEEN TO FAIL" || bad "knob manifestlast: no manifest written"
K=$(knob snapshotgaps) || exit 2; rc=$(QSTATE=Halted collect "$K" k-snap --logvol "$IMG" --since 2026-10-13T09:00:00Z --harness-cmd x)
[ "$rc" = 0 ] && [ "$(mfield k-snap "r['complete']")" = True ] && ok "knob 'snapshotgaps': a snapshot missing its clock no longer makes the package partial - the check is SEEN TO FAIL" || bad "knob snapshotgaps: rc=$rc"
K=$(knob gaprecord) || exit 2; rc=$(QSTATE=Running ALIVE=0 CORE_STUB=refuse collect "$K" k-gap --logvol "$IMG" --since 2026-10-13T09:00:00Z --harness-cmd x)
[ "$rc" = 0 ] && [ "$(mfield k-gap "r['complete']")" = True ] && ok "knob 'gaprecord': a refused core is logged but not counted - the check is SEEN TO FAIL" || bad "knob gaprecord: rc=$rc"
# the snapshot tool's own knob: an empty corpus must say module_logs is MISSING
mkdir -p "$T/emptylogs"
python3 "$ROOT/tools/activity-snapshot.py" --out "$T/snap-empty.json" --logs "$T/emptylogs" > "$T/snap-empty.out" 2>&1; rc=$?
[ $rc -eq 1 ] && grep -q 'MISSING module_logs' "$T/snap-empty.out" && ok "snapshot: an empty corpus is PARTIAL (rc=1) and names module_logs as missing" || bad "snapshot empty: rc=$rc $(cat "$T/snap-empty.out")"
sed -E "s|^( *)[^#]*# GUARD:missingtails DEFECT: (.*)$|\1\2|" "$ROOT/tools/activity-snapshot.py" > "$T/snap-knob.py"
python3 -m py_compile "$T/snap-knob.py" && python3 "$T/snap-knob.py" --out "$T/snap-empty-k.json" --logs "$T/emptylogs" > "$T/snap-empty-k.out" 2>&1
! grep -q 'MISSING module_logs' "$T/snap-empty-k.out" && ok "snapshot: knob 'missingtails' hides the missing tails - the check is SEEN TO FAIL" || bad "snapshot knob did not hide module_logs"

echo
echo "RESULT: $pass passed, $fail failed  (fixtures: $T)"
[ "$fail" -eq 0 ]
