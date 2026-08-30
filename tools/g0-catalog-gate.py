#!/usr/bin/env python3
"""G0 - the catalog-signature gate (ACCEPTANCE-PROTOCOL Sec 4, P0-CORE.1).

WHY THIS EXISTS. `patch-xenbus-inf.ps1` regenerated all five PV catalogs and re-signed only
`xenbus.cat`. Four of five therefore shipped UNSIGNED, and the install turned into a 27.9-minute
modal hang while PnP waited for a driver-trust answer nothing in session 0 could give. Nothing in
the build or the harness noticed, because nothing ever looked inside a .cat.

WHAT IT ASSERTS, per catalog, from the DER PKCS#7 itself:
  1. `signerInfos` is NON-EMPTY. An unsigned catalog is a well-formed PKCS#7 with an empty
     signerInfos SET - it does not fail to parse, which is exactly why it went unnoticed.
  2. Every signer resolves to a certificate SHIPPED IN THE PAYLOAD, matched by
     (issuer DN, serialNumber) - never by CN. These are throwaway CI certs; CN matching would
     accept any cert that merely calls itself the same thing.

Catalogs are read from the payload tree AND from inside `msi/installer.msi` (the PV catalogs live
in the MSI image, not loose on disk), so a gate run on the payload directory alone would miss the
very files the 27.9-minute hang came from.

WHY A HAND-ROLLED DER WALKER. This qube has no `openssl` binary and no `asn1crypto`; `cryptography`
exposes the embedded certificates but not `signerInfos`, which is the field that actually carries
the defect. The walker below reads only the SignedData spine needed to reach signerInfos and each
SignerInfo's issuerAndSerialNumber - it is not a general ASN.1 implementation and does not try to be.

  tools/g0-catalog-gate.py <payload-dir> [--expect-min N]

Exit 0 = PASS, 1 = FAIL (a real defect in the artifact), 2 = UNUSABLE INPUT (missing dir, no 7z,
no catalogs found) - the three-exit contract, so "the gate could not run" can never be read as
"the gate passed".
"""
import os
import subprocess
import sys
import tempfile

from cryptography import x509

OID_SIGNED_DATA = "1.2.840.113549.1.7.2"


# --- minimal DER reader -------------------------------------------------------------------------
def _read_tlv(buf, i):
    """Return (tag, header_len, content_len, content_start) for the TLV at buf[i:]."""
    tag = buf[i]
    j = i + 1
    n = buf[j]
    j += 1
    if n & 0x80:
        k = n & 0x7F
        if k == 0 or k > 4:
            raise ValueError("unsupported DER length form")
        n = int.from_bytes(buf[j:j + k], "big")
        j += k
    return tag, j - i, n, j


def _children(buf, start, end):
    """Yield (tag, content_start, content_end, elem_start, elem_end) for each TLV in a range."""
    i = start
    while i < end:
        tag, hlen, clen, cstart = _read_tlv(buf, i)
        yield tag, cstart, cstart + clen, i, cstart + clen
        i = cstart + clen


