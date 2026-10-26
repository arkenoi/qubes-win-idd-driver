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
# the POSIX shapes, added 2026-10-10 (owner: "PKILL IS HARD PROHIBITED FOREVER"). A pattern also
# matches the process doing the matching: a pgrep-fed kill loop killed my own tool shell twice in one
# hour, because my shell's command line carried the very text I was searching for.
D="$TMP/l17p1"; mk "$D"; printf '#!/bin/bash\npkill -f "qrexec-client-vm foo "\n' > "$D/mgmt/harness/h.sh"
expect_fires L17-process-by-name "$D" "pkill -f (prohibited outright)"
D="$TMP/l17p2"; mk "$D"; printf '#!/bin/bash\nkill $(pgrep -f matrix.sh)\n' > "$D/mgmt/harness/h.sh"
expect_fires L17-process-by-name "$D" "kill fed from a pattern match"
D="$TMP/l17p3"; mk "$D"; printf '#!/bin/bash\nfor p in $(pgrep -f thing); do kill "$p"; done\n' > "$D/mgmt/harness/h.sh"
expect_fires L17-process-by-name "$D" "for p in \$(pgrep ...); do kill"
D="$TMP/l17p4"; mk "$D"; printf '#!/bin/bash\nkillall gui-agent\n' > "$D/mgmt/harness/h.sh"
expect_fires L17-process-by-name "$D" "killall by name"
# and the half that is easy to get wrong: ADVICE about pkill must stay silent, or the lint teaches
# people to delete the warning (vmlock.sh and serial-rig-gate.sh both carry it)
D="$TMP/l17p5"; mk "$D"; printf '#!/bin/bash\necho "kill it BY PID with SIGTERM - never with pkill -f"\nsay "(never pkill -f)"\n' > "$D/mgmt/harness/h.sh"
expect_silent L17-process-by-name "$D" "advice about pkill inside a string is not a kill"
D="$TMP/l17p6"; mk "$D"; printf '#!/bin/bash\npend=$(pgrep -f "qrexec-client-vm foo ")\nfor pp in $pend; do [ "$(cat /proc/$pp/comm)" = qrexec-client-vm ] && kill -TERM "$pp"; done\n' > "$D/mgmt/harness/h.sh"
expect_silent L17-process-by-name "$D" "pids verified via /proc/<pid>/comm before the signal - the legal form"

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
# SCOPE: with a packaging/make-setup.ps1 present, EVERY script it ships is linted (widened 2026-10-03 from the updater payload
# alone): each single Copy-Item of a guest script, every foreach list (resolved against guest/ and packaging/setup/), all of
# packaging/setup/*.ps1, the core-agent rpc-services dir, the overlay installer. A guest script make-setup does not copy is
# not shipped and stays silent. One planted kill per covered file, each asserted BY FILE in the lint's output.
expect_fires_in(){ # <lint-id> <fixture-dir> <path-substring> <what was planted>
  local id="$1" dir="$2" path="$3" what="$4"
  local out; out=$(python3 "$LINT" --root "$dir" --quiet 2>&1)
  if echo "$out" | grep -q "^$id" && echo "$out" | grep -qF "$path"; then
    ok "$id fires in $path: $what"
  else
    no "$id did NOT fire in $path: $what  <-- a shipped file the lint does not cover"
  fi
}
D="$TMP/l17scope"; mk "$D"; mkdir -p "$D/packaging/setup" "$D/packaging/payload" "$D/core-agent/src/qubes-rpc-services"
cat > "$D/packaging/make-setup.ps1" <<'EOS'
foreach ($f in 'install.cmd', 'Install-QwtImproved.ps1', 'README.txt') {
    Copy-Item (Join-Path $setupSrc $f) $OutDir -Force
}
Copy-Item (Need (Join-Path $RepoRoot 'guest\single.ps1') 'a single-copy guest script') $OutDir -Force
foreach ($u in 'shipped.ps1', 'qubes-windows-update.ps1',
               'other.ps1') {
    Copy-Item (Need (Join-Path $RepoRoot "guest\$u") "updater agent payload ($u)") $OutDir -Force
}
foreach ($f in @(Get-ChildItem -LiteralPath $rpcSrcDir -File)) {
    Copy-Item $f.FullName $rpcSvcOut -Force
}
EOS
printf 'Stop-Process -Name foo -Force\n' > "$D/guest/unshipped.ps1"
printf 'Write-Host ok\n' > "$D/guest/shipped.ps1"
printf 'Write-Host ok\n' > "$D/guest/single.ps1"
printf 'Write-Host ok\n' > "$D/packaging/setup/Install-QwtImproved.ps1"
printf 'Write-Host ok\n' > "$D/packaging/payload/install-qwt-improved.ps1"
printf 'Write-Host ok\n' > "$D/core-agent/src/qubes-rpc-services/handler.ps1"
# WIDENED 2026-10-07 (owner: "why did you miss kill-by-name during the previous sweep?"): a guest script make-setup does
# NOT ship is still ours and is linted - until then this exact case asserted SILENCE, which is how every dev script kept
# its by-name kills through the 2026-10-03 sweep.
expect_fires_in L17-process-by-name "$D" "guest/unshipped.ps1" "a by-name kill in a guest script make-setup does not ship (every script of ours is linted now)"
printf 'Write-Host ok\n' > "$D/guest/unshipped.ps1"
printf 'Stop-Process -Name foo -Force\n' > "$D/guest/shipped.ps1"
expect_fires_in L17-process-by-name "$D" "guest/shipped.ps1" "a kill in a foreach-listed guest script (the updater payload)"
printf 'Write-Host ok\n' > "$D/guest/shipped.ps1"
printf 'Get-Process OneDrive -EA SilentlyContinue | Stop-Process -Force\n' > "$D/guest/single.ps1"
expect_fires_in L17-process-by-name "$D" "guest/single.ps1" "a kill in a single-Copy-Item guest script (quiet-desktop's shape)"
printf 'Write-Host ok\n' > "$D/guest/single.ps1"
cat > "$D/packaging/setup/Install-QwtImproved.ps1" <<'EOS'
foreach ($pr in @(Get-Process -Name 'gui-agent' -ErrorAction SilentlyContinue)) {
    try { $pr.Kill(); [void]$pr.WaitForExit(5000) } catch { }
}
EOS
expect_fires_in L17-process-by-name "$D" "packaging/setup/Install-QwtImproved.ps1" "the setup installer's old quiesce kill loop"
printf 'Write-Host ok\n' > "$D/packaging/setup/Install-QwtImproved.ps1"
printf 'Get-Process -Name $AGENTPROC -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue\n' > "$D/packaging/payload/install-qwt-improved.ps1"
expect_fires_in L17-process-by-name "$D" "packaging/payload/install-qwt-improved.ps1" "the overlay installer's old by-name kill"
printf 'Write-Host ok\n' > "$D/packaging/payload/install-qwt-improved.ps1"
printf '& taskkill.exe /F /IM foo.exe\n' > "$D/core-agent/src/qubes-rpc-services/handler.ps1"
expect_fires_in L17-process-by-name "$D" "core-agent/src/qubes-rpc-services/handler.ps1" "a taskkill /im in a core-agent rpc handler"
printf 'Write-Host ok\n' > "$D/core-agent/src/qubes-rpc-services/handler.ps1"
expect_silent L17-process-by-name "$D" "the widened scope with every shipped file clean (the fixed shapes: counting, waiting, -Id)"
# ...and the 2026-10-07 widening to ALL our code: bash harnesses (the taskkill they run and the PowerShell they embed),
# tools/ scripts, python tools. The correct shape - a control process stopped by the id the harness recorded when it
# started it (lifecycle-lib.sh ctl_start/ctl_stop) - stays silent.
D="$TMP/l17w1"; mk "$D"
cat > "$D/mgmt/harness/bad.sh" <<'EOS'
#!/bin/bash
q run 'cmd /c taskkill /f /im notepad.exe 2>nul & exit 0' >/dev/null 2>&1
EOS
expect_fires_in L17-process-by-name "$D" "mgmt/harness/bad.sh" "a taskkill /im a bash harness runs on the guest"
D="$TMP/l17w2"; mk "$D"
cat > "$D/mgmt/harness/bad.sh" <<'EOS'
#!/bin/bash
psrun "Stop-Service QubesGuiWatchdog -Force -EA SilentlyContinue; Start-Sleep 3
Get-Process gui-agent -EA SilentlyContinue | Stop-Process -Force; Start-Sleep 2"
EOS
expect_fires_in L17-process-by-name "$D" "mgmt/harness/bad.sh" "a by-name kill inside the PowerShell a bash harness sends"
D="$TMP/l17w3"; mk "$D"; mkdir -p "$D/tools/viewcheck"
printf 'Get-Process notepad -EA SilentlyContinue | Stop-Process -Force\n' > "$D/tools/viewcheck/t.ps1"
expect_fires_in L17-process-by-name "$D" "tools/viewcheck/t.ps1" "a by-name kill in a tools/ script"
D="$TMP/l17w4"; mk "$D"; mkdir -p "$D/tools"
printf 'cmd = ["tools/qtest", "run", "cmd /c taskkill /f /im notepad.exe"]\n' > "$D/tools/judge.py"
expect_fires_in L17-process-by-name "$D" "tools/judge.py" "a taskkill /im inside a python tool"
D="$TMP/l17wok"; mk "$D"
cat > "$D/mgmt/harness/good.sh" <<'EOS'
#!/bin/bash
read -r _ pid start <<< "$(ctl_start notepad)"
left=$(r 'cmd /c tasklist /nh /fo csv /fi "imagename eq notepad.exe"' | grep -aci '^"notepad\.exe"')
_lc_ps "Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue"
EOS
expect_silent L17-process-by-name "$D" "a harness stopping the control it started by the id it recorded, and a read-only tasklist count"

