#!/bin/bash
# Fetch the official Windows 10 22H2 (multi-edition, retail/non-eval) ISO link from
# Microsoft's software-download connector API.
#
# STATUS (measured 2026-08-01, on a residential exit): steps 1-3 work headlessly - the
# SKU catalogue comes back fine (English = SKU 16067). The final link call is refused
# with {"Key":"ErrorSettings.SentinelReject"}: Microsoft's Sentinel rejects the SESSION,
# not the IP, because a headless client never executes the vlscppe fingerprint
# JavaScript. quickget and Fido fail the same way for the same reason.
#
# To finish the automation, the fingerprint has to run in a real browser engine once and
# its cookies reused here (e.g. a headless-Firefox/Playwright step that loads the page,
# then hand off the cookie jar). Until then: open the page in a browser, copy the
# generated link (valid ~24h), and curl it - which is what was done for the current ISO.
set -uo pipefail
LANG_NAME="${1:-English}"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"
PAGE="https://www.microsoft.com/en-us/software-download/windows10ISO"
SID=$(cat /proc/sys/kernel/random/uuid)
JAR=$(mktemp)
curl -s -c "$JAR" -A "$UA" -o /dev/null "$PAGE"
curl -s -b "$JAR" -A "$UA" -o /dev/null "https://vlscppe.microsoft.com/fp/tags?org_id=y6jn8c31&session_id=$SID"
API="https://www.microsoft.com/software-download-connector/api"
sleep 2; SKUS=$(curl -s -b "$JAR" -A "$UA" -H "Referer: $PAGE" \
  "$API/getskuinformationbyproductedition?profile=606624d44113&ProductEditionId=2618&SKU=undefined&friendlyFileName=undefined&Locale=en-US&sessionID=$SID")
SKU=$(printf '%s' "$SKUS" | python3 -c "
import json,sys
want=sys.argv[1]
d=json.load(sys.stdin)
print(next((s['Id'] for s in d['Skus'] if want in (s['Language'], s.get('LocalizedLanguage'))), ''))" "$LANG_NAME")
[ -n "$SKU" ] || { echo 'no SKU for that language' >&2; exit 1; }
curl -s -b "$JAR" -A "$UA" -H "Referer: $PAGE" \
  "$API/GetProductDownloadLinksBySku?profile=606624d44113&productEditionId=undefined&SKU=$SKU&friendlyFileName=undefined&Locale=en-US&sessionID=$SID" \
  | python3 -c "
import json,sys
raw=sys.stdin.read()
try: d=json.loads(raw)
except Exception: print('unexpected response:', raw[:300], file=sys.stderr); sys.exit(1)
errs=(d.get('ValidationContainer') or {}).get('Errors') or []
if errs: print('API errors:', errs, file=sys.stderr)
for o in d.get('ProductDownloadOptions') or []:
    print(o.get('Name'), o.get('Uri'))"
rm -f "$JAR"
