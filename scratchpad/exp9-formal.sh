#!/bin/bash
# ============================================================================
# EXP 9 - THE FORMAL GATING MEASUREMENT (PLAN-trackb-t2-modes.md SS2.4, SS7 row 9)
#
# The 2026-08-04 (close) FINDINGS entry recorded Outcome A from HOT measurements and
# explicitly owed "formal 3x interleaved cold-boot runs ... for the record". This script
# is that record: 3 interleaved rounds of [BDA-primary CONTROL, IDD-primary TEST], one
# COLD BOOT per side (6 measurement boots; SS7 row 9 budget = 6).
#
# Per side:
#   PREPARE (on the previous side's running instance - the mutation window):
#     1. inventory PnP display devices (BDA = PCI\*, IDD = ROOT\DISPLAY\*; the
#        ROOT\BASICDISPLAY fallback is tracked separately and never targeted)
#     2. ARM the PnP revert marker (C:\qubes-idd\revert-request.txt) with the instance id
#        of the device about to be detached (control side: IDD; test side: BDA), so a
#        reboot out of a wedged mutation auto-recovers (QubesIddPnpRevert boot task,
#        proven on the real target 2026-08-04 item 6)
#     3. topology mutation: enable target adapter -> modeprobe --solo 1920x1080 on the
#        target's GDI name -> disable the other adapter -> converge/verify
#        (also pins FullscreenWidth/Height cache to 1920x1080 so the agent's boot path
#        is deterministic on both sides; 1920x1080 is in BOTH mode lists)
#     4. HOT health check: qrexec alive + decoded-pixel dom0 window at 1920 wide, non-flat
#     5. DISARM the marker - only after the health check passes. The measurement boot
#        runs disarmed on purpose: the boot task re-enables whenever the marker exists,
#        which would silently revert the topology under the measurement (this is exactly
#        what the 2026-08-04 exp-7 proof run demonstrated). Manual recovery for a
#        headless-but-qrexec-alive boot is printed by every STOP message.
#   MEASURE (cold boot):
#     6. COLD BOOT = qtest shutdown -> poll Halted -> qtest start -> poll qrexec
#        (soak-full.sh liveness model; a shutdown or boot that does not converge is a
#        HARD STOP with state frozen for forensics - no kill, no retry)
#     7. settle 75 s (M6 boot publish / work-area feed repopulation window), then TWO
#        modeprobe reads 15 s apart must both show: target device primary + attached at
#        1920x1080, ZERO other attached displays (persistence + stability gate)
#     8. formal topology assert: modeprobe --solo 1920x1080 --device <GDI name discovered
#        from THIS boot's modeprobe JSON> must exit 0 with match=true; its device name
#        must equal the persistence read's primary
#     9. PnP cross-check: other adapter still 'disabled' (the boot task must NOT have
#        fired), marker absent
#    10. hash-verify the on-guest ddaprobe.exe: SHA256 prefix must be 30F6012D0DA2753E
#        (the CI build validated in exp 0/0b; CLAUDE.md instrument rule 3)
#    11. run instrumentation/activity-gen.ps1 (45 s, session 1, Start-Process) CONCURRENTLY
#        with ddaprobe.exe 100 30 --json (idle desktops acquire ~1 frame/15 s - the
#        latency numbers are void without activity; SS2.4)
#    12. pull the JSON to instrumentation/exp9/round-N-{bda,idd}.json and evaluate the
#        SS2.4 acceptance fields (see eval_json below). NOTE: ddaprobe's process exit
#        code is NOT a verdict - it exits 0 whenever duplication succeeds, even with the
#        flag FALSE (FINDINGS 2026-08-04 cont 3). Only the JSON counts.
#    13. post-measure health: qrexec alive + decoded pixels again
#
# STOP-at-first-anomaly: every failed check calls stop(), which freezes state (no
# recovery attempt) and logs the manual headless-recovery recipe. Log:
# instrumentation/exp9/log.txt (append; each run stamps a header).
#
# VM ops are STRICTLY SERIAL (CLAUDE.md). Do not run this alongside any other harness.
# The only concurrency anywhere is guest-side Start-Process of activity-gen.ps1.
#
# The gui-agent stays RUNNING during the probe - deliberately: exp 0's 3/3 baseline and
# every informal hot measurement ran under the same condition, so the formal record is
# comparable to them (and to what the agent will actually experience).
#
# Preconditions (asserted, not assumed):
#   - guest has the CI ddaprobe.exe + a --solo-capable modeprobe.exe in QubesIncoming
#   - C:\qubes-idd\devcon.exe + pnp-revert-action.ps1 present, QubesIddPnpRevert task
#     registered (guest/pnp-revert-setup.ps1, branch scratch/d0-monitor3-control @dcc38a6)
#   - VM shell is elevated (UAC disabled on this VM - established provisioning state)
#   - python3 + PIL on the dev side (same as soak-full.sh)
#
# End state: guest left IDD-primary at 1920x1080, BDA disabled, marker disarmed (the
# intended steady config per FINDINGS 2026-08-05 boot acceptance). Restoring the user's
# preferred size afterwards is a dom0 resize away and is NOT done here.
#
# Verdict scoping (SS2.4): a PASS is Outcome A for THIS configuration only - current
# D4v3+M1 driver, WARP renderer, 19045, 1920x1080 solo topology. Do not port to GPU
# guests; re-measure if adapter caps or the mode source change.
# ============================================================================
set -u

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1

