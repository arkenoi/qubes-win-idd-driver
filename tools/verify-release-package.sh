#!/usr/bin/env bash
# tools/verify-release-package.sh - DOES THE SHIPPED PACKAGE ACTUALLY CONTAIN OUR WORK, AT THE
# VERSION WE ARE RELEASING, BUILT FROM THE COMMIT WE ARE RELEASING?
#
# CI's ours-wins guard (packaging/check-ours-wins.ps1, at build time) proves fork binaries were
# STAGED. This proves they SURVIVED into the artefact that will be installed - a setup tree, the
# ISO, the RPM, or the assets downloaded back from a published GitHub release - and that each one
# is the binary this release built. It is the per-component verifier the release process relies
# on; tools/cut-release.sh reads its gates.jsonl (invariant 5) before it will publish anything.
#
# THE THREE THINGS IT EXISTS FOR (all from the 4.3.21 release, 2026-09-08/09):
#   1. PROVENANCE. Two packages both read package_version "4.3.21+agent.a1956929c319" and the
#      release directory was staged from the EARLIER one. package_version is <ver>+agent.<agent sha>
#      and CANNOT distinguish two packages when only the driver repo changed between them - the fix
#      was driver-repo-only, so both packages carried the same agent sha. The field that differed
#      was MANIFEST.source.driver_repo_commit (d69aff9f vs 3245867) and nothing read it. PROVENANCE
#      reads it against the commit being released (--commit) or the tag's commit (--tag).
#   2. IDENTITY + VERSION PER COMPONENT. A fork binary can be present yet be a stale build or the
#      stock fallback. Every PE in the setup tree and inside the built MSI is classified by CONTENT
#      (below), and every one we built must read FileVersion == <release_version>.<build_rev> - the
#      per-component assertion that the version stamping exists for. Stamping does NOT fix upgrades
#      (Install-QwtImproved.ps1 already passes REINSTALLMODE=amus); it makes THIS check possible.
#      Until stamping has landed, a binary without a version resource is a NAMED failure
#      (VERSION_UNSTAMPED), never a silent pass and never an approximation.
#   3. PUBLISHED BYTES. Nothing verified the assets after upload; the published v4.3.21
#      SHA256SUMS.txt covered core-agent-bins/* - 0 of the 4 assets. `--tag` downloads the release
#      back and verifies THAT, against a CLOSED asset set.
#
# IDENTITY IS BY CONTENT, NEVER BY NAME. Inside the MSI the payload lives in cab1.cab under mangled
# keys ('filvWMFu3MH4uyPi.Yw7Ef2zwbRs1Y') and the StringFileInfo of the ITL-built exes carries no
# OriginalFilename. Each PE is classified by what only a build can put there:
#   STOCK  - byte-identical to a stream of the vendored stock QWT 4.2.2 MSI (vendor/qwt-4.2.2);
#   OURS   - its embedded PDB path lies in OUR build tree (...\qubes-win-idd-driver\...), or its
#            version resource names this fork (CompanyName QWT-NG). A stock ITL binary carries ITL's
#            c:\builder\build\... path and can never contain either;
#   PVRUN  - OURS-built xenvif/xencons family under pv-drivers/ (versioned against stock, not us);
#   MS     - the two Microsoft files (devcon.exe, vc_redist.x64.exe);
#   anything else FAILS (UNCLASSIFIED_PE) - an unknown binary never ships silently.
# The PDB path replaced content-string markers after a FALSE FAIL on 2026-09-08: relocate-dir.exe
# was correctly shipped and a literal-string marker called it missing, because that literal is
# simply not in that binary. A marker that can be absent from a correctly-shipped file is not a
# marker. The PDB path is emitted by every linked binary and names the project (<stem>.pdb), so it
# also identifies WHICH claimed component a mangled payload stream is. Both encodings are searched
# everywhere a string is looked for: Win32 wide literals land in the PE as UTF-16LE, and an
# ASCII-only search reports a correctly-shipped binary as absent. --require-marker stays opt-in
# for exactly that reason: a fix-specific string is a marker for one release only.
#
# EVERY GATE CAN FAIL, AND EVERY GATE HAS A FIXTURE THAT MAKES IT FAIL (--selftest). Gates that
# could not fail were deleted in the 2026-09-09 rework, not repaired: MS_FILES (passed with n=0),
# TAR_SUMS (a tar's own sums against its own files), the xencons '> 0.0.0.0' sub-check (pre-empted
# by VERSION_UNSTAMPED), PUBLISHED_SET PASS (a file count printed after its own FAIL), PROVENANCE
# PASS in tag mode with no tag commit (no relation checked), the tag-mode "manifest is an ancestor
# of the tag" relation (the stale d69aff9f package IS an ancestor of the tag commit - it passed),
# and the invented components[] manifest schema (MANIFEST.files already records sha256 + version
# per path). A selftest case whose code ALREADY fires on the unmutated fixture proves nothing and
# is reported NOT PROVEN with a non-zero exit - never PASS with a note.
#
# Every gate prints exactly one machine-readable line -
#     GATE <name> PASS [k=v ...]        GATE <name> FAIL code=<CODE> [k=v ...]
# - and is appended to gates.jsonl in the work dir (gitignored scratchpad, never a tracked path).
# The last line of gates.jsonl is a {"result": ...} record (manifest commit, want version, iso
# sha256) for cut-release.sh. Before RESULT the REQUIRED gate-name set for the mode is asserted
# present (GATES / GATES_INCOMPLETE) and the analyser's exit status is a gate (ANALYSER /
# ANALYSER_CRASHED): a crash that drops gates is a FAIL, never a shorter green run. Missing data
# FAILS: an absent field, an unreadable PE, an unresolvable commit, a failed gh/xorriso call are
# FAIL codes, never warnings.
#
# Usage:
#   tools/verify-release-package.sh --tree   <setup-tree-dir|setup.tar.gz> [common]
#   tools/verify-release-package.sh --iso    <qwt-*.iso>                   [common]
#   tools/verify-release-package.sh --assets <release-assets-dir>          [common]
#   tools/verify-release-package.sh --tag    <vX.Y.Z-agentSHA7>            [common]   (gh download)
#   tools/verify-release-package.sh --selftest [--selftest-tree <setup-tree-dir>]
#                                              [--selftest-assets <closed-set-assets-dir>]
#       (level 3 proves RPM_ISO_MISMATCH only with SELFTEST_OTHER_ISO=<a different qwt iso> set;
#        without it that case is reported NOT PROVEN, never skipped silently)
# common:
#   --commit <sha-ish>      the commit being released (default: HEAD, except in --tag mode where the
#                           tag's own commit is the expectation; with both, both must match)
#   --release <X.Y.Z>       release version (default: MANIFEST.release_version; FAIL if neither)
#   --build-rev <n>         4th FILEVERSION field, 0..65535 (default: MANIFEST.build_rev; FAIL if neither)
#   --run <id>              the release-package run that built it (MANIFEST.ci.run_id + gh run view)
#   --require-marker L=STR  additionally require a fork-only string STR (label L) somewhere in the
#                           MSI payload or tree binaries, both encodings (opt-in, see above)
#   --legacy-manifest       accept a MANIFEST without release_version/build_rev/core_agent_commit
#                           (release = package_version prefix, build_rev = 0, core-agent provenance
#                           SKIPped, ISO-artifact manifest with an `iso` block accepted). It never
#                           hides a version, identity or provenance failure: a legacy package can be
#                           verified for provenance and identity but can never PASS the version
#                           gates. Dies with the first stamped package.
#   --work <dir>            work/evidence dir (default scratchpad/release/verify-<utc>) - real disk,
#                           never /tmp (a 1 GB tmpfs here)
#   --keep                  keep the extracted trees in the work dir (default: keep gates.jsonl,
#                           universe.json and the analyser output only)
#
# Bash rules (each cost a real result once): set -uo pipefail with NO `grep -q` inside a pipeline -
# grep -q exits on the first match and closes the pipe, the producer dies of SIGPIPE, pipefail turns
# a MATCH into NO MATCH (measured 2026-09-08: rc=141 with -q, rc=0 without, same file, same marker);
# `grep -aF ... >/dev/null` consumes its input and the pipeline exits on grep's status. Producer
# output is captured into a variable/file FIRST and tested afterwards. Nothing that emits a GATE
# line runs inside $( ). Logs go to stderr so no capture is contaminated. Every extraction target
# is rm_rf'd before use so a glob can never pick up a stale directory from a previous run.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STOCK_MSI="$REPO/vendor/qwt-4.2.2/installer.msi"
RELEASE_WORKFLOW_NAME="release-package"
MAX16=65535

# ------------------------------------------------------------------------------ arguments
MODE=""; TARGET=""
OPT_COMMIT=""; OPT_RELEASE=""; OPT_BUILD_REV=""; OPT_RUN=""; OPT_LEGACY=0; OPT_WORK=""; OPT_KEEP=0
OPT_SELFTEST_TREE=""; OPT_SELFTEST_ASSETS=""
MARKERS=()
usage() {
  awk 'NR > 1 && !/^#/ {exit} NR > 1 {sub(/^# ?/, ""); print}' "${BASH_SOURCE[0]}" >&2
  exit 2
}
bad_input() { echo "verify-release-package: BAD_INPUT: $*" >&2; exit 2; }
setmode() { [ -z "$MODE" ] || bad_input "only one of --tree/--iso/--assets/--tag/--selftest"; MODE="$1"; TARGET="${2:-}"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --tree)     [ $# -ge 2 ] || usage; setmode tree "$2"; shift 2 ;;
    --iso)      [ $# -ge 2 ] || usage; setmode iso "$2"; shift 2 ;;
    --assets)   [ $# -ge 2 ] || usage; setmode assets "$2"; shift 2 ;;
    --tag)      [ $# -ge 2 ] || usage; setmode tag "$2"; shift 2 ;;
    --selftest) setmode selftest; shift ;;
    --selftest-tree)   [ $# -ge 2 ] || usage; OPT_SELFTEST_TREE="$2"; shift 2 ;;
    --selftest-assets) [ $# -ge 2 ] || usage; OPT_SELFTEST_ASSETS="$2"; shift 2 ;;
    --commit)   [ $# -ge 2 ] || usage; OPT_COMMIT="$2"; shift 2 ;;
    --release)  [ $# -ge 2 ] || usage; OPT_RELEASE="$2"; shift 2 ;;
    --build-rev) [ $# -ge 2 ] || usage; OPT_BUILD_REV="$2"; shift 2 ;;
    --run)      [ $# -ge 2 ] || usage; OPT_RUN="$2"; shift 2 ;;
    --require-marker) [ $# -ge 2 ] || usage; MARKERS+=("$2"); shift 2 ;;
    --legacy-manifest) OPT_LEGACY=1; shift ;;
    --work)     [ $# -ge 2 ] || usage; OPT_WORK="$2"; shift 2 ;;
    --keep)     OPT_KEEP=1; shift ;;
    -h|--help)  usage ;;
    *) echo "verify-release-package: unknown argument '$1'" >&2; usage ;;
  esac
