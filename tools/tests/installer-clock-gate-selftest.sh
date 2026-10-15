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

# ---- THE RTC CONVENTION IS A PAIR, NOT A CONSTANT ----------------------------------------------
# This block has now been inverted three times in one day, because each version asserted whichever
# constant I believed at the time. The constant is not the invariant. The invariant is:
#
#   * the INSTALLER picks an OPENING value, DERIVED from whether QWT is already installed. A qube
#     being cleanly installed has no `timezone` feature yet - qubes-core-admin gives it one only
#     once it knows the guest is Windows with working qrexec (qubes/ext/windows.py:
#     `if guest_os == "Windows" and qrexec:`), which it learns from qubes.NotifyTools, which OUR
#     agent calls when it starts. So no QWT means the RTC still holds TRUE UTC, and reading that as
#     local puts the guest BEHIND real time - the one direction that breaks a driver install
#     (0x800B0101, drvinst at 0.125 s of CPU for 25 minutes, measured 2026-09-25). QWT present
#     means the guest HAS reported, so the RTC holds dom0 local and Windows' default is right.
#     Neither derivation is provable from inside the guest (Jev ~0.60 for both available ones),
#     which is exactly why it is an opening value and not a verdict.
#   * the PER-BOOT TASK derives the convention from dom0's real UTC and FLIPS that value when it no
#     longer fits, because once dom0 has set `localtime` the RTC holds dom0 local and 1 puts the
#     guest dom0's whole offset AHEAD - measured 2026-10-15 at exactly 10800 s on a live guest.
#
# Either half alone is a shipped defect: 1 without the convergence is the +3 h we shipped, and 0 in
# the installer reintroduces the 25-minute hang (Jev scored that shape at 0.88 for the feature-unset
# qube). So this asserts BOTH, and that neither place decides alone.
# THE STAGED TREE IS NOT THE PRODUCT, AND MUST NOT GATE IT. mgmt/prime-jobs/<job>/setup is where
# prime-run COPIES the payload it was handed (`--payload`), so it holds whatever release was last
# installed on the rig - by design often an OLDER one, since upgrade cells install a previous
# version on purpose. Gating today's product shape on it fails on any machine that has primed an
# older package, which is noise rather than signal, and in CI the directory does not exist at all so
# the check was silently absent exactly where it would have mattered. The product is packaging/.
for f in packaging/setup/Install-QwtImproved.ps1; do
  b=$(echo "$f" | cut -d/ -f1)
  [ -f "$f" ] || { echo "  FAIL rtc($b): the product installer is missing"; fail=1; continue; }
  if command grep -q 'function Set-RtcConventionForNextBoot' "$f"; then echo "  OK   rtc($b) declares the RTC convention"
  else echo "  FAIL rtc($b): the installer has no RTC convention step"; fail=1; fi
  if tr -d '\r' < "$f" | sed 's/^ *#.*//' | command grep -cE 'New-ItemProperty[^|]*RealTimeIsUniversal' | command grep -q '^1$'; then
    echo "  OK   rtc($b) exactly one writer"
  else echo "  FAIL rtc($b): not exactly one RealTimeIsUniversal writer"; fail=1; fi
  if tr -d '\r' < "$f" | command grep -qE '^ *\$fixed = Set-RtcConventionForNextBoot *$'; then
    echo "  OK   rtc($b) reached from the clock gate's failure branch, by its return value"
  else echo "  FAIL rtc($b): the convention is not written in response to the measurement"; fail=1; fi
  if tr -d '\r' < "$f" | awk '/function Set-RtcConventionForNextBoot/,/^}$/' | command grep -q 'already 1'; then
    echo "  OK   rtc($b) idempotent, and says so when the RTC is not the fault"
  else echo "  FAIL rtc($b): it would rewrite a value that is already set"; fail=1; fi
  if tr -d '\r' < "$f" | awk '/function Set-RtcConventionForNextBoot/,/^}$/' | command grep -q 'sync-clock-from-dom0'; then
    echo "  OK   rtc($b) names the convergence that makes the guess safe"
  else echo "  FAIL rtc($b): it guesses without naming what corrects it later"; fail=1; fi
  if tr -d '\r' < "$f" | awk '/function Set-RtcConventionForNextBoot/,/^}$/' | command grep -q 'did not read back as'; then echo "  OK   rtc($b) reads the value back"
  else echo "  FAIL rtc($b): the write is assumed to have worked"; fail=1; fi
  if tr -d '\r' < "$f" | awk '/function Set-RtcConventionForNextBoot/,/^}$/' | command grep -q 'Fail '; then
    echo "  FAIL rtc($b): a failed write aborts the install - that is not what this breaks"; fail=1
  else echo "  OK   rtc($b) reported, never fatal"; fi
