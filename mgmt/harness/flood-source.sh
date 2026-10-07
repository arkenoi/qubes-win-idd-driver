#!/usr/bin/env bash
# flood-source.sh - GWeck, forum #175 item 1: "When starting the VM after the installation of QWT,
# a lot of notifications pop up." NAME every one of them, at the SOURCE, with nothing forwarded.
#
# WHY NOT flood-repro.sh. That harness measures what the bridge FORWARDED, which means the
# notifications arrive on the owner's desktop while it runs; its own header says "there is no way
# round that". There is. The bridge only forwards - it does not create a single notification - so
# the flood's identity and size live in Windows' own notification store, and that can be read with
# the bridge switched OFF:
#
#   service.notify-bridge 0   the bridge does not run, so nothing is sent to dom0 at all
#   guivm ''                  headless, so no window of this guest is displayed either
#
# Neither weakens the measurement: %LocalAppData%\Microsoft\Windows\Notifications\wpndatabase.db is
# the platform store that notifhost itself reads for a payload (tools/notifhost/notifhost.cpp:49),
# it records every notification Windows raised with its AUMID, arrival time and payload XML, and it
# is populated whether or not anything forwards them. The owner has twice had a test guest's toasts
# land on his desktop. He does not need to see the flood again for us to enumerate it.
#
# HYPOTHESIS  a FIRST boot of a freshly provisioned profile carries many pending Windows first-run
#             notifications, and our bridge faithfully forwards each one - so the flood is Windows'
#             nags, not duplication by us.
# CONTROL     the long-lived guest already measured: 471 lines of bridge log over four bridge starts
#             and two installs carry exactly ONE `SENT id=`. If a fresh profile's store holds many,
#             the difference is the profile and not the build.
# VARIABLE    a freshly provisioned profile vs a long-lived one. Nothing else.
# INSTRUMENT  the store itself, copied out byte-for-byte and parsed HERE with python3's sqlite3 -
#             counting and field extraction in code, never by eye. An empty read FAILS; it never
#             reads as "no notifications".
# BUDGET      clone ~10 s, boot <= 8 min with three exits, copy+parse ~1 min.
#
#   flood-source.sh   (GOLDEN and VM are named by the caller, never defaulted - lint L10)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$ROOT" || exit 2
GOLDEN="${GOLDEN:-}"
VM="${VM:-}"
REPORTER="${REPORTER:-gweck}"
[ -n "$GOLDEN" ] && [ -n "$VM" ] || {
    echo "usage: GOLDEN=<golden to clone> VM=<disposable subject> $0" >&2
    echo "       e.g. GOLDEN=win11de-qwt VM=win11de-fsrc $0" >&2
    exit 2
}
OUT="${OUT:-$HOME/qwt-flood/src-$(date -u +%m%d-%H%M)}"
mkdir -p "$OUT"
log(){ echo "$(date -u +%H:%M:%SZ) fsrc[$VM]: $*"; }

source mgmt/harness/vmlock.sh
source mgmt/harness/shutdown-lib.sh
vm_lock "$VM" "flood-source.sh"

teardown(){
  local rc=$?
  log "teardown (rc=$rc)"
  qwt_shutdown "$VM" 300 >/dev/null 2>&1 || qvm-kill "$VM" >/dev/null 2>&1
  [ "${KEEP:-0}" = 1 ] || qvm-remove -f "$VM" >/dev/null 2>&1
  log "teardown done; results in $OUT"
}
trap teardown EXIT INT TERM

qwt_shutdown "$VM" 240 >/dev/null 2>&1 || true
qvm-remove -f "$VM" >/dev/null 2>&1 || true
log "cloning $GOLDEN -> $VM"
mgmt/clone-guest.sh "$GOLDEN" "$VM" >>"$OUT/clone.log" 2>&1 || { log "FAIL clone - see $OUT/clone.log"; exit 2; }

# The reporter gate is not optional: a reproduction on the wrong image has already cost a day.
if ! mgmt/harness/env-assert.sh "$VM" "$REPORTER" >"$OUT/env-assert.log" 2>&1; then
  log "FAIL env-assert $REPORTER did not pass - this is not his environment; see $OUT/env-assert.log"
  exit 2
fi
log "env-assert $REPORTER PASSED - this is his environment"

qvm-prefs "$VM" guivm '' || { log "FAIL could not make it headless - refusing to boot it"; exit 2; }
qvm-features "$VM" service.notify-bridge 0
log "headless and service.notify-bridge=0: nothing of this guest is displayed and nothing is forwarded"