done
[ -n "$MODE" ] || usage
# VERSIONINFO fields are 16-bit: rc.exe silently truncates larger ones into a wrong-but-valid-
# looking number, and the version gates would then blame the binaries for the operator's input.
if [ -n "$OPT_RELEASE" ]; then
  [[ "$OPT_RELEASE" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || bad_input "--release must be MAJOR.MINOR.PATCH without leading zeros, got '$OPT_RELEASE'"
  for f in ${OPT_RELEASE//./ }; do [ "$f" -le $MAX16 ] || bad_input "--release field $f exceeds $MAX16 (16-bit VERSIONINFO field)"; done
fi
if [ -n "$OPT_BUILD_REV" ]; then
  [[ "$OPT_BUILD_REV" =~ ^(0|[1-9][0-9]*)$ ]] || bad_input "--build-rev must be an integer without leading zeros, got '$OPT_BUILD_REV'"
  [ "$OPT_BUILD_REV" -le $MAX16 ] || bad_input "--build-rev $OPT_BUILD_REV exceeds $MAX16 (16-bit VERSIONINFO field)"
fi
if [ -n "$OPT_RUN" ] && ! [[ "$OPT_RUN" =~ ^[0-9]+$ ]]; then bad_input "--run must be a numeric run id, got '$OPT_RUN'"; fi
for mk in "${MARKERS[@]}"; do
  [[ "$mk" =~ ^[A-Za-z0-9_-]+=.+$ ]] || bad_input "--require-marker must be LABEL=STRING, got '$mk'"
done

# ------------------------------------------------------------------------------ work dir / logging
if [ -z "$OPT_WORK" ]; then
  OPT_WORK="$REPO/scratchpad/release/verify-$(date -u +%Y%m%dT%H%M%SZ)-$$"
fi
WORK="$(realpath -m -- "$OPT_WORK")"
# Everything written here is per-run evidence and MUST stay out of the public repo. Checked on the
# path string BEFORE anything is created, so a refused path is never materialised.
case "$WORK" in
  "$REPO"/*)
    if ! git -C "$REPO" check-ignore -q -- "$WORK"; then
      echo "verify-release-package: $WORK is inside the repo and NOT gitignored - refusing to write evidence into a tracked path" >&2
      exit 2
    fi ;;
esac
mkdir -p "$WORK" || { echo "verify-release-package: cannot create work dir $WORK" >&2; exit 2; }
GATES="$WORK/gates.jsonl"
: > "$GATES"
log()  { printf '%s verify: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

# gate_record NAME PASS|FAIL|SKIP CODE k=v ...   (prints the GATE line and appends jsonl)
gate_record() {
  local name="$1" outcome="$2" code="$3"; shift 3
  local line="GATE $name $outcome"
  [ -n "$code" ] && line="$line code=$code"
  [ $# -gt 0 ] && line="$line $*"
  echo "$line"
  python3 - "$name" "$outcome" "$code" "$MODE" "$@" <<'PY' >> "$GATES"
import json, sys, time
name, outcome, code, mode, *kv = sys.argv[1:]
rec = {"utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "mode": mode,
       "gate": name, "outcome": outcome}
if code:
    rec["code"] = code
for item in kv:
    k, _, v = item.partition("=")
    if k:
        rec.setdefault("detail", {})[k] = v
print(json.dumps(rec, sort_keys=True))
PY
  return 0
}
gate_pass() { gate_record "$1" PASS "" "${@:2}"; }
gate_fail() { gate_record "$1" FAIL "$2" "${@:3}"; }
gate_skip() { gate_record "$1" SKIP "$2" "${@:3}"; }
# The Python analyser prints GATE lines into a file; this re-emits them through gate_record so the
# jsonl sees them too. Reads a FILE, never a pipe: the analyser's exit status is checked first.
relay_gates() { # $1=file
  local line name outcome first rest code
  while IFS= read -r line; do
    case "$line" in
      "GATE "*)
        read -r _ name outcome first rest <<< "$line"
        code=""
        if [[ "${first:-}" == code=* ]]; then
          code="${first#code=}"
        elif [ -n "${first:-}" ]; then
          rest="$first${rest:+ $rest}"
        fi
        # shellcheck disable=SC2086
        gate_record "$name" "$outcome" "$code" ${rest:-} ;;
      *) echo "$line" ;;
    esac
  done < "$1"
}
gate_seen() { grep -F -- "\"gate\": \"$1\"" "$GATES" >/dev/null; }

sha256_of() { sha256sum "$1" | cut -d' ' -f1; }

# xorriso materialises ISO 9660 directories read-only (0555); a plain rm -rf then fails on every
# file inside and a re-run into the same work dir dies at extraction. Always re-own before removing.
rm_rf() {
  local d
  for d in "$@"; do
    [ -e "$d" ] || continue
    chmod -R u+rwX "$d" 2>/dev/null || true
    rm -rf "$d"
  done
}

need_tools() {
  local t missing=""
  for t in "$@"; do command -v "$t" >/dev/null 2>&1 || missing="$missing $t"; done
  if [ -n "$missing" ]; then gate_fail PREREQ PREREQ_MISSING "tools=${missing# }"; return 1; fi
  return 0
}

# gh is anchored to THIS repository, never to the caller's cwd.
GH_SLUG=""
gh_slug() {
  [ -n "$GH_SLUG" ] && return 0
  local url
  url="$(git -C "$REPO" remote get-url origin 2>/dev/null)" || url=""
  if [[ "$url" =~ github\.com[:/]([^/]+)/([^/]+)/?$ ]]; then
    local repo="${BASH_REMATCH[2]}"
    repo="${repo%.git}"
    GH_SLUG="${BASH_REMATCH[1]}/$repo"; return 0
  fi
  return 1
}

# ------------------------------------------------------------------------------ extraction helpers
# MSI -> payload directory. The MSI stores its payload as OLE streams; 7z lists them under their
# mangled File-table keys; if the payload is a cab (WiX default: cab1.cab embedded), expand it in
# place. There is nothing to match on but content afterwards.
extract_msi() { # $1=msi $2=outdir ; prints file count; returns 1 on extraction failure
  local msi="$1" out="$2" c
  rm_rf "$out"; mkdir -p "$out"
  7z x -y -o"$out" "$msi" >/dev/null 2>&1 || return 1
  while IFS= read -r c; do
    cabextract -q -d "$out" "$c" >/dev/null 2>&1 || return 1
    rm -f "$c"
  done < <(find "$out" -type f -iname '*.cab')
  find "$out" -type f | wc -l
}
extract_iso() { # $1=iso $2=outdir
  local iso="$1" out="$2"
  rm_rf "$out"; mkdir -p "$out"
  xorriso -osirrox on -indev "$iso" -extract / "$out" >/dev/null 2>&1
}

# ------------------------------------------------------------------------------ stock image
STOCK_DIR="$WORK/stock-payload"
prepare_stock() {
  if [ ! -s "$STOCK_MSI" ]; then
    gate_fail STOCK_IMAGE STOCK_IMAGE_MISSING "path=vendor/qwt-4.2.2/installer.msi"; return 1
  fi
  local n
  n="$(extract_msi "$STOCK_MSI" "$STOCK_DIR")" || { gate_fail STOCK_IMAGE STOCK_EXTRACT_FAILED "msi=$STOCK_MSI"; return 1; }
  [ "${n:-0}" -gt 0 ] || { gate_fail STOCK_IMAGE STOCK_EXTRACT_FAILED "msi=$STOCK_MSI files=0"; return 1; }
  gate_pass STOCK_IMAGE "files=$n"
}

# ------------------------------------------------------------------------------ the PE reader
# Shared by the analyser, the selftest and the selftest's fixture mutators (exec'd out of this
# file's text between the two marker lines). Pure stdlib: walks the PE resource tree itself.
# ---- PE READER BEGIN
PE_READER='
import struct

def is_pe(data):
    if len(data) < 0x40 or data[:2] != b"MZ":
        return False
    off = struct.unpack_from("<I", data, 0x3C)[0]
    return off + 4 <= len(data) and data[off:off + 4] == b"PE\0\0"

# Returns (status, "a.b.c.d" | None, strings{}, fixed_off | None).
# status: OK | NO_VERSION | CORRUPT. fixed_off is the FILE offset of VS_FIXEDFILEINFO (the
# selftest patches dwFileVersionMS/LS there to build "wrong version" fixtures from real binaries).
def pe_fileversion(data):
    try:
        e_lfanew = struct.unpack_from("<I", data, 0x3C)[0]
        coff = e_lfanew + 4
        nsec = struct.unpack_from("<H", data, coff + 2)[0]
        optsz = struct.unpack_from("<H", data, coff + 16)[0]
        opt = coff + 20
        magic = struct.unpack_from("<H", data, opt)[0]
        if magic == 0x20B:
            ndd_off, dd_off = opt + 108, opt + 112
        elif magic == 0x10B:
            ndd_off, dd_off = opt + 92, opt + 96
        else:
            return ("CORRUPT", None, {}, None)
        ndd = struct.unpack_from("<I", data, ndd_off)[0]
        if ndd < 3:
            return ("NO_VERSION", None, {}, None)
        rsrc_rva, rsrc_size = struct.unpack_from("<II", data, dd_off + 2 * 8)
        if rsrc_rva == 0 or rsrc_size == 0:
            return ("NO_VERSION", None, {}, None)
        secs = []
        so = opt + optsz
        for i in range(nsec):
            vsize, va, rawsz, rawp = struct.unpack_from("<IIII", data, so + i * 40 + 8)
            secs.append((va, max(vsize, rawsz), rawp, rawsz))

        def rva2off(rva):
            for va, vs, rp, rs in secs:
                if va <= rva < va + vs:
                    o = rva - va
                    return None if o >= rs else rp + o
            return None

        base = rva2off(rsrc_rva)
        if base is None:
            return ("CORRUPT", None, {}, None)

        def read_dir(off):
            if off + 16 > len(data):
                raise ValueError
            nn, ni = struct.unpack_from("<HH", data, off + 12)
            return [struct.unpack_from("<II", data, off + 16 + i * 8) for i in range(nn + ni)]

        RT_VERSION = 16
        vdir = None
        for name, dat in read_dir(base):
            if not (name & 0x80000000) and name == RT_VERSION and (dat & 0x80000000):
                vdir = base + (dat & 0x7FFFFFFF)
        if vdir is None:
            return ("NO_VERSION", None, {}, None)
        leaf = None
        for name, dat in read_dir(vdir):
            if dat & 0x80000000:
                for n2, d2 in read_dir(base + (dat & 0x7FFFFFFF)):
                    if not (d2 & 0x80000000):
                        leaf = base + d2
                        break
            else:
                leaf = base + dat
            if leaf is not None:
                break
        if leaf is None:
            return ("NO_VERSION", None, {}, None)
        data_rva, data_size = struct.unpack_from("<II", data, leaf)
        voff = rva2off(data_rva)
        if voff is None or voff + data_size > len(data):
            return ("CORRUPT", None, {}, None)
        blob = data[voff:voff + data_size]
        wlen, vlen, wtype = struct.unpack_from("<HHH", blob, 0)
        key = "VS_VERSION_INFO".encode("utf-16le") + b"\0\0"
        if blob[6:6 + len(key)] != key:
            return ("CORRUPT", None, {}, None)
        p = (6 + len(key) + 3) & ~3
        if vlen < 52 or p + 52 > len(blob):
            return ("CORRUPT", None, {}, None)
        if struct.unpack_from("<I", blob, p)[0] != 0xFEEF04BD:
            return ("CORRUPT", None, {}, None)
        fvms, fvls = struct.unpack_from("<II", blob, p + 8)
        ver = "%d.%d.%d.%d" % (fvms >> 16, fvms & 0xFFFF, fvls >> 16, fvls & 0xFFFF)
        fixed_off = voff + p
    except (struct.error, ValueError, IndexError):
        return ("CORRUPT", None, {}, None)
    # StringFileInfo - reporting + the CompanyName fork attribution; never a version source
    strings = {}
    try:
        def rd_block(off):
            l, vl, t = struct.unpack_from("<HHH", blob, off)
            k_end = blob.find(b"\0\0", off + 6)
            while k_end != -1 and (k_end - (off + 6)) % 2:
                k_end = blob.find(b"\0\0", k_end + 1)
            k = blob[off + 6:k_end].decode("utf-16le", "replace") if k_end != -1 else ""
            body = ((k_end + 2) + 3) & ~3 if k_end != -1 else off + l
            return l, vl, t, k, body
        q = (p + vlen + 3) & ~3
        end = min(wlen, len(blob))
        while q + 6 <= end:
            l, vl, t, k, body = rd_block(q)
            if l == 0:
                break
            if k == "StringFileInfo":
                r = body
                while r + 6 <= q + l:
                    l2, vl2, t2, k2, b2 = rd_block(r)
                    if l2 == 0:
                        break
                    s = b2
                    while s + 6 <= r + l2:
                        l3, vl3, t3, k3, b3 = rd_block(s)
                        if l3 == 0:
                            break
                        val = blob[b3:b3 + vl3 * 2].decode("utf-16le", "replace").split("\0")[0]
                        strings[k3] = val
                        s = (s + l3 + 3) & ~3
                    r = (r + l2 + 3) & ~3
            q = (q + l + 3) & ~3
    except (struct.error, ValueError, IndexError):
        pass
    return ("OK", ver, strings, fixed_off)

# Patch the fixed FileVersion of a PE in place (bytes -> bytes). Used only by selftest fixtures.
def pe_set_fileversion(data, ver):
    st, _, _, off = pe_fileversion(data)
    if st != "OK":
        raise ValueError("no VS_FIXEDFILEINFO to patch: " + st)
    a, b, c, d = (int(x) for x in ver.split("."))
    out = bytearray(data)
    struct.pack_into("<II", out, off + 8, (a << 16) | b, (c << 16) | d)
    return bytes(out)
'
# ---- PE READER END
export PE_READER

# ------------------------------------------------------------------------------ the analyser
# One Python pass over the derived universe U = every PE in the setup tree + every PE in the built
# MSI's payload. It classifies, versions, resolves the ours-wins claims, checks the drivers, cross-
# checks MANIFEST.files and prints GATE lines. Its exit status and the completeness of what it
# printed are gates of their own (ANALYSER, GATES) on the bash side.
# VERIFY_INJECT_FAULT=crash|omit-gate is the selftest's fault injection for those two gates: the
# only way to prove a "the tool itself broke" detector is to break the tool on purpose.
analyse() { # $1=tree $2=payload $3=stock $4=want-version $5=manifest $6=claims-file $7=legacy(0/1)
  python3 - "$@" <<'PY'
import hashlib, json, os, re, struct, sys

exec(os.environ["PE_READER"])
tree, payload, stock, want, manifest_path, claims_path, legacy = sys.argv[1:8]
legacy = legacy == "1"
inject = os.environ.get("VERIFY_INJECT_FAULT", "")

def gate(name, outcome, code="", **kv):
    if inject == "omit-gate" and name == "MANIFEST_FILES":
        return
    s = f"GATE {name} {outcome}"
    if code:
        s += f" code={code}"
    for k, v in kv.items():
        s += f" {k}={str(v).replace(' ', '_')}"
    print(s)

def note(s):
    print("  " + s)

def sha256(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for ch in iter(lambda: f.read(1 << 20), b""):
            h.update(ch)
    return h.hexdigest()

# ---- identity: embedded PDB paths, both encodings ---------------------------------------------
PDB_RE_A = re.compile(rb"[A-Za-z]:\\[^\x00-\x1f]{1,400}?\.pdb", re.IGNORECASE)
PDB_RE_T = re.compile(r"[A-Za-z]:\\[^\x00-\x1f]{1,400}?\.pdb", re.IGNORECASE)

def pdb_paths(data):
    found = [m.group(0).decode("latin-1") for m in PDB_RE_A.finditer(data)]
    # UTF-16LE: decode the whole buffer at both alignments and regex the text; non-text bytes
    # decode to garbage the regex ignores.
    for off in (0, 1):
        try:
            txt = data[off:].decode("utf-16le", "ignore")
        except Exception:
            continue
        found.extend(m.group(0) for m in PDB_RE_T.finditer(txt))
    return found

def pe_size_of_code(data):
    try:
        pe = int.from_bytes(data[0x3c:0x40], "little")
        return int.from_bytes(data[pe + 24 + 4:pe + 24 + 8], "little")
    except Exception:
        return -1

def sibling_sys_version(p):
    """FileVersion of an OURS-built .sys in the same directory (PDB path names this repo), else None."""
    d = os.path.dirname(p)
    for f in sorted(os.listdir(d)):
        if not f.lower().endswith(".sys"):
            continue
        with open(os.path.join(d, f), "rb") as fh:
            b = fh.read()
        if not is_pe(b):
            continue
        o, _ = classify_pdb(pdb_paths(b))
        st2, v2, _, _ = pe_fileversion(b)
        if o and st2 == "OK":
            return v2
    return None

def classify_pdb(paths):
    ours = [p for p in paths if "\\qubes-win-idd-driver\\" in p.lower()]
    stockp = [p for p in paths if ":\\builder\\build\\" in p.lower()]
    return ours, stockp

def stem_of(pdb):
    return os.path.basename(pdb.replace("/", "\\").split("\\")[-1]).lower()[:-4]

# ---- enumerate the stock payload (identity by bytes) -----------------------------------------
stock_sha = {}
stock_by_stem = {}
for d, _, fs in os.walk(stock):
    for f in fs:
        p = os.path.join(d, f)
        with open(p, "rb") as fh:
            data = fh.read()
        if not is_pe(data):
            continue
        stock_sha[sha256(p)] = p
        st, ver, strs, _ = pe_fileversion(data)
        for pdb in pdb_paths(data):
            stock_by_stem.setdefault(stem_of(pdb), []).append((p, ver, strs))
        ofn = (strs.get("OriginalFilename") or "").lower()
        if ofn:
            stock_by_stem.setdefault(os.path.splitext(ofn)[0], []).append((p, ver, strs))

# ---- enumerate the universe U = tree PEs + built-MSI payload PEs -----------------------------
MS_FILES = {"devcon.exe", "vc_redist.x64.exe"}
universe = []   # dicts: rel, channel, path, sha, cls, ver, vstatus, stems, strings
tree_files = {}  # rel -> path, every regular file in the tree (for MANIFEST_FILES)

def rel_of(root, p):
    return os.path.relpath(p, root).replace("\\", "/")

def add_pe(root, p, channel):
    with open(p, "rb") as fh:
        data = fh.read()
    if not is_pe(data):
        return
    rel = rel_of(root, p)
    sha = sha256(p)
    st, ver, strs, _ = pe_fileversion(data)
    pdbs = pdb_paths(data)
    ours, stockp = classify_pdb(pdbs)
    stems = sorted({stem_of(x) for x in pdbs})
    base = os.path.basename(p).lower()
    # second OURS signal: the shared version resource (packaging/version-stamp/qwtng_version.rc)
    # names this fork in CompanyName - the only attribution a binary linked without a PDB path has
    company = (strs.get("CompanyName") or "").lower()
    # A RESOURCE-ONLY PE (SizeOfCode == 0: an event-message DLL such as xenbus_monitor.dll) is
    # linked without code and therefore without a PDB path, so it carries neither identity
    # signal. It is attributed through the driver it ships WITH: same directory, a .sys whose
    # FileVersion is OURS-stamped, and an identical FileVersion of its own. Anything else under
    # pv-drivers/ stays UNKNOWN and fails the universe gate as before.
    if sha in stock_sha:
        cls = "STOCK"
    elif ours or "qwt-ng" in company:
        cls = "PVRUN" if (channel == "tree" and rel.lower().startswith("pv-drivers/")) else "OURS"
    elif (channel == "tree" and rel.lower().startswith("pv-drivers/") and not pdbs
          and pe_size_of_code(data) == 0 and st == "OK" and sibling_sys_version(p) == ver):
        cls = "PVRUN"
    elif channel == "tree" and base in MS_FILES:
        cls = "MS"
    elif stockp:
        cls = "STOCKBUILT"   # ITL build tree, but bytes differ from the vendored stock image
    else:
        cls = "UNKNOWN"
    universe.append(dict(rel=rel, channel=channel, path=p, sha=sha, cls=cls, ver=ver,
                         vstatus=st, stems=stems, strings=strs, base=base))

for d, _, fs in os.walk(tree):
    for f in fs:
        p = os.path.join(d, f)
        tree_files[rel_of(tree, p)] = p
        add_pe(tree, p, "tree")
if payload and os.path.isdir(payload):
    for d, _, fs in os.walk(payload):
        for f in fs:
            add_pe(payload, os.path.join(d, f), "msi")

counts = {}
for u in universe:
    counts[u["cls"]] = counts.get(u["cls"], 0) + 1
note("universe: " + ", ".join(f"{k}={v}" for k, v in sorted(counts.items())) + f" (total {len(universe)} PEs)")

# ---- PE_UNIVERSE: nothing unclassified ships ---------------------------------------------------
bad = [u for u in universe if u["cls"] in ("UNKNOWN", "STOCKBUILT")]
tree_stock = [u for u in universe if u["cls"] == "STOCK" and u["channel"] == "tree"]
if bad:
    for u in bad:
        note(f"UNCLASSIFIED {u['channel']}:{u['rel']} pdb={','.join(u['stems']) or '-'} ver={u['ver']}")
    u = bad[0]
    gate("PE_UNIVERSE", "FAIL", "UNCLASSIFIED_PE", path=f"{u['channel']}:{u['rel']}", n=len(bad))
elif tree_stock:
    # A stock ITL binary loose in the overlay tree: the guest would receive stock bytes through a
    # channel that exists only to deliver ours.
    for u in tree_stock:
        note(f"STOCK-IN-TREE {u['rel']}")
    gate("PE_UNIVERSE", "FAIL", "UNEXPECTED_STOCK_PE", path=tree_stock[0]["rel"], n=len(tree_stock))
else:
    gate("PE_UNIVERSE", "PASS", **{k.lower(): v for k, v in counts.items()})

if inject == "crash":
    raise RuntimeError("VERIFY_INJECT_FAULT=crash: deliberate analyser crash (selftest fixture)")

# ---- CLAIMED_IS_OURS: every ours-wins Binaries path resolves to an OURS PE ---------------------
claims = []
if claims_path and os.path.isfile(claims_path):
    txt = open(claims_path, encoding="utf-8", errors="replace").read()
    body = "\n".join(l.split("#", 1)[0] for l in txt.splitlines())
    bstart = body.find("Binaries")
    bend = body.find("DeadEnds", bstart) if bstart != -1 else -1
    seg = body[bstart:bend if bend != -1 else None] if bstart != -1 else ""
    claims = re.findall(r"Package\s*=\s*'([^']+)'", seg)
if not claims:
    gate("CLAIMED_IS_OURS", "FAIL", "OURSWINS_UNREADABLE", file=claims_path or "-")
else:
    problems = []
    resolved = 0
    for c in claims:
        base = os.path.basename(c).lower()
        stem, ext = os.path.splitext(base)
        if ext not in (".exe", ".dll", ".sys"):
            continue
        if c.startswith("msi-image/"):
            hits = [u for u in universe if u["channel"] == "msi" and stem in u["stems"]]
            ours = [u for u in hits if u["cls"] == "OURS"]
            if ours:
                resolved += 1
                continue
            if hits or stem in stock_by_stem:
                problems.append(("STOCK_FALLBACK", c))   # the only build of this component in the MSI is stock
            else:
                problems.append(("CLAIMED_MISSING", c))
        else:
            p = os.path.join(tree, *c.split("/"))
            hit = [u for u in universe if u["channel"] == "tree" and u["path"] == p]
            if not hit or not os.path.isfile(p):
                problems.append(("CLAIMED_MISSING", c))
            elif hit[0]["cls"] != "OURS":
                problems.append(("STOCK_FALLBACK", c))
            else:
                resolved += 1
    if problems:
        for code, c in problems:
            note(f"{code} {c}")
        gate("CLAIMED_IS_OURS", "FAIL", problems[0][0], path=problems[0][1], n=len(problems), resolved=resolved)
    else:
        gate("CLAIMED_IS_OURS", "PASS", claims=resolved)

# ---- OURS_STAMPED / OURS_VERSION: every OURS PE carries a VERSIONINFO and reads want ------------
ours = [u for u in universe if u["cls"] == "OURS"]
if not ours:
    gate("OURS_STAMPED", "FAIL", "NO_OURS_PE", hint="no_PE_in_the_package_was_built_in_our_tree")
    gate("OURS_VERSION", "FAIL", "NO_OURS_PE", want=want)
else:
    unst = [u for u in ours if u["vstatus"] != "OK"]
    mism = [u for u in ours if u["vstatus"] == "OK" and u["ver"] != want]
    for u in ours:
        tag = "ok" if (u["vstatus"] == "OK" and u["ver"] == want) else ("UNSTAMPED" if u["vstatus"] != "OK" else "MISMATCH")
        note(f"{tag:9} {u['channel']}:{u['rel']:48} ver={u['ver']} pdb={','.join(u['stems']) or '-'}")
    # Two gates, two codes, so each is provable on its own: a package with one unstamped helper
    # must still be able to show that every STAMPED binary carries the wrong number.
    if unst:
        gate("OURS_STAMPED", "FAIL", "VERSION_UNSTAMPED", path=f"{unst[0]['channel']}:{unst[0]['rel']}",
             status=unst[0]["vstatus"], unstamped=len(unst), ours=len(ours))
    else:
        gate("OURS_STAMPED", "PASS", ours=len(ours))
    if mism:
        gate("OURS_VERSION", "FAIL", "OURS_VERSION_MISMATCH", path=f"{mism[0]['channel']}:{mism[0]['rel']}",
             got=mism[0]["ver"], want=want, mismatched=len(mism), stamped=len(ours) - len(unst))
    elif len(ours) - len(unst) == 0:
        gate("OURS_VERSION", "FAIL", "NO_STAMPED_PE", want=want)
    else:
        gate("OURS_VERSION", "PASS", stamped=len(ours) - len(unst), want=want)

# ---- INF DriverVer -----------------------------------------------------------------------------
def inf_driverver(path):
    with open(path, "rb") as fh:
        raw = fh.read()
    if raw[:2] == b"\xff\xfe":
        txt = raw[2:].decode("utf-16le", "replace")
    elif raw[:3] == b"\xef\xbb\xbf":
        txt = raw[3:].decode("utf-8", "replace")
    else:
        txt = raw.decode("utf-8", "replace")
    return re.findall(r"^\s*DriverVer\s*=\s*([0-9]{2}/[0-9]{2}/[0-9]{4})\s*,\s*([0-9]+(?:\.[0-9]+){3})\s*$", txt, re.I | re.M)

def vtuple(v):
    return tuple(int(x) for x in v.split("."))

def find_tree(rel):
    for u in universe:
        if u["channel"] == "tree" and u["rel"].lower() == rel.lower():
            return u
    return None

# ---- IDD_VERSION: the IddCx driver is ours, carries the release version, INF agrees ------------
idd_dll = find_tree("idd-driver/IddSampleDriver.dll")
idd_inf = os.path.join(tree, "idd-driver", "IddSampleDriver.inf")
if not idd_dll or not os.path.isfile(idd_inf):
    gate("IDD_VERSION", "FAIL", "IDD_MISSING", dll=bool(idd_dll), inf=os.path.isfile(idd_inf))
else:
    u = idd_dll
    dv = inf_driverver(idd_inf)
    if u["cls"] != "OURS":
        gate("IDD_VERSION", "FAIL", "IDD_NOT_OURS", cls=u["cls"])
    elif u["vstatus"] != "OK":
        gate("IDD_VERSION", "FAIL", "VERSION_UNSTAMPED", path=u["rel"], status=u["vstatus"])
    elif len(dv) != 1:
        gate("IDD_VERSION", "FAIL", "IDD_INF_DRIVERVER_COUNT", count=len(dv))
    elif dv[0][1] != u["ver"]:
        # INF and DLL disagree: activate-idd's bound-DriverVer == INF assertion would then prove
        # nothing about the DLL (the epoch-minute stamper produced exactly this, one minute apart)
        gate("IDD_VERSION", "FAIL", "IDD_INF_MISMATCH", inf=dv[0][1], dll=u["ver"], want=want)
    elif u["ver"] != want:
        gate("IDD_VERSION", "FAIL", "IDD_VERSION_MISMATCH", got=u["ver"], want=want, inf=dv[0][1])
    else:
        gate("IDD_VERSION", "PASS", version=want, inf_date=dv[0][0])

# ---- PV_VERSION: xenvif/xencons are OURS-built, INF == .sys, exes == xencons.sys, xenvif > stock -
# The PV drivers are versioned against the STOCK driver, not against the release: xenvif must be
# strictly above the xenvif in vendor/qwt-4.2.2, xencons has no stock counterpart and is checked
# for identity (PVRUN, stamped, INF == .sys, monitor/tty == .sys) only. Once pv-xenvif/pv-xencons
# take build_rev, add: 4th field == build_rev. Nothing weaker is asserted about xencons' number -
# a '> 0.0.0.0' check was deleted because VERSION_UNSTAMPED pre-empts the only case it could catch.
pv_problem = None
pv_detail = {}
xenvif = find_tree("pv-drivers/xenvif.sys")
xencons = find_tree("pv-drivers/xencons.sys")
if not xenvif or not xencons:
    pv_problem = ("PV_MISSING", dict(xenvif=bool(xenvif), xencons=bool(xencons)))
else:
    stock_vif = stock_by_stem.get("xenvif", [])
    stock_vif_ver = next((v for _, v, _ in stock_vif if v), None)
    if stock_vif_ver is None:
        pv_problem = ("STOCK_DRIVERVER_UNREADABLE", dict(driver="xenvif.sys"))
    for name, u in (("xenvif", xenvif), ("xencons", xencons)):
        if pv_problem:
            break
        if u["cls"] != "PVRUN":
            pv_problem = ("PV_NOT_OURS", dict(driver=name, cls=u["cls"])); break
        if u["vstatus"] != "OK":
            pv_problem = ("VERSION_UNSTAMPED", dict(path=u["rel"])); break
        inf = os.path.join(tree, "pv-drivers", f"{name}.inf")
        if not os.path.isfile(inf):
            pv_problem = ("PV_MISSING", dict(inf=f"{name}.inf")); break
        dv = inf_driverver(inf)
        if len(dv) != 1:
            pv_problem = ("PV_INF_DRIVERVER_COUNT", dict(inf=f"{name}.inf", count=len(dv))); break
        pv_detail[name] = u["ver"]
        if dv[0][1] != u["ver"]:
            pv_problem = ("PV_INF_SYS_DRIVERVER_DISAGREE", dict(driver=name, inf=dv[0][1], sys=u["ver"])); break
        if name == "xenvif":
            if not vtuple(u["ver"]) > vtuple(stock_vif_ver):
                pv_problem = ("PV_DRIVERVER_NOT_ABOVE_STOCK", dict(driver=name, got=u["ver"], stock=stock_vif_ver)); break
            pv_detail["stock_xenvif"] = stock_vif_ver
        else:
            for exe in ("xencons_monitor.exe", "xencons_tty.exe"):
                e = find_tree(f"pv-drivers/{exe}")
                if not e:
                    pv_problem = ("PV_MISSING", dict(exe=exe)); break
                if e["cls"] != "PVRUN" or e["vstatus"] != "OK" or e["ver"] != u["ver"]:
                    pv_problem = ("PV_EXE_SYS_DISAGREE", dict(exe=exe, got=e["ver"], sys=u["ver"], cls=e["cls"])); break
# xenbus (pv-drivers/xenbus/): OURS-built at the commit Qubes pins plus the bucket-lock fix, so
# it is versioned against the STOCK xenbus exactly like xenvif: strictly above it, INF == .sys,
# and every file the INF copies (xen.sys, xenfilt.sys, monitor exe + message dll) == xenbus.sys.
# Optional in the sense that a package without pv-drivers/xenbus is the pre-fix status quo;
# a package WITH a half-set fails here rather than shipping a driver whose INF cannot install.
xenbus = find_tree("pv-drivers/xenbus/xenbus.sys")
if not pv_problem and xenbus:
    stock_bus_ver = next((v for _, v, _ in stock_by_stem.get("xenbus", []) if v), None)
    if stock_bus_ver is None:
        pv_problem = ("STOCK_DRIVERVER_UNREADABLE", dict(driver="xenbus.sys"))
    elif xenbus["cls"] != "PVRUN":
        pv_problem = ("PV_NOT_OURS", dict(driver="xenbus", cls=xenbus["cls"]))
    elif xenbus["vstatus"] != "OK":
        pv_problem = ("VERSION_UNSTAMPED", dict(path=xenbus["rel"]))
    else:
        inf = os.path.join(tree, "pv-drivers", "xenbus", "xenbus.inf")
        dv = inf_driverver(inf) if os.path.isfile(inf) else []
        if len(dv) != 1:
            pv_problem = ("PV_INF_DRIVERVER_COUNT", dict(inf="xenbus/xenbus.inf", count=len(dv)))
        elif dv[0][1] != xenbus["ver"]:
            pv_problem = ("PV_INF_SYS_DRIVERVER_DISAGREE", dict(driver="xenbus", inf=dv[0][1], sys=xenbus["ver"]))
        elif not vtuple(xenbus["ver"]) > vtuple(stock_bus_ver):
            pv_problem = ("PV_DRIVERVER_NOT_ABOVE_STOCK", dict(driver="xenbus", got=xenbus["ver"], stock=stock_bus_ver))
        else:
            for member in ("xen.sys", "xenfilt.sys", "xenbus_monitor.exe", "xenbus_monitor.dll"):
                e = find_tree(f"pv-drivers/xenbus/{member}")
                if not e:
                    pv_problem = ("PV_MISSING", dict(exe=f"xenbus/{member}")); break
                if e["cls"] != "PVRUN" or e["vstatus"] != "OK" or e["ver"] != xenbus["ver"]:
                    pv_problem = ("PV_EXE_SYS_DISAGREE", dict(exe=f"xenbus/{member}", got=e["ver"], sys=xenbus["ver"], cls=e["cls"])); break
            if not pv_problem:
                pv_detail["xenbus"] = xenbus["ver"]; pv_detail["stock_xenbus"] = stock_bus_ver
if pv_problem:
    gate("PV_VERSION", "FAIL", pv_problem[0], **pv_problem[1])
else:
    gate("PV_VERSION", "PASS", **pv_detail)

# ---- MANIFEST_FILES: MANIFEST.files describes exactly this tree, byte for byte and version for -
# version. files[path] = {size, sha256, version} is what make-setup.ps1 has always emitted;
# `version` is PowerShell's VersionInfo.FileVersion STRING (devcon reads "10.0.26100.4202
# (WinBuild.160101.0800)"), so its leading dotted token is compared with the FIXED FileVersion
# read out of the PE, and a PE without a version resource must be recorded as null. Every tree
# file except the manifest and the sums must be listed - an OURS PE that is not is COMPONENT_UNLISTED.
# When the manifest carries build_rev, it must equal ci.run_number (both come from the same run).
try:
    m = json.load(open(manifest_path, encoding="utf-8-sig"))
except Exception as e:
    m = None
files = (m or {}).get("files")
if not isinstance(files, dict) or not files:
    gate("MANIFEST_FILES", "FAIL", "MANIFEST_NO_FILES", field="files", type=type(files).__name__)
else:
    problem = None
    checked = 0
    for rel, e in sorted(files.items()):
        if not isinstance(e, dict):
            problem = ("MANIFEST_FILE_ENTRY_BAD", dict(path=rel, type=type(e).__name__)); break
        p = tree_files.get(rel)
        if p is None:
            problem = ("FILE_MISSING", dict(path=rel)); break
        want_sha = str(e.get("sha256") or "").lower()
        if len(want_sha) != 64:
            problem = ("MANIFEST_FILE_ENTRY_BAD", dict(path=rel, field="sha256")); break
        if sha256(p) != want_sha:
            problem = ("FILE_SHA_MISMATCH", dict(path=rel, manifest=want_sha[:12], got=sha256(p)[:12])); break
        u = next((x for x in universe if x["channel"] == "tree" and x["path"] == p), None)
        if u is not None:
            mv = e.get("version")
            mv_token = str(mv).strip().split(" ")[0] if mv not in (None, "") else None
            if u["vstatus"] == "OK":
                if mv_token != u["ver"]:
                    problem = ("MANIFEST_FILE_VERSION", dict(path=rel, manifest=mv_token, got=u["ver"])); break
            elif mv_token is not None:
                problem = ("MANIFEST_FILE_VERSION", dict(path=rel, manifest=mv_token, got=u["vstatus"])); break
        checked += 1
    if not problem:
        # autorun.inf is written by packaging/make-iso.sh at ISO build time, after the tree manifest
        # and sums exist, and is deliberately outside SHA256SUMS.txt (make-iso.sh says so). It is the
        # only name exempt besides the manifest and the sums themselves; a PE by that name would
        # still be classified by PE_UNIVERSE.
        unlisted = sorted(r for r in tree_files if r not in files and r not in ("MANIFEST.json", "SHA256SUMS.txt", "autorun.inf"))
        if unlisted:
            ours_unlisted = [r for r in unlisted if any(x["channel"] == "tree" and x["rel"] == r and x["cls"] == "OURS" for x in universe)]
            if ours_unlisted:
                problem = ("COMPONENT_UNLISTED", dict(path=ours_unlisted[0], n=len(ours_unlisted)))
            else:
                problem = ("FILE_UNLISTED", dict(path=unlisted[0], n=len(unlisted)))
    if not problem:
        mrev = m.get("build_rev")
        crun = (m.get("ci") or {}).get("run_number")
        if mrev not in (None, "") and crun not in (None, ""):
            if str(mrev) != str(crun):
                problem = ("BUILD_REV_RUN_NUMBER_MISMATCH", dict(build_rev=mrev, run_number=crun))
    if problem:
        gate("MANIFEST_FILES", "FAIL", problem[0], **problem[1])
    else:
        gate("MANIFEST_FILES", "PASS", files=checked)

# ---- machine-readable universe dump for the work dir ------------------------------------------
dump = [dict(rel=u["rel"], channel=u["channel"], cls=u["cls"], sha256=u["sha"], file_version=u["ver"],
             version_status=u["vstatus"], pdb_stems=u["stems"]) for u in universe]
with open(os.path.join(os.environ.get("VERIFY_WORK", "."), "universe.json"), "w") as fh:
    json.dump(dump, fh, indent=1, sort_keys=True)
PY
}

# ------------------------------------------------------------------------------ MANIFEST + provenance
# Prints one line: OK <sha> <agent_sha> <release> <build_rev> <package_version> <run_id> <coreagent|->
# <has_rel 0/1> <has_rev 0/1>   or   FAIL <CODE> k=v ...
read_manifest() { # $1=manifest $2=opt-release $3=opt-build-rev $4=legacy
  python3 - "$@" <<'PY'
import json, re, sys
p, rel, rev, legacy = sys.argv[1:5]
try:
    m = json.load(open(p, encoding="utf-8-sig"))
except Exception as e:
    print("FAIL MANIFEST_UNREADABLE", f"file={p}"); sys.exit(0)
if not isinstance(m, dict):
    print("FAIL MANIFEST_UNREADABLE", f"file={p}", "reason=not_an_object"); sys.exit(0)
src = m.get("source") or {}
sha = str(src.get("driver_repo_commit") or "")
agent = str(src.get("agent_commit") or "")
if not re.fullmatch(r"[0-9a-f]{40}", sha):
    print("FAIL MANIFEST_NO_COMMIT", "field=source.driver_repo_commit"); sys.exit(0)
if not re.fullmatch(r"[0-9a-f]{40}", agent):
    print("FAIL MANIFEST_NO_COMMIT", "field=source.agent_commit"); sys.exit(0)
pv = str(m.get("package_version") or "")
if not pv:
    print("FAIL RELEASE_FIELDS_MISSING", "field=package_version"); sys.exit(0)
mrel = str(m.get("release_version") or "")
mrev = "" if m.get("build_rev") in (None, "") else str(m.get("build_rev"))
VER3 = r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
if mrel and not re.fullmatch(VER3, mrel):
    print("FAIL RELEASE_FIELDS_BAD", "field=release_version", f"got={mrel}"); sys.exit(0)
if mrev and not (re.fullmatch(r"0|[1-9][0-9]*", mrev) and int(mrev) <= 65535):
    print("FAIL RELEASE_FIELDS_BAD", "field=build_rev", f"got={mrev}"); sys.exit(0)
if rel and mrel and rel != mrel:
    print("FAIL RELEASE_FIELDS_MISMATCH", "field=release_version", f"manifest={mrel}", f"want={rel}"); sys.exit(0)
if rev and mrev and rev != mrev:
    print("FAIL RELEASE_FIELDS_MISMATCH", "field=build_rev", f"manifest={mrev}", f"want={rev}"); sys.exit(0)
rel = rel or mrel
rev = rev or mrev
if not rel or not rev:
    if legacy == "1":
        # legacy packages carried neither field: the release is the package_version prefix and
        # the build_rev is 0 - deliberately the shape the version gates reject, so a legacy
        # package can be VERIFIED for provenance/identity but never PASS the version gates.
        rel = rel or pv.split("+")[0]
        rev = rev or "0"
    if not rel:
        print("FAIL RELEASE_FIELDS_MISSING", "field=release_version", "hint=pass_--release"); sys.exit(0)
    if not rev:
        print("FAIL RELEASE_FIELDS_MISSING", "field=build_rev", "hint=pass_--build-rev"); sys.exit(0)
if pv.split("+")[0] != rel:
    print("FAIL RELEASE_FIELDS_MISMATCH", "field=package_version", f"got={pv}", f"want_prefix={rel}"); sys.exit(0)
ca = str(src.get("core_agent_commit") or "")
if ca and not re.fullmatch(r"[0-9a-f]{40}", ca):
    print("FAIL MANIFEST_NO_COMMIT", "field=source.core_agent_commit", f"got={ca}"); sys.exit(0)
run_id = str((m.get("ci") or {}).get("run_id") or "-")
print("OK", sha, agent, rel, rev, pv, run_id, ca or "-", "1" if mrel else "0", "1" if mrev else "0")
PY
}

# ------------------------------------------------------------------------------ verify one setup tree
# $1 = tree dir. Uses globals: EXPECT_COMMIT (may be empty in tag mode), TAG_TARGET (tag mode).
verify_tree() {
  local tree="$1"
  local mf="$tree/MANIFEST.json"
  if [ ! -f "$mf" ]; then gate_fail MANIFEST MANIFEST_MISSING "tree=$tree"; return 1; fi
  local r
  r="$(read_manifest "$mf" "$OPT_RELEASE" "$OPT_BUILD_REV" "$OPT_LEGACY")"
  local -a rf
  read -r -a rf <<< "$r"
  if [ "${rf[0]:-}" != OK ]; then
    gate_fail MANIFEST "${rf[1]:-MANIFEST_UNREADABLE}" "${rf[@]:2}"; return 1
  fi
  M_SHA="${rf[1]}"; M_AGENT="${rf[2]}"; M_REL="${rf[3]}"; M_REV="${rf[4]}"; M_PKGVER="${rf[5]}"
  M_RUN="${rf[6]}"; M_COREAGENT="${rf[7]}"; M_HAS_REL="${rf[8]}"; M_HAS_REV="${rf[9]}"
  WANT="$M_REL.$M_REV"
  local legacy_note=""
  [ "$M_HAS_REL$M_HAS_REV" = "11" ] || legacy_note="manifest_release_fields=absent"
  # the FULL commit is recorded here on purpose: cut-release invariant 5 compares it exactly
  gate_pass MANIFEST "package_version=$M_PKGVER" "want=$WANT" "commit=$M_SHA" "agent=${M_AGENT:0:12}" ${legacy_note:+$legacy_note}
  echo "  package_version : $M_PKGVER"
  echo "  driver commit   : $M_SHA"
  echo "  agent commit    : $M_AGENT"
  echo "  release/rev     : $WANT"

  # ---- PROVENANCE ------------------------------------------------------------------------------
  # package_version is <ver>+agent.<agent sha> and cannot tell two packages apart when only the
  # driver repo changed. The expectation is the commit being released (--commit) and/or the tag's
  # own commit (--tag). No expectation at all is a FAIL, never a pass with nothing checked.
  local prov_ok=1 exp="" expected=()
  if [ -n "$EXPECT_COMMIT" ]; then
    exp="$(git -C "$REPO" rev-parse --verify --quiet "$EXPECT_COMMIT^{commit}" 2>/dev/null)" || exp=""
    if [ -z "$exp" ]; then
      gate_fail PROVENANCE COMMIT_UNRESOLVABLE "commit=$EXPECT_COMMIT" "hint=git_fetch_origin"; prov_ok=0
    else
      expected+=("$exp")
    fi
  fi
  [ -n "${TAG_TARGET:-}" ] && expected+=("$TAG_TARGET")
  if [ "$prov_ok" = 1 ] && [ "${#expected[@]}" -eq 0 ]; then
    gate_fail PROVENANCE NO_EXPECTATION "hint=pass_--commit_or_a_resolvable_--tag"; prov_ok=0
  fi
  local e
  for e in "${expected[@]}"; do
    [ "$prov_ok" = 1 ] || break
    if [ "$e" != "$M_SHA" ]; then
      # THE failure-3 shape: right package_version, wrong build. In tag mode this also catches a
      # tag cut on HEAD rather than on the build (cut-release tags the manifest commit for that).
      gate_fail PROVENANCE PROVENANCE_COMMIT_MISMATCH "manifest=${M_SHA:0:12}" "expected=${e:0:12}" "package_version=$M_PKGVER"; prov_ok=0
    fi
  done
  if [ "$prov_ok" = 1 ]; then
    # the agent gitlink AT THAT COMMIT must be the agent the package was built from
    local pinned
    pinned="$(git -C "$REPO" rev-parse --verify --quiet "$M_SHA:agent" 2>/dev/null)" || pinned=""
    if [ -z "$pinned" ]; then
      gate_fail PROVENANCE AGENT_GITLINK_UNREADABLE "commit=${M_SHA:0:12}" "hint=git_fetch_origin"; prov_ok=0
    elif [ "$pinned" != "$M_AGENT" ]; then
      gate_fail PROVENANCE AGENT_SHA_MISMATCH "manifest=${M_AGENT:0:12}" "gitlink=${pinned:0:12}" "commit=${M_SHA:0:12}"; prov_ok=0
    fi
  fi
  if [ "$prov_ok" = 1 ]; then
    local ca_pinned
    ca_pinned="$(git -C "$REPO" rev-parse --verify --quiet "$M_SHA:core-agent" 2>/dev/null)" || ca_pinned=""
    if [ "$M_COREAGENT" = "-" ]; then
      if [ "$OPT_LEGACY" = 1 ]; then
        gate_skip PROVENANCE_COREAGENT LEGACY_MANIFEST "reason=core-agent_sha_not_recorded"
      else
        gate_fail PROVENANCE COREAGENT_SHA_MISSING "field=source.core_agent_commit"; prov_ok=0
      fi
    elif [ -z "$ca_pinned" ] || [ "$ca_pinned" != "$M_COREAGENT" ]; then
      gate_fail PROVENANCE COREAGENT_SHA_MISMATCH "manifest=${M_COREAGENT:0:12}" "gitlink=${ca_pinned:0:12}"; prov_ok=0
    fi
  fi
  if [ "$prov_ok" = 1 ] && [ -n "$OPT_RUN" ]; then
    if [ "$M_RUN" != "$OPT_RUN" ]; then
      gate_fail PROVENANCE MANIFEST_RUN_ID_MISMATCH "manifest=$M_RUN" "run=$OPT_RUN"; prov_ok=0
    elif ! command -v gh >/dev/null 2>&1 || ! gh_slug; then
      gate_fail PROVENANCE GH_UNAVAILABLE "run=$OPT_RUN" "hint=gh_not_installed_or_origin_not_github"; prov_ok=0
    else
      local rf2
      rf2="$(gh run view "$OPT_RUN" -R "$GH_SLUG" --json workflowName,headSha,number,conclusion -q '[.workflowName,.headSha,(.number|tostring),.conclusion]|join(" ")' 2>/dev/null)" || rf2=""
      if [ -z "$rf2" ]; then
        gate_fail PROVENANCE GH_UNAVAILABLE "run=$OPT_RUN" "repo=$GH_SLUG"; prov_ok=0
      else
        local wf hs num con
        read -r wf hs num con <<< "$rf2"
        if [ "$wf" != "$RELEASE_WORKFLOW_NAME" ]; then gate_fail PROVENANCE RUN_NOT_RELEASE_WORKFLOW "run=$OPT_RUN" "workflow=$wf"; prov_ok=0
        elif [ "$con" != success ]; then gate_fail PROVENANCE RUN_NOT_SUCCESS "run=$OPT_RUN" "conclusion=$con"; prov_ok=0
        elif [ "$hs" != "$M_SHA" ]; then gate_fail PROVENANCE RUN_SHA_MISMATCH "run_sha=${hs:0:12}" "manifest=${M_SHA:0:12}"; prov_ok=0
        elif [ "$num" != "$M_REV" ]; then gate_fail PROVENANCE RUN_NUMBER_MISMATCH "run_number=$num" "build_rev=$M_REV"; prov_ok=0
        fi
      fi
    fi
  fi
  [ "$prov_ok" = 1 ] && gate_pass PROVENANCE "commit=${M_SHA:0:12}" "agent=${M_AGENT:0:12}" "expectations=${#expected[@]}" ${OPT_RUN:+run=$OPT_RUN}

  # ---- PAYLOAD: sums + installer bytes vs the repo at the build commit (reused, explicit sha) ----
  local ap
  if ap="$("$REPO/tools/assert-payload.sh" "$tree" "$M_SHA" 2>&1)"; then
    gate_pass PAYLOAD "sha=${M_SHA:0:12}"
  else
    printf '%s\n' "$ap" | sed 's/^/  /'
    gate_fail PAYLOAD ASSERT_PAYLOAD_FAILED "sha=${M_SHA:0:12}"
  fi

  # ---- MSI payload -----------------------------------------------------------------------------
  local msi="$tree/msi/installer.msi" payload="$WORK/msi-payload" n=""
  if [ ! -s "$msi" ]; then
    gate_fail MSI_PAYLOAD MSI_MISSING "path=msi/installer.msi"
    payload=""
  else
    n="$(extract_msi "$msi" "$payload")" || { gate_fail MSI_PAYLOAD MSI_EXTRACT_FAILED "msi=msi/installer.msi"; payload=""; }
    if [ -n "$payload" ]; then
      if [ "${n:-0}" -gt 0 ]; then gate_pass MSI_PAYLOAD "files=$n"; else gate_fail MSI_PAYLOAD MSI_EMPTY "files=0"; payload=""; fi
    fi
  fi

  # ---- ours-wins claims AT THE BUILD COMMIT (never the working tree's copy) --------------------
  local claims="$WORK/ours-wins.psd1"
  if ! git -C "$REPO" show "$M_SHA:packaging/ours-wins.psd1" > "$claims" 2>/dev/null; then
    : > "$claims"   # the analyser reports OURSWINS_UNREADABLE
  fi

  # ---- the derived-universe analysis: to a file, exit status checked, THEN relayed ---------------
  local aout="$WORK/analyse.out" aerr="$WORK/analyse.err" arc
  VERIFY_WORK="$WORK" analyse "$tree" "$payload" "$STOCK_DIR" "$WANT" "$mf" "$claims" "$OPT_LEGACY" > "$aout" 2> "$aerr"; arc=$?
  relay_gates "$aout"
  if [ "$arc" -ne 0 ]; then
    sed 's/^/  analyser: /' "$aerr" | tail -n 5
    gate_fail ANALYSER ANALYSER_CRASHED "rc=$arc" "stderr=$aerr"
  else
    gate_pass ANALYSER "rc=0"
  fi

  # ---- opt-in fork-only markers, both encodings, no grep -q --------------------------------------
  local mk label str hit f
  for mk in "${MARKERS[@]}"; do
    label="${mk%%=*}"; str="${mk#*=}"
    hit=0
    while IFS= read -r f; do
      if strings -a      "$f" 2>/dev/null | grep -aF -- "$str" >/dev/null ||
         strings -a -e l "$f" 2>/dev/null | grep -aF -- "$str" >/dev/null; then hit=1; break; fi
    done < <({ [ -n "$payload" ] && find "$payload" -type f -size +8k; find "$tree" -type f \( -iname '*.exe' -o -iname '*.dll' -o -iname '*.sys' \); } 2>/dev/null)
    if [ "$hit" = 1 ]; then gate_pass "MARKER_$label"; else gate_fail "MARKER_$label" MARKER_ABSENT "label=$label"; fi
  done
  return 0
}

# ------------------------------------------------------------------------------ asset-set verification
# $1 = assets dir: a release-assets artifacts dir or what `gh release download` produced.
# THE ASSET SET IS CLOSED: exactly one *.iso, exactly one *.rpm, one qubes-tools-<ver>.exe,
# MANIFEST.json, SHA256SUMS.txt, and at most one *-setup.tar.gz. Anything else is a shipped file
# from an unknown build (the published 4.3.21 carried a loose gui-agent.exe) and FAILS.
TAR_PRESENT=0
verify_assets() {
  local a
  a="$(realpath -- "$1")"   # absolute: rpm2cpio/sha256sum -c run after a cd
  local iso="" rpm="" exe="" tarb="" f b n_iso=0 n_rpm=0 n_exe=0 n_tar=0 unexpected="" have_mf=0 have_sums=0
  while IFS= read -r f; do
    b="$(basename "$f")"
    case "$b" in
      *.iso)              iso="$f"; n_iso=$((n_iso + 1)) ;;
      *.rpm)              rpm="$f"; n_rpm=$((n_rpm + 1)) ;;
      qubes-tools-*.exe)  exe="$f"; n_exe=$((n_exe + 1)) ;;
      *-setup.tar.gz)     tarb="$f"; n_tar=$((n_tar + 1)) ;;
      MANIFEST.json)      have_mf=1 ;;
      SHA256SUMS.txt)     have_sums=1 ;;
      *)                  unexpected="$unexpected $b" ;;
    esac
  done < <(find "$a" -mindepth 1 -maxdepth 1 | sort)
  # Every defect of the set is collected; the gate's code is the first, `also=` names the rest, so
  # a release missing MANIFEST.json does not hide that its sums cover none of the assets either.
  local -a problems=() details=()
  local missing=""
  [ -n "$unexpected" ] && { problems+=(ASSET_UNEXPECTED); details+=("unexpected=${unexpected# }"); }
  [ "$n_iso" -eq 1 ] || missing="$missing iso(n=$n_iso)"
  [ "$n_rpm" -eq 1 ] || missing="$missing rpm(n=$n_rpm)"
  [ "$n_exe" -eq 1 ] || missing="$missing qubes-tools-exe(n=$n_exe)"
  [ "$n_tar" -le 1 ] || missing="$missing setup-tar(n=$n_tar)"
  [ "$have_mf" = 1 ] || missing="$missing MANIFEST.json"
  [ "$have_sums" = 1 ] || missing="$missing SHA256SUMS.txt"
  [ -n "$missing" ] && { problems+=(ASSET_MISSING); details+=("kinds=${missing# }"); }
  if [ "$have_sums" = 1 ]; then
    # Coverage is SET MEMBERSHIP of parsed names (leading '*' / './' stripped, CRLF tolerated),
    # never a substring match: 'foo.iso' is not covered by a 'foo.iso.sig' line, and a binary-
    # mode '<sha> *name' entry is a real entry.
    local covered uncovered=""
    covered="$(tr -d '\r' < "$a/SHA256SUMS.txt" | awk 'NF >= 2 { $1 = ""; sub(/^ +\*?/, ""); sub(/^\.\//, ""); print }')"
    while IFS= read -r f; do
      b="$(basename "$f")"
      [ "$b" = SHA256SUMS.txt ] && continue
      if ! printf '%s\n' "$covered" | grep -Fx -- "$b" >/dev/null; then uncovered="$uncovered $b"; fi
    done < <(find "$a" -mindepth 1 -maxdepth 1 -type f)
    if [ -n "$uncovered" ]; then
      problems+=(ASSET_SUMS_INCOMPLETE); details+=("uncovered=${uncovered# }")
    elif ! (cd "$a" && tr -d '\r' < SHA256SUMS.txt | sha256sum -c --quiet >/dev/null 2>&1); then
      problems+=(ASSET_SUMS); details+=("sums=SHA256SUMS.txt")
    fi
  fi
  if [ "${#problems[@]}" -gt 0 ]; then
    local also=""
    [ "${#problems[@]}" -gt 1 ] && also="also=$(printf '%s,' "${problems[@]:1}" | sed 's/,$//')"
    gate_fail ASSET_SET "${problems[0]}" "${details[@]}" ${also:+$also}
  else
    gate_pass ASSET_SET "iso=$(basename "$iso")" "rpm=$(basename "$rpm")" "exe=$(basename "$exe")" "tar=${tarb:+$(basename "$tarb")}"
  fi
  [ "$n_iso" -eq 1 ] || { gate_fail ISO_IDENTITY ISO_EXTRACT_FAILED "reason=no_single_iso_asset" "n=$n_iso"; return 1; }
  [ -n "$tarb" ] && TAR_PRESENT=1

  # ---- ISO -> tree -------------------------------------------------------------------------------
  local isodir="$WORK/iso" mfa="$a/MANIFEST.json"
  if ! extract_iso "$iso" "$isodir"; then gate_fail ISO_IDENTITY ISO_EXTRACT_FAILED "iso=$(basename "$iso")"; return 1; fi
  [ -f "$isodir/MANIFEST.json" ] || { gate_fail ISO_IDENTITY ISO_MANIFEST_MISMATCH "reason=no_MANIFEST.json_in_iso"; return 1; }
  ISO_SHA="$(sha256_of "$iso")"
  echo "  iso sha256      : $ISO_SHA"
  if [ -f "$mfa" ]; then
    if cmp -s "$isodir/MANIFEST.json" "$mfa"; then
      gate_pass ISO_IDENTITY "iso=$(basename "$iso")" "sha=${ISO_SHA:0:12}"
    else
      # legacy: the iso-artifact MANIFEST is the tree manifest with package renamed and an `iso`
      # block naming the image; accepted only when that block's sha256 IS this iso's.
      local leg
      leg="$(python3 - "$isodir/MANIFEST.json" "$mfa" "$ISO_SHA" <<'PY'
import json, sys
a = json.load(open(sys.argv[1], encoding="utf-8-sig")); b = json.load(open(sys.argv[2], encoding="utf-8-sig")); sha = sys.argv[3]
extra = set(b) - set(a)
diff = sorted(k for k in set(a) & set(b) if a.get(k) != b.get(k))
if set(a) <= set(b) and extra == {"iso"} and diff in ([], ["package"]) \
        and str((b.get("iso") or {}).get("sha256", "")).lower() == sha:
    print("LEGACY_OK")
else:
    print("DIFF", ",".join(sorted(extra)) or "-", ",".join(diff) or "-", str((b.get("iso") or {}).get("sha256", "-"))[:12])
PY
)"
      if [ "$leg" = LEGACY_OK ] && [ "$OPT_LEGACY" = 1 ]; then
        gate_pass ISO_IDENTITY "iso=$(basename "$iso")" "sha=${ISO_SHA:0:12}" "legacy_iso_block=1"
      else
        gate_fail ISO_IDENTITY ISO_MANIFEST_MISMATCH "iso=$(basename "$iso")" "detail=${leg// /_}"
      fi
    fi
  elif [ "$OPT_LEGACY" = 1 ]; then
    gate_skip ISO_IDENTITY LEGACY_NO_MANIFEST_ASSET "iso=$(basename "$iso")" "sha=${ISO_SHA:0:12}"
  else
    gate_fail ISO_IDENTITY ISO_MANIFEST_MISMATCH "reason=no_MANIFEST.json_asset"
  fi

  # ---- setup tar: the SAME tree as the ISO (manifest and sums byte-identical to the ISO's) ---------
  if [ -n "$tarb" ]; then
    local td="$WORK/setup-tar"
    rm_rf "$td"; mkdir -p "$td"
    if ! tar -xzf "$tarb" -C "$td" 2>/dev/null; then
      gate_fail SETUP_TAR TAR_EXTRACT_FAILED "tar=$(basename "$tarb")"
    else
      local tm
      tm="$(find "$td" -maxdepth 2 -name MANIFEST.json | head -1)"
      if [ -z "$tm" ]; then gate_fail SETUP_TAR TAR_MANIFEST_MISMATCH "reason=no_MANIFEST.json_in_tar"
      elif ! cmp -s "$tm" "$isodir/MANIFEST.json"; then gate_fail SETUP_TAR TAR_MANIFEST_MISMATCH "tar=$(basename "$tarb")"
      elif [ ! -f "$(dirname "$tm")/SHA256SUMS.txt" ]; then gate_fail SETUP_TAR TAR_SUMS_MISMATCH "reason=no_SHA256SUMS.txt_in_tar"
      elif ! cmp -s "$(dirname "$tm")/SHA256SUMS.txt" "$isodir/SHA256SUMS.txt"; then gate_fail SETUP_TAR TAR_SUMS_MISMATCH "tar=$(basename "$tarb")" "reason=tar_sums_differ_from_iso_sums"
      else gate_pass SETUP_TAR "tar=$(basename "$tarb")"; fi
    fi
  fi

  # ---- RPM: embeds THIS iso ---------------------------------------------------------------------
  if [ -n "$rpm" ]; then
    if ! command -v rpm2cpio >/dev/null 2>&1 || ! command -v cpio >/dev/null 2>&1 || ! command -v rpm >/dev/null 2>&1; then
      gate_fail RPM_IDENTITY PREREQ_MISSING "tools=rpm,rpm2cpio,cpio"
    else
      local rd="$WORK/rpm"
      rm_rf "$rd"; mkdir -p "$rd"
      if ! (cd "$rd" && rpm2cpio "$rpm" | cpio -idm --quiet 2>/dev/null); then
        gate_fail RPM_IDENTITY RPM_EXTRACT_FAILED "rpm=$(basename "$rpm")"
      else
        local emb="$rd/usr/lib/qubes/qubes-windows-tools.iso"
        if [ ! -f "$emb" ]; then
          gate_fail RPM_IDENTITY RPM_NO_ISO "path=/usr/lib/qubes/qubes-windows-tools.iso"
        elif [ "$(sha256_of "$emb")" != "$ISO_SHA" ]; then
          gate_fail RPM_IDENTITY RPM_ISO_MISMATCH "rpm_iso=$(sha256_of "$emb" | cut -c1-12)" "iso=${ISO_SHA:0:12}"
        else
          RPM_VR="$(rpm -qp --qf '%{VERSION} %{RELEASE}' "$rpm" 2>/dev/null)" || RPM_VR=""
          gate_pass RPM_IDENTITY "rpm=$(basename "$rpm")" "iso=${ISO_SHA:0:12}" "version_release=${RPM_VR// /-}"
        fi
      fi
    fi
  fi

  # ---- the tree checks, on the ISO's own contents -------------------------------------------------
  verify_tree "$isodir" || return 1

  # ---- RPM naming needs the manifest fields verify_tree just read --------------------------------
  # release-package.yml emits Release=1.agent<sha12>; nothing else about the Release string is a
  # contract, so nothing else is asserted (a '.r<build_rev>' clause with no producer was deleted).
  if [ -n "$rpm" ]; then
    if [ -z "${RPM_VR:-}" ]; then
      gate_fail RPM_VERSION RPM_QUERY_FAILED "rpm=$(basename "$rpm")"
    else
      local rv rr want_rel="1.agent${M_AGENT:0:12}"
      read -r rv rr <<< "$RPM_VR"
      if [ "$rv" != "$M_REL" ]; then
        gate_fail RPM_VERSION RPM_VERSION_MISMATCH "version=$rv" "want=$M_REL"
      elif [[ "$rr" != "$want_rel"* ]]; then
        gate_fail RPM_VERSION RPM_VERSION_MISMATCH "release=$rr" "want_prefix=$want_rel"
      else
        gate_pass RPM_VERSION "version=$rv" "release=$rr"
      fi
    fi
  fi

  # ---- qubes-tools-<ver>.exe asset: the very bytes the ISO carries -------------------------------
  if [ -n "$exe" ]; then
    local inside="$isodir/$(basename "$exe")"
    if [ "$(basename "$exe")" != "qubes-tools-$M_REL.exe" ]; then
      gate_fail EXE_ASSET EXE_ASSET_MISMATCH "asset=$(basename "$exe")" "want=qubes-tools-$M_REL.exe"
    elif [ ! -f "$inside" ]; then
      gate_fail EXE_ASSET EXE_ASSET_MISMATCH "reason=not_in_iso" "asset=$(basename "$exe")"
    elif ! cmp -s "$exe" "$inside"; then
      gate_fail EXE_ASSET EXE_ASSET_MISMATCH "asset_sha=$(sha256_of "$exe" | cut -c1-12)" "iso_sha=$(sha256_of "$inside" | cut -c1-12)"
    else
      gate_pass EXE_ASSET "asset=$(basename "$exe")"
    fi
  fi
  return 0
}

# ------------------------------------------------------------------------------ completeness + result
required_gates() {
  local req=(STOCK_IMAGE MANIFEST PROVENANCE PAYLOAD MSI_PAYLOAD ANALYSER PE_UNIVERSE CLAIMED_IS_OURS
             OURS_STAMPED OURS_VERSION IDD_VERSION PV_VERSION MANIFEST_FILES)
  local mk
  for mk in "${MARKERS[@]}"; do req+=("MARKER_${mk%%=*}"); done
  case "$MODE" in
    assets) req+=(ASSET_SET ISO_IDENTITY RPM_IDENTITY RPM_VERSION EXE_ASSET) ;;
    tag)    req+=(TAG_TARGET ASSET_SET ISO_IDENTITY RPM_IDENTITY RPM_VERSION EXE_ASSET) ;;
  esac
  [ "$TAR_PRESENT" = 1 ] && req+=(SETUP_TAR)
  printf '%s\n' "${req[@]}"
}
# finish: assert the required gate set is present, write the result record, print RESULT, exit.
finish() {
  local g missing="" fails
  while IFS= read -r g; do
    gate_seen "$g" || missing="$missing $g"
  done < <(required_gates)
  if [ -n "$missing" ]; then
    gate_fail GATES GATES_INCOMPLETE "missing=${missing# }"
  else
    gate_pass GATES "required=$(required_gates | wc -l)"
  fi
  # Count from the record, not a shell variable.
  fails="$(grep -c '"outcome": "FAIL"' "$GATES")"
  python3 - "$GATES" "$MODE" "$TARGET" "$fails" "${M_SHA:-}" "${WANT:-}" "${ISO_SHA:-}" "${M_REV:-}" <<'PY'
import json, sys, time
g, mode, target, fails, sha, want, iso, rev = sys.argv[1:9]
rec = {"result": "COMPLETE" if fails == "0" else "INCOMPLETE", "fails": int(fails), "mode": mode,
       "target": target, "manifest_commit": sha, "want": want, "build_rev": rev, "iso_sha256": iso,
       "utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
with open(g, "a") as fh:
    fh.write(json.dumps(rec, sort_keys=True) + "\n")
PY
  echo
  if [ "$fails" -eq 0 ]; then
    echo "RESULT: PACKAGE COMPLETE${WANT:+ (version $WANT)} - $(grep -c '"outcome": "PASS"' "$GATES") gates passed, $(grep -c '"outcome": "SKIP"' "$GATES") skipped (gates: $GATES)"
    exit 0
  fi
  echo "RESULT: INCOMPLETE - $fails gate(s) FAILED (gates: $GATES)"
  exit 1
}

# ------------------------------------------------------------------------------ selftest
# A check counts as evidence only once it has been seen to FAIL with the defect re-introduced.
# Level 1 (always): the VS_VERSIONINFO reader on real fixtures from the vendored stock MSI.
# Level 2 (--selftest-tree <setup-tree>): whole-verifier runs on mutated copies of a real package,
#   each expected to emit the named FAIL code - AND that code must be NEW relative to the unmutated
#   baseline. A code the fixture already has for real (today: every version gate on a legacy,
#   unstamped package) proves nothing about the mutation and is reported NOT PROVEN, which fails
#   the selftest. Re-run on the first stamped package to turn those into proofs.
# Level 3 (--selftest-assets <closed-set-dir>): the same on the asset-level gates.
selftest() {
  local fails=0 pass_n=0 notproven_n=0
  st_ok()  { echo "  PASS        $1"; pass_n=$((pass_n + 1)); }
  st_bad() { echo "  FAIL        $1"; fails=$((fails + 1)); }
  st_np()  { echo "  NOT PROVEN  $1"; notproven_n=$((notproven_n + 1)); fails=$((fails + 1)); }
  need_tools 7z cabextract python3 sha256sum strings || return 1
  prepare_stock || return 1
  echo "--- level 1: version reader on stock fixtures ---"
  local r
  r="$(python3 - "$STOCK_DIR" <<'PY'
import os, re, struct, sys
stock = sys.argv[1]
exec(os.environ["PE_READER"])
PDB = re.compile(rb"[A-Za-z]:\\[^\x00-\x1f]{1,400}?\.pdb", re.I)
def stems(data):
    return {m.group(0).decode("latin-1").split("\\")[-1].lower()[:-4] for m in PDB.finditer(data)}
fx = {}
for d, _, fs in os.walk(stock):
    for f in fs:
        p = os.path.join(d, f)
        data = open(p, "rb").read()
        if not is_pe(data):
            continue
        for s in stems(data):
            fx.setdefault(s, (p, data))
out = []
def case(name, cond, detail):
    out.append(("PASS" if cond else "FAIL") + " " + name + " " + detail)
ga = fx.get("gui-agent")
if not ga:
    out.append("FAIL stock-gui-agent-located no gui-agent.pdb stem in the stock payload")
else:
    st, v, _, off = pe_fileversion(ga[1])
    case("stock-gui-agent-reads-4.2.2.0", st == "OK" and v == "4.2.2.0", f"status={st} version={v} key={os.path.basename(ga[0])}")
    data = bytearray(ga[1])
    e = struct.unpack_from("<I", data, 0x3C)[0]; opt = e + 24
    magic = struct.unpack_from("<H", data, opt)[0]
    dd = opt + (112 if magic == 0x20B else 96) + 2 * 8
    struct.pack_into("<II", data, dd, 0, 0)
    st2, v2, _, _ = pe_fileversion(bytes(data))
    case("stripped-resource-dir-reads-NO_VERSION", st2 == "NO_VERSION" and v2 is None, f"status={st2} version={v2}")
    st3, v3, _, _ = pe_fileversion(ga[1][:4096])
    case("truncated-pe-reads-CORRUPT", st3 in ("CORRUPT", "NO_VERSION") and v3 is None, f"status={st3} version={v3}")
    # the fixed-version patcher the level-2 fixtures rely on: patch, re-read, and the bytes outside
    # the 8 patched ones are untouched
    patched = pe_set_fileversion(ga[1], "9.1.0.0")
    st5, v5, _, off5 = pe_fileversion(patched)
    same_elsewhere = patched[:off + 8] == ga[1][:off + 8] and patched[off + 16:] == ga[1][off + 16:]
    case("patched-fixed-version-reads-9.1.0.0", st5 == "OK" and v5 == "9.1.0.0" and off5 == off and same_elsewhere, f"status={st5} version={v5} bytes_outside_unchanged={same_elsewhere}")
    case("stock-gui-agent-pdb-is-not-ours", b"\\qubes-win-idd-driver\\" not in ga[1] and b":\\builder\\build\\" in ga[1], "pdb=c:\\builder\\build\\...")
qc = fx.get("qubesdb-cmd")
if not qc:
    out.append("FAIL stock-qubesdb-cmd-located no qubesdb-cmd.pdb stem in the stock payload")
else:
    st4, v4, _, _ = pe_fileversion(qc[1])
    case("stock-qubesdb-cmd-reads-NO_VERSION", st4 == "NO_VERSION" and v4 is None, f"status={st4} version={v4}")
case("text-file-is-not-a-pe", not is_pe(b"MZ this is not a PE file at all" + b"\0" * 100), "")
print("\n".join(out))
PY
)"
  local line
  while IFS= read -r line; do
    case "$line" in
      PASS*) st_ok "${line#PASS }" ;;
      *)     st_bad "${line#FAIL }" ;;
    esac
  done <<< "$r"

  local self
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
  # codes_of OUT -> the set of FAIL codes in a verifier output
  codes_of() { printf '%s\n' "$1" | sed -nE 's/^GATE [A-Za-z0-9_-]+ FAIL code=([A-Z0-9_]+).*/\1/p' | sort -u; }
  # run_case NAME EXPECT_CODE MUTATOR [extra verifier args...]: copies the fixture, mutates it,
  # runs the verifier and requires EXPECT_CODE among the FAIL codes AND absent from the baseline.
  # Output is captured first, then tested: never `grep -q` on a pipeline.
  local baseline_out="" baseline_codes="" src="" fixture_mode="" fixture_args=()
  # RUN_ARGS_OVERRIDE (env, space-separated) replaces the fixture's default verifier args for one
  # case - used to run a legacy fixture STRICTLY.
  run_case() {
    local name="$1" expect="$2" mut="$3"; shift 3
    local copy="$WORK/case-$name"
    rm_rf "$copy" "$WORK/run-$name"; cp -a "$src" "$copy"; chmod -R u+rwX "$copy"
    "$mut" "$copy"
    local -a args=("${fixture_args[@]}")
    # shellcheck disable=SC2206
    [ -n "${RUN_ARGS_OVERRIDE:-}" ] && args=($RUN_ARGS_OVERRIDE)
    local out
    out="$("$self" "--$fixture_mode" "$copy" "${args[@]}" --work "$WORK/run-$name" "$@" 2>/dev/null)"
    local codes
    codes="$(codes_of "$out")"
    if ! printf '%s\n' "$codes" | grep -Fx -- "$expect" >/dev/null; then
      st_bad "$name: expected code=$expect; got FAIL codes: $(printf '%s' "$codes" | tr '\n' ',')"
    elif printf '%s\n' "$baseline_codes" | grep -Fx -- "$expect" >/dev/null; then
      st_np "$name -> code=$expect already fires on the UNMUTATED fixture (the fixture really has this defect); the mutation proved nothing - re-prove on a fixture without it"
    else
      st_ok "$name -> code=$expect"
    fi
    rm_rf "$copy" "$WORK/run-$name"
  }
  # fixture_prep DIR MODE: reads the fixture's own commit/release/rev and legacy-ness, runs baseline
  fixture_prep() {
    src="$1"; fixture_mode="$2"
    local mf="$src/MANIFEST.json"
    [ -f "$mf" ] || { st_bad "selftest fixture $src has no MANIFEST.json"; return 1; }
    local info
    info="$(python3 - "$mf" "$src" <<'PY'
import json, os, re, sys
exec(os.environ["PE_READER"])
m = json.load(open(sys.argv[1], encoding="utf-8-sig"))
sha = m["source"]["driver_repo_commit"]
rel = str(m.get("release_version") or m["package_version"].split("+")[0])
rev = m.get("build_rev")
legacy = "0" if (m.get("release_version") and rev not in (None, "")) else "1"
if rev in (None, ""):
    # legacy fixture: the fixture's real 4th field is whatever builderv2's set-version stamped
    # into reference/gui-agent.exe (0), read from the binary rather than assumed; an assets dir
    # has no tree, so there the manifest's own record of that binary is the source.
    p = os.path.join(sys.argv[2], "reference", "gui-agent.exe")
    if os.path.isfile(p):
        st, v, _, _ = pe_fileversion(open(p, "rb").read())
        if st != "OK":
            print("FAIL reference/gui-agent.exe unreadable: " + st); sys.exit(0)
    else:
        v = str(((m.get("files") or {}).get("reference/gui-agent.exe") or {}).get("version") or "")
        if not re.fullmatch(r"\d+\.\d+\.\d+\.\d+", v):
            print("FAIL no reference/gui-agent.exe in the fixture and MANIFEST.files has no version for it"); sys.exit(0)
    rev = v.split(".")[3]
print("OK", sha, rel, rev, legacy)
PY
)"
    local -a fi
    read -r -a fi <<< "$info"
    [ "${fi[0]}" = OK ] || { st_bad "fixture: ${info#FAIL }"; return 1; }
    FX_SHA="${fi[1]}"; FX_REL="${fi[2]}"; FX_REV="${fi[3]}"; FX_LEGACY="${fi[4]}"
    fixture_args=(--commit "$FX_SHA" --release "$FX_REL" --build-rev "$FX_REV")
    [ "$FX_LEGACY" = 1 ] && fixture_args+=(--legacy-manifest)
    rm_rf "$WORK/run-baseline"
    baseline_out="$("$self" "--$fixture_mode" "$src" "${fixture_args[@]}" --work "$WORK/run-baseline" 2>/dev/null)"
    baseline_codes="$(codes_of "$baseline_out")"
    echo "  fixture: commit=${FX_SHA:0:12} release=$FX_REL build_rev=$FX_REV legacy=$FX_LEGACY"
    echo "  baseline (unmutated) FAIL codes: $(printf '%s' "$baseline_codes" | tr '\n' ' ')"
    return 0
  }

  # ---- fixture mutators (all take the copy dir) --------------------------------------------------
  mut_none() { :; }
  mut_json() { # $1=copy ; stdin = python body operating on `m` (the MANIFEST dict) and `root`
    python3 - "$1/MANIFEST.json" "$1" "$(cat)" <<'PY'
import hashlib, json, sys
p, root, body = sys.argv[1:4]
m = json.load(open(p, encoding="utf-8-sig"))
exec(body)
json.dump(m, open(p, "w"), indent=2)
PY
  }
  mut_commit() { mut_json "$1" <<< 'm["source"]["driver_repo_commit"] = "d69aff9f78d68915867b75fdf010907e9be38ce3"'; }
  stock_stream_with_stem() { # prints the stock payload stream whose PDB stem or OriginalFilename stem is $1
    python3 - "$STOCK_DIR" "$1" <<'PY'
import os, re, sys
exec(os.environ["PE_READER"])
stem = sys.argv[2].lower()
PDB = re.compile((r"[A-Za-z]:\\[^\x00-\x1f]{1,400}?" + re.escape(stem) + r"\.pdb").encode(), re.I)
for d, _, fs in sorted(os.walk(sys.argv[1])):
    for f in sorted(fs):
        p = os.path.join(d, f)
        data = open(p, "rb").read()
        if not is_pe(data):
            continue
        if PDB.search(data):
            print(p); sys.exit(0)
        _, _, strs, _ = pe_fileversion(data)
        ofn = (strs.get("OriginalFilename") or "").lower()
        if ofn and os.path.splitext(ofn)[0] == stem:
            print(p); sys.exit(0)
print("/nonexistent/stock-stream-for-" + stem)
PY
  }
  mut_stock_in_bin()   { cp "$(stock_stream_with_stem qrexec-agent)" "$1/bin/qrexec-wrapper.exe"; }
  mut_claimed_deleted(){ rm -f "$1/bin/qrexec-wrapper.exe"; }
  mut_stock_stray()    { cp "$(stock_stream_with_stem qrexec-agent)" "$1/bin/stock-stray.exe"; }
  mut_unknown_pe() { # a PE from nowhere: neither stock bytes nor our build tree
    python3 - "$1/bin/stray.exe" <<'PY'
import struct, sys
mz = bytearray(b"MZ" + b"\0" * 0x3E); struct.pack_into("<I", mz, 0x3C, 0x40)
coff = b"PE\0\0" + struct.pack("<HHIIIHH", 0x8664, 0, 0, 0, 0, 112, 0x22)
opt = struct.pack("<HBBIIIIIQ", 0x20B, 14, 0, 0, 0, 0, 0x1000, 0x1000, 0x140000000)
opt += struct.pack("<IIHHHHHHIIIIHHQQQQII", 0x1000, 0x200, 6, 0, 0, 0, 6, 0, 0, 0x2000, 0x400, 0, 3, 0x8160, 0x100000, 0x1000, 0x100000, 0x1000, 0, 0)
open(sys.argv[1], "wb").write(bytes(mz) + coff + opt + b"\0" * 0x400)
PY
  }
  mut_strip_reference() { # our gui-agent.exe with its version resource stripped, as an extra bin/ file
    python3 - "$1/reference/gui-agent.exe" "$1/bin/gui-agent-stripped.exe" <<'PY'
import struct, sys
src, dst = sys.argv[1:3]
data = bytearray(open(src, "rb").read())
e = struct.unpack_from("<I", data, 0x3C)[0]; opt = e + 24
magic = struct.unpack_from("<H", data, opt)[0]
dd = opt + (112 if magic == 0x20B else 96) + 2 * 8
struct.pack_into("<II", data, dd, 0, 0)
open(dst, "wb").write(bytes(data))
PY
  }
  set_inf_driverver() { # $1=inf $2=version
    python3 - "$1" "$2" <<'PY'
import re, sys
p, ver = sys.argv[1:3]; raw = open(p, "rb").read()
enc = "utf-16le" if raw[:2] == b"\xff\xfe" else "utf-8"
bom = raw[:2] if enc == "utf-16le" else b""
txt = raw[len(bom):].decode(enc)
txt = re.sub(r"(DriverVer\s*=\s*[0-9/]+\s*,\s*)[0-9.]+", r"\g<1>" + ver, txt)
open(p, "wb").write(bom + txt.encode(enc))
PY
  }
  set_pe_version() { # $1=pe $2=version  (patches VS_FIXEDFILEINFO in place)
    python3 - "$1" "$2" <<'PY'
import os, sys
exec(os.environ["PE_READER"])
p, ver = sys.argv[1:3]
data = open(p, "rb").read()          # read FIRST: open(p, "wb") truncates before the argument is evaluated
patched = pe_set_fileversion(data, ver)
with open(p, "wb") as fh:
    fh.write(patched)
PY
  }
  mut_idd_inf()        { set_inf_driverver "$1/idd-driver/IddSampleDriver.inf" 9.9.9.9; }
  mut_xenvif_stockver(){ # .sys AND inf at the stock number, so 'not above stock' is the ONLY difference
    set_pe_version "$1/pv-drivers/xenvif.sys" 9.1.0.0
    set_inf_driverver "$1/pv-drivers/xenvif.inf" 9.1.0.0
  }
  mut_xenvif_stock()   { cp "$(stock_stream_with_stem xenvif)" "$1/pv-drivers/xenvif.sys"; }
  mut_strip_release_fields() { mut_json "$1" <<< 'm.pop("release_version", None); m.pop("build_rev", None)'; }
  mut_files_version()  { mut_json "$1" <<< 'm["files"]["bin/qrexec-wrapper.exe"]["version"] = "9.9.9.9"'; }
  mut_files_sha()      { mut_json "$1" <<< 'm["files"]["bin/qrexec-wrapper.exe"]["sha256"] = "0" * 64'; }
  mut_files_unlisted() { mut_json "$1" <<< 'del m["files"]["reference/gui-agent.exe"]'; }
  mut_files_missing()  { mut_json "$1" <<< 'm["files"]["bin/does-not-exist.exe"] = {"size": 1, "sha256": "0" * 64, "version": None}'; }
  mut_files_not_dict() { mut_json "$1" <<< 'm["files"] = ["not-an-object"]'; }
  mut_files_entry_bad(){ mut_json "$1" <<< 'm["files"]["bin/qrexec-wrapper.exe"] = "not-an-object"'; }
  mut_build_rev_vs_run() { # build_rev disagreeing with ci.run_number, everything else consistent
    mut_json "$1" <<< 'm["release_version"] = m["package_version"].split("+")[0]; m["build_rev"] = int(m["ci"]["run_number"]) + 1; m["source"]["core_agent_commit"] = "0" * 40'
  }

  if [ -n "$OPT_SELFTEST_TREE" ]; then
    echo "--- level 2: whole-verifier runs on mutated copies of $OPT_SELFTEST_TREE ---"
    if fixture_prep "$OPT_SELFTEST_TREE" tree; then
      local legacy_flag=()
      [ "$FX_LEGACY" = 1 ] && legacy_flag=(--legacy-manifest)
      run_case stale-build-commit               PROVENANCE_COMMIT_MISMATCH   mut_commit
      run_case unresolvable-commit              COMMIT_UNRESOLVABLE          mut_none --commit 0123456789abcdef0123456789abcdef01234567
      run_case stock-exe-at-claimed-path        STOCK_FALLBACK               mut_stock_in_bin
      run_case claimed-file-deleted             CLAIMED_MISSING              mut_claimed_deleted
      run_case unknown-pe-in-tree               UNCLASSIFIED_PE              mut_unknown_pe
      run_case stock-pe-loose-in-tree           UNEXPECTED_STOCK_PE          mut_stock_stray
      run_case stripped-version-resource        VERSION_UNSTAMPED            mut_strip_reference
      # wrong build_rev: the fixture's own rev + 1 (legacy stays as the fixture requires: a legacy
      # manifest has no build_rev to disagree with, a stamped one is run strictly)
      run_case wrong-build-rev                  OURS_VERSION_MISMATCH        mut_none --build-rev "$((FX_REV + 1))"
      run_case idd-inf-disagrees-with-dll       IDD_INF_MISMATCH             mut_idd_inf
      run_case xenvif-not-above-stock           PV_DRIVERVER_NOT_ABOVE_STOCK mut_xenvif_stockver
      run_case stock-xenvif-in-pv-drivers       PV_NOT_OURS                  mut_xenvif_stock
      run_case manifest-files-version-wrong     MANIFEST_FILE_VERSION        mut_files_version
      run_case manifest-files-sha-wrong         FILE_SHA_MISMATCH            mut_files_sha
      run_case manifest-files-ours-unlisted     COMPONENT_UNLISTED           mut_files_unlisted
      run_case manifest-files-lists-absent-file FILE_MISSING                 mut_files_missing
      run_case manifest-files-not-an-object     MANIFEST_NO_FILES            mut_files_not_dict
      run_case manifest-files-entry-not-object  MANIFEST_FILE_ENTRY_BAD      mut_files_entry_bad
      run_case build-rev-vs-run-number          BUILD_REV_RUN_NUMBER_MISMATCH mut_build_rev_vs_run --build-rev "$(python3 -c "import json,sys;print(int(json.load(open(sys.argv[1],encoding='utf-8-sig'))['ci']['run_number'])+1)" "$src/MANIFEST.json")"
      run_case marker-absent                    MARKER_ABSENT                mut_none --require-marker "nonesuch=THIS_STRING_IS_IN_NO_BINARY_0x5f3759df"
      # strict mode on a manifest without release fields must refuse, never default
      RUN_ARGS_OVERRIDE="--commit $FX_SHA" run_case no-release-fields-strict RELEASE_FIELDS_MISSING mut_strip_release_fields
      # the tool-broke detectors, by breaking the tool on purpose
      VERIFY_INJECT_FAULT=crash     run_case analyser-crash                ANALYSER_CRASHED  mut_none
      VERIFY_INJECT_FAULT=omit-gate run_case analyser-omits-a-gate         GATES_INCOMPLETE  mut_none
      # the positive direction: the version gate can PASS a correctly stamped file. reference/
      # gui-agent.exe reads <rel>.<fixture rev> (read from the binary, not assumed) and must be
      # marked ok in the OURS_VERSION detail of the baseline.
      if printf '%s\n' "$baseline_out" | grep -E "^  (MISMATCH|UNSTAMPED) +tree:reference/gui-agent.exe" >/dev/null; then
        st_bad "positive-direction: reference/gui-agent.exe reported as not matching $FX_REL.$FX_REV"
      elif printf '%s\n' "$baseline_out" | grep -E "^  ok +tree:reference/gui-agent.exe" >/dev/null; then
        st_ok "positive-direction: reference/gui-agent.exe reads $FX_REL.$FX_REV and is accepted"
      else
        st_bad "positive-direction: reference/gui-agent.exe not found in the OURS_VERSION detail"
      fi
      # the legacy knob must be the ONLY way a legacy fixture is accepted for identity checks
      if [ "$FX_LEGACY" = 1 ]; then
        st_ok "fixture is LEGACY (no release_version/build_rev): version-gate cases above are expected NOT PROVEN until the first stamped package"
      fi
    fi
  fi

  if [ -n "$OPT_SELFTEST_ASSETS" ]; then
    echo "--- level 3: whole-verifier runs on mutated copies of the closed asset set $OPT_SELFTEST_ASSETS ---"
    if fixture_prep "$OPT_SELFTEST_ASSETS" assets; then
      local other_iso=""
      mut_loose_exe()      { cp "$1/MANIFEST.json" "$1/gui-agent.exe"; }
      mut_sums_drop_iso()  { local s="$1/SHA256SUMS.txt"; grep -v -- '\.iso$' "$s" > "$s.new"; mv "$s.new" "$s"; }
      mut_sums_sig_only()  { local s="$1/SHA256SUMS.txt"; sed -i -E 's/(\.iso)$/\1.sig/' "$s"; }
      mut_sums_corrupt()   { local s="$1/SHA256SUMS.txt"; python3 - "$s" <<'PY'
import sys
p = sys.argv[1]; lines = open(p).read().splitlines(True)
h = lines[0][:64]; flipped = ("0" if h[0] != "0" else "1") + h[1:]
lines[0] = flipped + lines[0][64:]
open(p, "w").write("".join(lines))
PY
      }
      mut_exe_flip()       { local e; e="$(find "$1" -maxdepth 1 -name 'qubes-tools-*.exe' | head -1)"; printf 'X' | dd of="$e" bs=1 seek=78 count=1 conv=notrunc 2>/dev/null; }
      mut_manifest_asset() { mut_json "$1" <<< 'm["description"] = "asset manifest edited: no longer the ISO manifest"'; }
      mut_other_iso()      { cp "$other_iso" "$1/$(basename "$(find "$1" -maxdepth 1 -name '*.iso' | head -1)")"; }
      run_case asset-loose-exe               ASSET_UNEXPECTED        mut_loose_exe
      run_case asset-sums-uncovered-iso      ASSET_SUMS_INCOMPLETE   mut_sums_drop_iso
      run_case asset-sums-sig-line-only      ASSET_SUMS_INCOMPLETE   mut_sums_sig_only
      run_case asset-sums-corrupt            ASSET_SUMS              mut_sums_corrupt
      run_case asset-exe-differs-from-iso    EXE_ASSET_MISMATCH      mut_exe_flip
      run_case asset-manifest-not-iso-manifest ISO_MANIFEST_MISMATCH mut_manifest_asset
      # a DIFFERENT iso substituted for the asset: the RPM embeds the real one
      other_iso="${SELFTEST_OTHER_ISO:-}"
      if [ -n "$other_iso" ] && [ -f "$other_iso" ]; then
        run_case asset-iso-substituted-rpm   RPM_ISO_MISMATCH        mut_other_iso
      else
        st_np "asset-iso-substituted-rpm -> RPM_ISO_MISMATCH: needs SELFTEST_OTHER_ISO=<a different qwt iso> in the environment"
      fi
      [ "$TAR_PRESENT" = 1 ] || echo "  (no *-setup.tar.gz in the fixture: SETUP_TAR has no fixture here - UNPROVEN)"
    fi
  fi

  echo
  if [ "$fails" -eq 0 ]; then echo "verify-release-package selftest: ALL PASS ($pass_n cases)"; return 0; fi
  echo "verify-release-package selftest: $fails FAILED ($pass_n passed, $notproven_n NOT PROVEN)"
  return 1
}

# ------------------------------------------------------------------------------ main
EXPECT_COMMIT="$OPT_COMMIT"
TAG_TARGET=""
WANT=""
ISO_SHA=""
RPM_VR=""
M_SHA=""; M_AGENT=""; M_REL=""; M_REV=""; M_PKGVER=""; M_RUN=""; M_COREAGENT=""; M_HAS_REL=""; M_HAS_REV=""
FX_SHA=""; FX_REL=""; FX_REV=""; FX_LEGACY=""

cleanup() {
  if [ "$OPT_KEEP" != 1 ]; then
    rm_rf "$WORK/stock-payload" "$WORK/msi-payload" "$WORK/iso" "$WORK/setup-tar" "$WORK/rpm" "$WORK/tree" "$WORK/assets"
    rm_rf "$WORK"/case-* "$WORK"/run-* "$WORK"/run-baseline
  fi
}
trap cleanup EXIT

if [ "$MODE" = selftest ]; then
  echo "=== verify-release-package selftest (work: $WORK)"
  selftest; rc=$?
  exit $rc
fi

echo "=== verify-release-package: mode=$MODE target=${TARGET} (work: $WORK)"
[ -z "$EXPECT_COMMIT" ] && [ "$MODE" != tag ] && EXPECT_COMMIT=HEAD

need_tools 7z cabextract python3 sha256sum strings git realpath || finish
case "$MODE" in
  iso|assets|tag) need_tools xorriso cmp || finish ;;
