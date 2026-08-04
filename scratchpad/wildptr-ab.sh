#!/bin/bash
# Interleaved rounds 2-3 of the wild-pointer A/B. Round 1 already ran:
#   ctl-unfixed 4DA9FE96 -> agent DIED (pid 3636->7112, 0 log growth)
#   fixed       F06C0979 -> survived  (same pid 824, +115 lines)
set -u
cd /home/user/qubes-win-idd-driver
INC='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
OUT=/tmp/claude-1000/-home-user-qubes-win-idd-driver/af572f4c-9813-43a7-b2fc-a1299d189356/scratchpad/wildptr-ab.txt
: > "$OUT"

side() { # $1=label $2=srcname $3=hash
  local tag=$1 src=$2 hash=$3
  timeout 90 ./tools/qtest ps "& '$INC\\install-agent2.ps1' -SrcName $src -ExpectHash $hash" 2>&1 \
    | tr -d '\r' | grep -E '^INSTALL=' >> "$OUT"
  if ! grep -q "hash=$hash" "$OUT"; then echo "$tag: FAIL install" | tee -a "$OUT"; return 1; fi
  bash scratchpad/vmcycle.sh >/dev/null 2>&1 || { echo "$tag: FAIL vmcycle" | tee -a "$OUT"; return 1; }
  sleep 15
  echo "=== $tag ===" >> "$OUT"
  timeout 250 ./tools/qtest ps "& '$INC\\wildptr2.ps1' -Which $tag -ExpectHash $hash" 2>&1 \
    | tr -d '\r' | grep -E '^STEP|^RESULT' >> "$OUT"
  echo "$tag: $(grep -h '^RESULT' "$OUT" | tail -1)"
}

for r in 2 3; do
  side "ctl-r$r"   gui-agent.exe        4DA9FE967A8A1012
  side "fixed-r$r" gui-agent-fixed3.exe F06C0979A98E4442
done
echo "--- all ---"; grep -E '^RESULT' "$OUT"