EXPECTED_DDAPROBE_SHA16='30F6012D0DA2753E'
INC='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
QIDD='C:\qubes-idd'
W=1920; H=1080
ROUNDS=3
OUTDIR="$REPO/instrumentation/exp9"
LOG="$OUTDIR/log.txt"
TMPD="${EXP9_TMP:-$(mktemp -d /tmp/exp9.XXXXXX)}"
VMNAME="${QTEST_VM:-win-idd-test}"

mkdir -p "$OUTDIR" "$TMPD"

# Set per side before any mutation; printed by stop() for manual recovery.
LAST_DISABLED_ID='(none yet)'

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" | tee -a "$LOG"; }

stop() {
    log "EXP9 STOP: $*"
    log "EXP9 STOP: state FROZEN for forensics - no recovery attempted, no kill issued."
    log "EXP9 STOP: headless recovery (if qrexec still answers): write the disabled adapter's"
    log "EXP9 STOP:   instance id [$LAST_DISABLED_ID] to $QIDD\\revert-request.txt and reboot;"
    log "EXP9 STOP:   the QubesIddPnpRevert boot task re-enables it (proven 2026-08-04)."
    log "EXP9 STOP: if qrexec is dead too: dom0 forensics first (protocol in"
    log "EXP9 STOP:   instrumentation/hang-2026-08-04/), then qtest kill + start."
    exit 1
}

# ---- guest plumbing ---------------------------------------------------------
# All guest output is stripped of \r and NUL (the Admin API NUL byte made an earlier
# harness check silently void - FINDINGS 2026-08-05 cont 3).

qrun() { # $1=cmdline  $2=timeout(s, default 90)
    timeout "${2:-90}" ./tools/qtest run "$1" 2>&1 | tr -d '\r\0'
}

ghelper() { # $1=helper args  $2=timeout
    qrun "powershell -NoProfile -ExecutionPolicy Bypass -File $INC\\exp9-guest.ps1 $1" "${2:-180}"
}

kv() { # $1=captured output  $2=key   -> value of "EXP9 key=value" (first match)
    printf '%s\n' "$1" | sed -n "s/^EXP9 $2=//p" | head -1
}

alive() { # soak-full.sh model: >=2 because cmd echoes the command line back
    [ "$(qrun 'echo ALIVE' 25 | grep -c ALIVE)" -ge 2 ]
}

vmstate() {
    qvm-ls --fields NAME,STATE 2>/dev/null | awk -v vm="$VMNAME" '$1==vm{print $2}'
}

mp_json() { # plain modeprobe read -> single VALIDATED JSON line on stdout (empty on failure)
    # Retry-on-garbage: the first read after a cold boot can yield an empty or
    # truncated line while the session warms (measured: round-1-bda stopped on a
    # non-JSON first read while the topology was actually fine). Up to 4 tries.
    local line try
    for try in 1 2 3 4; do
        line=$(qrun "cd $INC && modeprobe.exe" 120 | grep -E '^\{' | head -1)
        if [ -n "$line" ] && printf '%s' "$line" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
            printf '%s\n' "$line"
            return 0
        fi
        sleep 15
    done
    return 1
}

# ---- cold boot (soak-full.sh reboot_vm, hardened to STOP not return) --------
cold_boot() {
    log "cold boot: shutdown..."
    timeout 200 ./tools/qtest shutdown >/dev/null 2>&1
    local st=""
    for _ in $(seq 1 60); do st="$(vmstate)"; [ "$st" = "Halted" ] && break; sleep 5; done
    [ "$st" = "Halted" ] || stop "shutdown did not converge (state=$st) - shutdown-path wedge"
    log "cold boot: start..."
    timeout 200 ./tools/qtest start >/dev/null 2>&1
    for _ in $(seq 1 30); do alive && { log "cold boot: qrexec alive"; return 0; } ; sleep 10; done
    stop "guest unresponsive after start (qrexec never answered)"
}

