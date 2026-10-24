#!/usr/bin/env bash
# build-attribution-selftest.sh - the BIRTH CUTOFF: a line is billed to the build that WROTE it, and
# a capture that cannot establish who wrote what must FAIL rather than grade green. No guest, no rig.
#
# WHY THIS EXISTS. On an upgrade cell the capture holds two builds' logs, and attributing the ENTRY
# FIXTURE's lines to the candidate has produced real, recorded misreadings: a release was briefly
# suspected of shipping stale binaries, two fixes were reported as not working, and a campaign cell
# failed on strings the candidate's source does not contain (log-sweep.py records each with its
# run id). The owner's account of the cost is his own, not a measurement of this code: "we literally
# fucked around for 3 weeks managing the fallout and false alarms from these upgrades". He also
# named the design, 2026-10-23:
# "you were supposed to put in birth cutoff lines. so everything before is NOT attributed to product.
# AND?" - the AND being that the cutoff existed, was applied to ONE metric, returned None on the
# cells that needed it, and its absence was reported by nothing.
#
# FOUR PROPERTIES, each with its mutation. Every fixture line below is VERBATIM from
# /home/user/qwt-matrix/20261023-061821/win11-upgrade-guestlogs (campaign 20261023-061821,
# win11-upgrade, 4.3.35.795 -> 4.3.37.1062), because a fixture I invent cannot prove what the
# product's own format does. The captures are not tracked, so the LINES are copied here; the
# conditions they carry are the real ones.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$(mktemp -d /tmp/buildattr-selftest-XXXXXX)"
L="$OUT/logs"; mkdir -p "$L"
PASS=0; FAIL=0
ok(){ echo "ok   $*"; PASS=$((PASS+1)); }
no(){ echo "FAIL $*"; FAIL=$((FAIL+1)); }

# ---- the turnover module: ONE module that shows both builds, which is what establishes the
# ---- superseded series AND the install anchor for the whole capture.
cat > "$L/qrexec-agent-20261023.log" <<'LOG'
[20261023.091958.340-2764:2768-I] LogInit: QWTBIRTH module=qrexec-agent ver=4.3.35.795 pid=2764 session=0 uptime=52.900
[20261023.091958.377-2764:2768-I] XcOpen: XenIface handle: 00000000000001E4
[20261023.092357.780-5468:5472-I] LogInit: QWTBIRTH module=qrexec-agent ver=4.3.37.1062 pid=5468 session=0 uptime=291.100
[20261023.092357.800-5468:5472-I] XcOpen: XenIface handle: 00000000000001F0
LOG

# ---- the module whose ONLY log is the PREDECESSOR's: it declares one version, so it cannot tell a
# ---- turnover happened. This is the shape measured on win10-upgrade of run 39767068509.
cat > "$L/gui-agent-20261023-091959-800.log" <<'LOG'
[20261023.091959.705-984-I] LogInit: Log started, module name: gui-agent
[20261023.091959.705-984-I] LogInit: System uptime: 54.328 seconds
[20261023.091959.712-984-I] LogInit: Running as user: SYSTEM, process ID: 800
[20261023.091959.712-984-I] LogInit: Module version: 4.3.35.795
[20261023.091959.712-984-I] LogInit: Session: 1
[20261023.092000.235-984-E] WinMain: WatchForEvents failed with error 0x0
LOG

# ---- OUR INSTALLER: no version resource, so it declares 0.0.0.0, and it runs BEFORE the candidate's
# ---- first init. Its ERROR lines are the product's own and must be counted.
cat > "$L/qwtng-netsetup-20261023-092233-3724.log" <<'LOG'
[20261023.092233.002-4136-I] LogInit: Log started, module name: qwtng-netsetup
[20261023.092233.002-4136-I] LogInit: System uptime: 207.625 seconds
[20261023.092233.006-4136-I] LogInit: Running as user: SYSTEM, process ID: 3724
[20261023.092233.006-4136-I] LogInit: Module version: 0.0.0.0
[20261023.092233.006-4136-I] LogInit: Session: 0
[20261023.092233.006-4136-E] QioWriteBuffer: WriteFile failed with error 0xe8: The pipe is being closed.
LOG

