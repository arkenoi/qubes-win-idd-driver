#!/bin/bash
# SELF-TEST for guest/restart-gui-agent.ps1's turnover PROOF - every INVALID reason must be SEEN TO FIRE.
#
# The helper's success path used to trust the newest log FILE NAME as the identity of a running agent
# (Jev review 2026-10-07: false_pass 0.34, worst flaw log-name-trust 0.60): a newer log whose process
# already died, or whose pid was reused by anything, would have passed. Now the success path needs three
# facts - the log's CONTENT pid agrees with its name, the PROCESS behind it runs the owner's exe and
# started between the service start and the log's creation, and the log carries the agent's post-Init
# SERVING marker. Each has its own INVALID reason and each is planted here, offline, with pwsh against
# REAL processes (a `sleep` child stands in for gui-agent.exe; its path is the "expected exe") and
# fixture log files. The on-guest fail-proof (an agent surviving the service stop, no new log in
# bound) is driven on a real guest separately - this file proves the EVALUATION, not the service.
#
#   tools/tests/restart-gui-agent-selftest.sh
set -uo pipefail
cd "$(dirname "$0")/../.."
PWSH="${PWSH:-/home/user/pwsh/pwsh}"
[ -x "$PWSH" ] || { echo "SKIP: no pwsh at $PWSH"; exit 0; }
pass=0; fail=0
ok(){ echo "  PASS  $*"; pass=$((pass+1)); }
no(){ echo "  FAIL  $*"; fail=$((fail+1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"; pkill -P $$ sleep 2>/dev/null' EXIT

# One pwsh session runs every case: it starts the stand-in processes, writes the fixture logs around them
# (ORDER is the point: a log created before its process started is the pid-reuse signature), calls the
# pure functions and prints "CASE <name> <stage|value>" lines this script asserts on.
"$PWSH" -NoProfile -NonInteractive -Command "
\$ErrorActionPreference = 'Continue'
. ./guest/restart-gui-agent.ps1
\$dir = '$TMP'
function MkLog([string]\$name, [int]\$headerPid, [string]\$marker) {
    \$p = Join-Path \$dir \$name
    \$lines = @('[20261007.120000.000-1234-I] LogInit: Running as user: NT AUTHORITY\SYSTEM, process ID: ' + \$headerPid,
               '[20261007.120000.001-1234-I] LogInit: Module version: 4.3.35.0')
    if (\$marker) { \$lines += ('[20261007.120001.000-1234-I] ' + \$marker) }
    Set-Content -LiteralPath \$p -Value \$lines -Encoding ASCII
    return (Get-Item -LiteralPath \$p)
}
function Clean { Get-ChildItem -LiteralPath \$dir -Filter 'gui-agent-*.log' | Remove-Item -Force }
# the stand-in agent: a real process whose Path and StartTime the checks read
\$agent = Start-Process -FilePath sleep -ArgumentList 600 -PassThru
Start-Sleep -Milliseconds 300
\$exe = (Get-Process -Id \$agent.Id).Path
\$before = (Get-Date).AddSeconds(-5)

# header pid parsing on the real line shape
Write-Output ('CASE header-pid ' + (Get-GuiAgentLogHeaderPid (MkLog 'gui-agent-20261007-120000-4242.log' 4242 '').FullName))

# POSITIVE CONTROL: name pid = header pid = a live process running the expected exe, started before the
# log was created, serving marker present
Clean; Start-Sleep -Milliseconds 1200
\$null = MkLog ('gui-agent-20261007-120000-' + \$agent.Id + '.log') \$agent.Id 'Awaiting for a vchan client, write buffer size: 65536'
\$t = Resolve-GuiAgentTurnover -LogDir \$dir -OldLog 'gui-agent-20261007-110000-1.log' -ExpectedExe \$exe -NotBefore \$before
Write-Output ('CASE positive ' + \$t.stage + ' serving=' + \$t.serving)
# 'connected' is the other accepted marker
Clean; Start-Sleep -Milliseconds 1200
\$null = MkLog ('gui-agent-20261007-120000-' + \$agent.Id + '.log') \$agent.Id 'A vchan client has connected'
\$t = Resolve-GuiAgentTurnover -LogDir \$dir -OldLog 'x' -ExpectedExe \$exe -NotBefore \$before
Write-Output ('CASE connected ' + \$t.stage + ' serving=' + \$t.serving)

# KNOB 0: no newer log than the old one
\$t = Resolve-GuiAgentTurnover -LogDir \$dir -OldLog ('gui-agent-20261007-120000-' + \$agent.Id + '.log') -ExpectedExe \$exe -NotBefore \$before
Write-Output ('CASE no-new-log ' + \$t.stage)

# KNOB 1: the name says one pid, the LogInit header another (a foreign or renamed file)
Clean; Start-Sleep -Milliseconds 1200
\$null = MkLog ('gui-agent-20261007-120000-' + \$agent.Id + '.log') (\$agent.Id + 1) 'Awaiting for a vchan client, write buffer size: 65536'
\$t = Resolve-GuiAgentTurnover -LogDir \$dir -OldLog 'x' -ExpectedExe \$exe -NotBefore \$before
Write-Output ('CASE log-pid-mismatch ' + \$t.stage)

# KNOB 2a: the pid in the (agreeing) name and header no longer exists
\$dead = Start-Process -FilePath sleep -ArgumentList 0.1 -PassThru; \$null = \$dead.WaitForExit(5000); Start-Sleep -Milliseconds 300
Clean; \$null = MkLog ('gui-agent-20261007-120000-' + \$dead.Id + '.log') \$dead.Id 'Awaiting for a vchan client, write buffer size: 65536'
\$t = Resolve-GuiAgentTurnover -LogDir \$dir -OldLog 'x' -ExpectedExe \$exe -NotBefore \$before
Write-Output ('CASE pid-not-alive ' + \$t.stage)

# KNOB 2b: the pid is alive but runs something else (a reused pid)
Clean; Start-Sleep -Milliseconds 1200
\$null = MkLog ('gui-agent-20261007-120000-' + \$agent.Id + '.log') \$agent.Id 'Awaiting for a vchan client, write buffer size: 65536'
\$t = Resolve-GuiAgentTurnover -LogDir \$dir -OldLog 'x' -ExpectedExe '/opt/not-the-agent/gui-agent.exe' -NotBefore \$before
Write-Output ('CASE pid-reused-path ' + \$t.stage)

# KNOB 2c: the pid is alive, right exe, but started BEFORE the service start (an older process wearing the pid)
\$t = Resolve-GuiAgentTurnover -LogDir \$dir -OldLog 'x' -ExpectedExe \$exe -NotBefore (Get-Date).AddSeconds(30)
Write-Output ('CASE pid-reused-start-before-service ' + \$t.stage)

# KNOB 2d: the log was created BEFORE the process started - the process is younger than its own log
Clean; \$null = MkLog 'gui-agent-20261007-120000-PLACEHOLDER.log' 1 ''
Start-Sleep -Milliseconds 1500
\$young = Start-Process -FilePath sleep -ArgumentList 600 -PassThru; Start-Sleep -Milliseconds 300
\$yexe = (Get-Process -Id \$young.Id).Path
Rename-Item -LiteralPath (Join-Path \$dir 'gui-agent-20261007-120000-PLACEHOLDER.log') -NewName ('gui-agent-20261007-120000-' + \$young.Id + '.log')
Set-Content -LiteralPath (Join-Path \$dir ('gui-agent-20261007-120000-' + \$young.Id + '.log')) -Value @('[x] LogInit: Running as user: u, process ID: ' + \$young.Id, '[x] Awaiting for a vchan client, write buffer size: 1') -Encoding ASCII
\$f = Get-Item -LiteralPath (Join-Path \$dir ('gui-agent-20261007-120000-' + \$young.Id + '.log'))
\$t = Resolve-GuiAgentTurnover -LogDir \$dir -OldLog 'x' -ExpectedExe \$yexe -NotBefore \$before
Write-Output ('CASE pid-reused-start-younger-than-log ' + \$t.stage + ' (log created ' + \$f.CreationTime.ToString('HH:mm:ss.fff') + ', process started ' + (Get-Process -Id \$young.Id).StartTime.ToString('HH:mm:ss.fff') + ')')
Stop-Process -Id \$young.Id -Force -ErrorAction SilentlyContinue

# KNOB 3: identity and process hold, but no serving marker (started, not serving / dead on arrival)
Clean; Start-Sleep -Milliseconds 1200
\$null = MkLog ('gui-agent-20261007-120000-' + \$agent.Id + '.log') \$agent.Id ''
\$t = Resolve-GuiAgentTurnover -LogDir \$dir -OldLog 'x' -ExpectedExe \$exe -NotBefore \$before
Write-Output ('CASE not-serving ' + \$t.stage)

# the identity of an OLD agent: same content check (a reused pid is 'not our agent', never waited on)
Clean; Start-Sleep -Milliseconds 1200
\$l = MkLog ('gui-agent-20261007-120000-' + \$agent.Id + '.log') \$agent.Id 'Awaiting for a vchan client, write buffer size: 1'
\$id = Get-GuiAgentIdentity -Log \$l -ExpectedExe \$exe
Write-Output ('CASE old-identity-ours alive=' + \$id.alive + ' ' + \$id.reason)
\$id = Get-GuiAgentIdentity -Log \$l -ExpectedExe '/opt/not-the-agent/gui-agent.exe'
Write-Output ('CASE old-identity-reused alive=' + \$id.alive + ' ' + \$id.reason)
Stop-Process -Id \$agent.Id -Force -ErrorAction SilentlyContinue
" > "$TMP/cases.txt" 2>&1
sed 's/^/    /' "$TMP/cases.txt"

want(){ # <case> <expected-stage-token>
  local line; line=$(grep -a "^CASE $1 " "$TMP/cases.txt" | head -1)
  if printf '%s' "$line" | grep -qa -- " $2"; then ok "$1 -> $2"; else no "$1: wanted '$2', got '${line:-no CASE line}'"; fi
}
want header-pid 4242
want positive 'ok serving=awaiting'
want connected 'ok serving=connected'
want no-new-log no-new-log
want log-pid-mismatch log-pid-mismatch
want pid-not-alive pid-not-alive
want pid-reused-path pid-reused-path
want pid-reused-start-before-service pid-reused-start
want pid-reused-start-younger-than-log pid-reused-start
want not-serving not-serving
want old-identity-ours 'alive=True ok'
want old-identity-reused 'alive=False pid-reused-path'

echo "  ---- $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
