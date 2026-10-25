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
PWSH="$("$(dirname "$0")/pwsh-path.sh" || true)"
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
m = re.search(r'^(function Test-SigningClockSane \{.*?\n\}\n)', s, re.S | re.M)
if not m:
    sys.exit("SELFTEST-ERROR: Test-SigningClockSane not found in the installer")
w = re.search(r'^(function Assert-PayloadClockSane \{.*?\n\}\n)', s, re.S | re.M)
if not w:
    sys.exit("SELFTEST-ERROR: Assert-PayloadClockSane not found in the installer")
# The shipped Write-Log uses Write-Host, which does NOT go to the pipeline. Stubbing it with
# Write-Output instead made the function return an ARRAY of log lines plus the boolean, and
# `if ($r)` on a non-empty array is always true - so the first version of this selftest
# reported the gate broken when the gate was fine and the STUB was wrong. Match the real one.
print("function Write-Log { param($m,$l='INFO') Write-Host \"[$l] $m\" }")
print(m.group(1))
print(w.group(1))
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

# STRICTMODE GUARD. The installer runs under Set-StrictMode, where READING a variable that was
# never set is a terminating error. The first version of this gate set $global:QwtClockSkewRefusal
# only in the refusal branch, so on a guest with a HEALTHY clock the xencons gate read an undefined
# variable and failed the entire install - a guard that breaks the good path is worse than the hang
# it prevents. Assert the assignment comes before any read.
# The check must demand the UNCONDITIONAL initialiser, not merely "some assignment first":
# the buggy version assigned $true inside the refusal branch, which precedes the read and would
# satisfy a naive ordering test while leaving the good path throwing. Measured: the first version
# of this check PASSED with the defect re-introduced, i.e. it was decoration.
first_init=$(grep -n '\$global:QwtClockSkewRefusal *= *\$false' "$SRC" | head -1 | cut -d: -f1)
first_read=$(grep -n '\$global:QwtClockSkewRefusal' "$SRC" | grep -v '\$global:QwtClockSkewRefusal *=' | head -1 | cut -d: -f1)
if [ -z "${first_init:-}" ]; then
  echo "  FAIL QwtClockSkewRefusal has no unconditional '= \$false' initialiser - under StrictMode the good path throws"; fail=1
elif [ -n "${first_read:-}" ] && [ "$first_read" -lt "$first_init" ]; then
  echo "  FAIL QwtClockSkewRefusal is READ at line $first_read before its initialiser at line $first_init"; fail=1
else
  echo "  OK   QwtClockSkewRefusal initialised (line $first_init) before any read${first_read:+ (line $first_read)}"
fi

# ---- THE WHOLE-PAYLOAD GATE ---------------------------------------------------------------
# The per-driver gate was NOT sufficient (Jev: fix_sufficient 0.26). A payload has certs in three
# directories and msiexec installs drivers of its own, so the gate that matters is the one that
# looks at the ENTIRE payload once, before anything mutates. Drive it on a real tree, both ways.
mkpayload() { # $1=dest $2..=cer files to scatter
  mkdir -p "$1/certs" "$1/pv-drivers" "$1/idd-driver"
  cp "$T/valid.cer" "$1/certs/qwt-signer.cer"
  cp "$2" "$1/pv-drivers/xenvif-signer.cer"
  cp "$T/valid.cer" "$1/idd-driver/idd-signer.cer"
}
mkpayload "$T/good" "$T/valid.cer"
mkpayload "$T/bad"  "$T/future.cer"
# A skewed cert in idd-driver/ ALONE must also be caught - that directory was invisible to the
# per-driver gate entirely, which is the coverage hole this function exists to close.
mkpayload "$T/baditd" "$T/valid.cer"; cp "$T/future.cer" "$T/baditd/idd-driver/idd-signer.cer"

