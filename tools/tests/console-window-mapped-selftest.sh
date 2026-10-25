#!/usr/bin/env bash
# console-window-mapped-selftest.sh - the console-window check must count MAPPED windows.
#
# WHY. mgmt/harness/console-window-check.sh looked for AddWindow lines of the console classes while
# every message about it - its own header, the harness FAIL text, the ledger entry - says "mapped".
# AddWindow is the agent ACCEPTING a window into tracking; SendWindowMap is what puts it on the
# dom0 screen, and a window can be accepted and then never mapped.
#
# MEASURED 2026-10-17 on win11de-sm, and it cost a clean cycle: a Windows Terminal hosting window
# was accepted at t=72562 with brokerslot=-1 while the broker was still coming up, held with "no
# painted frame yet", and NEVER mapped. Its replacement arrived 3.3 s later, got slot 0, took a
# first WGC frame and WAS mapped. One terminal, one mapped window - and the check reported
# "FOUND 2 console/Terminal windows mapped", failing an upgrade whose other 10 checks passed.
# Reading that as a product regression was the obvious next mistake; the count was the defect.
#
# The fixture lines below are VERBATIM from that capture, so this test is about what the guest
# actually wrote rather than about a shape I imagined.
#
# It drives the check's OWN PowerShell, extracted from the script by its assignment, rather than a
# reimplementation - a test that re-states the logic it is checking proves nothing.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
CHK="$HERE/mgmt/harness/console-window-check.sh"
PW="$("$(dirname "$0")/pwsh-path.sh" || true)"
[ -f "$CHK" ] || { echo "FAIL  $CHK missing - nothing ran (missing data fails)"; exit 2; }
[ -x "$PW" ] || { echo "FAIL  no pwsh at $PW - nothing ran"; exit 2; }
case "${CWCMAP_DEFECT:-}" in ""|1) ;; *) echo "FAIL  unknown CWCMAP_DEFECT='$CWCMAP_DEFECT' (1)"; exit 2 ;; esac
D=$(mktemp -d); trap 'rm -rf -- "$D"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }

# VERBATIM from qwt-quick-upgrade/win11de-sm-20261017-122951 (logvol gui-agent-20261017-153117).
cat > "$D/fixture.log" <<'EOF'
[20261017.153117.001-5016-I] Init: gui-agent starting
[20261017.153147.719-5016-I] AddWindow: QGAHELDDEFER hwnd=0x50042 class=CASCADIA_HOSTING_WINDOW_CLASS w=1115 h=628 t=72562 slicefed=1 brokerslot=-1
[20261017.153148.465-5016-I] UpdateWindowData: QGADIRECTWAIT hwnd 0x50042 (class CASCADIA_HOSTING_WINDOW_CLASS, 1115x628) held: no painted frame yet
[20261017.153151.036-5016-I] AddWindow: QGAHELDDEFER hwnd=0x201e4 class=CASCADIA_HOSTING_WINDOW_CLASS w=1115 h=628 t=75875 slicefed=1 brokerslot=0
[20261017.153151.864-5016-I] SendWindowMap: Mapping window 0x201e4
EOF
# a second fixture: a console window accepted and mapped, which MUST be reported
cat > "$D/mapped.log" <<'EOF'
[20261017.153117.001-5016-I] Init: gui-agent starting
[20261017.153147.719-5016-I] AddWindow: QGAHELDDEFER hwnd=0x50042 class=ConsoleWindowClass w=1115 h=628 t=72562
[20261017.153148.100-5016-I] SendWindowMap: Mapping window 0x50042
EOF
# and one accepted, never mapped - the shape that must NOT be reported
head -4 "$D/fixture.log" | command grep -v 'hwnd=0x201e4' > "$D/unmapped.log"

