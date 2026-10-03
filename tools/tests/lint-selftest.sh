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
cd "$(dirname "$0")/../.."   # the checkout this selftest lives in (a worktree included), not a fixed path
LINT=tools/lint-harness.py
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok(){ echo "  PASS  $*"; pass=$((pass+1)); }
no(){ echo "  FAIL  $*"; fail=$((fail+1)); }

mk(){ # <dir> — a minimal tree the lints can walk
  mkdir -p "$1/mgmt/harness" "$1/guest" "$1/agent/gui-agent"
  printf '#!/bin/bash\n: clean\n' > "$1/mgmt/harness/clean.sh"
}

expect_silent(){ # <lint-id> <fixture-dir> <what was planted> - a lint that fires on the
  # CORRECT shape is as useless as one that never fires; this is the other half of the proof.
  local id="$1" dir="$2" what="$3"
  local out; out=$(python3 "$LINT" --root "$dir" --quiet 2>&1)
  if echo "$out" | grep -q "^$id"; then
    no "$id fired on the CORRECT shape: $what  <-- false positive"
  else
    ok "$id stays silent on: $what"
  fi
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

# ---------------------------------------------------------------- L9 shutdown --wait kills
D="$TMP/l9"; mk "$D"
printf '#!/bin/bash\n# a COMMENT naming qvm-shutdown --wait must NOT fire\ntimeout 300 qvm-shutdown --wait "$VM"\n' > "$D/mgmt/harness/bad.sh"
expect_fires L9-shutdown-wait-kills "$D" "timeout 300 qvm-shutdown --wait (kills at 60)"

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

# ---------------------------------------------------------------- L11 absent guest command
# 2026-09-21: a boot-time classifier shipped reading `wmic`, which Windows 11 24H2+ does not have,
# so it could never have returned a value and every verdict on it was decoration.
D="$TMP/l11"; mk "$D"
printf '#!/bin/bash\nVM=$1\nsource mgmt/harness/vmlock.sh; vm_lock "$VM"\nb=$(tools/qtest run "cmd /c wmic os get lastbootuptime /value")\n' > "$D/mgmt/harness/bad.sh"
expect_fires L11-absent-guest-command "$D" "a guest probe built on wmic"
# ...and in a python tool, which is where the second copy lived and where no lint was looking.
D="$TMP/l11b"; mk "$D"; mkdir -p "$D/tools"
printf 'cmd = ["tools/qtest", "run", "cmd /c wmic os get lastbootuptime /value"]\n' > "$D/tools/judge.py"
expect_fires L11-absent-guest-command "$D" "the same command inside a python tool"

# ---------------------------------------------------------------- the NEGATIVE control
# L16: a catch-block local that differs only in case from a $script: name (the 2026-10-02 `$st` that silenced the updater's remedy)
D="$TMP/l16"; mk "$D"
cat > "$D/guest/upd.ps1" <<'EOS'
$script:St = [ordered]@{ phase='init' }
try { throw 'x' } catch {
  $st = "$($_.ScriptStackTrace)"
}
EOS
expect_fires L16-ps-script-scope-case-collision "$D" 'a local $st beside $script:St'
D="$TMP/l16ok"; mk "$D"
cat > "$D/guest/upd.ps1" <<'EOS'
$script:St = [ordered]@{ phase='init' }
$warn = 0
function Bump { $script:warn++ }
try { throw 'x' } catch { $stackText = "$($_.ScriptStackTrace)" }
EOS
expect_silent L16-ps-script-scope-case-collision "$D" 'same-case script-level reuse and a distinct local name'

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
# ---------------------------------------------------------------- L12 provisioning recipe
# Three ways the recipe was actually broken, each planted on its own so one cannot mask another.
D="$TMP/l12a"; mk "$D"
printf '#!/bin/bash\nqvm-device block assign -o frontend-dev=xvdi -o devtype=disk "$VM" holder:loop0\n' > "$D/mgmt/harness/bad.sh"
expect_fires L12-provisioning-recipe "$D" "a block assign WITHOUT --required"

D="$TMP/l12b"; mk "$D"
printf '#!/bin/bash\nPRIME_ASSIGN_MODE="${PRIME_ASSIGN_MODE:-plain}"\n' > "$D/mgmt/harness/bad.sh"
expect_fires L12-provisioning-recipe "$D" "a default selecting the plain assignment mode"

D="$TMP/l12c"; mk "$D"
printf '#!/bin/bash\nqvm-device block attach --ro -o devtype=cdrom "$VM" holder:loop0\n' > "$D/mgmt/harness/bad.sh"
expect_fires L12-provisioning-recipe "$D" "a LIVE cdrom attach (qubesd refuses it)"

D="$TMP/l12ok"; mk "$D"
printf '#!/bin/bash\nqvm-device block assign --required -o frontend-dev=xvdi -o devtype=disk "$VM" holder:loop0\n' > "$D/mgmt/harness/good.sh"
expect_silent L12-provisioning-recipe "$D" "the recipe shape: assign --required"

# ---------------------------------------------------------------- L17 process killed or adopted by NAME (owner 2026-10-03, ADR-updater 12.4)
# One fixture per shape, each planted alone. No packaging/make-setup.ps1 in these fixtures, so every guest/*.ps1 counts as shipped.
D="$TMP/l17a"; mk "$D"; printf 'Stop-Process -Name foo -Force -EA SilentlyContinue\n' > "$D/guest/upd.ps1"
expect_fires L17-process-by-name "$D" "Stop-Process -Name"
D="$TMP/l17b"; mk "$D"; printf 'Get-Process qubes-updates-relay -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue\n' > "$D/guest/upd.ps1"
expect_fires L17-process-by-name "$D" "Get-Process <name> | Stop-Process (the old Ensure-Proxy respawn)"
D="$TMP/l17c"; mk "$D"; printf 'Get-Process qubes-updates-relay -EA SilentlyContinue | ForEach-Object { $_.Kill() }\n' > "$D/guest/upd.ps1"
expect_fires L17-process-by-name "$D" "Get-Process <name> | ForEach-Object { .Kill() } (the old Remove-Proxy)"
D="$TMP/l17d"; mk "$D"; printf '& taskkill.exe /F /IM foo.exe *>$null\n' > "$D/guest/upd.ps1"
expect_fires L17-process-by-name "$D" "taskkill /im"
D="$TMP/l17e"; mk "$D"; printf 'if (-not (Get-Process qubes-updates-relay -EA SilentlyContinue)) { Start-Relay }\n' > "$D/guest/upd.ps1"
expect_fires L17-process-by-name "$D" "existence by name decides whether to start our own (the old Ensure-Proxy adoption)"
D="$TMP/l17f"; mk "$D"
cat > "$D/guest/upd.ps1" <<'EOS'
foreach ($p in @(Get-Process qubes-updates-relay -EA SilentlyContinue)) {
    $rp = $p
    try { $rp.Kill() } catch { }
}
EOS
expect_fires L17-process-by-name "$D" "a variable bound by a by-name lookup, aliased, then .Kill()ed (the old dead-pass cleanup)"
D="$TMP/l17g"; mk "$D"; printf '$script:Relay = Get-Process qubes-updates-relay -EA SilentlyContinue\n' > "$D/guest/upd.ps1"
expect_fires L17-process-by-name "$D" "a by-name lookup retained as script state (adoption)"
D="$TMP/l17h"; mk "$D"
cat > "$D/guest/upd.ps1" <<'EOS'
$running = @(Get-Process qubes-updates-relay -EA SilentlyContinue)
if ($running.Count -eq 0) {
    Log 'starting'
    Start-Process foo.exe
}
EOS
expect_fires L17-process-by-name "$D" "a by-name count gating a start across lines (adoption)"
D="$TMP/l17i"; mk "$D"; printf 'Get-WmiObject Win32_Process -Filter "Name = ''foo.exe''" | ForEach-Object { $_.Terminate() }\n' > "$D/guest/upd.ps1"
expect_fires L17-process-by-name "$D" "a Win32_Process selected by Name and Terminate'd"
# ...and the shapes that are neither kill nor adopt: counting, waiting, by handle, by id, a start gated on something else
D="$TMP/l17ok"; mk "$D"
cat > "$D/guest/upd.ps1" <<'EOS'
$ti = @(Get-Process TiWorker, TrustedInstaller -EA SilentlyContinue).Count
while ((Get-Date) -lt $q) {
  $tiw = @(Get-Process TiWorker -EA SilentlyContinue)
  if ($tiw.Count -eq 0) { break }
  try { [void]$tiw[0].WaitForExit($ms) } catch { Start-Sleep -Seconds 10 }
}
$me = Get-Process -Id $PID -EA SilentlyContinue
$p = Start-Process -FilePath $exe -ArgumentList '--listen' -PassThru
$script:OwnRelay = $p
$p.Kill(); [void]$p.WaitForExit(10000)
Stop-Process -Id $ownerPid -Force
if (-not (Test-RelayListening)) { Start-Relay }
# a comment naming Get-Process foo | Stop-Process must not fire
EOS
expect_silent L17-process-by-name "$D" "counting and waiting on a by-name process, kill by handle, kill by id, a start gated on a probe, a comment"
# SCOPE: with a packaging/make-setup.ps1 present only the updater payload it names is linted (the other shipped scripts are out of
# scope this time - see the lint's docstring for the sites that still kill by name)
D="$TMP/l17scope"; mk "$D"; mkdir -p "$D/packaging"
cat > "$D/packaging/make-setup.ps1" <<'EOS'
foreach ($u in 'shipped.ps1', 'qubes-windows-update.ps1',
               'other.ps1') {
    Copy-Item (Need (Join-Path $RepoRoot "guest\$u") "updater agent payload ($u)") $OutDir -Force
}
EOS
printf 'Stop-Process -Name foo -Force\n' > "$D/guest/unshipped.ps1"
printf 'Write-Host ok\n' > "$D/guest/shipped.ps1"
expect_silent L17-process-by-name "$D" "a by-name kill in a guest script outside the make-setup updater payload"
printf 'Stop-Process -Name foo -Force\n' > "$D/guest/shipped.ps1"
expect_fires L17-process-by-name "$D" "the same kill inside the make-setup updater payload"

echo "  ---- $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