payload_run() { # $1=payload root -> prints the offender count
  "$PWSH" -NoProfile -Command ". '$T/fn.ps1'; \$script:Result = @{ detail = @{} }; \
     \$o = @(Assert-PayloadClockSane -Root '$1'); \$o.Count" 2>/dev/null | tail -1
}
chk "sane payload passes the whole-payload gate"     0 "$(payload_run "$T/good")"
chk "skewed pv-drivers cert caught"                  1 "$(payload_run "$T/bad")"
chk "skewed idd-driver cert caught (per-driver gate never saw this dir)" 1 "$(payload_run "$T/baditd")"

# ---- COVERAGE: every driver-install site is dominated by a refusal -------------------------
# The first version of this gate guarded ONE of four sites. This counts them, so adding a fourth
# pnputil call without a guard fails here rather than on a German guest twenty-five minutes in.
cov=$(python3 - "$SRC" <<'PYCOV'
import sys
# DOMINANCE, not proximity. The first version of this check looked for the string
# "QwtClockSkewRefusal" in the 60 lines before each pnputil call. That is not a guard: deleting
# the xencons SKIP branch left the setter line inside the window, so the check still passed with
# the defect re-introduced - decoration again, the exact failure this file already records once.
# So walk the braces and ask the real question: is this call inside a block whose CONDITION is a
# clock test? `} else {` is resolved back to its own `if`, because that is how xenvif is guarded.
s = open(sys.argv[1], encoding="utf-8").read()
lines = s.split("\n")
GUARDS = ("QwtClockSkewRefusal", "Test-SigningClockSane")
stack = []          # line indices of the currently-open blocks' CONDITION lines
last_closed = None
bad = []
for i, l in enumerate(lines):
    code = l.split("#", 1)[0]
    opener = i
    for ch in code:
        if ch == "{":
            # a `} else {` on this line has already popped; the condition that governs this
            # block is the `if` that opened the block just closed, not the word "else".
            stack.append(last_closed if (last_closed is not None and "else" in code) else opener)
        elif ch == "}":
            if stack:
                last_closed = stack.pop()
    if "pnputil.exe /add-driver" in l:
        # (a) an enclosing block's condition is a clock test (xenvif's `} else {`, xencons' skip);
        by_block = any(any(g in lines[j] for g in GUARDS) for j in stack)
        # (b) or an EARLY EXIT on a clock test precedes the call in the innermost enclosing block
        #     (the IddCx site: `if ($global:QwtClockSkewRefusal) { throw ... }`, which does not
        #     wrap the call but does stop it). Both are real guards; only one shape was.
        by_exit = False
        top = stack[-1] if stack else 0
        for j in range(top, i):
            if lines[j].lstrip().startswith("if (") and any(g in lines[j] for g in GUARDS):
                body = "\n".join(lines[j:j + 6])
                if "throw" in body or "return" in body or "Fail " in body:
                    by_exit = True
        if not (by_block or by_exit):
            bad.append(str(i + 1))
if "Assert-PayloadClockSane -Root $Root -Why $Why" not in s:
    bad.append("Import-PayloadCerts:no-gate")
if "$skewed = Assert-PayloadClockSane -Root $Root -Why 'stage 1 pre-flight'" not in s:
    bad.append("Assert-Stage1Preflight:no-gate")
print(",".join(bad) if bad else "0")
PYCOV
)
chk "every driver-install site is behind a clock refusal" 0 "$cov"

# ---- PROOF OF FAILURE ----------------------------------------------------------------------
# `--prove` neutralises each of the five guards in turn and asserts the coverage check FAILS on
# every one. A check that has never been seen to fail is decoration, and the first two versions of
# the check above were exactly that: one matched the guard's own setter line, the other could not
# see an early-exit guard. Run this after touching either the installer's guards or the check.
if [ "${1:-}" = "--prove" ]; then
  echo "--- proof of failure: each guard neutralised in turn"
  python3 - <<'PYPROVE' || fail=1