# ---- a STOCK component, versioning on its own line (4.3.1.0 inside a 4.3.37 package).
cat > "$L/qubesdb-daemon-20261023.log" <<'LOG'
[20261023.092321.353-3284:3460-I] LogInit: QWTBIRTH module=qubesdb-daemon ver=4.3.1.0 pid=3284 session=0 uptime=254.281
[20261023.092321.557-3284:628-I] QpsConnectClient: [1] (000001D2B7323A20) connected (1 total)
[20261023.092321.719-3284:7380-W] pipe_thread_client: QpsRead from client 1 failed: 109
LOG

python3 - "$ROOT" "$L" <<'PY' > "$OUT/res.txt" 2>&1
import importlib.util, sys
root, logs = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("ls", root + "/tools/log-sweep.py")
m = importlib.util.module_from_spec(spec)
try: spec.loader.exec_module(m)
except SystemExit: pass

BUILD = "4.3.37+agent.39cbad1d32e0"      # a package_version, NOT a module version: the join is on
                                         # the first three components (see _build_series)
_, files, _, _ = m.load_logs(logs)
by = {}
for lf in files:
    by[lf.module] = lf

def pick(mod, level, needle):
    lf = by[mod]
    for l in lf.lines:
        if l.level == level and needle in l.msg:
            return lf, l
    raise SystemExit("FIXTURE BROKEN: no %s %s line matching %r in %s" % (mod, level, needle, lf.name))

_sc = m.build_scope(files, BUILD)   # a BuildScope: read by NAME, never by position
builds, anchor, pre_install, prior, unattrib = _sc.builds, _sc.anchor, _sc.pre_install, _sc.prior, _sc.unattributable
sup = m.superseded_series(builds, BUILD)
print("ANCHOR %s" % anchor)
print("SUPERSEDED %s" % sorted(".".join(s) for s in sup))
print("MODULES %s" % {k: v["versions"] for k, v in sorted(builds.items())})

# ---- P1: the predecessor's line, from a module that declares ONE version ---------------------
lf, l = pick("gui-agent", "E", "WatchForEvents")
print("P1 %s" % prior(lf, l))
print("P1MUT %s" % m.is_prior_build(lf, l, builds))        # the old rule: no superseded set

# ---- P2: our installer's line, 0.0.0.0, before the anchor ------------------------------------
lf2, l2 = pick("qwtng-netsetup", "E", "WriteFile failed")   # the parser strips the function prefix
print("P2PRE %s" % pre_install(l2))                        # it IS before the cutoff
print("P2 %s" % prior(lf2, l2))                            # and must NOT be the predecessor's
_real = m.declared_unreadable
m.declared_unreadable = lambda a, b: False                 # MUTATION: lose the discriminator
prior_mut = m.build_scope(files, BUILD).prior
print("P2MUT %s" % prior_mut(lf2, l2))
m.declared_unreadable = _real

# ---- P3: a stock component is not ours to declare unattributable -----------------------------
lf3, l3 = pick("qubesdb-daemon", "W", "QpsRead")
print("P3 %s" % unattrib(lf3, l3))
_stock = m.STOCK_FAMILIES
m.STOCK_FAMILIES = set()                                   # MUTATION: stop sparing stock modules
unattrib_mut = m.build_scope(files, BUILD).unattributable
print("P3MUT %s" % unattrib_mut(lf3, l3))
m.STOCK_FAMILIES = _stock

# ---- P4: a capture that cannot be attributed at all ------------------------------------------
def absent(b):
    cs = m._build_series(b)
    if not cs:
        return None
    return 0 if any(i.get("version") and m._build_series(i["version"]) == cs
                    for lf in files for i in lf.inits) else 1