# ---- decoded-pixel health (byte-wise tar diff is a killed option - SS5) -----
shot_ok() { # $1=expected width
    ./tools/qtest shot "$TMPD/shot.tar" >/dev/null 2>&1 || return 1
    rm -rf "$TMPD/shot" && mkdir -p "$TMPD/shot" && tar xf "$TMPD/shot.tar" -C "$TMPD/shot" 2>/dev/null
    python3 - "$TMPD/shot" "$1" <<'PYEOF'
import sys, glob
from PIL import Image
f = sorted(glob.glob(sys.argv[1] + '/**/*.png', recursive=True))
if not f:
    print('PIXELS FAIL no-window'); sys.exit(1)
im = Image.open(f[0]).convert('RGB')
flat = all(a == b for a, b in im.getextrema())
ok = im.size[0] == int(sys.argv[2]) and not flat
print('PIXELS OK ' + str(im.size) if ok else f'PIXELS FAIL size={im.size} flat={flat}')
sys.exit(0 if ok else 1)
PYEOF
}

poll_pixels() { # $1=expected width; the follow pipeline has real latency - poll
    for _ in $(seq 1 12); do shot_ok "$1" >/dev/null 2>&1 && return 0; sleep 10; done
    return 1
}

# ---- topology persistence assert (dev-side, on a plain modeprobe read) ------
check_persist() { # $1=side  $2=json-line ; prints "PERSIST OK gdi=..." on stdout
    # NB: `python3 - ... <<EOF` reads the SCRIPT from stdin, so a piped JSON would
    # be swallowed as source and json.load(sys.stdin) would see EOF (that is the
    # 'json-unparseable' stop that killed two runs). Pass the JSON as argv.
    python3 - "$1" "$W" "$H" "$2" <<'PYEOF'
import sys, json
side, W, H, raw = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
pat = 'IddSampleDriver Device' if side == 'idd' else 'Microsoft Basic Display Adapter'
try:
    d = json.loads(raw)
except Exception as e:
    print(f'PERSIST FAIL json-unparseable: {e}'); sys.exit(1)
devs = d.get('devices') or []
prim = [x for x in devs if x.get('primary') and x.get('attached')]
others = [x for x in devs if x.get('attached') and not x.get('primary')]
if len(prim) != 1:
    print(f'PERSIST FAIL attached-primaries={len(prim)}'); sys.exit(1)
p = prim[0]
# startswith, not equality: distinguishes 'Microsoft Basic Display Adapter' (BDA) from
# 'Microsoft Basic Display Driver' (the ROOT\BASICDISPLAY fallback).
if not p.get('device_string', '').startswith(pat):
    print(f"PERSIST FAIL primary_string={p.get('device_string')!r} want-prefix={pat!r}"); sys.exit(1)
c = p.get('current') or {}
if (c.get('w'), c.get('h')) != (W, H):
    print(f"PERSIST FAIL current={c.get('w')}x{c.get('h')} want {W}x{H}"); sys.exit(1)
if others:
    print('PERSIST FAIL attached_others=' + ','.join(repr(x.get('device_string')) for x in others)); sys.exit(1)
print('PERSIST OK gdi=' + p.get('device_name', ''))
PYEOF
}

# ---- SS2.4 acceptance evaluation of one ddaprobe JSON -----------------------
eval_json() { # $1=json path  $2=side  $3=expected GDI name ; verdict via exit code
    python3 - "$1" "$2" "$3" "$W" "$H" <<'PYEOF'
import sys, json
path, side, gdi, W, H = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5])
fails = []
def req(cond, msg):
    if not cond:
        fails.append(msg)
try:
    d = json.load(open(path))
except Exception as e:
    print(f'EVAL FAIL json-unparseable: {e}'); sys.exit(1)

# Run validity (SS2.4 instrument validation b): session 0 voids the run, ddaprobe only warns.
req(d.get('session_id') == 1, f"session_id={d.get('session_id')}!=1")
req(d.get('window_station') == 'WinSta0', f"window_station={d.get('window_station')}")
req(d.get('desktop') == 'Default', f"desktop={d.get('desktop')}")

s = d.get('summary') or {}
# The direct capture.c:317-324 verdict - ddaprobe models the agent's exact selection.
req(s.get('agent_capture_would_work') is True, 'agent_capture_would_work!=true')
ai = s.get('agent_output_index', -1)
outs = d.get('outputs') or []
if not (isinstance(ai, int) and 0 <= ai < len(outs)):
    fails.append(f'agent_output_index={ai} (outputs={len(outs)})')
    print('EVAL FAIL ' + ' | '.join(fails)); sys.exit(1)
o = outs[ai]