# Extract the check's per-file matching block and drive it over one file.
drive() { # $1 = log file -> prints its CWC-HIT lines
    CWC_LOG="$1" CWC_DEFECT="${CWCMAP_DEFECT:-}" python3 - "$D" <<'PY'
import os, re, pathlib, subprocess, sys
D = sys.argv[1]
src = pathlib.Path(os.environ['CHK']).read_text()
body = re.search(r"PS='(.*?)'\n", src, re.S).group(1)
inner = re.search(r"(\s*\$lines = New-Object.*?\$sr\.Dispose\(\))", body, re.S).group(1)
if os.environ.get('CWC_DEFECT') == '1':
    # DEFECT: report every ACCEPTED console window, as before 2026-10-17
    inner = re.sub(r'\$accepted\[\$Matches\[1\]\.ToLower\(\)\] = \$lines\[\$k\]',
                   '"CWC-HIT|" + $x.Name + "|" + $lines[$k]', inner)
ps = ('$x = Get-Item "%s"\n' % os.environ['CWC_LOG']) + \
     '$fs = [System.IO.File]::Open($x.FullName,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::ReadWrite)\n' + \
     '$sr = New-Object System.IO.StreamReader($fs)\n' + inner + '\n$fs.Dispose()\n'
p = D + '/drive.ps1'; pathlib.Path(p).write_text(ps)
r = subprocess.run([os.environ['PW'], '-NoProfile', '-File', p], capture_output=True, text=True)
for l in r.stdout.splitlines():
    if l.startswith('CWC-HIT|'):
        print(l)
if r.returncode != 0 and not r.stdout.strip():
    print("DRIVER-ERROR " + r.stderr.strip()[:200])
PY
}
export CHK PW

n=$(drive "$D/fixture.log" | command grep -c '^CWC-HIT' || true)
h=$(drive "$D/fixture.log" | command grep '^CWC-HIT' | head -1)
if [ "$n" = 1 ] && printf '%s' "$h" | command grep -q '0x201e4'; then
    ok "real capture: of two accepted console windows only the MAPPED one is reported"
else bad "real capture: reported $n hit(s) [$(printf '%s' "$h" | cut -c1-90)] - the false FAIL is back"; fi

n=$(drive "$D/mapped.log" | command grep -c '^CWC-HIT' || true)
if [ "$n" = 1 ]; then ok "mapped: a console window that WAS mapped is still reported"
else bad "mapped: a genuinely mapped console window was missed ($n hits) - the check would go blind"; fi

n=$(drive "$D/unmapped.log" | command grep -c '^CWC-HIT' || true)
if [ "$n" = 0 ]; then ok "unmapped: a window accepted and never mapped is not reported"
else bad "unmapped: an accepted-but-never-mapped window was reported ($n hits)"; fi

# THE PAYLOAD MUST FIT A WINDOWS COMMAND LINE. cmd.exe truncates at 8191 characters, mid-base64,
# and runs the rest as a command: eleven comment lines added to $PS took the invocation to 8682 and
# the guest answered "Die eingegebene Zeile ist zu lang", so the check reported INVALID-INSTRUMENT
# and failed an upgrade. UTF-16 then base64 costs ~2.7x per source character.
n=$(python3 - "$CHK" <<'PY2'
import re, base64, sys, pathlib
t = re.search(r"PS='(.*?)'\n", pathlib.Path(sys.argv[1]).read_text(), re.S).group(1)
print(len(base64.b64encode(t.encode('utf-16-le')).decode()) + 62)
PY2
)
if [ "$n" -le 8000 ]; then ok "payload: the encoded probe is $n characters, inside the cmd.exe limit"
else bad "payload: $n characters - cmd.exe truncates at 8191 and the probe never completes"; fi
# and the guard in the script must FIRE on an oversized payload
# The padded copy must live where its own "$0/../.." still resolves to the repo root, or it dies on
# its includes before reaching the guard. It is removed on exit either way.
big="$HERE/mgmt/harness/.cwc-oversize-probe.sh"
trap 'rm -rf -- "$D"; rm -f "$big"' EXIT
python3 - "$CHK" "$big" <<'PY3'
import re, sys, pathlib
s = pathlib.Path(sys.argv[1]).read_text()
m = re.search(r"PS='(.*?)'\n", s, re.S)
pad = "\n" + "\n".join("# pad %d" % i for i in range(400))
pathlib.Path(sys.argv[2]).write_text(s[:m.start(1)] + m.group(1) + pad + s[m.end(1):])
PY3
# The guard returns BEFORE anything is sent, so this needs a guest that passes the preconditions
# (a bogus name exits earlier and the guard is never reached). Nothing touches the guest.
# CAPTURE, THEN MATCH. Under `set -o pipefail` a pipeline returns the PRODUCER's non-zero status,
# and this probe exits 2 by design - so `probe | grep -q` reported failure while grep had matched.
probe_out=$(bash "$big" "${CWC_GUEST:-win11de-sm}" --allow-installer-console 2>&1 || true)
if printf '%s' "$probe_out" | command grep -q 'past cmd.exe'; then
    ok "guard: an oversized payload is refused before it is sent"
else bad "guard: oversized payload not refused - said: ${probe_out:0:90}"; fi

echo "console-window-mapped: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