import subprocess, os
src = "packaging/setup/Install-QwtImproved.ps1"
orig = open(src, encoding="utf-8").read()
subjects = {
 "xenvif else-guard":  ("if (-not (Test-SigningClockSane $pvCer 'xenvif')) {", "if ($false) {"),
 "xencons skip-guard": ("        if ($global:QwtClockSkewRefusal) {\n            # The refusal has to SKIP",
                        "        if ($false) {\n            # The refusal has to SKIP"),
 "idd throw-guard":    ("        if ($global:QwtClockSkewRefusal) {\n            throw (\"the guest clock cannot validate",
                        "        if ($false) {\n            throw (\"the guest clock cannot validate"),
 "preflight gate":     ("$skewed = Assert-PayloadClockSane -Root $Root -Why 'stage 1 pre-flight'", "$skewed = @()"),
 "cert-import gate":   ("$skewed = Assert-PayloadClockSane -Root $Root -Why $Why", "$skewed = @()"),
}
bad = 0
try:
    for name, (a, b) in subjects.items():
        if a not in orig:
            print("  FAIL %-20s: the guard this proof neutralises is GONE from the installer" % name); bad = 1; continue
        open(src, "w", encoding="utf-8").write(orig.replace(a, b, 1))
        r = subprocess.run(["bash", "tools/tests/installer-clock-gate-selftest.sh"],
                           capture_output=True, text=True, env={**os.environ})
        hit = [x for x in r.stdout.split("\n") if "driver-install site" in x]
        got = hit[0].strip() if hit else "NO COVERAGE LINE"
        if got.startswith("FAIL"):
            print("  OK   %-20s neutralised -> the check caught it (%s)" % (name, got.split("got ")[-1]))
        else:
            print("  FAIL %-20s neutralised -> the check still PASSED: it is decoration" % name); bad = 1
finally:
    # Always restore, even on an exception. An earlier hand-run of this proof aborted on a
    # mismatched pattern and left a NEUTRALISED guard in the installer.
    open(src, "w", encoding="utf-8").write(orig)
raise SystemExit(bad)
PYPROVE
fi

# ---- THERE IS NO RTC CONVENTION TO SET, AND NOTHING SETS ONE ----------------------------------
# This region asserted five different shapes of a RealTimeIsUniversal write over two weeks - a
# constant, a derived value, a value written only on this gate's failure branch, each with a
# per-boot task converging it. All of it was machinery for a window that only existed because the
# qube's `timezone` feature is set LATE: dom0 sets it when the GUEST reports os+qrexec, which cannot
# happen before the first install. The window is removed instead - every path that creates a guest
# sets `timezone=localtime` before its first boot - so the clock holds dom0 local time on every
# boot, Windows reads it as local (its default), and the guest's zone is dom0's. Nothing to declare.
# The absence is asserted in full by tools/tests/rtc-utc-selftest.sh; here we only check that this
# installer, whose gate this suite is about, writes none and names the real fix when it refuses.
I=packaging/setup/Install-QwtImproved.ps1
W='New-ItemProperty[^|]*RealTimeIsUniversal|Set-ItemProperty[^|]*RealTimeIsUniversal|reg(\.exe)? +add[^|]*RealTimeIsUniversal'
if [ "$(tr -d '\r' < "$I" | sed 's/^ *#.*//' | command grep -cE "$W")" = 0 ]; then
  echo "  OK   rtc: the installer sets no hardware-clock convention"
else echo "  FAIL rtc: the installer writes RealTimeIsUniversal - nothing should"; fail=1; fi
if tr -d '\r' < "$I" | awk '/function Assert-Stage1Preflight/,/^}$/' | command grep -q 'qvm-features <vm> timezone localtime'; then
  echo "  OK   rtc: the clock refusal names the qube feature as the fix"
else echo "  FAIL rtc: the refusal does not name 'qvm-features <vm> timezone localtime'"; fail=1; fi
C=guest/sync-clock-from-dom0.ps1
if [ "$(tr -d '\r' < "$C" | sed 's/^ *#.*//' | command grep -cE "$W")" = 0 ]; then
  echo "  OK   rtc(boot): the per-boot task sets no convention either - it only pulls the clock"
else echo "  FAIL rtc(boot): the per-boot task writes a convention"; fail=1; fi

