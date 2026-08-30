#!/bin/bash
# G0 NEGATIVE CONTROL — the run that turns G0's PASS from `PASS-UNPROVEN` into evidence.
#
# H5.2: "A check counts as evidence only once it has been seen to FAIL on a build with the defect
# deliberately re-introduced. Otherwise record its PASS as unproven." G0 has been carried as
# PASS-UNPROVEN because sourcing an unsigned-catalog fixture was an open question (protocol D7).
# This settles it without needing an archived defect-era package: the defect is not a rare artifact,
# it is a STRUCTURE — an unsigned catalog is a well-formed PKCS#7 SignedData whose `signerInfos` SET
# is EMPTY. That is precisely why `patch-xenbus-inf.ps1` shipping 4-of-5 unsigned went unnoticed:
# the files parse fine, they just carry no signer, and nothing ever looked.
#
# So the fixture is SYNTHESISED to that exact structure rather than hunted for. The control is
# two-sided, which is what makes it meaningful:
#   POSITIVE  - the untouched payload copy must PASS (exit 0). Without this the negative could be
#               failing for some unrelated reason, e.g. a broken temp copy.
#   NEGATIVE  - the same copy with ONE catalog replaced by the unsigned structure must FAIL
#               (exit 1) AND name that catalog as UNSIGNED. A gate that failed without naming it
#               would be failing by accident.
#
# Exit 0 = the control passed (G0 is proven to detect the defect); 1 = the control FAILED, which
# means G0's verdicts cannot be trusted; 2 = the control could not run.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$HERE/tools/g0-catalog-gate.py"
SRC="${1:-$HOME/qwt-matrix-work/dl/qwt-improved-setup}"

[ -f "$GATE" ] || { echo "UNUSABLE: no gate at $GATE"; exit 2; }
[ -d "$SRC"  ] || { echo "UNUSABLE: no payload at $SRC"; exit 2; }

WORK=$(mktemp -d -p "${CLAUDE_JOB_DIR:-/tmp}/tmp" g0nc-XXXXXX 2>/dev/null) \
  || WORK=$(mktemp -d -t g0nc-XXXXXX) || { echo "UNUSABLE: no temp dir"; exit 2; }
trap 'rm -rf "$WORK"' EXIT
cp -r "$SRC" "$WORK/payload" || { echo "UNUSABLE: could not copy payload"; exit 2; }

echo "=== G0 negative control ==="
echo "  payload copy: $WORK/payload"
echo ""

# --- side 1: the untouched copy must PASS -------------------------------------------------------
echo "--- POSITIVE side: untouched copy must PASS"
if ! python3 "$GATE" "$WORK/payload" > "$WORK/pos.out" 2>&1; then
    echo "CONTROL FAILED: the untouched payload copy did not pass G0."
    echo "  Nothing can be concluded from the negative side until this passes."
    tail -20 "$WORK/pos.out" | sed 's/^/    /'
    exit 1
fi
echo "  ok: $(grep -a '^G0 PASS' "$WORK/pos.out")"
echo ""

# --- plant the defect ---------------------------------------------------------------------------
# Pick a REAL catalog from the copy and overwrite it with a structurally-valid PKCS#7 SignedData
# carrying an EMPTY signerInfos SET - i.e. a catalog that was regenerated and never re-signed.
VICTIM=$(find "$WORK/payload" -iname '*.cat' | sort | head -1)
[ -n "$VICTIM" ] || { echo "UNUSABLE: no .cat in the payload copy to substitute"; exit 2; }
echo "--- planting the defect in: ${VICTIM#$WORK/payload/}"

python3 - "$VICTIM" <<'PY' || { echo "UNUSABLE: could not write the fixture"; exit 2; }
import sys

def L(n):
    if n < 0x80:
        return bytes([n])
    b = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return bytes([0x80 | len(b)]) + b

def T(tag, content):
    return bytes([tag]) + L(len(content)) + content

# OID 1.2.840.113549.1.7.2 (signedData) and 1.2.840.113549.1.7.1 (data)
OID_SIGNED = bytes([0x2A,0x86,0x48,0x86,0xF7,0x0D,0x01,0x07,0x02])
OID_DATA   = bytes([0x2A,0x86,0x48,0x86,0xF7,0x0D,0x01,0x07,0x01])

signed_data = T(0x30,
    T(0x02, b"\x01") +          # version
    T(0x31, b"") +              # digestAlgorithms: empty SET
    T(0x30, T(0x06, OID_DATA)) +  # encapContentInfo
    T(0x31, b"")                # signerInfos: EMPTY - this IS the defect
)
content_info = T(0x30, T(0x06, OID_SIGNED) + T(0xA0, signed_data))
open(sys.argv[1], "wb").write(content_info)
print(f"  wrote {len(content_info)} bytes: PKCS#7 signedData with an empty signerInfos SET")
PY
echo ""

# --- side 2: the gate must now FAIL, and must name the victim ------------------------------------
echo "--- NEGATIVE side: gate must FAIL and name the catalog"
python3 "$GATE" "$WORK/payload" > "$WORK/neg.out" 2>&1
RC=$?
VNAME=$(basename "$VICTIM")

if [ $RC -eq 0 ]; then
    echo "CONTROL FAILED: G0 PASSED a payload containing an unsigned catalog."
    echo "  G0's verdicts are worthless until this is fixed - it cannot see the defect it exists for."
    tail -20 "$WORK/neg.out" | sed 's/^/    /'
    exit 1
fi
if ! grep -aq 'UNSIGNED' "$WORK/neg.out"; then
    echo "CONTROL FAILED: G0 failed (rc=$RC) but never reported UNSIGNED."
    echo "  A gate that fails for the wrong reason is not evidence."
    tail -20 "$WORK/neg.out" | sed 's/^/    /'
    exit 1
fi
if ! grep -a 'UNSIGNED' "$WORK/neg.out" | grep -aq "$VNAME"; then
    echo "CONTROL FAILED: G0 reported UNSIGNED but not for $VNAME - it flagged something else."
    grep -a 'UNSIGNED' "$WORK/neg.out" | sed 's/^/    /'
    exit 1
fi
echo "  ok: $(grep -a 'UNSIGNED' "$WORK/neg.out" | head -1 | sed 's/^ *//')"
echo "  ok: $(grep -a '^G0 FAIL' "$WORK/neg.out")"
echo ""
echo "=== CONTROL PASSED ==="
echo "G0 has now been SEEN TO FAIL with the defect deliberately present, and to pass without it."
echo "Its PASS is evidence (H5.2), no longer PASS-UNPROVEN. Protocol D7 is settled: the fixture is"
echo "synthesised to the defect's structure, not sourced from an archived package."
exit 0