# ---------------------------------------------------------------- L18 a relauncher's child ended while the relauncher is armed (owner 2026-10-07)
# One fixture per shape, each planted alone, each the literal line a harness or dev script carried before the fix.
D="$TMP/l18a"; mk "$D"
cat > "$D/mgmt/harness/bad.sh" <<'EOS'
#!/bin/bash
psrun "Stop-Service QubesGuiWatchdog -Force -EA SilentlyContinue; Start-Sleep 3
Get-Process gui-agent -EA SilentlyContinue | Stop-Process -Force; Start-Sleep 2
Start-Service QubesGuiWatchdog"
EOS
expect_fires L18-relauncher-armed "$D" "the old harness restart: service stopped, then gui-agent killed by name anyway (the race this rule exists for)"
D="$TMP/l18b"; mk "$D"; printf '& taskkill.exe /F /IM gui-agent.exe *>$null\n' > "$D/guest/x.ps1"
expect_fires L18-relauncher-armed "$D" "taskkill /im gui-agent.exe"
D="$TMP/l18c"; mk "$D"
cat > "$D/guest/x.ps1" <<'EOS'
$old = @(Get-Process gui-agent -EA SilentlyContinue)
Start-Sleep 1
foreach ($a in $old) { $a.Kill() }
EOS
expect_fires L18-relauncher-armed "$D" "gui-agent found by name, held in a variable, ended later by that handle"
D="$TMP/l18d"; mk "$D"; printf 'Get-Process qubes-updates-relay -EA SilentlyContinue | ForEach-Object { $_.Kill() }\n' > "$D/guest/x.ps1"
expect_fires L18-relauncher-armed "$D" "the updates relay ended by name (a pass's task relaunches it)"
D="$TMP/l18e"; mk "$D"; printf 'Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue\n' > "$D/guest/x.ps1"
expect_fires L18-relauncher-armed "$D" "explorer ended by name (Winlogon AutoRestartShell relaunches it)"
D="$TMP/l18f"; mk "$D"; printf 'Get-Process ShellExperienceHost -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue\n' > "$D/guest/x.ps1"
expect_fires L18-relauncher-armed "$D" "ShellExperienceHost ended by name (the shell relaunches it)"
D="$TMP/l18g"; mk "$D"; printf 'Get-Process notifhost | Stop-Process -Force\n' > "$D/guest/x.ps1"
expect_fires L18-relauncher-armed "$D" "notifhost ended by name (gui-agent relaunches it)"
D="$TMP/l18h"; mk "$D"
cat > "$D/mgmt/harness/bad.sh" <<'EOS'
#!/bin/bash
enc_run 'tasklist /nh /fo csv /fi "imagename eq etwproxy.exe"' | tr -d '\r' > "$OUT/t5-tasklist.csv"
ppid=$(awk -F'","' '/[Ee]twproxy\.exe/ {gsub(/"/,"",$2); print $2}' "$OUT/t5-tasklist.csv" | head -1)
qrun "taskkill /f /pid $ppid" >/dev/null 2>&1
EOS
expect_fires L18-relauncher-armed "$D" "a pid SELECTED by a tasklist imagename scan for etwproxy, then taskkill /pid (by name in two steps; the old p3a drill)"
D="$TMP/l18i"; mk "$D"
cat > "$D/guest/x.ps1" <<'EOS'
$xml = @"
<Task><Settings><RestartOnFailure><Interval>PT1M</Interval><Count>3</Count></RestartOnFailure></Settings></Task>
"@
& schtasks /create /tn QwtRestarting /xml "$f" /f
& schtasks /end /tn QwtRestarting
EOS
expect_fires L18-relauncher-armed "$D" "schtasks /end on a task whose definition carries RestartOnFailure, with no disable first"
D="$TMP/l18iok"; mk "$D"
cat > "$D/guest/x.ps1" <<'EOS'
$xml = @"
<Task><Settings><RestartOnFailure><Interval>PT1M</Interval><Count>3</Count></RestartOnFailure></Settings></Task>
"@
& schtasks /create /tn QwtRestarting /xml "$f" /f
& schtasks /change /tn QwtRestarting /disable
& schtasks /end /tn QwtRestarting
& schtasks /end /tn QwtPlain
EOS
expect_silent L18-relauncher-armed "$D" "schtasks /end after the task was disabled, and /end on a task with no restart policy"
# ...and the correct shapes: the service restart with a wait on the old agent's HANDLE, a by-id stop of the shell window's
# owner, a relay stopped by the handle its starter kept, a drill's taskkill /pid of the pid the AGENT logged (no name scan),
# a by-name COUNT, a read-only tasklist, a comment.
D="$TMP/l18ok"; mk "$D"
cat > "$D/guest/restart.ps1" <<'EOS'
$oldPid = 4242
$oldProc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
Stop-Service -Name QubesGuiWatchdog -Force -ErrorAction Stop
[void]$oldProc.WaitForExit(45000)
Start-Service -Name QubesGuiWatchdog
$np = Get-Process -Id 5151 -ErrorAction SilentlyContinue
$count = @(Get-Process gui-agent -ErrorAction SilentlyContinue).Count
Stop-Process -Id $shellPid -Force -ErrorAction SilentlyContinue
$relay = Start-Process -FilePath $exe -ArgumentList '--listen','8082' -PassThru
$relay.Kill()
# a comment: Get-Process gui-agent | Stop-Process must not fire
EOS
cat > "$D/mgmt/harness/good.sh" <<'EOS'
#!/bin/bash
pp=$(proxy_owned_pid); ppid=$(printf '%s' "$pp" | awk '{print $2}')
qrun "taskkill /f /pid $ppid" >/dev/null 2>&1
alive=$(r 'cmd /c tasklist /fi "imagename eq gui-agent.exe" /nh' | grep -ac 'gui-agent\.exe')
EOS
expect_silent L18-relauncher-armed "$D" "the service restart waiting on the old agent's handle, a by-id shell stop, a relay stopped by its own handle, a drill kill by the agent-logged pid, a count, a read, a comment"

