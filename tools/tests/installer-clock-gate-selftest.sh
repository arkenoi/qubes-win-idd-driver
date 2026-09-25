#!/bin/bash
# installer-clock-gate-selftest.sh - the installer must REFUSE a driver whose signing certificate
# is not valid at the guest's current clock, instead of hanging.
#
# WHY: measured 2026-09-25, a guest whose clock was two hours behind UTC rejected the driver
# catalog as not-yet-valid (setupapi.dev.log: "Catalog = xenvif.cat, Error = 0x800B0101") and then
# drvinst sat at 0.125 s of CPU for twenty-five minutes until the harness deadline fired. The
# installer log said only "installing xenvif". The gate exists so that becomes a named refusal in
# seconds; this drives it with the defect present, because a check never seen to fail is decoration.
#
# It extracts the function from the shipped installer rather than copying it, so the thing tested
# is the thing that ships.
set -u
cd "$(dirname "$0")/../.." || exit 2
SRC=packaging/setup/Install-QwtImproved.ps1
PWSH="${PWSH:-/home/user/pwsh74/pwsh}"
[ -f "$SRC" ] || { echo "SELFTEST-ERROR: $SRC missing"; exit 2; }
[ -x "$PWSH" ] || { echo "SELFTEST-ERROR: no pwsh at $PWSH (set PWSH=)"; exit 2; }
python3 -c 'import cryptography' 2>/dev/null || { echo "SELFTEST-ERROR: python cryptography needed to mint test certificates"; exit 2; }

T=$(mktemp -d "${TMPDIR:-/tmp}/clockgate.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT

# Three certificates: valid now, not yet valid, already expired. Minted in DER so the .NET
# X509Certificate2 the installer uses can load them exactly as it would a shipped signer .cer.
python3 - "$T" <<'PYCERT'
import sys, datetime
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
out = sys.argv[1]
now = datetime.datetime.now(datetime.timezone.utc)
def mk(name, nb_days, na_days):
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    n = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "clockgate-" + name)])
    cert = (x509.CertificateBuilder()
            .subject_name(n).issuer_name(n).public_key(key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(now + datetime.timedelta(days=nb_days))
            .not_valid_after(now + datetime.timedelta(days=na_days))
            .sign(key, hashes.SHA256()))
    open("%s/%s.cer" % (out, name), "wb").write(cert.public_bytes(serialization.Encoding.DER))
mk("valid",  -1,  30)     # valid right now
mk("future",  2,  40)     # NotBefore in the future - the measured failure
mk("past",  -40,  -2)     # already expired
PYCERT

# Pull the function out of the installer verbatim.
python3 - "$SRC" > "$T/fn.ps1" <<'PY'
import re, sys
s = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'(    function Test-SigningClockSane \{.*?\n    \}\n)', s, re.S)
if not m:
    sys.exit("SELFTEST-ERROR: Test-SigningClockSane not found in the installer")
# The shipped Write-Log uses Write-Host, which does NOT go to the pipeline. Stubbing it with
# Write-Output instead made the function return an ARRAY of log lines plus the boolean, and
# `if ($r)` on a non-empty array is always true - so the first version of this selftest
# reported the gate broken when the gate was fine and the STUB was wrong. Match the real one.
print("function Write-Log { param($m,$l='INFO') Write-Host \"[$l] $m\" }")
print(m.group(1))
PY
[ -s "$T/fn.ps1" ] || { echo "SELFTEST-ERROR: could not extract the function"; exit 2; }

run() { # $1=cer  -> prints True/False
  "$PWSH" -NoProfile -Command ". '$T/fn.ps1'; \$r = Test-SigningClockSane '$1' 'probe'; if (\$r) { 'True' } else { 'False' }" 2>/dev/null | tail -1
}

fail=0
chk() { # name expected actual
  if [ "$2" = "$3" ]; then echo "  OK   $1 -> $3"
  else echo "  FAIL $1: expected $2, got $3"; fail=1; fi
}
echo "installer clock-gate selftest"
chk "valid certificate accepted"        True  "$(run "$T/valid.cer")"
chk "NOT-YET-VALID certificate refused" False "$(run "$T/future.cer")"
chk "EXPIRED certificate refused"       False "$(run "$T/past.cer")"
chk "missing file does not block"       True  "$(run "$T/does-not-exist.cer")"

if [ "$fail" = 0 ]; then echo "PASS: the gate refuses exactly the clock-broken cases"; exit 0; fi
echo "FAIL: the installer would not refuse a clock-broken driver package"
exit 1