done
# THE LATE STEP SETS THE ZONE, AND MUST NOT PREDICT THE CONVENTION. Its first version wrote
# RealTimeIsUniversal=0 for the next boot, reasoning that dom0 would have set `timezone=localtime`
# by then. That is a prediction about a domain creation that has not happened: a subject can be
# CREATED with the feature unset - the acceptance harness does exactly that - so the next boot can
# still have a true-UTC RTC, and 0 then subtracts the guest's offset. Only a MEASUREMENT can say
# which convention applies, and the per-boot task makes it.
# The ZONE is different and is set here unconditionally: it is correct under either convention, it
# is what makes the guest show the user's own wall clock, and the pre-flight cannot do it because
# qubesdb is not up that early (measured on a fresh install: "qubesdb is not readable yet").
# THE STAGED TREE IS NOT THE PRODUCT, AND MUST NOT GATE IT. mgmt/prime-jobs/<job>/setup is where
# prime-run COPIES the payload it was handed (`--payload`), so it holds whatever release was last
# installed on the rig - by design often an OLDER one, since upgrade cells install a previous
# version on purpose. Gating today's product shape on it fails on any machine that has primed an
# older package, which is noise rather than signal, and in CI the directory does not exist at all so
# the check was silently absent exactly where it would have mattered. The product is packaging/.
for f in packaging/setup/Install-QwtImproved.ps1; do
  b=$(echo "$f" | cut -d/ -f1)
  [ -f "$f" ] || { echo "  FAIL late($b): the product installer is missing"; fail=1; continue; }
  if command grep -q 'function Set-GuestClockForNextBoot' "$f"; then echo "  OK   late($b) a late zone step exists"
  else echo "  FAIL late($b): nothing sets the zone where qubesdb is readable"; fail=1; fi
  # COMMENTS STRIPPED FIRST. The block's own prose explains why it must NOT write the
  # convention, so grepping raw text finds that explanation and calls it a write - the same
  # mistake this repo's checks have made repeatedly. The prose check below uses raw text.
  blkraw=$(tr -d '\r' < "$f" | awk '/function Set-GuestClockForNextBoot/,/^}$/')
  blk=$(printf '%s' "$blkraw" | sed 's/#.*//')
  printf '%s' "$blk" | command grep -q 'Set-GuestTimeZoneFromHost' \
    && echo "  OK   late($b) retries the zone where qubesdb IS readable" \
    || { echo "  FAIL late($b): it does not retry the zone"; fail=1; }
  # A WRITE, not a mention: the step's own log line says the per-boot task "sets
  # RealTimeIsUniversal from what it finds", and matching that string called the message a write.
  printf '%s' "$blk" | command grep -qE 'New-ItemProperty|Set-ItemProperty|reg add' \
    && { echo "  FAIL late($b): it writes the convention from a PREDICTION - only a measurement may set it"; fail=1; } \
    || echo "  OK   late($b) never writes the convention - that is the per-boot task's measurement"
  printf '%s' "$blk" | command grep -q 'per-boot task' \
    && echo "  OK   late($b) names what does decide it" \
    || { echo "  FAIL late($b): it does not say where the convention comes from"; fail=1; }
  [ "$(sed 's/#.*//' "$f" | command grep -c 'Set-GuestClockForNextBoot')" -ge 2 ] \
    && echo "  OK   late($b) is called, not just defined" \
    || { echo "  FAIL late($b): defined and never called"; fail=1; }
  # A ZONE THE USER CHOSE IS NOT OURS TO OVERWRITE.
  tzblk=$(tr -d '\r' < "$f" | awk '/function Set-GuestTimeZoneFromHost/,/^}$/')
  printf '%s' "$tzblk" | command grep -q "notin @('UTC', '')" \
    && echo "  OK   late($b) a non-default guest timezone is left alone" \
    || { echo "  FAIL late($b): it would overwrite a timezone the user chose"; fail=1; }
done

# THE SECOND HALF MUST EXIST, or the constant above is the +3 h defect on every boot.
C=guest/sync-clock-from-dom0.ps1
if command grep -q 'CLOCKCONV' "$C"; then echo "  OK   rtc(boot) the per-boot task derives the convention"
else echo "  FAIL rtc(boot): nothing converges the value after dom0 sets the timezone feature"; fail=1; fi
if awk '/CLOCKCONV the RTC fits NEITHER/,0' "$C" | command grep -q 'diagnose, do not guess'; then
  echo "  OK   rtc(boot) an RTC fitting neither convention is an anomaly, not a guess"
