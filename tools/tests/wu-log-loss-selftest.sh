#!/usr/bin/env bash
# wu-log-loss-selftest.sh - the updater's Log must never lose a line in SILENCE.
#
# WHY. The shipped body was
#     try { Add-Content -LiteralPath (Join-Path $WorkDir 'agent.log') -Value $line -EA SilentlyContinue } catch {}
# - a suppressed error inside an empty catch. A failed append left no trace in the file, on the
# console or in the status, so the ABSENCE of a log line meant nothing. Measured 2026-10-08: with an
# unwritable WorkDir the call does not throw, writes nothing and reports nothing.
# IT HAPPENED FOR REAL: on WIN11-upgrade and win11de-tup the pass's agent.log was missing
# "relay started: pid ..." and "proxy up: ..." although it reached Sync-Revocation, which runs only
# if Ensure-Proxy returned and whose success path emits both. Add-Content takes a write lock and the
# updater deploy was writing in the same second. Those absences were then nearly written up as a
# product defect that did not exist.
# Save has retried its own write since it was written; Log never did.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="${WU_SRC:-$HERE/guest/qubes-windows-update.ps1}"
PW="${PWSH:-/home/user/pwsh/pwsh}"
[ -f "$SRC" ] || { echo "FAIL  $SRC missing - nothing ran (missing data fails)"; exit 2; }
[ -x "$PW" ] || { echo "FAIL  no pwsh at $PW - nothing ran"; exit 2; }
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }

# LOGLOSS_DEFECT=silent puts the old swallowing body back; every check below must then FAIL.
out=$("$PW" -NoProfile -Command "
\$src = Get-Content -Raw '$SRC'
\$m = [regex]::Match(\$src, '(?s)function Log\(\\\$m\)\{.*?\n\}')
if (-not \$m.Success) { 'INSTRUMENT: Log not found'; exit 2 }
\$body = \$m.Value
if ('${LOGLOSS_DEFECT:-}' -eq 'silent') {
  \$body = 'function Log(\$m){ \$line = (Get-Date -Format ''HH:mm:ss'')+'' ''+\$m; Write-Host \$line; try { Add-Content -LiteralPath (Join-Path \$WorkDir ''agent.log'') -Value \$line -EA SilentlyContinue } catch {} }'
}
\$script:LogDropped = 0; \$script:LogDropFirst = ''
\$WorkDir = '/proc/definitely-not-writable'
. ([scriptblock]::Create(\$body))
\$t0 = Get-Date
Log 'relay started: pid 4188'
Log 'proxy up: 127.0.0.1:8082'
\$ms = [int]((Get-Date) - \$t0).TotalMilliseconds
'DROPPED=' + \$script:LogDropped
'REASON=' + [bool]\$script:LogDropFirst
'ELAPSED=' + \$ms
# a writable dir must still log normally and count nothing
\$d = Join-Path ([IO.Path]::GetTempPath()) ('wulog-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path \$d -Force | Out-Null
\$WorkDir = \$d; \$script:LogDropped = 0
Log 'ordinary line'
'OKDROPPED=' + \$script:LogDropped
'OKPRESENT=' + ((Get-Content (Join-Path \$d 'agent.log') -Tail 1) -match 'ordinary line')
# AND THE LOG MUST ANNOUNCE ITS OWN GAP once it can write again: drop two lines against an
# unwritable dir, then point WorkDir at a writable one and log normally. tools/wu-pass-judge.py
# FAILS a capture carrying QWTUPDLOGLOST, so the notice is what makes a lossy log gradeable.
\$WorkDir = '/proc/definitely-not-writable'; \$script:LogDropped = 0; \$script:LogDropFirst = ''; \$script:LogLossReported = \$false
Log 'relay started: pid 4188'
Log 'proxy up: 127.0.0.1:8082'
\$d2 = Join-Path ([IO.Path]::GetTempPath()) ('wulog2-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path \$d2 -Force | Out-Null
\$WorkDir = \$d2
Log 'the next line that could be written'
\$t = Get-Content (Join-Path \$d2 'agent.log') -Raw
'NOTICE=' + (\$t -match 'QWTUPDLOGLOST 2 line')
'NOTICEONCE=' + ([regex]::Matches(\$t, 'QWTUPDLOGLOST')).Count
'NOTICEWHY=' + (\$t -match 'unsafe')

# and the retry must SHORT-CIRCUIT once the log is plainly gone
\$WorkDir = '/proc/definitely-not-writable'; \$script:LogDropped = 0
\$t1 = Get-Date; 1..12 | ForEach-Object { Log \"line \$_\" }; \$ms2 = [int]((Get-Date) - \$t1).TotalMilliseconds
'MANY=' + \$script:LogDropped
'MANYMS=' + \$ms2
" 2>&1)

g(){ echo "$out" | command grep -ao "^$1=.*" | head -1 | cut -d= -f2-; }
[ "$(g DROPPED)" = 2 ] && ok "a line that cannot be written is COUNTED, not swallowed (dropped=2)" \
                       || bad "dropped=$(g DROPPED), expected 2 - a failed write is still silent"
[ "$(g REASON)" = True ] && ok "and the first failure reason is kept, so the loss can be explained" \
                         || bad "no reason captured for the dropped line"
[ "$(g OKDROPPED)" = 0 ] && [ "$(g OKPRESENT)" = True ] \
  && ok "a writable log still works, and nothing is counted" \
  || bad "the normal path broke: dropped=$(g OKDROPPED) present=$(g OKPRESENT)"
[ "$(g MANY)" = 12 ] && ok "every dropped line is counted, not just the first (12 of 12)" \
                     || bad "many=$(g MANY), expected 12"
[ "$(g NOTICE)" = True ] && ok "the log ANNOUNCES its own gap (QWTUPDLOGLOST 2 line) on the first write that succeeds" \
                         || bad "no QWTUPDLOGLOST notice after a loss - the gap is only a gap"
[ "$(g NOTICEONCE)" = 1 ] && ok "and it says so ONCE, not on every later line" \
                          || bad "the notice appeared $(g NOTICEONCE) times"
[ "$(g NOTICEWHY)" = True ] && ok "and it warns that an absence in this file is not evidence" \
                            || bad "the notice does not say why it matters"
m=$(g MANYMS); [ -n "$m" ] && [ "$m" -lt 4000 ] \
  && ok "the retry short-circuits once the log is gone (12 lines in ${m} ms, not ~4500)" \
  || bad "12 dropped lines took ${m} ms - the retry is not short-circuiting"

echo
echo "wu-log-loss-selftest: $pass passed, $fail failed"
[ "$fail" = 0 ] || exit 1