# Asked before the flag (SS2.4 read order): where did the monitor land?
req(o.get('adapter_index') == 0, f"agent output on adapter {o.get('adapter_index')}!=0")
a0 = [x for x in outs if x.get('adapter_index') == 0 and x.get('attached_to_desktop')]
# Two attached outputs on adapter 0 is a BLOCKING finding independent of the flag.
req(len(a0) == 1, f'attached_outputs_on_adapter0={len(a0)}!=1')
req(o.get('attached_to_desktop') is True, 'agent output not attached_to_desktop')
# Cross-witness: the output the agent would capture must be the device modeprobe saw primary.
req(o.get('device_name') == gdi, f"agent_output_device={o.get('device_name')}!=modeprobe_primary={gdi}")

# DuplicateOutput failure is WORSE than Outcome B (per-window engine loses its trigger too).
req(o.get('duplication_ok') is True, f"duplication_ok=false hr={o.get('duplication_hr_name')}")

# THE flag, plus whether it flipped mid-run (a flip makes even a passing cold check unsafe).
req(o.get('desktop_image_in_system_memory') is True, 'DesktopImageInSystemMemory FALSE')
req(o.get('desktop_image_in_system_memory_ever_false') is False, 'flag flipped mid-run (ever_false)')
req(o.get('mode_changes', 0) == 0, f"mode_changes={o.get('mode_changes')} during the run")

# Independent corroboration via the exact call capture.c:515 makes.
m = o.get('map_desktop_surface') or {}
req(m.get('attempted') is True and m.get('ok') is True,
    f"map_desktop_surface ok={m.get('ok')} hr={m.get('hr_name')}")
req(m.get('pbits_non_null') is True, 'map pBits NULL')

md = o.get('mode') or {}
req(md.get('width') == W and md.get('height') == H,
    f"mode={md.get('width')}x{md.get('height')} want {W}x{H}")
# Any format other than 87/B8G8R8A8_UNORM is silent corruption, not an error.
req(md.get('format') == 87, f"format={md.get('format')}({md.get('format_name')})!=87")
# The stride killer: nothing in the protocol can express pitch != width*4.
req(m.get('pitch') == W * 4, f"pitch={m.get('pitch')}!={W*4}=width*4 (stride killer)")

# Non-trivial churn counts promote the A6 class from prerequisite to hard blocker.
lp = o.get('loop') or {}
for k in ('errors', 'access_lost', 'reduplications', 'reduplication_failures'):
    req(lp.get(k, 0) == 0, f'loop.{k}={lp.get(k)}')
# Activity-effectiveness gate: idle desktops acquire ~1 frame; below this the run did not
# actually measure an active desktop and the data is void (missing data FAILS).
req(lp.get('acquired', 0) >= 20, f"acquired={lp.get('acquired')}<20 - activity-gen ineffective")

line = (f"side={side} flag={o.get('desktop_image_in_system_memory')} "
        f"ever_false={o.get('desktop_image_in_system_memory_ever_false')} "
        f"map_ok={m.get('ok')} pitch={m.get('pitch')} (width*4={W*4}) "
        f"dup_ok={o.get('duplication_ok')} agent_ok={s.get('agent_capture_would_work')} "
        f"device={o.get('device_name')} adapter0_attached={len(a0)} "
        f"acquired={lp.get('acquired')} access_lost={lp.get('access_lost')} "
        f"redup={lp.get('reduplications')} format={md.get('format')} session={d.get('session_id')}")
if fails:
    print('EVAL FAIL ' + ' | '.join(fails))
    print('EVAL DATA ' + line)
    sys.exit(1)
print('EVAL PASS ' + line)
PYEOF
}

# ============================================================================
# Guest helper (pushed to QubesIncoming). Pattern: coexistence-test.ps1 (elevation
# check, activity Start-Process), pnp-revert-action.ps1 (devcon + status readback).
# Machine-parseable lines only: "EXP9 key=value".
# ============================================================================
cat > "$TMPD/exp9-guest.ps1" <<'PSEOF'
param(
    [Parameter(Mandatory=$true)][string]$Action,
    [string]$Role = '',     # arm: which device id goes into the marker (bda|idd)
    [string]$Target = '',   # topo/solo: which adapter must end up primary (bda|idd)
    [string]$Tag = ''       # measure/fetch: round-N-{bda,idd}
)
$ErrorActionPreference = 'Continue'
$inc  = 'C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
$qdir = 'C:\qubes-idd'
$devcon    = Join-Path $qdir 'devcon.exe'
$req       = Join-Path $qdir 'revert-request.txt'
$probe     = Join-Path $inc 'ddaprobe.exe'
$modeprobe = Join-Path $inc 'modeprobe.exe'
$actgen    = Join-Path $inc 'activity-gen.ps1'
$SOLO = '1920x1080'; $SW = 1920; $SH = 1080

# Write-Host, NOT Write-Output: KV is called inside functions with return values
# (RunSolo), and Write-Output would inject these lines into the caller's pipeline,
# making a $null (failure) return undetectable. Write-Host still lands on
# powershell.exe stdout and is captured by qrexec.
function KV($k, $v) { Write-Host "EXP9 $k=$v" }

