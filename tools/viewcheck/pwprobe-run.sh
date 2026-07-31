#!/bin/bash
# Gate 0 runner: push pwprobe.exe, run it in the interactive session, print the verdict.
# Retries until the probe demonstrably ran (pushrun's first push intermittently sends 0
# bytes — see coldboot-test.sh); a run that produced no result file is retried, not judged.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$HERE"
EXE="${1:?usage: pwprobe-run.sh <path-to-pwprobe.exe>}"
export QTEST_INCOMING="${QTEST_INCOMING:-C:\\Users\\user\\Documents\\QubesIncoming\\win-idd-mgmt}"
S="${SCRATCH:-/tmp}"

# guest-side scene: run the exe (blocking), then emit the result file with a marker
cat > "$S/pwprobe-scene.ps1" <<'EOF'
$dir = "C:\Users\user\Documents\QubesIncoming\win-idd-mgmt"
Remove-Item "$dir\pwprobe-result.txt" -ErrorAction SilentlyContinue
$p = Start-Process "$dir\pwprobe.exe" -PassThru
$null = $p.WaitForExit(30000)
if (Test-Path "$dir\pwprobe-result.txt") {
    Write-Output "=== PWPROBE RESULT ==="
    Get-Content "$dir\pwprobe-result.txt"
    Write-Output "=== END ==="
    Write-Output ("exe-sha256=" + (Get-FileHash "$dir\pwprobe.exe" -Algorithm SHA256).Hash)
} else {
    Write-Output "PWPROBE-NO-RESULT (exit=$($p.ExitCode))"
}
EOF

timeout 120 ./tools/qtest push "$EXE" >/dev/null 2>&1

for attempt in 1 2 3 4 5; do
    OUT=$(timeout 200 ./tools/qtest pushrun "$S/pwprobe-scene.ps1" 2>&1 | tr -d '\r')
    if echo "$OUT" | grep -q "=== PWPROBE RESULT ==="; then
        echo "$OUT"
        exit 0
    fi
    # push may have sent 0 bytes; re-push the exe and try again
    timeout 120 ./tools/qtest push "$EXE" >/dev/null 2>&1
    timeout 40 ./tools/qtest run "ping -n 5 127.0.0.1" >/dev/null 2>&1
done
echo "FAIL: probe never demonstrably ran"
exit 1
