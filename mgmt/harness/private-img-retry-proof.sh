#!/bin/bash
# private-img-retry-proof.sh - drive the private-image retry DELIBERATELY, instead of waiting for
# the race to be lost.
#
# WHY THIS EXISTS. The stock MSI's PreparePrivateImg custom action is sequenced BEFORE it copies
# the script that action runs (measured 2026-09-14 from the MSI's own verbose log: action ends
# 20:17:38, FileCopy of prepare-private-img.ps1 lands 20:17:41, "No existing file"), and it
# returns 1 regardless. Win11 wins that race, win10 loses it - so the installer guard added in
# 91aafb5/b6d7a4b only fires on the losing side, and a campaign that happens to WIN the race
# reports "private image: Q:\ present after the MSI" and proves nothing about the retry.
#
# This project's own rule: a check counts as evidence only once it has been seen to FAIL on a
# build with the defect deliberately re-introduced. So: re-create the defect state (private disk
# back to RAW, Q: gone), run the installer, and require the guard to say it recovered.
#
# It asserts THREE things, in order, and any missing one FAILS:
#   1. the defect state was really established  - Q: gone AND disk partstyle RAW;
#   2. the guard SAW it                          - "Q:\ ABSENT after the MSI";
#   3. the guard FIXED it                        - "created by the retry" AND Q: present after.
# A run where Q: never disappeared is VOID, not a pass: it means the wipe failed and the guard
# was never asked the question.
#
# Usage:  VM=win11-nfy PKG=<setup-tree> mgmt/harness/private-img-retry-proof.sh
#         (any guest that already carries QWT; it is modified destructively and is not reusable
#          for a measurement afterwards)
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

VM="${VM:?set VM to a guest that already carries QWT}"
PKG="${PKG:?set PKG to the release setup tree under test}"
OUT="${PIRP_OUT:-scratchpad/private-img-retry/$VM-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"
pass=0; fail=0
say(){ echo "[$(date -u +%H:%M:%S)] $*"; }
ok(){  pass=$((pass+1)); say "PASS  $*"; }
no(){  fail=$((fail+1)); say "FAIL  $*"; }

source mgmt/harness/vmlock.sh
vm_lock "$VM"
trap 'vm_unlock "$VM"' EXIT

b64(){ python3 -c "import sys,base64;print(base64.b64encode(sys.argv[1].encode('utf-16-le')).decode())" "$1"; }
gps(){ QTEST_VM=$VM timeout -k 5 "${2:-120}" ./tools/qtest run "powershell -NoProfile -EncodedCommand $(b64 "$1")" 2>/dev/null | tr -d '\r'; }

# ---- 1. establish the defect state ------------------------------------------------------------
say "wiping the private image back to RAW (this is destructive and deliberate)"
gps '$d = Get-Disk | Where-Object { $_.Size -gt 15GB -and $_.Size -lt 25GB } | Select-Object -First 1
if (-not $d) { Write-Host "WIPE=no-candidate-disk"; exit }
try { Clear-Disk -Number $d.Number -RemoveData -RemoveOEM -Confirm:$false -EA Stop; Write-Host "WIPE=cleared" }
catch { Write-Host ("WIPE=failed " + $_.Exception.Message) }' 200 | grep -a '^WIPE=' | sed 's/^/    /'

st=$(gps '$q = Test-Path -LiteralPath "Q:\"
$d = Get-Disk | Where-Object { $_.Size -gt 15GB -and $_.Size -lt 25GB } | Select-Object -First 1
Write-Host ("STATE=Q:" + $q + " partstyle=" + $(if ($d) { $d.PartitionStyle } else { "none" }))' | grep -a '^STATE=')
say "  after wipe: $st"
case "$st" in
  *"Q:False"*RAW*) ok "defect state established: Q: gone and the private disk is RAW" ;;
  *) no "VOID - could not establish the defect state ($st); the guard was never asked the question"
     say "=== private-img retry proof: $pass passed, $fail failed ==="; exit 1 ;;
esac

# ---- 2+3. run the installer and require the guard to see it AND fix it -------------------------
say "running the installer over the wiped guest"
QTEST_VM=$VM timeout -k 5 300 ./tools/qtest push "$PKG"/Install-QwtImproved.ps1 >/dev/null 2>&1
INC='C:\Users\user\Documents\QubesIncoming\'$(hostname)
gps "& '$INC\\Install-QwtImproved.ps1' -Auto -Stage 2 2>&1 | Select-Object -Last 40" 1800 >"$OUT/install.out" 2>&1 || true
grep -aE "private image:" "$OUT/install.out" | sed 's/^/    /' | head -6

if grep -qa "private image: Q:\\\\ ABSENT after the MSI" "$OUT/install.out"; then
  ok "the guard SAW the missing private image"
else
  no "the guard did not report the missing private image - it either never ran or never looked"
fi

post=$(gps 'Write-Host ("POST=Q:" + (Test-Path -LiteralPath "Q:\"))' | grep -a '^POST=')
say "  after install: $post"
if grep -qa "created by the retry" "$OUT/install.out" && [ "$post" = "POST=Q:True" ]; then
  ok "the guard CREATED the private image (Q: present after the retry)"
elif grep -qa "the private image is not available as Q:" "$OUT/install.out"; then
  no "the guard failed the install loudly - correct refusal, but the retry did not work; see $OUT/install.out"
else
  no "no retry outcome recorded and Q: is ${post#POST=} - see $OUT/install.out"
fi

say "evidence: $OUT"
say "=== private-img retry proof: $pass passed, $fail failed ==="
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
