#!/bin/bash
# =============================================================================
# benchmark.sh - reproducible performance benchmark: STOCK QWT vs OUR gui-agent
# =============================================================================
#
#   scratchpad/benchmark.sh run stock      # 3 reps, stock QWT 4.2.2 agent installed
#   scratchpad/benchmark.sh run ours       # 3 reps, our build installed
#   scratchpad/benchmark.sh compare        # side-by-side medians + delta
#
# One command per side, as asked. But read "INTERLEAVING" below before believing any
# number produced by two back-to-back full-side runs: CLAUDE.md's rule 2 ("every build
# comparison runs at least 3 times per side, INTERLEAVED with the control") is not
# satisfied by `run stock` followed by `run ours`, and this script says so in the
# compare output rather than letting the table imply otherwise.
#
# -----------------------------------------------------------------------------
# WHAT IS MEASURABLE ON WHICH SIDE - read this before adding a metric
# -----------------------------------------------------------------------------
# Stock QWT 4.2.2 emits NO QGAPERF records: the per-frame instrumentation is ours.
# So every frame-cost/fps number in this benchmark is OURS-ONLY *by construction*.
# It cannot be fixed by trying harder on the stock side - the data does not exist.
# Therefore the metric set is split in three, and the split is enforced in code:
#
#   CROSS-SIDE  (stock + ours, genuinely comparable)
#     idle_cpu_pct, drag_cpu_pct, scroll_cpu_pct, type_cpu_pct   process CPU accounting
#     drag_ws_mb, idle_ws_mb                                     working set
#     dom0_distinct_fps / dom0_distinct_frac / dom0_pixels_moving dom0-observed PIXELS
#     vm_cpu_idle, vm_cpu_work                                   whole-VM cputime slope
#   These are the only rows in the compare table where a delta is meaningful.
#
#   INSTRUMENTED-ONLY (ours, and any control build carrying the QGAPERF patch)
#     drag_tot_p50_us / p95 / p99, drag_fps, drag_iwn, drag_dr, drag_area,
#     drag_sends, drag_snd_p50_us, scroll_tot_p50_us, type_tot_p50_us, idle_frames
#   For side=stock these are emitted as {"na": "stock build emits no QGAPERF"} - never
#   as 0, never omitted. (Missing data fails; it does not silently become a number.)
#   To get a frame-cost A/B, run the third side label `base`: our instrumentation patch
#   on the pre-Phase-2A behaviour. That is the only build pair where p50/p95 of `tot`
#   is an apples-to-apples comparison.
#
#   OURS-ONLY FEATURE (stock cannot do it at all, so there is nothing to compare)
#     resize_ttfp_ms, resize_converged
#   Stock is pinned to the Basic Display Adapter's FIXED mode list: an arbitrary size
#   such as 1234x777 is never offered, so a dom0 window resize cannot change the guest
#   resolution. On stock this is recorded as na="stock cannot resize (BDA fixed mode
#   list)" - an absent capability, not a slow one. Do not average it into anything.
#
#   Also note stock lacks per-window capture, so its dom0 window images are crops of one
#   composited desktop. dom0_distinct_* stays valid (it asks only "did the pixels the
#   user sees change"), but ws/handle counts are expected HIGHER on ours - per-window
#   framebuffers are a real cost and are reported, not hidden.
#
# -----------------------------------------------------------------------------
# SCENARIO SET (fixed, deterministic, in-guest)
# -----------------------------------------------------------------------------
# Nothing new is invented here; the scene driver is the existing
# instrumentation/drag-harness.ps1 (C# SendInput loops, absolute coordinates,
# timeBeginPeriod(1) pacing, proves SendInput reaches the input desktop before
# measuring, kills stray windows so damage volume is not a function of window
# placement, reports its own achieved cadence + jitter).
#
#   1. reset      kill notepad/chromerepro, settle                      (both sides)
#   2. idle60     60 s idle, gui-agent CPU + working set                (both sides)
#   3. workload   drag-harness.ps1: idle-pre 5s / drag 10s / scroll 10s / type 10s
#                 / idle-post 5s, with a 4 Hz CPU sampler running in parallel from a
#                 second qrexec connection; sliced per phase by the harness's own
#                 wall-clock phase markers (guest clock on both sides of the slice, so
#                 no host/guest clock-skew assumption is made)                (both sides)
#   4. dragshot   12 s drag-only, sampled from dom0 with `qtest shot`; counts how often
#                 the pixels dom0 shows actually change                       (both sides)
#   5. resize     3 dom0 window resizes, time to first correctly-sized non-flat pixel
#                                                                             (ours only)
# Each rep is ~4 minutes; 3 reps ~12 minutes per side.
#
# -----------------------------------------------------------------------------
# INTERLEAVING (what the orchestrator should actually run)
# -----------------------------------------------------------------------------
# Interleaved is strictly better than two full-side runs, and needs the binary swapped
# between reps. With --install (uses scratchpad/install-agent3.ps1 + a COLD BOOT, so the
# boot path is exercised as CLAUDE.md requires):
#
#   for r in 1 2 3; do
#     scratchpad/benchmark.sh run stock --rep $r --install ORIG:<STOCKHASH16>
#     scratchpad/benchmark.sh run ours  --rep $r --install gui-agent-ours.exe:<OURSHASH16>
#   done
#   scratchpad/benchmark.sh compare
#
# Without --install (binary swapped by the orchestrator between commands), the minimum
# is still one rep per side at a time, alternating - not 3+3.
#
# -----------------------------------------------------------------------------
# VALIDITY GATES (a run that trips one is marked invalid, not quietly averaged)
# -----------------------------------------------------------------------------
#  * running binary hash must equal --expect-hash. No --expect-hash => the rep is
#    flagged unverified and `compare` refuses to print a verdict line.
#  * side label vs QGAPERF presence: stock+QGAPERF or ours-without-QGAPERF = hard fail.
#  * gui-agent pid must not change during a phase (a restart resets CPU accounting).
#  * CPU sampler must cover >=70% of each phase, >=6 samples.
#  * harness drag cadence jitter p95 must be < BENCH_JITTER_MAX_MS (default 25 ms) -
#    otherwise the guest could not keep the input cadence and the run measures load,
#    not the build.
#  * dom0 pixel sampling reports its achieved sample rate; if distinct_frac == 1.0 the
#    metric is SATURATED (sampling-limited) and compare says so instead of implying the
#    two sides delivered the same frame rate.
#
# Everything the guest prints is parsed as data (CLAUDE.md hard rule). No field from the
# VM is used as a path or executed here.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QT="$HERE/tools/qtest"
VM="${QTEST_VM:-win-idd-test}"

# PRECONDITION (user directive 2026-08-06): no OTHER Windows qube may be running -
# a second Windows guest contends for host CPU and silently corrupts every timing
# here. Refuse rather than measure noise.
_others=$(qvm-ls --fields NAME,STATE 2>/dev/null | awk '$2=="Running"||$2=="Transient"{print $1}' \
          | grep -E '^win' | grep -v -x "$VM" | grep -v -x win-idd-mgmt || true)
if [ -n "$_others" ]; then
    echo "REFUSING: other Windows qube(s) running, would contaminate timings:" >&2
    echo "$_others" >&2
    echo "shut them down first (qvm-shutdown <vm>)" >&2
    exit 2
fi
INC="${BENCH_INC:-C:\\Users\\user\\Documents\\QubesIncoming\\win-idd-mgmt}"
OUTDIR="${BENCH_OUT:-$HERE/scratchpad/bench-results}"
GUESTDIR='C:\qbench'