function DevStatus($id) {
    $s = (& $devcon status "@$id" 2>&1) -join ' | '
    if     ($s -match 'Driver is running') { 'running' }
    elseif ($s -match 'disabled')          { 'disabled' }
    elseif ($s -match 'stopped')           { 'stopped' }
    else                                   { 'unknown' }
}

function DisplayIds {
    $all = @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue)
    # BDA = the emulated PCI VGA; IDD = our root-enumerated device. ROOT\BASICDISPLAY is
    # the fallback Windows spins up when the BDA is disabled - report, never target.
    $bda = @($all | Where-Object { $_.InstanceId -like 'PCI\*' })
    $idd = @($all | Where-Object { $_.InstanceId -like 'ROOT\DISPLAY\*' })
    $bas = @($all | Where-Object { $_.InstanceId -like 'ROOT\BASICDISPLAY*' })
    @{ bda = $bda; idd = $idd; bas = $bas }
}

function MpJson {
    $l = & $modeprobe 2>$null | Where-Object { $_ -match '^\{' } | Select-Object -First 1
    if (-not $l) { return $null }
    try { $l | ConvertFrom-Json } catch { $null }
}

function GdiPattern($role) {
    if ($role -eq 'idd') { '^IddSampleDriver Device' } else { '^Microsoft Basic Display Adapter' }
}

function FindGdi($role) {
    $j = MpJson
    if (-not $j) { return $null }
    $pat = GdiPattern $role
    $hit = @($j.devices | Where-Object { $_.device_string -match $pat })
    if ($hit.Count -lt 1) { return $null }
    $hit[0].device_name
}

function TopoState($role) {
    # Post-mutation truth: target primary+attached at SOLO, zero other attached devices.
    $j = MpJson
    if (-not $j) { return @{ ok = $false; reason = 'modeprobe-no-json' } }
    $pat = GdiPattern $role
    $prim = @($j.devices | Where-Object { $_.primary -and $_.attached })
    $others = @($j.devices | Where-Object { $_.attached -and -not $_.primary })
    if ($prim.Count -ne 1) { return @{ ok = $false; reason = "primaries=$($prim.Count)"; others = $others.Count } }
    $p = $prim[0]
    if ($p.device_string -notmatch $pat) { return @{ ok = $false; reason = "primary=$($p.device_string)"; others = $others.Count } }
    if (-not $p.current -or $p.current.w -ne $SW -or $p.current.h -ne $SH) {
        return @{ ok = $false; reason = "current=$($p.current.w)x$($p.current.h)"; others = $others.Count }
    }
    if ($others.Count -gt 0) { return @{ ok = $false; reason = "attached_others=$($others.Count)"; others = $others.Count } }
    @{ ok = $true; gdi = $p.device_name; others = 0 }
}

function RunSolo($role) {
    # Discover the GDI name fresh (names shift across PnP churn), then assert with --solo.
    $gdi = $null
    for ($i = 0; $i -lt 6 -and -not $gdi; $i++) { $gdi = FindGdi $role; if (-not $gdi) { Start-Sleep 5 } }
    if (-not $gdi) { KV solo_gdi 'NOT-FOUND'; return $null }
    KV solo_gdi $gdi
    & $modeprobe --solo $SOLO --device $gdi --json (Join-Path $qdir "exp9-solo-$role.json") *> $null
    KV solo_exit $LASTEXITCODE
    if ($LASTEXITCODE -ne 0) { return $null }
    $gdi
}