# ---------------------------------------------------------------- L23 a guest probe piped into grep -q
# The defect this file's own expect_fires warned about on 2026-08-31 - `lint | grep -q` reporting the
# LEFT side's status - turned out to be live in the harnesses too: w_alive and nine other liveness
# probes graded a guest that ANSWERED as dead, 86 times in 200, and the collector then fetched a
# multi-GB memory image of a healthy guest.
D="$TMP/l23"; mk "$D"
printf '#!/bin/bash\nset -uo pipefail\nalive(){ timeout -k 5 45 ./tools/qtest run %s | grep -qa PONG; }\n' "'cmd /c echo PONG'" > "$D/mgmt/harness/probe.sh"
expect_fires L23-pipe-into-grep-q-probe "$D" "a qtest liveness probe piped into grep -q under pipefail"

# NO PIPEFAIL IS NOT A DEFENCE, and this case used to assert that it was. Without pipefail the
# pipeline does return grep's own status - but grep's early exit still SIGPIPEs the qrexec client
# mid-connect, and the GUEST then writes `QGAVCHANFAIL ... request dropped` at ERROR, against the
# owner's clean-error-log gate condition. MEASURED on win11-nfy 2026-10-16: twice in 163 calls, from
# `alive(){ T=30 q run 'cmd /c echo LIVE' | grep -qa LIVE; }`, whose own file sets no pipefail.
D="$TMP/l23nopf"; mk "$D"
printf '#!/bin/bash\nset -u\nalive(){ timeout 30 qrexec-client-vm "$1" qubes.VMShell | grep -q QALIVE_OK; }\n' > "$D/mgmt/harness/nopipefail.sh"
expect_fires L23-pipe-into-grep-q-probe "$D" "a pipe into grep -q with NO pipefail: it still kills the guest's caller"