DRAG_SHOT_SECONDS="${BENCH_DRAGSHOT_S:-12}"
IDLE_SECONDS="${BENCH_IDLE_S:-60}"
JITTER_MAX_MS="${BENCH_JITTER_MAX_MS:-25}"
RESIZE_TARGETS="${BENCH_RESIZE_TARGETS:-1600x1000 1234x777 2000x1000}"

now_ms() { date +%s%3N; }
log()    { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die()    { log "FATAL: $*"; exit 1; }

usage() {
    sed -n '2,120p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

# --- guest plumbing ----------------------------------------------------------
# Scripts are invoked with `powershell -File "<path>" <args>`, the form tools/bench-agent.sh
# proved works through qrexec -> cmd -> powershell. Inline `-Command` mangles the quoting
# around "C:\Program Files\..." and silently returns nothing (recorded in bench-agent.sh).
psfile() {  # psfile <script-basename> "<args>"
    printf 'powershell -NoProfile -ExecutionPolicy Bypass -File "%s\\%s" %s' "$INC" "$1" "$2"
}
probe() {  # probe "<args to bench-probe.ps1>" [timeout_s]
    timeout "${2:-180}" "$QT" run "$(psfile bench-probe.ps1 "$1")" 2>&1 | tr -d '\r\0'
}
guest_alive() {
    [ "$(timeout 25 "$QT" run 'echo ALIVE' 2>&1 | tr -d '\r\0' | grep -c ALIVE)" -ge 2 ]
}
vm_cputime_s() {  # whole-VM cpu seconds (admin.vm.CurrentState cputime is in ns)
    local c
    c=$(timeout 25 "$QT" state 2>/dev/null | tr -d '\0' | grep -oE 'cputime=[0-9]+' | cut -d= -f2)
    [ -n "$c" ] && echo $(( c / 1000000000 )) || echo ""
}
kv() { grep -oE "$2=[^ ]*" "$1" 2>/dev/null | tail -1 | cut -d= -f2-; }

push_assets() {
    "$QT" push "$HERE/scratchpad/bench-probe.ps1" \
                "$HERE/instrumentation/drag-harness.ps1" \
                "$HERE/instrumentation/collect-perf.ps1" >/dev/null 2>&1
}

# --- optional install + cold boot -------------------------------------------
install_side() {  # install_side <SrcName>:<HASH16>
    local spec="$1" src hash out
    src="${spec%%:*}"; hash="${spec##*:}"
    [ -n "$src" ] && [ -n "$hash" ] || die "--install wants <SrcName>:<HASH16>"
    [ -f "$HERE/scratchpad/install-agent3.ps1" ] || die "missing scratchpad/install-agent3.ps1"
    "$QT" push "$HERE/scratchpad/install-agent3.ps1" >/dev/null 2>&1
    out=$(timeout 120 "$QT" ps "& '$INC\\install-agent3.ps1' -SrcName $src -ExpectHash $hash" 2>&1 |
          tr -d '\r\0' | grep -E '^INSTALL=' | tail -1)
    log "install: $out"
    printf '%s' "$out" | grep -q "INSTALL=OK" || die "install failed: $out"
    printf '%s' "$out" | grep -q "hash=$hash"  || die "install hash mismatch: $out"
    # Cold boot, not an agent restart: a restart CLEARS faults a cold boot exposes.
    log "cold boot after install..."
    bash "$HERE/scratchpad/vmcycle.sh" >&2 || die "cold boot failed after install"
    sleep 20   # let the shell/session settle so idle really is idle
}

# --- one repetition ----------------------------------------------------------
run_rep() {
    # NB: bash under `set -u` cannot reference a variable being declared in the SAME
    # `local` statement - `local a="$1" b="$a"` errors "a: unbound variable". Split.
    local side="$1" rep="$2"
    local repdir="$OUTDIR/$side-r$rep"
    rm -rf "$repdir"; mkdir -p "$repdir"
    local t_start; t_start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    log "=== $side rep $rep -> $repdir ==="

    guest_alive || die "guest not answering qrexec"
    push_assets

    # ---- 0. preflight facts + the build discriminator -----------------------
    probe "-Mode info" 90 | grep -E '^INFO ' > "$repdir/info.txt"
    [ -s "$repdir/info.txt" ] || die "probe info returned nothing"
    local ahash qg
    ahash=$(kv "$repdir/info.txt" agent_hash)
    qg=$(kv "$repdir/info.txt" qgaperf_recent)
    log "  agent hash=$ahash qgaperf_recent=$qg watchdog=$(kv "$repdir/info.txt" watchdog)"
    [ "$(kv "$repdir/info.txt" agent_running)" = "True" ] || die "gui-agent not running"

    if [ -n "$EXPECT_HASH" ]; then
        [ "$ahash" = "$EXPECT_HASH" ] || die "installed binary $ahash != --expect-hash $EXPECT_HASH"
        echo "hash_verified=True" >> "$repdir/meta.txt"
    else
        log "  WARNING: no --expect-hash; this rep is UNVERIFIED"
        echo "hash_verified=False" >> "$repdir/meta.txt"
    fi

    # The side label is a claim about which build runs. Check it against evidence.
    case "$side" in
      stock)
        [ "${qg:-0}" -eq 0 ] || die "side=stock but the running agent emits QGAPERF ($qg recent records) - mislabelled build"
        ;;
      ours|base)
        [ "${qg:-0}" -gt 0 ] || die "side=$side but no QGAPERF records in the recent log - instrumented build not running (or PerfLog=0)"
        ;;
      *) die "unknown side '$side' (want stock|ours|base)" ;;
    esac

    {
      echo "side=$side"; echo "rep=$rep"; echo "started=$t_start"
      echo "expect_hash=${EXPECT_HASH:-NONE}"; echo "tag=${TAG:-}"
    } >> "$repdir/meta.txt"

    # ---- 1. deterministic scene --------------------------------------------
    probe "-Mode reset" 90 | grep -E '^RESET ' > "$repdir/reset.txt"
    log "  $(cat "$repdir/reset.txt" | tr '\n' ' ')"

    # ---- 2. idle CPU over 60 s ---------------------------------------------
    log "  idle ${IDLE_SECONDS}s..."
    local vc0 vc1 t0 t1
    vc0=$(vm_cputime_s); t0=$(date +%s)
    probe "-Mode idle -Seconds $IDLE_SECONDS -Out $GUESTDIR\\idle.txt" $((IDLE_SECONDS + 120)) \
        | grep -E '^IDLE ' > "$repdir/idle.txt"
    vc1=$(vm_cputime_s); t1=$(date +%s)
    printf 'IDLEVM vm_cpu_s=%s wall_s=%s\n' "$(( ${vc1:-0} - ${vc0:-0} ))" "$(( t1 - t0 ))" >> "$repdir/idle.txt"
    log "  $(grep '^IDLE ' "$repdir/idle.txt" | head -1)"

    # ---- 3. drag/scroll/type workload with a parallel CPU sampler ----------
    # The sampler runs on its own qrexec connection and BLOCKS for its whole duration:
    # keeping the connection open is the only way proven here to keep the process alive.
    log "  workload (drag/scroll/type) + 4Hz sampler..."
    ( probe "-Mode trace -Seconds 110 -Out $GUESTDIR\\trace.txt" 200 > "$repdir/sampler.txt" 2>&1 ) &
    local spid=$!
    sleep 3
    vc0=$(vm_cputime_s); t0=$(date +%s)
    timeout 300 "$QT" run "$(psfile drag-harness.ps1 '')" 2>&1 | tr -d '\r\0' > "$repdir/harness.txt"
    vc1=$(vm_cputime_s); t1=$(date +%s)
    printf 'WORKVM vm_cpu_s=%s wall_s=%s\n' "$(( ${vc1:-0} - ${vc0:-0} ))" "$(( t1 - t0 ))" >> "$repdir/harness.txt"
    wait "$spid" 2>/dev/null
    probe "-Mode collect -Out $GUESTDIR\\trace.txt" 150 > "$repdir/trace.txt"
    grep -cE '^SAMP ' "$repdir/trace.txt" >/dev/null 2>&1 || log "  WARNING: no trace samples collected"
    grep -E '^### PHASE-(START|END)' "$repdir/harness.txt" | sed 's/^/  /' >&2

    # ---- 4. QGAPERF records (instrumented builds only) ----------------------
    : > "$repdir/perf.txt"
    if [ "$side" != "stock" ]; then
        timeout 240 "$QT" run "$(psfile collect-perf.ps1 '')" 2>&1 | tr -d '\r\0' \
            | sed -n '/===PERFSTART===/,/===PERFEND===/p' | grep 'QGAPERF,' > "$repdir/perf.txt"
        log "  QGAPERF records: $(wc -l < "$repdir/perf.txt")"
    fi

    # ---- 5. dom0-observed pixel change rate during a drag ------------------
    dragshot "$repdir"

    # ---- 6. resize time-to-first-pixel (ours only) -------------------------
    resize_probe "$side" "$repdir"

    # ---- 7. assemble ------------------------------------------------------
    assemble "$repdir" || die "assemble failed for $repdir"
    log "  wrote $repdir/rep.json"
}