def _oid_str(buf, s, e):
    b = buf[s:e]
    first = b[0]
    parts = [str(first // 40), str(first % 40)]
    v = 0
    for c in b[1:]:
        v = (v << 7) | (c & 0x7F)
        if not c & 0x80:
            parts.append(str(v))
            v = 0
    return ".".join(parts)


def is_pkcs7_signed_data(der):
    """Cheap content sniff: is this a DER PKCS#7 ContentInfo carrying signedData?"""
    if len(der) < 16 or der[0] != 0x30:
        return False
    try:
        tag, _, clen, cs = _read_tlv(der, 0)
        kids = list(_children(der, cs, cs + clen))
        return bool(kids) and kids[0][0] == 0x06 and \
            _oid_str(der, kids[0][1], kids[0][2]) == OID_SIGNED_DATA
    except Exception:
        return False


def parse_signer_infos(der):
    """-> list of (issuer_der, serial_int). Empty list means the catalog is UNSIGNED."""
    # ContentInfo ::= SEQUENCE { contentType OID, content [0] EXPLICIT SignedData }
    tag, _, clen, cs = _read_tlv(der, 0)
    if tag != 0x30:
        raise ValueError("not a DER SEQUENCE")
    kids = list(_children(der, cs, cs + clen))
    if not kids or kids[0][0] != 0x06:
        raise ValueError("no contentType OID")
    if _oid_str(der, kids[0][1], kids[0][2]) != OID_SIGNED_DATA:
        raise ValueError("contentType is not signedData")
    explicit = next((k for k in kids if k[0] == 0xA0), None)
    if explicit is None:
        raise ValueError("no [0] EXPLICIT content")
    sd = next(_children(der, explicit[1], explicit[2]))
    if sd[0] != 0x30:
        raise ValueError("SignedData is not a SEQUENCE")

    # SignedData ::= SEQUENCE { version, digestAlgorithms SET, encapContentInfo SEQUENCE,
    #                           certificates [0] IMPL OPT, crls [1] IMPL OPT, signerInfos SET }
    # signerInfos is the LAST element and the only universal SET after the encapContentInfo,
    # so take the final child and require it to be a SET.
    sd_kids = list(_children(der, sd[1], sd[2]))
    last = sd_kids[-1]
    if last[0] != 0x31:
        raise ValueError("last SignedData element is not the signerInfos SET")

    signers = []
    for si in _children(der, last[1], last[2]):
        if si[0] != 0x30:
            continue
        # SignerInfo ::= SEQUENCE { version INTEGER, sid IssuerAndSerialNumber, ... }
        f = list(_children(der, si[1], si[2]))
        ias = next((x for x in f if x[0] == 0x30), None)
        if ias is None:
            raise ValueError("SignerInfo carries no issuerAndSerialNumber")
        parts = list(_children(der, ias[1], ias[2]))
        issuer = next(x for x in parts if x[0] == 0x30)
        serial = next(x for x in parts if x[0] == 0x02)
        signers.append((
            der[issuer[3]:issuer[4]],                                  # issuer, full DER
            int.from_bytes(der[serial[1]:serial[2]], "big", signed=False),
        ))
    return signers


# --- payload collection -------------------------------------------------------------------------
def find(root, ext):
    out = []
    for d, _, fs in os.walk(root):
        out += [os.path.join(d, f) for f in fs if f.lower().endswith(ext)]
    return sorted(out)


def main():
    if len(sys.argv) < 2:
        print("usage: g0-catalog-gate.py <payload-dir> [--expect-min N]", file=sys.stderr)
        return 2
    payload = sys.argv[1]
    expect_min = 7
    if "--expect-min" in sys.argv:
        expect_min = int(sys.argv[sys.argv.index("--expect-min") + 1])
    if not os.path.isdir(payload):
        print(f"UNUSABLE: {payload} is not a directory", file=sys.stderr)
        return 2

    cats = [(p, os.path.relpath(p, payload)) for p in find(payload, ".cat")]
    cer_paths = find(payload, ".cer")

    tmp = tempfile.mkdtemp(prefix="g0-msi-")
    msis = find(payload, ".msi")
    for m in msis:
        d = os.path.join(tmp, os.path.basename(m) + ".x")
        os.makedirs(d, exist_ok=True)
        r = subprocess.run(["7z", "x", "-y", f"-o{d}", m],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print(f"UNUSABLE: 7z could not open {m}: {r.stderr.strip()[:200]}", file=sys.stderr)
            return 2
        # The MSI's embedded cabinet holds the driver payload; expand it too.
        for cab in find(d, ".cab"):
            cd = cab + ".x"
            os.makedirs(cd, exist_ok=True)
            subprocess.run(["7z", "x", "-y", f"-o{cd}", cab], capture_output=True, text=True)
        # MSI cabinets store payload files under GENERATED keys (`filXjulsKDudTZ38...`), with no
        # extension at all - so matching on ".cat" finds nothing inside an MSI and the gate would
        # silently grade only the three loose catalogs while reporting a clean run. Identify
        # catalogs by CONTENT instead: a .cat is a DER PKCS#7 ContentInfo whose contentType is
        # signedData. A .cer cannot be mistaken for one (it is a bare X.509 SEQUENCE, no
        # ContentInfo), so this discriminates precisely rather than heuristically.
        for p in find(d, ""):
            if os.path.basename(p).lower().endswith(".cat"):
                cats.append((p, f"{os.path.basename(m)}!{os.path.relpath(p, d)}"))
                continue
            try:
                if is_pkcs7_signed_data(open(p, "rb").read()):
                    cats.append((p, f"{os.path.basename(m)}!{os.path.relpath(p, d)}"))
            except Exception:
                pass
        cer_paths += find(d, ".cer")

    if not cats:
        print("UNUSABLE: no .cat files found in the payload or its MSI", file=sys.stderr)
        return 2

    # Index the shipped certs by (issuer DER, serial) - the identity a SignerInfo names.
    shipped = {}
    for c in sorted(set(cer_paths)):
        raw = open(c, "rb").read()
        try:
            cert = x509.load_der_x509_certificate(raw)
        except Exception:
            try:
                cert = x509.load_pem_x509_certificate(raw)
            except Exception:
                continue
        shipped[(cert.issuer.public_bytes(), cert.serial_number)] = os.path.basename(c)

    print(f"G0 catalog-signature gate")
    print(f"  payload : {payload}")
    print(f"  catalogs: {len(cats)}   shipped certs: {len(shipped)}")
    print("")

    unsigned, unknown, errors = [], [], []
    signer_names = {}
    for path, label in cats:
        try:
            sis = parse_signer_infos(open(path, "rb").read())
        except Exception as e:
            errors.append((label, str(e)))
            print(f"  ERROR    {label}: {e}")
            continue
        if not sis:
            unsigned.append(label)
            print(f"  UNSIGNED {label}   <-- signerInfos is EMPTY")
            continue
        names = []
        for ident in sis:
            who = shipped.get(ident)
            if who is None:
                unknown.append((label, ident[1]))
                names.append(f"UNKNOWN(serial={ident[1]:x})")
            else:
                names.append(who)
                signer_names.setdefault(who, []).append(label)
        print(f"  ok       {label}   signers={len(sis)} [{', '.join(names)}]")

    print("")
    print(f"  distinct signers resolving to a shipped cert: {len(signer_names)}")
    for k, v in sorted(signer_names.items()):
        print(f"    {k}: {len(v)} catalog(s)")

    fails = []
    if errors:
        fails.append(f"{len(errors)} catalog(s) could not be parsed")
    if unsigned:
        fails.append(f"{len(unsigned)} UNSIGNED catalog(s): {', '.join(unsigned)}")
    if unknown:
        fails.append(f"{len(unknown)} signer(s) not matching any shipped .cer")
    if len(cats) < expect_min:
        fails.append(f"only {len(cats)} catalogs, expected >= {expect_min}")

    print("")
    if fails:
        print("G0 FAIL: " + "; ".join(fails))
        return 1
    print(f"G0 PASS: {len(cats)} catalogs, 0 unsigned, "
          f"{len(signer_names)} signer(s), every signer matched a shipped .cer")
    return 0


if __name__ == "__main__":
    sys.exit(main())