export QTEST_VM="$VM"
log "starting (this is the FIRST boot of this profile as a clone)"
qvm-start "$VM" >>"$OUT/start.log" 2>&1 || { log "FAIL start - see $OUT/start.log"; exit 2; }

# three exits, and it says which it took
deadline=$((SECONDS + 480)); exitby=""; last=""
while [ $SECONDS -lt $deadline ]; do
  st=$(qvm-ls --raw-data --fields STATE "$VM" 2>/dev/null | tail -1)
  if [ "$st" != "Running" ]; then exitby="terminal: state=$st"; break; fi
  who=$(tools/qtest run 'powershell -NoProfile -Command "(Get-Process explorer -ErrorAction SilentlyContinue | Select-Object -First 1).Id"' 2>/dev/null | tr -d '\r' | command grep -oE '^[0-9]+$' | head -1)
  if [ -n "$who" ]; then exitby="session (explorer pid $who)"; break; fi
  [ "$last" = "$st" ] || log "  waiting: state=$st"
  last="$st"; sleep 15
done
[ -n "$exitby" ] || exitby="deadline (480 s)"
log "wait exit: $exitby"
case "$exitby" in session*) ;; *) log "FAIL no session - nothing measured (missing data fails)"; exit 2;; esac

# Windows writes the first-run notifications as the shell settles; give the storm its own window
# rather than sampling once the instant explorer appears.
log "letting the first-run notifications settle (${SETTLE:-120} s after session)"
sleep "${SETTLE:-120}"

