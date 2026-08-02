#!/bin/bash
# Cold-boot acceptance: shut the VM down, start it, open a known scene, and require dom0 to
# actually receive the windows.
#
# Every check in this suite until now restarted the gui-agent inside a LIVE session. That path
# and the boot path are not the same: the first cold boot with the clipping change produced
# continuous EnumWindows failures and a qube with zero windows in dom0, while every existing
# check passed. A reboot is now part of acceptance.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
S="${SCRATCH:-/tmp}"
EXPECT="${1:-0}"   # 0 = derive from the scene itself (see below); pass a number to override
cd "$HERE"
export QTEST_INCOMING="${QTEST_INCOMING:-C:\\Users\\user\\Documents\\QubesIncoming\\win-idd-mgmt}"

echo "== cold boot =="
timeout 300 ./tools/qtest shutdown >/dev/null 2>&1
timeout 400 ./tools/qtest start   >/dev/null 2>&1
for i in $(seq 1 10); do
    if printf 'echo OK\r\n' | timeout 60 qrexec-client-vm win-idd-test qubes.VMShell 2>/dev/null |
       tr -d '\r' | grep -q OK; then echo "  qrexec up"; break; fi
    timeout 40 ./tools/qtest run "ping -n 6 127.0.0.1" >/dev/null 2>&1
done

# pushrun is flaky immediately after boot; a scene that did not run makes every number below
# meaningless, so retry until it demonstrably ran rather than reporting an empty result.
ran=0
for attempt in 1 2 3 4 5; do
    OUT=$(timeout 400 ./tools/qtest pushrun "$S/scene.ps1" 2>&1 | tr -d '\r')
    if echo "$OUT" | grep -q "guest top-level"; then
        echo "  scene ran (attempt $attempt)"; ran=1; break
    fi
    timeout 60 ./tools/qtest run "ping -n 10 127.0.0.1" >/dev/null 2>&1
done
[ "$ran" = 1 ] || { echo "FAIL: scene never ran; nothing was verified"; exit 1; }

# Expect what the scene ACTUALLY created, not a hardcoded number: chromerepro is absent on a
# freshly installed guest, so the old default of 3 failed a healthy build. The scene prints
# one line per guest top-level window under its header.
scenelist=$(echo "$OUT" | sed -n '/guest top-level windows now visible/,$p' | grep -E '^\s+[0-9]+,[0-9]+ ')
scenecount=$(echo "$scenelist" | grep -c .)
# chromerepro deliberately shows 5 guest windows (1 main + 4 layered shadow strips) of which
# the agent maps exactly ONE - that is the 2A-chrome fix working. Counting raw guest windows
# would demand the strips appear in dom0 and fail a correct build.
chromecount=$(echo "$scenelist" | grep -ci chromerepro)
expected=$(( scenecount - chromecount + (chromecount > 0 ? 1 : 0) ))
[ "$expected" -gt 0 ] 2>/dev/null && EXPECT="$expected"
echo "  scene: $scenecount guest window(s), $chromecount of them chromerepro -> expecting $EXPECT in dom0"

# Windows do not reach dom0 the instant the scene returns (map + first damage + daemon
# pixmap), and local.WinScreenshot occasionally returns an empty tar. Retry rather than
# reporting 0 on a healthy build - that produced two false FAILs before this was fixed.
n=0
for attempt in 1 2 3 4 5; do
    sleep 15
    qrexec-client-vm dom0 local.WinScreenshot </dev/null > "$S/cb.tar" 2>/dev/null
    rm -rf "$S/cb" && mkdir -p "$S/cb" && tar -xf "$S/cb.tar" -C "$S/cb" 2>/dev/null
    n=$(ls "$S/cb"/*.png 2>/dev/null | wc -l)
    [ "$n" -ge "$EXPECT" ] && break
    echo "  (attempt $attempt: $n/$EXPECT windows, retrying)"
done
rm -rf "$S/cb" && mkdir -p "$S/cb" && tar -xf "$S/cb.tar" -C "$S/cb" 2>/dev/null
n=$(ls "$S/cb"/*.png 2>/dev/null | wc -l)
echo "  dom0 windows: $n (expected >= $EXPECT)"

fails=$(timeout 250 ./tools/qtest pushrun "$S/vchanchk.ps1" 2>&1 | tr -d '\r' | grep -cE "EnumWindows failed")
echo "  EnumWindows failures since boot: $fails"

rc=0
[ "$n" -ge "$EXPECT" ] || { echo "FAIL: dom0 received $n windows, expected >= $EXPECT"; rc=1; }
[ "$fails" -eq 0 ]     || { echo "FAIL: $fails EnumWindows failures - z-order unreliable, clipping degraded"; rc=1; }
[ $rc -eq 0 ] && echo "cold boot OK"
exit $rc