# THE THREE HOLES that let this rule report 0 findings against 30 live sites on 2026-10-16.
D="$TMP/l23holes"; mk "$D"
# (1) the producer is a LOCAL WRAPPER, named only by its guest payload
printf '#!/bin/bash\nset -u\nalive(){ T=30 q run %s | grep -qa LIVE; }\n' "'cmd /c echo LIVE'" > "$D/mgmt/harness/wrapper.sh"
expect_fires L23-pipe-into-grep-q-probe "$D" "hole 1: a local wrapper (q run 'cmd /c ...') hid the producer"
D="$TMP/l23holes2"; mk "$D"
# (2) grep reached through `command`, so it is not the first word after the pipe
printf '#!/bin/bash\nset -u\nup(){ QTEST_VM=$VM timeout 40 tools/qtest run %s 2>/dev/null | command grep -qa QREADY; }\n' "'cmd /c echo QREADY'" > "$D/mgmt/harness/cmdgrep.sh"
expect_fires L23-pipe-into-grep-q-probe "$D" "hole 2: 'command grep -qa' hid the consumer"
D="$TMP/l23holes3"; mk "$D"
# (3) $QTEST_BIN as the producer's spelling
printf '#!/bin/bash\nset -u\nup(){ QTEST_VM=$VM timeout 40 "$QTEST_BIN" run %s | grep -qa QREADY; }\n' "'cmd /c echo QREADY'" > "$D/mgmt/harness/qtestbin.sh"
expect_fires L23-pipe-into-grep-q-probe "$D" "hole 3: \$QTEST_BIN hid the producer"