# dom0 pixel sampling: the only "did the user's pixels move" metric that works on BOTH
# sides. Sampling-limited by qtest shot's round-trip, which is measured and reported so a
# saturated result cannot be read as "the two builds are equal".
dragshot() {
    local repdir="$1"
    local out="$repdir/shots.txt" tmp="$repdir/shot.tar" i=0 started=none
    local hf="$repdir/dragshot-harness.txt"
    : > "$out"; : > "$hf"
    log "  dragshot (drag ${DRAG_SHOT_SECONDS}s)..."
    ( timeout 200 "$QT" run "$(psfile drag-harness.ps1 "-DragSeconds $DRAG_SHOT_SECONDS -ScrollSeconds 0 -TypeSeconds 0 -IdleSeconds 0")" \
        2>&1 | tr -d '\r\0' > "$hf" ) &
    local hpid=$!
    # Sample for the WHOLE harness lifetime rather than waiting for the phase marker to
    # stream through qrexec: if that stream is buffered, a marker-gated sampler would open
    # its window after the drag was over and report "no pixels moved" for a healthy build.
    # The marker is still watched, and when it arrives its host timestamp is recorded so the
    # analysis can restrict to the true drag window; if it never arrives the analysis uses
    # the full window and SAYS so.
    local deadline=$(( $(date +%s) + 120 ))
    while kill -0 "$hpid" 2>/dev/null && [ "$(date +%s)" -lt "$deadline" ]; do
        if [ "$started" = none ] && grep -q 'PHASE-START drag' "$hf" 2>/dev/null; then
            started=marker
            echo "SHOTMETA drag_start_ms=$(now_ms)" >> "$out"
        fi
        local ts0 h
        ts0=$(now_ms)
        if "$QT" shot "$tmp" >/dev/null 2>&1; then
            # sha over the tar's PNG payloads: identical pixels out of the same encoder give
            # identical bytes, so a changed hash means changed pixels in dom0.
            h=$(tar xOf "$tmp" --wildcards '*.png' 2>/dev/null | sha256sum | cut -c1-16)
            [ -z "$h" ] && h=EMPTY
        else
            h=SHOTFAIL
        fi
        echo "SHOT t_ms=$(now_ms) rt_ms=$(( $(now_ms) - ts0 )) sha=$h" >> "$out"
        i=$((i+1))
    done
    wait "$hpid" 2>/dev/null
    echo "SHOTMETA start_detected=$started samples=$i drag_s=$DRAG_SHOT_SECONDS" >> "$out"
    log "  dragshot: $i samples (drag marker: $started)"
}