print("P4HELD %s" % absent(BUILD))
print("P4GONE %s" % absent("4.9.99+agent.nonesuch"))
print("P4NONE %s" % absent(None))

# ---- P5: both new metrics are GATED, not informational ---------------------------------------
for k in ("warning_lines_unattributable", "candidate_build_absent"):
    print("P5 %s thr=%s informational=%s" % (k, k in m.DEFAULT_THRESHOLDS, k in m.INFORMATIONAL_METRICS))
PY

R="$OUT/res.txt"
g(){ grep -a "^$1 " "$R" | head -1 | cut -d' ' -f2-; }
if grep -qa 'FIXTURE BROKEN\|Traceback' "$R"; then
    no "the fixture did not load - $(grep -aE 'FIXTURE BROKEN|Error' "$R" | head -1)"
    sed 's/^/     /' "$R" | tail -12
else
    echo "     anchor=$(g ANCHOR)  superseded=$(g SUPERSEDED)"
    echo "     modules=$(g MODULES)"

    [ "$(g SUPERSEDED)" = "['4.3.35']" ] \
      && ok "the capture establishes 4.3.35 as superseded from the ONE module that turned over" \
      || no "superseded series wrong: $(g SUPERSEDED)"

    [ "$(g P1)" = "True" ] \
      && ok "P1 the predecessor's ERROR is excluded although its module declares ONE version" \
      || no "P1 the entry fixture's ERROR is billed to the candidate - the three-week defect"
    [ "$(g P1MUT)" = "False" ] \
      && ok "P1 seen-to-fail: without the capture-wide set the same line is NOT excluded" \
      || no "P1 seen-to-fail did not fail (got $(g P1MUT)) - this suite proves nothing"

    [ "$(g P2PRE)" = "True" ] \
      && ok "P2 our installer's line IS before the birth cutoff (so the clause can reach it)" \
      || no "P2 fixture does not hold the condition: the installer line is not pre-anchor"
    [ "$(g P2)" = "False" ] \
      && ok "P2 our installer's ERROR is COUNTED, not billed to the build it replaced" \
      || no "P2 our own installer's ERROR is hidden as prior-build - 12 of these per upgrade cell"
    [ "$(g P2MUT)" = "True" ] \
      && ok "P2 seen-to-fail: without declared_unreadable the installer's ERROR is swallowed" \
      || no "P2 seen-to-fail did not fail (got $(g P2MUT))"

    [ "$(g P3)" = "False" ] \
      && ok "P3 a stock component's own version does not make its line unattributable" \
      || no "P3 a stock WARNING is unattributable - 10323 of 12430 corpus-wide were this"
    [ "$(g P3MUT)" = "True" ] \
      && ok "P3 seen-to-fail: without the STOCK_FAMILIES guard it breaches" \
      || no "P3 seen-to-fail did not fail (got $(g P3MUT))"

    [ "$(g P4HELD)" = "0" ] \
      && ok "P4 candidate_build_absent=0 when the capture holds the named build" \
      || no "P4 wrong for a build the capture DOES hold: $(g P4HELD)"
    [ "$(g P4GONE)" = "1" ] \
      && ok "P4 candidate_build_absent=1 when no module declared the named build" \
      || no "P4 a capture holding nothing the candidate wrote still grades green: $(g P4GONE)"
    [ "$(g P4NONE)" = "None" ] \
      && ok "P4 None (not 0) when --build was not passed: a metric that cannot run reports no pass" \
      || no "P4 reports a PASS with no build named: $(g P4NONE)"

    while read -r k thr inf; do
        [ "$thr" = "thr=True" ] && [ "$inf" = "informational=False" ] \
          && ok "P5 $k is GATED" \
          || no "P5 $k is not gated ($thr $inf)"
    done < <(grep -a '^P5 ' "$R" | cut -d' ' -f2-)
fi

echo
echo "RESULT: $PASS passed, $FAIL failed  (fixtures: $OUT)"
[ "$FAIL" -eq 0 ] || exit 1