# THE ANSWER FILES PIN A REAL ZONE. The clock holds dom0 LOCAL time from the first instant of Setup
# (the feature is set at create time), so the zone that makes the arithmetic right is dom0's, not
# UTC. This check asserted the opposite for one afternoon, while the feature was still set late.
for x in mgmt/autounattend*.xml; do
  [ -f "$x" ] || continue
  b=$(basename "$x"); z=$(command grep -aoE '<TimeZone>[^<]*' "$x" | head -1 | cut -d'>' -f2)
  if [ "$z" = "UTC" ]; then
    echo "  FAIL tz($b): pins UTC, but this qube's clock holds dom0 local time from its first boot"; fail=1
  elif [ -n "$z" ]; then echo "  OK   tz($b) pins a real zone ('$z')"
  else echo "  FAIL tz($b): no TimeZone element"; fail=1; fi
done

# ---- THE OS APPLIES THE ZONE -------------------------------------------------------------------
# Setting the RTC convention fixes the guest's notion of UTC. It still has to DISPLAY the user's
# wall-clock time, and a desktop pinned to UTC does not. dom0 publishes its own zone in qubesdb as
# an IANA name (/qubes-timezone), so the installer matches it instead of guessing - and tzutil
# takes WINDOWS ids, which .NET Framework on the guest cannot derive from IANA.
I=packaging/setup/Install-QwtImproved.ps1
if command grep -q 'function Set-GuestTimeZoneFromHost' "$I"; then echo "  OK   tz: the installer matches dom0's zone"
else echo "  FAIL tz: the installer does not set the guest timezone"; fail=1; fi
if tr -d '\r' < "$I" | awk '/function Set-GuestTimeZoneFromHost/,/^}$/' | command grep -q "/qubes-timezone"; then
  echo "  OK   tz: read from qubesdb, not hardcoded"
else echo "  FAIL tz: the zone is not read from /qubes-timezone"; fail=1; fi
# an unmapped zone must be REPORTED, never guessed: a wrong zone is worse than an admitted gap
if tr -d '\r' < "$I" | awk '/function Set-GuestTimeZoneFromHost/,/^}$/' | command grep -q 'not in this installer'; then
  echo "  OK   tz: an unmapped IANA zone is reported, not guessed"
else echo "  FAIL tz: an unmapped zone would be guessed at or silently skipped"; fail=1; fi
if tr -d '\r' < "$I" | awk '/function Set-GuestTimeZoneFromHost/,/^}$/' | command grep -q 'already'; then
  echo "  OK   tz: idempotent when the zone already matches"
else echo "  FAIL tz: it would rewrite the zone on every install"; fail=1; fi
if tr -d '\r' < "$I" | awk '/function Set-GuestTimeZoneFromHost/,/^}$/' | command grep -q 'reads back'; then
  echo "  OK   tz: the result is read back"
else echo "  FAIL tz: the tzutil result is assumed"; fail=1; fi
# the two zones this project actually ships must map correctly
for pair in "Europe/Sofia:FLE Standard Time" "Europe/Berlin:W. Europe Standard Time"; do
  ia=${pair%%:*}; wz=${pair#*:}
  if tr -d '\r' < "$I" | command grep -q "'$ia'='$wz'"; then echo "  OK   tz: $ia -> $wz"
  else echo "  FAIL tz: $ia is not mapped to '$wz'"; fail=1; fi
done
# and the late transition must exist, or the guest never reaches dom0's zone at all
if tr -d '\r' < "$I" | awk '/function Set-GuestClockForNextBoot/,/^}$/' | command grep -q 'Set-GuestTimeZoneFromHost'; then
  echo "  OK   tz: the real zone is set late, where qubesdb is readable"
else echo "  FAIL tz: nothing transitions the guest off the Setup zone"; fail=1; fi

if [ "$fail" = 0 ]; then echo "PASS: the gate refuses exactly the clock-broken cases"; exit 0; fi
echo "FAIL: the installer would not refuse a clock-broken driver package"
exit 1