# the correct shape stays silent - including a pipeline out of a LOCAL command, which is a
# different risk and must not be swept in (flagging those is how a real rule dies in noise)
D="$TMP/l23ok"; mk "$D"
printf '#!/bin/bash\nset -uo pipefail\nalive(){ grep -qa PONG <<< "$(timeout -k 5 45 ./tools/qtest run %s)"; }\n' "'cmd /c echo PONG'" > "$D/mgmt/harness/good.sh"
printf '#!/bin/bash\nset -uo pipefail\nhas(){ timeout 5 cat /etc/hosts | grep -q localhost; }\n' > "$D/mgmt/harness/local.sh"
expect_silent L23-pipe-into-grep-q-probe "$D" "capture-then-match, and a purely LOCAL pipeline under pipefail"

# a LIBRARY that sets nothing itself inherits pipefail from whoever sources it - exactly how
# e2e-wait.sh carried this into every harness that sources it
D="$TMP/l23lib"; mk "$D"
printf '#!/bin/bash\nw_alive(){ timeout -k 5 40 ./tools/qtest run %s | grep -qa QREADY; }\n' "'cmd /c echo QREADY'" > "$D/mgmt/harness/wait-lib.sh"
printf '#!/bin/bash\nset -uo pipefail\nsource mgmt/harness/wait-lib.sh\nw_alive x\n' > "$D/mgmt/harness/user.sh"
expect_fires L23-pipe-into-grep-q-probe "$D" "a sourced library's probe, with pipefail coming from the caller"