else echo "  FAIL rtc(boot): an unexplainable RTC would be guessed at"; fail=1; fi
if command grep -qE 'Value \$want' "$C"; then echo "  OK   rtc(boot) it writes the DERIVED value, not a constant"
else echo "  FAIL rtc(boot): the per-boot task writes a constant too"; fail=1; fi
# THE UNATTENDED IMAGES MUST DECLARE NOTHING. They used to write 1 in the specialize pass, and that
# is what made the rig unable to measure its own product: the value was baked into every golden and
# inherited by every clone, so whatever the installer and the per-boot task derived was pre-empted.
# Windows' own default - the value absent, the RTC read as LOCAL time - is already the half that
# PAIRS with the `timezone=localtime` Qubes gives every Windows qube. An image that declares a
# convention is deciding something only a measurement can decide.
# XML COMMENTS ARE STRIPPED FIRST, because each of these files now EXPLAINS the write it used to
# carry - and a raw grep finds that explanation and calls it a write. Stripping the prose and then
# matching ANY mention is stronger than matching one spelling of `reg add`: it fails whatever way a
# future edit reintroduces the value.
for x in mgmt/autounattend*.xml; do
  [ -f "$x" ] || continue
  body=$(python3 -c "import re,sys;print(re.sub(r'<!--.*?-->','',open(sys.argv[1],encoding='utf-8').read(),flags=re.S))" "$x")
  if printf '%s' "$body" | command grep -q 'RealTimeIsUniversal'; then
    echo "  FAIL rtc($(basename "$x")): the image declares an RTC convention - that is the product's to derive"; fail=1
  else echo "  OK   rtc($(basename "$x")) declares no convention; Windows' default pairs with localtime"
  fi
done
# THE ORDER IS INVERTED ON PURPOSE, AND THAT IS THE ASSERTION. The convention used to be declared
# BEFORE the gate - unconditionally, on every install - and this check used to require exactly that.
# The normal configuration is already correct, so nothing may be declared until a measurement says
# otherwise: the gate runs FIRST and the convention is written only from its failure branch. A write
# that still came first would be the unconditional write this release removed.
gate_line=$(command grep -n "Assert-PayloadClockSane -Root .Root -Why 'stage 1 pre-flight'" packaging/setup/Install-QwtImproved.ps1 | head -1 | cut -d: -f1)
rtc_line=$(command grep -nE '^ *\$fixed = Set-RtcConventionForNextBoot *$' packaging/setup/Install-QwtImproved.ps1 | head -1 | cut -d: -f1)
ncalls=$(command grep -cE '^ *\$?[a-z]* *=? *Set-RtcConventionForNextBoot *$' packaging/setup/Install-QwtImproved.ps1)
if [ -n "$gate_line" ] && [ -n "$rtc_line" ] && [ "$gate_line" -lt "$rtc_line" ] && [ "$ncalls" = 1 ]; then
  echo "  OK   the clock is MEASURED (line $gate_line) before the convention is written (line $rtc_line), once"
else
  echo "  FAIL the convention is not written from the gate's verdict (gate=${gate_line:-none} write=${rtc_line:-none} calls=$ncalls)"; fail=1
fi

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
# THE SETUP WINDOW MUST PIN A ZERO-OFFSET ZONE, and this check asserted the opposite for a day.
# The zone and the RTC convention are two halves of one sum: Windows computes
# guest_UTC = RTC_content - guest_zone_offset. During Setup the qube has no `timezone` feature yet,
# so Xen gives the RTC its default and it holds TRUE UTC - and the only zone that makes that sum
# come out right is one whose offset is ZERO. A non-zero zone there puts the guest BEHIND real time,
# which is the direction that makes a CI-minted catalog look not-yet-valid (0x800B0101, 25 minutes).
# 'FLE Standard Time' worked for exactly one day, and only because the same commit also forced
# RealTimeIsUniversal=1; removing that half and keeping this one is how a pair becomes a defect.
# The REAL zone is set by the installer from /qubes-timezone at the end of the install, so every
# boot the sweep measures still runs with a non-zero offset (Jev: coverage_after_the_change 0.82).
# THE GERMAN FILE IS A DOCUMENTED EXCEPTION: it is the reproduction environment for the hang, and
# the only rig image that enters the Setup window with a non-zero offset. Nothing in the gate matrix
# clean-installs from it.
for x in mgmt/autounattend*.xml; do
  [ -f "$x" ] || continue
  b=$(basename "$x"); z=$(command grep -aoE '<TimeZone>[^<]*' "$x" | head -1 | cut -d'>' -f2)
  case "$b" in
    *-de.xml) echo "  OK   tz($b) keeps its own zone '$z' - the documented reproduction environment" ;;
    *) if [ "$z" = "UTC" ]; then echo "  OK   tz($b) pins a zero-offset zone for the Setup window"
       else echo "  FAIL tz($b): Setup zone '$z' has a non-zero offset while the RTC holds true UTC - this guest installs BEHIND real time and the catalog gate refuses it"; fail=1; fi ;;
  esac
done
# and the late transition must exist, or the guest never reaches dom0's zone at all
if tr -d '\r' < "$I" | awk '/function Set-GuestClockForNextBoot/,/^}$/' | command grep -q 'Set-GuestTimeZoneFromHost'; then
  echo "  OK   tz: the real zone is set late, where qubesdb is readable"
else echo "  FAIL tz: nothing transitions the guest off the Setup zone"; fail=1; fi

if [ "$fail" = 0 ]; then echo "PASS: the gate refuses exactly the clock-broken cases"; exit 0; fi
echo "FAIL: the installer would not refuse a clock-broken driver package"
exit 1