switch ($Action) {

    'checkpre' {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object Security.Principal.WindowsPrincipal($id)
        $elev = $pr.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
        cmd /c "schtasks /query /tn QubesIddPnpRevert >nul 2>nul"
        $taskOk = ($LASTEXITCODE -eq 0)
        $help = (& $modeprobe --help 2>&1 | Out-String)
        $soloOk = ($help -match '--solo')
        $devconOk = Test-Path $devcon
        $actionOk = Test-Path (Join-Path $qdir 'pnp-revert-action.ps1')
        $probeOk = Test-Path $probe
        $mpOk = Test-Path $modeprobe
        $agOk = Test-Path $actgen
        KV elevated $elev
        KV devcon_present $devconOk
        KV revert_action_present $actionOk
        KV revert_task_registered $taskOk
        KV ddaprobe_present $probeOk
        KV modeprobe_present $mpOk
        KV activity_present $agOk
        KV solo_supported $soloOk
        $ok = $elev -and $devconOk -and $actionOk -and $taskOk -and $probeOk -and $mpOk -and $agOk -and $soloOk
        KV checkpre ($(if ($ok) { 'OK' } else { 'FAIL' }))
    }

    'inventory' {
        $d = DisplayIds
        KV bda_count $d.bda.Count
        KV idd_count $d.idd.Count
        KV basicdisplay_count $d.bas.Count
        KV marker_present (Test-Path $req)
        if ($d.bda.Count -ne 1 -or $d.idd.Count -ne 1) { KV inventory FAIL; exit 1 }
        KV bda_id $d.bda[0].InstanceId
        KV idd_id $d.idd[0].InstanceId
        KV bda_status (DevStatus $d.bda[0].InstanceId)
        KV idd_status (DevStatus $d.idd[0].InstanceId)
        KV inventory OK
    }

    'arm' {
        $d = DisplayIds
        if ($d.bda.Count -ne 1 -or $d.idd.Count -ne 1) { KV arm FAIL; exit 1 }
        $id = if ($Role -eq 'bda') { $d.bda[0].InstanceId } else { $d.idd[0].InstanceId }
        Set-Content -Path $req -Value $id -Encoding ASCII
        $rb = (Get-Content $req -TotalCount 1).Trim()
        KV armed_id $rb
        KV arm ($(if ($rb -eq $id) { 'OK' } else { 'FAIL' }))
    }

    'disarm' {
        if (Test-Path $req) { Remove-Item $req -Force }
        KV disarm ($(if (Test-Path $req) { 'FAIL' } else { 'OK' }))
    }

    'topo' {
        $d = DisplayIds
        if ($d.bda.Count -ne 1 -or $d.idd.Count -ne 1) { KV topo FAIL; KV topo_reason inventory; exit 1 }
        if ($Target -eq 'bda') { $tid = $d.bda[0].InstanceId; $oid = $d.idd[0].InstanceId }
        else                   { $tid = $d.idd[0].InstanceId; $oid = $d.bda[0].InstanceId }
        & $devcon enable "@$tid" *> $null
        KV enable_exit $LASTEXITCODE
        Start-Sleep 8
        if (-not (RunSolo $Target)) { KV topo FAIL; KV topo_reason solo1; exit 1 }
        & $devcon disable "@$oid" *> $null
        KV disable_exit $LASTEXITCODE
        Start-Sleep 8
        $st = TopoState $Target
        if (-not $st.ok) {
            # Disabling the other adapter can pop the BASICDISPLAY fallback into the
            # topology (FINDINGS 2026-08-04 close item 5); one more --solo detaches it.
            KV topo_retry_reason $st.reason
            if (-not (RunSolo $Target)) { KV topo FAIL; KV topo_reason solo2; exit 1 }
            Start-Sleep 3
            $st = TopoState $Target
        }
        if (-not $st.ok) { KV topo FAIL; KV topo_reason $st.reason; exit 1 }
        KV other_status (DevStatus $oid)
        # Deterministic agent boot on both sides: pin the cache to the solo mode.
        $rk = 'HKLM:\Software\Invisible Things Lab\Qubes Tools'
        Set-ItemProperty $rk -Name FullscreenWidth  -Value $SW -Type DWord
        Set-ItemProperty $rk -Name FullscreenHeight -Value $SH -Type DWord
        KV topo_gdi $st.gdi
        KV topo OK
    }

    'solo' {
        $gdi = RunSolo $Target
        if (-not $gdi) { KV solo FAIL; exit 1 }
        $st = TopoState $Target
        if (-not $st.ok) { KV solo FAIL; KV solo_reason $st.reason; exit 1 }
        KV solo_final_gdi $st.gdi
        KV solo OK
    }

    'hash' {
        if (-not (Test-Path $probe)) { KV hash FAIL; exit 1 }
        $h = (Get-FileHash $probe -Algorithm SHA256).Hash
        KV ddaprobe_sha256 $h
        KV ddaprobe_sha256_16 $h.Substring(0, 16)
        KV hash OK
    }

    'measure' {
        $out = Join-Path $qdir "exp9-$Tag.json"
        Remove-Item $out -Force -ErrorAction SilentlyContinue
        if (Test-Path $out) { KV measure FAIL; KV measure_reason stale-json-undeletable; exit 1 }
        # Concurrent desktop activity (SS2.4): 45 s outlasts the 30 s probe window.
        Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass',
            '-File', "`"$actgen`"", '-Seconds', '45' -WindowStyle Minimized
        Start-Sleep 2
        & $probe 100 30 --json $out 2>&1 | ForEach-Object { $_ }
        # NOT a verdict: ddaprobe exits 0 whenever duplication succeeds, flag or no flag
        # (FINDINGS 2026-08-04 cont 3). Recorded for the log only; the JSON decides.
        KV probe_exit $LASTEXITCODE
        KV json_present (Test-Path $out)
        KV measure ($(if (Test-Path $out) { 'OK' } else { 'FAIL' }))
    }

    'fetch' {
        $out = Join-Path $qdir "exp9-$Tag.json"
        if (-not (Test-Path $out)) { KV fetch FAIL; exit 1 }
        Get-Content $out -Raw | Write-Output
    }

    default { KV error "unknown-action:$Action"; exit 2 }
}
PSEOF

# ============================================================================
# Run
# ============================================================================
log "============================================================"
log "EXP9 formal gating measurement start (PLAN SS2.4 / SS7 row 9)"
log "repo commit: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
log "structure: $ROUNDS interleaved rounds x [bda control, idd test], cold boot per side"
log "mode: ${W}x${H} solo on both sides; expected ddaprobe SHA256[0:16]=$EXPECTED_DDAPROBE_SHA16"
log "outputs: $OUTDIR/round-N-{bda,idd}.json + .report.txt; this log appends"

# --- preflight ---------------------------------------------------------------
[ -x tools/qtest ] || stop "tools/qtest missing/not executable"
command -v python3 >/dev/null || stop "python3 missing on dev side"
python3 -c 'import PIL' 2>/dev/null || stop "python3-PIL missing on dev side"

st="$(vmstate)"
case "$st" in
    Running) log "VM running" ;;
    Halted)  log "VM halted - initial prep boot (not a measurement boot)"
             timeout 200 ./tools/qtest start >/dev/null 2>&1
             ok=0; for _ in $(seq 1 30); do alive && { ok=1; break; }; sleep 10; done
             [ "$ok" = 1 ] || stop "initial boot: qrexec never answered" ;;
    *)       stop "VM in unexpected state '$st' (Transient wedge? investigate before running)" ;;
esac

log "pushing exp9-guest.ps1 + activity-gen.ps1"
./tools/qtest push "$TMPD/exp9-guest.ps1" "$REPO/instrumentation/activity-gen.ps1" \
    || stop "qtest push failed"

pre="$(ghelper '-Action checkpre')"
printf '%s\n' "$pre" >> "$LOG"
[ "$(kv "$pre" checkpre)" = "OK" ] || stop "guest preconditions not met (see checkpre lines above; if the revert task is missing: guest/pnp-revert-setup.ps1, branch scratch/d0-monitor3-control @dcc38a6)"

pass_lines=()

for r in $(seq 1 "$ROUNDS"); do
  for side in bda idd; do
    tag="round-$r-$side"
    if [ "$side" = "bda" ]; then role_kind="CONTROL"; other="idd"; else role_kind="TEST"; other="bda"; fi
    log "------------------------------------------------------------"
    log "$tag ($role_kind: $side primary, $other detached+disabled)"

    # ---- PREPARE (on the running instance) ---------------------------------
    inv="$(ghelper '-Action inventory')"
    printf '%s\n' "$inv" >> "$LOG"
    [ "$(kv "$inv" inventory)" = "OK" ] || stop "$tag: PnP inventory failed"
    bda_id="$(kv "$inv" bda_id)"; idd_id="$(kv "$inv" idd_id)"
    if [ "$side" = "bda" ]; then LAST_DISABLED_ID="$idd_id"; else LAST_DISABLED_ID="$bda_id"; fi
    log "$tag: to-be-detached device: $other ($LAST_DISABLED_ID)"

    arm="$(ghelper "-Action arm -Role $other")"
    printf '%s\n' "$arm" >> "$LOG"
    [ "$(kv "$arm" arm)" = "OK" ] || stop "$tag: could not arm revert marker"
    [ "$(kv "$arm" armed_id)" = "$LAST_DISABLED_ID" ] || stop "$tag: marker armed with wrong id '$(kv "$arm" armed_id)'"
    log "$tag: revert marker ARMED with $LAST_DISABLED_ID"

    topo="$(ghelper "-Action topo -Target $side" 420)"
    printf '%s\n' "$topo" >> "$LOG"
    [ "$(kv "$topo" topo)" = "OK" ] || stop "$tag: topology mutation failed (reason=$(kv "$topo" topo_reason))"
    [ "$(kv "$topo" other_status)" = "disabled" ] || stop "$tag: $other not disabled after mutation (status=$(kv "$topo" other_status))"
    log "$tag: hot topology OK, gdi=$(kv "$topo" topo_gdi), $other=disabled"

    alive || stop "$tag: qrexec dead after topology mutation"
    poll_pixels "$W" || stop "$tag: dom0 window never showed live ${W}-wide pixels after mutation"
    log "$tag: hot health OK (qrexec + decoded pixels)"

    dis="$(ghelper '-Action disarm')"
    printf '%s\n' "$dis" >> "$LOG"
    [ "$(kv "$dis" disarm)" = "OK" ] || stop "$tag: could not disarm marker (armed marker would revert topology on the measurement boot)"
    log "$tag: marker DISARMED (measurement boot must not be auto-reverted)"

    # ---- MEASURE (cold boot) -----------------------------------------------
    cold_boot
    log "$tag: settling 75 s (M6 boot publish / work-area feed window)"
    sleep 75

    j1="$(mp_json)"; [ -n "$j1" ] || stop "$tag: modeprobe read 1 returned no JSON"
    p1="$(check_persist "$side" "$j1")" || { log "$p1"; stop "$tag: topology did not persist across cold boot (read 1)"; }
    sleep 15
    j2="$(mp_json)"; [ -n "$j2" ] || stop "$tag: modeprobe read 2 returned no JSON"
    p2="$(check_persist "$side" "$j2")" || { log "$p2"; stop "$tag: topology unstable after cold boot (read 2)"; }
    [ "$p1" = "$p2" ] || stop "$tag: topology changed between stability reads ('$p1' vs '$p2')"
    gdi="${p2##*gdi=}"
    log "$tag: post-boot topology persisted + stable ($p2)"

    inv2="$(ghelper '-Action inventory')"
    printf '%s\n' "$inv2" >> "$LOG"
    [ "$(kv "$inv2" inventory)" = "OK" ] || stop "$tag: post-boot inventory failed"
    [ "$(kv "$inv2" marker_present)" = "False" ] || stop "$tag: marker present after boot"
    if [ "$side" = "bda" ]; then ostat="$(kv "$inv2" idd_status)"; tstat="$(kv "$inv2" bda_status)"
    else                         ostat="$(kv "$inv2" bda_status)"; tstat="$(kv "$inv2" idd_status)"; fi
    [ "$ostat" = "disabled" ] || stop "$tag: $other no longer disabled after boot (status=$ostat - did the revert task fire?)"
    [ "$tstat" = "running" ]  || stop "$tag: $side adapter not running after boot (status=$tstat)"

    solo="$(ghelper "-Action solo -Target $side" 240)"
    printf '%s\n' "$solo" >> "$LOG"
    [ "$(kv "$solo" solo)" = "OK" ] || stop "$tag: formal --solo assert failed (exit=$(kv "$solo" solo_exit) reason=$(kv "$solo" solo_reason))"
    [ "$(kv "$solo" solo_final_gdi)" = "$gdi" ] || stop "$tag: --solo gdi '$(kv "$solo" solo_final_gdi)' != persistence gdi '$gdi'"
    log "$tag: formal modeprobe --solo assert OK on $gdi"

    hout="$(ghelper '-Action hash')"
    printf '%s\n' "$hout" >> "$LOG"
    got="$(kv "$hout" ddaprobe_sha256_16)"
    [ "$got" = "$EXPECTED_DDAPROBE_SHA16" ] || stop "$tag: on-guest ddaprobe hash '$got' != '$EXPECTED_DDAPROBE_SHA16' - wrong instrument, run void"
    log "$tag: ddaprobe hash verified ($got)"

    m="$(ghelper "-Action measure -Tag $tag" 300)"
    printf '%s\n' "$m" > "$OUTDIR/$tag.report.txt"
    printf '%s\n' "$m" >> "$LOG"
    [ "$(kv "$m" measure)" = "OK" ] || stop "$tag: ddaprobe run failed / wrote no JSON (probe_exit=$(kv "$m" probe_exit))"

    f="$(ghelper "-Action fetch -Tag $tag" 120)"
    printf '%s\n' "$f" | grep -E '^\{' | head -1 > "$OUTDIR/$tag.json"
    [ -s "$OUTDIR/$tag.json" ] || stop "$tag: fetched JSON empty"
    ev="$(eval_json "$OUTDIR/$tag.json" "$side" "$gdi")" || { log "$ev"; stop "$tag: SS2.4 acceptance FAILED - see EVAL FAIL above and $OUTDIR/$tag.json"; }
    log "$tag: $ev"
    pass_lines+=("$tag: $ev")

    alive || stop "$tag: qrexec dead after measurement"
    poll_pixels "$W" || stop "$tag: pixels dead after measurement"
    log "$tag: post-measure health OK"
    log "$tag PASS"
  done
done

log "============================================================"
log "EXP9 VERDICT: PASS $((ROUNDS * 2))/$((ROUNDS * 2)) sides - Outcome A formally recorded."
for l in "${pass_lines[@]}"; do log "  $l"; done
log "SCOPE (SS2.4): verdict applies to the CURRENT driver build + WARP renderer + 19045 at"
log "  ${W}x${H} solo topology only. Near-zero odds on a real GPU - do not port a PASS."
log "Guest left: IDD primary ${W}x${H}, BDA disabled, marker disarmed (intended steady"
log "  config). Restore the preferred desktop size via a dom0 resize when convenient."
log "Next: append the dated verdict + per-side EVAL lines to FINDINGS.md."