esac
if [ "$MODE" = tag ]; then need_tools gh || finish; gh_slug || { gate_fail PREREQ PREREQ_MISSING "what=github_origin_remote"; finish; }; fi
[ -x "$REPO/tools/assert-payload.sh" ] || { gate_fail PREREQ PREREQ_MISSING "file=tools/assert-payload.sh"; finish; }

prepare_stock || finish

case "$MODE" in
  tree)
    T="$TARGET"
    if [ -f "$T" ]; then
      rm_rf "$WORK/tree"; mkdir -p "$WORK/tree"
      tar -xzf "$T" -C "$WORK/tree" 2>/dev/null || { gate_fail INPUT TAR_EXTRACT_FAILED "tar=$T"; finish; }
      tm="$(find "$WORK/tree" -maxdepth 2 -name MANIFEST.json | head -1)"
      [ -n "$tm" ] || { gate_fail INPUT INPUT_MISSING "path=$TARGET" "reason=no_MANIFEST.json_in_tarball"; finish; }
      T="$(dirname "$tm")"
    fi
    [ -d "$T" ] || { gate_fail INPUT INPUT_MISSING "path=$TARGET"; finish; }
    verify_tree "$T"
    ;;
  iso)
    [ -f "$TARGET" ] || { gate_fail INPUT INPUT_MISSING "path=$TARGET"; finish; }
    if ! extract_iso "$TARGET" "$WORK/iso"; then gate_fail ISO_IDENTITY ISO_EXTRACT_FAILED "iso=$TARGET"; finish; fi
    ISO_SHA="$(sha256_of "$TARGET")"
    echo "  iso sha256      : $ISO_SHA"
    verify_tree "$WORK/iso"
    ;;
  assets)
    [ -d "$TARGET" ] || { gate_fail INPUT INPUT_MISSING "path=$TARGET"; finish; }
    verify_assets "$TARGET"
    ;;
  tag)
    # PUBLISHED assets: download the release back and verify THAT - the bytes a user gets. A
    # successful download is not a gate (ASSET_SET judges what arrived); a failed one is.
    A="$WORK/assets"; rm_rf "$A"; mkdir -p "$A"
    if ! gh release download "$TARGET" -R "$GH_SLUG" -D "$A" 2>"$WORK/gh-download.err"; then
      gate_fail PUBLISHED_SET GH_DOWNLOAD_FAILED "tag=$TARGET" "repo=$GH_SLUG" "err=$(tr -s ' \n' '_' < "$WORK/gh-download.err" | cut -c1-120)"
      finish
    fi
    # TAG_TARGET: the tag resolves to a commit, and the release's target is that commit (a sha) or
    # a branch the commit is on. The tag commit is then PROVENANCE's expectation: the manifest's
    # build commit must BE it - "is an ancestor of it" was deleted because the stale d69aff9f
    # package is an ancestor of the v4.3.21 tag commit exactly as the correct 3245867 is.
    git -C "$REPO" fetch origin --tags --quiet 2>/dev/null || gate_fail TAG_FETCH FETCH_FAILED "remote=origin"
    rv="$(gh release view "$TARGET" -R "$GH_SLUG" --json targetCommitish,isDraft -q '[.targetCommitish,(.isDraft|tostring)]|join(" ")' 2>/dev/null)" || rv=""
    tagc="$(git -C "$REPO" rev-list -n1 "refs/tags/$TARGET" 2>/dev/null)" || tagc=""
    if [ -z "$rv" ]; then
      gate_fail TAG_TARGET GH_UNAVAILABLE "tag=$TARGET" "repo=$GH_SLUG"
    elif [ -z "$tagc" ]; then
      gate_fail TAG_TARGET TAG_TARGET_UNRESOLVABLE "tag=$TARGET" "hint=git_fetch_origin_--tags"
    else
      read -r tgt draft <<< "$rv"
      if [[ "$tgt" =~ ^[0-9a-f]{40}$ ]]; then
        if [ "$tgt" = "$tagc" ]; then TAG_TARGET="$tagc"; gate_pass TAG_TARGET "target=${tagc:0:12}" "draft=$draft"
        else gate_fail TAG_TARGET TAG_TARGET_MISMATCH "tag=${tagc:0:12}" "release_target=${tgt:0:12}"; fi
      elif git -C "$REPO" rev-parse --verify --quiet "refs/remotes/origin/$tgt" >/dev/null 2>&1; then
        if git -C "$REPO" merge-base --is-ancestor "$tagc" "refs/remotes/origin/$tgt"; then
          TAG_TARGET="$tagc"; gate_pass TAG_TARGET "target=${tagc:0:12}" "branch=$tgt" "draft=$draft"
        else
          gate_fail TAG_TARGET TAG_TARGET_MISMATCH "tag=${tagc:0:12}" "not_on=origin/$tgt"
        fi
      else
        gate_fail TAG_TARGET TAG_TARGET_UNRESOLVABLE "release_target=$tgt"
      fi
    fi
    verify_assets "$A"
    ;;
esac
finish