# ---------------------------------------------------------------- L27 a detached guest launch via `start`
# `start` passes every inheritable handle whatever the redirection, so the launched process inherits
# the qrexec data vchan's pipes and holds them for its whole life; the wrapper's output pumps never
# see EOF. MEASURED 2026-09-27 (d3fe180): `cmd /c start ... <nul >nul` did NOT prevent it. MEASURED
# AGAIN 2026-10-17 on campaign run 38994277148, because the finding lived in one harness and was
# never applied in the others - two matrix.sh launches left wrappers reporting at ERROR that output
# "may not have reached the peer", the only two undeclared error lines that cell carried.
D="$TMP/l27"; mk "$D"
printf '#!/bin/bash\nqrun(){ :; }\narm(){ qrun "cmd /c start \\"w\\" /min powershell -File C:\\\\w.ps1"; }\n' > "$D/mgmt/harness/detach.sh"
expect_fires L27-detached-guest-launch-uses-start "$D" "a detached guest launch via cmd /c start"
# A REDIRECTION IS NOT THE FIX and must not silence it - that is the measurement d3fe180 recorded.
D="$TMP/l27red"; mk "$D"
printf '#!/bin/bash\nqrun(){ :; }\narm(){ qrun "cmd /c start \\"w\\" /min powershell -File C:\\\\w.ps1 >nul 2>&1"; }\n' > "$D/mgmt/harness/detachred.sh"
expect_fires L27-detached-guest-launch-uses-start "$D" "the same launch WITH a redirection - start passes the handles anyway"
# Start-Process goes through ShellExecute and inherits nothing: silent.
D="$TMP/l27ok"; mk "$D"
printf '#!/bin/bash\nqrun(){ :; }\narm(){ qrun "powershell -NoProfile -Command \\"Start-Process -FilePath %s -ArgumentList %s\\""; }\n' "'powershell.exe'" "'-File','C:\\w.ps1'" > "$D/mgmt/harness/detachok.sh"
expect_silent L27-detached-guest-launch-uses-start "$D" "Start-Process, which inherits no handles"

# ------------------------------------------------------- L31 one writer for qemu-extra-args
# The rule shipped with NO leg here, which makes it exactly the decoration the whole file exists to
# catch - it reported clean the day it was written and nobody had seen it go red. The value is read
# at DOMAIN CREATION only: campaign 40134888669 rewrote it against a RUNNING win10-acc and the log
# volume was invisible to the guest eight seconds later; campaign 1024-2333's first judged boot then
# never created a domain at all, because the recorded value still named an unassigned loop.
D="$TMP/l31"; mk "$D"
printf '#!/bin/bash\nqvm-features "$VM" qemu-extra-args -- %s\n' "'-device nec-usb-xhci,id=b'" > "$D/mgmt/harness/bad.sh"
expect_fires L31-qemu-args-not-one-writer "$D" "a harness composing qemu-extra-args itself"
# THE SCOPE, SEEN TO MATTER. mgmt/*.sh was outside the first cut and the rule SAID so; Jev then
# scored `a-caller-writing-qemu-extra-args-directly` 0.99 as the biggest remaining way to boot a
# guest with the wrong device set - that gap by name. A provisioning script is covered now.
D="$TMP/l31mgmt"; mk "$D"; mkdir -p "$D/mgmt"
printf '#!/bin/bash\nqvm-features "$VM" qemu-extra-args -- %s\n' "'-device nec-usb-xhci,id=b'" > "$D/mgmt/reprovision-usb.sh"
expect_fires L31-qemu-args-not-one-writer "$D" "a PROVISIONING script in mgmt/ composing the args - outside the rule's first scope"
# THE OTHER ARGUMENT ORDER - the blanket wipe. `--unset` BEFORE the feature name walked past the
# first regex in three teardown paths (seal-qwt-golden.sh, rebuild-rig.sh, provision_disarm), and an
# unset deletes the controller the evidence volume rides on, not just our drive. Jev scored exactly
# this route a-blanket-unset-deleting-the-log-volume-device 0.94.
D="$TMP/l31unset"; mk "$D"
printf '#!/bin/bash\nqvm-features --unset "$VM" qemu-extra-args\n' > "$D/mgmt/harness/wipe.sh"
expect_fires L31-qemu-args-not-one-writer "$D" "a blanket --unset of qemu-extra-args, the argument order the first regex missed"
# A READ is not a write and must stay silent - matrix.sh and logvol-chain-check.sh both read it.
D="$TMP/l31read"; mk "$D"
printf '#!/bin/bash\ncur=$(qvm-features "$VM" qemu-extra-args 2>/dev/null || true)\n' > "$D/mgmt/harness/read.sh"
expect_silent L31-qemu-args-not-one-writer "$D" "READING qemu-extra-args, which every caller that composes has to do"
# The phase owner is the sanctioned route and must not fire.
D="$TMP/l31ok"; mk "$D"
printf '#!/bin/bash\n. mgmt/harness/logvol-lib.sh\nlogvol_devices_apply "$VM" graded || exit 1\n' > "$D/mgmt/harness/ok.sh"
expect_silent L31-qemu-args-not-one-writer "$D" "logvol_devices_apply, the one writer's phase API"
# A COMMENT and an OPERATOR INSTRUCTION are not writes - mgmt/build-answer-stick.sh echoes this very
# command for a human to run, and a lint that fired there would be turned off rather than obeyed.
D="$TMP/l31txt"; mk "$D"
printf '#!/bin/bash\n# qvm-features <vm> qemu-extra-args -- %s\necho "  qvm-features <vm> qemu-extra-args -- %s"\n' "'-device x'" "'-device x'" > "$D/mgmt/harness/txt.sh"
expect_silent L31-qemu-args-not-one-writer "$D" "the command named in a comment and echoed for an operator"
# And the one writer itself is exempt: its qvm-features call IS the write.
D="$TMP/l31lib"; mk "$D"
printf '#!/bin/bash\nqvm-features "$vm" qemu-extra-args -- "$val"\n' > "$D/mgmt/harness/logvol-lib.sh"
expect_silent L31-qemu-args-not-one-writer "$D" "logvol-lib.sh, which is the one writer"

