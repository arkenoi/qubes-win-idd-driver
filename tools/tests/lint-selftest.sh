#!/bin/bash
# SELF-TEST for tools/lint-harness.py — every lint must be SEEN TO FIRE.
#
# H5 applied to the linter. A lint that has never gone red is exactly the unproven check the
# linter exists to find; shipping one would be the same disease one level up. So: build a fixture
# tree containing a deliberate violation of each rule, run the lints against it, and require the
# matching lint to appear. Then build a CLEAN fixture and require silence, so a lint that fires
# unconditionally is caught too.
#
#   tools/tests/lint-selftest.sh
set -uo pipefail
cd /home/user/qubes-win-idd-driver
LINT=tools/lint-harness.py
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ echo "  PASS  $*"; pass=$((pass+1)); }
no(){ echo "  FAIL  $*"; fail=$((fail+1)); }

mk(){ # <dir> — a minimal tree the lints can walk
  mkdir -p "$1/mgmt/harness" "$1/guest" "$1/agent/gui-agent"
  printf '#!/bin/bash\n: clean\n' > "$1/mgmt/harness/clean.sh"
}

expect_fires(){ # <lint-id> <fixture-dir> <what was planted>
  local id="$1" dir="$2" what="$3"
  # CAPTURE FIRST. `set -o pipefail` + a linter that EXITS 1 ON FINDINGS means
  # `lint | grep -q` reports the LINT's status, not grep's - so every case "failed" while the
  # lint was in fact firing correctly. Found 2026-08-31 while writing this very self-test.
  local out; out=$(python3 "$LINT" --root "$dir" --quiet 2>&1)
  if echo "$out" | grep -q "^$id"; then
    ok "$id fires on: $what"
  else
    no "$id did NOT fire on: $what  <-- the lint cannot detect its own target"
  fi
}

# ---------------------------------------------------------------- L1 double background
D="$TMP/l1"; mk "$D"
printf '#!/bin/bash\nnohup bash runner.sh &\n' > "$D/mgmt/harness/bad.sh"
expect_fires L1-double-background "$D" "nohup ... &"

# ---------------------------------------------------------------- L2 missing vmlock
D="$TMP/l2"; mk "$D"
printf '#!/bin/bash\nVM=$1\n./tools/qtest run "echo hi"\n' > "$D/mgmt/harness/bad.sh"
expect_fires L2-missing-vmlock "$D" "drives a guest with no vm_lock"

# ---------------------------------------------------------------- L3 nested-quote powershell
D="$TMP/l3"; mk "$D"
cat > "$D/mgmt/harness/bad.sh" <<'EOS'
#!/bin/bash
r 'cmd /c powershell -NoProfile -Command "$x=(Get-Item \"C:\a\").Name; Write-Output $x"'
EOS
expect_fires L3-nested-quote-powershell "$D" "escaped quotes inside -Command"

# ---------------------------------------------------------------- L4 check that cannot fail
D="$TMP/l4"; mk "$D"
cat > "$D/mgmt/harness/bad.sh" <<'EOS'
#!/bin/bash
printf 'CELL\tnever-fails\tPASS-UNPROVEN\tlooks good\t%s\n' "$EV" >> "$V"
EOS
expect_fires L4-check-cannot-fail "$D" "a check emitted only from a PASS branch"

# ---------------------------------------------------------------- L5 injector string collision
D="$TMP/l5"; mk "$D"
cat > "$D/agent/gui-agent/faultinject.c" <<'EOS'
void FiThing(void){ LogWarning("QGAFAULT firing: the capture thread returns WITHOUT signalling"); }
EOS
cat > "$D/mgmt/harness/bad.sh" <<'EOS'
#!/bin/bash
psrun 'Select-String -Pattern "capture thread|thread exiting"'
EOS
expect_fires L5-injector-collision "$D" "a grep pattern the injector also logs"

# ---------------------------------------------------------------- L6 probe null-deref
D="$TMP/l6"; mk "$D"
cat > "$D/guest/probe.ps1" <<'EOS'
[pscustomobject]@{
    sha = (Get-FileHash 'C:\missing.ps1' -Algorithm SHA256).Hash.ToLower()
} | ConvertTo-Json -Compress
EOS
expect_fires L6-probe-null-deref "$D" "chained access on a cmdlet that can return null"

# ---------------------------------------------------------------- L7 orphan ledger check
D="$TMP/l7"; mk "$D"
printf 'CELL\tnobody-emits-this\tPASS-UNPROVEN\tdetail\tEV\n' > "$TMP/led.tsv"
l7out=$(python3 "$LINT" --root "$D" --ledger "$TMP/led.tsv" --quiet 2>&1)
if echo "$l7out" | grep -q '^L7-orphan-ledger-check'; then
  ok "L7-orphan-ledger-check fires on: a ledger name no harness emits"
else
  no "L7-orphan-ledger-check did NOT fire  <-- the lint cannot detect its own target"
fi

# ---------------------------------------------------------------- the NEGATIVE control
# A lint that fires on everything is as useless as one that never fires. A clean tree must be
# silent, or every finding above is meaningless.
D="$TMP/clean"; mk "$D"
cat > "$D/mgmt/harness/good.sh" <<'EOS'
#!/bin/bash
VM="$1"
source mgmt/harness/vmlock.sh; vm_lock "$VM"
./tools/qtest run 'cmd /c echo ok'
printf 'CELL\tproper-check\tPASS-UNPROVEN\tgood\t%s\n' "$EV" >> "$V"
printf 'CELL\tproper-check\tFAIL\tbad\t%s\n' "$EV" >> "$V"
EOS
cat > "$D/guest/probe.ps1" <<'EOS'
$h = $(if (Test-Path 'C:\x.ps1') { (Get-FileHash 'C:\x.ps1' -Algorithm SHA256).Hash.ToLower() } else { $null })
[pscustomobject]@{ sha = $h } | ConvertTo-Json -Compress
EOS
out=$(python3 "$LINT" --root "$D" --quiet 2>&1)
if echo "$out" | grep -q '^CLEAN'; then
  ok "negative control: a compliant tree produces NO findings"
else
  no "negative control: a compliant tree produced findings:"; echo "$out" | sed 's/^/        /'
fi

echo
echo "  ---- $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
