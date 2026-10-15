#!/bin/bash
# qtest-push-selftest.sh - a pushed file must ARRIVE before anything runs it.
#
# WHY THIS EXISTS. `qtest pushrun` deleted the destination (ignoring failure), copied (ignoring
# qvm-copy-to-vm's exit status) and then ran the script with no check that it was there. MEASURED on
# win11r-lt twice - 2026-10-15 21:21 and 2026-10-16 22:37 - the transcript reads `sent 0/11 KB` and
# then `The argument '...\logvol-bind.ps1' to the -File parameter does not exist`. Both times the
# log-volume bind failed, so QWT's logs stayed on C: and the DIAG image - the store the HOST reads
# with mtools when the guest is WEDGED, i.e. exactly when the pull path cannot help - held 155
# bytes. The harness named the consequence itself during that run: "no qrexec for 41s - and the log
# volume could not be read either: THAT is the gap, not the silence."
#
# The guest is stubbed at the two programs qtest shells out to - qrexec-client-vm (which vmshell
# pipes into) and qvm-copy-to-vm - so the REAL qtest code path runs here. Nothing stubs qtest.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 2
T="$(mktemp -d "${TMPDIR:-/tmp}/qtestpush-XXXXXX")"
trap 'rc=$?; if [ "$rc" -eq 0 ]; then rm -rf "$T"; else printf "kept %s for inspection (rc=%s)\n" "$T" "$rc" >&2; fi' EXIT
pass=0; fail=0
ok(){  printf 'ok   %s\n' "$1"; pass=$((pass+1)); }
bad(){ printf 'FAIL %s   %s\n' "$1" "${2:-}"; fail=$((fail+1)); }
ck(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want=$2 got=$3"; fi; }

mkdir -p "$T/bin" "$T/incoming"
INC='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'

# --- the stub guest -------------------------------------------------------------------------
# qrexec-client-vm reads the command on stdin. It answers the three shapes qtest sends: the QSIZE
# probe, the delete, and the PowerShell run (which records that it ran). The file name is taken as
# the text after the LAST backslash before the closing quote - the same thing the guest would do.
python3 - "$T" <<'PYSTUB'
import os, sys, stat
T = sys.argv[1]
qrexec = r"""#!/usr/bin/env python3
import os, re, sys
T = %r
cmd = sys.stdin.read()
if 'QSIZE' in cmd:
    m = re.findall(r'\\([^\\"]+)"', cmd)
    name = m[0] if m else ''
    f = os.path.join(T, 'incoming', name)
    print('QSIZE=%%d' %% (os.path.getsize(f) if os.path.isfile(f) else 0))
elif 'del /q /f' in cmd:
    pass
elif 'powershell' in cmd and '-File' in cmd:
    open(os.path.join(T, 'ran.txt'), 'a').write('RAN\n')
""" % (T,)
copy = r"""#!/usr/bin/env python3
import os, shutil, sys
T = %r
args = sys.argv[2:]                      # drop the VM name
mode = open(os.path.join(T,'mode')).read().strip() if os.path.exists(os.path.join(T,'mode')) else 'deliver'
cf = os.path.join(T,'calls')
n = int(open(cf).read().strip() or 0) if os.path.exists(cf) else 0
n += 1; open(cf,'w').write(str(n))
if mode == 'never': sys.exit(0)          # sent 0/11 KB: reports nothing, moves nothing
if mode == 'attempt2' and n < 2: sys.exit(0)
for f in args: shutil.copy(f, os.path.join(T,'incoming',os.path.basename(f)))
""" % (T,)
for name, body in (('qrexec-client-vm', qrexec), ('qvm-copy-to-vm', copy),
                   ('qvm-check', '#!/bin/sh\nexit 0\n')):
    p = os.path.join(T, 'bin', name)
    open(p, 'w').write(body)
    os.chmod(p, 0o755)
PYSTUB
printf 'hello-payload\n' > "$T/payload.ps1"
export PATH="$T/bin:$PATH" QTEST_VM=stub-vm QTEST_INCOMING="$INC"

run_pushrun(){ rm -f "$T/ran.txt" "$T/calls"; rm -f "$T/incoming/"*; echo "$1" > "$T/mode"
               ./tools/qtest pushrun "$T/payload.ps1" >"$T/out.txt" 2>&1; echo $?; }

# 1. THE MEASURED CASE: the copy moves nothing. The script must NOT run, and it must fail loudly.
rc=$(run_pushrun never)
ck "a copy that delivers nothing FAILS instead of running the script" 4 "$rc"
ck "and the script was never run" "" "$(grep -ac RAN "$T/ran.txt" 2>/dev/null || true)"
if grep -q 'arrived as 0 of' "$T/out.txt" 2>/dev/null; then ok "it says what arrived and what was expected"
else bad "it says what arrived and what was expected" "$(tail -2 "$T/out.txt")"; fi
ck "it retried before giving up (3 copy attempts)" 3 "$(cat "$T/calls" 2>/dev/null || true)"

# 2. the ordinary case: delivered, so the script runs
rc=$(run_pushrun deliver)
ck "a delivered file runs the script" 0 "$rc"
ck "and it ran exactly once" 1 "$(grep -ac RAN "$T/ran.txt" 2>/dev/null || true)"

# 3. a transient failure is survived rather than reported as the guest's fault
rc=$(run_pushrun attempt2)
ck "a transient copy failure is retried and then succeeds" 0 "$rc"
ck "and the script still ran once" 1 "$(grep -ac RAN "$T/ran.txt" 2>/dev/null || true)"

# 4. SEEN TO FAIL: the shipped behaviour - copy, then run regardless - would have run the script
#    with nothing delivered. That is what produced "the file does not exist" on a real guest.
rm -f "$T/ran.txt"; rm -f "$T/incoming/"*; echo never > "$T/mode"
( export PATH="$T/bin:$PATH"; VM=stub-vm
  printf '%s\n' "cmd /c del /q /f \"$INC\\payload.ps1\" 2>nul" | qrexec-client-vm "$VM" qubes.VMShell >/dev/null 2>&1 || true
  qvm-copy-to-vm "$VM" "$T/payload.ps1" >/dev/null 2>&1 || true
  printf '%s\n' "powershell -NoProfile -File \"$INC\\payload.ps1\"" | qrexec-client-vm "$VM" qubes.VMShell >/dev/null 2>&1 || true )
ck "SEEN TO FAIL: the old copy-then-run shape runs the script with 0 bytes delivered" 1 \
   "$(grep -ac RAN "$T/ran.txt" 2>/dev/null || true)"

printf 'qtest-push-selftest: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