# ---------------------------------------------------------------- L32 producer for every test file
D="$TMP/l32"; mk "$D"; mkdir -p "$D/tools/tests"
printf 'registered-selftest.sh\n' > "$D/tools/tests/offline-suites.txt"
printf '#!/bin/bash\n: ok\n' > "$D/tools/tests/registered-selftest.sh"
printf '#!/bin/bash\n: ok\n' > "$D/tools/tests/nobody-runs-me-selftest.sh"
expect_fires L32-producer-missing "$D" "a selftest in neither list"

# the SPELLING must not be what saves a file - this is the census error the rule exists to stop
D="$TMP/l32b"; mk "$D"; mkdir -p "$D/tools/tests"
printf 'registered-selftest.sh\n' > "$D/tools/tests/offline-suites.txt"
printf '#!/bin/bash\n: ok\n' > "$D/tools/tests/registered-selftest.sh"
printf '#!/usr/bin/env python3\n' > "$D/tools/tests/some-audit.py"
expect_fires L32-producer-missing "$D" "a .py test file in neither list (not the *-selftest.sh spelling)"

# a declaration with no reason is an allowlist entry, and those rot
D="$TMP/l32c"; mk "$D"; mkdir -p "$D/tools/tests"
: > "$D/tools/tests/offline-suites.txt"
printf '#!/bin/bash\n: ok\n' > "$D/tools/tests/rig-only-selftest.sh"
printf 'rig-only-selftest.sh\n' > "$D/tools/tests/not-in-the-gate.txt"
expect_fires L32-producer-missing "$D" "declared out of the gate with no reason"

# a declaration naming a file that is gone has rotted
D="$TMP/l32d"; mk "$D"; mkdir -p "$D/tools/tests"
: > "$D/tools/tests/offline-suites.txt"
printf 'deleted-selftest.sh   needs the rig: drives a real guest\n' > "$D/tools/tests/not-in-the-gate.txt"
expect_fires L32-producer-missing "$D" "declaration naming a file that no longer exists"

# a git hook in tools/hooks/ runs suites, so it IS a producer - a non-recursive glob flagged 8
# files the hooks do run
D="$TMP/l32f"; mk "$D"; mkdir -p "$D/tools/tests" "$D/tools/hooks"
: > "$D/tools/tests/offline-suites.txt"
printf '#!/bin/bash
: ok
' > "$D/tools/tests/hook-runs-me-selftest.sh"
printf '#!/bin/bash
bash tools/tests/hook-runs-me-selftest.sh
' > "$D/tools/hooks/pre-commit.sh"
expect_silent L32-producer-missing "$D" "a git hook in tools/hooks names it"