resize_probe() {
    local side="$1" repdir="$2"
    local out="$repdir/resize.txt"
    : > "$out"
    if [ "$side" = "stock" ]; then
        echo 'RESIZE na=stock cannot resize (Basic Display Adapter fixed mode list - arbitrary sizes are never offered)' > "$out"
        return 0
    fi
    if ! "$QT" resize query 2>/dev/null | grep -qE 'w=[0-9]+'; then
        echo 'RESIZE na=dom0 local.WinResize service not installed (dom0/10-install-resize-service.sh) - cannot request a resize' > "$out"
        return 0
    fi
    if ! python3 -c 'import PIL.Image' 2>/dev/null; then
        # Without pixel decoding the only alternative is trusting a log line, which this
        # project has already been burned by ("recovered - windows kept" while frozen).
        echo 'RESIZE na=python3 PIL not available in this qube - cannot judge pixels, and a log-only resize verdict is not accepted' > "$out"
        return 0
    fi
    local target W H t0 ok ttfp shot="$repdir/rz.tar"
    for target in $RESIZE_TARGETS; do
        W="${target%x*}"; H="${target#*x}"
        log "  resize -> $target"
        t0=$(now_ms); ok=0; ttfp=""
        "$QT" resize "$target" >/dev/null 2>&1
        local k
        for k in $(seq 1 40); do
            if "$QT" shot "$shot" >/dev/null 2>&1; then
                rm -rf "$repdir/rz"; mkdir -p "$repdir/rz"
                tar xf "$shot" -C "$repdir/rz" 2>/dev/null
                if python3 - "$repdir/rz" "$W" <<'PY' >/dev/null 2>&1
import sys, glob
from PIL import Image
f = sorted(glob.glob(sys.argv[1] + '/**/*.png', recursive=True))
if not f: sys.exit(1)
im = Image.open(f[0]).convert('RGB')
flat = all(a == b for a, b in im.getextrema())
sys.exit(0 if (im.size[0] == int(sys.argv[2]) and not flat) else 1)
PY
                then ttfp=$(( $(now_ms) - t0 )); ok=1; break; fi
            fi
            sleep 0.5
        done
        local gres="NA"
        if timeout 60 "$QT" run "cd $INC && modeprobe.exe" 2>/dev/null | tr -d '\r\0' | grep -qE '^\{'; then
            gres=$(timeout 60 "$QT" run "cd $INC && modeprobe.exe" 2>/dev/null | tr -d '\r\0' | grep -E '^\{' | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    for x in d['devices']:
        if x.get('primary') and x.get('current'):
            print('%dx%d' % (x['current']['w'], x['current']['h'])); break
except Exception: print('NA')" )
        fi
        echo "RESIZE target=$target ok=$ok ttfp_ms=${ttfp:-} guest_res=$gres" >> "$out"
    done
}

# --- assemble one rep into JSON ---------------------------------------------
assemble() {
    python3 - "$1" "$JITTER_MAX_MS" <<'PYEOF'
import json, os, re, sys, statistics
from datetime import datetime

repdir, jitter_max = sys.argv[1], float(sys.argv[2])
def path(n): return os.path.join(repdir, n)
def lines(n):
    try:
        with open(path(n), 'r', encoding='utf-8', errors='replace') as fh:
            return [l.rstrip('\n') for l in fh]
    except OSError:
        return []

def parse_ts(s):
    return datetime.strptime(s, '%Y%m%d.%H%M%S.%f')

warnings = []
def na(reason): return {'na': reason}
def val(v, unit=None, **kw):
    d = {'value': v}
    if unit: d['unit'] = unit
    d.update(kw); return d

# ---------------- meta / info ----------------
meta = {}
for l in lines('meta.txt') + lines('info.txt') + lines('reset.txt'):
    for k, v in re.findall(r'([a-z_]+)=(\S*)', l):
        meta.setdefault(k, v)
side = meta.get('side', '?')
instrumented = side in ('ours', 'base')

# ---------------- phases (guest wall clock, from the harness itself) --------
phases = {}
for l in lines('harness.txt'):
    m = re.match(r'###\s+PHASE-(START|END)\s+(\S+)\s+(\d{8}\.\d{6}\.\d{3})', l.strip())
    if m:
        kind, name, ts = m.groups()
        phases.setdefault(name, {})[kind.lower()] = ts
phases = {k: v for k, v in phases.items() if 'start' in v and 'end' in v}
if not phases:
    warnings.append('no phase markers in harness output - the workload did not run')

cadence = {}
for l in lines('harness.txt'):
    m = re.search(r'#\s+(\S+) cadence: (.+)$', l)
    if m:
        d = dict(re.findall(r'(\w+(?:_\w+)?)=([\d.]+)', m.group(2)))
        cadence[m.group(1)] = d
harness_ok = any('"ok":  true' in l or '"ok": true' in l for l in lines('harness.txt'))
if not harness_ok:
    warnings.append('drag-harness did not report ok=true')

drag_jit = None
if 'drag' in cadence:
    # "jitter_ms p50=.. p95=.. max=.." -> the p95 key collides with nothing else here
    m = re.search(r'jitter_ms p50=([\d.]+) p95=([\d.]+)', ' '.join(
        l for l in lines('harness.txt') if 'drag cadence' in l))
    if m: drag_jit = float(m.group(2))
if drag_jit is not None and drag_jit > jitter_max:
    warnings.append('drag input cadence jitter p95=%.1fms > %.1fms - the guest could not '
                    'keep the scripted cadence; this rep measures load, not the build'
                    % (drag_jit, jitter_max))

# ---------------- CPU trace ----------------
samples = []
for l in lines('trace.txt'):
    m = re.match(r'SAMP (\d{8}\.\d{6}\.\d{3}) cpu_ms=(\d+) ws=(\d+) handles=(\d+) pid=(\d+)', l)
    if m:
        samples.append({'t': parse_ts(m.group(1)), 'cpu': int(m.group(2)),
                        'ws': int(m.group(3)), 'h': int(m.group(4)), 'pid': int(m.group(5))})
    elif l.startswith('SAMP') and 'agent=absent' in l:
        warnings.append('CPU sampler saw no gui-agent process at least once')

def cpu_phase(name):
    if name not in phases: return na('phase %s missing from harness output' % name)
    if not samples:        return na('CPU sampler produced no samples (did it die with the qrexec connection?)')
    a, b = parse_ts(phases[name]['start']), parse_ts(phases[name]['end'])
    sel = [s for s in samples if a <= s['t'] <= b]
    if len(sel) < 6:
        return na('only %d CPU samples inside phase %s (need >=6)' % (len(sel), name))
    span = (b - a).total_seconds()
    cov = (sel[-1]['t'] - sel[0]['t']).total_seconds()
    if span > 0 and cov / span < 0.70:
        return na('CPU sampler covered %.0f%% of phase %s (need >=70%%)' % (100 * cov / span, name))
    if len(set(s['pid'] for s in sel)) != 1:
        return na('gui-agent pid changed during phase %s - CPU accounting reset' % name)
    dt = (sel[-1]['t'] - sel[0]['t']).total_seconds() * 1000.0
    if dt <= 0: return na('zero wall time in phase %s' % name)
    return val(round(100.0 * (sel[-1]['cpu'] - sel[0]['cpu']) / dt, 3), '%of1core',
               samples=len(sel), coverage=round(cov / span, 3) if span else None)

def ws_phase(name):
    if name not in phases or not samples: return na('no samples for phase %s' % name)
    a, b = parse_ts(phases[name]['start']), parse_ts(phases[name]['end'])
    sel = [s['ws'] for s in samples if a <= s['t'] <= b]
    if not sel: return na('no samples inside phase %s' % name)
    return val(round(max(sel) / 1048576.0, 2), 'MB')

# ---------------- idle ----------------
idle_line = next((l for l in lines('idle.txt') if l.startswith('IDLE ')), '')
idle_kv = dict(re.findall(r'(\w+)=([^\s]+)', idle_line))
if idle_kv.get('ok') == 'True' and 'cpu_pct' in idle_kv:
    if idle_kv.get('pid_count') != '1':
        idle_cpu = na('gui-agent pid changed during the idle window (pid_count=%s)' % idle_kv.get('pid_count'))
    else:
        idle_cpu = val(float(idle_kv['cpu_pct']), '%of1core',
                       samples=int(idle_kv.get('samples', 0)),
                       wall_ms=int(idle_kv.get('wall_ms', 0)))
else:
    idle_cpu = na('idle probe returned no usable summary (%r)' % idle_line[:80])

vmline = next((l for l in lines('idle.txt') if l.startswith('IDLEVM')), '')
m = re.search(r'vm_cpu_s=(-?\d+) wall_s=(\d+)', vmline)
idle_vm = val(round(int(m.group(1)) / max(1, int(m.group(2))), 3), 'vcpu-s/s') if m and int(m.group(2)) > 0 \
          else na('whole-VM cputime unavailable')
wm = re.search(r'vm_cpu_s=(-?\d+) wall_s=(\d+)',
               next((l for l in lines('harness.txt') if l.startswith('WORKVM')), ''))
work_vm = val(round(int(wm.group(1)) / max(1, int(wm.group(2))), 3), 'vcpu-s/s') if wm and int(wm.group(2)) > 0 \
          else na('whole-VM cputime unavailable')

# ---------------- QGAPERF ----------------
REC = re.compile(r'^\[(\d{8}\.\d{6}\.\d{3})-\d+-.\]\s*(?:\w+:\s*)?QGAPERF,(v=\d+,.+)$')
frames = []
for l in lines('perf.txt'):
    m = REC.match(l.strip())
    if not m: continue
    rec = {'ts': m.group(1)}
    ok = True
    for kv in m.group(2).split(','):
        if '=' not in kv: ok = False; break
        k, v = kv.split('=', 1)
        if k == 'mode': rec[k] = v
        else:
            try: rec[k] = int(v)
            except ValueError: ok = False; break
    if ok and rec.get('n', 0) >= 1: frames.append(rec)

def pctl(vals, q):
    if not vals: return None
    vals = sorted(vals)
    return vals[min(len(vals) - 1, max(0, int(round(q * (len(vals) - 1)))))]

def qg_phase(name):
    """Per-frame stats for one harness phase. Returns dict of metric->value or None."""
    if not instrumented: return None
    if name not in phases: return None
    a, b = phases[name]['start'], phases[name]['end']
    sel = [r for r in frames if a <= r['ts'] <= b]
    if not sel: return {}
    n = sum(r['n'] for r in sel)
    span = (parse_ts(sel[-1]['ts']) - parse_ts(sel[0]['ts'])).total_seconds()
    per = lambda f: [r.get(f, 0) / float(r['n']) for r in sel]
    tot = per('tot')
    return {
        'frames': n, 'span_s': round(span, 3),
        'fps': round(n / span, 2) if span > 0 else None,
        'tot_p50': pctl(tot, .50), 'tot_p95': pctl(tot, .95), 'tot_p99': pctl(tot, .99),
        'tot_max': max(tot) if tot else None,
        'snd_p50': pctl(per('snd'), .50),
        'iwn': round(sum(r.get('iwn', 0) for r in sel) / float(n), 2),
        'dr': round(sum(r.get('dr', 0) for r in sel) / float(n), 2),
        'area': round(sum(r.get('area', 0) for r in sel) / float(n), 0),
        'sends': round(sum(r.get('sends', 0) for r in sel) / float(n), 2),
        'skip': sum(r.get('skip', 0) for r in sel),
        'mrmax': max(r.get('mrmax', 0) for r in sel),
    }

QG_NA = 'stock QWT 4.2.2 emits no QGAPERF - per-frame cost is not observable on this build'
def qg_metric(phase, key, unit=None):
    if not instrumented: return na(QG_NA)
    st = qg_phase(phase)
    if st is None: return na('phase %s missing' % phase)
    if not st:     return na('no QGAPERF records inside phase %s' % phase)
    v = st.get(key)
    return val(v, unit) if v is not None else na('%s unavailable in phase %s' % (key, phase))

# ---------------- dom0 pixel sampling ----------------
shots = [dict(re.findall(r'(\w+)=(\S+)', l)) for l in lines('shots.txt') if l.startswith('SHOT ')]
shotmeta = {}
for l in lines('shots.txt'):
    if l.startswith('SHOTMETA'): shotmeta.update(dict(re.findall(r'(\w+)=(\S+)', l)))
# Prefer the samples taken after the drag actually started. Fall back to the whole capture
# only when the marker never arrived, and record which window was used.
if shotmeta.get('drag_start_ms'):
    sel = [s for s in shots if int(s['t_ms']) >= int(shotmeta['drag_start_ms'])]
    if len(sel) >= 4:
        shots = sel
    else:
        shotmeta['start_detected'] = 'marker-but-too-few-samples-after-it'
if len(shots) >= 4:
    ts = [int(s['t_ms']) for s in shots]
    sha = [s['sha'] for s in shots]
    fails = sum(1 for s in sha if s in ('SHOTFAIL', 'EMPTY'))
    span = (ts[-1] - ts[0]) / 1000.0
    changes = sum(1 for i in range(1, len(sha)) if sha[i] != sha[i - 1])
    frac = changes / float(len(sha) - 1)
    rt = statistics.median(int(s['rt_ms']) for s in shots)
    dom0_fps = val(round(changes / span, 2) if span > 0 else None, 'distinct/s',
                   samples=len(shots), sample_fps=round((len(shots) - 1) / span, 2) if span > 0 else None,
                   distinct_frac=round(frac, 3), shot_rt_ms=rt,
                   saturated=(frac >= 0.999),
                   start_detected=shotmeta.get('start_detected'))
    dom0_frac = val(round(frac, 3), 'fraction', saturated=(frac >= 0.999))
    dom0_moving = val(changes > 0, 'bool', changes=changes)
    if fails:
        warnings.append('%d dom0 screenshots failed or were empty during the drag' % fails)
    if frac >= 0.999:
        warnings.append('dom0 pixel sampling SATURATED (every sample differed): the metric is '
                        'sampling-limited at ~%.1f Hz and cannot discriminate the two sides'
                        % ((len(shots) - 1) / span if span > 0 else 0))
    if shotmeta.get('start_detected') != 'marker':
        warnings.append('dragshot sample window was NOT aligned to the drag phase marker '
                        '(fell back to a fixed delay) - treat the rate as approximate')
else:
    r = 'fewer than 4 dom0 screenshots collected'
    dom0_fps = dom0_frac = dom0_moving = na(r)

# ---------------- resize ----------------
rz = [l for l in lines('resize.txt') if l.startswith('RESIZE ')]
rz_na = next((l.split('na=', 1)[1] for l in lines('resize.txt') if 'na=' in l), None)
if rz_na:
    resize_ttfp = resize_conv = na(rz_na)
else:
    good = [dict(re.findall(r'(\w+)=(\S+)', l)) for l in rz]
    okd = [g for g in good if g.get('ok') == '1' and g.get('ttfp_ms')]
    if okd:
        resize_ttfp = val(round(statistics.median(int(g['ttfp_ms']) for g in okd)), 'ms',
                          targets=len(good), converged=len(okd),
                          per_target={g['target']: int(g['ttfp_ms']) for g in okd})
        resize_conv = val(len(okd) == len(good) and len(good) > 0, 'bool',
                          detail=[g.get('target') + ':' + g.get('guest_res', '?') for g in good])
    else:
        resize_ttfp = na('no resize converged to a correctly-sized non-flat dom0 image')
        resize_conv = val(False, 'bool')

# ---------------- flat metric table ----------------
metrics = {
    # ---- cross-side ----
    'idle_cpu_pct':      idle_cpu,
    'idle_ws_mb':        ws_phase('idle-post'),
    'drag_cpu_pct':      cpu_phase('drag'),
    'scroll_cpu_pct':    cpu_phase('scroll'),
    'type_cpu_pct':      cpu_phase('type'),
    'idlepre_cpu_pct':   cpu_phase('idle-pre'),
    'drag_ws_mb':        ws_phase('drag'),
    'vm_cpu_idle':       idle_vm,
    'vm_cpu_work':       work_vm,
    'dom0_distinct_fps': dom0_fps,
    'dom0_distinct_frac': dom0_frac,
    'dom0_pixels_moving': dom0_moving,
    # ---- instrumented-only ----
    'drag_tot_p50_us':   qg_metric('drag', 'tot_p50', 'us'),
    'drag_tot_p95_us':   qg_metric('drag', 'tot_p95', 'us'),
    'drag_tot_p99_us':   qg_metric('drag', 'tot_p99', 'us'),
    'drag_fps':          qg_metric('drag', 'fps', 'fps'),
    'drag_iwn':          qg_metric('drag', 'iwn', 'windows/frame'),
    'drag_dr':           qg_metric('drag', 'dr', 'rects/frame'),
    'drag_area_px':      qg_metric('drag', 'area', 'px/frame'),
    'drag_sends':        qg_metric('drag', 'sends', 'msgs/frame'),
    'drag_snd_p50_us':   qg_metric('drag', 'snd_p50', 'us'),
    'scroll_tot_p50_us': qg_metric('scroll', 'tot_p50', 'us'),
    'scroll_tot_p95_us': qg_metric('scroll', 'tot_p95', 'us'),
    'type_tot_p50_us':   qg_metric('type', 'tot_p50', 'us'),
    'type_tot_p95_us':   qg_metric('type', 'tot_p95', 'us'),
    'idle_frames':       qg_metric('idle-post', 'frames', 'frames'),
    # ---- ours-only feature ----
    'resize_ttfp_ms':    resize_ttfp,
    'resize_converged':  resize_conv,
}

out = {
    'side': side, 'rep': meta.get('rep'), 'started': meta.get('started'),
    'tag': meta.get('tag', ''),
    'agent': {k: meta.get(k) for k in
              ('agent_hash', 'agent_ver', 'agent_size', 'agent_pid', 'agent_uptime_s',
               'watchdog', 'log', 'qgaperf_recent', 'screen', 'os_boot')},
    'hash_verified': meta.get('hash_verified') == 'True',
    'instrumented': instrumented,
    'harness': {'ok': harness_ok, 'cadence': cadence, 'drag_jitter_p95_ms': drag_jit,
                'phases': phases},
    'qgaperf_frames': len(frames),
    'valid': (harness_ok and bool(phases) and
              (drag_jit is None or drag_jit <= jitter_max)),
    'warnings': warnings,
    'metrics': metrics,
}
with open(os.path.join(repdir, 'rep.json'), 'w', encoding='utf-8') as fh:
    json.dump(out, fh, indent=2, sort_keys=True)
print('assembled %s: valid=%s warnings=%d qgaperf=%d'
      % (repdir, out['valid'], len(warnings), len(frames)))
for w in warnings:
    print('  WARNING: ' + w)
PYEOF
}

# --- compare -----------------------------------------------------------------
compare() {
    python3 - "$OUTDIR" <<'PYEOF'
import glob, json, os, statistics, sys

outdir = sys.argv[1]
runs = []
for p in sorted(glob.glob(os.path.join(outdir, '*', 'rep.json'))):
    try:
        with open(p, encoding='utf-8') as fh: runs.append(json.load(fh))
    except Exception as e:
        print('skipping %s: %s' % (p, e))
if not runs:
    print('no results in %s - run `benchmark.sh run <side>` first' % outdir); sys.exit(1)

SCOPE_BOTH, SCOPE_INSTR, SCOPE_OURS = 'both', 'instrumented', 'ours-only'
# (key, label, scope, better-direction, what a difference PROVES)
METRICS = [
 ('idle_cpu_pct',      'idle gui-agent CPU (60s)',      SCOPE_BOTH,  'lower',
  'no idle busy-loop / re-assert churn'),
 ('idle_ws_mb',        'idle working set',              SCOPE_BOTH,  'lower',
  'memory cost of per-window buffers at rest'),
 ('drag_cpu_pct',      'gui-agent CPU during drag',     SCOPE_BOTH,  'lower',
  'the cross-side proxy for per-frame cost'),
 ('scroll_cpu_pct',    'gui-agent CPU during scroll',   SCOPE_BOTH,  'lower',
  'scroll-path cost'),
 ('type_cpu_pct',      'gui-agent CPU during typing',   SCOPE_BOTH,  'lower',
  'typing-path cost (small single-window damage)'),
 ('drag_ws_mb',        'peak working set during drag',  SCOPE_BOTH,  'lower',
  'per-window capture memory cost (ours expected higher)'),
 ('vm_cpu_work',       'whole-VM CPU during workload',  SCOPE_BOTH,  'lower',
  'cost outside gui-agent (DWM, capture threads)'),
 ('dom0_distinct_fps', 'dom0 distinct frames/s (drag)', SCOPE_BOTH,  'higher',
  'pixels actually reaching dom0 - output, not logs'),
 ('dom0_distinct_frac','dom0 changed-sample fraction',  SCOPE_BOTH,  'higher',
  '1.000 == sampling-limited, metric saturated'),
 ('dom0_pixels_moving','dom0 pixels moved at all',      SCOPE_BOTH,  'higher',
  'floor check: the drag was visible in dom0'),
 ('drag_tot_p50_us',   'drag frame cost p50',           SCOPE_INSTR, 'lower',
  'median per-frame agent cost (bar: 5000us)'),
 ('drag_tot_p95_us',   'drag frame cost p95',           SCOPE_INSTR, 'lower',
  'tail per-frame cost - what a drag stutter is'),
 ('drag_tot_p99_us',   'drag frame cost p99',           SCOPE_INSTR, 'lower', 'worst-case tail'),
 ('drag_fps',          'frames/s processed during drag',SCOPE_INSTR, 'higher',
  'frames the agent actually delivered'),
 ('drag_iwn',          'windows interrogated / frame',  SCOPE_INSTR, 'lower',
  'the Phase 2A headline (was ~67/frame)'),
 ('drag_dr',           'dirty rects / frame',           SCOPE_INSTR, 'lower', 'damage granularity'),
 ('drag_area_px',      'dirty pixels / frame',          SCOPE_INSTR, 'lower', 'repaint volume'),
 ('drag_sends',        'vchan messages / frame',        SCOPE_INSTR, 'lower', 'protocol chattiness'),
 ('drag_snd_p50_us',   'vchan send cost p50',           SCOPE_INSTR, 'lower', 'transport cost'),
 ('scroll_tot_p50_us', 'scroll frame cost p50',         SCOPE_INSTR, 'lower', 'scroll latency proxy'),
 ('scroll_tot_p95_us', 'scroll frame cost p95',         SCOPE_INSTR, 'lower', 'scroll tail'),
 ('type_tot_p50_us',   'typing frame cost p50',         SCOPE_INSTR, 'lower', 'typing latency proxy'),
 ('type_tot_p95_us',   'typing frame cost p95',         SCOPE_INSTR, 'lower', 'typing tail'),
 ('idle_frames',       'frames processed while idle',   SCOPE_INSTR, 'lower', 'idle wakeups'),
 ('resize_ttfp_ms',    'resize time-to-first-pixel',    SCOPE_OURS,  'lower',
  'dom0 window resize -> correctly sized guest pixels'),
 ('resize_converged',  'resize converged (all targets)',SCOPE_OURS,  'higher',
  'the feature works at all'),
]

sides = []
for r in runs:
    if r['side'] not in sides: sides.append(r['side'])
sides.sort(key=lambda s: {'stock': 0, 'base': 1, 'ours': 2}.get(s, 3))
by = {s: [r for r in runs if r['side'] == s] for s in sides}

def med(side, key):
    vals, nas = [], []
    for r in by[side]:
        m = r['metrics'].get(key, {})
        if 'value' in m and m['value'] is not None:
            v = m['value']
            if isinstance(v, bool): v = 1.0 if v else 0.0
            vals.append(float(v))
        elif 'na' in m: nas.append(m['na'])
    if vals: return statistics.median(vals), len(vals), None
    return None, 0, (nas[0] if nas else 'no data')

def fmt(v):
    if v is None: return '-'
    if abs(v) >= 1000: return '%.0f' % v
    if abs(v) >= 10:   return '%.1f' % v
    return '%.3f' % v

print('=' * 100)
print('BENCHMARK COMPARE   %s' % outdir)
print('=' * 100)

# ---- run inventory + validity ------------------------------------------------
print('\n-- runs --')
unverified = invalid = 0
for r in sorted(runs, key=lambda r: (r.get('started') or '')):
    flags = []
    if not r.get('hash_verified'): flags.append('UNVERIFIED-HASH'); unverified += 1
    if not r.get('valid'):         flags.append('INVALID'); invalid += 1
    print('  %-6s rep %-3s %-21s agent=%s qgaperf=%-6d %s'
          % (r['side'], r.get('rep'), r.get('started'), r['agent'].get('agent_hash'),
             r.get('qgaperf_frames', 0), ' '.join(flags)))
    for w in r.get('warnings', []): print('        warn: ' + w)

side_hashes = {}
for s in sides:
    hashes = set(r['agent'].get('agent_hash') for r in by[s])
    side_hashes[s] = hashes
    if len(hashes) > 1:
        print('\n  *** ERROR: side %s ran with MORE THAN ONE binary %s - its reps are not '
              'a single build and must not be pooled.' % (s, sorted(hashes)))
# Two different side labels reporting the SAME binary means the swap did not happen and the
# "comparison" is one build against itself. This must be impossible to miss.
mislabelled = False
for i, s in enumerate(sides):
    for t in sides[i + 1:]:
        common = side_hashes[s] & side_hashes[t]
        if common:
            mislabelled = True
            print('\n  *** ERROR: sides %s and %s both ran binary %s - the build was NEVER '
                  'SWAPPED. These results compare one build against itself; discard them.'
                  % (s, t, sorted(common)[0]))

# ---- interleaving check (CLAUDE.md: comparisons must be interleaved) --------
order = [r['side'] for r in sorted(runs, key=lambda r: (r.get('started') or ''))]
alternating = all(order[i] != order[i + 1] for i in range(len(order) - 1)) if len(order) > 1 else False
print('\n-- protocol --')
print('  run order      : %s' % ' -> '.join(order))
print('  interleaved    : %s' % ('YES' if alternating else
      'NO  <-- reps were run in blocks; per CLAUDE.md rule 2 a block comparison is weaker '
      'evidence than an interleaved one (scene state drifts between blocks)'))
for s in sides:
    print('  %-6s reps     : %d %s' % (s, len(by[s]),
          '' if len(by[s]) >= 3 else '<-- fewer than the required 3'))
if unverified:
    print('  *** %d rep(s) ran without --expect-hash: it is NOT proven that the build under '
          'test was installed. No verdict is printed below.' % unverified)

# ---- the table ---------------------------------------------------------------
base = 'stock' if 'stock' in sides else (sides[0] if sides else None)
cmpside = 'ours' if 'ours' in sides else None
w = 32
print('\n-- medians (%d rep(s) per side) --' % max((len(by[s]) for s in sides), default=0))
hdr = '%-*s' % (w, 'metric') + ''.join('%14s' % s for s in sides)
if base and cmpside and base != cmpside: hdr += '%16s' % ('delta %s' % cmpside)
print(hdr); print('-' * len(hdr))
cur_scope = None
for key, label, scope, better, proves in METRICS:
    if scope != cur_scope:
        cur_scope = scope
        title = {'both': 'CROSS-SIDE (comparable)',
                 'instrumented': 'INSTRUMENTED BUILDS ONLY (stock has no QGAPERF)',
                 'ours-only': 'OURS-ONLY FEATURE (stock cannot do it)'}[scope]
        print('\n[%s]' % title)
    row = '%-*s' % (w, label)
    cells = {}
    for s in sides:
        v, n, reason = med(s, key)
        cells[s] = (v, reason)
        row += '%14s' % (fmt(v) if v is not None else 'n/a')
    if base and cmpside and base != cmpside:
        a, b = cells.get(base, (None, None))[0], cells.get(cmpside, (None, None))[0]
        if a is not None and b is not None and a != 0:
            d = (b - a) / abs(a) * 100.0
            if abs(d) < 1.0:
                row += '%16s' % ('%+.1f%% same' % d)
            else:
                good = (d < 0) if better == 'lower' else (d > 0)
                row += '%16s' % ('%+.1f%% %s' % (d, 'better' if good else 'worse'))
        else:
            row += '%16s' % '-'
    print(row)
    for s in sides:
        v, reason = cells[s]
        if v is None and reason:
            print('     %-6s n/a: %s' % (s, reason[:88]))

print('\n-- what each metric proves --')
for key, label, scope, better, proves in METRICS:
    print('  %-32s %-14s %s' % (label, scope, proves))

print('\n-- reading this table --')
print('  * delta is computed only where BOTH sides produced a number. An "n/a" is a')
print('    missing capability or missing data, never a zero.')
print('  * dom0_distinct_frac == 1.000 means the dom0 sampler saturated: both sides')
print('    delivered at least the sample rate, and the row proves nothing beyond that.')
print('  * drag frame-cost rows compare our build against the *instrumented control*')
print('    (side `base`), not against stock - stock cannot report per-frame cost.')
if unverified or invalid or mislabelled:
    print('\n  VERDICT WITHHELD: %d unverified rep(s), %d invalid rep(s), same-binary-both-sides=%s.'
          % (unverified, invalid, mislabelled))
PYEOF
}

# --- selftest: exercise the parsers on synthetic input, no VM involved -------
selftest() {
    local d; d="$(mktemp -d)"; local r="$d/ours-r1"; mkdir -p "$r"
    {
      echo "INFO agent_running=True"; echo "INFO agent_pid=1234"
      echo "INFO agent_hash=ABCDEF0123456789"; echo "INFO agent_ver=4.2.2.0"
      echo "INFO agent_size=80968"; echo "INFO watchdog=Running"
      echo "INFO log=gui-agent-x.log"; echo "INFO qgaperf_recent=42"
      echo "INFO screen=2566x1022"; echo "INFO os_boot=20260806.100000"
    } > "$r/info.txt"
    { echo "side=ours"; echo "rep=1"; echo "started=2026-08-06T10:00:00Z"; echo "hash_verified=True"; } > "$r/meta.txt"
    echo "RESET killed_left=0 stamp=20260806.100000.000" > "$r/reset.txt"
    {
      echo "IDLE ok=True samples=240 wall_ms=60000 cpu_ms=180 cpu_pct=0.300 pid_count=1 out=x stamp=20260806.100100.000"
      echo "IDLEVM vm_cpu_s=3 wall_s=62"
    } > "$r/idle.txt"
    {
      echo "### PHASE-START idle-pre 20260806.100200.000"
      echo "### PHASE-END   idle-pre 20260806.100205.000"
      echo "### PHASE-START drag 20260806.100207.000"
      echo "#   drag cadence: steps=600 wall_ms=10001 want_ms=10000 jitter_ms p50=15.88 p95=16.24 max=16.39"
      echo "### PHASE-END   drag 20260806.100217.000"
      echo "### PHASE-START scroll 20260806.100219.000"
      echo "#   scroll cadence: steps=200 wall_ms=10000 want_ms=10000 jitter_ms p50=49.38 p95=49.57 max=49.79"
      echo "### PHASE-END   scroll 20260806.100229.000"
      echo "### PHASE-START type 20260806.100231.000"
      echo "### PHASE-END   type 20260806.100241.000"
      echo "### PHASE-START idle-post 20260806.100243.000"
      echo "### PHASE-END   idle-post 20260806.100248.000"
      echo '    "ok":  true,'
      echo "WORKVM vm_cpu_s=20 wall_s=50"
    } > "$r/harness.txt"
    python3 - "$r/trace.txt" <<'PY'
import sys, datetime
t = datetime.datetime(2026, 8, 6, 10, 2, 0)
with open(sys.argv[1], 'w') as fh:
    fh.write('===TRACESTART===\n')
    cpu = 1000
    for i in range(400):
        ts = t + datetime.timedelta(milliseconds=250 * i)
        cpu += 40 if 28 <= i * 0.25 - 7 <= 100 else 5
        fh.write('SAMP %s cpu_ms=%d ws=%d handles=300 pid=1234\n'
                 % (ts.strftime('%Y%m%d.%H%M%S.') + '%03d' % (ts.microsecond // 1000),
                    cpu, 60 * 1048576))
    fh.write('===TRACEEND===\n')
PY
    python3 - "$r/perf.txt" <<'PY'
import sys, datetime, random
random.seed(7)
t = datetime.datetime(2026, 8, 6, 10, 2, 7)
with open(sys.argv[1], 'w') as fh:
    for i in range(600):
        ts = t + datetime.timedelta(milliseconds=16 * i)
        fh.write('[%s-2820-I] PerfEmitFrame: QGAPERF,v=2,seq=%d,n=1,mode=s,dt=16000,acq=15000,'
                 'wak=100,mrq=10,drq=40,upd=20,enu=100,rem=10,dmg=200,snd=50,tot=%d,dr=2,mr=0,'
                 'mrmax=0,area=450000,win=3,iwn=1,wev=1,sends=3,skip=0,log=30\n'
                 % (ts.strftime('%Y%m%d.%H%M%S.') + '%03d' % (ts.microsecond // 1000),
                    i + 1, 600 + random.randint(0, 400)))
PY
    { echo "SHOTMETA drag_start_ms=5000"
      # 4 pre-drag samples that must be excluded, then 12 drag samples where the pixels
      # change on 2 of every 3 steps (i.e. NOT saturated - exercises that branch too)
      for i in $(seq 1 4);  do echo "SHOT t_ms=$((1000 + i * 500)) rt_ms=450 sha=static0"; done
      for i in $(seq 1 12); do echo "SHOT t_ms=$((5200 + i * 900)) rt_ms=850 sha=$((i / 2))abcdef"; done
      echo "SHOTMETA start_detected=marker samples=16 drag_s=12"
    } > "$r/shots.txt"
    { echo "RESIZE target=1600x1000 ok=1 ttfp_ms=2400 guest_res=1600x1000"
      echo "RESIZE target=1234x777 ok=1 ttfp_ms=2900 guest_res=1234x777"
      echo "RESIZE target=2000x1000 ok=1 ttfp_ms=2600 guest_res=2000x1000"; } > "$r/resize.txt"

    # a stock rep: same shape, no QGAPERF, resize unavailable
    local s="$d/stock-r1"; cp -r "$r" "$s"
    sed -i 's/side=ours/side=stock/' "$s/meta.txt"
    sed -i 's/qgaperf_recent=42/qgaperf_recent=0/' "$s/info.txt"
    sed -i 's/agent_hash=ABCDEF0123456789/agent_hash=0011223344556677/' "$s/info.txt"
    : > "$s/perf.txt"
    echo 'RESIZE na=stock cannot resize (Basic Display Adapter fixed mode list)' > "$s/resize.txt"
    sed -i 's/started=2026-08-06T10:00:00Z/started=2026-08-06T09:50:00Z/' "$s/meta.txt"

    OUTDIR="$d"
    assemble "$r" || return 1
    assemble "$s" || return 1
    compare
    echo
    echo "selftest artifacts in $d"

    # Negative control: a check that has never been seen to FAIL is not evidence
    # (CLAUDE.md, "No result counts until the instrument is validated", rule 5).
    # Re-run compare with the swap deliberately not done (both sides on one binary)
    # and require the mislabel detector to fire.
    local n="$d/neg"; mkdir -p "$n"
    cp -r "$r" "$n/ours-r1"; cp -r "$r" "$n/stock-r1"
    sed -i 's/side=ours/side=stock/' "$n/stock-r1/meta.txt"
    sed -i 's/qgaperf_recent=42/qgaperf_recent=0/' "$n/stock-r1/info.txt"
    : > "$n/stock-r1/perf.txt"
    OUTDIR="$n"; assemble "$n/ours-r1" >/dev/null; assemble "$n/stock-r1" >/dev/null
    if compare | grep -q 'the build was NEVER SWAPPED'; then
        echo 'NEGATIVE CONTROL 1 PASS: same-binary-both-sides is detected'
    else
        echo 'NEGATIVE CONTROL 1 FAIL: same-binary-both-sides went undetected'; return 1
    fi

    # Control 2: a run where the guest could not keep the scripted input cadence must be
    # marked invalid, not averaged in.
    local j="$d/jitter/ours-r9"; mkdir -p "$j"; cp "$r"/*.txt "$j/"
    sed -i 's/p95=16.24/p95=61.24/' "$j/harness.txt"
    OUTDIR="$d/jitter"; assemble "$j" >/dev/null
    if python3 -c "import json,sys; d=json.load(open('$j/rep.json')); sys.exit(0 if not d['valid'] else 1)"; then
        echo 'NEGATIVE CONTROL 2 PASS: a run with excessive input-cadence jitter is invalid'
    else
        echo 'NEGATIVE CONTROL 2 FAIL: high jitter did not invalidate the run'; return 1
    fi

    # Control 3: a dead CPU sampler must produce n/a, never a number.
    local k="$d/nosamp/ours-r9"; mkdir -p "$k"; cp "$r"/*.txt "$k/"
    grep -v '^SAMP' "$r/trace.txt" > "$k/trace.txt"
    OUTDIR="$d/nosamp"; assemble "$k" >/dev/null
    if python3 -c "import json,sys; d=json.load(open('$k/rep.json')); sys.exit(0 if 'na' in d['metrics']['drag_cpu_pct'] else 1)"; then
        echo 'NEGATIVE CONTROL 3 PASS: a dead CPU sampler yields n/a, not a number'
    else
        echo 'NEGATIVE CONTROL 3 FAIL: drag_cpu_pct got a value with no samples'; return 1
    fi
    OUTDIR="$d"
    python3 - "$r/rep.json" "$s/rep.json" <<'PY'
import json, sys
ours = json.load(open(sys.argv[1])); stock = json.load(open(sys.argv[2]))
fails = []
if not ours['metrics']['drag_tot_p50_us'].get('value'): fails.append('ours drag_tot_p50_us missing')
if 'na' not in stock['metrics']['drag_tot_p50_us']:     fails.append('stock drag_tot_p50_us should be n/a')
if 'na' not in stock['metrics']['resize_ttfp_ms']:      fails.append('stock resize should be n/a')
if not ours['metrics']['drag_cpu_pct'].get('value'):    fails.append('ours drag_cpu_pct missing')
if not stock['metrics']['drag_cpu_pct'].get('value'):   fails.append('stock drag_cpu_pct missing (cross-side!)')
if not ours['valid']:                                   fails.append('ours rep should be valid')
print('SELFTEST ' + ('FAIL: ' + '; '.join(fails) if fails else 'PASS'))
sys.exit(1 if fails else 0)
PY
}

# --- main --------------------------------------------------------------------
CMD="${1:-}"; shift || true
EXPECT_HASH=""; INSTALL=""; PUSHBIN=""; REPS=3; SINGLE_REP=""; TAG=""

case "$CMD" in
  run)
    SIDE="${1:-}"; shift || true
    [ -n "$SIDE" ] || usage
    while [ $# -gt 0 ]; do
      case "$1" in
        --reps)        REPS="$2"; shift 2 ;;
        --rep)         SINGLE_REP="$2"; shift 2 ;;
        --expect-hash) EXPECT_HASH="$2"; shift 2 ;;
        --install)     INSTALL="$2"; EXPECT_HASH="${2##*:}"; shift 2 ;;
        --push)        PUSHBIN="$2"; shift 2 ;;
        --outdir)      OUTDIR="$2"; shift 2 ;;
        --tag)         TAG="$2"; shift 2 ;;
        *) usage ;;
      esac
    done
    mkdir -p "$OUTDIR"
    [ -x "$QT" ] || die "tools/qtest not executable at $QT"
    if [ -n "$PUSHBIN" ]; then
        [ -f "$PUSHBIN" ] || die "--push file not found: $PUSHBIN"
        "$QT" push "$PUSHBIN" >/dev/null 2>&1 || die "push failed"
        log "pushed $(basename "$PUSHBIN")"
    fi
    if [ -n "$SINGLE_REP" ]; then
        [ -n "$INSTALL" ] && install_side "$INSTALL"
        run_rep "$SIDE" "$SINGLE_REP"
    else
        for i in $(seq 1 "$REPS"); do
            [ -n "$INSTALL" ] && install_side "$INSTALL"
            run_rep "$SIDE" "$i"
        done
    fi
    log "done. Now run: $0 compare"
    ;;
  compare)
    while [ $# -gt 0 ]; do
      case "$1" in --outdir) OUTDIR="$2"; shift 2 ;; *) usage ;; esac
    done
    compare
    ;;
  doctor)
    [ -x "$QT" ] || die "tools/qtest not executable"
    guest_alive && log "qrexec: OK" || die "qrexec: guest not answering"
    push_assets
    probe "-Mode info" 90 | grep -E '^INFO '
    "$QT" resize query 2>&1 | head -2
    ;;
  selftest) selftest ;;
  *) usage ;;
esac
