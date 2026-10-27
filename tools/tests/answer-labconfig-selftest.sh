#!/bin/bash
# A WINDOWS 11 ANSWER FILE MUST CARRY THE BYPASS KEYS, NOT THE WORD "LabConfig".
# run: tools/tests/answer-labconfig-selftest.sh
# pass: exit 0
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 2
T=$(mktemp -d "${TMPDIR:-/tmp}/labcfg-XXXXXX"); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "ok   $1"; }
no(){ FAIL=$((FAIL+1)); echo "FAIL $1"; printf '       -> %s\n' "${2:-}"; }

blk=$(awk '/# ANSWER-LABCONFIG-A/,/# ANSWER-LABCONFIG-B/' mgmt/build-answer-stick.sh)
if [ -n "$blk" ] && printf '%s' "$blk" | command grep -qa 'BypassTPMCheck'; then
  ok "the guard was extracted from build-answer-stick.sh"
else
  echo "FATAL: could not extract the LabConfig guard"; exit 2
fi

judge(){ # $1=file contents -> "rc=<n> <output>"
  mkdir -p "$T/w"; printf '%s' "$1" > "$T/w/Autounattend.xml"
  local out rc
  out=$(bash -c 'WORK="$1"; HERE=mgmt; IMG_NAME="Windows 11 Pro"; eval "$2"; echo PASSED-THE-GUARD' _ "$T/w" "$blk" 2>&1); rc=$?
  printf 'rc=%s %s' "$rc" "$(printf '%s' "$out" | tr '\n' ' ')"
}

# the real templates must pass, all three of them
for f in mgmt/autounattend-win11.xml mgmt/autounattend-win11-de.xml mgmt/autounattend-win11-static.xml; do
  got=$(judge "$(cat "$f")")
  case "$got" in
    rc=0*PASSED-THE-GUARD*) ok "the shipped $(basename "$f") passes" ;;
    *) no "the shipped $(basename "$f") was refused" "$got" ;;
  esac
done

# the case the old guard passed: the word, with none of the keys
got=$(judge '<!-- LabConfig bypasses are handled elsewhere -->
<unattend><settings pass="windowsPE"></settings></unattend>')
case "$got" in
  rc=1*"missing the LabConfig bypass key"*) ok "a file that only MENTIONS LabConfig is REFUSED, naming the missing keys" ;;
  *) no "the word alone still passes" "$got - this is the defect"; ;;
esac

# an empty LabConfig component - present, named, and useless
got=$(judge '<unattend><settings><component name="Microsoft-Windows-LabConfig"></component></settings></unattend>')
case "$got" in
  rc=1*missing*) ok "an EMPTY LabConfig component is refused" ;;
  *) no "an empty LabConfig component passed" "$got" ;;
esac

# one key short is still refused, and the message names WHICH
got=$(judge '<LabConfig><BypassTPMCheck>1</BypassTPMCheck><BypassSecureBootCheck>1</BypassSecureBootCheck><BypassRAMCheck>1</BypassRAMCheck></LabConfig>')
case "$got" in
  rc=1*BypassStorageCheck*) ok "one missing key is refused and NAMED (BypassStorageCheck)" ;;
  *) no "a file missing one key was accepted or the message did not name it" "$got" ;;
esac

# and a non-Windows-11 image is not subjected to it (the case runs only for *"Windows 11"*)
got=$(bash -c 'WORK="$1"; HERE=mgmt; IMG_NAME="Windows 10 Pro"
  case "$IMG_NAME" in *"Windows 11"*) eval "$2" ;; esac
  echo PASSED-THE-GUARD' _ "$T/w" "$blk" 2>&1)
case "$got" in
  *PASSED-THE-GUARD*) ok "a Windows 10 image is not subjected to the Windows 11 bypass guard" ;;
  *) no "the guard fired for a Windows 10 image" "$got" ;;
esac

# SEEN TO FAIL: the pre-fix guard accepts the word alone
got=$(bash -c 'WORK="$1"
  grep -q "LabConfig" "$WORK/Autounattend.xml" || exit 1
  echo PASSED-THE-GUARD' _ "$T/w" 2>&1)
printf '%s' '<!-- LabConfig mentioned only -->' > "$T/w/Autounattend.xml"
got=$(bash -c 'WORK="$1"
  grep -q "LabConfig" "$WORK/Autounattend.xml" || exit 1
  echo PASSED-THE-GUARD' _ "$T/w" 2>&1)
case "$got" in
  *PASSED-THE-GUARD*) ok "SEEN TO FAIL: the pre-fix word match accepts a file with no keys at all" ;;
  *) no "the pre-fix shape did not reproduce" "$got" ;;
esac

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