# a SIBLING suite naming another does not run it - that chain has to be declared, so it is visible
D="$TMP/l32g"; mk "$D"; mkdir -p "$D/tools/tests"
: > "$D/tools/tests/offline-suites.txt"
printf '#!/bin/bash
: ok
' > "$D/tools/tests/sib-a-selftest.sh"
printf '#!/bin/bash
bash tools/tests/sib-a-selftest.sh
' > "$D/tools/tests/sib-b-selftest.sh"
expect_fires L32-producer-missing "$D" "named only by a sibling suite in tools/tests"

# A COMMENTED-OUT CALL RUNS NOTHING. This is the predicate the census got wrong on 2026-10-25: the
# first implementation matched the suite's name anywhere in a producer's text, comments included,
# while its own comment said prose runs nothing - and a comment inside tools/foo.sh is prose too.
# Dropping whole-line comments raised the orphan count by 18.
D="$TMP/l32h"; mk "$D"; mkdir -p "$D/tools/tests"
: > "$D/tools/tests/offline-suites.txt"
printf '#!/bin/bash\n: ok\n' > "$D/tools/tests/commented-selftest.sh"
printf '#!/bin/bash\n# bash tools/tests/commented-selftest.sh\n: nothing\n' > "$D/tools/run-suites.sh"
expect_fires L32-producer-missing "$D" "named only by a COMMENTED-OUT call in a real producer"

# ...and the SAME tree with that one line uncommented must be silent. Without this pair the leg
# above could pass because tools/run-suites.sh is never scanned at all, which would prove nothing.
D="$TMP/l32h2"; mk "$D"; mkdir -p "$D/tools/tests"
: > "$D/tools/tests/offline-suites.txt"
printf '#!/bin/bash\n: ok\n' > "$D/tools/tests/commented-selftest.sh"
printf '#!/bin/bash\nbash tools/tests/commented-selftest.sh\n' > "$D/tools/run-suites.sh"
expect_silent L32-producer-missing "$D" "the same producer with the call UNcommented - the pair that makes the leg above mean something"

# THE DECLARED RESIDUE, pinned deliberately: the rule keys on the first non-space character only,
# because cutting from any '#' would truncate real calls (${v#prefix}, a colour code, a URL
# fragment) and lose the producer instead of the mention. So a TRAILING-comment mention survives.
# If that is ever tightened, this leg is the thing that has to be changed on purpose.
D="$TMP/l32i"; mk "$D"; mkdir -p "$D/tools/tests"
: > "$D/tools/tests/offline-suites.txt"
printf '#!/bin/bash\n: ok\n' > "$D/tools/tests/trailing-selftest.sh"
printf '#!/bin/bash\n: ok   # see tools/tests/trailing-selftest.sh\n' > "$D/tools/run-suites.sh"
expect_silent L32-producer-missing "$D" "a TRAILING-comment mention, the residue the rule declares"

# WORD BOUNDARY, not substring: every error in this rule's history has been the flattering one, and
# a near-miss name reading as coverage is the flattering one here.
D="$TMP/l32j"; mk "$D"; mkdir -p "$D/tools/tests"
: > "$D/tools/tests/offline-suites.txt"
printf '#!/bin/bash\n: ok\n' > "$D/tools/tests/near-selftest.sh"
printf '#!/bin/bash\nbash tools/tests/xnear-selftest.sh\n' > "$D/tools/run-suites.sh"
expect_fires L32-producer-missing "$D" "a producer naming xnear-selftest.sh while near-selftest.sh is the file"

# and the correct shape must be silent, or the lint is noise
D="$TMP/l32e"; mk "$D"; mkdir -p "$D/tools/tests"
printf 'registered-selftest.sh\n' > "$D/tools/tests/offline-suites.txt"
printf '#!/bin/bash\n: ok\n' > "$D/tools/tests/registered-selftest.sh"
printf '#!/bin/bash\n: ok\n' > "$D/tools/tests/rig-only-selftest.sh"
printf 'rig-only-selftest.sh   needs the rig: drives a real Windows guest\n' > "$D/tools/tests/not-in-the-gate.txt"
expect_silent L32-producer-missing "$D" "one file registered, one declared with a reason"

echo "  ---- $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