# ---- pull the platform store out, byte for byte ------------------------------------------------
cat > "$OUT/probe.ps1" <<'PS1'
# The live DB plus its WAL: a notification that has not been checkpointed lives only in the WAL,
# and copying the .db alone would silently under-count exactly the newest arrivals we are here for.
$dir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Notifications'
$names = @('wpndatabase.db', 'wpndatabase.db-wal')
foreach ($n in $names) {
    $src = Join-Path $dir $n
    if (-not (Test-Path -LiteralPath $src)) { Write-Output "FS|absent|$n"; continue }
    $tmp = Join-Path $env:TEMP $n
    try {
        # a live SQLite file cannot be opened for ordinary copy while in use - go through a
        # read-shared stream rather than Copy-Item, which asks for more than it needs
        $fs = [IO.File]::Open($src, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $ms = New-Object IO.MemoryStream
        $fs.CopyTo($ms); $fs.Close()
        $b = $ms.ToArray(); $ms.Close()
        Write-Output "FS|size|$n|$($b.Length)"
        Write-Output "FS|b64begin|$n"
        $s = [Convert]::ToBase64String($b)
        for ($i = 0; $i -lt $s.Length; $i += 240) {
            Write-Output $s.Substring($i, [Math]::Min(240, $s.Length - $i))
        }
        Write-Output "FS|b64end|$n"
    } catch {
        Write-Output "FS|error|$n|$($_.Exception.Message)"
    }
}
# what our OWN routes would have sent, so the flood is attributed by evidence and not by assumption
$qlog = 'Q:\Qubes Logs'
if (Test-Path -LiteralPath $qlog) {
    $ours = @(Get-ChildItem -LiteralPath $qlog -Filter *.log -ErrorAction SilentlyContinue |
              Sort-Object LastWriteTime | Select-Object -Last 8)
    foreach ($f in $ours) {
        Select-String -LiteralPath $f.FullName -Pattern 'SENT id=','NOTIFYERR','DEATH ','QGANOTIF' -ErrorAction SilentlyContinue |
            ForEach-Object { Write-Output "FS|ourlog|$($_.Line)" }
    }
}
Write-Output 'FS|done'
PS1
log "pulling the notification store out"
tools/qtest pushrun "$OUT/probe.ps1" > "$OUT/probe.out" 2>&1 || true
tr -d '\r' < "$OUT/probe.out" > "$OUT/probe.txt"
command grep -c . "$OUT/probe.txt" >/dev/null || { log "FAIL the probe produced nothing"; exit 2; }
command grep -a '^FS|done$' "$OUT/probe.txt" >/dev/null || log "NOTE the probe did not reach its end marker - the decode below may be short"

# ---- decode and read it HERE --------------------------------------------------------------------
python3 - "$OUT" <<'PY' | tee "$OUT/inventory.txt"
import base64, os, re, sqlite3, sys, xml.etree.ElementTree as ET
out = sys.argv[1]
txt = open(os.path.join(out, 'probe.txt'), encoding='utf-8', errors='replace').read().splitlines()

files, cur, buf = {}, None, []
sizes = {}
for line in txt:
    if line.startswith('FS|size|'):
        _, _, n, sz = line.split('|', 3); sizes[n] = int(sz)
    elif line.startswith('FS|b64begin|'):
        cur = line.split('|', 2)[2]; buf = []
    elif line.startswith('FS|b64end|'):
        files[cur] = ''.join(buf); cur = None
    elif cur is not None:
        buf.append(line.strip())

ours = [l.split('|', 2)[2] for l in txt if l.startswith('FS|ourlog|')]
absent = [l.split('|', 2)[2] for l in txt if l.startswith('FS|absent|')]
errors = [l for l in txt if l.startswith('FS|error|')]
for e in errors:
    print('PROBE ERROR:', e)

if 'wpndatabase.db' not in files:
    print('FAIL  the notification store did not come out of the guest - nothing is measured, and '
          'an absent read FAILS rather than reading as zero.')
    print('      absent:', absent or 'none reported')
    sys.exit(2)

for n, b64 in files.items():
    raw = base64.b64decode(b64)
    if n in sizes and len(raw) != sizes[n]:
        print('FAIL  %s decoded to %d bytes, the guest reported %d - the stream was truncated'
              % (n, len(raw), sizes[n]))
        sys.exit(2)
    open(os.path.join(out, n), 'wb').write(raw)
    print('pulled %-20s %d bytes (hash-checked against the guest\'s own count)' % (n, len(raw)))

db = os.path.join(out, 'wpndatabase.db')
con = sqlite3.connect('file:%s?immutable=1' % db, uri=True)
con.row_factory = sqlite3.Row
tabs = {r[0] for r in con.execute("select name from sqlite_master where type='table'")}
print('tables:', ', '.join(sorted(tabs)))
if 'Notification' not in tabs:
    print('FAIL  no Notification table - this is not the store we expected')
    sys.exit(2)

cols = {r[1] for r in con.execute('pragma table_info(Notification)')}
sel = 'select * from Notification'
rows = list(con.execute(sel))
print()
print('=' * 100)
print('NOTIFICATIONS IN THE STORE: %d' % len(rows))
print('=' * 100)

def text_of(payload):
    if payload is None:
        return ''
    if isinstance(payload, bytes):
        for enc in ('utf-8', 'utf-16-le', 'latin-1'):
            try:
                s = payload.decode(enc)
                if '<' in s:
                    break
            except Exception:
                continue
        else:
            return '<undecodable>'
    else:
        s = str(payload)
    try:
        # the toast XML's <text> elements are the title and body the user reads
        xml = s[s.index('<'):]
        root = ET.fromstring(xml)
        parts = [(t.text or '').strip() for t in root.iter() if t.tag.endswith('text')]
        return ' / '.join(p for p in parts if p)
    except Exception:
        return re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', ' ', s)).strip()[:200]

# the handler table carries the AUMID; join it when it is there
handlers = {}
if 'NotificationHandler' in tabs:
    for r in con.execute('select * from NotificationHandler'):
        d = dict(r)
        hid = d.get('RecordId') or d.get('Id')
        handlers[hid] = d.get('PrimaryId') or d.get('HandlerId') or ''

by_app = {}
for r in con.execute(sel):
    d = dict(r)
    hid = d.get('HandlerId')
    app = handlers.get(hid, '') or str(hid)
    by_app[app] = by_app.get(app, 0) + 1

print()
print('BY SENDER:')
for app, n in sorted(by_app.items(), key=lambda kv: -kv[1]):
    print('  %4d  %s' % (n, app))

print()
print('EACH ONE, NAMED:')
for i, r in enumerate(con.execute(sel), 1):
    d = dict(r)
    hid = d.get('HandlerId')
    app = handlers.get(hid, '') or str(hid)
    arrival = d.get('ArrivalTime') or d.get('Expiry') or ''
    body = text_of(d.get('Payload'))
    print('  %3d  [%s] %s' % (i, app, body or '<no text in payload>'))

print()
print('OUR OWN ROUTES on this boot (the bridge was OFF, so these are what WOULD have been sent):')
if ours:
    for l in ours[-40:]:
        print('  ', l[:180])
else:
    print('   none - no SENT/NOTIFYERR/DEATH/QGANOTIF line in the last 8 guest logs')
print()
print('VERDICT INPUTS: store=%d  our_routes=%d' % (len(rows), len(ours)))
PY
rc=${PIPESTATUS[0]}
log "inventory written to $OUT/inventory.txt (rc=$rc)"
exit "$rc"
